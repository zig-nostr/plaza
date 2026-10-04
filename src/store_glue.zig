//! The way into the local store, and the backups of the reader's own replaceable lists.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const activePubkey = main.activePubkey;
const blossom_list_kind = main.blossom_list_kind;
const bookmark_list_kind = main.bookmark_list_kind;
const contact_list_kind = main.contact_list_kind;
const generic_repost_kind = main.generic_repost_kind;
const hexLower = main.hexLower;
const ingestBlossomList = main.ingestBlossomList;
const ingestBookmarkList = main.ingestBookmarkList;
const ingestMuteList = main.ingestMuteList;
const invalidateFeed = main.invalidateFeed;
const kindRender = main.kindRender;
const mute_list_kind = main.mute_list_kind;
const noteFeedArrival = main.noteFeedArrival;
const noteOwnContactListStored = main.noteOwnContactListStored;
const recordSeenOn = main.recordSeenOn;
const relay_list_kind = main.relay_list_kind;
const releasePendingFollowBase = main.releasePendingFollowBase;
const repost_kind = main.repost_kind;

/// How many superseded versions of each of our own lists to keep. Small on
/// purpose: this is a way back from the last mistake, not an archive. The
/// store's KV has no cursor and no delete, so a growing key scheme could never
/// be read back or pruned; one rewritten key per (kind, pubkey) can be both.
const own_backup_keep = 3;

/// The key holding this account's replaced versions of `kind`.
fn ownBackupKey(buf: *[96]u8, kind: u16, pubkey: [32]u8) []const u8 {
    var hex: [64]u8 = undefined;
    hexLower(&hex, pubkey);
    return std.fmt.bufPrint(buf, "backup/{d}/{s}", .{ kind, hex[0..] }) catch buf[0..0];
}

/// Whether a kind is one of OUR lists worth keeping a copy of. Deliberately
/// short: a backup for a kind nothing writes is a guess about the future, and
/// this app writes exactly these.
fn isOwnList(kind: u16) bool {
    return kind == 0 or kind == relay_list_kind or kind == contact_list_kind or
        kind == mute_list_kind or kind == bookmark_list_kind or kind == blossom_list_kind;
}

/// `plazaIngest` for an event a relay just delivered, which also remembers WHICH
/// relay delivered it. A relay that sent a note holds it, and that is the best
/// thing Plaza knows when it later has to name a relay for that note (see
/// `hintsFor`). An event that does not verify is not remembered: it proves
/// nothing about where anything lives.
pub fn plazaIngestFrom(gpa: std.mem.Allocator, ev: nostr.event.Event, options: nostr.store.IngestOptions, relay_url: []const u8) !nostr.store.IngestResult {
    const result = try plazaIngest(gpa, ev, options);
    if (result != .invalid) recordSeenOn(ev, relay_url);
    return result;
}

/// The one door into the store.
///
/// Every `store.ingest` in this app goes through here, because the backup has to
/// happen BEFORE the write that destroys what it is backing up, and a single
/// missed call site is a contact list lost while the app believes it has a copy.
pub fn plazaIngest(gpa: std.mem.Allocator, ev: nostr.event.Event, options: nostr.store.IngestOptions) !nostr.store.IngestResult {
    const store = main.g_store orelse return error.NoStore;
    // Read what is about to be destroyed, BEFORE the write that destroys it,
    // but keep the copy only once the store says it actually replaced
    // something. Backing up on the way in was wrong twice over: the signature
    // is not checked until inside `ingest`, so three forged events carrying the
    // reader's pubkey and a future stamp would rotate their real history out of
    // a three-slot ring from across the network; and the store's own rule for
    // what replaces what (NIP-01's tie-break on equal timestamps) is the only
    // correct answer to whether a copy is even needed.
    const previous = capturePrevious(gpa, store, ev);
    defer if (previous) |prev| gpa.free(prev.json);
    const result = try store.ingest(gpa, ev, options);
    if (result == .replaced) {
        if (previous) |prev| keepReplaced(gpa, store, ev.kind, prev.json);
    }
    // A contact list this app was holding as the base for the next follow is
    // released the moment one at least as new reaches the store. This is the one
    // door every ingest goes through: `ingestContactList` only sees a relay
    // ECHO, so a locally signed list would otherwise be held until the reader
    // signed out.
    if (ev.kind == contact_list_kind and result != .invalid) {
        if (activePubkey()) |pk| {
            if (std.mem.eql(u8, &pk, &ev.pubkey)) {
                releasePendingFollowBase(ev.created_at);
                // And the view's cheap answer to "do they have a list", which is
                // asked once per note card per frame and must never be an LMDB
                // query again.
                noteOwnContactListStored(pk);
            }
        }
    }
    // What the feed needs to know about this, and the only place that can say
    // it: the store's own event count moves for every kind, so it cannot tell a
    // note from a reaction, and the feed used to re-read everything on either.
    switch (ev.kind) {
        1 => if (result == .added) noteFeedArrival(ev.id),
        // A repost forces the fuller read rather than splicing.
        //
        // The splice path is keyed on the arriving event's OWN id: it asks
        // whether that id is already held, and merges it by its own timestamp.
        // For a repost neither is the card. The card is the note it points at,
        // which may already be on screen under its own name and which has a
        // different id and a different time. Teaching the splice to unwrap
        // would mean teaching it all three, and the full read already knows
        // how. Reposts are a small share of arrivals, so paying for a rebuild
        // on one is cheaper than a splice that puts the wrong row in the wrong
        // place.
        repost_kind, generic_repost_kind => if (result == .added) {
            // The reposted note, out of the wrapper's content, ingested like
            // anything else so `ingest` checks its signature. NIP-18 puts the
            // whole event there and this app writes it too, so the note is
            // usually in hand without asking any relay for it.
            //
            // Straight to `store.ingest` rather than back through here: the
            // embedded event is a note, this door is for arrivals, and routing
            // it back would invite a wrapper that contains a wrapper.
            ingestRepostedNote(gpa, store, ev);
            invalidateFeed();
        },
        // A deletion takes a note OUT, and no arrival describes a removal, so
        // the list in hand has to be read again. Amethyst hit the mirror image
        // of this: one kind:5 folded into an ordinary batch quietly emptied rows
        // that had nothing to do with it, because their splice could only add.
        5 => if (result != .invalid) invalidateFeed(),
        mute_list_kind => if (result != .invalid) ingestMuteList(ev),
        bookmark_list_kind => if (result != .invalid) ingestBookmarkList(ev),
        blossom_list_kind => if (result != .invalid) ingestBlossomList(ev),
        else => {},
    }
    return result;
}

/// Stores the note carried inside a repost, when it carries one.
///
/// Every reference client treats the embedded copy this way: as a shortcut that
/// saves a round trip, never as something to draw. Amethyst consumes it into
/// the cache keyed by its OWN id and verified like any relay event; Jumble and
/// Coracle both verify it and fall back to fetching when it fails. Nothing
/// renders it straight out of the wrapper, because the wrapper's author chose
/// those bytes and no relay serving them vouches for them.
///
/// Here that safety is `store.ingest`, which checks the signature and refuses
/// anything that does not match its own id. A forged copy is simply not stored,
/// and the feed then finds nothing to draw and skips the row, which is what
/// Notedeck does for a target it cannot resolve.
fn ingestRepostedNote(gpa: std.mem.Allocator, store: *nostr.store.Store, ev: nostr.event.Event) void {
    if (ev.content.len == 0) return;
    var parsed = nostr.event.fromJson(gpa, ev.content) catch return;
    defer parsed.deinit();
    // Only what a feed row can be. A repost naming something else is legal and
    // is not a row here.
    if (kindRender(parsed.value.kind) != .note) return;
    _ = store.ingest(gpa, parsed.value, .{}) catch return;
}

const ReplacedCopy = struct { json: []u8 };

/// The version `ev` would replace, serialised, or null when there is nothing to
/// keep. Cheap for everything that is not one of our own lists: a kind compare.
fn capturePrevious(gpa: std.mem.Allocator, store: *nostr.store.Store, ev: nostr.event.Event) ?ReplacedCopy {
    if (!isOwnList(ev.kind)) return null;
    const pk = activePubkey() orelse return null;
    if (!std.mem.eql(u8, &pk, &ev.pubkey)) return null;

    const kinds = [_]u16{ev.kind};
    const authors = [_][32]u8{pk};
    var result = store.query(gpa, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return null;
    defer result.deinit();
    if (result.events.len == 0) return null;
    // The same event arriving twice replaces nothing.
    if (std.mem.eql(u8, &result.events[0].id, &ev.id)) return null;
    const json = nostr.event.toJson(gpa, result.events[0]) catch return null;
    return .{ .json = json };
}

/// Guards the backup ring. The read-modify-write below spans three separate LMDB
/// transactions, and eight ingest threads plus the UI thread can reach it, so
/// without this two replacements landing together can leave the ring holding two
/// copies of one version and none of the other.
var g_backup_lock = std.atomic.Value(bool).init(false);

/// Puts `json` at the front of the ring for `kind`, dropping the oldest.
fn keepReplaced(gpa: std.mem.Allocator, store: *nostr.store.Store, kind: u16, json: []const u8) void {
    const pk = activePubkey() orelse return;
    var key_buf: [96]u8 = undefined;
    const key = ownBackupKey(&key_buf, kind, pk);
    if (key.len == 0) return;

    while (g_backup_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    defer g_backup_lock.store(false, .release);

    // Newest first, oldest dropped: the reader wants the version from a minute
    // ago, not the one from last year, and the KV cannot be pruned any other way.
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, json) catch return;
    out.append(gpa, '\n') catch return;
    if (store.get(gpa, key) catch null) |old| {
        defer gpa.free(old);
        var lines = std.mem.tokenizeScalar(u8, old, '\n');
        var kept: usize = 1;
        while (lines.next()) |line| {
            if (kept >= own_backup_keep) break;
            if (line.len == 0) continue;
            out.appendSlice(gpa, line) catch return;
            out.append(gpa, '\n') catch return;
            kept += 1;
        }
    }
    store.put(key, out.items) catch {};
}
/// The versions of `kind` this account has had replaced, newest first. This is
/// the half that makes the backup real: a copy nothing can read back is not a
/// copy, it is a belief.
pub fn ownListBackups(gpa: std.mem.Allocator, kind: u16) ?[]u8 {
    const store = main.g_store orelse return null;
    const pk = activePubkey() orelse return null;
    var key_buf: [96]u8 = undefined;
    const key = ownBackupKey(&key_buf, kind, pk);
    if (key.len == 0) return null;
    return store.get(gpa, key) catch null;
}

/// How many whole-record reads have happened. See `ownRecordJson`.
pub var g_own_record_reads: usize = 0;
/// Whether this account has a stored event of `kind` at all.
///
/// Distinct from `ownRecordJson` on purpose: this reads one row and copies
/// nothing, where that duplicates the record's content and every one of its tags.
/// For a question that is only ever "is there one", the copy was the whole cost.
pub fn ownRecordExists(kind: u16) bool {
    const store = main.g_store orelse return false;
    const pk = activePubkey() orelse return false;
    const kinds = [_]u16{kind};
    const authors = [_][32]u8{pk};
    var result = store.query(std.heap.page_allocator, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return false;
    defer result.deinit();
    return result.events.len != 0;
}

/// When this account's newest stored event of `kind` was signed, or 0.
///
/// Every replaceable record this app writes needs this: a new one must beat the
/// stored one or it is dropped silently, by this store and by every relay, while
/// the app goes on showing the change as applied.
pub fn ownRecordCreatedAt(kind: u16) i64 {
    const store = main.g_store orelse return 0;
    const pk = activePubkey() orelse return 0;
    const kinds = [_]u16{kind};
    const authors = [_][32]u8{pk};
    var result = store.query(std.heap.page_allocator, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return 0;
    defer result.deinit();
    if (result.events.len == 0) return 0;
    return result.events[0].created_at;
}

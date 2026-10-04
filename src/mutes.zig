//! The mute list: reading it, and writing it without losing anything.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const own_lists = @import("own_lists.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const ownWriteUnstored = main.ownWriteUnstored;
const listWriteInFlight = main.listWriteInFlight;
const Model = main.Model;
const forgetBookmarks = main.forgetBookmarks;
const loadBookmarksFromStore = main.loadBookmarksFromStore;
const sayMuteWrite = main.sayMuteWrite;
const Effects = main.Effects;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
const countPeople = main.countPeople;
const freeOwnProfile = main.freeOwnProfile;
const hexEqlIgnoreCase = main.hexEqlIgnoreCase;
const hexLower = main.hexLower;
const invalidateFeed = main.invalidateFeed;
const max_mutes = main.max_mutes;
const mute_list_kind = main.mute_list_kind;
const nowSeconds = main.nowSeconds;
const ownRecordCreatedAt = main.ownRecordCreatedAt;
const ownRecordJson = main.ownRecordJson;
const ownWriteBase = main.ownWriteBase;
const privateHalfGate = main.privateHalfGate;
const privateHalfOpened = main.privateHalfOpened;
const shrinkAllowed = main.shrinkAllowed;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const takeFresh = main.takeFresh;

// ---------------------------------------------------------------- muting
//
// The reader's NIP-51 mute list, read and honoured. Not written: a mute list is
// REPLACEABLE, and the rule this app already learned about contact lists holds
// here too, that nothing may write over a record it has not read back first.
// Jumble does the careful version of that write (it re-fetches immediately
// before every change, and when the fetch comes back empty it ASKS rather than
// assuming there is nothing there, because "not found" and "the fetch failed"
// look identical). Doing that properly is its own change; honouring a list made
// elsewhere costs nothing and is most of the value, because muting is something
// people mostly did in whatever client they came from.

pub var g_mutes: [max_mutes][32]u8 = undefined;
pub var g_mute_count: usize = 0;
var g_mute_owner: ?[32]u8 = null;
var g_mute_created_at: i64 = 0;
var g_mute_lock = std.atomic.Value(bool).init(false);

pub fn lockMutes() void {
    while (g_mute_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockMutes() void {
    g_mute_lock.store(false, .release);
}

/// Whether the list in memory is THIS account's. Same question the follow set
/// asks, and for the same reason: one account's mutes must never silently
/// become another's.
pub fn mutesAreOwned() bool {
    const pk = activePubkey() orelse return false;
    const owner = g_mute_owner orelse return false;
    return std.mem.eql(u8, &owner, &pk);
}

/// Whether this reader has muted `pubkey`.
///
/// The one question the rest of the app asks. Answering false when no list is
/// known is the right default in a way the follow set's is not: an unknown
/// follow list falls back to a starter pack, but an unknown mute list has no
/// stand-in, and inventing one would hide people nobody asked to hide.
pub fn isMuted(pubkey: [32]u8) bool {
    lockMutes();
    defer unlockMutes();
    if (!mutesAreOwned()) return false;
    for (g_mutes[0..g_mute_count]) |m| {
        if (std.mem.eql(u8, &m, &pubkey)) return true;
    }
    return false;
}

/// How many accounts this reader has muted.
pub fn muteCount() usize {
    lockMutes();
    defer unlockMutes();
    if (!mutesAreOwned()) return 0;
    return g_mute_count;
}

/// Installs a mute set as this account's. Returns whether anything changed.
pub fn setMutes(list: []const [32]u8, created_at: i64) bool {
    const pk = activePubkey() orelse return false;
    lockMutes();
    const same = blk: {
        if (!mutesAreOwned()) break :blk false;
        if (g_mute_count != @min(list.len, max_mutes)) break :blk false;
        for (list[0..@min(list.len, max_mutes)], 0..) |m, i| {
            if (!std.mem.eql(u8, &m, &g_mutes[i])) break :blk false;
        }
        break :blk true;
    };
    if (same) {
        unlockMutes();
        return false;
    }
    const n = @min(list.len, max_mutes);
    @memcpy(g_mutes[0..n], list[0..n]);
    g_mute_count = n;
    g_mute_owner = pk;
    g_mute_created_at = created_at;
    unlockMutes();
    // The feed in hand was built without this. Unlike a follow change, an empty
    // list is a meaningful answer here (they unmuted everybody), so this runs on
    // any change rather than only on a non-empty one.
    invalidateFeed();
    return true;
}

/// Forgets whose list this is, on any identity change.
pub fn forgetMutes() void {
    lockMutes();
    g_mute_owner = null;
    g_mute_count = 0;
    g_mute_created_at = 0;
    unlockMutes();
}

/// The pubkeys a kind:10000's public `p` tags name, deduped.
///
/// Only `p`. NIP-51 also allows `t` (hashtags), `word` and `e` (threads) here,
/// and none of those is read yet: hiding a person is the whole of what the feed
/// can act on today, and claiming to honour a word filter that does nothing
/// would be worse than not claiming it.
fn mutesFromTags(tags: []const nostr.event.Tag, out: [][32]u8) usize {
    @setRuntimeSafety(true); // Tags off a relay, and `out` is indexed as they are walked.
    var n: usize = 0;
    for (tags) |tag| {
        if (n >= out.len) break;
        if (tag.len < 2) continue;
        if (!std.mem.eql(u8, tag[0], "p")) continue;
        if (tag[1].len != 64) continue;
        var pk: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk, tag[1]) catch continue;
        var seen = false;
        for (out[0..n]) |had| {
            if (std.mem.eql(u8, &had, &pk)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        out[n] = pk;
        n += 1;
    }
    return n;
}
pub const MuteWrite = enum {
    published,
    /// Already muted, or already not, or the reader themselves.
    nothing_to_do,
    /// A signature is already out. One key signs one thing at a time.
    signer_busy,
    /// This account's mute list has not been read back yet. Publishing one now
    /// would replace whatever is really out there with a list of one name.
    no_list_yet,
    /// The list has a private half the signer has not opened yet. Nothing is
    /// published; the answer lands on a later tick.
    private_half_waiting,
    /// The signer refused to open it, or never answered. Nothing is published,
    /// and the press has asked it again.
    private_half_declined,
    /// The list has a private half this app could not decrypt, so it cannot
    /// carry it forward and will not write without it.
    private_half_unreadable,
    /// The write would have dropped more people than the press asked for.
    would_shrink,
    /// The last write was published and is not in the store yet, so the store
    /// holds an older list than the relays do.
    not_read_back,
    failed,
};
/// Mutes or unmutes `pubkey`, by splicing this reader's own kind:10000.
///
/// The same discipline the contact list learned, for the same reason: this is a
/// REPLACEABLE record, so publishing one replaces what the reader has muted
/// everywhere at once.
///
/// Jumble asks the user when it cannot find a list, because "you have no mute
/// list" and "the fetch failed" are indistinguishable from here. This refuses
/// instead, which is the answer this app already gives for a contact list, and
/// the button says why rather than silently doing nothing. A key minted here is
/// the one case where having no list is a fact rather than a failed read.
pub fn writeMute(fx: *Effects, pubkey: [32]u8, muting: bool) MuteWrite {
    if (!signerReady()) return .signer_busy;
    if (listWriteInFlight(mute_list_kind)) return .signer_busy;
    if (ownWriteUnstored(mute_list_kind)) return .not_read_back;
    const me = activePubkey() orelse return .failed;
    // Muting yourself would hide your own notes from your own feed.
    if (std.mem.eql(u8, &me, &pubkey)) return .nothing_to_do;
    const gpa = std.heap.page_allocator;

    var previous: ?OwnProfile = null;
    if (ownWriteBase(gpa, mute_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);

    const base_tags: []const nostr.event.Tag = if (previous) |prev| prev.tags else &.{};
    const base_content: []const u8 = if (previous) |prev| prev.json else "";
    const have_base = previous != null;
    const base_created_at: i64 = if (previous) |prev| prev.created_at else 0;

    if (!have_base and !own_lists.g_identity_minted_here and !takeFresh(.mutes)) return .no_list_yet;

    // The private half, carried forward VERBATIM and only when it is understood.
    //
    // This is the bug in Jumble worth not copying. Its `getPrivateTags` returns
    // an empty list when the decrypt throws, and the write then sets `content`
    // to `''`, publishing away every private mute the reader had. A bunker
    // reader hits that path every time, because the decrypt needs a NIP-46 round
    // trip.
    //
    // This app makes that round trip: the half is opened by whoever holds the
    // key, through the same cache bookmarks use, and what is carried forward is
    // the ciphertext the reader already has. So content that is present and not
    // yet opened means no write at all, and the reader is told which of waiting,
    // declined or unreadable it is.
    if (base_content.len > 0) switch (privateHalfGate(gpa, base_content)) {
        .readable => {},
        .waiting => return .private_half_waiting,
        .declined => return .private_half_declined,
        .unreadable => return .private_half_unreadable,
    };

    var tags = std.ArrayList(nostr.event.Tag).empty;
    var handed_off = false;
    defer if (!handed_off) {
        for (tags.items) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        tags.deinit(gpa);
    };
    var found = false;
    var hex: [64]u8 = undefined;
    hexLower(&hex, pubkey);

    // Every tag is carried, `p` and otherwise. NIP-51 also puts hashtags,
    // words and threads in here, and this app reads none of those: dropping
    // what it does not understand would delete a filter the reader set in a
    // client that does.
    for (base_tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and hexEqlIgnoreCase(tag[1], &hex)) {
            found = true;
            if (!muting) continue;
        }
        const copy = gpa.alloc([]const u8, tag.len) catch return .failed;
        for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    }

    if (muting) {
        if (found) return .nothing_to_do;
        const copy = gpa.alloc([]const u8, 2) catch return .failed;
        copy[0] = gpa.dupe(u8, "p") catch return .failed;
        copy[1] = gpa.dupe(u8, &hex) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    } else if (!found) {
        return .nothing_to_do;
    }

    // The same shrink guard the contact list has. A mute adds exactly one name
    // and an unmute removes exactly one, so a write that drops more than that is
    // a bug here or a stale base, and refusing beats publishing it.
    if (have_base and !shrinkAllowed(countPeople(base_tags), countPeople(tags.items), muting)) return .would_shrink;

    const owned_tags = tags.toOwnedSlice(gpa) catch return .failed;
    handed_off = true;
    const content = gpa.dupe(u8, base_content) catch return .failed;
    const created = @max(@max(nowSeconds(), ownRecordCreatedAt(mute_list_kind) + 1), base_created_at + 1);

    // The live set moves first, so the feed reflects the press immediately.
    var next: [max_mutes][32]u8 = undefined;
    var n = mutesFromTags(owned_tags, &next);
    n += privateMutes(gpa, content, next[n..]);
    // Read BEFORE the set moves, for the same reason the contact list does.
    const undo_stamp = g_mute_created_at;
    _ = setMutes(next[0..n], created);

    signAndPublish(fx, gpa, created, mute_list_kind, owned_tags, content, false, .{ .mute = .{ .pubkey = pubkey, .added = muting, .created_at = undo_stamp } }, null);
    return .published;
}
/// Seeds the mute set from the local store, at boot and at sign-in, so a muted
/// account is hidden from the first frame rather than after a round trip.
pub fn loadMutesFromStore() void {
    const gpa = std.heap.page_allocator;
    const own = ownRecordJson(gpa, mute_list_kind) orelse return;
    defer freeOwnProfile(gpa, own);
    var list: [max_mutes][32]u8 = undefined;
    var n = mutesFromTags(own.tags, &list);
    n += privateMutes(gpa, own.json, list[n..]);
    // No `if (n == 0) return` here, deliberately, and this is the one place the
    // mute list differs from the contact list. An empty contact list is a
    // malformed event to be ignored, because a reader with no follows has no
    // feed; an empty mute list is somebody who unmuted everybody, and refusing
    // to adopt it would leave the last person they unmuted hidden.
    _ = setMutes(list[0..n], own.created_at);
}

/// A mute list arriving from a relay. Newer wins; the reader's own only.
pub fn ingestMuteList(ev: nostr.event.Event) void {
    const me = activePubkey() orelse return;
    if (!std.mem.eql(u8, &me, &ev.pubkey)) return;
    lockMutes();
    const owned = mutesAreOwned();
    const held_at = g_mute_created_at;
    unlockMutes();
    if (owned and ev.created_at <= held_at) return;
    const gpa = std.heap.page_allocator;
    var list: [max_mutes][32]u8 = undefined;
    var n = mutesFromTags(ev.tags, &list);
    n += privateMutes(gpa, ev.content, list[n..]);
    _ = setMutes(list[0..n], ev.created_at);
}

/// The private half of a mute list: `content` is a JSON array of tags,
/// encrypted to yourself, which NIP-51 says may be NIP-04 or NIP-44.
///
/// Opened by whoever holds the key, never here: Notary over its loopback door,
/// or a bunker over NIP-46 (`nip44_decrypt`, or `nip04_decrypt` for a legacy
/// half). Until the answer lands the half reads as no mutes AND as unreadable,
/// and `writeMute` refuses on the second of those, because a failed decrypt that
/// is allowed to look like an empty half is how Jumble publishes away every
/// private mute the reader had.
pub fn privateMutes(gpa: std.mem.Allocator, content: []const u8, out: [][32]u8) usize {
    if (content.len == 0 or out.len == 0) return 0;
    // From the cache Notary fills, not from a secret key here. A miss queues
    // the ask and reads as "cannot read", which is the fail-safe every caller
    // already handles.
    const plain = privateHalfOpened(content) orelse return 0;
    const parsed = std.json.parseFromSlice([]const []const []const u8, gpa, plain, .{}) catch return 0;
    defer parsed.deinit();
    var tags = gpa.alloc(nostr.event.Tag, parsed.value.len) catch return 0;
    defer gpa.free(tags);
    for (parsed.value, 0..) |tag, i| tags[i] = tag;
    return mutesFromTags(tags, out);
}

pub fn privateMutesForTest(content: []const u8, out: [][32]u8) usize {
    return privateMutes(std.heap.page_allocator, content, out);
}
pub fn writeMuteForTest(fx: *Effects, pubkey: [32]u8, muting: bool) MuteWrite {
    return writeMute(fx, pubkey, muting);
}
pub fn forgetMutesForTest() void {
    forgetMutes();
    forgetBookmarks();
}

pub fn setMutesForTest(list: []const [32]u8, created_at: i64) bool {
    return setMutes(list, created_at);
}

pub fn loadMutesFromStoreForTest() void {
    loadMutesFromStore();
    loadBookmarksFromStore();
}

pub fn ingestMuteListForTest(ev: nostr.event.Event) void {
    ingestMuteList(ev);
}
pub fn sayMuteWriteForTest(model: *Model, outcome: MuteWrite, muting: bool) void {
    sayMuteWrite(model, outcome, muting);
}

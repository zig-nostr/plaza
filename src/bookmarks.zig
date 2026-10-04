//! Bookmarks, public and private.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const own_lists = @import("own_lists.zig");
const private_lists = @import("private_lists.zig");
const keyholder = @import("keyholder.zig");
const feed_state = @import("feed_state.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const unstored_toast = main.unstored_toast;
const ownWriteUnstored = main.ownWriteUnstored;
const listWriteInFlight = main.listWriteInFlight;
const parkSealAnswer = main.parkSealAnswer;
const max_private_cipher_len = main.max_private_cipher_len;
const plausibleSeal = main.plausibleSeal;
const max_private_plain_len = main.max_private_plain_len;
const privateSealKey = main.privateSealKey;
const sayBookmarkWrite = main.sayBookmarkWrite;
const Effects = main.Effects;
const Model = main.Model;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
const bookmark_list_kind = main.bookmark_list_kind;
const freeOwnProfile = main.freeOwnProfile;
const helperFetch = main.helperFetch;
const hexEqlIgnoreCase = main.hexEqlIgnoreCase;
const hexLower = main.hexLower;
const max_bookmarks = main.max_bookmarks;
const noHistoryKnown = main.noHistoryKnown;
const noListToast = main.noListToast;
const nowSeconds = main.nowSeconds;
const ownRecordCreatedAt = main.ownRecordCreatedAt;
const ownRecordJson = main.ownRecordJson;
const ownWriteBase = main.ownWriteBase;
const privateHalfGate = main.privateHalfGate;
const privateHalfOpened = main.privateHalfOpened;
const freePrivatePlain = main.freePrivatePlain;
const private_seal_key = main.private_seal_key;
const requestRemoteEncrypt = main.requestRemoteEncrypt;
const sameRecord = main.sameRecord;
const setToast = main.setToast;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const takeFresh = main.takeFresh;

// ------------------------------------------------------------- bookmarks

/// The event ids this reader has bookmarked, public half and private half
/// together, and whose list it is.
///
/// Both halves in one set on purpose: a bookmark is a bookmark, and a reader who
/// saved one privately in another client should still see it filled in here.
/// Which half a given one lives in only matters when writing, and the write
/// reads the record again anyway.
var g_bookmarks: [max_bookmarks][32]u8 = undefined;
var g_bookmark_count: usize = 0;
var g_bookmark_owner: ?[32]u8 = null;
var g_bookmark_created_at: i64 = 0;
var g_bookmarks_lock = std.atomic.Value(bool).init(false);

fn lockBookmarks() void {
    while (g_bookmarks_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlockBookmarks() void {
    g_bookmarks_lock.store(false, .release);
}

/// Whether the set in memory belongs to the account that is signed in. The same
/// question the mute set answers, and for the same reason: a set left over from
/// another account would be written back as this one's.
pub fn bookmarksAreOwned() bool {
    const me = activePubkey() orelse return false;
    const owner = g_bookmark_owner orelse return false;
    return std.mem.eql(u8, &me, &owner);
}

pub fn bookmarkCount() usize {
    lockBookmarks();
    defer unlockBookmarks();
    if (!bookmarksAreOwned()) return 0;
    return g_bookmark_count;
}

/// Whether this note is in the list. Answered from memory, because the feed asks
/// it once per card per frame and a store query there would be a disk read per
/// row.
pub fn isBookmarked(event_id: [32]u8) bool {
    lockBookmarks();
    defer unlockBookmarks();
    if (!bookmarksAreOwned()) return false;
    for (g_bookmarks[0..g_bookmark_count]) |id| {
        if (std.mem.eql(u8, &id, &event_id)) return true;
    }
    return false;
}

pub fn bookmarkAt(i: usize) ?[32]u8 {
    lockBookmarks();
    defer unlockBookmarks();
    if (!bookmarksAreOwned() or i >= g_bookmark_count) return null;
    return g_bookmarks[i];
}

fn setBookmarks(list: []const [32]u8, created_at: i64) void {
    const pk = activePubkey() orelse return;
    lockBookmarks();
    const n = @min(list.len, max_bookmarks);
    @memcpy(g_bookmarks[0..n], list[0..n]);
    g_bookmark_count = n;
    g_bookmark_owner = pk;
    g_bookmark_created_at = created_at;
    unlockBookmarks();
}

pub fn forgetBookmarks() void {
    lockBookmarks();
    g_bookmark_owner = null;
    g_bookmark_count = 0;
    g_bookmark_created_at = 0;
    unlockBookmarks();
}

/// The event ids a bookmark list's `e` tags name, deduped.
///
/// Only `e`. NIP-51 also allows `a` (addressable events, so a long-form article
/// or a place), `t` and `r` in here, and none of those is read yet. They are
/// CARRIED on write, which is the part that matters: dropping what this app does
/// not draw would delete an article somebody bookmarked in another client.
fn bookmarksFromTags(tags: []const nostr.event.Tag, out: [][32]u8) usize {
    @setRuntimeSafety(true); // Tags off a relay, and `out` is indexed as they are walked.
    var n: usize = 0;
    for (tags) |tag| {
        if (n >= out.len) break;
        if (tag.len < 2) continue;
        if (!std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        var seen = false;
        for (out[0..n]) |had| {
            if (std.mem.eql(u8, &had, &id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        out[n] = id;
        n += 1;
    }
    return n;
}

/// The bookmarks in an encrypted half, read through the same cache the mute
/// list uses. A miss reads as none AND as unreadable, which the write path
/// tells apart with `privateHalfIsReadable`.
fn privateBookmarks(gpa: std.mem.Allocator, content: []const u8, out: [][32]u8) usize {
    // Asked even for an empty content or a full list, because the read is also
    // what tells the cache which half this list has now.
    const plain = privateHalfOpened(gpa, .bookmarks, content) orelse return 0;
    defer freePrivatePlain(gpa, plain);
    if (out.len == 0) return 0;
    const parsed = std.json.parseFromSlice([]const []const []const u8, gpa, plain, .{}) catch return 0;
    defer parsed.deinit();
    var tags = gpa.alloc(nostr.event.Tag, parsed.value.len) catch return 0;
    defer gpa.free(tags);
    for (parsed.value, 0..) |tag, i| tags[i] = tag;
    return bookmarksFromTags(tags, out);
}

pub fn loadBookmarksFromStore() void {
    const gpa = std.heap.page_allocator;
    const own = ownRecordJson(gpa, bookmark_list_kind) orelse return;
    defer freeOwnProfile(gpa, own);
    var list: [max_bookmarks][32]u8 = undefined;
    var n = bookmarksFromTags(own.tags, &list);
    n += privateBookmarks(gpa, own.json, list[n..]);
    setBookmarks(list[0..n], own.created_at);
}

/// A bookmark list arriving from a relay. Newer wins; this reader's own only.
pub fn ingestBookmarkList(ev: nostr.event.Event) void {
    const me = activePubkey() orelse return;
    if (!std.mem.eql(u8, &me, &ev.pubkey)) return;
    if (ev.created_at < g_bookmark_created_at) return;
    loadBookmarksFromStore();
}

pub const BookmarkWrite = enum {
    published,
    /// Already bookmarked, or already not.
    nothing_to_do,
    /// A signature is already out. One key signs one thing at a time.
    signer_busy,
    /// This account's bookmark list has not been read back yet. Publishing one
    /// now would replace whatever is really out there with a list of one note.
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
    /// The last write was published and is not in the store yet, so the store
    /// holds an older list than the relays do.
    not_read_back,
    failed,
};

/// Adds or removes a bookmark, by splicing this reader's own kind:10003.
///
/// A near-copy of `writeMute` rather than a generalisation of it, deliberately.
/// A shared "list writer" would be a second call site reconstructing the write
/// by hand, and that is exactly how Amethyst ends up with a path that defeats
/// the guard its own event class enforces. Two instances of one careful shape
/// are safer than one abstraction with two callers.
///
/// The gates, in order, are the whole safety of this:
///
///   1. The signer is free. One key signs one thing at a time.
///   2. The RAW previous record is read, tags and encrypted content whole,
///      never a parsed cache.
///   3. No record and no key minted here means REFUSE. LMDB holding no row and
///      the fetch not having landed are the same observation from in here, and
///      this is precisely where Jumble goes wrong: its cache stores a null for
///      "the relay returned nothing", its lookup cannot tell that from "never
///      fetched", and a toggle then publishes a one-item list with an empty
///      content over whatever was really out there.
///   4. A private half that is present and unreadable means no write at all.
///      Carrying it forward verbatim is the only safe thing to do with bytes
///      this app did not open, and publishing without them erases every private
///      bookmark the reader has.
pub fn writeBookmark(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    if (!signerReady()) return .signer_busy;
    if (listWriteInFlight(bookmark_list_kind)) return .signer_busy;
    if (ownWriteUnstored(bookmark_list_kind)) return .not_read_back;
    // A private bookmark being sealed is a write to this same list. Its finish
    // checks the stored record is the one it was built on, and a public write
    // still out is in no store, so that check could not see it: whichever
    // landed second would publish a list without the other.
    if (private_lists.g_private_seal.active) return .signer_busy;
    _ = activePubkey() orelse return .failed;
    forgetPrivateAnnounce();
    const gpa = std.heap.page_allocator;

    var previous: ?OwnProfile = null;
    if (ownWriteBase(gpa, bookmark_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);

    const base_tags: []const nostr.event.Tag = if (previous) |prev| prev.tags else &.{};
    const base_content: []const u8 = if (previous) |prev| prev.json else "";
    const have_base = previous != null;
    const base_created_at: i64 = if (previous) |prev| prev.created_at else 0;

    if (!have_base and !own_lists.g_identity_minted_here and !takeFresh(.bookmarks)) return .no_list_yet;

    if (base_content.len > 0) switch (privateHalfGate(gpa, .bookmarks, base_content)) {
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
    hexLower(&hex, event_id);

    // Every tag carried, `e` and otherwise. NIP-51 also puts addressable events,
    // hashtags and URLs in here, and this app draws none of those: dropping what
    // it does not understand would delete an article somebody bookmarked in
    // another client.
    for (base_tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "e") and hexEqlIgnoreCase(tag[1], &hex)) {
            found = true;
            if (!adding) continue;
        }
        const copy = gpa.alloc([]const u8, tag.len) catch return .failed;
        for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    }

    if (adding) {
        // Already there, in the public half or the private one. Removing a
        // PRIVATE bookmark is not something this can do by splicing public tags,
        // so a press on one is a no-op rather than a write that would leave the
        // private entry standing and the button wrong.
        if (found) return .nothing_to_do;
        if (isBookmarked(event_id)) return .nothing_to_do;
        const copy = gpa.alloc([]const u8, 2) catch return .failed;
        copy[0] = gpa.dupe(u8, "e") catch return .failed;
        copy[1] = gpa.dupe(u8, &hex) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    } else if (!found) {
        return .nothing_to_do;
    }

    const owned_tags = tags.toOwnedSlice(gpa) catch return .failed;
    handed_off = true;
    const content = gpa.dupe(u8, base_content) catch return .failed;
    const created = @max(@max(nowSeconds(), ownRecordCreatedAt(bookmark_list_kind) + 1), base_created_at + 1);

    // The set moves first, so the icon fills on the press rather than a round
    // trip later. Private entries are re-read from the carried content, so an
    // add or a remove of a public one never drops them out of the set.
    var next: [max_bookmarks][32]u8 = undefined;
    var n = bookmarksFromTags(owned_tags, &next);
    n += privateBookmarks(gpa, content, next[n..]);
    setBookmarks(next[0..n], created);

    signAndPublish(fx, gpa, created, bookmark_list_kind, owned_tags, content, false, .none, null);
    return .published;
}

/// Starts a PRIVATE bookmark write: seals the new private half, and parks.
///
/// Every gate the public path applies is applied here first, before anything is
/// sent to a signer, because a refusal after the ciphertext exists would leave
/// the reader wondering what happened to it.
pub fn writePrivateBookmark(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    if (!signerReady()) return .signer_busy;
    if (private_lists.g_private_seal.active) return .signer_busy;
    // And the other way round: a public write still out would be missing from
    // the record this seal is built on.
    if (listWriteInFlight(bookmark_list_kind)) return .signer_busy;
    if (ownWriteUnstored(bookmark_list_kind)) return .not_read_back;
    const me = activePubkey() orelse return .failed;
    forgetPrivateAnnounce();
    const gpa = std.heap.page_allocator;

    var previous: ?OwnProfile = null;
    if (ownWriteBase(gpa, bookmark_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);
    const base_content: []const u8 = if (previous) |prev| prev.json else "";
    if (previous == null and !noHistoryKnown(.bookmarks)) return .no_list_yet;
    if (base_content.len > 0) switch (privateHalfGate(gpa, .bookmarks, base_content)) {
        .readable => {},
        .waiting => return .private_half_waiting,
        .declined => return .private_half_declined,
        .unreadable => return .private_half_unreadable,
    };

    const plaintext = privateBookmarkPlaintext(gpa, base_content, event_id, adding) orelse {
        // Either nothing to do (already private, or not private), or the half
        // would not open. The readable check above has already ruled the second
        // out, so this is the first.
        return .nothing_to_do;
    };
    defer gpa.free(plaintext);
    // Past what NIP-44 can seal. No signer can do it, so nothing is asked.
    if (plaintext.len > max_private_plain_len) return .failed;
    if (builtin.is_test) {
        const n = @min(plaintext.len, g_test_seal_plain.len);
        @memcpy(g_test_seal_plain[0..n], plaintext[0..n]);
        g_test_seal_plain_len = n;
    }

    private_lists.g_seal_ask_seq +%= 1;
    if (private_lists.g_seal_ask_seq == 0) private_lists.g_seal_ask_seq = 1;
    private_lists.g_private_seal = .{ .active = true, .event_id = event_id, .adding = adding, .base = if (previous) |prev| prev.id else null, .account = me, .ask_seq = private_lists.g_seal_ask_seq, .plain_len = plaintext.len };
    // Kept so the half this publishes is open from the moment it is.
    private_lists.holdSealPlaintext(private_lists.g_seal_ask_seq, base_content, plaintext);

    if (keyholder.g_signer_kind == .remote) {
        private_lists.g_private_seal.awaiting_remote = true;
        if (!requestRemoteEncrypt(gpa, plaintext)) {
            private_lists.clearPrivateSeal();
            return .failed;
        }
        return .published;
    }

    var peer_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&peer_hex, "{x}", .{me}) catch {
        private_lists.clearPrivateSeal();
        return .failed;
    };
    // To yourself: NIP-51's private half is encrypted to your own key, so both
    // sides of the conversation key are this account's.
    const body = (nostr.signer_ipc.Cipher{ .peer = &peer_hex, .items = &.{plaintext} }).toJson(gpa) catch {
        private_lists.clearPrivateSeal();
        return .failed;
    };
    defer gpa.free(body);
    if (builtin.is_test) {
        sealPrivateBookmarkForTest(gpa, plaintext);
        return .published;
    }
    helperFetch(fx, privateSealKey(private_lists.g_private_seal.ask_seq), "/nip44/encrypt", body, Effects.responseMsg(.private_seal));
    return .published;
}

/// Notary's answer to a seal. The ciphertext, or a refusal that leaves the list
/// exactly as it was.
pub fn handlePrivateSeal(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    if (!private_lists.g_private_seal.active) return;
    // Only the ask this seal is waiting on.
    if (response.key != privateSealKey(private_lists.g_private_seal.ask_seq)) return;
    if (response.outcome != .ok or response.status != 200) {
        private_lists.clearPrivateSeal();
        setToast(model, "Keyholder could not seal that. Nothing was sent.");
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.CipherResult, gpa, response.body) catch {
        private_lists.clearPrivateSeal();
        setToast(model, "Keyholder could not seal that. Nothing was sent.");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.items.len == 0) {
        private_lists.clearPrivateSeal();
        setToast(model, "Keyholder could not seal that. Nothing was sent.");
        return;
    }
    finishPrivateBookmark(model, fx, parsed.value.items[0]);
}

/// The splice, once the ciphertext exists.
///
/// The record is read AGAIN here rather than carried from the press. A seal goes
/// through a keyholder and, on a bunker, through a person pressing approve, so
/// the list can have moved in between, and a splice built against a record that
/// is no longer current is what the read-before-write rule exists to stop.
pub fn finishPrivateBookmark(model: *Model, fx: *Effects, ciphertext: []const u8) void {
    const seal = private_lists.g_private_seal;
    private_lists.g_private_seal = .{};
    // The plaintext is wiped however this ends; it is seeded below first if the
    // splice goes out.
    defer private_lists.dropSealPlaintext();
    if (!seal.active) return;
    // Sealed for the account that pressed, and published only as that account.
    const me = activePubkey() orelse return;
    if (!std.mem.eql(u8, &me, &seal.account)) return;
    // Asked again here, because the press asked before the seal's round trip.
    // Notary signs one thing at a time, and a like pressed while this was being
    // sealed holds its one key: signing this too took the like's slot and its
    // undo, and the SDK refused this sign, so nothing was published.
    if (!signerReady()) {
        setToast(model, "Your signer is busy. Nothing was sent.");
        return;
    }
    // What came back is checked before it becomes the list's content. A
    // ciphertext of any other length than this plaintext seals to was cut or
    // mangled on the way, and publishing it would replace every private
    // bookmark with bytes nobody can open.
    if (!plausibleSeal(ciphertext, seal.plain_len)) {
        setToast(model, "That seal came back damaged. Nothing was sent.");
        return;
    }
    if (ownWriteUnstored(bookmark_list_kind)) {
        setToast(model, unstored_toast);
        return;
    }
    const gpa = std.heap.page_allocator;

    var previous: ?OwnProfile = null;
    if (ownWriteBase(gpa, bookmark_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);
    const base_tags: []const nostr.event.Tag = if (previous) |prev| prev.tags else &.{};
    const base_created_at: i64 = if (previous) |prev| prev.created_at else 0;
    // The ciphertext was sealed over the record held at the press. If another
    // has landed since (the real list, arriving late), it carries a private half
    // this seal never saw, and publishing would erase it.
    if (!sameRecord(previous, seal.base)) {
        setToast(model, "Your bookmarks just changed. Nothing was sent.");
        return;
    }
    if (previous == null and !own_lists.g_identity_minted_here and !takeFresh(.bookmarks)) {
        setToast(model, noListToast("bookmarks"));
        return;
    }

    // The PUBLIC half is carried forward whole and untouched. A private write
    // changes the content and nothing else.
    var tags = std.ArrayList(nostr.event.Tag).empty;
    var handed_off = false;
    defer if (!handed_off) {
        for (tags.items) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        tags.deinit(gpa);
    };
    for (base_tags) |tag| {
        const copy = gpa.alloc([]const u8, tag.len) catch return;
        for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return;
        tags.append(gpa, copy) catch return;
    }
    const owned_tags = tags.toOwnedSlice(gpa) catch return;
    handed_off = true;
    const content = gpa.dupe(u8, ciphertext) catch return;
    const created = @max(@max(nowSeconds(), ownRecordCreatedAt(bookmark_list_kind) + 1), base_created_at + 1);

    // The set moves now, so the row reads right immediately. The new ciphertext
    // has not been decrypted by anything yet, so the private side is taken from
    // the press rather than re-read: it is the one thing here that is known.
    var next: [max_bookmarks][32]u8 = undefined;
    var n = bookmarksFromTags(owned_tags, &next);
    if (seal.adding and n < next.len) {
        next[n] = seal.event_id;
        n += 1;
    }
    // Everything else already private, from the half that was readable before.
    if (previous) |prev| {
        var had: [max_bookmarks][32]u8 = undefined;
        const m = privateBookmarks(gpa, prev.json, &had);
        for (had[0..m]) |id| {
            if (n >= next.len) break;
            if (seal.adding and std.mem.eql(u8, &id, &seal.event_id)) continue;
            if (!seal.adding and std.mem.eql(u8, &id, &seal.event_id)) continue;
            var seen = false;
            for (next[0..n]) |have| {
                if (std.mem.eql(u8, &have, &id)) seen = true;
            }
            if (seen) continue;
            next[n] = id;
            n += 1;
        }
    }
    setBookmarks(next[0..n], created);

    // Said when it is published (see `notePrivateBookmarkPublished`), not when
    // it is handed to the signer.
    g_private_announce_adding = seal.adding;
    g_private_announce_account = me;
    g_private_announce_at.store(created, .release);
    // The half going out is open already: the plaintext it was sealed from is
    // here, so the reader never asks the signer to open what it just wrote, and
    // the half it replaces is free to give up its slot.
    private_lists.seedSealedHalf(.bookmarks, seal.ask_seq, ciphertext);
    signAndPublish(fx, gpa, created, bookmark_list_kind, owned_tags, content, false, .none, null);
}

/// The stamp of the private bookmark write out with the signer, and whether it
/// adds, so the reader is told it happened when it is published. The publish
/// can land on the bunker listener's thread, so the stamp is atomic, and the
/// other two are written before it.
var g_private_announce_at = std.atomic.Value(i64).init(0);
var g_private_announce_adding: bool = false;
var g_private_announce_account: [32]u8 = undefined;
/// 0 nothing to say, 1 bookmarked, 2 removed. Set where it is published, said
/// on the tick.
var g_private_announced = std.atomic.Value(u8).init(0);

/// A private bookmark whose sign failed is never published, so its stamp stayed
/// armed, and a later write of the list with the same stamp was announced as
/// bookmarked privately. Each new write of the list starts clean. Only after a
/// press passes its busy checks: one refused while an earlier private bookmark
/// is still signing must not silence that one.
fn forgetPrivateAnnounce() void {
    g_private_announce_at.store(0, .release);
}

/// The publish path's half: `ev` is going out, and if it is the private
/// bookmark write, the tick says so.
pub fn notePrivateBookmarkPublished(ev: nostr.event.Event) void {
    if (ev.kind != bookmark_list_kind) return;
    const at = g_private_announce_at.load(.acquire);
    if (at == 0 or at != ev.created_at) return;
    if (!std.mem.eql(u8, &ev.pubkey, &g_private_announce_account)) return;
    if (g_private_announce_at.cmpxchgStrong(at, 0, .acq_rel, .acquire) != null) return;
    g_private_announced.store(if (g_private_announce_adding) 1 else 2, .release);
}

/// The tick's half.
pub fn sayPrivateBookmarkPublished(model: *Model) void {
    switch (g_private_announced.swap(0, .acq_rel)) {
        1 => setToast(model, "Bookmarked privately"),
        2 => setToast(model, "Bookmark removed"),
        else => {},
    }
}
pub var g_test_sealed: [max_private_cipher_len]u8 = undefined;
pub var g_test_sealed_len: usize = 0;

/// The plaintext the last private bookmark press asked to have sealed.
var g_test_seal_plain: [max_private_plain_len]u8 = undefined;

var g_test_seal_plain_len: usize = 0;

pub fn lastSealPlaintextForTest() []const u8 {
    return g_test_seal_plain[0..g_test_seal_plain_len];
}

/// What the listener does with a bunker's `nip44_encrypt` answer.
pub fn parkSealAnswerForTest(result: []const u8) void {
    parkSealAnswer(result);
}
/// The private tag array a bookmark write should seal, as JSON.
///
/// Built from the CURRENT private half plus or minus the one entry the press is
/// about. Returns null when the half is present and could not be opened, which
/// is the same refusal the public path makes and for the same reason: an array
/// built without bytes this app could not read is an array missing everything
/// that was in them.
fn privateBookmarkPlaintext(gpa: std.mem.Allocator, base_content: []const u8, event_id: [32]u8, adding: bool) ?[]u8 {
    var hex: [64]u8 = undefined;
    hexLower(&hex, event_id);

    var tags = std.ArrayList([]const []const u8).empty;
    defer tags.deinit(gpa);
    var found = false;

    // The parsed tags can point into the plaintext, so it outlives them.
    var plain: ?[]u8 = null;
    defer if (plain) |p| freePrivatePlain(gpa, p);
    var parsed: ?std.json.Parsed([]const []const []const u8) = null;
    defer if (parsed) |p| p.deinit();
    if (base_content.len > 0) {
        plain = privateHalfOpened(gpa, .bookmarks, base_content) orelse return null;
        parsed = std.json.parseFromSlice([]const []const []const u8, gpa, plain.?, .{}) catch return null;
        for (parsed.?.value) |tag| {
            if (tag.len >= 2 and std.mem.eql(u8, tag[0], "e") and hexEqlIgnoreCase(tag[1], &hex)) {
                found = true;
                if (!adding) continue;
            }
            tags.append(gpa, tag) catch return null;
        }
    }
    if (adding and found) return null; // Already private. Nothing to seal.
    if (!adding and !found) return null; // Not private. Nothing to seal.
    const added = [_][]const u8{ "e", &hex };
    if (adding) tags.append(gpa, &added) catch return null;
    // Serialized by the JSON writer, not by hand. Every field is carried as it
    // was, and a field from another client can hold anything a JSON string can:
    // a newline, a tab, a control byte. Escaping only `"` and `\` sealed those
    // raw, which is invalid JSON, and then every client found the whole private
    // half unreadable.
    return std.json.Stringify.valueAlloc(gpa, tags.items, .{}) catch null;
}

/// The keyholder a test has, for the seal path.
pub fn sealPrivateBookmarkForTest(gpa: std.mem.Allocator, plaintext: []const u8) void {
    const secret = feed_state.g_test_secret orelse {
        private_lists.clearPrivateSeal();
        return;
    };
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        private_lists.clearPrivateSeal();
        return;
    };
    // A test binary has no runtime io, so it makes its own. The seal has to be
    // real: the point of this path is that what gets published decrypts back.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = main.g_io orelse threaded.io();
    const sealed = nostr.nip44.encrypt(gpa, io, signer, kp.secret_key, kp.public_key, plaintext) catch {
        private_lists.clearPrivateSeal();
        return;
    };
    defer gpa.free(sealed);
    if (sealed.len > g_test_sealed.len) {
        private_lists.clearPrivateSeal();
        return;
    }
    g_test_sealed_len = sealed.len;
    @memcpy(g_test_sealed[0..sealed.len], sealed);
}

pub fn lastSealedForTest() []const u8 {
    return g_test_sealed[0..g_test_sealed_len];
}

pub fn finishPrivateBookmarkForTest(model: *Model, fx: *Effects) void {
    finishPrivateBookmark(model, fx, g_test_sealed[0..g_test_sealed_len]);
}

pub fn writePrivateBookmarkForTest(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    return writePrivateBookmark(fx, event_id, adding);
}

pub fn writeBookmarkForTest(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    return writeBookmark(fx, event_id, adding);
}

pub fn loadBookmarksFromStoreForTest() void {
    loadBookmarksFromStore();
}

pub fn forgetBookmarksForTest() void {
    forgetBookmarks();
}
pub fn sayBookmarkWriteForTest(model: *Model, outcome: BookmarkWrite, adding: bool) void {
    sayBookmarkWrite(model, outcome, adding);
}

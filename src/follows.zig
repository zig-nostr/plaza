//! The contact list: who the reader follows, the home scope, follow writes, and undo.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const own_lists = @import("own_lists.zig");
const relay_list = @import("relay_list.zig");
const routing = @import("routing.zig");
const mutes = @import("mutes.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const plazaIngestFrom = main.plazaIngestFrom;
const plazaIngest = main.plazaIngest;
const putBackRefusedReply = main.putBackRefusedReply;
const Effects = main.Effects;
const Model = main.Model;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
const blossom_list_kind = main.blossom_list_kind;
const clearRepostedByMe = main.clearRepostedByMe;
const dupeEventForPublish = main.dupeEventForPublish;
const dupeTags = main.dupeTags;
const feed_request_limit = main.feed_request_limit;
const forgetFresh = main.forgetFresh;
const forgetLike = main.forgetLike;
const forgetOwnListMemo = main.forgetOwnListMemo;
const freePublishedEvent = main.freePublishedEvent;
const freeOwnProfile = main.freeOwnProfile;
const generic_repost_kind = main.generic_repost_kind;
const haveOwnContactList = main.haveOwnContactList;
const hexLower = main.hexLower;
const invalidateFeed = main.invalidateFeed;
const keepReplyDraft = main.keepReplyDraft;
const lockMutes = main.lockMutes;
const noHistoryKnown = main.noHistoryKnown;
const nowSeconds = main.nowSeconds;
const ownRecordCreatedAt = main.ownRecordCreatedAt;
const ownRecordJson = main.ownRecordJson;
const relay_list_kind = main.relay_list_kind;
const rememberLike = main.rememberLike;
const repost_kind = main.repost_kind;
const resetFeedEnd = main.resetFeedEnd;
const saveRelays = main.saveRelays;
const setMutes = main.setMutes;
const setRelayListStamp = main.setRelayListStamp;
const setToast = main.setToast;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const starter_pack = main.starter_pack;
const takeFresh = main.takeFresh;
const unlockMutes = main.unlockMutes;

/// NIP-02's kind. A contact list is replaceable: publishing one replaces who
/// this reader follows, everywhere, at once.
pub const contact_list_kind: u16 = 3;

/// NIP-51's mute list. Public entries are `p` tags; private ones live in the
/// content, encrypted to yourself, and are read separately (see `privateMutes`).
pub const mute_list_kind: u16 = 10000;
/// NIP-51's bookmark list. Registered in `isOwnList` so `capturePrevious` and
/// `keepReplaced` hold a backup ring for it, and in `self_filter_kinds` so this
/// reader's own arrives on the same one-author subscription as their kind:0 and
/// their relay list. Both matter before the button does anything: without the
/// first a bad splice is unrecoverable, and without the second a fresh machine
/// would write over a list it had never read.
pub const bookmark_list_kind: u16 = 10003;
/// How many bookmarks are held in memory. NIP-51 sets no ceiling; this is what
/// the screen can show and what a splice can carry without the tag array
/// growing without bound.
pub const max_bookmarks = 512;

/// How many muted accounts are held. Far past any real list: muting is a thing
/// people do a handful of times, not two thousand.
pub const max_mutes = 512;

/// How many follows are TRACKED, which is not how many the feed reads.
///
/// These are two different numbers and conflating them was a real bug: the feed
/// asks the store for notes by author, and the store opens one cursor per
/// author, so reading is what has to be capped. Membership is not: "do I follow
/// this person" has to be right for every name on the list, or the Follow button
/// offers to add somebody who is already there and the press does nothing.
const max_follows_tracked = 2048;
/// How many the FEED reads from: all of them.
///
/// This was 128 for two reasons and neither survived measurement.
///
/// The store cost was real and is fixed. Asking for one kind by many authors
/// used to be answered from the author index, so it walked everything those
/// people had ever written and discarded the wrong kinds after decoding them;
/// nostr v0.3.8 indexes the pair. A feed rebuild across 2048 follows now
/// measures inside one frame at 60Hz, and the curve that made 128 look like a
/// cliff turned out to have been recorded in a Debug build.
///
/// The REQ payload is real and is handled: a filter naming a few thousand
/// authors is past what several relays accept, so the subscription splits them
/// across filters of `follow_chunk` and sends the lot in ONE REQ, which is what
/// Damus does and what strfry's own limit is written against. A relay answers
/// every filter in a REQ, so this is a payload split, not a narrower question.
pub const max_follows = max_follows_tracked;

/// Authors per filter in the feed subscription.
///
/// strfry refuses a filter whose field items exceed 65535 bytes, which is 2047
/// hex pubkeys, and it is not the only relay with a ceiling. Damus splits at
/// 500 and has had years of contact with relays nobody here runs. Taking the
/// number that is already proven against the wild rather than the largest one
/// that fits the one implementation whose source states a limit.
pub const follow_chunk = 500;

/// How many chunks the author set can need, rounded up, with the reader's own
/// key counted. Sizes the filter buffer, so a follow list that grows past it is
/// a compile-time question rather than a truncated subscription.
const max_follows_divided = (max_follows + 1 + follow_chunk - 1) / follow_chunk;

/// How many filters the feed subscription can need: two per chunk, plus one per
/// kind of the reader's own records.
pub const max_feed_filters = 2 * (max_follows_divided + 1) + self_filter_kinds.len;

/// The feed's notes.
/// How many kinds the feed may read in one rebuild.
///
/// The store read opens one query per kind (see `rebuildNotesFromStore` for
/// why), and they are held open together to be merged, so this bounds both the
/// stack array and how many cursors exist at once.
pub const feed_kind_cap: usize = 4;

pub const feed_filter_kinds = [_]u16{ 1, repost_kind, generic_repost_kind };
/// What the feed needs about the people in it: kind:0 is who they are, 10002 is
/// where they are.
///
/// NOT kind:3. Somebody else's contact list is asked for in exactly one place,
/// the profile card's follow counts, and the worker that opens a profile
/// already fetches that person's kind:0 and kind:3 on its own. Asking for it
/// here asked every relay for the contact list of all two thousand follows at
/// dial: a list of two thousand `p` tags is well over a hundred kilobytes, so
/// this was megabytes per relay, per connection, to answer a question nobody
/// had asked, about people whose profile the reader may never open.
const profile_filter_kinds = [_]u16{ 0, relay_list_kind };

/// What the feed needs about the READER, which is the above plus their own
/// contact list.
///
/// Their own kind:3 is not optional and not a nicety: nothing may write over a
/// replaceable record that has not been read back first, and the follow list is
/// the one where getting that wrong empties somebody's account. It is one
/// author and three records, so it costs nothing to ask for separately, which
/// is the entire reason the bulk filter above can stop asking for it.
const self_filter_kinds = [_]u16{ 0, relay_list_kind, contact_list_kind, mute_list_kind, bookmark_list_kind, blossom_list_kind };

/// Whether one relay's answer about the reader's own records can be read as
/// "that is all I have".
///
/// An EOSE says the relay sent everything it holds. It does not say Plaza kept
/// it. One of the reader's own records that arrived and could not be stored, or
/// did not verify, or a message that could not be read at all, is a record
/// that may be the very list this relay holds. Counting the EOSE then reads a
/// list that arrived as a list that does not exist, and the new-list question
/// replaces it.
pub const SelfRead = struct {
    unread: bool = false,

    /// An event on the question's subscription, and whether it made it into
    /// the store. Only the reader's own records of the kinds asked about count.
    pub fn sawEvent(self: *SelfRead, ev: nostr.event.Event, me: [32]u8, stored: bool) void {
        if (stored) return;
        if (!std.mem.eql(u8, &ev.pubkey, &me)) return;
        if (std.mem.indexOfScalar(u16, &self_filter_kinds, ev.kind) == null) return;
        self.unread = true;
    }

    /// A message that arrived and could not be read. Whose it was cannot be
    /// known, so it may have been the reader's.
    pub fn sawUnreadable(self: *SelfRead) void {
        self.unread = true;
    }

    /// Whether this relay's end of stored events answers the question.
    pub fn eoseAnswers(self: SelfRead) bool {
        return !self.unread;
    }
};

pub const SelfReadForTest = SelfRead;

/// The reader's own records that were published and did not reach the store,
/// by kind, with the stamp that went out.
///
/// Every write to one of these splices onto the record in the store. When a
/// write is signed and published but the store refuses it, the store still
/// holds the record before it, and the next write would splice onto that and
/// publish a list without the change that is already out on the relays. So
/// the kind is held until a record at least that new is stored, normally the
/// same event coming back from a relay, and writes to it are refused with a
/// reason until then.
var g_unstored_for: ?[32]u8 = null;

/// Cleared by whichever thread stores the record, so atomic.
var g_unstored_at: [self_filter_kinds.len]std.atomic.Value(i64) = @splat(std.atomic.Value(i64).init(0));

/// A copy of each held record, so the tick can put it in the store itself
/// rather than wait on a relay to send it back, which may never happen: with
/// nothing retrying, a store that refused once kept that kind of write refused
/// for the session. Owned, and touched on the UI thread only.
var g_unstored_copy: [self_filter_kinds.len]?nostr.event.Event = @splat(null);
var g_unstored_tries: [self_filter_kinds.len]u8 = @splat(0);
var g_unstored_retry_at: [self_filter_kinds.len]i64 = @splat(0);

/// How often a held record is offered to the store again, and how many times
/// before the hold is let go.
const unstored_retry_s: i64 = 2;
const unstored_max_tries: u8 = 15;

/// What the reader is told when the hold is let go without the record stored.
pub const unstored_lost_toast = "Published, but this machine could not keep it.";

fn dropUnstoredCopy(i: usize) void {
    if (g_unstored_copy[i]) |copy| freePublishedEvent(copy);
    g_unstored_copy[i] = null;
    g_unstored_tries[i] = 0;
    g_unstored_retry_at[i] = 0;
}

fn selfKindIndex(kind: u16) ?usize {
    return std.mem.indexOfScalar(u16, &self_filter_kinds, kind);
}

/// Records that the reader's own `ev` was published without being stored.
pub fn noteOwnWriteUnstored(ev: nostr.event.Event) void {
    const i = selfKindIndex(ev.kind) orelse return;
    const me = activePubkey() orelse return;
    if (!std.mem.eql(u8, &me, &ev.pubkey)) return;
    if (g_unstored_for) |who| {
        if (!std.mem.eql(u8, &who, &me)) forgetOwnWritesUnstored();
    }
    g_unstored_for = me;
    _ = g_unstored_at[i].fetchMax(ev.created_at, .acq_rel);
    // The newest record of the kind is the one to store. One that cannot be
    // copied still holds, and the tick lets it go after the same tries.
    if (g_unstored_copy[i]) |held| {
        if (held.created_at > ev.created_at) return;
    }
    dropUnstoredCopy(i);
    g_unstored_copy[i] = dupeEventForPublish(ev);
}

/// A record of the reader's own, of `kind` and stamped `created_at`, is in the
/// store now.
pub fn noteOwnRecordStored(pubkey: [32]u8, kind: u16, created_at: i64) void {
    const i = selfKindIndex(kind) orelse return;
    const who = g_unstored_for orelse return;
    if (!std.mem.eql(u8, &who, &pubkey)) return;
    const held = g_unstored_at[i].load(.acquire);
    if (held != 0 and created_at >= held) _ = g_unstored_at[i].cmpxchgStrong(held, 0, .acq_rel, .acquire);
}

/// The tick's half of the hold: each held record is offered to the store again
/// every few seconds, and the hold goes as soon as one at least as new is in.
/// After `unstored_max_tries` the hold is let go and the reader is told the
/// change went out but is not on this machine. Writes of that kind then work
/// again, on the older record the store still has.
pub fn retryUnstoredOwnWrites(model: *Model, now: i64) void {
    const gpa = std.heap.page_allocator;
    for (&g_unstored_at, 0..) |*at, i| {
        if (at.load(.acquire) == 0) {
            // Read back, by a relay or by an earlier try.
            if (g_unstored_copy[i] != null or g_unstored_tries[i] != 0) dropUnstoredCopy(i);
            continue;
        }
        if (now < g_unstored_retry_at[i]) continue;
        if (g_unstored_copy[i]) |copy| _ = plazaIngest(gpa, copy, .{}) catch {};
        if (at.load(.acquire) == 0) {
            dropUnstoredCopy(i);
            continue;
        }
        g_unstored_tries[i] += 1;
        if (g_unstored_tries[i] >= unstored_max_tries) {
            at.store(0, .release);
            dropUnstoredCopy(i);
            setToast(model, unstored_lost_toast);
            continue;
        }
        g_unstored_retry_at[i] = now + unstored_retry_s;
    }
}

/// Whether a write of `kind` must wait for a published record to be read back.
pub fn ownWriteUnstored(kind: u16) bool {
    const i = selfKindIndex(kind) orelse return false;
    const me = activePubkey() orelse return false;
    const who = g_unstored_for orelse return false;
    if (!std.mem.eql(u8, &who, &me)) return false;
    return g_unstored_at[i].load(.acquire) != 0;
}

fn forgetOwnWritesUnstored() void {
    g_unstored_for = null;
    for (&g_unstored_at, 0..) |*at, i| {
        at.store(0, .release);
        dropUnstoredCopy(i);
    }
}

pub fn ownWriteUnstoredForTest(kind: u16) bool {
    return ownWriteUnstored(kind);
}

/// Makes the next store ingests fail, the way a full disk or a store error does.
pub var g_test_fail_ingest = false;

pub fn failIngestForTest(fail: bool) void {
    g_test_fail_ingest = fail;
}

/// The toast for a write held back by `ownWriteUnstored`.
pub const unstored_toast = "Last change not read back yet. Try again soon.";

/// One event on the feed subscription, verified and stored, and noted against
/// `self_read` when it is one of the reader's own records that was not. Null
/// when it was not stored.
pub fn ingestFeedEvent(gpa: std.mem.Allocator, signer: nostr.keys.Signer, url: []const u8, ev: nostr.event.Event, asked_about: ?[32]u8, self_read: *SelfRead) ?nostr.store.IngestResult {
    const result: ?nostr.store.IngestResult = plazaIngestFrom(gpa, ev, .{ .verify_with = signer }, url) catch null;
    const stored = if (result) |r| r != .invalid else false;
    if (asked_about) |me| self_read.sawEvent(ev, me, stored);
    return if (stored) result else null;
}

pub fn ingestFeedEventForTest(gpa: std.mem.Allocator, signer: nostr.keys.Signer, ev: nostr.event.Event, asked_about: ?[32]u8, self_read: *SelfRead) bool {
    return ingestFeedEvent(gpa, signer, "wss://relay.example", ev, asked_about, self_read) != null;
}

/// Splits `authors` across filters small enough for a relay to accept, two per
/// chunk, and returns the slice of `out` that was filled.
///
/// One REQ carries all of them. A relay answers every filter in a REQ, so this
/// asks exactly the question one enormous filter would have asked, in an
/// envelope that arrives. The per-chunk limit is NOT divided: each chunk names
/// different people, and splitting the limit would starve whoever landed in the
/// last one.
pub fn buildFeedFilters(authors: []const [32]u8, self: ?*const [1][32]u8, since: ?i64, out: []nostr.filter.Filter) []nostr.filter.Filter {
    var len: usize = 0;
    var start: usize = 0;
    while (start < authors.len) : (start += follow_chunk) {
        if (len + 2 > out.len) break;
        const chunk = authors[start..@min(start + follow_chunk, authors.len)];
        // The notes carry `since`; the metadata filter deliberately does not.
        // A profile or relay list edited while the app was closed has an older
        // `created_at` than the newest note held, so bounding that filter would
        // hide exactly the update the app most needs.
        out[len] = .{ .authors = chunk, .kinds = &feed_filter_kinds, .since = since, .limit = feed_request_limit };
        // One record per author per kind, which is what the filter can actually
        // return: these are all replaceable, so a relay holds at most one of
        // each. The old limit was `profile_cap`, a UI cache size, which for a
        // 500-author chunk across three kinds asked for 1500 records and
        // permitted 160. A relay obeying the limit answered a third of a chunk
        // and the rest of those authors stayed nameless until something else
        // happened to ask for them.
        out[len + 1] = .{
            .authors = chunk,
            .kinds = &profile_filter_kinds,
            .limit = @intCast(chunk.len * profile_filter_kinds.len),
        };
        len += 2;
    }
    // The reader's own records, asked for on their own rather than folded into a
    // five-hundred-author filter, and one filter per kind with a limit of one.
    //
    // They were one filter with a limit of five. A relay that keeps older
    // versions of a replaceable record (some do) could fill those five with old
    // contact lists and finish without ever sending the mute list, and "this
    // relay finished without one" is what the fresh-list question rests on.
    //
    // The author is the caller's: a filter borrows its authors, and the shared
    // module-level copy this used to write was written by every relay thread
    // at once, so one thread could send the account another had just put there.
    if (self) |pk| {
        for (0..self_filter_kinds.len) |k| {
            if (len >= out.len) break;
            out[len] = .{
                .authors = pk,
                .kinds = self_filter_kinds[k .. k + 1],
                .limit = 1,
            };
            len += 1;
        }
    }
    return out[0..len];
}

var g_follows: [max_follows_tracked][32]u8 = undefined;
var g_follow_count: usize = 0;
/// Whose list is in `g_follows`, for the same reason the relay pool records it:
/// a list left behind by one account must never be read as another's.
var g_follow_owner: ?[32]u8 = null;
/// When the list in memory was signed, so an older one arriving from a slower
/// relay does not overwrite a newer one.
var g_follow_created_at: i64 = 0;
/// Bumped whenever the set changes, or the identity does. The ingest threads
/// snapshot it at dial and re-subscribe when it moves, so a follow shows new
/// notes, and a sign-in asks for the new account's own records, without waiting
/// for a socket to drop.
pub var g_follow_gen = std.atomic.Value(u32).init(0);

/// Bumped only when WHO IS SIGNED IN changes, never when the follow list moves.
///
/// The inbox REQ hung off the follow generation, so following one person
/// re-issued `plaza-inbox` on every read relay with a 200-event backfill. At
/// eight relays that is up to 1600 events re-delivered and re-verified for a
/// change the inbox does not depend on: its filter names one pubkey, the
/// reader's own. Amethyst keeps these on separate watchers for the same reason.
var g_identity_gen = std.atomic.Value(u32).init(0);

pub fn identityGeneration() u32 {
    return g_identity_gen.load(.acquire);
}

pub fn bumpIdentityGeneration() void {
    _ = g_identity_gen.fetchAdd(1, .monotonic);
}
/// Guards the table. The UI thread writes it; ingest threads read it to build
/// their filters.
var g_follow_lock = std.atomic.Value(bool).init(false);

fn lockFollows() void {
    while (g_follow_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn unlockFollows() void {
    g_follow_lock.store(false, .release);
}

/// Whether the list in memory is THIS account's.
fn followsAreOwned() bool {
    const pk = activePubkey() orelse return false;
    const owner = g_follow_owner orelse return false;
    return std.mem.eql(u8, &owner, &pk);
}
/// Which of the two feeds Home is reading.
///
/// A key made here starts on the pack and STAYS there until the reader says
/// otherwise. Their own list on the first day is the one or two people they have
/// pressed Follow on, and a feed that narrow is not a feed: dropping them into
/// it the moment they follow somebody takes away everything they were reading as
/// payment for one press. An imported key defaults to `following`, because they
/// arrived with a list and it is the reason they signed in.
pub const HomeScope = enum { starter_pack, following };
pub var g_home_scope: HomeScope = .following;

/// Whether Home is reading the pack right now.
///
/// Owning no list of their own is not a CHOICE, so it outranks the setting: the
/// pack is the only feed there is until they have followed somebody.
pub fn homeReadsPack() bool {
    if (!followsAreOwned()) return true;
    return g_home_scope == .starter_pack;
}

/// Whether the reader has a list of their own to switch TO. Until they do, the
/// scope is a label rather than a switcher, which is the same rule the place
/// header follows.
pub fn homeScopeSwitchable() bool {
    return followsAreOwned();
}

pub fn homeScope() HomeScope {
    return g_home_scope;
}
pub fn followTotalOwned() usize {
    return if (followsAreOwned()) g_follow_count else 0;
}

/// Moves Home between the two feeds. Everything scoped to the author set is
/// stale afterwards, exactly as it is when the follow list itself changes, so
/// this says so the same way `setFollows` does.
pub fn setHomeScope(next: HomeScope) void {
    if (g_home_scope == next) return;
    g_home_scope = next;
    _ = g_follow_gen.fetchAdd(1, .monotonic);
    resetFeedEnd();
    invalidateFeed();
    routing.g_relay_ranks_dirty.store(true, .release);
}

/// Who the FEED reads: a bounded slice of the follow list, or the starter pack.
pub fn followSet() []const [32]u8 {
    if (homeReadsPack()) return &starter_pack;
    return g_follows[0..@min(g_follow_count, max_follows)];
}

/// How many accounts this reader follows, all of them, whether or not the feed
/// reads them all.
pub fn followTotal() usize {
    if (homeReadsPack()) return starter_pack.len;
    return g_follow_count;
}

/// Copies the feed's author set for a caller on another thread. `followSet`
/// hands back a slice of a table the UI thread rewrites, and an ingest thread
/// holding one across a dial is the same hazard the relay pool already learned.
pub fn followSnapshot(out: *[max_follows][32]u8) usize {
    lockFollows();
    defer unlockFollows();
    if (homeReadsPack()) {
        const n = @min(starter_pack.len, out.len);
        @memcpy(out[0..n], starter_pack[0..n]);
        return n;
    }
    const n = @min(g_follow_count, out.len);
    @memcpy(out[0..n], g_follows[0..n]);
    return n;
}

pub fn followGeneration() u32 {
    return g_follow_gen.load(.acquire);
}

/// Whether `pubkey` is inside the graph this reader is READING: their own follow
/// list once it is known, and the starter pack until then.
///
/// This is the ranking question, not the membership one. The inbox uses it to
/// tell somebody the reader reads from a stranger, and a thread uses it to split
/// replies into the conversation and the crowd outside it. For those, the pack
/// IS the graph while the pack is what fills the feed.
///
/// Not the same question as `isFollowedByMe`, and the difference is the whole
/// point of having both. Checked against EVERY follow, not the slice the feed
/// reads.
pub fn isInReadGraph(pubkey: [32]u8) bool {
    // A guest reads the pack, but the app has nothing to rank for them: no
    // inbox, no own-graph split.
    if (activePubkey() == null) return false;
    return inFollowedSet(pubkey);
}

/// Whether `pubkey` is in the set the feed is built from: the reader's whole
/// contact list, or the starter pack while the pack is what they are reading.
///
/// EVERY follow, never `followSet()`. That one is capped at `max_follows`
/// because it is the feed's author set and the feed pays a relay filter entry
/// and a store cursor per author, so being a slice is the point of it. Asking a
/// membership question of that slice told a reader with three hundred follows
/// that follows 129 and up were strangers, and a new follow is APPENDED, so the
/// people they had followed most recently were the ones most likely to be
/// misfiled.
fn inFollowedSet(pubkey: [32]u8) bool {
    lockFollows();
    defer unlockFollows();
    if (!followsAreOwned()) {
        for (starter_pack) |f| {
            if (std.mem.eql(u8, &f, &pubkey)) return true;
        }
        return false;
    }
    for (g_follows[0..g_follow_count]) |f| {
        if (std.mem.eql(u8, &f, &pubkey)) return true;
    }
    return false;
}

/// Whether this reader has actually FOLLOWED `pubkey`: their own kind:3 says so.
///
/// The starter pack is not a follow list. It is what the app reads on a new
/// account's behalf until that account has one, nothing is ever published to say
/// otherwise, and the feed's own header says as much ("Starter pack · hand-picked",
/// against "Following · yours"). But every control that asks about following
/// asked `isFollowing`, which counted the pack: a reader who had just made a key
/// was told they followed nine strangers, offered "Unfollow" on each, and got
/// nothing when they pressed it, because the write path correctly refuses to
/// remove somebody who is not on a list.
///
/// So the controls ask this instead. It says Follow for the pack, which is true,
/// and which is how a starter pack is supposed to turn into a list of your own.
pub fn isFollowedByMe(pubkey: [32]u8) bool {
    if (activePubkey() == null) return false;
    lockFollows();
    defer unlockFollows();
    if (!followsAreOwned()) return false;
    for (g_follows[0..g_follow_count]) |f| {
        if (std.mem.eql(u8, &f, &pubkey)) return true;
    }
    return false;
}

/// Installs a follow set as this account's. Returns whether anything changed.
pub fn setFollows(list: []const [32]u8, created_at: i64) bool {
    const pk = activePubkey() orelse return false;
    lockFollows();
    const same = blk: {
        if (!followsAreOwned()) break :blk false;
        if (g_follow_count != @min(list.len, max_follows_tracked)) break :blk false;
        for (list[0..@min(list.len, max_follows_tracked)], 0..) |f, i| {
            if (!std.mem.eql(u8, &f, &g_follows[i])) break :blk false;
        }
        break :blk true;
    };
    if (same) {
        unlockFollows();
        return false;
    }
    const n = @min(list.len, max_follows_tracked);
    @memcpy(g_follows[0..n], list[0..n]);
    g_follow_count = n;
    g_follow_owner = pk;
    g_follow_created_at = created_at;
    unlockFollows();
    // Everything scoped to the follow set is now stale: the feed's query, the
    // relay filters, the names being fetched, and which relays are worth
    // suggesting (the ranking is a count of THESE people).
    _ = g_follow_gen.fetchAdd(1, .monotonic);
    // The author set moved, so whatever was concluded about the end of their
    // history was concluded about a different question.
    resetFeedEnd();
    invalidateFeed();
    routing.g_relay_ranks_dirty.store(true, .release);
    return true;
}

/// Forgets whose list this is. Called on any identity change, so one account's
/// follows are never read, published, or shown as another's.
pub fn forgetFollows() void {
    lockFollows();
    g_follow_owner = null;
    g_follow_count = 0;
    g_follow_created_at = 0;
    unlockFollows();
    // A list signed but not yet seen belongs to the account that signed it. Left
    // behind, it would be the base the NEXT account's first follow builds on.
    clearPendingFollowBase();
    forgetOwnListMemo();
    // A record of the previous account's held back is nothing to this one.
    forgetOwnWritesUnstored();
    // And how long it has been waiting on this account's lists: the next one
    // starts its own clock.
    own_lists.g_own_lists_since_for = null;
    forgetFresh();
    // The open subscriptions were built for the previous identity and are now
    // asking the wrong question. Without this a sign-in never gets its own
    // records requested on an already-open socket, and following stays disabled
    // for the whole session.
    _ = g_follow_gen.fetchAdd(1, .monotonic);
    // The author set moved, so whatever was concluded about the end of their
    // history was concluded about a different question.
    resetFeedEnd();
    // And the routing is redone, so the connections opened to where the
    // previous account's follows write stop asking about those people.
    routing.g_relay_ranks_dirty.store(true, .release);
    // And this is the one thing the inbox DOES depend on: whose notifications
    // these are. It is the only place that bumps it, which is the point.
    bumpIdentityGeneration();
}

/// Seeds the follow set from the local store, at boot and at sign-in.
///
/// A local-first app that forgets who you follow every launch is not local
/// first. The store already holds the reader's newest kind:3 from last session,
/// so the feed is theirs from the first frame rather than after a round trip.
pub fn loadFollowsFromStore() void {
    const gpa = std.heap.page_allocator;
    const own = ownRecordJson(gpa, contact_list_kind) orelse return;
    defer freeOwnProfile(gpa, own);
    var list: [max_follows_tracked][32]u8 = undefined;
    const n = followsFromTags(own.tags, &list);
    if (n == 0) return;
    _ = setFollows(list[0..n], own.created_at);
}

/// Whether a follow write is safe to make right now.
///
/// The hard rule of this feature, and the one that took three attempts. A
/// contact list is REPLACEABLE: publishing one replaces who this reader follows,
/// on every relay, at once.
///
/// Attempt one gated on "some relay sent EOSE". Wrong, and dangerously so: EOSE
/// means "that is all *I* have", never "you have none". Attempt two required
/// EVERY readable relay to answer. Better, and still wrong, because it treats
/// relay silence as evidence: on a cold import the relays being asked are this
/// app's bootstrap five, chosen before the reader's own kind:10002 has been
/// read, so they can all answer cleanly while the real list sits on relays this
/// app has never dialed. Negative evidence is only ever as strong as the relay
/// set, and the relay set is the thing that is unresolved at exactly that
/// moment.
///
/// So the question is not "did the network answer" but "do we KNOW". Two ways:
///   - We HAVE their list. Splice onto it. Always safe, no relay condition, no
///     waiting: this is the branch that cannot destroy anything.
///   - The key was minted by this app, so it provably has no history. Creating
///     a list from nothing is safe with no relay condition either.
///
/// An IMPORTED identity gets neither. It has a past this app cannot see, and
/// nothing local can rule out a list of a thousand. The reader is told the app
/// is still looking rather than handed a button that would replace it.
/// (This is Damus's rule plus the explanation Damus does not give.)
pub fn canWriteFollows() bool {
    if (activePubkey() == null) return false;
    if (haveOwnContactList()) return true;
    return noHistoryKnown(.follows);
}
/// Follows or unfollows `pubkey`, as newest-known-list plus the change.
///
/// Everything the reader's existing kind:3 carries comes forward untouched: the
/// petnames and relay hints on other people's `p` tags, tag types this app does
/// not model, and the content blob, which on older clients is a relay map and on
/// none of them is ours to discard.
/// What a follow write DID, rather than whether it worked.
///
/// It was a bool, and two of the three callers discarded it. A refusal is a
/// legitimate outcome here and there are four different ones, each with
/// something worth saying: pressing Follow in the first seconds after opening
/// the app is refused because the account's own list has not arrived yet, and
/// what the reader saw was a button that did not move and no reason given.
pub const FollowWrite = enum {
    published,
    /// Already in the state asked for, or the reader themselves.
    nothing_to_do,
    /// A signature is already out. One key signs one thing at a time.
    signer_busy,
    /// This account's contact list has not been read back yet, and writing one
    /// over a list nobody has seen is the thing this app refuses everywhere.
    no_list_yet,
    /// The shrink guard: the write would have dropped more names than the press
    /// asked for.
    would_shrink,
    failed,
};

pub fn writeFollow(fx: *Effects, pubkey: [32]u8, following: bool) FollowWrite {
    // Not while a signature is already out. Everything below moves state before
    // it signs, and a rejected sign is silent, so pressing Follow during another
    // sign used to leave the follow set carrying a name that was never published.
    if (!signerReady()) return .signer_busy;
    // No `canWriteFollows()` here on purpose, though it is the same question.
    // It runs its own store query, and this function then ran a SECOND one for
    // the list itself: a transient failure between the two answered "yes they
    // have a list" and then "here is nothing", and nothing is the branch that
    // publishes nine names over eight hundred. The gate below is decided from
    // the one read this function actually uses. `canWriteFollows` stays as what
    // the button asks, where being approximate costs nothing.
    const me = activePubkey() orelse return .failed;
    // Following yourself is not a thing, and an app that lets you is confusing
    // about whose feed it is.
    if (std.mem.eql(u8, &me, &pubkey)) return .nothing_to_do;
    const gpa = std.heap.page_allocator;

    var previous: ?OwnProfile = null;
    if (ownRecordJson(gpa, contact_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);

    // A list this app signed moments ago and has not seen come back is newer
    // than anything in the store, so it is the base. Without this, two presses
    // inside one bunker round trip both build on the pre-press list and the
    // second undoes the first, on every relay, with both saying "Following".
    var base_tags: []const nostr.event.Tag = if (previous) |prev| prev.tags else &.{};
    var base_content: []const u8 = if (previous) |prev| prev.json else "";
    var have_base = previous != null;
    var base_created_at: i64 = if (previous) |prev| prev.created_at else 0;
    if (g_pending_follow_tags) |pending| {
        if (g_pending_follow_created_at > base_created_at) {
            base_tags = pending;
            base_content = g_pending_follow_content orelse "";
            base_created_at = g_pending_follow_created_at;
            have_base = true;
        }
    }

    // THE GATE, decided from the read above rather than from a second one.
    // `canWriteFollows` runs its own store query, so a transient failure between
    // the two turned "they have a list, splice onto it" into "they have none,
    // publish the nine names this app chose" over a real list. A key minted here
    // is the only case where having nothing is a fact rather than a read error.
    if (!have_base and !own_lists.g_identity_minted_here and !takeFresh(.follows)) return .no_list_yet;

    var tags = std.ArrayList(nostr.event.Tag).empty;
    // Freed on every path that does not hand it to the write seam. Two of those
    // paths are the ordinary "already following" and "not following" no-ops, so
    // leaking here would leak a whole contact list per idle press.
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

    if (have_base) {
        for (base_tags) |tag| {
            if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and hexEqlIgnoreCase(tag[1], &hex)) {
                found = true;
                // Unfollowing drops the tag; following keeps the one already
                // there, petname, relay hint and all.
                if (!following) continue;
            }
            const copy = gpa.alloc([]const u8, tag.len) catch return .failed;
            for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return .failed;
            tags.append(gpa, copy) catch return .failed;
        }
    }
    // No list of their own, and this app minted the key, so there provably is
    // none anywhere: the list starts EMPTY and gains exactly the person pressed.
    //
    // It used to start as the STARTER PACK, so that the feed they arrived
    // reading travelled with them to every other client. What that did on the
    // first press was publish nine accounts the reader never chose: one press,
    // nine follows, every face in the feed flipping to Following at once. The
    // pack is something to READ, and reading it is not a claim about anybody, so
    // it must not be signed on their behalf. Home goes on offering it as a feed
    // for as long as they want it (see `g_home_scope`), which is the half of
    // that idea worth keeping.
    //
    // The branch above is the dangerous one, and the gate before it is what
    // makes it safe: reaching it on a guess, or on a store read that merely
    // failed, would replace a real contact list with almost nothing.

    if (following) {
        // Already among the tags. What that MEANS depends on whose tags they
        // are, and reading it as "already followed" is what made Follow do
        // nothing on a new account's first screen.
        //
        // With a base, they are the reader's own list and there is nothing to
        // write. Without one, they are the STARTER PACK: `isFollowedByMe` says
        // false for everyone in it, because the pack is not a list the reader
        // owns, so the button correctly offers Follow. Returning here made that
        // press silent, and publishing is exactly what it should do: the pack
        // becomes their list, this person already in it. Until that happens the
        // reader has no list at all, so every later press on a pack member was
        // silent too.
        if (found) {
            return .nothing_to_do; // already on their list: nothing to write
        } else {
            const copy = gpa.alloc([]const u8, 2) catch return .failed;
            copy[0] = gpa.dupe(u8, "p") catch return .failed;
            copy[1] = gpa.dupe(u8, &hex) catch return .failed;
            tags.append(gpa, copy) catch return .failed;
        }
    } else if (!found) {
        return .nothing_to_do; // not followed: nothing to write
    }

    // THE SHRINK GUARD. No client in the ecosystem has one, and it is the
    // cheapest protection here: a follow adds one name and an unfollow removes
    // exactly one, so any write that drops more than that is a bug in this code,
    // a stale base, or a rebase onto somebody else's truncation. It refuses
    // rather than publishing, because the alternative is losing follows to a
    // mistake this app made.
    // Measured against the base the write actually used, which for a signer that
    // has not answered yet is the list this app signed rather than the older one
    // still in the store.
    if (have_base) {
        if (!shrinkAllowed(countPeople(base_tags), countPeople(tags.items), following)) return .would_shrink;
    }

    const owned_tags = tags.toOwnedSlice(gpa) catch return .failed;
    handed_off = true;
    // The content is carried forward verbatim. On older clients it is a relay
    // map, and emptying it would delete a record this app does not even read.
    const content = gpa.dupe(u8, base_content) catch return .failed;
    // Past the base too, not just past the store: a second press inside one
    // signer round trip would otherwise stamp equal to the first, and NIP-01
    // breaks that tie on the id, which is a coin flip over the reader's follows.
    const created = @max(@max(nowSeconds(), ownRecordCreatedAt(contact_list_kind) + 1), base_created_at + 1);

    // The live list moves first, so the feed reflects the press immediately.
    // Tracked in full, not capped: membership has to be right for every name or
    // the next press on somebody past the cap does nothing.
    var next: [max_follows_tracked][32]u8 = undefined;
    const n = followsFromTags(owned_tags, &next);
    // Read BEFORE the list moves: `setFollows` overwrites it, so taking it at
    // the call below would hand back the stamp this press just wrote.
    const undo_stamp = g_follow_created_at;
    _ = setFollows(next[0..n], created);

    // Remembered as the base for the next press BEFORE the write seam is handed
    // the originals, since it owns them from here and the remote path frees them.
    setPendingFollowBase(owned_tags, content, created);
    signAndPublish(fx, gpa, created, contact_list_kind, owned_tags, content, false, .{ .follow = .{ .pubkey = pubkey, .added = following, .created_at = undo_stamp } }, null);
    return .published;
}

/// How many DISTINCT people a tag set names. Distinct on purpose: some clients
/// emit the same person twice, and an unfollow that removes both duplicates has
/// removed one person, not two.
pub fn countPeople(tags: []const nostr.event.Tag) usize {
    var seen: [max_follows_tracked][32]u8 = undefined;
    var n: usize = 0;
    for (tags) |tag| {
        if (n >= seen.len) break;
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "p")) continue;
        if (tag[1].len != 64) continue;
        var pk: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk, tag[1]) catch continue;
        var dup = false;
        for (seen[0..n]) |had| {
            if (std.mem.eql(u8, &had, &pk)) dup = true;
        }
        if (dup) continue;
        seen[n] = pk;
        n += 1;
    }
    return n;
}

// The contact list this app has SIGNED but has not seen come back yet.
//
// `writeFollow` takes its base from the store, and for a bunker or a Notary key
// the store is not written until the signer answers: one to five seconds, longer
// with an approval prompt in front of a human. Two follow presses inside that
// window both read the SAME pre-press list, so the second one publishes a list
// that does not contain the first, at an equal or newer stamp, and the first
// follow is undone on every relay. The reader saw both say "Following".
//
// So a signed list becomes the base for the next write until the real one
// arrives. It is a full copy of the tags, not the follow set: the follow set is
// pubkeys, and rebasing on it would drop every petname, relay hint and tag type
// this app does not model, which is the loss the splice exists to prevent.
pub var g_pending_follow_tags: ?[]const nostr.event.Tag = null;
var g_pending_follow_content: ?[]u8 = null;
var g_pending_follow_created_at: i64 = 0;

/// Frees the pending base. THE one place that does, so its lifetime is a rule
/// rather than a habit.
pub fn clearPendingFollowBase() void {
    const gpa = std.heap.page_allocator;
    if (g_pending_follow_tags) |tags| {
        for (tags) |t| {
            for (t) |field| gpa.free(field);
            gpa.free(t);
        }
        gpa.free(tags);
    }
    if (g_pending_follow_content) |c| gpa.free(c);
    g_pending_follow_tags = null;
    g_pending_follow_content = null;
    g_pending_follow_created_at = 0;
}

/// Remembers what was just signed, as the base the next press builds on. Takes
/// its own copy: the write seam owns what it was handed and frees it.
pub fn setPendingFollowBase(tags: []const nostr.event.Tag, content: []const u8, created_at: i64) void {
    const gpa = std.heap.page_allocator;
    clearPendingFollowBase();
    // No base beats a partial one: a partial one publishes a list with nobody
    // in it. `dupeTags` reports the difference now rather than returning an
    // empty set that reads as "this list was empty".
    const tag_copy = dupeTags(gpa, tags) orelse return;
    g_pending_follow_tags = tag_copy;
    g_pending_follow_content = gpa.dupe(u8, content) catch {
        clearPendingFollowBase();
        return;
    };
    g_pending_follow_created_at = created_at;
}

/// Drops the pending base once the store holds something at least as new, which
/// is the signer's answer having come back and been ingested.
pub fn releasePendingFollowBase(stored_at: i64) void {
    if (g_pending_follow_tags == null) return;
    if (stored_at < g_pending_follow_created_at) return;
    clearPendingFollowBase();
}

/// What one follow press changed, held only until that write is known to have
/// landed.
///
/// The press moves the live list before anything is signed, which is what makes
/// the feed answer immediately and is worth keeping. What was missing is the
/// other half: if the signature never comes back, nothing put the list back, so
/// the app went on showing a follow that reached no relay. Worse, the stamp the
/// press wrote outranked the real list for the rest of the session, so the
/// account could not even be corrected by re-reading it.
///
/// One name, one direction and the stamp to go back to. A press toggles exactly
/// one person, so undoing it needs nothing more than that.
///
/// Held WITH the request it belongs to: in `g_helper_sign` for Notary, in the
/// request's own `g_pending` slot for a bunker. It used to be one global slot,
/// on the reasoning that only one signature is ever in flight. That holds for
/// Notary and not for a bunker, whose table has eight slots: a like pressed
/// while a reply was still on the phone freed the reply's text, and when the
/// reply was then refused the like was the one taken back. Kept with its own
/// request, a failure puts back exactly what that press changed, and a success
/// releases exactly that.
pub const PendingUndo = union(enum) {
    none,
    follow: ListPress,
    mute: ListPress,
    like: i64,
    unlike: Unlike,
    /// The stamp to go back to. This one is written to disk, so a failure that
    /// leaves it forward keeps the reader's real relay list out ACROSS
    /// RESTARTS, not just for the session.
    relay_list: i64,
    repost: i64,
    /// The typed text, owned here, so a refused reply is not destroyed, and the
    /// thread it answers, so it goes back to that thread and no other.
    reply: Reply,
    profile,

    const ListPress = struct { pubkey: [32]u8, added: bool, created_at: i64 };
    pub const Reply = struct { text: []const u8, root: [32]u8 };
    const Unlike = struct { note_id: i64, reaction_id: [32]u8 };
};

/// Drops a record without applying it: the signature came back, or the request
/// it rode with is gone with its session.
pub fn releaseUndo(u: PendingUndo) void {
    switch (u) {
        .reply => |r| std.heap.page_allocator.free(r.text),
        else => {},
    }
}

/// The record a test arms by hand, standing in for the one a request carries.
var g_test_undo: PendingUndo = .none;
/// Puts back what one press changed, after its signature never arrived, and
/// says so. Takes ownership of `undo`.
///
/// Silence was the whole defect. A reader who unfollows somebody, or mutes
/// them, and is shown the state they asked for has no way to learn that nothing
/// was published; on the next launch the person is still there.
pub fn applyUndo(model: *Model, undo: PendingUndo) void {
    switch (undo) {
        .none => return,
        .follow => |p| {
            var next: [max_follows_tracked][32]u8 = undefined;
            var n: usize = 0;
            // Snapshot under the lock, rebuild outside it: `setFollows` takes
            // the same lock and this one is not reentrant.
            lockFollows();
            for (g_follows[0..g_follow_count]) |f| {
                if (p.added and std.mem.eql(u8, &f, &p.pubkey)) continue;
                if (n >= next.len) break;
                next[n] = f;
                n += 1;
            }
            unlockFollows();
            if (!p.added and n < next.len) {
                next[n] = p.pubkey;
                n += 1;
            }
            // The base went with the press, so it goes back with it. Leaving it
            // would make the next press build on a list nobody published.
            clearPendingFollowBase();
            _ = setFollows(next[0..n], p.created_at);
            setToast(model, "Not signed. Put that back.");
        },
        .mute => |p| {
            var next: [max_mutes][32]u8 = undefined;
            var n: usize = 0;
            lockMutes();
            for (mutes.g_mutes[0..mutes.g_mute_count]) |m| {
                if (p.added and std.mem.eql(u8, &m, &p.pubkey)) continue;
                if (n >= next.len) break;
                next[n] = m;
                n += 1;
            }
            unlockMutes();
            if (!p.added and n < next.len) {
                next[n] = p.pubkey;
                n += 1;
            }
            // Restoring the stamp is the half that matters most here. The press
            // stamped the list forward, and `ingestMuteList` drops anything at
            // or below the stamp it holds, so without this the reader's real
            // mute list could not reach the screen again for the whole session.
            _ = setMutes(next[0..n], p.created_at);
            setToast(model, "Not signed. Put that back.");
        },
        .like => |note_id| {
            _ = forgetLike(note_id);
            setToast(model, "That like was not signed.");
        },
        .unlike => |u| {
            // The reaction id was dropped before signing, so the heart emptied
            // and the kind:7 stayed on every relay. Putting the id back is what
            // stops the next press publishing a SECOND reaction.
            rememberLike(u.note_id, u.reaction_id);
            setToast(model, "That was not signed.");
        },
        .repost => |note_id| {
            clearRepostedByMe(note_id);
            setToast(model, "That repost was not signed.");
        },
        .relay_list => |stamp| {
            setRelayListStamp(stamp);
            saveRelays();
            // And the edit is pending again. `clearRelayListPublish` runs on the
            // handoff rather than on a publish, so without this a refused
            // signature is recorded as delivered and never retried, which is the
            // opposite of what its own comment promises.
            relay_list.g_relay_list_dirty = true;
            setToast(model, "Your relays were not saved. Trying again.");
        },
        .reply => |r| {
            defer std.heap.page_allocator.free(r.text);
            setToast(model, switch (putBackRefusedReply(model, r.root, r.text)) {
                .box => "Not signed. Your reply is back.",
                .box_below => "Not signed. Reply put back under your new text.",
                .kept => "Not signed. Reply kept in its thread.",
                .kept_below => "Not signed. Reply kept under the newer one.",
                .copied => "Not signed. Reply did not fit back, so copied.",
            });
        },
        .profile => {
            model.profile_stage = .failed;
            setToast(model, "That was not saved.");
        },
    }
}
/// Whether a write may shrink the list this much.
///
/// Following adds a name and never removes one; unfollowing removes exactly one.
/// Anything larger is this app's own bug, a stale base, or a rebase onto
/// somebody else's truncation, and refusing beats publishing and finding out
/// later. No client in the ecosystem has this guard.
///
/// It is defense in depth: no path in this file can currently trip it, which is
/// the point. It is here to catch the refactor that would.
pub fn shrinkAllowed(before: usize, after: usize, following: bool) bool {
    const allowed: usize = if (following) 0 else 1;
    return before <= after + allowed;
}
/// Two hex strings naming the same key. A `p` tag in the wild is not reliably
/// lower case, and treating `AB…` as a different person from `ab…` would let a
/// follow silently duplicate somebody already on the list.
pub fn hexEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
/// The reader's own kind:3, arriving from a relay. Adopted when it is NEWER than
/// what is held, so a slower relay's older copy never undoes a newer one, and
/// unless they have written one here since.
pub fn ingestContactList(ev: nostr.event.Event) void {
    const pk = activePubkey() orelse return;
    if (!std.mem.eql(u8, &pk, &ev.pubkey)) return;
    lockFollows();
    const owned = followsAreOwned();
    const held_at = g_follow_created_at;
    unlockFollows();
    // The signer answered and the list came back: the copy this app was holding
    // as a base has been superseded by the real one.
    releasePendingFollowBase(ev.created_at);
    // Their hands beat their history, and history beats older history.
    if (owned and ev.created_at <= held_at) return;
    var list: [max_follows_tracked][32]u8 = undefined;
    const n = followsFromTags(ev.tags, &list);
    // A contact list with no usable `p` tag is not a list. Adopting it would
    // empty the reader's feed on the word of one malformed event.
    if (n == 0) return;
    _ = setFollows(list[0..n], ev.created_at);
}

/// The pubkeys a kind:3's `p` tags name, in their published order, deduped.
pub fn followsFromTags(tags: []const nostr.event.Tag, out: [][32]u8) usize {
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
            if (std.mem.eql(u8, &had, &pk)) seen = true;
        }
        if (seen) continue;
        out[n] = pk;
        n += 1;
    }
    return n;
}
/// Whether a pubkey is inside the reader's follow graph: the accounts whose
/// replies rank first in a thread. That is the reader themself, plus EVERY
/// account on their contact list, plus the starter pack while the pack is what
/// the feed reads.
///
/// Asked of the whole list, never of `followSet()`. That one is capped at
/// `max_follows` because it is the FEED's author set, and the feed pays a relay
/// filter entry and a store cursor per author, so it is deliberately a slice.
/// Membership is a different question and has no reason to be capped: asking it
/// of the slice told a reader with three hundred follows that follows 129 and up
/// were strangers, in every thread, forever. Worse, a new follow is APPENDED, so
/// the people most recently followed were the ones most likely to be misfiled.
///
/// Two differences from `isInReadGraph`, both deliberate. Your OWN replies are
/// inside your conversation, though you do not follow yourself and the inbox
/// would be wrong if you did. And a GUEST still has a graph here: they are
/// reading the pack, so pack members are the conversation and everyone else is
/// the crowd, where for the inbox a guest has nothing to rank at all.
pub fn inFollowGraph(pubkey: [32]u8) bool {
    if (activePubkey()) |me| {
        if (std.mem.eql(u8, &me, &pubkey)) return true;
    }
    return inFollowedSet(pubkey);
}

pub fn followSetForTest() []const [32]u8 {
    return followSet();
}
/// How many people are on the reader's OWN list, whichever feed is being read.
/// The menu names both feeds at once, so it cannot ask `followTotal`: that one
/// answers for the feed in front of you.
pub fn setHomeScopeForTest(next: HomeScope) void {
    setHomeScope(next);
}

/// Arms an undo directly, for the writes whose real path needs a live note, a
/// live `Effects` or a relay behind it. Arming itself is not what these check:
/// `signAndPublish` takes the record as an argument, so a write cannot reach
/// the signer without one. What they check is that each record puts the right
/// thing back.
pub fn armUndoForTest(u: PendingUndo) void {
    releaseUndo(g_test_undo);
    g_test_undo = u;
}

pub fn armUnlikeUndoForTest(note_id: i64, reaction_id: [32]u8) void {
    armUndoForTest(.{ .unlike = .{ .note_id = note_id, .reaction_id = reaction_id } });
}

pub fn applyUndoForTest(model: *Model) void {
    const u = g_test_undo;
    g_test_undo = .none;
    applyUndo(model, u);
}

/// Puts the app in the state a bunker or a Notary key leaves it in: a contact
/// list signed, handed to the signer, and not yet in the store. That gap cannot
/// be driven from a test, because the async paths need a live `Effects`, so the
/// state they produce is set up directly and the write is then driven for real.
pub fn setPendingFollowBaseForTest(tags: []const nostr.event.Tag, content: []const u8, created_at: i64) void {
    setPendingFollowBase(tags, content, created_at);
}

pub fn clearPendingFollowBaseForTest() void {
    clearPendingFollowBase();
}

pub fn pendingFollowCountForTest() ?usize {
    const tags = g_pending_follow_tags orelse return null;
    return countPeople(tags);
}

pub fn countPeopleForTest(tags: []const nostr.event.Tag) usize {
    return countPeople(tags);
}

pub fn shrinkAllowedForTest(before: usize, after: usize, following: bool) bool {
    return shrinkAllowed(before, after, following);
}

pub fn writeFollowForTest(fx: *Effects, pubkey: [32]u8, following: bool) bool {
    return writeFollow(fx, pubkey, following) == .published;
}

pub fn followsFromTagsForTest(tags: []const nostr.event.Tag, out: [][32]u8) usize {
    return followsFromTags(tags, out);
}

pub fn setFollowsForTest(list: []const [32]u8, created_at: i64) bool {
    return setFollows(list, created_at);
}

pub fn forgetFollowsForTest() void {
    g_home_scope = .following;
    forgetFollows();
}
pub fn loadFollowsFromStoreForTest() void {
    loadFollowsFromStore();
}

pub fn ingestContactListForTest(ev: nostr.event.Event) void {
    ingestContactList(ev);
}

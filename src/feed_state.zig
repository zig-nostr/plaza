//! The feed's working state: arrivals, rebuild work, note storage, and the since stamps.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const adoptHelperIdentity = main.adoptHelperIdentity;
const refreshProfiles = main.refreshProfiles;
const Model = main.Model;
const Note = main.Note;
const feed_page = main.feed_page;
const isMuted = main.isMuted;
const isRepostKind = main.isRepostKind;
const kindRender = main.kindRender;
const noteFrom = main.noteFrom;
const repostTargetId = main.repostTargetId;
const thread_reply_cap = main.thread_reply_cap;

/// Ids of kind:1 events an ingest thread has just added to the store.
///
/// Sized well past a busy second so the common case never overflows. A backfill
/// does overflow it, and that is not a loss: overflow means the list in hand
/// cannot be brought up to date by splicing, so the next rebuild reads the store
/// in full, which is exactly what a backfill wants anyway.
pub const feed_arrival_cap = 1024;
var g_arrival_lock = std.atomic.Value(bool).init(false);
var g_arrival_ids: [feed_arrival_cap][32]u8 = undefined;
var g_arrival_len: usize = 0;
var g_arrival_overflowed: bool = false;
/// Read on every tick without taking the lock, so a tick with nothing waiting
/// costs one atomic load.
pub var g_arrival_pending = std.atomic.Value(bool).init(false);
/// The render thread's private copy, drained under the lock.
pub var g_arrival_taken: [feed_arrival_cap][32]u8 = undefined;

/// The list in hand is no longer a valid starting point: read the store in full
/// on the next rebuild. Safe from any thread.
///
/// Set by everything that changes what the feed is a view OF (the author set,
/// the identity, how deep the reader has paged) and by a deletion, which is the
/// one arrival a splice cannot express: splicing only ever adds.
pub var g_feed_rebuild_all = std.atomic.Value(bool).init(true);

pub fn invalidateFeed() void {
    g_feed_rebuild_all.store(true, .release);
}

fn lockArrivals() void {
    while (g_arrival_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn unlockArrivals() void {
    g_arrival_lock.store(false, .release);
}

pub fn noteFeedArrival(id: [32]u8) void {
    lockArrivals();
    defer unlockArrivals();
    if (g_arrival_len >= g_arrival_ids.len) {
        g_arrival_overflowed = true;
    } else {
        g_arrival_ids[g_arrival_len] = id;
        g_arrival_len += 1;
    }
    g_arrival_pending.store(true, .release);
}

/// Empties the buffer into the render thread's copy and reports whether anything
/// was dropped on the way in.
///
/// Everything, in one locked step, at the top of the rebuild. That is what makes
/// it safe: an event landing while the rebuild is running goes into the emptied
/// buffer and is spliced on the next tick, rather than falling between the query
/// and the clear. Taking the count first and clearing after the query would lose
/// exactly those.
pub fn takeFeedArrivals() struct { n: usize, lost: bool } {
    lockArrivals();
    defer unlockArrivals();
    const n = g_arrival_len;
    @memcpy(g_arrival_taken[0..n], g_arrival_ids[0..n]);
    const lost = g_arrival_overflowed;
    g_arrival_len = 0;
    g_arrival_overflowed = false;
    g_arrival_pending.store(false, .release);
    return .{ .n = n, .lost = lost };
}

/// Forgets what is waiting. For a reset that is about to rebuild from nothing.
pub fn clearFeedArrivals() void {
    lockArrivals();
    defer unlockArrivals();
    g_arrival_len = 0;
    g_arrival_overflowed = false;
    g_arrival_pending.store(false, .release);
}
/// The newest kind:1 this app holds, for the feed's `since`.
///
/// Updated by the ingest threads, seeded once from the store at startup so a
/// relaunch does not re-download everything it already has.
pub var g_feed_newest = std.atomic.Value(i64).init(0);

/// How far back of the newest held note the feed re-asks from.
///
/// The same one hour `inboxSince` uses, and for the same reason: relays differ
/// on whether `since` is inclusive, clocks differ, and an event can be stored
/// with a `created_at` behind the one that arrived before it. An hour of
/// overlap costs a few duplicate events, which the store rejects, and buys not
/// silently missing the notes either side of a reconnect.
const feed_since_overlap_s: i64 = 3600;

pub fn noteFeedNewest(created_at: i64) void {
    var seen = g_feed_newest.load(.monotonic);
    while (created_at > seen) {
        seen = g_feed_newest.cmpxchgWeak(seen, created_at, .monotonic, .monotonic) orelse break;
    }
}

/// Reads the newest stored kind:1 once, so the first subscription after a
/// launch is bounded too. One cursor on the kind index, not a merge.
pub fn seedFeedNewest(store: *nostr.store.Store) void {
    if (g_feed_newest.load(.monotonic) != 0) return;
    const kinds = [_]u16{1};
    var result = store.query(std.heap.page_allocator, .{ .kinds = &kinds, .limit = 1 }) catch return;
    defer result.deinit();
    if (result.events.len > 0) noteFeedNewest(result.events[0].created_at);
}

/// What the feed asks relays to start from, or null on a cold store.
///
/// Every reconnect re-asked for the full three hundred per chunk, from every
/// relay, because no feed filter ever carried a `since`. A flapping relay was
/// therefore handed a fifteen-hundred-event question every few seconds, and
/// every one of those events cost a Schnorr verify before the store recognised
/// it as a duplicate. The app already knew the shape: `subscribeInbox` has done
/// exactly this since it was written.
///
/// Null when nothing is held, which is Notedeck's rule: a cold store needs the
/// whole backfill, and bounding it would leave a new install with an empty feed.
pub fn feedSince() ?i64 {
    const newest = g_feed_newest.load(.monotonic);
    if (newest == 0) return null;
    return @max(0, newest - feed_since_overlap_s);
}
/// Whether `pubkey` is one of the feed's authors. A walk, because the set is a
/// plain array; only arrivals that are not already on screen reach it.
pub fn authorInSet(authors: []const [32]u8, pubkey: [32]u8) bool {
    for (authors) |a| {
        if (std.mem.eql(u8, &a, &pubkey)) return true;
    }
    return false;
}

/// Whether `ev` sorts ahead of `note` in the feed: newer, or the same second and
/// a higher id.
///
/// The tie-break is not decoration. It is the store's own ordering
/// (`created_at` descending, then id descending), and a merge that broke ties
/// differently would put two same-second notes in one order while a full read
/// put them in the other, so the pair would swap places the next time anything
/// forced a full read.
pub fn eventNewerThanNote(ev: nostr.event.Event, note: Note) bool {
    if (ev.created_at != note.created_at) return ev.created_at > note.created_at;
    return std.mem.order(u8, &ev.id, &note.event_id) == .gt;
}

/// Orders two events the way the store orders them: newest first, ties broken
/// by id so the sequence is total and stable rather than dependent on which
/// cursor happened to answer first.
pub fn eventNewer(a: nostr.event.Event, b: nostr.event.Event) bool {
    if (a.created_at != b.created_at) return a.created_at > b.created_at;
    return std.mem.order(u8, &a.id, &b.id) == .gt;
}

/// Adopts `secret` as the active local identity. For tests: the feed scopes
/// its queries to the follow set plus the signed-in user, so a test that
/// stores its own events needs to BE somebody.
/// The key a test's stand-in daemon signs with.
///
/// Plaza does not hold a secret key any more, so a test cannot be somebody by
/// being given one. It is somebody the way the shipped app is: it knows a
/// pubkey and asks a keyholder for signatures. The keyholder in a test is the
/// few lines at the end of `requestHelperSign`, and this is the key it uses.
///
/// The point is not the convenience. Four hundred tests call the shim below,
/// and pointing them at the helper path means four hundred tests now exercise
/// the path that ships, instead of a local-key arm that no longer exists
/// outside them.
pub var g_test_secret: ?[32]u8 = null;
/// How the feed has been brought up to date, counted. Asserted on instead of
/// timed: a stopwatch in a Debug test binary on a shared machine says nothing,
/// and the whole point of this path is which of the two ran.
pub const FeedWork = struct {
    /// Windows read back from the store in full: a cursor per followed author.
    full_reads: usize = 0,
    /// Merges of what the ingest threads announced: a direct read per id.
    splices: usize = 0,
    /// Notes parsed from an event. A reused card costs nothing and is not here.
    parses: usize = 0,
};
pub var g_feed_work: FeedWork = .{};

pub fn feedWork() FeedWork {
    return g_feed_work;
}
pub fn resetFeedWork() void {
    g_feed_work = .{};
}
/// The feed key derived from an event id: the first eight bytes, sign bit
/// masked so the markup engine's i64 key round-trip never overflows.
pub fn noteIdOf(ev: nostr.event.Event) i64 {
    return feedKeyOf(ev.id);
}

pub fn feedKeyOf(id: [32]u8) i64 {
    return @intCast(std.mem.readInt(u64, id[0..8], .big) & std.math.maxInt(i64));
}

// The previous feed, kept across one rebuild so unchanged notes carry over
// without being re-parsed. Static rather than stack: three hundred cards of
// fixed buffers are far too big for a frame's stack.
/// The feed's note storage, and the scratch copy a rebuild carries the previous
/// pass in. Both grow together and neither ever shrinks: a reader who has paged
/// down to four thousand notes will do it again next session, and returning the
/// memory only to ask for it back is churn for a number nobody sees.
///
/// Page-allocated rather than static. Three hundred notes was already 900 KB of
/// BSS across the two arrays; sizing a static array for "no limit" is not a
/// thing that can be done.
pub var g_feed_notes: []Note = &.{};
pub var g_feed_scratch: []Note = &.{};

/// What a level's notes start on, and the larger buffer a long profile moves to.
/// Process-wide like the feed's, for the same reason: there is one reader and
/// one level on screen, and a model that is made (or copied) already points at
/// storage it can write to.
pub var g_level_boot: [thread_reply_cap]Note = [_]Note{.{}} ** thread_reply_cap;
pub var g_level_notes: []Note = &g_level_boot;
/// The names generation the open person's notes were parsed under.
pub var g_profile_notes_names: u64 = std.math.maxInt(u64);
/// How many notes the person's page has parsed, rather than carried over. For a
/// test, which has no clock that could tell the two apart.
pub var g_profile_parses: usize = 0;
/// Makes room for `want` notes, returning what is actually available. A failed
/// growth keeps what it had, so a feed that cannot grow stops growing instead of
/// losing the notes it is already showing.
pub fn ensureFeedCapacity(want: usize) usize {
    if (g_feed_notes.len >= want) return g_feed_notes.len;
    // Doubling, so paging down a long feed is a handful of allocations rather
    // than one per page.
    var next = @max(g_feed_notes.len, feed_page);
    while (next < want) next *|= 2;
    const grown = std.heap.page_allocator.realloc(g_feed_notes, next) catch return g_feed_notes.len;
    const scratch = std.heap.page_allocator.realloc(g_feed_scratch, next) catch {
        // The two must stay the same length: a rebuild indexes both.
        g_feed_notes = grown;
        return @min(grown.len, g_feed_scratch.len);
    };
    for (grown[g_feed_notes.len..]) |*n| n.* = .{};
    g_feed_notes = grown;
    g_feed_scratch = scratch;
    return g_feed_notes.len;
}

/// An open-addressed id-to-slot table over the previous pass, so a rebuild finds
/// an already-parsed card in constant time.
///
/// This was a linear scan of the previous feed, once per event. That is ninety
/// thousand comparisons at the old three-hundred cap, which was survivable, and
/// quadratic without one: sixteen million at four thousand notes, on a rebuild
/// that runs about once a second. Removing the cap is what made the scan matter.
var g_reuse_slots: []u32 = &.{};
const reuse_empty: u32 = std.math.maxInt(u32);

/// Which of a splice's arrivals belong in the feed, as indices into the query
/// result. Indices rather than parsed cards: a thousand `Note`s is over a
/// megabyte of buffers, and the merge can parse each one straight into its final
/// position instead.
pub var g_splice_keep: [feed_arrival_cap]u32 = undefined;

/// The window depth the list in hand was built for, as asked for and as it came
/// out after clamping to the storage. A change in either means notes below the
/// old bottom belong now, and no arrival says so.
///
/// Both, because they move for different reasons: the reader raises the ask by
/// paging down, and the clamp lifts on its own when a growth that failed earlier
/// succeeds. The ask is also what the tick's own staleness check reads, so that
/// paging down wakes a tick that would otherwise see an unchanged store and
/// skip the rebuild entirely.
pub var g_notes_limit: usize = 0;
pub var g_notes_feed_limit: usize = 0;
/// The place revision the notes on screen were built from.
pub var g_notes_place_rev: u32 = 0;

fn reuseHash(id: i64, mask: usize) usize {
    // Fibonacci mixing: note ids are the first eight bytes of a hash, so the low
    // bits are already well spread, but the multiply costs nothing and protects
    // against a masked slice of them clustering.
    const mixed = @as(u64, @bitCast(id)) *% 0x9E37_79B9_7F4A_7C15;
    return @as(usize, @intCast(mixed >> 40)) & mask;
}

/// Fills the table for `old` and returns it, or an empty slice if it cannot be
/// sized, in which case the caller reparses rather than reusing. Reparsing is
/// slower, never wrong.
pub fn buildReuseIndex(old: []const Note) []u32 {
    if (old.len == 0) return &.{};
    // Half load factor, so probes stay short.
    var want: usize = 128;
    while (want < old.len * 2) want *|= 2;
    if (g_reuse_slots.len < want) {
        g_reuse_slots = std.heap.page_allocator.realloc(g_reuse_slots, want) catch return &.{};
    }
    const table = g_reuse_slots[0..want];
    @memset(table, reuse_empty);
    const mask = want - 1;
    for (old, 0..) |note, i| {
        var at = reuseHash(note.id, mask);
        while (table[at] != reuse_empty) at = (at + 1) & mask;
        table[at] = @intCast(i);
    }
    return table;
}

/// Where `event_id` sits in `old`, when it is there at all.
///
/// Compares the full 32 bytes, not the eight-byte feed key the table is hashed
/// on. The key is a render handle and two ids could in principle share one; the
/// splice uses this answer to decide whether an arriving note is already on
/// screen, and getting that wrong would show the same note twice or hide a real
/// one behind a stranger's card.
pub fn heldIndex(table: []const u32, old: []const Note, event_id: [32]u8) ?usize {
    if (table.len == 0) return null;
    const mask = table.len - 1;
    var at = reuseHash(feedKeyOf(event_id), mask);
    while (table[at] != reuse_empty) : (at = (at + 1) & mask) {
        const i = table[at];
        if (std.mem.eql(u8, &old[i].event_id, &event_id)) return i;
    }
    return null;
}

/// A seen-set over the cards this rebuild has already placed.
///
/// A hash rather than a look-back scan: the feed grows as the reader pages down
/// and is never handed back, so scanning what is already placed would be
/// quadratic in how far they have read.
///
/// Hashed on the render key and compared on the FULL id, for the reason
/// `heldIndex` gives one screen up: the key is a handle and two ids could in
/// principle share one, and getting this wrong would hide a real note behind a
/// stranger's card.
var g_placed_slots: []u32 = &.{};

pub fn placedReset(want_len: usize) []u32 {
    var want: usize = 128;
    while (want < want_len * 2) want *|= 2;
    if (g_placed_slots.len < want) {
        g_placed_slots = std.heap.page_allocator.realloc(g_placed_slots, want) catch return &.{};
    }
    const table = g_placed_slots[0..want];
    @memset(table, reuse_empty);
    return table;
}

/// True when `event_id` is already placed; records it at `index` otherwise.
///
/// False when the table could not be sized, which draws a duplicate rather than
/// dropping a card. Of the two wrong answers, showing something twice is the
/// one a reader can see and understand.
pub fn placedTake(table: []u32, notes: []const Note, event_id: [32]u8, index: usize) bool {
    if (table.len == 0) return false;
    const mask = table.len - 1;
    var at = reuseHash(feedKeyOf(event_id), mask);
    while (table[at] != reuse_empty) : (at = (at + 1) & mask) {
        if (std.mem.eql(u8, &notes[table[at]].event_id, &event_id)) return true;
    }
    table[at] = @intCast(index);
    return false;
}

/// The card an event becomes in the feed.
///
/// A repost is not drawn as itself. NIP-18 wraps somebody else's note, and what
/// a reader wants is that note with a line saying who passed it on, so the card
/// built here IS the reposted note: its id, its author, its words. Everything
/// else then falls out for free, because the rest of this file already keys on
/// `event_id`: dedup collapses two follows reposting one note into one row, and
/// engagement is already counted against the note's own id, so the numbers
/// belong to what was reposted rather than to the wrapper.
///
/// The target is resolved FROM THE STORE by the `e` tag, never rendered out of
/// the wrapper's `content`. Every reference client does it this way, and the
/// embedded copy is the reason: it is whatever the reposter pasted, and no
/// relay serving it vouches for it. Coracle spells out the consequence, that a
/// forged or unsigned embedded copy costs a round trip rather than rendering.
/// The copy still earns its keep, one door up in `plazaIngest`, where it is
/// ingested like any other event and has its signature checked there.
///
/// Null when the target is not in the store yet, or is not something drawable
/// as a note. Notedeck drops the row for exactly these two reasons.
pub fn feedCardFrom(store: *nostr.store.Store, ev: nostr.event.Event, now_s: i64) ?Note {
    if (!isRepostKind(ev.kind)) return noteFrom(ev, now_s);
    const target_id = repostTargetId(ev.tags) orelse return null;
    var se = (store.getEvent(std.heap.page_allocator, target_id) catch return null) orelse return null;
    defer se.deinit();
    if (kindRender(se.event.kind) != .note) return null;
    // Both authors get a say. The loop above already refused a muted reposter;
    // this refuses a muted author whose note a follow passed on, which is the
    // same reader asking not to see the same person.
    if (isMuted(se.event.pubkey)) return null;
    var note = noteFrom(se.event, now_s);
    note.reposter = ev.pubkey;
    note.has_reposter = true;
    return note;
}

/// Points a model at the feed storage, growing it to at least one page. Called
/// wherever a Model is made, so `notes[0]` is writable without every caller
/// having to think about it.
pub fn attachFeedStorage(model: *Model) void {
    _ = ensureFeedCapacity(feed_page);
    model.notes = g_feed_notes;
}

/// Points the app's store at a test's own, so the funnel can be driven for real.
pub fn setStoreForTest(store: ?*nostr.store.Store) void {
    main.g_store = store;
    if (store) |st| seedFeedNewest(st);
}
/// Stamps the newest note the feed has seen, so a test can put `feedSince` in
/// the state that matters. Without this it returns null for want of any note at
/// all, and a test asserting "no since" passes whether or not the code asks for
/// one.
pub fn setFeedNewestForTest(created_at: i64) void {
    g_feed_newest.store(created_at, .monotonic);
}
pub fn feedSinceForTest() ?i64 {
    return feedSince();
}
pub fn setIdentityForTest(secret: [32]u8) void {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    g_test_secret = secret;
    adoptHelperIdentity(kp.public_key);
}
/// Forces the next reconcile to do the full work rather than take the
/// unchanged-store fast path, so a benchmark measures a rebuild.
pub fn invalidateFeedForTest() void {
    invalidateFeed();
}
pub fn reconcileForTest(model: *Model, store: *nostr.store.Store, now_s: i64) void {
    invalidateFeed();
    refreshProfiles(store);
    model.rebuildNotes(store, now_s);
}
/// Empties the arrival buffer and asks for a full read next time, so a test
/// starts from a known place rather than from whatever the last one left.
pub fn resetFeedChangeDetectionForTest() void {
    clearFeedArrivals();
    invalidateFeed();
    g_notes_limit = 0;
    g_notes_feed_limit = 0;
    main.g_last_count = std.math.maxInt(usize);
}

/// Announces an id as newly arrived without storing anything. For the case the
/// app is not supposed to produce and the splice guards against anyway.
pub fn noteFeedArrivalForTest(id: [32]u8) void {
    noteFeedArrival(id);
}

/// Fills the arrival buffer past its capacity, the way a backfill does.
pub fn overflowFeedArrivalsForTest() void {
    for (0..feed_arrival_cap + 1) |i| {
        var id = [_]u8{0} ** 32;
        std.mem.writeInt(u64, id[0..8], i, .big);
        noteFeedArrival(id);
    }
}

pub fn profileParsesForTest() usize {
    return g_profile_parses;
}
pub fn reserveFeedForTest(model: *Model, n: usize) void {
    _ = ensureFeedCapacity(n);
    model.notes = g_feed_notes;
}
/// The key a quote of `id` is uncovered by, which is the key the same note
/// carries in the feed.
pub fn feedKeyForTest(id: [32]u8) i64 {
    return feedKeyOf(id);
}

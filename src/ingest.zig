//! The per-relay reader threads, their reconnect ladder, and the feed watch.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const routing = @import("routing.zig");
const session = @import("session.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AuthSession = main.AuthSession;
const Note = main.Note;
const activePubkey = main.activePubkey;
const authPoll = main.authPoll;
const authReact = main.authReact;
const authSlotReset = main.authSlotReset;
const buildFeedFilters = main.buildFeedFilters;
const buildRoutedFilters = main.buildRoutedFilters;
const clearRelayRefusal = main.clearRelayRefusal;
const clearRelayRtt = main.clearRelayRtt;
const clearRoutedLive = main.clearRoutedLive;
const contact_list_kind = main.contact_list_kind;
const countEngagement = main.countEngagement;
const discoveredSnapshot = main.discoveredSnapshot;
const discovered_authors_cap = main.discovered_authors_cap;
const discovered_watch_base = main.discovered_watch_base;
const engagementFilter = main.engagementFilter;
const engagement_watch_cap = main.engagement_watch_cap;
const engagement_widen_ms = main.engagement_widen_ms;
const feedSince = main.feedSince;
const feed_sub_base = main.feed_sub_base;
const followGeneration = main.followGeneration;
const hexLower = main.hexLower;
const identityGeneration = main.identityGeneration;
const inboxAdd = main.inboxAdd;
const ingestContactList = main.ingestContactList;
const ingestRelayList = main.ingestRelayList;
const ingest_wake = main.ingest_wake;
const isFeedSub = main.isFeedSub;
const isOneShotSub = main.isOneShotSub;
const markInboxDirty = main.markInboxDirty;
const markRelaySeen = main.markRelaySeen;
const max_feed_filters = main.max_feed_filters;
const max_follows = main.max_follows;
const noteContactsAnsweredBy = main.noteContactsAnsweredBy;
const noteFeedNewest = main.noteFeedNewest;
const noteIdOf = main.noteIdOf;
const noteRelayRefusal = main.noteRelayRefusal;
const nowSeconds = main.nowSeconds;
const offerLiveRelay = main.offerLiveRelay;
const outbox_sub_id = main.outbox_sub_id;
const plazaIngestFrom = main.plazaIngestFrom;
const poolAuthorsOrAll = main.poolAuthorsOrAll;
const probeFilters = main.probeFilters;
const probe_interval_ms = main.probe_interval_ms;
const probe_sub = main.probe_sub;
const recordRelayRtt = main.recordRelayRtt;
const relayAt = main.relayAt;
const relaySnapshot = main.relaySnapshot;
const relayUrlAt = main.relayUrlAt;
const relayUrlEql = main.relayUrlEql;
const relay_list_kind = main.relay_list_kind;
const relaysPaused = main.relaysPaused;
const routedSlotStillNames = main.routedSlotStillNames;
const setRelayStatus = main.setRelayStatus;
const setRoutedLive = main.setRoutedLive;
const subscribeInbox = main.subscribeInbox;

/// The first wait before redialling a relay whose connection ended, and the
/// ceiling that wait grows to.
///
/// This used to be a flat three seconds, forever, with no counter. A relay that
/// is down, that has stopped taking this reader, or that accepts the handshake
/// and then drops the socket was dialled twelve hundred times an hour for as
/// long as the app stayed open, from eight threads with no jitter between them,
/// and every one of those dials re-asked for the whole backlog.
const reconnect_base_ms: u64 = 3_000;
const reconnect_max_ms: u64 = 300_000;

/// How long a connection has to last before it counts as having worked.
///
/// The reason for the rule is not obvious: a successful handshake is NOT
/// evidence that a relay is healthy. A relay that accepts the socket and
/// immediately closes it would reset the ladder on every open, and the widening
/// delay would never widen. Only a connection that stayed up clears the count.
const stable_connection_ms: i64 = 60_000;

/// The wait before redialling, after `attempts` connections in a row that did
/// not last. Doubling, capped.
pub fn reconnectDelayMs(attempts: u6) u64 {
    const shift: u6 = @min(attempts, 7);
    return @min(reconnect_base_ms << shift, reconnect_max_ms);
}

/// The attempt count after a connection that stayed up for `lasted_ms`.
///
/// Separate from the loop so the rule can be asserted rather than described: a
/// connection only clears the ladder by LASTING, never by opening.
pub fn nextReconnectAttempts(attempts: u6, lasted_ms: i64) u6 {
    return if (lasted_ms >= stable_connection_ms) 0 else attempts +| 1;
}

/// Extra delay for slot `index`, so the pool does not redial in lockstep.
///
/// Spread rather than randomness, because the thing being avoided is specific:
/// eight threads that dropped together on one network blip coming back together,
/// and then staying in step for the rest of the session. Walking the offset by
/// the attempt as well as the slot separates two relays that happened to start
/// aligned. Never more than a quarter of the wait, and it is a function, so what
/// it promises can be asserted.
pub fn reconnectJitterMs(wait: u64, index: usize, attempts: u6) u64 {
    const slice = wait / 64;
    const step = (index *% 5 +% @as(usize, attempts) *% 3) % 16;
    return slice * step;
}
pub fn rememberFeedId(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: *usize,
    ev: nostr.event.Event,
) void {
    if (len.* >= engagement_watch_cap) return;
    const nid = noteIdOf(ev);
    for (ids[0..len.*]) |seen| {
        if (seen == nid) return;
    }
    ids[len.*] = nid;
    hexLower(&hex[len.*], ev.id);
    len.* += 1;
}

// -- What the feed is SHOWING, rather than what happened to arrive -----------
//
// The watch list was built only from events that came down the wire this
// session, while the feed's own REQ carries a `since` off the newest stored
// note. So on any store that is not cold, the feed draws notes nobody has asked
// a relay about, and every one of them reads zero replies, zero reposts, zero
// likes and zero sats for the whole session. A guest sees it worst, because a
// starter-pack feed is nearly all store after the first launch, and it looked
// like guests simply do not get counts.
//
// It also explains the shape of it: opening a note fetches THAT note's
// engagement on its own socket, so a count would appear for exactly the note
// somebody had looked at, stay when they went back, and nowhere else.
//
// So the view publishes what it is drawing, and each relay worker folds that in
// before it asks. Written by the view thread, read by every relay thread, under
// a lock of its own: the engagement table has one already and taking it here
// would mean holding two in an order nothing else in the app agrees on.
var g_feed_watch_lock = std.atomic.Value(bool).init(false);
var g_feed_watch_ids: [engagement_watch_cap]i64 = undefined;
var g_feed_watch_hex: [engagement_watch_cap][64]u8 = undefined;
var g_feed_watch_len: usize = 0;
/// Moves whenever the published set CHANGES, so a worker can tell "the feed grew
/// while I was reading" from "the same feed, redrawn". A redraw happens on every
/// tick; re-asking every relay four times a second is a different bug.
var g_feed_watch_gen = std.atomic.Value(u32).init(0);

fn lockFeedWatch() void {
    while (g_feed_watch_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockFeedWatch() void {
    g_feed_watch_lock.store(false, .release);
}

/// The view thread, after a feed rebuild. Newest first and bounded, which is
/// the order the feed is already in: what a reader is looking at is what its
/// counts are wanted for.
pub fn publishFeedWatch(notes: []const Note) void {
    lockFeedWatch();
    defer unlockFeedWatch();
    const n = @min(notes.len, engagement_watch_cap);
    var changed = n != g_feed_watch_len;
    for (notes[0..n], 0..) |note, i| {
        if (!changed and g_feed_watch_ids[i] != note.id) changed = true;
        g_feed_watch_ids[i] = note.id;
        hexLower(&g_feed_watch_hex[i], note.event_id);
    }
    g_feed_watch_len = n;
    if (changed) _ = g_feed_watch_gen.fetchAdd(1, .monotonic);
}

pub fn feedWatchGeneration() u32 {
    return g_feed_watch_gen.load(.monotonic);
}

/// Folds the published set into one worker's watch list, keeping what that
/// socket already knew. Returns the new length.
pub fn mergeFeedWatch(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: usize,
) usize {
    lockFeedWatch();
    defer unlockFeedWatch();
    var n = len;
    outer: for (0..g_feed_watch_len) |i| {
        if (n >= engagement_watch_cap) break;
        for (ids[0..n]) |seen| {
            if (seen == g_feed_watch_ids[i]) continue :outer;
        }
        ids[n] = g_feed_watch_ids[i];
        hex[n] = g_feed_watch_hex[i];
        n += 1;
    }
    return n;
}
fn subscribeEngagement(relay: *nostr.relay.Relay, hex: *const [engagement_watch_cap][64]u8, count: usize) void {
    if (count == 0) return;
    var evals: [engagement_watch_cap][]const u8 = undefined;
    for (0..count) |i| evals[i] = &hex[i];
    const eng_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = evals[0..count] }};
    const eng_filters = [_]nostr.filter.Filter{engagementFilter(&eng_tags)};
    relay.subscribe("plaza-engagement", &eng_filters) catch {};
}
/// One discovered relay's loop: dial, ask about the people who write there,
/// ingest, and redial when the connection drops or the table moves under it.
///
/// Deliberately thinner than the pool's loop. No publish, no latency probe, no
/// engagement subscription, no inbox: this connection exists to close one gap,
/// which is that a follow writing somewhere the reader is not would otherwise
/// never arrive at all.
pub fn discoveredRelayThread(gpa: std.mem.Allocator, index: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var attempts: u6 = 0;
    var url_buf: [96]u8 = undefined;
    var authors: [discovered_authors_cap][32]u8 = undefined;
    while (true) {
        const gen = routing.g_discovered_gen[index].load(.acquire);
        const snap = discoveredSnapshot(index, gen, &url_buf, &authors);
        if (snap == null or relaysPaused()) {
            attempts = 0;
            io.sleep(std.Io.Duration.fromSeconds(2), .awake) catch {};
            continue;
        }
        const opened_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        const url = url_buf[0..snap.?.url_len];
        discoveredOnce(gpa, io, signer, index, url, authors[0..snap.?.authors_len], gen) catch {};
        const lasted = std.Io.Timestamp.now(io, .awake).toMilliseconds() - opened_at;
        // The pool's ladder, and its guard: a relay that accepts the handshake
        // and drops the socket would otherwise reset the backoff on every
        // connection and redial in a tight loop forever.
        attempts = nextReconnectAttempts(attempts, lasted);
        // Unlike the pool, this slot can be spent elsewhere. A connection that
        // held is a relay that will have us; a run of short ones is a relay that
        // will not, and the slot is worth more on the next relay down.
        if (attempts == 0) {
            clearRelayRefusal(url);
        } else if (noteRelayRefusal(url)) {
            // Ask for a rethink rather than waiting for somebody's relay list
            // to land, which on a settled account may be never.
            routing.g_relay_ranks_dirty.store(true, .release);
        }
        const base = reconnectDelayMs(attempts);
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(base + reconnectJitterMs(base, index, attempts))), .awake) catch {};
    }
}

fn discoveredOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    signer: nostr.keys.Signer,
    index: usize,
    url: []const u8,
    authors: []const [32]u8,
    gen_in: u32,
) !void {
    const authors_len_in = authors.len;
    var relay = try nostr.relay.dial(gpa, io, url);
    // Declared after `deinit` so it runs before it: the keeper must have let go
    // of the pointer before the connection is freed.
    defer relay.deinit();
    offerLiveRelay(discovered_watch_base + index, relay);
    defer offerLiveRelay(discovered_watch_base + index, null);

    var filter_buf: [max_feed_filters]nostr.filter.Filter = undefined;
    try relay.subscribe(outbox_sub_id, buildRoutedFilters(authors[0..authors_len_in], &filter_buf));

    // The notes this relay carries, so their engagement can be watched HERE.
    //
    // The pool threads have done this since counts existed, and these have not,
    // and after the outbox landed these are the relays that carry most of the
    // feed. So a note routed here showed no replies, no likes and no zaps for as
    // long as it was on screen: the numbers only appeared once the note was
    // opened, because a thread fetches engagement on its own path, and then they
    // were in the table and the feed looked fine. That is why this reads as
    // "counts load late" rather than as "counts are missing".
    var feed_ids: [engagement_watch_cap]i64 = undefined;
    var feed_id_hex: [engagement_watch_cap][64]u8 = undefined;
    var feed_ids_len: usize = 0;
    var engagement_watching: usize = 0;
    var engagement_at: i64 = 0;
    var engagement_gen: u32 = 0;
    // Published only now, so the keeper never replaces a question that has not
    // been asked yet. Cleared on the way out, before the connection is freed.
    setRoutedLive(index, url, gen_in);
    defer clearRoutedLive(index);

    while (true) {
        if (relaysPaused()) return;
        // Widen as more of this relay's feed arrives, on the same rule the pool
        // threads use: a subscription opened once at EOSE leaves every note that
        // arrives afterwards reading zero forever.
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        // Two things can put a note in front of a reader without a count: one
        // arriving here, and one the view read out of the store. Both are asked
        // about, and the second is why this no longer waits for `watching > 0`:
        // a connection whose first EOSE found nothing had no way back to
        // watching anything at all, for the rest of its life.
        const watch_gen = feedWatchGeneration();
        if (now_ms - engagement_at > engagement_widen_ms and
            (watch_gen != engagement_gen or feed_ids_len > engagement_watching))
        {
            feed_ids_len = mergeFeedWatch(&feed_ids, &feed_id_hex, feed_ids_len);
            engagement_gen = watch_gen;
            if (feed_ids_len > 0) {
                subscribeEngagement(relay, &feed_id_hex, feed_ids_len);
                engagement_watching = feed_ids_len;
                engagement_at = now_ms;
            }
        }
        // The slot was pointed at a DIFFERENT relay. Nothing here is worth
        // keeping, so drop it and let the loop dial whatever the slot holds now.
        //
        // A change of WHO is not checked here and must not be: this thread only
        // reaches this line when the relay says something, and a relay with
        // nothing to say says nothing. The keeper replaces the question on the
        // live socket instead.
        if (!routedSlotStillNames(index, url)) return;
        var msg = (relay.receive() catch return) orelse return;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| {
                if (std.mem.eql(u8, e.subscription_id, outbox_sub_id)) {
                    // Verified before it is stored. This is a relay the reader
                    // never chose, reached because a follow named it, so it gets
                    // less trust than the pool rather than more.
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch continue;
                    if (result == .invalid) continue;
                    if (e.event.kind == 1) {
                        noteFeedNewest(e.event.created_at);
                        rememberFeedId(&feed_ids, &feed_id_hex, &feed_ids_len, e.event);
                    }
                } else {
                    // The engagement subscription. Verified too, so a forged
                    // reaction cannot inflate a tally.
                    if (nostr.event.verify(gpa, signer, e.event) catch false) {
                        countEngagement(e.event, feed_ids[0..feed_ids_len]);
                    }
                }
            },
            .eose => |eo| {
                // What this relay had, drained: now watch those notes.
                if (engagement_watching == 0 and std.mem.eql(u8, eo.subscription_id, outbox_sub_id)) {
                    feed_ids_len = mergeFeedWatch(&feed_ids, &feed_id_hex, feed_ids_len);
                    engagement_gen = feedWatchGeneration();
                    if (feed_ids_len > 0) {
                        subscribeEngagement(relay, &feed_id_hex, feed_ids_len);
                        engagement_watching = feed_ids_len;
                        engagement_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
                    }
                }
            },
            .closed => return,
            else => {},
        }
    }
}

/// One relay's ingest loop: dial, serve, and reconnect after a widening delay,
/// forever.
pub fn ingestRelay(gpa: std.mem.Allocator, index: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Connections in a row that did not last `stable_connection_ms`.
    var attempts: u6 = 0;
    // The address last dialled, so re-pointing a slot starts a clean ladder
    // instead of inheriting the previous relay's failures. Fixing a typo in a
    // relay URL should take effect now, not in five minutes.
    var tried_buf: [96]u8 = undefined;
    var tried_len: usize = 0;

    while (true) {
        // An empty slot is not an error: it is a seat kept for a relay the
        // reader may add. It costs a sleeping thread and nothing else.
        if (relayAt(index) == null) {
            setRelayStatus(index, .offline);
            attempts = 0;
            tried_len = 0;
            io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            continue;
        }
        // A paused pool never dials. The reader still has the whole store, so
        // pausing costs them nothing but the live tail.
        if (relaysPaused()) {
            setRelayStatus(index, .offline);
            attempts = 0;
            io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            continue;
        }
        var url_buf: [96]u8 = undefined;
        if (relaySnapshot(index, &url_buf)) |now| {
            if (!relayUrlEql(now.url, tried_buf[0..tried_len])) {
                attempts = 0;
                tried_len = now.url.len;
                @memcpy(tried_buf[0..tried_len], now.url);
            }
        }
        setRelayStatus(index, .connecting);
        const opened_at = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        ingestOnce(gpa, io, signer, index) catch |err| {
            std.debug.print("plaza: [{s}] {s}\n", .{ relayUrlAt(index), @errorName(err) });
        };
        setRelayStatus(index, .offline);
        clearRelayRtt(index);
        const lasted = std.Io.Timestamp.now(io, .awake).toMilliseconds() - opened_at;
        attempts = nextReconnectAttempts(attempts, lasted);
        const wait = reconnectDelayMs(attempts);
        const spread = reconnectJitterMs(wait, index, attempts);
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(wait + spread)), .awake) catch {};
    }
}
/// Dials relay `index`, subscribes for recent kind:1, and ingests each event
/// into the shared store until the connection closes.
fn ingestOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, index: usize) !void {
    // Read fresh each time round: the reader may have changed this slot's URL,
    // or emptied it, since the last dial.
    var url_buf: [96]u8 = undefined;
    const entry = relaySnapshot(index, &url_buf) orelse return error.RelayRemoved;
    const url = entry.url;
    const reads = entry.read;
    var relay = try nostr.relay.dial(gpa, io, url);
    // Withdrawn BEFORE the connection is freed, and the defers unwind in
    // reverse, so this one is declared second and runs first. The other order
    // hands the keeper a pointer to a `Relay` that is already gone.
    defer relay.deinit();
    offerLiveRelay(index, relay);
    defer offerLiveRelay(index, null);
    setRelayStatus(index, .connected);

    // NIP-42, for this connection. The slot is wiped on the way in and on the
    // way out: a challenge belongs to the socket that heard it, and a notice
    // left standing for a socket that is gone would be asking about nothing.
    var auth = AuthSession{ .index = index };
    authSlotReset(index);
    defer authSlotReset(index);

    // Follow-scoped: the starter pack's recent notes for the feed, plus their
    // kind:0 metadata (and the user's own) so the feed can show real names and
    // avatars. Two filters share one subscription.
    var authors: [max_follows + 1][32]u8 = undefined;
    // Snapshotted, not borrowed: `followSet` hands back a slice of a table the
    // UI thread rewrites when a follow lands, and this filter outlives the frame.
    // Not every follow: the ones who write HERE, plus everyone no relay in
    // either set is being asked about. See `fillPoolRoutes`.
    //
    // Before the routing existed this was the whole follow list on all eight
    // relays, which asked every relay about two thousand strangers and told
    // each of them the reader's entire social graph.
    var authors_len: usize = poolAuthorsOrAll(index, &authors);
    // The generation this subscription was built for. When it moves, this
    // connection is asking the wrong question and re-asks below.
    var subscribed_gen = followGeneration();
    // Set to the generation already served by `subscribeInbox` at dial below,
    // so the loop does not immediately re-issue what was just sent.
    var inbox_gen = identityGeneration();
    // WHO this subscription asked about, if anyone. A connection dialed while
    // signed out did not ask about the reader, and its EOSE is not an answer
    // about them. Read once, so the filter and the record of what it asked
    // cannot name two different accounts across a sign-in.
    var asked_about: ?[32]u8 = activePubkey();
    if (asked_about) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    // Two filters per chunk of authors, all in ONE REQ.
    //
    // `authors_len` INCLUDES the reader. An earlier version took the snapshot
    // BEFORE appending the reader's own key, so a note written anywhere but this
    // install was never fetched from any relay: the feed reads your own notes
    // from the store and the store never had them. Signing in with an existing
    // key showed a feed with none of your own writing in it, and every
    // notification about those notes pressed into nothing, because the note it
    // pointed at was not held.
    //
    // The chunking is a payload split and nothing more. A relay answers every
    // filter in a REQ, so five filters of five hundred authors ask the same
    // question as one filter of two and a half thousand, in an envelope relays
    // actually accept. The per-chunk limit stays whole for the same reason:
    // dividing it would starve whoever landed in the last chunk.
    var filter_buf: [max_feed_filters]nostr.filter.Filter = undefined;
    // The reader's key for their own filters, owned by this connection.
    var self_author: [1][32]u8 = undefined;
    if (asked_about) |pk| self_author[0] = pk;
    const filters = buildFeedFilters(authors[0..authors_len], if (asked_about != null) &self_author else null, feedSince(), &filter_buf);
    // What other people aimed at this reader. Its own subscription, never folded
    // into the feed's: a relay that is handed two differently-scoped filters in
    // one REQ may answer the stored query and then go quiet, which is the worst
    // failure mode to notice.
    if (reads) subscribeInbox(relay);

    // A relay marked write-only is not asked anything. It keeps its socket, so a
    // note goes out the moment it is written, but no filter of this reader's
    // ever reaches it: that is the whole difference the badge promises.
    // The feed's id carries the generation it was asked under. A REQ re-issued
    // under the SAME id cannot be told apart from the one it replaced, and the
    // one it replaced may still be answering: the subscription sent as a guest
    // at launch is usually still in flight when the account signs in, and its
    // end-of-stored-events would then be read as this relay having finished with
    // the reader's own lists before it had sent them. See `isFeedSub`.
    var feed_sub_buf: [32]u8 = undefined;
    var feed_sub: []const u8 = feed_sub_base;
    if (reads) try relay.subscribe(feed_sub, filters);

    // Latency is measured with a PROBE, never with the subscriptions above: the
    // feed REQ asks for a 300-note backlog plus profiles, so timing it measures
    // how much this relay had to send, not how fast it answers. The probe asks
    // for an id that cannot exist, so the answer is an empty EOSE and the number
    // is the round trip and nothing else. Re-sent periodically so it stays live,
    // and CLOSED as soon as it answers. The AWAKE clock, so a system clock step
    // cannot swing a reading.
    var probe_at: i64 = 0;
    var probed_at: i64 = 0;

    // The loaded notes' ids (and their hex), collected from the feed as it
    // arrives. On the feed's EOSE a second subscription opens for their
    // engagement, so counts fold in alongside the feed on the same connection,
    // and it is widened as more notes load.
    var feed_ids: [engagement_watch_cap]i64 = undefined;
    var feed_id_hex: [engagement_watch_cap][64]u8 = undefined;
    var feed_ids_len: usize = 0;
    // How many of those ids the engagement subscription currently names, and
    // when it was last (re)issued.
    var engagement_watching: usize = 0;
    var engagement_at: i64 = 0;
    var engagement_gen: u32 = 0;

    while (true) {
        // A pause takes effect within a wake: the thread returns, `defer
        // relay.deinit()` closes the socket, and the reconnect loop parks. The
        // chip still says "pausing" until every thread has actually left rather
        // than claiming a pause it has not achieved, because a thread mid-frame
        // finishes the frame first.
        if (relaysPaused()) return;
        // The same for an edit. Removing a relay, or clearing its read marker,
        // must end THIS connection: leaving the socket up until the next
        // reconnect would keep a relay the reader dropped feeding the store, and
        // keep a relay they set write-only answering their filters. Checked
        // against the address dialed, so a slot that changed hands also drops.
        var now_buf: [96]u8 = undefined;
        const now_entry = relaySnapshot(index, &now_buf) orelse return;
        if (!relayUrlEql(now_entry.url, url)) return;
        if (now_entry.read != reads) return;
        // Following someone changes what this connection should be asking for.
        // NIP-01 makes a REQ under an existing id a replacement, so the same
        // subscription is simply re-issued: without this a follow shows nothing
        // new until the socket happens to drop, which reads as a broken button.
        // A follow OR an identity change: `forgetFollows` bumps the same
        // counter on sign-out and sign-in, because a connection built for a
        // guest never asks for the account's own records and would otherwise
        // leave following disabled for the whole session.
        if (reads and followGeneration() != subscribed_gen) {
            subscribed_gen = followGeneration();
            authors_len = poolAuthorsOrAll(index, &authors);
            var next_authors_len = authors_len;
            const next_self = activePubkey();
            asked_about = null;
            if (next_self) |pk| {
                if (next_authors_len < authors.len) {
                    authors[next_authors_len] = pk;
                    next_authors_len += 1;
                    asked_about = pk;
                }
            }
            // Built by the SAME function the dial-time subscription uses.
            //
            // This path used to hand-roll its own pair of filters, and both of
            // the things `buildFeedFilters` exists to prevent came back with it:
            // every author named in ONE filter, which is past the size several
            // relays accept once a real follow list is loaded, and a metadata
            // limit taken from `profile_cap`, which is the size of a screen
            // cache and has nothing to do with how many records to ask for.
            //
            // It mattered more here than anywhere, because this is the path
            // every reader takes: Plaza dials before anyone has signed in, so
            // the subscription that carries the actual account is always the
            // re-issued one, never the one built at dial.
            if (next_self) |pk| self_author[0] = pk;
            const next_filters = buildFeedFilters(authors[0..next_authors_len], if (next_self != null) &self_author else null, feedSince(), &filter_buf);
            // Closed and asked again under a new id, rather than replaced in
            // place, so the old question's answers stay its own.
            relay.unsubscribe(feed_sub) catch {};
            feed_sub = std.fmt.bufPrint(&feed_sub_buf, feed_sub_base ++ "-{d}", .{subscribed_gen}) catch feed_sub_base;
            relay.subscribe(feed_sub, next_filters) catch {};
            // The inbox rides the SAME signal, and for a reason the feed's own
            // comment above already explains: this counter moves on sign-in.
            // Asking only at dial was the whole feature's undoing, because Plaza
            // opens as a guest and dials every relay BEFORE anyone has signed in.
            // The bell then read zero for the entire session, on a healthy
            // connection, no matter who replied. Re-issuing here is also what
            // heals a REQ that failed to send, and what stops a socket carrying
            // the previous account's filter after a switch.
        }
        // The inbox rides its own generation: its filter names ONE pubkey, the
        // reader's, so a contact-list change has nothing to do with it.
        if (reads and identityGeneration() != inbox_gen) {
            inbox_gen = identityGeneration();
            subscribeInbox(relay);
        }
        // A signature that has come back is sent from here and nowhere else:
        // this thread owns the socket's conversation, and the UI thread that got
        // the signature never touches it. A relay set write-only is not asked
        // anything, so it has nothing an identity would unlock.
        if (reads) {
            const awake_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
            if (authPoll(&auth, url, relay, awake_ms, identityGeneration()) == .redial) return error.FeedSubscriptionClosed;
        }
        // With a deadline, so the checks above actually run on a quiet relay.
        //
        // Without one this loop only advances when the relay speaks, so a relay
        // the reader removed, repointed or set write-only kept its socket and
        // kept feeding the store until it happened to say something. A relay
        // that says nothing for an hour held one for an hour. `nostr#64`.
        //
        // A timeout consumes nothing, so `continue` here resumes on the same
        // connection rather than resynchronising: the wait is a readiness check
        // on the socket, not a read. Cutting the socket to achieve the same
        // thing would not do: `shutdown` over TLS poisons the session, and this
        // one is also carrying the inbox and engagement subscriptions.
        var msg = (relay.receiveTimeout(ingest_wake) catch |err| switch (err) {
            error.Timeout => continue,
            else => |e| return e,
        }) orelse break;
        defer msg.deinit();

        // Time to re-probe? The probe rides the next message rather than a
        // timer; a relay too quiet to carry one is also a relay whose latency
        // nobody is waiting on.
        //
        // A write-only relay is probed too: a question about one id that does
        // not exist, which says nothing about who this reader follows or reads,
        // and its answer is the latency shown beside a relay they do use.
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        // A challenge, a refusal for want of one, or the verdict on our reply.
        // None of these is the end of a subscription: a CLOSED for auth is the
        // relay saying "not yet", and the feed it refused is asked again once
        // the relay has accepted us. Without this arm the refused feed ended the
        // connection and the reconnect ladder went round again, forever, without
        // ever answering the challenge that was the reason.
        if (reads) {
            const react = authReact(&auth, url, msg.value, now_ms);
            if (react.handled) {
                switch (msg.value) {
                    .closed => |c| {
                        std.debug.print("plaza: [{s}] closed {s}: {s}\n", .{ url, c.subscription_id, c.message });
                        if (std.mem.eql(u8, c.subscription_id, probe_sub)) probe_at = 0;
                    },
                    else => {},
                }
                // Moving the generation is how this loop already re-asks a
                // subscription, so the refused ones are re-sent by the same
                // code that built them rather than by a copy of it.
                if (react.resend.feed) subscribed_gen -%= 1;
                if (react.resend.inbox) inbox_gen -%= 1;
                if (react.resend.engagement) {
                    engagement_watching = 0;
                    engagement_at = 0;
                }
                continue;
            }
        }
        if (probe_at == 0 and (probed_at == 0 or now_ms - probed_at > probe_interval_ms)) {
            const probe_filters = probeFilters();
            if (relay.subscribe(probe_sub, &probe_filters)) |_| {
                probe_at = now_ms;
                probed_at = now_ms;
            } else |_| {}
        }
        // Widen the engagement subscription as more of the feed loads. It used
        // to be opened once per connection over whatever had arrived by the
        // feed's EOSE and never touched again, so every note past that point
        // read zero likes, zero replies and zero zaps for the whole session, and
        // so did every note that arrived live.
        //
        // And it asked only about arrivals, which left every note the view read
        // out of the store unwatched. That is most of the feed on any launch but
        // the first. Both sources are folded in here now, and the "already
        // watching" guard is gone with them: a connection whose first EOSE found
        // nothing had no way back to watching anything for the rest of its life.
        const watch_gen = feedWatchGeneration();
        if (now_ms - engagement_at > engagement_widen_ms and
            (watch_gen != engagement_gen or feed_ids_len > engagement_watching))
        {
            feed_ids_len = mergeFeedWatch(&feed_ids, &feed_id_hex, feed_ids_len);
            engagement_gen = watch_gen;
            if (feed_ids_len > 0) {
                subscribeEngagement(relay, &feed_id_hex, feed_ids_len);
                engagement_watching = feed_ids_len;
                engagement_at = now_ms;
            }
        }
        switch (msg.value) {
            .event => |e| {
                if (std.mem.eql(u8, e.subscription_id, "plaza-inbox")) {
                    // Verified before it counts: a relay can send anything down
                    // any subscription, and an inbox is the one surface where a
                    // stranger chooses what the reader sees.
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch continue;
                    if (result == .invalid) continue;
                    if (inboxAdd(e.event, nowSeconds())) markInboxDirty();
                    continue;
                }
                if (isFeedSub(e.subscription_id)) {
                    // Verify (secp256k1) before storing; silently drop a bad event.
                    // `.invalid` is a RETURNED VALUE here, not an error: a
                    // forged event does not throw, it comes back saying it did
                    // not verify. Reading only the error channel let a relay
                    // hand this reader a relay list signed by nobody.
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch continue;
                    if (result == .invalid) continue;
                    // Note which relay carried it, so a thread can say how widely
                    // a note is held rather than guess.
                    if (e.event.kind == 1) {
                        markRelaySeen(noteIdOf(e.event), index);
                        // What the next subscription will start from.
                        noteFeedNewest(e.event.created_at);
                    }
                    if (e.event.kind == relay_list_kind) ingestRelayList(e.event);
                    if (e.event.kind == contact_list_kind) ingestContactList(e.event);
                    // Note this feed post so its engagement can be watched. Bounded
                    // to keep the `#e` filter a size relays accept.
                    if (e.event.kind == 1) rememberFeedId(&feed_ids, &feed_id_hex, &feed_ids_len, e.event);
                } else if (isOneShotSub(e.subscription_id)) {
                    // Somebody else's question, answered on this socket. It goes
                    // to the store like everything else and nothing is routed
                    // back, which is exactly why the socket can be shared: there
                    // is no caller waiting on a reply.
                    //
                    // This branch has to exist before anything uses `askPool`.
                    // Without it a one-shot's events fall into the engagement
                    // arm below and every profile fetched gets counted as
                    // somebody reacting to a note.
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch continue;
                    if (result == .invalid) continue;
                    if (e.event.kind == 1) noteFeedNewest(e.event.created_at);
                } else {
                    // The engagement subscription: fold into the counts, verified
                    // so a forged reaction cannot inflate a tally.
                    if (nostr.event.verify(gpa, signer, e.event) catch false) countEngagement(e.event, feed_ids[0..feed_ids_len]);
                }
            },
            .eose => |eo| {
                if (std.mem.eql(u8, eo.subscription_id, probe_sub) and probe_at != 0) {
                    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - probe_at;
                    if (elapsed >= 0) recordRelayRtt(index, @intCast(@min(elapsed, std.math.maxInt(u16))));
                    probe_at = 0;
                    // Answered, so close it. A REQ stays live past EOSE, and the
                    // question has been answered: leaving it open is how the
                    // probe became a standing subscription on every relay.
                    relay.unsubscribe(probe_sub) catch {};
                }
                // A one-shot has been answered. Close it: a REQ stays live past
                // EOSE, and leaving them open is how the latency probe became a
                // standing subscription on every relay in the pool.
                //
                // Closed HERE, on the thread that owns the socket, and never
                // before EOSE: relays dislike a CLOSE for a subscription they
                // are still answering, which NDK's source says in as many words.
                if (isOneShotSub(eo.subscription_id)) relay.unsubscribe(eo.subscription_id) catch {};
                if (isFeedSub(eo.subscription_id)) {
                    // Only when THIS subscription actually asked about the
                    // reader. A guest-era filter names nine strangers, and its
                    // EOSE says nothing at all about the account that signed in
                    // afterwards. Nor is the EOSE of a generation this one
                    // replaced, and nor is an answer about an account that is
                    // no longer the one signed in: the identity can change
                    // between the check at the top of this loop and here.
                    if (asked_about) |asked| {
                        if (activePubkey()) |me| {
                            // Who they follow, recorded against THIS relay.
                            // EOSE means "that is all I have", never "you have
                            // none": one relay that does not carry this list
                            // must not be able to authorize replacing it.
                            if (std.mem.eql(u8, &asked, &me) and std.mem.eql(u8, eo.subscription_id, feed_sub)) {
                                noteContactsAnsweredBy(index, url, me);
                            }
                        }
                    }
                }
                // Stored feed drained: now watch those notes' engagement, plus
                // whatever the view is drawing out of the store.
                if (engagement_watching == 0 and isFeedSub(eo.subscription_id)) {
                    feed_ids_len = mergeFeedWatch(&feed_ids, &feed_id_hex, feed_ids_len);
                    engagement_gen = feedWatchGeneration();
                    if (feed_ids_len > 0) {
                        subscribeEngagement(relay, &feed_id_hex, feed_ids_len);
                        engagement_watching = feed_ids_len;
                        engagement_at = now_ms;
                    }
                }
            },
            .closed => |c| {
                // A relay saying no. NIP-01's CLOSED carries a reason, and
                // dropping it on the floor is what made a refused subscription
                // indistinguishable from a quiet one: a green chip, "Live", and
                // nothing arriving, for the rest of the connection, with no
                // retry and nothing written down.
                std.debug.print("plaza: [{s}] closed {s}: {s}\n", .{ url, c.subscription_id, c.message });
                if (std.mem.eql(u8, c.subscription_id, probe_sub)) {
                    // Only the latency reading is lost. Clear the pending sample
                    // so the next message asks again rather than waiting forever
                    // for an EOSE that is not coming.
                    probe_at = 0;
                } else if (std.mem.eql(u8, c.subscription_id, feed_sub)) {
                    // The feed is what this connection is FOR, so end it and let
                    // the reconnect ladder decide when to ask again. A relay that
                    // refuses this filter now will usually refuse it in three
                    // seconds too, which is exactly why that delay widens.
                    return error.FeedSubscriptionClosed;
                }
                // The inbox and the engagement subscription are refused on their
                // own terms. Either one is worth reporting and neither is worth
                // tearing down a working feed for.
            },
            else => {},
        }
    }
}

pub fn rememberFeedIdForTest(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: *usize,
    ev: nostr.event.Event,
) void {
    rememberFeedId(ids, hex, len, ev);
}

pub fn publishFeedWatchForTest(notes: []const Note) void {
    publishFeedWatch(notes);
}

pub fn mergeFeedWatchForTest(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: usize,
) usize {
    return mergeFeedWatch(ids, hex, len);
}

pub fn feedWatchGenerationForTest() u32 {
    return feedWatchGeneration();
}

//! Live connection state: status per relay, seats for live and one-shot relays, pause, and latency probes.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const followRouteChanges = main.followRouteChanges;
const max_discovered_relays = main.max_discovered_relays;
const max_relays = main.max_relays;
const nowSeconds = main.nowSeconds;
const outboxLock = main.outboxLock;
const outboxUnlock = main.outboxUnlock;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;

/// A relay slot's connection state.
///
/// `quiet` is the state this app used to be unable to express, and the reason a
/// green dot could be a lie: the socket is open, nothing has come down it for a
/// while, and a ping is out with no answer yet. It is not offline, because
/// nothing has failed; it is not plainly connected either, because the last
/// evidence of that is a minute old. Every shipping client the pool was
/// compared against has exactly two states here and shows the same green dot
/// over a half-open socket, so this is not a bug being fixed so much as a lie
/// being stopped.
pub const Conn = enum(u8) { connecting = 0, connected = 1, offline = 2, quiet = 3 };
// One connection state per relay in the pool, flipped by that relay's ingest
// thread and read by the UI thread to summarise the pool.
pub var g_relay_status = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(@intFromEnum(Conn.connecting))} ** max_relays;

/// Whether a slot holds a socket, whatever the socket is doing. A relay that has
/// gone quiet has not dropped: nothing has failed, and counting it as offline
/// would put the whole app behind an "offline, reconnecting" banner because the
/// night was slow.
pub fn connHolds(state: Conn) bool {
    return state == .connected or state == .quiet;
}
/// Sets relay `index`'s live connection state.
pub fn setRelayStatus(index: usize, state: Conn) void {
    const was: Conn = @enumFromInt(g_relay_status[index].load(.monotonic));
    g_relay_status[index].store(@intFromEnum(state), .monotonic);
    // A relay coming back is the event a queued note has been waiting for. The
    // backoff was only ever reset by editing the relay list, so a note that had
    // widened out to an hourly retry stayed on that schedule even when the
    // network returned a second later.
    //
    // Coming back from QUIET does not count. A relay answering the keepalive it
    // was sent is not news about the network, it is news about that one socket,
    // and treating it as a recovery would let a quiet pool reset the queue's
    // ladder every minute forever.
    if (state == .connected and was != .connected and was != .quiet) wakeOutboxBackoff();
}

// -- Knowing a socket is still there -----------------------------------------
//
// A relay's ingest thread blocks in `receive` until the relay says something.
// If the peer goes away without closing, that thread waits forever and the chip
// stays green: no error, no timeout, no reconnect. Nothing in this app could
// tell that apart from a quiet night.
//
// Nothing can tell it apart from inside that thread either, which is the whole
// difficulty. A thread waiting on a dead peer cannot notice anything. So a
// separate one watches the pool: it sends the ping, and it is the one that can
// still act when no answer comes.
//
// When to ping and when to give up is `nostr.liveness`, which is where those
// numbers belong: they were the same numbers in this app and in Notary, written
// down in neither. They are Amethyst's, from their survey of 122 relays.
//
// The table below and the thread that ticks stay here. What "give up" means
// differs between a client and a signer, and only the policy is shared.

//// How often an ingest thread comes up for air to re-read its own slot.
///
/// This is not a keepalive and has nothing to do with the numbers above: it is
/// how long a relay the reader just removed, repointed or set write-only can go
/// on feeding the store. A second is under the time it takes to notice, and
/// costs one readiness check per socket per second.
pub const ingest_wake: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1_000), .clock = .awake } };

// The live connection for each slot, for the keeper and nothing else.
///
/// Published by the thread that dialled it and cleared by that same thread
/// before the connection is freed, both under the slot's lock, and the keeper
/// holds that lock for as long as it touches the pointer. Without it the keeper
/// can be inside `ping` on a `Relay` whose owner has already returned and run
/// its `deinit`.
/// One per pool slot, plus one for the bunker listener.
///
/// The listener is not a pool relay (it is not in the reader's list, it is not
/// published to, it has no badge) but it is the same kind of thing: a socket
/// held open indefinitely by a thread blocked in `receive`. When it half-opens,
/// remote signing stops working with no error anywhere, which is the worst way
/// for a signer to fail.
pub const relay_watch_slots = max_relays + 1 + max_discovered_relays;
pub const bunker_watch_slot = max_relays;
/// The discovered connections sit past the pool and the bunker. They are
/// watched the same way and deliberately have no entry in the pool's status
/// table: they are not the reader's relays, they are where the reader's follows
/// turned out to be, and a chip claiming otherwise would be a lie about whose
/// list this is.
pub const discovered_watch_base = max_relays + 1;

pub var g_relay_live: [relay_watch_slots]?*nostr.relay.Relay = @splat(null);
var g_relay_live_lock: [relay_watch_slots]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false));
/// When each slot was last pinged, so a socket that stops answering is pinged
/// once per interval rather than once per keeper tick.
var g_relay_pinged_ms: [relay_watch_slots]i64 = @splat(0);

pub fn lockLiveRelay(index: usize) void {
    while (g_relay_live_lock[index].cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockLiveRelay(index: usize) void {
    g_relay_live_lock[index].store(false, .release);
}

/// Offers this slot's connection to the keeper, or withdraws it. The owning
/// thread calls this with the connection on the way in and with null on the way
/// out, BEFORE the connection is freed.
///
/// Named "offer", not "publish". It hands over a POINTER; nothing here sends
/// anything to a relay, and a name that reads as publishing an event on a code
/// path near a signing key is the kind of thing that gets misread once and then
/// trusted.
pub fn offerLiveRelay(index: usize, relay: ?*nostr.relay.Relay) void {
    lockLiveRelay(index);
    defer unlockLiveRelay(index);
    g_relay_live[index] = relay;
    g_relay_pinged_ms[index] = 0;
}

// -- A question that cannot be asked forever ---------------------------------
//
// Every fetch that is not the feed dials its own socket, asks one question and
// reads until EOSE. `receive` has no deadline, so a relay that accepts the REQ
// and then goes quiet holds that thread for the life of the process. Several of
// these loops are bounded by a message COUNT, which does not help at all: a
// relay that sends nothing never reaches the count either.
//
// The keeper already watches the pool's sockets and already knows how to
// half-close one. A one-shot registers with it under a deadline and gets the
// same treatment for the same reason: the thread that would notice is the
// thread that is blocked.
//
// The deadline is ABSOLUTE, not idle. A fetch is a question with an answer, not
// a conversation, so what needs bounding is how long the whole exchange may
// take. A relay dribbling one event every few seconds forever is exactly as
// stuck as one sending nothing, and an idle deadline would never fire on it.
//
// This does NOT stop a one-shot dialling its own socket, which is the other
// half of the finding and a larger change: the eight pool threads already hold
// connections these questions could go down, and no answer needs routing back
// because every event reaches the render thread through the store either way.
// Worth doing, and not this.
pub const one_shot_slots = 16;
/// Per relay, not per fetch. A fetch walks the pool one relay at a time, so a
/// whole sweep can still take several of these; what it can no longer do is
/// take forever.
///
/// Eight seconds sits among what the reference clients allow one request:
/// welshman 3s, Amethyst 8s, NDK and Jumble 10s.
pub const one_shot_budget_ms: i64 = 8_000;
/// Written into a cut slot's deadline so the keeper does not cut the same
/// socket again on every tick until its owner notices. The owner clears it.
pub const one_shot_already_cut: i64 = std.math.maxInt(i64);

var g_oneshot_lock = std.atomic.Value(bool).init(false);
pub var g_oneshot: [one_shot_slots]?*nostr.relay.Relay = @splat(null);
pub var g_oneshot_deadline: [one_shot_slots]i64 = @splat(0);

fn lockOneShot() void {
    while (g_oneshot_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn unlockOneShot() void {
    g_oneshot_lock.store(false, .release);
}

/// Puts `relay` under the keeper's deadline until `releaseOneShot`.
///
/// Returns null when the table is full, and the caller then runs unwatched
/// rather than not at all. Sixteen concurrent one-shots is more than this app
/// starts, and an unbounded read is bad where refusing to read is worse: it
/// would turn a busy moment into a blank profile.
pub fn watchOneShot(io: std.Io, relay: *nostr.relay.Relay, budget_ms: i64) ?usize {
    const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    lockOneShot();
    defer unlockOneShot();
    for (0..one_shot_slots) |i| {
        if (g_oneshot[i] != null) continue;
        g_oneshot[i] = relay;
        g_oneshot_deadline[i] = now + budget_ms;
        return i;
    }
    return null;
}

/// Takes the connection back out of the keeper's reach. MUST run before the
/// connection is freed. The keeper only ever holds the pointer under the lock,
/// and this takes the same lock, which is the whole reason it can never be
/// inside `shutdown` on a `Relay` that has already been deinit'd.
pub fn releaseOneShot(slot: ?usize) void {
    const i = slot orelse return;
    lockOneShot();
    defer unlockOneShot();
    g_oneshot[i] = null;
    g_oneshot_deadline[i] = 0;
}

/// Which one-shot slots have run out of time. Pure over the deadline table, so
/// what the keeper decides here can be asserted without a socket or a thread.
///
/// A slot already cut carries `one_shot_already_cut` and is not returned again:
/// its owner is on its way out, and shutting the same socket on every tick
/// until then is noise rather than safety.
pub fn expiredOneShots(now_ms: i64, out: *[one_shot_slots]usize) usize {
    var n: usize = 0;
    for (0..one_shot_slots) |i| {
        if (g_oneshot_deadline[i] == 0) continue;
        if (g_oneshot_deadline[i] == one_shot_already_cut) continue;
        if (now_ms < g_oneshot_deadline[i]) continue;
        out[n] = i;
        n += 1;
    }
    return n;
}

/// Watches every slot's connection for silence: pings one that has gone quiet,
/// and cuts off one that will not answer. Also holds the deadline on every
/// one-shot fetch, for the same reason and by the same means.
pub fn relayKeeper(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(nostr.liveness.tick_ms), .awake) catch {};
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        for (0..relay_watch_slots) |i| {
            lockLiveRelay(i);
            defer unlockLiveRelay(i);
            const relay = g_relay_live[i] orelse continue;
            const idle = relay.idleMs(io);
            const since_ping: ?i64 = if (g_relay_pinged_ms[i] == 0) null else now - g_relay_pinged_ms[i];
            switch (nostr.liveness.action(idle, since_ping)) {
                .leave_it => {},
                .ping => {
                    // A failed write is not a verdict on its own; the silence
                    // deadline is. Letting a write error tear the socket down
                    // here would race the owning thread's own error handling.
                    relay.ping(io) catch {};
                    g_relay_pinged_ms[i] = now;
                    // The bunker listener has no chip and no slot in the pool's
                    // status table; it is watched, not displayed.
                    if (i < max_relays) setRelayStatus(i, .quiet);
                },
                .give_up => {
                    // Half-close, so the owner's blocked `receive` returns and
                    // it reconnects through its own path. NOT deinit: the owner
                    // still holds this and has to unwind.
                    relay.shutdown(io);
                    g_relay_live[i] = null;
                    g_relay_pinged_ms[i] = 0;
                    if (i < max_relays) setRelayStatus(i, .offline);
                },
            }
        }

        // Routed sockets whose slot moved while they were blocked reading.
        followRouteChanges(io);

        // And the one-shots. Same means, different clock: those above are idle
        // deadlines on a standing connection, these are absolute deadlines on
        // an exchange that is supposed to end.
        {
            lockOneShot();
            defer unlockOneShot();
            var expired: [one_shot_slots]usize = undefined;
            const n = expiredOneShots(now, &expired);
            for (expired[0..n]) |i| {
                const relay = g_oneshot[i] orelse continue;
                relay.shutdown(io);
                // Left in the table on purpose. Clearing it here would let the
                // slot be handed to another fetch while this one's owner still
                // holds the pointer; the owner clears it on the way out.
                g_oneshot_deadline[i] = one_shot_already_cut;
            }
        }
    }
}

/// How often a returning relay may pull the queue's backoff back to zero.
///
/// A relay that accepts the handshake and drops the socket reconnects every
/// three seconds, and without this each of those would reset every note to an
/// immediate retry: the widening delay would never widen and a dead relay would
/// be dialled continuously. Amethyst has the same guard for the same reason.
const outbox_wake_min_s: i64 = 60;
pub var g_outbox_woke_at: std.atomic.Value(i64) = .init(0);
/// Whether a wake has happened at all. A separate flag rather than a zero
/// sentinel, because zero is a real timestamp: `nowSeconds` returns it whenever
/// there is no io, and a rate limit that stops working at a particular clock
/// value is not a rate limit.
pub var g_outbox_woke_ever = std.atomic.Value(bool).init(false);

/// Puts every unacked note back at the front of the retry ladder.
fn wakeOutboxBackoff() void {
    const now = nowSeconds();
    if (g_outbox_woke_ever.load(.monotonic) and
        now -| g_outbox_woke_at.load(.monotonic) < outbox_wake_min_s) return;
    g_outbox_woke_ever.store(true, .monotonic);
    g_outbox_woke_at.store(now, .monotonic);

    outboxLock();
    defer outboxUnlock();
    var changed = false;
    for (&main.g_outbox) |*e| {
        if (!e.used or e.acked != 0 or e.rounds == 0) continue;
        e.rounds = 0;
        changed = true;
    }
    if (changed) _ = main.g_outbox_rev.fetchAdd(1, .monotonic);
}

/// Whether the reader has paused the pool. Read by every relay thread between
/// reconnect attempts, so a pause takes hold without tearing a socket down
/// mid-message.
var g_relays_paused = std.atomic.Value(bool).init(false);

pub fn setRelaysPaused(paused: bool) void {
    g_relays_paused.store(paused, .monotonic);
}

pub fn relaysPaused() bool {
    return g_relays_paused.load(.monotonic);
}

/// A relay's round-trip time in milliseconds, sampled REQ to EOSE and kept as a
/// small ring so the bar can show a median rather than the last spike. Zero means
/// no sample yet.
const rtt_samples = 8;
/// The latency probe: a query whose round trip is the number the status bar
/// shows, and how often each relay is asked for it.
pub const probe_sub = "plaza-ping";
pub const probe_interval_ms: i64 = 20_000;

/// What the probe asks for: one event id that cannot exist.
///
/// The relay does an index lookup, finds nothing, and answers EOSE. That round
/// trip is the number the bar wants, and it costs one lookup and zero events.
///
/// It used to ask `{"kinds":[1],"limit":1}`: no authors, no since, no until, and
/// nothing ever closed it. A REQ stays live past EOSE, so every relay then
/// pushed Plaza every kind:1 it received, from anyone, for the life of the
/// connection. Each one was parsed, allocated and put through a full Schnorr
/// verify before being dropped for not being a note this reader is watching. It
/// also held a subscription slot on every relay permanently, and an unauthored
/// global request for all text notes is not a thing an ordinary client sends.
///
/// An all-zero id is a value no event can have: the id IS the hash, so having
/// one would mean holding a SHA-256 preimage of thirty-two zero bytes.
const probe_ids = [_][32]u8{[_]u8{0} ** 32};

/// The probe's REQ. One filter, naming only that id, capped at one event so even
/// a relay that answered it somehow could not turn the probe into a stream.
pub fn probeFilters() [1]nostr.filter.Filter {
    return .{.{ .ids = &probe_ids, .limit = 1 }};
}
var g_relay_rtt = [_][rtt_samples]std.atomic.Value(u16){[_]std.atomic.Value(u16){std.atomic.Value(u16).init(0)} ** rtt_samples} ** max_relays;
var g_relay_rtt_at = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(0)} ** max_relays;
pub fn recordRelayRtt(index: usize, ms: u64) void {
    if (index >= max_relays) return;
    const slot = g_relay_rtt_at[index].load(.monotonic) % rtt_samples;
    g_relay_rtt[index][slot].store(@intCast(@min(ms, std.math.maxInt(u16) - 1) + 1), .monotonic);
    g_relay_rtt_at[index].store(slot +% 1, .monotonic);
}

/// Forgets relay `index`'s samples. Called when it drops, so the bar never shows
/// a number measured on a connection that no longer exists.
pub fn clearRelayRtt(index: usize) void {
    if (index >= max_relays) return;
    for (&g_relay_rtt[index]) |*sample| sample.store(0, .monotonic);
}

/// Relay `index`'s median round trip, or null when it has never answered.
pub fn relayRttMs(index: usize) ?u16 {
    if (index >= max_relays) return null;
    var seen: [rtt_samples]u16 = undefined;
    var n: usize = 0;
    for (&g_relay_rtt[index]) |*sample| {
        const v = sample.load(.monotonic);
        if (v != 0) {
            seen[n] = v - 1;
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(u16, seen[0..n], {}, std.sort.asc(u16));
    return median(seen[0..n]);
}

/// The middle of a sorted run, averaging the two middles for an even count so a
/// four-sample reading is not silently the third-fastest.
fn median(sorted: []const u16) u16 {
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    return @intCast((@as(u32, sorted[mid - 1]) + @as(u32, sorted[mid])) / 2);
}
/// Prefix for a one-shot's subscription id, so the relay threads can recognise
/// one and close it at EOSE. Anything not the feed, the inbox or a one-shot is
/// the engagement subscription, and that dispatch is by prefix rather than by a
/// list of names precisely so a new question cannot land in the engagement
/// branch and be counted as somebody liking something.
pub const one_shot_sub_prefix = "plaza-ask-";

/// The feed subscription's id, and the prefix every re-issue of it carries.
pub const feed_sub_base = "plaza-feed";

/// Whether `sub_id` is the feed subscription under any of its generations. Its
/// events are stored whichever generation carried them; only the CURRENT one's
/// end-of-stored-events says the relay has answered the question now asked.
pub fn isFeedSub(sub_id: []const u8) bool {
    return std.mem.startsWith(u8, sub_id, feed_sub_base);
}
pub fn isOneShotSub(sub_id: []const u8) bool {
    return std.mem.startsWith(u8, sub_id, one_shot_sub_prefix);
}

/// Asks every READ relay in the pool one question, on the socket it already
/// holds. Returns how many were asked.
///
/// Does not wait, and has nothing to wait for: the answers arrive in the store.
/// A caller that needs to know when they have arrived watches the store, the
/// way the profile cache and the feed already do.
///
/// A REQ under an existing id REPLACES it (NIP-01), so re-asking the same
/// question costs one message and no CLOSE, and two batches of the same kind
/// cannot pile up subscriptions on a relay.
/// Which pool slots a one-shot question goes to: the ones that take reads.
///
/// Split out from the asking so it can be asserted. Inside `askPool` the choice
/// is invisible to a test: with no live socket every slot is skipped anyway, so
/// a test of "how many were asked" passes whether or not the read marker is
/// honoured, which is the assertion looking right for the wrong reason.
pub fn askableSlots(out: []usize) usize {
    var n: usize = 0;
    for (0..relaySlots()) |i| {
        if (n >= out.len) break;
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(i, &url_buf) orelse continue;
        // Asking a write-only relay to answer a filter is asking it the wrong
        // question. It keeps its socket, for publishing.
        if (!entry.read) continue;
        out[n] = i;
        n += 1;
    }
    return n;
}

pub fn askPool(sub_id: []const u8, filters: []const nostr.filter.Filter) usize {
    std.debug.assert(isOneShotSub(sub_id));
    var slots: [max_relays]usize = undefined;
    const n = askableSlots(&slots);
    var asked: usize = 0;
    for (slots[0..n]) |i| {
        // The lock is what stops the owning thread freeing this connection
        // while the REQ is being written onto it.
        lockLiveRelay(i);
        defer unlockLiveRelay(i);
        const relay = g_relay_live[i] orelse continue;
        relay.subscribe(sub_id, filters) catch continue;
        asked += 1;
    }
    return asked;
}
/// Whether this build may open a socket of its own accord.
///
/// False under `zig build test`, and not as tidiness. The feed's background
/// fetchers are reached from `reconcile`, so every test that reconciles was
/// spawning a thread and completing TLS handshakes against public relays. It
/// made the perf numbers a measurement of the network (a profiler found
/// `relay.dial` and `handshake` at the top of a run that was supposed to be
/// timing a feed rebuild), it made the suite slow and flaky, and it sent
/// traffic from every machine that ran the tests.
///
/// Comptime, so the shipped binary has no branch. Anything that genuinely needs
/// to exercise a fetcher should drive its ingest seam with an event, which is
/// what the tests that care already do.
pub fn networkAllowed() bool {
    return !builtin.is_test;
}

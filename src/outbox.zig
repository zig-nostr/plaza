//! The outbox: queued events, retries, and what survives a restart.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const relay_conn = @import("relay_conn.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const oneShotDeadline = main.oneShotDeadline;
const activePlace = main.activePlace;
const activePubkey = main.activePubkey;
const copyBounded = main.copyBounded;
const max_relays = main.max_relays;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const place_relay_cap = main.place_relay_cap;
const place_relays_cap = main.place_relays_cap;
const publishWorker = main.publishWorker;
const relayAt = main.relayAt;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const relayUrlEql = main.relayUrlEql;
const relay_list_kind = main.relay_list_kind;
const releaseOneShot = main.releaseOneShot;
const watchOneShot = main.watchOneShot;

// -------------------------------------------------------------------- the outbox
//
// What happens to a note between pressing Post and knowing it is somewhere else.
//
// Publishing used to be fire-and-forget: a detached thread dialled every relay,
// wrote the frame, read one message to flush it, and dropped the verdict. The
// note was in the local store, so the feed showed it, and whether it ever
// reached anyone was not a question the app could answer.
//
// Now every publish goes through a queue. Each entry names an event that is
// already in the store's own tables (we ingest what we sign) and carries one bit
// per relay: did that relay say OK. The queue is the app's answer to "is my note
// out there", the status bar reads it, and it survives a quit, because a note
// written on a train and lost on landing is the worst thing a client can do.
//
// The queue is small on purpose. It is not a retry engine for a broken network;
// it is a record of what has not been acknowledged yet, drained whenever a relay
// comes back.

/// One note on its way out.
pub const OutboxEntry = struct {
    used: bool = false,
    id: [32]u8 = [_]u8{0} ** 32,
    /// Where this note was written, kept so a retry minutes later still goes to
    /// the room it was written in and not to whichever one the reader has since
    /// walked into. Not persisted: a queue reloaded from disk has lost the room,
    /// and falls back to the reader's own relays, which is the safe direction to
    /// be wrong in.
    route: PlaceRoute = .none,
    /// Who signed the note this entry owes. A queue entry is a promise to ONE
    /// account, and the publisher, the counts and the popover all filter on it.
    ///
    /// Not persisted, and it does not need to be: `loadOutbox` already reads the
    /// event back out of the store to check it still exists, and the event
    /// carries its own author. Deriving it there keeps the on-disk format
    /// unchanged, so a queue written by an older build still loads.
    author: [32]u8 = [_]u8{0} ** 32,
    /// When it was queued, so the popover can say how long it has been waiting
    /// and the oldest entry can be dropped when the queue is full.
    queued_at: i64 = 0,
    /// One bit per pool relay: this relay answered OK.
    acked: u8 = 0,
    /// One bit per pool relay: this relay answered, and said no.
    refused: u8 = 0,
    /// How many times the publisher has walked the relays for this entry, so a
    /// note nobody will take stops asking rather than hammering forever.
    rounds: u8 = 0,
    /// Whether a publish walk is in flight for this entry right now.
    sending: bool = false,
    /// When the last walk started, so the next one waits.
    last_try_at: i64 = 0,

    /// How many relays have taken it.
    pub fn ackCount(self: OutboxEntry) usize {
        return @popCount(self.acked);
    }

    /// Where this note is, in the words the popover uses.
    pub fn state(self: OutboxEntry) OutboxState {
        if (self.acked != 0) return .sent;
        if (self.sending) return .sending;
        // A LABEL, not a verdict. The queue keeps offering this note; the word
        // only tells the reader it has been a while. It used to mean the app
        // had given up, which is the one thing a queue must not do silently.
        if (self.rounds >= rounds_before_stuck) return .stuck;
        return .queued;
    }
};

pub const OutboxState = enum { queued, sending, sent, stuck };

/// How long to wait before offering a note again, widening with each attempt so
/// a relay that is down is asked minutes apart rather than every second.
pub fn outboxRetryDelay(rounds: u8) i64 {
    return switch (rounds) {
        0 => 0,
        1 => 5,
        2 => 20,
        3 => 60,
        4 => 300,
        5 => 900,
        // Once an hour, forever. A relay that has been unreachable for an hour
        // may well come back tomorrow, and asking it hourly costs one dial.
        else => 3600,
    };
}

/// Set when a note could not be queued at all, so the reader is told rather than
/// left with a promise the app did not keep.
pub var g_outbox_overflow = std.atomic.Value(bool).init(false);

/// Room for a burst of posting without becoming a store of its own. A reader who
/// writes more than this while offline is past what a status bar can explain.
pub const outbox_cap = 16;
/// After how many failed rounds the popover starts calling a note stuck.
///
/// This used to be the point at which the queue GAVE UP. Six rounds on the old
/// ladder is about eleven and a half minutes, so closing a laptop lid for
/// twelve, or spending that long on a captive portal where TCP connects and TLS
/// does not, permanently abandoned every queued note. It was never offered
/// again for the life of the install, the count survived a restart, and sixteen
/// of them filled the queue so the account could never post from that install
/// again. The only escape was editing the relay list, which nobody would guess.
///
/// Now it only changes the word on the row. The note keeps being offered, on a
/// widening delay, for as long as the app is running.
pub const rounds_before_stuck = 6;

pub var g_outbox = [_]OutboxEntry{.{}} ** outbox_cap;
/// Bumped whenever the queue changes, so the UI thread can tell that the
/// publisher touched something without locking.
pub var g_outbox_rev = std.atomic.Value(u32).init(0);
/// The same tiny spinlock the pending-signature table uses, and for the same
/// reason: every critical section here is a handful of field writes or a
/// 16-slot scan and never touches IO, while `std.Io.Mutex` would drag a
/// per-thread `io` across threads that deliberately never share one.
var g_outbox_lock = std.atomic.Value(bool).init(false);

pub fn outboxLock() void {
    while (g_outbox_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn outboxUnlock() void {
    g_outbox_lock.store(false, .release);
}

/// Whether this entry belongs to whoever is signed in right now.
///
/// The three places that ACT on the reader's behalf ask this: what the publisher
/// sends, what the status bar counts, and what the popover lists. The bookkeeping
/// that runs over the whole array (`sweepOutbox`, `forgetOutboxAcks`,
/// `recordOutboxAck`, `markOutboxSending`) deliberately does not, because by the
/// time any of it runs the array holds one account's entries and nobody else's:
/// `syncOutboxOwner` hands the slots over when the account changes.
///
/// A queued note is a promise made to ONE account. Logging out does not empty
/// the queue, deliberately: `sweepOutbox` refuses to erase a note nobody has
/// taken, because that is the app destroying something the reader wrote, and a
/// logout is not a reason to break that promise. So the note stays, and stops
/// being walkable instead. Sign back in as its author and it resumes; sign in as
/// somebody else and it is not theirs to send, not theirs to be counted, and not
/// theirs to see.
///
/// Signed out, nothing is anybody's, which is why a null active key is false
/// rather than a wildcard.
fn outboxEntryIsMine(e: OutboxEntry) bool {
    const me = activePubkey() orelse return false;
    return std.mem.eql(u8, &me, &e.author);
}

/// Puts `id` in the queue, or returns the entry already there. The caller holds
/// the lock.
pub fn outboxEntryFor(id: [32]u8) ?*OutboxEntry {
    for (&g_outbox) |*e| {
        if (e.used and std.mem.eql(u8, &e.id, &id)) return e;
    }
    return null;
}

/// Queues a note we have just signed and stored. Returns false when the queue is
/// full of notes that have not been acknowledged, which is a state the reader can
/// see rather than one the app hides.
pub fn enqueueOutbox(id: [32]u8, author: [32]u8, now_s: i64, route: PlaceRoute) bool {
    outboxLock();
    defer outboxUnlock();
    if (outboxEntryFor(id) != null) return true;
    for (&g_outbox) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .author = author, .queued_at = now_s, .route = route };
            _ = g_outbox_rev.fetchAdd(1, .monotonic);
            return true;
        }
    }
    // Full: drop the oldest note that has already reached somebody, since its
    // record is the least useful thing here.
    var victim: ?*OutboxEntry = null;
    for (&g_outbox) |*e| {
        if (e.acked == 0) continue;
        if (victim == null or e.queued_at < victim.?.queued_at) victim = e;
    }
    const slot = victim orelse return false;
    slot.* = .{ .used = true, .id = id, .author = author, .queued_at = now_s, .route = route };
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
    return true;
}

/// Whether the queue could take another note right now.
///
/// Asked BEFORE the composer is emptied, which is the difference between a note
/// the reader still has and one that is gone. `ingestAndPublish` refuses to
/// publish what it cannot track, and it is right to: a note nobody is counting
/// under a banner promising that anything written is kept is the lie the queue
/// exists to stop telling. But the refusal happened after `.post` had cleared
/// the composer and deleted the draft file, so the note was simply lost, with no
/// queue row, no retry and no way back.
///
/// Sixteen slots, and eviction only takes a note that has already reached
/// somebody. Sixteen unacked notes therefore wedge the queue for as long as the
/// failure lasts, which for a pool that all requires NIP-42 AUTH, or a laptop on
/// a plane, is a real state and not a corner.
pub fn outboxHasRoom() bool {
    outboxLock();
    defer outboxUnlock();
    for (&g_outbox) |*e| {
        if (!e.used) return true;
        if (e.acked != 0) return true;
    }
    return false;
}
/// Records what one relay said about one note.
pub fn recordOutboxAck(id: [32]u8, relay_index: usize, accepted: bool) void {
    if (relay_index >= max_relays) return;
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return;
    const bit = @as(u8, 1) << @intCast(relay_index);
    if (accepted) e.acked |= bit else e.refused |= bit;
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// A snapshot of the queue for the view, newest first. The view never reads the
/// queue directly: the publisher writes it from its own thread.
pub fn outboxSnapshot(out: []OutboxEntry) usize {
    outboxLock();
    defer outboxUnlock();
    var n: usize = 0;
    for (&g_outbox) |*e| {
        if (!e.used or n == out.len) continue;
        // The same rule `outboxCounts` applies: the popover explains the count,
        // so it has to be a list of the same notes.
        if (!outboxEntryIsMine(e.*)) continue;
        out[n] = e.*;
        n += 1;
    }
    std.mem.sort(OutboxEntry, out[0..n], {}, struct {
        fn lt(_: void, a: OutboxEntry, b: OutboxEntry) bool {
            return a.queued_at > b.queued_at;
        }
    }.lt);
    return n;
}

/// How many notes are still trying, and how many have given up. They are
/// counted apart because they say different things: one is work in progress,
/// the other is a note the reader wrote that never left.
pub const OutboxCounts = struct { trying: usize = 0, stuck: usize = 0 };

pub fn outboxCounts() OutboxCounts {
    outboxLock();
    defer outboxUnlock();
    var counts: OutboxCounts = .{};
    for (&g_outbox) |*e| {
        if (!e.used or e.acked != 0) continue;
        // The status bar speaks for the reader who is here now. Counting a note
        // they did not write would have the app owe them something that is not
        // theirs, and offer no way to act on it.
        if (!outboxEntryIsMine(e.*)) continue;
        if (e.state() == .stuck) counts.stuck += 1 else counts.trying += 1;
    }
    return counts;
}

/// How many notes are still waiting for their first relay, trying or not.
pub fn outboxPending() usize {
    const c = outboxCounts();
    return c.trying + c.stuck;
}

/// Forgets the notes that are done: acknowledged by somebody, or refused by
/// everyone that answered after enough rounds. Called once the reader has had a
/// chance to see them, so the zone does not blink out mid-glance.
pub fn sweepOutbox(now_s: i64) void {
    outboxLock();
    defer outboxUnlock();
    var changed = false;
    for (&g_outbox) |*e| {
        if (!e.used or e.sending) continue;
        // A note that LANDED is let go once it has been on screen long enough to
        // read. A note that did not is KEPT: erasing it would be the app quietly
        // dropping something the reader wrote, which is the one thing this queue
        // exists to prevent. It stops asking, and it stays visible as stuck.
        if (e.acked != 0 and now_s - e.queued_at > outbox_sent_linger_s) {
            e.* = .{};
            changed = true;
        }
    }
    if (changed) _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// How long a sent note stays in the queue so the reader can see that it landed.
pub const outbox_sent_linger_s: i64 = 20;
/// The revision last written to disk, so the queue is saved when it changes and
/// not on every tick.
pub var g_outbox_saved_rev: u32 = 0;
/// A fingerprint of the pool, in slot order. The outbox records which relay took
/// a note as a BIT PER SLOT, so those bits only mean anything against the list
/// they were written for: after an edit, bit 2 may be a relay that never saw the
/// note. The fingerprint travels with the queue so a changed list is noticed
/// rather than silently misread.
fn relayListFingerprint() u64 {
    var h = std.hash.Wyhash.init(0);
    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse {
            h.update("-");
            continue;
        };
        h.update(e.url());
        h.update(if (e.write) "w" else ".");
    }
    return h.final();
}

/// Forgets which relays took what, keeping the notes themselves. Called when the
/// list changes: a note that was delivered will simply be offered again, and a
/// relay that already has it will say so, which is cheaper than remembering a
/// claim that may now name the wrong relay.
pub fn forgetOutboxAcks() void {
    outboxLock();
    defer outboxUnlock();
    var changed = false;
    for (&g_outbox) |*e| {
        // EVERY owed note, including one that gave up with no verdict at all.
        // Skipping those would skip exactly the notes an edit is meant to
        // rescue: a note is stuck because `rounds` ran out, and a note whose
        // relays all went silent has `acked == 0 and refused == 0`. Adding a
        // relay for a note that never went out has to give that note its rounds
        // back, or the new relay is never asked.
        if (!e.used) continue;
        if (e.acked == 0 and e.refused == 0 and e.rounds == 0) continue;
        e.acked = 0;
        e.refused = 0;
        e.rounds = 0;
        changed = true;
    }
    if (changed) _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// The queue's key in the store's generic table, one record PER ACCOUNT. The
/// events themselves are in the store's own event tables (we ingest what we
/// sign), so this holds only the index: which ids are owed, and what each relay
/// said.
///
/// Per account, because the sixteen slots in `g_outbox` are a scarce resource
/// and they belong to whoever is signed in. An account that logs out has its
/// queue written to its own record and its slots handed back; signing in reads
/// that record and nothing else. The alternative, leaving another account's
/// entries sitting in the array where they can never be sent, never acked and
/// therefore never reclaimed, wedges the queue: sixteen of them and the person
/// at the keyboard cannot publish at all, in silence.
const outbox_key_prefix = "outbox:";

/// The pre-account record, kept readable so a queue written by an older build is
/// not stranded. Each account claims its own share of it the first time it signs
/// in; whatever is left belongs to somebody else and stays put.
const legacy_outbox_key = "outbox";

fn outboxKeyFor(out: *[outbox_key_prefix.len + 64]u8, owner: [32]u8) []const u8 {
    @memcpy(out[0..outbox_key_prefix.len], outbox_key_prefix);
    var hex: [64]u8 = undefined;
    writeHexId(&hex, owner);
    @memcpy(out[outbox_key_prefix.len..][0..64], &hex);
    return out[0 .. outbox_key_prefix.len + 64];
}

/// Whose entries are in `g_outbox` right now. Null while signed out, when the
/// array is empty.
pub var g_outbox_owner: ?[32]u8 = null;

/// Writes the queue where a restart can find it. A note written on a train and
/// lost on landing is the worst thing a client can do, so this runs on every
/// change rather than at exit, which may never come.
pub fn saveOutbox() void {
    const store = main.g_store orelse return;
    // Nobody signed in means nothing of anybody's in the array, so there is no
    // record to write and nowhere to write it.
    const owner = g_outbox_owner orelse return;
    // Snapshotted under the lock, written outside it. `store.put` opens a write
    // transaction and commits it, which fsyncs and waits on LMDB's writer mutex
    // that the ingest threads hold: holding a SPINLOCK across that would burn a
    // core in every publisher and stall the frame that reads the queue. The lock
    // is only justified while it is what it claims to be, a few field writes.
    var entries: [outbox_cap]OutboxEntry = undefined;
    var n: usize = 0;
    outboxLock();
    for (&g_outbox) |*e| {
        if (!e.used) continue;
        entries[n] = e.*;
        n += 1;
    }
    outboxUnlock();

    // Room for every entry at its longest: 64 hex, four separators, a ten-digit
    // second, three small numbers and a newline. Sized at the worst case rather
    // than the typical one, because a short buffer would drop the LAST entries,
    // which is exactly when the queue matters most.
    var buf: [outbox_cap * 100 + 32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // The list those ack bits were recorded against, first.
    w.print("pool {d}\n", .{relayListFingerprint()}) catch return;
    for (entries[0..n]) |e| {
        var hex: [64]u8 = undefined;
        writeHexId(&hex, e.id);
        // A short write means the buffer was mis-sized, so nothing is written at
        // all: a truncated index would silently lose notes on the next start.
        w.print("{s}:{d}:{d}:{d}:{d}\n", .{ hex[0..], e.queued_at, e.acked, e.refused, e.rounds }) catch return;
    }
    var key_buf: [outbox_key_prefix.len + 64]u8 = undefined;
    store.put(outboxKeyFor(&key_buf, owner), w.buffered()) catch {};
}

fn writeHexId(out: *[64]u8, id: [32]u8) void {
    const hexdigits = "0123456789abcdef";
    for (id, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0x0f];
    }
}

/// Reads `owner`'s queue into the array, replacing whatever was there.
///
/// Anything whose event is no longer in the store is dropped: the index points
/// at events, and an index without its event is not something the reader can be
/// shown or the app can publish. Anything signed by somebody else is dropped
/// too, which only matters for the legacy record, and is the whole point of
/// reading it: each account takes its own share and leaves the rest.
pub fn loadOutbox(owner: [32]u8) void {
    const store = main.g_store orelse return;
    var key_buf: [outbox_key_prefix.len + 64]u8 = undefined;
    const raw = blk: {
        if (store.get(std.heap.page_allocator, outboxKeyFor(&key_buf, owner)) catch null) |own| break :blk own;
        if (store.get(std.heap.page_allocator, legacy_outbox_key) catch null) |legacy| break :blk legacy;
        // No record at all is an ANSWER, not a reason to leave the array alone:
        // this account's queue is empty, and whatever is in the slots belongs to
        // somebody else. Returning here without clearing is how the previous
        // account's notes stay in the next account's queue.
        clearOutboxSlots();
        return;
    };
    defer std.heap.page_allocator.free(raw);
    // Parsed and resolved first, installed second: every `getEvent` below opens a
    // read transaction, and the lock may not span IO.
    var parsed: [outbox_cap]OutboxEntry = undefined;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    // Whether the ack bits still refer to the relays they were written for.
    var same_pool = false;
    var n: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "pool ")) {
            const saved = std.fmt.parseInt(u64, line["pool ".len..], 10) catch 0;
            same_pool = saved == relayListFingerprint();
            continue;
        }
        if (n == parsed.len) break;
        var parts = std.mem.splitScalar(u8, line, ':');
        const hex = parts.next() orelse continue;
        if (hex.len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, hex) catch continue;
        const queued_at = std.fmt.parseInt(i64, parts.next() orelse "0", 10) catch continue;
        const acked = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        const refused = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        const rounds = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        // The event has to still be there, or there is nothing to publish.
        const se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        var owned = se;
        // The author comes from the event, which is why it is not in the file.
        const author = owned.event.pubkey;
        owned.deinit();
        // Somebody else's, which the legacy record can hold. Theirs to keep, so
        // it is left in that record rather than taken or dropped.
        if (!std.mem.eql(u8, &author, &owner)) continue;
        // A note is kept whatever the list did; only the CLAIMS about who has it
        // are dropped, so it is offered again rather than assumed delivered.
        parsed[n] = if (same_pool)
            .{ .used = true, .id = id, .author = author, .queued_at = queued_at, .acked = acked, .refused = refused, .rounds = rounds }
        else
            .{ .used = true, .id = id, .author = author, .queued_at = queued_at };
        n += 1;
    }
    outboxLock();
    defer outboxUnlock();
    // The WHOLE array, not the first n. This replaces one account's queue with
    // another's, so anything past the new entries has to go, or the tail of the
    // previous account's queue survives in the slots nobody overwrote.
    g_outbox = [_]OutboxEntry{.{}} ** outbox_cap;
    for (parsed[0..n], g_outbox[0..n]) |src, *dst| dst.* = src;
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// Empties the sixteen slots. The notes themselves are events in the store and
/// their index is in a per-account record, so this hands slots back rather than
/// destroying anything.
fn clearOutboxSlots() void {
    outboxLock();
    g_outbox = [_]OutboxEntry{.{}} ** outbox_cap;
    outboxUnlock();
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// Which queued notes the next drain will actually send, stamping each one's
/// attempt as it goes.
///
/// Split out of `drainOutbox` so the choice can be tested without a store and
/// without spawning publishers. The choice IS the safety property: the drain
/// itself is a loop that reads events and hands them to threads, and every
/// question worth asking about who may publish what is answered here.
pub fn collectOutboxDue(ids: *[outbox_cap][32]u8, now_s: i64) usize {
    var n: usize = 0;
    outboxLock();
    defer outboxUnlock();
    for (&g_outbox) |*e| {
        if (!e.used or e.sending or e.acked != 0) continue;
        // Somebody else's note. This is the line that stops the previous
        // account's unsent writing going out over the next account's relays,
        // and signed out it stops everything, because a queued note is a promise
        // to one account and there is nobody here to keep it for.
        if (!outboxEntryIsMine(e.*)) continue;
        // Spaced out, and widening: the drain runs every tick, so without this a
        // transient failure (a captive portal, a TLS error, a relay that takes
        // the socket and refuses the publish) would burn every round in seconds
        // and leave the note stuck a moment after it was written.
        if (e.last_try_at != 0 and now_s - e.last_try_at < outboxRetryDelay(e.rounds)) continue;
        if (n == ids.len) break;
        e.last_try_at = now_s;
        ids[n] = e.id;
        n += 1;
    }
    return n;
}
/// Hands the sixteen slots to whoever is signed in, whenever that changes.
///
/// ONE place, called from the tick before anything reads the queue, because
/// getting it wrong in two places is how the previous account's notes end up in
/// the next account's queue. The leaving account's entries are written to their
/// own record first and only then cleared, so nothing is dropped: they are
/// parked, not deleted, and reading them back is what signing in again does.
///
/// This is what keeps `outboxEntryIsMine` an invariant rather than a load-
/// bearing filter. Leaving foreign entries in the array and merely refusing to
/// send them looks safe and is not: nothing can ever ack them, so nothing can
/// ever sweep or evict them either, and sixteen of them stop the person at the
/// keyboard publishing anything at all, with no counter, no popover row and no
/// banner to say why.
pub fn syncOutboxOwner() void {
    const now_owner = activePubkey();
    if (g_outbox_owner) |had| {
        if (now_owner) |now| if (std.mem.eql(u8, &had, &now)) return;
    } else if (now_owner == null) return;

    // Park the leaving account's queue before the slots are handed over.
    if (g_outbox_owner != null) {
        saveOutbox();
        clearOutboxSlots();
    }
    g_outbox_owner = now_owner;
    if (now_owner) |owner| loadOutbox(owner) else clearOutboxSlots();
    // The queue on disk is already current for both accounts, so the tick's
    // save-on-change is told not to write the freshly loaded one straight back.
    g_outbox_saved_rev = g_outbox_rev.load(.monotonic);
}

/// Offers every note that nobody has taken to the relays again. Called when a
/// Where a queued note was written, for the retry that carries it.
fn outboxRouteFor(id: [32]u8) PlaceRoute {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return .none;
    return e.route;
}

/// relay comes back, which is the moment the answer might have changed.
pub fn drainOutbox(gpa: std.mem.Allocator) void {
    const store = main.g_store orelse return;
    var ids: [outbox_cap][32]u8 = undefined;
    const n = collectOutboxDue(&ids, nowSeconds());
    for (ids[0..n]) |id| {
        const route = outboxRouteFor(id);
        var se = (store.getEvent(gpa, id) catch continue) orelse continue;
        defer se.deinit();
        // COPIED, not borrowed. `StoredEvent.deinit` tears down the arena that
        // backs the content and the tags, and it would fire at the end of this
        // iteration, while the detached publisher is still serialising them.
        // `ingestAndPublish` states the same rule for its own path: what the
        // publisher reads has to outlive the call that spawned it.
        const owned = dupeEventForPublish(se.event) orelse continue;
        const thread = std.Thread.spawn(.{}, publishOwnedWorker, .{ gpa, owned, route }) catch {
            freePublishedEvent(owned);
            continue;
        };
        thread.detach();
    }
}

/// A process-lifetime copy of an event, for handing to a detached publisher.
/// Returns null when the copy cannot be made, in which case nothing is spawned.
fn dupeEventForPublish(ev: nostr.event.Event) ?nostr.event.Event {
    const gpa = std.heap.page_allocator;
    var out = ev;
    out.content = gpa.dupe(u8, ev.content) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, ev.tags.len) catch {
        gpa.free(out.content);
        return null;
    };
    var filled: usize = 0;
    errdefer {
        for (tags[0..filled]) |t| {
            for (t) |field| gpa.free(field);
            gpa.free(t);
        }
        gpa.free(tags);
        gpa.free(out.content);
    }
    for (ev.tags, tags) |src, *dst| {
        const fields = gpa.alloc([]const u8, src.len) catch return null;
        var wrote: usize = 0;
        for (src, fields) |field, *slot| {
            slot.* = gpa.dupe(u8, field) catch {
                for (fields[0..wrote]) |f| gpa.free(f);
                gpa.free(fields);
                return null;
            };
            wrote += 1;
        }
        dst.* = fields;
        filled += 1;
    }
    out.tags = tags;
    return out;
}

/// Frees what `dupeEventForPublish` allocated.
fn freePublishedEvent(ev: nostr.event.Event) void {
    const gpa = std.heap.page_allocator;
    for (ev.tags) |t| {
        for (t) |field| gpa.free(field);
        gpa.free(t);
    }
    gpa.free(ev.tags);
    gpa.free(ev.content);
}

/// The drain's worker: publishes a copy it owns, and frees it when the walk is
/// over rather than leaving it to a caller that has already moved on.
fn publishOwnedWorker(gpa: std.mem.Allocator, ev: nostr.event.Event, route: PlaceRoute) void {
    defer freePublishedEvent(ev);
    publishWorker(gpa, ev, route);
}

/// Publishes `ev` to every relay in the pool, each on a throwaway connection,
/// best-effort. Posting is a rare, human-paced action, so a fresh dial per post
/// keeps the ingest loops untouched; the note is already in the local store, so
/// the feed shows it regardless of publish latency. Runs on a detached thread
/// with its own io backend, never the UI thread's.
/// At most this many of one recipient's read relays are added for a publish.
///
/// Jumble takes five, welshman's default scenario limit is three. Three is the
/// smaller of the two and still means a person has to have lost three relays at
/// once to miss a reply.
const inbox_relays_per_recipient = 3;
/// A ceiling on the whole extra set, so a note naming a dozen people does not
/// turn one Post into thirty dials.
const max_extra_inbox_relays = 8;

/// Publishes `ev` to the relays the people it names actually READ from.
///
/// Plaza sent every note to the reader's own write relays and nowhere else. If
/// the person being replied to does not read those relays, their client never
/// sees the reply and never tells them: a thread started from Plaza reads
/// one-sided to everybody else in it. Plaza's own inbox subscription is the
/// mirror of this and is correct, so the app was receiving what others routed
/// to it and not reciprocating.
///
/// Best effort, and deliberately not recorded in the outbox. An acknowledgement
/// there is a bit in a per-slot bitmap and these relays hold no slot; more to
/// the point, "did my note go out" is a question about the reader's own relays,
/// and a stranger's inbox relay refusing an unknown pubkey is normal rather
/// than a delivery failure worth alarming them about.
fn publishToRecipientInboxes(gpa: std.mem.Allocator, io: std.Io, ev: nostr.event.Event) void {
    const store = main.g_store orelse return;

    // Who the note names. The author is skipped: a reply to yourself does not
    // need routing, and the pool already carries it.
    var recipients: [max_extra_inbox_relays * 2][32]u8 = undefined;
    var n: usize = 0;
    for (ev.tags) |tag| {
        if (n == recipients.len) break;
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "p") or tag[1].len != 64) continue;
        var pk: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk, tag[1]) catch continue;
        if (std.mem.eql(u8, &pk, &ev.pubkey)) continue;
        var dupe = false;
        for (recipients[0..n]) |seen| {
            if (std.mem.eql(u8, &seen, &pk)) dupe = true;
        }
        if (dupe) continue;
        recipients[n] = pk;
        n += 1;
    }
    if (n == 0) return;

    const kinds = [_]u16{relay_list_kind};
    var result = store.query(gpa, .{ .authors = recipients[0..n], .kinds = &kinds, .limit = @intCast(n) }) catch return;
    defer result.deinit();

    var urls: [max_extra_inbox_relays][96]u8 = undefined;
    var url_len: [max_extra_inbox_relays]usize = undefined;
    var urls_n: usize = 0;

    for (result.events) |list_ev| {
        var parsed = nostr.nip65.parseRelayList(gpa, list_ev) catch continue;
        defer parsed.deinit();
        var taken: usize = 0;
        for (parsed.list.entries) |entry| {
            if (taken == inbox_relays_per_recipient or urls_n == urls.len) break;
            // Where they READ. A relay they only write to will never show them
            // anything, so a reply left there is a reply nobody receives.
            if (!entry.read) continue;
            const trimmed = std.mem.trim(u8, entry.url, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > 96) continue;
            // Already covered by the pool walk, so dialling it again would only
            // publish the same note twice to the same host.
            if (poolHasRelay(trimmed)) continue;
            var already = false;
            for (0..urls_n) |i| {
                if (std.mem.eql(u8, urls[i][0..url_len[i]], trimmed)) already = true;
            }
            if (already) continue;
            @memcpy(urls[urls_n][0..trimmed.len], trimmed);
            url_len[urls_n] = trimmed.len;
            urls_n += 1;
            taken += 1;
        }
    }

    for (0..urls_n) |i| {
        const url = urls[i][0..url_len[i]];
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms);
        defer releaseOneShot(watched);
        relay.publish(ev) catch continue;
        // One read, to give the frame somewhere to flush to. The verdict is not
        // recorded, so there is nothing to wait around for. Bounded on its own,
        // for when the keeper had no slot to watch it with.
        var msg = (relay.receiveTimeout(oneShotDeadline(io)) catch continue) orelse continue;
        msg.deinit();
    }
}
pub fn poolHasRelay(url: []const u8) bool {
    for (0..relaySlots()) |i| {
        var buf: [96]u8 = undefined;
        const entry = relaySnapshot(i, &buf) orelse continue;
        // The pool's own comparison, which knows that a trailing slash and a
        // difference of case are the same relay. Two spellings here would mean
        // publishing the same note to the same host twice.
        if (relayUrlEql(entry.url, url)) return true;
    }
    return false;
}

/// Where a write goes, decided when the reader asked for it.
///
/// A VALUE, and copied, for two reasons. `activePlace()` hands back a pointer
/// into a global the UI thread assigns a whole new `Place` over, and this is
/// read on a detached publish thread across a dial: one walk could see half of
/// one room's relay list and half of another's. And the room is read LATE
/// otherwise. A note held for the undo pause, a note waiting on a remote
/// signer's approval, and a note the outbox retries minutes later are all
/// published long after the reader pressed Post, so asking then answers about
/// whichever room they have since walked into, not the one they wrote in.
pub const PlaceRoute = struct {
    urls: [place_relays_cap][place_relay_cap]u8 = @splat(@splat(0)),
    lens: [place_relays_cap]u8 = @splat(0),
    len: u8 = 0,
    /// The place said "only these". Honoured only when it named some, because a
    /// place claiming exclusivity and naming none would silence the reader.
    exclusive: bool = false,

    /// No room: the reader's own relays, and nothing else.
    pub const none: PlaceRoute = .{};

    pub fn url(self: *const PlaceRoute, i: usize) []const u8 {
        return self.urls[i][0..self.lens[i]];
    }
};
pub var g_route_probe: PlaceRoute = .none;

/// The room open right now, as something that can be carried away from it.
pub fn routeForOpenPlace() PlaceRoute {
    var out: PlaceRoute = .{};
    // `activePlace`, not `visitingPlace`. The second one means a place being
    // looked at and NOT yet entered, so this would go quiet the moment somebody
    // actually joined the community: exactly backwards.
    const place = activePlace() orelse return out;
    for (0..place.write_relays_len) |i| {
        if (out.len == out.urls.len) break;
        const u = place.writeRelay(i);
        out.lens[out.len] = @intCast(copyBounded(&out.urls[out.len], u));
        out.len += 1;
    }
    out.exclusive = place.write_exclusive;
    return out;
}

pub fn publishEvent(gpa: std.mem.Allocator, ev: nostr.event.Event, route: PlaceRoute) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The place being read, if any, sent to FIRST and separately from the
    // reader's own pool.
    //
    // `activePlace`, not `visitingPlace`. The second one means a place being
    // looked at and NOT yet entered, so every one of these would have gone
    // quiet the moment somebody actually joined the community: exactly
    // backwards.
    //
    // A note written inside a community used to walk only the reader's write
    // slots, so it went everywhere except the community it was written in. The
    // place names where it lives; this is that promise kept.
    //
    // Not recorded in the outbox: a slot index is what an acknowledgement is
    // filed against, and these relays hold no slot. So they are a best effort
    // in the same sense the room itself is, and the note is still tracked
    // against the reader's own relays below.
    for (0..route.len) |i| {
        var relay = nostr.relay.dial(gpa, io, route.url(i)) catch continue;
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms);
        defer releaseOneShot(watched);
        relay.publish(ev) catch continue;
    }
    if (route.exclusive and route.len > 0) return;

    for (0..relaySlots()) |i| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(i, &url_buf) orelse continue;
        // Only where the reader asked to be published. The slot index is what
        // the outbox records an acknowledgement against, which is why a slot is
        // never reused for a different relay while the process lives.
        if (!entry.write) continue;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms);
        defer releaseOneShot(watched);
        relay.publish(ev) catch continue;
        // The relay's OK is the answer to "is my note out there", so it is READ
        // rather than merely waited for: which relay took it, and which refused,
        // is the whole content of the outbox. A relay may say other things
        // first (a NOTICE, an EVENT for an open subscription), so this reads
        // until it sees a verdict for THIS id or runs out of patience.
        // One deadline for the whole exchange, so the reads end on time even
        // when the keeper had no slot to watch this socket with.
        const until = oneShotDeadline(io);
        var seen: usize = 0;
        while (seen < max_publish_messages) : (seen += 1) {
            var msg = (relay.receiveTimeout(until) catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .ok => |ok| {
                    if (!std.mem.eql(u8, &ok.event_id, &ev.id)) continue;
                    // An ack is recorded against a SLOT, and this walk has been
                    // blocked on a socket long enough for the reader to have
                    // removed the relay or put another one in its seat. Record
                    // it only if the seat still holds the relay that answered,
                    // or the note would be reported as delivered to a relay that
                    // never saw it.
                    var still_buf: [96]u8 = undefined;
                    const still = relaySnapshot(i, &still_buf) orelse break;
                    if (!relayUrlEql(still.url, entry.url)) break;
                    recordOutboxAck(ev.id, i, ok.accepted);
                    break;
                },
                else => continue,
            }
        }
    }

    // And where the people it names actually read, which the reader's own
    // relays say nothing about.
    publishToRecipientInboxes(gpa, io, ev);
}

/// How many frames to read from one relay while waiting for its verdict. A relay
/// with a busy subscription can have several in front of the OK; past this it is
/// not answering about this note.
const max_publish_messages = 8;

pub fn forgetOutboxAcksForTest() void {
    forgetOutboxAcks();
}
pub fn outboxHasRoomForTest() bool {
    return outboxHasRoom();
}

/// The queue's own seams, so a test drives the real state machine rather than a
/// copy of it.
pub fn resetOutboxForTest() void {
    outboxLock();
    defer outboxUnlock();
    for (&g_outbox) |*e| e.* = .{};
    relay_conn.g_outbox_woke_at.store(0, .monotonic);
    relay_conn.g_outbox_woke_ever.store(false, .monotonic);
}

pub fn outboxStateForTest(id: [32]u8) ?OutboxState {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return null;
    return e.state();
}

pub fn outboxRoundsForTest(id: [32]u8) ?u8 {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return null;
    return e.rounds;
}

pub fn enqueueOutboxForTest(id: [32]u8, author: [32]u8, now_s: i64) bool {
    return enqueueOutbox(id, author, now_s, .none);
}

pub fn recordOutboxAckForTest(id: [32]u8, relay_index: usize, accepted: bool) void {
    recordOutboxAck(id, relay_index, accepted);
}

pub fn sweepOutboxForTest(now_s: i64) void {
    sweepOutbox(now_s);
}

pub fn outboxRetryDelayForTest(rounds: u8) i64 {
    return outboxRetryDelay(rounds);
}

pub const rounds_before_stuck_for_test = rounds_before_stuck;
pub const outbox_sent_linger_for_test = outbox_sent_linger_s;

pub fn collectOutboxDueForTest(ids: *[outbox_cap][32]u8, now_s: i64) usize {
    return collectOutboxDue(ids, now_s);
}

pub fn syncOutboxOwnerForTest() void {
    syncOutboxOwner();
}

pub fn loadOutboxForTest(owner: [32]u8) void {
    loadOutbox(owner);
}

pub fn saveOutboxForTest() void {
    saveOutbox();
}

pub fn outboxOwnerForTest() ?[32]u8 {
    return g_outbox_owner;
}

pub fn clearOutboxOwnerForTest() void {
    g_outbox_owner = null;
}

pub fn outboxAuthorAtForTest(i: usize) ?[32]u8 {
    outboxLock();
    defer outboxUnlock();
    if (!g_outbox[i].used) return null;
    return g_outbox[i].author;
}

pub fn outboxUsedSlotsForTest() usize {
    outboxLock();
    defer outboxUnlock();
    var n: usize = 0;
    for (&g_outbox) |*e| {
        if (e.used) n += 1;
    }
    return n;
}

pub const outbox_cap_for_test = outbox_cap;

/// Whether `url` is already one of the reader's own relays.
pub fn poolHasRelayForTest(url: []const u8) bool {
    return poolHasRelay(url);
}

pub fn routeForOpenPlaceRelaysForTest(out: [][]const u8) usize {
    const r = routeForOpenPlace();
    g_route_probe = r;
    var n: usize = 0;
    while (n < g_route_probe.len and n < out.len) : (n += 1) out[n] = g_route_probe.url(n);
    return n;
}

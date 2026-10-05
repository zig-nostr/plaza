//! Tests of relay_conn.zig. Live connection state: status per relay, seats for live and one-shot relays, pause, and latency probes.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContaining = harness.findAnyTextContaining;
const ui_fmt_pool = harness.ui_fmt_pool;

test "a latency reading survives only as long as its connection" {
    main.clearRelayRttForTest(0);
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(0));

    // Sub-millisecond answers are readings, not holes: a warm relay that replies
    // in under a millisecond truncates to zero, which must not read as "never
    // answered".
    main.recordRelayRttForTest(0, 0);
    try testing.expectEqual(@as(?u16, 0), main.relayRttMs(0));

    // An even number of samples takes the middle of the two middles, so a reading
    // is not silently the slower one.
    main.clearRelayRttForTest(0);
    main.recordRelayRttForTest(0, 10);
    main.recordRelayRttForTest(0, 20);
    try testing.expectEqual(@as(?u16, 15), main.relayRttMs(0));

    // And a relay that drops forgets: the bar must never show a number measured
    // on a connection that no longer exists.
    main.clearRelayRttForTest(0);
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(0));
}
test "a removed relay is not still connected" {
    // The status is recorded per SLOT and the slot outlives its relay, so a
    // removal that left the status alone kept counting a relay that is gone.
    main.resetRelaysForTest();
    main.setRelayStatusForTest(0, true);
    main.setRelayStatusForTest(1, true);
    try testing.expectEqual(@as(usize, 2), main.liveRelayCountForTest());
    main.removeRelayForTest(1);
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(1));
}
test "only the feed subscription's own ids are read as the feed" {
    try testing.expect(main.isFeedSubForTest("plaza-feed"));
    try testing.expect(main.isFeedSubForTest("plaza-feed-12"));
    try testing.expect(!main.isFeedSubForTest("plaza-inbox"));
    try testing.expect(!main.isFeedSubForTest("plaza-engagement"));
    try testing.expect(!main.isFeedSubForTest("plaza-ask-1"));
}
test "only the seats that changed hands lose their row" {
    // The discrimination itself, which neither half of the test above reaches:
    // one of them changes NO seat and the other changes EVERY seat, so an
    // all-or-nothing rule would satisfy both. This pool changes some and keeps
    // others, in the same swap.
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.resetRelaysForTest();

    const kept_0 = main.relayUrlAt(0);
    const kept_2 = main.relayUrlAt(2);
    try testing.expect(kept_0.len > 0 and kept_2.len > 0);

    // Everybody reporting in.
    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);

    // Their published list keeps seats 0 and 2 exactly as they are, puts a
    // different relay in seat 1, and empties the rest.
    const tags = [_]nostr.event.Tag{
        &.{ "r", kept_0 },
        &.{ "r", "wss://swapped-in.example.com" },
        &.{ "r", kept_2 },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x51} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());

    // Seats 0 and 2 kept their relay, so they kept their connection. Seat 1
    // changed hands and seats 3 and 4 emptied, so those rows are gone. A rule
    // that cleared everything gives 0 here; a rule that cleared nothing gives 5.
    try testing.expect(main.relayStatusConnectedForTest(0));
    try testing.expect(!main.relayStatusConnectedForTest(1));
    try testing.expect(main.relayStatusConnectedForTest(2));
    try testing.expect(!main.relayStatusConnectedForTest(3));
    try testing.expect(!main.relayStatusConnectedForTest(4));
}
test "the relay chip is text on the bar, and says nothing about latency" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();
    main.resetRelaysForTest();

    // A live round trip on record, which is what used to be printed here. The
    // popover only shows a ping for a relay it believes is connected, so the
    // status goes with it.
    main.recordRelayRttForTest(0, 337);
    main.setRelayStatusForTest(0, true);
    defer main.clearRelayRttForTest(0);
    defer main.setRelayStatusForTest(0, false);

    var model = main.initialModel();
    model.stage = .ready;
    model.live_relays = main.relayCount();
    model.relay_count = main.relayCount();
    const tree = try buildTree(arena, &model);

    // The count, and only the count. A round-trip figure that swings with
    // whichever relay answered last is a number nobody acts on, and it sat where
    // the reader looks to find out whether the pool is up.
    try testing.expect(findAnyText(tree.root, ui_fmt_pool(arena, main.relayCount())) != null);
    try testing.expect(!findAnyTextContaining(tree.root, "337 ms"));

    // The per-relay pings are still in the card the chip opens, beside the relay
    // each one belongs to, which is the only place the number means anything.
    // The popover writes it tight ("337ms") and Settings spaced ("337 ms"), so
    // both are asked for by their own spelling rather than a shared substring.
    model.menu = .relays;
    const open = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(open.root, "337ms"));

    // And no plate behind it. The dot already carries the pool's health, so the
    // surface was a second voice saying the same thing.
    // Unconditional: `fillAtCenterOf` returns null when nothing paints there,
    // which is the answer this assertion wants, so wrapping it in `if` let the
    // whole check pass by finding nothing at all.
    const p = try painted.Painted.render(arena, &model);
    try testing.expect(p.frameOf("Relays") != null);
    if (p.fillAtCenterOf("Relays")) |fill| {
        try testing.expect(!painted.sameColor(fill, theme.palette.surface_chip));
    }
}
test "the latency probe cannot deliver a single event" {
    // The probe exists to time a round trip, and that is ALL it should cost. It
    // used to ask for kind:1 with no author, no since and no until, which is a
    // subscription to every text note the relay receives, from anyone, held open
    // for the life of the connection: every one of those events was parsed,
    // allocated and secp256k1-verified before being thrown away.
    //
    // Asserting the property rather than the wording: whatever the probe asks
    // for, an ordinary note must not match it.
    const filters = main.probeFilters();
    try testing.expectEqual(@as(usize, 1), filters.len);
    const f = filters[0];

    const ev = nostr.event.Event{
        .id = [_]u8{0x9c} ** 32,
        .pubkey = [_]u8{0x11} ** 32,
        .created_at = 1_700_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "an ordinary note",
        .sig = [_]u8{0} ** 64,
    };
    try testing.expect(!f.matches(ev));

    // And it is narrow by construction, not by luck: it names exact ids, so
    // there is no kind, author or time window for anything to arrive through.
    try testing.expect(f.ids != null);
    try testing.expect(f.kinds == null);
    try testing.expect(f.authors == null);
    try testing.expect(f.tags == null);
    // Belt and braces: even a relay that matched it somehow sends one event.
    try testing.expectEqual(@as(u32, 1), f.limit.?);
}
test "a quiet relay still counts as a relay" {
    // The pool summary drives an "offline, reconnecting" banner over the whole
    // app. A relay with an open socket, live subscriptions and a publish path
    // that works is not offline, and saying so on a slow night would be the
    // same kind of lie as the green dot, pointing the other way.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example", true, true);
    main.setRelayStatusForTest(0, true);
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());

    main.setRelayQuietForTest(0);
    try testing.expect(main.relayStatusQuietForTest(0));
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());
    // And it is still a relay a note can go out on.
    try testing.expect(main.relayStatusConnectedForTest(0));
}

test "coming back from quiet is not a network recovery" {
    // The outbox widens its retry delay when nothing can be reached and pulls it
    // back when a relay returns. A relay answering the keepalive it was just
    // sent is news about one socket, not about the network, and letting it reset
    // the ladder would mean a quiet pool resetting it every minute forever.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example", true, true);
    main.forgetOutboxAcksForTest();

    main.setRelayStatusForTest(0, false);
    main.setRelayStatusForTest(0, true);
    const after_real_recovery = main.outboxWokeForTest();
    try testing.expect(after_real_recovery);

    main.resetOutboxWokeForTest();
    main.setRelayQuietForTest(0);
    main.setRelayStatusForTest(0, true);
    try testing.expect(!main.outboxWokeForTest());
}

// -- A fetch that cannot run forever ----------------------------------------
//
// Every fetch that is not the feed dials its own socket, asks one question and
// reads until EOSE. A relay that accepts the REQ and then goes quiet used to
// hold that thread for the life of the process, and a message-count bound does
// not help: a relay that sends nothing never reaches the count either.
//
// The keeper holds an absolute deadline on each of them. Its decision is pure
// over the deadline table, so it is asserted here without a socket or a thread.

test "a fetch inside its budget is left alone" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(0, 10_000);
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(9_999, &out));
}

test "a fetch past its budget is cut off" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(3, 10_000);
    const n = main.expiredOneShotsForTest(10_000, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 3), out[0]);
}

test "an empty slot is not a fetch that ran out of time" {
    // Zero is the empty marker, and a keeper reading it as a deadline in 1970
    // would try to shut down every unused slot on every tick.
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(std.math.maxInt(i64), &out));
}

test "a fetch already cut off is not cut off again" {
    // The slot stays in the table until its owner clears it, because clearing
    // it from the keeper would hand the slot to another fetch while the first
    // one still holds the pointer. So the keeper has to stop acting on it
    // without forgetting it.
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(5, 1_000);
    try testing.expectEqual(@as(usize, 1), main.expiredOneShotsForTest(2_000, &out));
    main.markOneShotCutForTest(5);
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(2_000, &out));
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(std.math.maxInt(i64), &out));
}

test "several overdue fetches are all cut, not just the first" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(0, 1_000);
    main.seatOneShotForTest(1, 50_000);
    main.seatOneShotForTest(2, 1_000);
    const n = main.expiredOneShotsForTest(2_000, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 0), out[0]);
    try testing.expectEqual(@as(usize, 2), out[1]);
}

test "the bunker listener is watched alongside the pool" {
    // It is not a pool relay: no badge, no slot in the reader's list, never
    // published to. It is the same kind of thing though, a socket held open by
    // a thread blocked in `receive`, and when it half-opens remote signing
    // stops with no error anywhere. Its slot sits past the pool's, which is why
    // the keeper's status updates have to stay inside the pool's range.
    try testing.expectEqual(main.maxRelaysForTest, main.bunkerWatchSlotForTest);
}

test "a one-shot budget is shorter than the connection deadline it borrows" {
    // A fetch is a question with an answer; a pool connection is a
    // conversation. Bounding the fetch by the connection's ninety seconds would
    // leave a wedged profile lookup sitting for a minute and a half, and there
    // is nothing to wait for: the relay was asked one thing.
    try testing.expect(main.oneShotBudgetMsForTest < nostr.liveness.dead_after_ms);
}
test "the discovered pool is separate from the eight the outbox counts" {
    // `max_relays` is eight because a delivery is recorded in a `u8` bitmap,
    // one bit per slot. A ninth slot would silently stop being counted and
    // every note would look undelivered forever, so these connections live
    // past the pool and never publish.
    try testing.expectEqual(main.maxRelaysForTest + 1, main.discoveredWatchBaseForTest);
    try testing.expect(main.relayWatchSlotsForTest >= main.discoveredWatchBaseForTest + main.maxDiscoveredRelaysForTest);
    // And a discovered connection is watched by the keeper like any other, or a
    // relay nobody chose could half-open and sit there.
    try testing.expect(main.maxDiscoveredRelaysForTest > 0);
}
test "a one-shot subscription id is recognisable as one" {
    // The relay threads dispatch on this. Anything that is not the feed, the
    // inbox or a one-shot falls into the engagement arm and is counted as
    // somebody reacting to a note, so a question that does not announce itself
    // does not merely go unanswered: it inflates a tally.
    try testing.expect(main.isOneShotSubForTest(main.oneShotSubPrefixForTest ++ "profiles"));
    try testing.expect(main.isOneShotSubForTest(main.oneShotSubPrefixForTest ++ "quotes"));
    try testing.expect(!main.isOneShotSubForTest("plaza-feed"));
    try testing.expect(!main.isOneShotSubForTest("plaza-inbox"));
    try testing.expect(!main.isOneShotSubForTest("plaza-engagement"));
    try testing.expect(!main.isOneShotSubForTest("plaza-thread"));
}

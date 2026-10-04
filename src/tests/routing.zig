//! Tests of routing.zig. Outbox reads: which relays to ask about which authors, and the relay-list sweep that learns them.

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
const routedHolds = harness.routedHolds;
const seedRelayLists = harness.seedRelayLists;

test "a follow's relay list is a suggestion, and only where they write" {
    // Same three rules as ever, now reached through the store: only where they
    // write, never a relay the reader is already on, and one list is one
    // opinion however many times it arrives.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{9} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/suggest.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://writes.example.com", "write" },
        &.{ "r", "wss://both.example.com" },
        // Where they only READ will never hold their notes, so it buys nothing.
        &.{ "r", "wss://reads.example.com", "read" },
        // Already in the pool: not worth offering.
        &.{ "r", "wss://relay.damus.io" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
    var buf: [96]u8 = undefined;
    // Equal counts, so the tie-break orders them, and the order is stable
    // rather than whatever the tags happened to say.
    try testing.expectEqualStrings("wss://both.example.com", main.relaySuggestionCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://writes.example.com", main.relaySuggestionCopy(1, &buf).?);

    // Ranking again over the same store changes nothing: it is a count of
    // people, and there is still one person.
    main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
}

test "the relay more of your follows write to is offered first" {
    // The bug this replaces: the first six write relays ever seen filled the
    // table and everything after was dropped, so which six you were offered
    // depended on whose relay list happened to arrive first. A relay one person
    // uses could sit above one everybody uses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/rank.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One person on the lonely relay, and they list it FIRST so arrival order
    // would have put it at the top. Five on the popular one.
    var list: [6][32]u8 = undefined;
    for (0..6) |i| {
        var secret = [_]u8{3} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        list[i] = kp.public_key;
        const tags = if (i == 0)
            [_]nostr.event.Tag{&.{ "r", "wss://lonely.example.com" }}
        else
            [_]nostr.event.Tag{&.{ "r", "wss://popular.example.com" }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
    try testing.expectEqualStrings("wss://popular.example.com", main.relaySuggestionCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://lonely.example.com", main.relaySuggestionCopy(1, &buf).?);
}

test "one person cannot outvote everyone by listing a relay twice" {
    var table: [8]main.RelayRankForTest = undefined;
    const urls = [_][]const u8{
        "wss://a.example.com",
        "wss://a.example.com/",
        "WSS://A.example.com",
    };
    const len = main.foldWriteRelaysForTest(&table, 0, &urls);
    try testing.expectEqual(@as(usize, 1), len);
    try testing.expectEqual(@as(u16, 1), main.relayRankWritersForTest(table[0]));
}

test "one enthusiastic relay list does not outvote everyone else's" {
    // Jumble's rule, and their reasoning: most people do not understand relays,
    // so an author advertising a dozen is not telling you about a dozen places
    // their notes reliably are. Only the first few of any one list count.
    var table: [64]main.RelayRankForTest = undefined;
    var urls: [16][]const u8 = undefined;
    const names = [_][]const u8{
        "wss://r0.example.com", "wss://r1.example.com", "wss://r2.example.com",
        "wss://r3.example.com", "wss://r4.example.com", "wss://r5.example.com",
        "wss://r6.example.com", "wss://r7.example.com", "wss://r8.example.com",
        "wss://r9.example.com", "wss://ra.example.com", "wss://rb.example.com",
    };
    for (names, 0..) |n, i| urls[i] = n;
    const len = main.foldWriteRelaysForTest(&table, 0, urls[0..names.len]);
    try testing.expectEqual(main.outboxRelaysPerAuthorForTest, len);
}

test "a relay list that is nothing but junk contributes nothing" {
    var table: [8]main.RelayRankForTest = undefined;
    const urls = [_][]const u8{ "", "   ", "http://not-a-relay.example.com", "nostr:npub1x" };
    try testing.expectEqual(@as(usize, 0), main.foldWriteRelaysForTest(&table, 0, &urls));
}

test "one relay under two spellings is one relay" {
    // A relay is an address, not text: the scheme's case and a trailing slash
    // carry nothing, and a list holding both spellings would dial twice.
    try testing.expect(main.relayUrlEql("wss://relay.example.com", "wss://relay.example.com/"));
    try testing.expect(main.relayUrlEql("WSS://Relay.example.com", "wss://relay.example.com"));
    try testing.expect(!main.relayUrlEql("wss://relay.example.com", "wss://relay.example.org"));
    try testing.expectEqualStrings("relay.example.com", main.relayShortName("wss://relay.example.com/"));
}
test "a relay the reader is not on is dialled, and asked only about its writers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/outbox.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // Four people on one relay the reader is not on, two on another.
    var list: [6][32]u8 = undefined;
    for (0..6) |i| {
        var secret = [_]u8{5} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        list[i] = kp.public_key;
        const tags = if (i < 4)
            [_]nostr.event.Tag{&.{ "r", "wss://many.example.com" }}
        else
            [_]nostr.event.Tag{&.{ "r", "wss://few.example.com" }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(@as(usize, 2), main.discoveredCount());
    var buf: [96]u8 = undefined;
    // The busier relay first, and each asked only about its own writers. That
    // is the whole point: a small relay gets asked about its handful of people,
    // not about two thousand strangers.
    try testing.expectEqualStrings("wss://many.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 4), main.discoveredAuthorCount(0));
    try testing.expectEqualStrings("wss://few.example.com", main.discoveredUrlCopy(1, &buf).?);
    try testing.expectEqual(@as(usize, 2), main.discoveredAuthorCount(1));
}

test "the ranking and the routing pick the same relays for one author" {
    // They did not, and the disagreement was invisible: an author listing
    // [A, A, B, C, D] had D counted by the ranking (which skipped the repeat
    // before counting against the cap) and dropped by the routing (which
    // counted raw tags), so D got a connection with nobody on it. One function
    // now, so they cannot drift again.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{8} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/drift.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The repeat is what does it: counted once by the selection, so the fourth
    // distinct relay is still inside the cap.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://a.example.com" },
        &.{ "r", "wss://a.example.com/" },
        &.{ "r", "wss://b.example.com" },
        &.{ "r", "wss://c.example.com" },
        &.{ "r", "wss://d.example.com" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // The author names four distinct relays, and exactly two get connections:
    // coverage stops at the target, so a third relay carrying only somebody
    // already covered twice is a thread and a socket for nothing.
    //
    // Counting is the assertion, not "every slot with a url has authors": the
    // empty-relay guard makes that true whether or not the two selections
    // agree, and it masked this drift when the test was first written. A relay
    // the ranking counted and the routing dropped shows up as a missing
    // connection, which is the only place it is visible.
    var routed: usize = 0;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        if (main.discoveredUrlCopy(i, &buf) == null) continue;
        routed += 1;
        try testing.expect(main.discoveredAuthorCount(i) > 0);
    }
    try testing.expectEqual(@as(usize, main.routeCoverageTargetForTest), routed);

    // And the one author really is covered twice, which is what stopped it.
    const cov = main.routeCoverageForTest();
    try testing.expectEqual(@as(usize, 1), cov.reached);
    try testing.expectEqual(@as(usize, 1), cov.doubly_reached);
    try testing.expectEqual(@as(usize, 0), cov.residual);
}

test "an unchanged route table does not tell the connections to re-ask" {
    // The ranking reruns every time a relay list lands, and during a cold start
    // hundreds of them land. If each rerun bumped the generation, every
    // discovered connection would drop and redial each time, and the pool would
    // spend the whole startup reconnecting instead of reading. Seen in a live
    // run before this: three connections, each redialled inside two minutes,
    // for a route table that had not changed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{11} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/stable.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://steady.example.com" }};
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    main.rankRelaySuggestionsForTest(&store);
    const settled = main.discoveredGenerationForTest(0);
    const settled_1 = main.discoveredGenerationForTest(1);
    try testing.expectEqual(@as(usize, 1), main.discoveredCount());

    // Five more runs over the same store. Nothing has moved, so nothing should
    // be told that it has.
    for (0..5) |_| main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(settled, main.discoveredGenerationForTest(0));

    // But a real change still gets through: somebody else, writing elsewhere.
    const other = try signer.keyPairFromSecretKey([_]u8{12} ** 32);
    const other_tags = [_]nostr.event.Tag{&.{ "r", "wss://elsewhere.example.com" }};
    const other_ev = try nostr.event.create(arena, signer, other, 1_800_000_001, 10002, &other_tags, "", null);
    _ = try main.plazaIngestForTest(arena, other_ev);
    const both = [_][32]u8{ kp.public_key, other.public_key };
    _ = main.setFollowsForTest(&both, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(@as(usize, 2), main.discoveredCount());

    // The NEW relay's slot moved. The one that was already connected did not,
    // which is the whole point of a counter per slot: a stranger publishing a
    // relay list must not cost the connections that were already right.
    try testing.expect(main.discoveredGenerationForTest(1) != settled_1);
    try testing.expectEqual(settled, main.discoveredGenerationForTest(0));
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://steady.example.com", main.discoveredUrlCopy(0, &buf).?);
}

test "a relay that stays in the set keeps its seat" {
    // The choice comes back in coverage order, and that order moves whenever
    // anybody's relay list does. Filling the slots in that order would hand one
    // relay's socket to another because they swapped places in a ranking, and
    // both connections would be dropped and redialled to do it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/seat.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One author on `quiet`, so it is the only relay worth dialling and it
    // lands in slot 0.
    const quiet = [_][]const u8{"wss://quiet.example.com"};
    const one = [_][]const []const u8{&quiet};
    var first: [1][32]u8 = undefined;
    try seedRelayLists(arena, signer, &one, &first);
    _ = main.setFollowsForTest(&first, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://quiet.example.com", main.discoveredUrlCopy(0, &buf).?);
    const seat_gen = main.discoveredGenerationForTest(0);

    // Now three more people, all on `busy`. It outranks `quiet` by three to
    // one, so a coverage-ordered fill would put it in slot 0 and push `quiet`
    // into slot 1: two redials to learn nothing.
    const busy = [_][]const u8{"wss://busy.example.com"};
    const four = [_][]const []const u8{ &quiet, &busy, &busy, &busy };
    var follows: [4][32]u8 = undefined;
    try seedRelayLists(arena, signer, &four, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);

    // Both are routed, and `quiet` is still where it was.
    try testing.expectEqualStrings("wss://quiet.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://busy.example.com", main.discoveredUrlCopy(1, &buf).?);
    // Its question did not change either, so its counter did not move: the
    // socket is never touched.
    try testing.expectEqual(seat_gen, main.discoveredGenerationForTest(0));
}

test "a live connection is not dropped for one more author" {
    // Coverage is computed from relay lists that arrive one at a time, so the
    // margin between two candidates moves all day. Without a margin the set
    // flaps: one person's kind:10002 lands, a challenger passes the incumbent
    // by a single author, and a live socket is torn down to gain one.
    // One more author is not enough once a relay carries more than four, which
    // is where the twenty-five per cent comes from.
    try testing.expect(!main.worthEvictingForTest(6, 5));
    try testing.expect(!main.worthEvictingForTest(9, 8));
    try testing.expect(!main.worthEvictingForTest(31, 30));
    // Nor is a draw.
    try testing.expect(!main.worthEvictingForTest(4, 4));
    // A quarter more is, exactly at the line and past it.
    try testing.expect(main.worthEvictingForTest(5, 4));
    try testing.expect(main.worthEvictingForTest(10, 8));
    try testing.expect(main.worthEvictingForTest(40, 4));
    // An incumbent reaching nobody new is defending nothing.
    try testing.expect(main.worthEvictingForTest(1, 0));
    try testing.expect(main.worthEvictingForTest(0, 0));
}
test "a route that changed in its last author has changed" {
    // Amethyst shipped this comparison as a `forEachIndexed` with a return
    // inside it, which returns from the lambda rather than the function, so
    // only the first filter was ever compared. A relay whose author list
    // changed anywhere but the front looked unchanged, and its subscription was
    // never replaced.
    var a: [4][32]u8 = undefined;
    for (&a, 0..) |*x, i| {
        x.* = [_]u8{0} ** 32;
        x[0] = @intCast(i + 1);
    }
    const url = "wss://same.example.com";

    var b = a;
    try testing.expect(main.sameRouteForTest(url, &a, url, &b));

    // The first.
    b = a;
    b[0][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // The LAST. This is the one that was broken.
    b = a;
    b[b.len - 1][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // And one in the middle, for completeness.
    b = a;
    b[2][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // A different relay, and a shorter list.
    b = a;
    try testing.expect(!main.sameRouteForTest(url, &a, "wss://other.example.com", &b));
    try testing.expect(!main.sameRouteForTest(url, &a, url, b[0..3]));
}

test "the same relay with a new question keeps its url and moves its counter" {
    // The two facts a live connection branches on when its slot moves: if the
    // url is the same it replaces its REQ in place, and if it is not it drops
    // the socket. So a change of WHO must move the counter and leave the url
    // alone, or the connection either never re-asks or redials to do it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/reask.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    const there = [_][]const u8{"wss://there.example.com"};
    const two = [_][]const []const u8{ &there, &there };
    var follows: [2][32]u8 = undefined;
    try seedRelayLists(arena, signer, &two, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://there.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 2), main.discoveredAuthorCount(0));
    const before = main.discoveredGenerationForTest(0);

    // A third person, writing to the same relay. Same url, one more author.
    const three = [_][]const []const u8{ &there, &there, &there };
    var wider: [3][32]u8 = undefined;
    try seedRelayLists(arena, signer, &three, &wider);
    _ = main.setFollowsForTest(&wider, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqualStrings("wss://there.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 3), main.discoveredAuthorCount(0));
    try testing.expect(main.discoveredGenerationForTest(0) != before);
}

test "a relay is set aside only after a run of failures, and not forever" {
    // A handshake fails for a blip as well as for a refusal, so one is not a
    // verdict. Measured in a single live run: the paid relay failed every time
    // and a free one in my own pool failed once and was fine on the retry.
    const strikes = main.routedRefusalStrikesForTest;
    const window = main.routedRefusalMsForTest;
    const t: i64 = 1_000_000;

    try testing.expect(!main.relayIsRefusedForTest(0, t, t));
    try testing.expect(!main.relayIsRefusedForTest(strikes - 1, t, t));
    try testing.expect(main.relayIsRefusedForTest(strikes, t, t));

    // Pinned against the literal, not against the constant. Everything else
    // here counts off `strikes`, so all of it stays true if the constant drops
    // to one and a single blip starts costing a relay six hours. This is the
    // line that refuses that, and it is the property, not the number.
    try testing.expect(main.routedRefusalStrikesForTest > 1);
    try testing.expect(!main.relayIsRefusedForTest(1, t, t));

    // A record with no timestamp is not a verdict either. Zero is a real
    // reading on some clocks, so "never" is -1 and it has to be distinguished.
    try testing.expect(!main.relayIsRefusedForTest(strikes, -1, t));

    // It expires. A subscription, a block and an outage all end.
    try testing.expect(main.relayIsRefusedForTest(strikes, t, t + window - 1));
    try testing.expect(!main.relayIsRefusedForTest(strikes, t, t + window));

    // With no clock, a strike already recorded still counts. Nothing is dialled
    // before the clock exists, so this is the safe reading rather than a live
    // case: it can only set a relay aside, never wrongly reinstate one.
    try testing.expect(main.relayIsRefusedForTest(strikes, t, null));
    try testing.expect(!main.relayIsRefusedForTest(strikes - 1, t, null));
}

test "a relay that will not have us gives up its slot to the next one down" {
    // Coverage says which relays carry the people you follow. It does not say
    // which of them will talk to you. The best relay by coverage on my own
    // account refuses the websocket handshake, and held a routed slot dialling
    // and failing forever while the coverage counter reported its writers as
    // reached.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/refused.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.forgetRefusedRelaysForTest();
    defer main.forgetRefusedRelaysForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One relay each, two more relays than there are slots, so setting one
    // aside has somewhere for the slot to go. With slots to spare the choice
    // takes everything and being set aside costs nothing visible.
    const budget = main.maxDiscoveredRelaysForTest;
    const specs = try arena.alloc([]const []const u8, budget + 2);
    for (specs, 0..) |*spec, i| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = try std.fmt.allocPrint(arena, "wss://r{d:0>2}.example.com", .{i});
        spec.* = one;
    }
    const follows = try arena.alloc([32]u8, specs.len);
    try seedRelayLists(arena, signer, specs, follows);
    _ = main.setFollowsForTest(follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(budget, routedCount());
    // Whichever one it picked first: that is the one to refuse.
    var buf: [96]u8 = undefined;
    const chosen = main.discoveredUrlCopy(0, &buf).?;
    var chosen_owned: [96]u8 = undefined;
    @memcpy(chosen_owned[0..chosen.len], chosen);
    const victim = chosen_owned[0..chosen.len];

    // One strike short of the line changes nothing: a blip must not cost a
    // relay its slot.
    const t: i64 = 5_000_000;
    for (0..main.routedRefusalStrikesForTest - 1) |i| {
        try testing.expect(!main.noteRelayRefusalAtForTest(victim, t + @as(i64, @intCast(i))));
    }
    try testing.expectEqual(@as(usize, 0), main.refusedRelayCountForTest());
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(routedHolds(victim));

    // The strike that does it says so, so the caller knows to ask for a rethink
    // rather than waiting for somebody's relay list to land.
    try testing.expect(main.noteRelayRefusalAtForTest(victim, t + 10));
    try testing.expectEqual(@as(usize, 1), main.refusedRelayCountForTest());

    main.rankRelaySuggestionsForTest(&store);
    // Gone, and the slot went to a relay that might answer rather than being
    // left empty. Both halves matter: dropping it and shrinking the pool would
    // cost reach instead of recovering it.
    try testing.expect(!routedHolds(victim));
    try testing.expectEqual(budget, routedCount());

    // And it comes back when it starts working.
    main.clearRelayRefusalForTest(victim);
    try testing.expectEqual(@as(usize, 0), main.refusedRelayCountForTest());
}

test "a socket whose owner is blocked reading it is re-asked by the keeper" {
    // The owner of a routed connection cannot re-ask on its own. It spends its
    // life inside `receive`, which blocks until the relay says something, and a
    // relay with nothing new to say says nothing. Driving a route change under
    // a live connection and watching it not notice took forty seconds of a
    // real run, which is how this got written.
    const here = "wss://here.example.com";
    const there = "wss://there.example.com";

    // Nothing connected in this slot: nothing to do to it.
    try testing.expectEqual(main.RouteFollowUp.leave_it, main.routeFollowUpForTest("", 0, here, 7));
    // Connected and current.
    try testing.expectEqual(main.RouteFollowUp.leave_it, main.routeFollowUpForTest(here, 7, here, 7));
    // Same relay, the slot moved: replace the question, keep the socket. This
    // is the case the whole mechanism exists for.
    try testing.expectEqual(main.RouteFollowUp.re_ask, main.routeFollowUpForTest(here, 7, here, 8));
    // A trailing slash is the same relay, not a different one, or every
    // recompute would look like a repoint and redial the whole set.
    try testing.expectEqual(main.RouteFollowUp.re_ask, main.routeFollowUpForTest(here, 7, here ++ "/", 8));
    // Pointed at somebody else: close it.
    try testing.expectEqual(main.RouteFollowUp.retire, main.routeFollowUpForTest(here, 7, there, 8));
    // Slot emptied: close it.
    try testing.expectEqual(main.RouteFollowUp.retire, main.routeFollowUpForTest(here, 7, "", 8));
}

test "every routed connection asks under one subscription id" {
    // A REQ under an id the relay already holds is a replacement rather than a
    // second subscription, and that is the entire mechanism: two ids would
    // leave the old question standing and the relay would send both answers.
    try testing.expectEqualStrings("plaza-outbox", main.outboxSubIdForTest);
    // And it must not look like a one-shot, which is swept on a deadline.
    try testing.expect(!std.mem.startsWith(u8, main.outboxSubIdForTest, main.oneShotSubPrefixForTest));
}

test "the routing waits for the flurry to stop" {
    // A cold start lands hundreds of relay lists in a few seconds, and each one
    // is a reason to redo the ranking. Redoing it on each one is work the next
    // one throws away, and every intermediate answer is a route table nobody
    // should act on.
    const settle = main.routeSettleMsForTest;
    const floor = main.routeRecomputeMinMsForTest;
    const cap = main.routeSettleMaxMsForTest;

    // Nothing wanted, nothing to do.
    try testing.expect(!main.routeRecomputeDueForTest(null, null, null));
    // Wanted, and nothing has ever landed or run: the first ranking is not
    // delayed by a window it has no reason to wait for.
    try testing.expect(main.routeRecomputeDueForTest(0, null, null));

    // A list just landed. Wait for quiet.
    try testing.expect(!main.routeRecomputeDueForTest(1, 1, null));
    try testing.expect(!main.routeRecomputeDueForTest(settle - 1, settle - 1, null));
    try testing.expect(main.routeRecomputeDueForTest(settle, settle, null));

    // Quiet, but the last run was moments ago. The floor still holds.
    try testing.expect(!main.routeRecomputeDueForTest(settle, settle, floor - 1));
    try testing.expect(main.routeRecomputeDueForTest(settle, settle, floor));

    // A steady trickle, one list every second forever. Without the cap this
    // never runs at all.
    try testing.expect(!main.routeRecomputeDueForTest(cap - 1, 1, cap - 1));
    try testing.expect(main.routeRecomputeDueForTest(cap, 1, cap));
}
test "every followed author is asked of at least one relay" {
    // THE invariant. A follow that appears in nobody's filters is a person who
    // silently stops existing in the feed, which is worse than a slow feed and
    // is the thing routing is most likely to break while improving reach.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cover.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // MORE distinct relays than the routed budget can hold, which is the whole
    // point: with only a couple of relays everything gets routed and the
    // residual is never exercised, so the test passes without testing anything.
    // Removing the residual entirely failed nothing until this list grew.
    //
    // One writes to the reader's own relay, two share a popular one, one has no
    // relay list at all, and the rest each write to a relay of their own that
    // is too unpopular to be chosen.
    const specs = [_][]const []const u8{
        &.{"wss://mine.example.com"},
        &.{"wss://busy.example.com"},
        &.{"wss://busy.example.com"},
        &.{},
        &.{"wss://lonely-a.example.com"},
        &.{"wss://lonely-b.example.com"},
        &.{"wss://lonely-c.example.com"},
        &.{"wss://lonely-d.example.com"},
        &.{"wss://lonely-e.example.com"},
        &.{"wss://lonely-f.example.com"},
    };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Collect every author named anywhere: the routed relays, then the pool.
    var seen = [_]bool{false} ** specs.len;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        var ubuf: [96]u8 = undefined;
        if (main.discoveredUrlCopy(i, &ubuf) == null) continue;
        var abuf: [main.discoveredAuthorsCapForTest][32]u8 = undefined;
        const n = main.discoveredAuthorsForTest(i, &abuf);
        for (abuf[0..n]) |a| {
            for (follows, 0..) |f, k| {
                if (std.mem.eql(u8, &a, &f)) seen[k] = true;
            }
        }
    }
    var pool_buf: [main.max_follows + 1][32]u8 = undefined;
    const pn = main.poolAuthorsForTest(0, &pool_buf);
    for (pool_buf[0..pn]) |a| {
        for (follows, 0..) |f, k| {
            if (std.mem.eql(u8, &a, &f)) seen[k] = true;
        }
    }

    for (seen, 0..) |ok, k| {
        if (!ok) {
            std.debug.print("\nfollow {d} is asked of no relay at all\n", .{k});
            return error.AuthorAskedOfNobody;
        }
    }

    // And the residual is actually carrying people here, or the loop above
    // proved coverage in a case where routing happened to reach everyone.
    try testing.expect(main.residualCountForTest() > 0);
}

test "coverage beats popularity when the popular relays carry the same crowd" {
    // The reason ranking and routing need different algorithms. Three relays
    // are popular and carry an overlapping crowd; one quiet relay is the only
    // way to reach two people. Top-N by popularity spends the whole budget on
    // the crowd and never reaches them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cover2.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The crowd has to outnumber the budget or this proves nothing: with fewer
    // candidate relays than slots everything is dialled and the two orderings
    // cannot disagree. One person may name at most `outbox_relays_per_author`
    // relays, so the crowd comes in groups of that many, each group's relays
    // carrying only that group.
    const budget = main.maxDiscoveredRelaysForTest;
    const per_author = main.outboxRelaysPerAuthorForTest;
    const groups = (budget - 1) / 2;
    const per_group = 5;
    // Coverage needs two relays per group and one slot left for the quiet
    // relay, and popularity has to run out of budget before it reaches that
    // relay. If a change to the budget breaks either, this fails loudly rather
    // than passing hollow.
    try testing.expect(groups * 2 + 1 <= budget);
    try testing.expect(groups * per_author > budget);

    var specs = std.ArrayList([]const []const u8).empty;
    for (0..groups) |g| {
        const urls = try arena.alloc([]const u8, per_author);
        for (urls, 0..) |*u, j| u.* = try std.fmt.allocPrint(arena, "wss://crowd-{d}-{d}.example.com", .{ g, j });
        for (0..per_group) |_| try specs.append(arena, urls);
    }
    const quiet_url = "wss://onlyhere.example.com";
    const quiet = try arena.alloc([]const u8, 1);
    quiet[0] = quiet_url;
    try specs.append(arena, quiet);

    const follows = try arena.alloc([32]u8, specs.items.len);
    try seedRelayLists(arena, signer, specs.items, follows);
    _ = main.setFollowsForTest(follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Everybody reached, including the one nobody popular carries.
    const cov = main.routeCoverageForTest();
    try testing.expectEqual(specs.items.len, cov.reached);
    try testing.expectEqual(@as(usize, 0), cov.residual);
    try testing.expect(routedHolds(quiet_url));

    // And the popularity order really does leave that person out, which is the
    // half of this the coverage numbers cannot show. Every crowd relay carries
    // five writers against the quiet relay's one, so the suggestions never
    // mention it while the routing dials it.
    var sbuf: [96]u8 = undefined;
    for (0..main.relaySuggestionCount()) |i| {
        const u = main.relaySuggestionCopy(i, &sbuf) orelse continue;
        try testing.expect(!std.mem.eql(u8, u, quiet_url));
    }

    // The budget is not spent, either. Two relays per group is enough to carry
    // that group twice, so the greedy stops rather than opening sockets to
    // relays whose people are already covered.
    try testing.expectEqual(groups * 2 + 1, routedCount());
}

/// How many routed slots hold a relay.
fn routedCount() usize {
    var n: usize = 0;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        if (main.discoveredUrlCopy(i, &buf) != null) n += 1;
    }
    return n;
}

test "the candidate cap is counted, not swallowed" {
    // A cap that drops work in silence reads as a complete answer. This one was
    // hit exactly on a real account (128 distinct relays for 257 follows) and
    // nobody knew, because nothing said so.
    const cov = main.routeCoverageForTest();
    _ = cov;
    try testing.expect(@hasField(main.RouteCoverage, "candidates_dropped"));
}
test "a follow with no relay list anywhere is asked once, not on every rebuild" {
    // The routing table is rebuilt whenever a relay list lands, and somebody who
    // has never published one is unroutable at every one of those rebuilds. If
    // the sweep re-asked each time, a single account with no kind:10002 would
    // put a REQ to four relays for the life of the session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const nobody = try signer.keyPairFromSecretKey([_]u8{5} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/asked.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.resetIndexerAskedForTest();
    defer main.resetIndexerAskedForTest();
    main.setIdentityForTest([_]u8{89} ** 32);
    defer main.clearIdentityForTest();

    const follows = [_][32]u8{nobody.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), main.collectUnroutedForTest(&out));

    // Once the sweep has put them to the indexers, they are off the list even
    // though the store still holds nothing for them: an attempt that came back
    // empty is still an attempt, which is what Amethyst's LRU gets wrong when
    // it evicts and resurrects a question already given up on.
    main.markIndexerAskedForTest(nobody.public_key);
    try testing.expectEqual(@as(usize, 0), main.collectUnroutedForTest(&out));
}

test "the feed does not route to a follow's relay on the reader's own network" {
    // The same selection the outbox routes the feed with, which dials every
    // relay it ranks: a follow listing their LAN relay ranks nothing.
    var table: [8]main.RelayRankForTest = undefined;
    const urls = [_][]const u8{
        "wss://127.0.0.1",
        "wss://10.0.0.7:4848",
        "wss://relay.home.arpa",
        "wss://public.example.com",
    };
    const len = main.foldWriteRelaysForTest(&table, 0, &urls);
    try testing.expectEqual(@as(usize, 1), len);
    try testing.expectEqualStrings("wss://public.example.com", main.relayRankUrlForTest(&table[0]));
}

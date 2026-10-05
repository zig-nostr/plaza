//! Tests of ingest.zig. The per-relay reader threads, their reconnect ladder, and the feed watch.

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
const signedNote = harness.signedNote;

test "the feed asks about the notes it is SHOWING, not only the ones that arrived" {
    // The watch list was built purely from events coming down the wire, and the
    // feed's own REQ carries a `since` off the newest stored note. So on any
    // launch but the first, the feed draws notes nobody has asked a relay about
    // and every one of them reads zero replies, zero reposts, zero likes and
    // zero sats for the session. A guest saw it worst: a starter-pack feed is
    // nearly all store once it has been read once, which made it look like
    // guests do not get counts at all.
    var notes: [3]main.Note = undefined;
    for (&notes, 0..) |*n, i| {
        n.* = main.Note{ .created_at = 1_800_000_000 };
        n.id = @intCast(100 + i);
        n.event_id = [_]u8{@intCast(0xA0 + i)} ** 32;
    }
    main.publishFeedWatchForTest(notes[0..]);

    // A socket that has heard nothing still has the whole visible feed to ask
    // about. This is the case that used to watch nothing at all.
    var ids: [main.engagementWatchCapForTest]i64 = undefined;
    var hex: [main.engagementWatchCapForTest][64]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), main.mergeFeedWatchForTest(&ids, &hex, 0));
    try testing.expectEqual(@as(i64, 100), ids[0]);
    try testing.expectEqualStrings("a0" ** 32, &hex[0]);

    // What the socket already knew is kept, and nothing is asked about twice.
    ids[0] = 100;
    hex[0] = [_]u8{'z'} ** 64;
    try testing.expectEqual(@as(usize, 3), main.mergeFeedWatchForTest(&ids, &hex, 1));

    // A redraw of the same feed is not news. Every tick rebuilds it, and
    // re-asking every relay four times a second is a different bug.
    const gen = main.feedWatchGenerationForTest();
    main.publishFeedWatchForTest(notes[0..]);
    try testing.expectEqual(gen, main.feedWatchGenerationForTest());

    // A feed that actually moved is.
    main.publishFeedWatchForTest(notes[0..2]);
    try testing.expect(main.feedWatchGenerationForTest() != gen);
}
test "a relay that keeps dropping is asked less and less often" {
    // The wait doubles from three seconds and stops at five minutes, so a relay
    // that is down, that has stopped taking this reader, or that accepts the
    // handshake and hangs up is not dialled twelve hundred times an hour for as
    // long as the app is open.
    try testing.expectEqual(@as(u64, 3_000), main.reconnectDelayMs(0));
    try testing.expectEqual(@as(u64, 6_000), main.reconnectDelayMs(1));
    try testing.expectEqual(@as(u64, 12_000), main.reconnectDelayMs(2));
    try testing.expectEqual(@as(u64, 96_000), main.reconnectDelayMs(5));
    try testing.expectEqual(@as(u64, 300_000), main.reconnectDelayMs(7));
    // And it stops there rather than growing into hours, or wrapping.
    try testing.expectEqual(@as(u64, 300_000), main.reconnectDelayMs(63));

    // The ladder is cleared by a connection that LASTED, never by one that
    // merely opened. A relay that accepts the socket and drops it immediately
    // is the case this exists for: without the rule its ladder resets on every
    // open and it is redialled at three seconds forever.
    try testing.expectEqual(@as(u6, 1), main.nextReconnectAttempts(0, 1_200));
    try testing.expectEqual(@as(u6, 2), main.nextReconnectAttempts(1, 59_999));
    try testing.expectEqual(@as(u6, 0), main.nextReconnectAttempts(5, 60_000));
    try testing.expectEqual(@as(u6, 0), main.nextReconnectAttempts(63, 3_600_000));
    // A clock that reads backwards must not clear it either.
    try testing.expectEqual(@as(u6, 4), main.nextReconnectAttempts(3, -1));
    // And the count saturates instead of wrapping back to a short wait.
    try testing.expectEqual(@as(u6, 63), main.nextReconnectAttempts(63, 0));
}
test "eight relays that drop together do not come back together" {
    // The whole pool goes down on one network blip, so without a spread all
    // eight threads redial in the same millisecond, and keep doing it, forever.
    // Assert the consequence: eight distinct wake-up times, none of them more
    // than a quarter past the wait.
    const wait = main.reconnectDelayMs(0);
    var seen: [8]u64 = undefined;
    for (0..8) |i| {
        const jitter = main.reconnectJitterMs(wait, i, 0);
        try testing.expect(jitter <= wait / 4);
        seen[i] = wait + jitter;
    }
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| {
            if (a == b) return error.RelaysStillInLockstep;
        }
    }

    // Two relays that DID start aligned are separated by the attempt count, so
    // a slot that fails while its neighbour recovers drifts apart from it.
    try testing.expect(main.reconnectJitterMs(wait, 3, 0) != main.reconnectJitterMs(wait, 3, 1));
}
test "a note's id is remembered once, and the table is bounded" {
    var ids: [main.engagementWatchCapForTest]i64 = undefined;
    var hex: [main.engagementWatchCapForTest][64]u8 = undefined;
    var len: usize = 0;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x81} ** 32);

    const one = try signedNote(arena, signer, kp, 1_800_000_000, "first");
    main.rememberFeedIdForTest(&ids, &hex, &len, one);
    try testing.expectEqual(@as(usize, 1), len);

    // The same note arriving again, which is the ordinary case: several relays
    // carry it. It must not take a second slot, or the `#e` filter fills with
    // duplicates and the cap is reached on a fraction of the feed.
    main.rememberFeedIdForTest(&ids, &hex, &len, one);
    try testing.expectEqual(@as(usize, 1), len);

    const two = try signedNote(arena, signer, kp, 1_800_000_001, "second");
    main.rememberFeedIdForTest(&ids, &hex, &len, two);
    try testing.expectEqual(@as(usize, 2), len);

    // And it stops at the cap rather than writing past the array. The `#e`
    // filter has to stay a size relays accept.
    //
    // A note NOT already in the table, which the first version of this got
    // wrong: reusing `two` meant the dedup scan found it and returned before the
    // cap was ever consulted, so the assertion passed while the branch it exists
    // for was never reached.
    const fresh = try signedNote(arena, signer, kp, 1_800_000_002, "past the cap");
    len = main.engagementWatchCapForTest;
    main.rememberFeedIdForTest(&ids, &hex, &len, fresh);
    try testing.expectEqual(main.engagementWatchCapForTest, len);
}

//! Tests of view_chrome.zig. Menus, popovers, banners and the status chips around the content.

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

test "one straggler is not a fault, at any pool size" {
    // The redesign's at-rest bar reads "4/5 relays" in green while its working
    // bar reads "3/5" in amber. A bar that goes amber for one straggler is a bar
    // nobody reads.
    //
    // That was written as four fifths, which says the same thing ONLY for a pool
    // of five or more. At four relays four fifths demands four of four, so a
    // single relay down leaves the dot amber for good, and this test kept passing
    // while asserting exactly that, because the arithmetic moved under it when
    // the bootstrap list lost a relay. Stated against the sizes now, so the next
    // change to the list cannot quietly redefine health.
    try testing.expect(main.poolIsHealthyOfForTest(5, 5));
    try testing.expect(main.poolIsHealthyOfForTest(4, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(3, 5));

    try testing.expect(main.poolIsHealthyOfForTest(4, 4));
    try testing.expect(main.poolIsHealthyOfForTest(3, 4));
    try testing.expect(!main.poolIsHealthyOfForTest(2, 4));

    try testing.expect(main.poolIsHealthyOfForTest(2, 3));
    try testing.expect(!main.poolIsHealthyOfForTest(1, 3));

    // And nothing connected is never healthy, whatever the size. A one-relay
    // pool with nothing up satisfies "one straggler" on its own, which is why
    // the rule carries a second clause.
    try testing.expect(!main.poolIsHealthyOfForTest(0, 1));
    try testing.expect(main.poolIsHealthyOfForTest(1, 1));
    try testing.expect(!main.poolIsHealthyOfForTest(0, 5));

    // The pool the app is born with, with one relay down, has to be green.
    main.resetRelaysForTest();
    try testing.expect(main.poolIsHealthyForTest(main.bootstrap_relay_count_for_test - 1));
    try testing.expect(!main.poolIsHealthyForTest(0));
}
test "the offline banner says what still works" {
    // 11p's banner. A spinner would say the opposite of the truth: the store is
    // the app, so reading continues, and a note written now is kept.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes_len = 0;

    // No relay is up in a test, so the banner is the state under test.
    const p = try painted.Painted.render(arena, &model);
    const banner = p.fillRectOf(theme.palette.surface_offline) orelse return error.NoBanner;
    try testing.expect(banner.width > 100);
    // And it names what is waiting, when something is.
    model.outbox_pending = 3;
    const text = main.offlineBannerTextForTest(arena, model.outbox_pending, false);
    try testing.expect(std.mem.indexOf(u8, text, "3 notes are") != null);
}
test "a relay's badge says what it is for, everywhere it is shown" {
    main.resetRelaysForTest();
    try testing.expectEqualStrings("R·W", main.relayBadgeTextForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqualStrings("R", main.relayBadgeTextForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqualStrings("W", main.relayBadgeTextForTest(0));
}

test "the pool chip never reads more live relays than it has" {
    // Both halves come from one sample. A tick-old numerator against a live
    // denominator printed "5/3 relays" for a second after a removal.
    try testing.expect(!main.poolIsHealthyOfForTest(0, 5));
    try testing.expect(main.poolIsHealthyOfForTest(4, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(3, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(1, 0));
}
test "a paused pool is not worded or coloured as a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;

    // No relay is up in a test. Not paused: the amber failure strip.
    const down = try painted.Painted.render(arena, &model);
    try testing.expect(down.fillRectOf(theme.palette.surface_offline) != null);
    try testing.expect(down.frameOf("Resume relays") == null);

    // Paused: the same silence, but it is the reader's doing, so it is not amber
    // and it carries the way back.
    model.relays_paused = true;
    const paused = try painted.Painted.render(arena, &model);
    try testing.expect(paused.fillRectOf(theme.palette.surface_offline) == null);
    try testing.expect(paused.frameOf("Resume relays") != null);
    try testing.expect(std.mem.indexOf(u8, main.pausedBannerTextForTest(arena, 0), "paused") != null);
    try testing.expect(std.mem.indexOf(u8, main.pausedBannerTextForTest(arena, 2), "2 notes are waiting") != null);

    // And a list with nobody in it is not "no relay is answering".
    const none = main.offlineBannerTextForTest(arena, 0, true);
    try testing.expect(std.mem.indexOf(u8, none, "No relays are set up") != null);
    try testing.expect(std.mem.indexOf(u8, none, "answering") == null);
}

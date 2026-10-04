//! Tests of view_settings.zig. The settings sheet and the relay card.

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

test "a dormant seat in the middle does not leave the popover a hole" {
    // The popover used to index rows by SLOT, so a removed relay left a row
    // nobody wrote, and the arena hands out uninitialised memory that the
    // widget walker then follows. Removing a middle relay and opening the
    // popover is the exact press that reached it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetRelaysForTest();
    main.removeRelayForTest(1);
    main.cycleRelayForTest(2); // R·W -> R, the other way a row used to be skipped

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .relays;
    const tree = try buildTree(arena, &model);
    // The four survivors are named; the removed one is not.
    try testing.expect(findAnyText(tree.root, "relay.damus.io") != null);
    try testing.expect(findAnyText(tree.root, "nos.lol") == null);
    // And a read-only relay is listed rather than hidden: the chip counts it, so
    // a list that dropped it would disagree with the number beside it.
    try testing.expect(findAnyText(tree.root, "relay.primal.net") != null);
}
fn findKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findKind(child, kind)) |found| return found;
    }
    return null;
}

test "asking to log out brings the question into view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    model.stage = .settings;
    // The reader has scrolled to the foot of the page to find the button.
    main.update(&model, Msg{ .settings_scrolled = .{ .offset_y = 120, .viewport_extent_y = 500, .content_extent_y = 620 } }, &fx);
    try testing.expectEqual(@as(f32, 120), model.settings_scroll_y);

    main.update(&model, .logout_request, &fx);
    try testing.expect(model.logout_pending);
    try testing.expectEqual(main.settings_scroll_end, model.settings_scroll_y);
    // And the scroll view is told, which is what moves the page.
    const tree = try buildTree(arena, &model);
    const scroll = findKind(tree.root, .scroll_view) orelse return error.NoScroll;
    try testing.expectEqual(main.settings_scroll_end, scroll.value);

    // Reopening Settings starts at the top, not where the last visit asked for.
    main.update(&model, .close_settings, &fx);
    main.update(&model, .open_settings, &fx);
    try testing.expectEqual(@as(f32, 0), model.settings_scroll_y);
}

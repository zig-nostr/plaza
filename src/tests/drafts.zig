//! Tests of drafts.zig. Drafts: the note being written, kept across a restart, and the replies parked per thread.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig

test "a draft saved to disk keeps its content warning, and loses it with the draft" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var model = main.initialModel();
    model.draft_buffer.set("half a thought");
    model.warn_on = true;
    model.warn_buffer.set("politics");
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));

    // A fresh launch: the composer and the warning come back together.
    var next = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &next);
    try testing.expectEqualStrings("half a thought", next.draft());
    try testing.expect(next.warn_on);
    try testing.expectEqualStrings("politics", next.warn_draft());

    // A warning with no reason is still a warning.
    model.warn_buffer.clear();
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    var bare = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &bare);
    try testing.expect(bare.warn_on);
    try testing.expectEqual(@as(usize, 0), bare.warn_draft().len);

    // The warning switched off removes the file, so it cannot come back over a
    // draft that no longer wants it.
    model.warn_on = false;
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    var plain = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &plain);
    try testing.expectEqualStrings("half a thought", plain.draft());
    try testing.expect(!plain.warn_on);

    // And deleting the draft deletes the warning with it.
    model.warn_on = true;
    model.warn_buffer.set("politics");
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    main.writeDraftForTest(io, &tmp.dir, "", null);
    var gone = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &gone);
    try testing.expect(gone.draft_empty());
    try testing.expect(!gone.warn_on);
    main.writeDraftForTest(io, &tmp.dir, "a new draft", null);
    var fresh = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &fresh);
    try testing.expect(!fresh.warn_on);
}

test "refused notes wait beside the composer until Copy, and only Copy writes the clipboard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    defer main.forgetRefused();
    main.clearLastClipboardForTest();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("what I am typing");

    // Two refused, one of them covered. Neither touches the box or its
    // warning, and the clipboard is left alone.
    const covered = main.WarnCarry.fromTags(&.{&.{ "content-warning", "spoilers" }});
    try testing.expectEqual(main.RefusedBack.aside, main.giveDraftBack(&model, "the first", .{}));
    try testing.expectEqual(main.RefusedBack.aside, main.giveDraftBack(&model, "the second", covered));
    try testing.expectEqualStrings("what I am typing", model.draft());
    try testing.expect(!model.warn_on);
    try testing.expectEqualStrings("", main.lastClipboardForTest());
    // The warning stays with its own text.
    try testing.expect(!main.refusedWarnForTest(0).?.on);
    try testing.expect(main.refusedWarnForTest(1).?.on);

    // The composer says how many, with the two presses.
    const tree = try harness.buildTree(arena, &model);
    try testing.expect(harness.findAnyTextContaining(tree.root, "2 notes were not signed. They are kept here."));
    try testing.expect(harness.pressableByLabel(tree, tree.root, "Copy the notes that were not signed"));
    try testing.expect(harness.pressableByLabel(tree, tree.root, "Dismiss the notes that were not signed"));

    // Copy: both, oldest first, and the warning that could not come along is
    // said instead. The line goes with them.
    main.update(&model, .{ .refused_copy = .note }, &fx);
    try testing.expectEqualStrings("the first\n\nthe second", main.lastClipboardForTest());
    try testing.expectEqualStrings("Copied. Set its content warning again.", model.toast_text());
    try testing.expectEqual(@as(usize, 0), main.refusedCount(&model, .note));
    try testing.expect(!harness.findAnyTextContaining((try harness.buildTree(arena, &model)).root, "not signed"));

    // Dismiss lets them go and writes nothing.
    main.clearLastClipboardForTest();
    _ = main.giveDraftBack(&model, "let go of", .{});
    main.update(&model, .{ .refused_dismiss = .note }, &fx);
    try testing.expectEqual(@as(usize, 0), main.refusedCount(&model, .note));
    try testing.expectEqualStrings("", main.lastClipboardForTest());

    // An empty composer takes a refused note back with its warning.
    model.draft_buffer.clear();
    try testing.expectEqual(main.RefusedBack.box, main.giveDraftBack(&model, "the covered one", covered));
    try testing.expectEqualStrings("the covered one", model.draft());
    try testing.expect(model.warn_on);
    try testing.expectEqualStrings("spoilers", model.warn_draft());
}

test "kept refused notes stop at a cap that fits one copy, and say so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    defer main.forgetRefused();
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("typing");

    var long: [main.compose_capacity_for_test]u8 = undefined;
    @memset(&long, 'z');
    for (0..main.refused_slots) |_| {
        try testing.expectEqual(main.RefusedBack.aside, main.giveDraftBack(&model, &long, .{}));
    }
    try testing.expectEqual(main.RefusedBack.full, main.giveDraftBack(&model, "one too many", .{}));
    const tree = try harness.buildTree(arena_state.allocator(), &model);
    try testing.expect(harness.findAnyTextContaining(tree.root, "No room for more."));

    // All of them, at their longest, fit in the one copy the toolkit accepts.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .refused_copy = .note }, &fx);
    const copied = main.lastClipboardForTest();
    try testing.expectEqual(main.refused_slots * long.len + (main.refused_slots - 1) * 2, copied.len);
    try testing.expect(copied.len <= native_sdk.max_effect_clipboard_bytes);
}

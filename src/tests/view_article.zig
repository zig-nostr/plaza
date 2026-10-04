//! Tests of view_article.zig. The article reader: a long-form note's header, body and footer.

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
const articleStore = harness.articleStore;
const buildTree = harness.buildTree;
const countNodes = harness.countNodes;
const findAnyTextContaining = harness.findAnyTextContaining;
const longArticleBody = harness.longArticleBody;
const signedKind = harness.signedKind;

test "opening an article by id opens a reader, and a long one builds only what is on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x63} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "reader");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    const body = try longArticleBody(arena, 400);
    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "the-long-one" },
        &[_][]const u8{ "title", "A reasonably long article" },
        &[_][]const u8{ "summary", "What the article is about, in a sentence." },
        &[_][]const u8{ "t", "zig" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, body);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);
    // A level of its own, rooted at the article.
    try testing.expectEqual(@as(u16, 30023), model.thread_root.kind);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));

    const tree = try buildTree(arena, &model);
    // The head: title, summary and the reading time.
    try testing.expect(findAnyTextContaining(tree.root, "A reasonably long article"));
    try testing.expect(findAnyTextContaining(tree.root, "What the article is about, in a sentence."));
    try testing.expect(findAnyTextContaining(tree.root, "min read"));
    // The body, rendered: the first section's heading and paragraph are here, as
    // text rather than as markup.
    try testing.expect(findAnyTextContaining(tree.root, "Section 0"));
    try testing.expect(findAnyTextContaining(tree.root, "Paragraph number 0 says"));
    try testing.expect(!findAnyTextContaining(tree.root, "## Section 0"));
    // And the end of it is not: four hundred paragraphs are not built to show the
    // first screenful.
    try testing.expect(!findAnyTextContaining(tree.root, "Paragraph number 399 says"));
    try testing.expect(!findAnyTextContaining(tree.root, "Paragraph number 200 says"));
    try testing.expect(main.articleRowCountForTest(ev.id) > 20);
    try testing.expect(countNodes(tree.root) < 600);
}

/// The first widget whose text contains `needle`.
fn widgetContaining(widget: canvas.Widget, needle: []const u8) ?canvas.Widget {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return widget;
    for (widget.children) |child| {
        if (widgetContaining(child, needle)) |found| return found;
    }
    return null;
}

test "every part of a long article is drawn by some row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6d} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "every-row");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    // What a writer actually does, each at a size that used to lose text: a
    // poem in short stanzas, a listing longer than a row, a folded aside, and one
    // paragraph written as a single enormous line.
    var body = std.ArrayList(u8).empty;
    try body.appendSlice(arena, "Fold the notes in a `<details>` element if they run long.\n\n");
    for (0..150) |n| try body.print(arena, "Verse {d} of the poem\n\n", .{n});
    try body.appendSlice(arena, "```\n");
    for (0..500) |n| try body.print(arena, "listing line {d};\n", .{n});
    try body.appendSlice(arena, "```\n\n");
    try body.appendSlice(arena, "<details>\n<summary>Notes</summary>\n\nThe folded words.\n\n</details>\n\n");
    for (0..3000) |n| try body.print(arena, "word{d} ", .{n});
    try body.appendSlice(arena, "END_OF_THE_LONG_LINE\n\nThe last paragraph.\n");

    const tags = [_]nostr.event.Tag{ &[_][]const u8{ "d", "every-row" }, &[_][]const u8{ "title", "All of it" } };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, body.items);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);

    // Every row, drawn on its own, as the list draws it.
    const rows = main.articleRowCountForTest(ev.id);
    try testing.expect(rows > 2);
    const trees = try arena.alloc(AppUi.Tree, rows - 2);
    for (trees, 1..) |*tree, index| {
        var ui = AppUi.init(arena);
        const node = main.articleRowForTest(&ui, &model.thread_root, index);
        try testing.expect(!ui.failed);
        tree.* = try ui.finalize(node);
        // And a row stays a size the window can hold a few of at once.
        try testing.expect(countNodes(tree.root) < 200);
    }
    const Find = struct {
        fn in(all: []const AppUi.Tree, needle: []const u8) ?canvas.Widget {
            for (all) |t| {
                if (widgetContaining(t.root, needle)) |w| return w;
            }
            return null;
        }
    };
    for (0..150) |n| {
        const verse = try std.fmt.allocPrint(arena, "Verse {d} of the poem", .{n});
        try testing.expect(Find.in(trees, verse) != null);
    }
    // The listing is code from its first line to its last, across the rows it
    // was cut into: line for line, where prose would have run them together.
    const first = Find.in(trees, "listing line 0;") orelse return error.ListingStartMissing;
    const last = Find.in(trees, "listing line 499;") orelse return error.ListingEndMissing;
    try testing.expectEqual(first.kind, last.kind);
    try testing.expect(std.mem.indexOf(u8, last.text, "listing line 498;\nlisting line 499;") != null);
    try testing.expect(Find.in(trees, "The folded words.") != null);
    try testing.expect(Find.in(trees, "END_OF_THE_LONG_LINE") != null);
    try testing.expect(Find.in(trees, "The last paragraph.") != null);
}

test "a draft is not opened as though it were published" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x64} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "draft");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "unfinished" },
        &[_][]const u8{ "title", "Not ready" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30024, &tags, "Half a thought.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqualStrings("That is an unpublished draft.", model.toast_text());
    // And the reader will not draw one even if asked directly.
    try testing.expectEqual(@as(usize, 0), main.articleRowCountForTest(ev.id));
}

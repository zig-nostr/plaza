//! Tests of tuning.zig. App-wide numbers: layout metrics, caps, timers, effect keys and the image budget.

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
const openFullSettings = harness.openFullSettings;
const releaseDoc = harness.releaseDoc;
const threadNote = harness.threadNote;

test "the settings screen shows the identity, the way to the signer, and logout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Signed in, because half this screen is about the identity: a guest has no
    // profile to edit and no key to back up.
    main.setIdentityForTest([_]u8{9} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    try testing.expect(findAnyText(tree.root, "Settings") != null);
    // Every section the design names, in the order it names them.
    try testing.expect(findAnyText(tree.root, "IDENTITY") != null);
    try testing.expect(findAnyText(tree.root, "RELAYS") != null);
    try testing.expect(findAnyText(tree.root, "APPEARANCE") != null);
    try testing.expect(findAnyText(tree.root, "FEED") != null);
    // The identity card says what signs, and offers the way into the profile.
    try testing.expect(findAnyText(tree.root, "Signing via Notary") != null);
    try testing.expect(findAnyText(tree.root, "Edit profile") != null);
    try testing.expect(findAnyText(tree.root, "Copy npub") != null);
    // The key is NOT offered here, and that is the point. Backing it up happens
    // in the signer's own window, which is the process that holds it: Plaza
    // showing a key would be Plaza holding one. What this screen owes the
    // reader is the way to that window.
    try testing.expect(findAnyText(tree.root, "Reveal secret key") == null);
    // The way to that window is the "Open Notary" link on the signer row, which
    // needs both a keyholder holding the key and the window binary beside the
    // app. Neither is true of a bare test model, so its presence is not asserted
    // here; its absence from THIS screen is the property that matters.
    // So is the media proxy, which is a privacy setting with no other UI.
    try testing.expect(findAnyText(tree.root, "Media proxy") != null);
    try testing.expect(findAnyText(tree.root, "Load media previews") != null);
    // The logout entry point is present; the confirmation is not yet.
    try testing.expect(findAnyText(tree.root, "Log out") != null);
    try testing.expect(findAnyText(tree.root, "Cancel") == null);
    // The version line renders.
    // The version app.zon declares, not a literal. This line used to say
    // "Plaza 0.1.0" and passed happily while the shipped app was 0.2.2, because
    // both the screen and the test were reading the same stale copy.
    const shown = try std.fmt.allocPrint(arena, "Plaza {s}", .{main.plaza_version_for_test});
    try testing.expect(findAnyText(tree.root, shown) != null);
    try testing.expect(main.plaza_version_for_test.len > 0);
}
test "a feed row's estimated height is the sum of its measured parts" {
    // The virtual list prices unbuilt rows from this estimate, so it has to agree
    // with what the engine lays out. The literals are MEASURED from the running
    // app through the automation harness; the constants are the redesign's own
    // terms. Changing a term without re-measuring fails here, which is the drift
    // this pins. (It cannot catch the engine itself changing a metric: that shows
    // up as a live measurement mismatch, not a test failure.)
    const one_line = main.feed_row_chrome + main.body_line_height;
    try testing.expectApproxEqAbs(@as(f32, 126.125), one_line, 0.001);
    // The chrome is 12 above, the 36px identity block, 5 to the body, 10 to the
    // verbs, the verb strip, 14 below, and the hairline.
    try testing.expectApproxEqAbs(@as(f32, 108), main.feed_row_chrome, 0.001);
    // The verb row is a STATED height now. It used to be exactly the count's
    // line box, so the verbs sat hard against the rule above them and the row
    // below: a strip of icons rather than a row of controls.
    try testing.expectApproxEqAbs(@as(f32, 30), main.engagement_row_height, 0.001);
    // The metadata register is exactly 12px. `.size = .sm` would be 13.5, since
    // the size enum steps by one from the 14.5 body.
    try testing.expectApproxEqAbs(@as(f32, 12), main.meta_size, 0.001);
}
// A note's body, so a row under test has something to wrap.
fn ancestorNote(text: []const u8) main.Note {
    var note = threadNote(0xA1, 100, 0xAA);
    @memcpy(note.content_buf[0..text.len], text);
    note.content_len = @intCast(text.len);
    return note;
}

test "the rail between two discs actually paints" {
    // It did not, for as long as the nesting existed: the row pinned its
    // children to the top, so the disc's column was exactly as tall as the disc
    // and the rail, which grows into whatever is left, got nothing. A widget-tree
    // assertion cannot see that; the display list can.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Build = struct {
        var note: main.Note = undefined;
        var ancestor: main.Ancestor = undefined;
        fn ancestorRow(ui: *main.AppUi) main.AppUi.Node {
            return main.ancestorRowForTest(ui, &ancestor, true);
        }
    };
    Build.note = ancestorNote("Two lines of an ancestor, enough to make the row taller than its own disc so the rail has somewhere to run.");
    Build.ancestor = .{ .note = Build.note };

    const p = try painted.Painted.renderPiece(arena, &model, Build.ancestorRow, main.window_width, 300);
    // The rail hangs under the disc, on the disc's centre line.
    const x = main.thread_inset_for_test + main.avatar_size / 2;
    const top = main.ancestor_top_pad + main.avatar_size + 4;
    try testing.expect(p.hasFillAt(x, top + 6, theme.palette.border_hairline));
}

/// How tall a row actually lays out, and how many widgets it costs. The rows of
/// a windowed list are priced by constants, and a constant that says more than
/// the row draws is a scrollbar over nothing; one that says less is a list that
/// jumps as the reader scrolls into it.
fn measuredHeight(arena: std.mem.Allocator, model: *const main.Model, build: *const fn (*main.AppUi) main.AppUi.Node) !f32 {
    const p = try painted.Painted.renderPiece(arena, model, build, main.window_width, 4000);
    var bottom: f32 = 0;
    for (p.layout.nodes) |node| {
        // The root fills the box it was given, so it says nothing about the row.
        if (node.depth == 0) continue;
        const b = node.widget.frame.y + node.widget.frame.height;
        if (b > bottom) bottom = b;
    }
    return bottom;
}

test "every fixed-height thread row is priced at what it draws" {
    // Each of these was calibrated by hand and then drifted, which a windowed
    // list hides until the scrollbar is over nothing. An OCCLUDED level makes it
    // worse: it builds no rows, so its estimates are never corrected by a
    // measurement, and its restored scroll offset is measured against them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Rows = struct {
        fn ghost(ui: *main.AppUi) main.AppUi.Node {
            return main.ghostRowForTest(ui, false);
        }
        fn ghostCapped(ui: *main.AppUi) main.AppUi.Node {
            return main.ghostRowForTest(ui, true);
        }
        fn footer(ui: *main.AppUi) main.AppUi.Node {
            return main.listeningFooterForTest(ui);
        }
        fn outsideClosed(ui: *main.AppUi) main.AppUi.Node {
            return main.outsideGraphRowForTest(ui, false);
        }
        fn outsideOpen(ui: *main.AppUi) main.AppUi.Node {
            return main.outsideGraphRowForTest(ui, true);
        }
        fn showMore(ui: *main.AppUi) main.AppUi.Node {
            return main.showMoreRepliesForTest(ui);
        }
    };

    const cases = [_]struct { name: []const u8, build: *const fn (*main.AppUi) main.AppUi.Node, estimate: f32, lead: f32 }{
        .{ .name = "ghost", .build = Rows.ghost, .estimate = main.ghost_row_extent_for_test, .lead = main.ancestor_top_pad },
        .{ .name = "ghost capped", .build = Rows.ghostCapped, .estimate = main.ghost_row_extent_for_test, .lead = main.ancestor_top_pad },
        .{ .name = "listening footer", .build = Rows.footer, .estimate = main.listening_row_extent_for_test, .lead = 0 },
        .{ .name = "outside line closed", .build = Rows.outsideClosed, .estimate = main.outside_row_extent_for_test, .lead = 0 },
        .{ .name = "outside line open", .build = Rows.outsideOpen, .estimate = main.outside_row_extent_for_test, .lead = 0 },
        .{ .name = "show more", .build = Rows.showMore, .estimate = main.show_more_extent_for_test, .lead = 0 },
    };
    for (cases) |c| {
        const measured = try measuredHeight(arena, &model, c.build);
        const priced = c.estimate + c.lead;
        if (@abs(measured - priced) > 0.5) {
            std.debug.print("\n{s}: draws {d}, priced {d}\n", .{ c.name, measured, priced });
            return error.EstimateDisagreesWithLayout;
        }
    }
}

test "an ancestor row is priced at what it draws, one line and two" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const One = struct {
        var a: main.Ancestor = .{};
        fn row(ui: *main.AppUi) main.AppUi.Node {
            return main.ancestorRowForTest(ui, &a, true);
        }
    };

    const bodies = [_][]const u8{
        "One line.",
        // Comfortably over one line of the reading column, so the clamp fires.
        "Two lines of an ancestor, long enough that it wraps well past the width of the column it is drawn in, and then keeps going so the clamp has something to cut.",
    };
    for (bodies) |body| {
        var note = threadNote(0xA1, 100, 0xAA);
        @memcpy(note.content_buf[0..body.len], body);
        note.content_len = @intCast(body.len);
        // The same field the estimator prices from, filled the way the chain
        // walk fills it, so this measures the real path and not a parallel one.
        One.a = .{ .note = note, .lines = @intFromFloat(main.ancestorBodyLinesForTest(&note)) };

        const measured = try measuredHeight(arena, &model, One.row);
        // The NESTED unit: an ancestor's body is set one register down, and
        // that register is now boxed at the height it draws rather than at a
        // full body line.
        const priced = main.ancestor_top_pad + main.ancestor_row_chrome_for_test +
            @as(f32, @floatFromInt(One.a.lines)) * main.nested_line_height;
        if (@abs(measured - priced) > 0.5) {
            std.debug.print("\nancestor ({d} chars): draws {d}, priced {d}, lines {d}\n", .{ body.len, measured, priced, main.ancestorBodyLinesForTest(&One.a.note) });
            return error.EstimateDisagreesWithLayout;
        }
    }
}

test "a reply block's rail paints too" {
    // The ancestor row's rail has its own test, but the row that ACTUALLY
    // shipped without a rail is this one, and it is a different call site with
    // its own alignment. Guarding only the new code would have left the old bug
    // free to come back.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Build = struct {
        var block: main.ThreadBlock = undefined;
        var parent: main.Note = undefined;
        var of: main.Model = .{};
        fn row(ui: *main.AppUi) main.AppUi.Node {
            return main.replyBlockForTest(ui, &block, [_]u8{0} ** 32, true, true);
        }
    };
    const body = "A reply long enough to wrap past its own disc, so the rail below that disc has somewhere to run.";
    Build.parent = threadNote(0xB1, 200, 0xA1);
    @memcpy(Build.parent.content_buf[0..body.len], body);
    Build.parent.content_len = @intCast(body.len);
    Build.block = .{ .parent = &Build.parent, .children = &.{}, .deeper = &.{} };

    const p = try painted.Painted.renderPiece(arena, &model, Build.row, main.window_width, 600);
    const x = main.thread_inset_for_test + main.avatar_size / 2;
    // Below the disc, inside the block: the rail's own run.
    const y = 12 + main.avatar_size + 8;
    try testing.expect(p.hasFillAt(x, y, theme.palette.border_hairline));
}
test "a row's own frame holds everything it draws" {
    // The kind a pressable row is matters more than it looks. `wrappedVerticalExtentForWidth`
    // (the width-aware measurer) has branches for `row`, `column`, `card` and
    // friends and falls back to the CLASSIC intrinsic for everything else, where
    // a wrapping paragraph measures as a single line. So a row whose body wraps
    // measures one line tall whatever it draws: its content spills into the row
    // below, the hairline cuts through the text, and a press near the bottom of a
    // long note opens the note under it.
    //
    // Nothing else here catches it. The estimator test measures the deepest
    // DESCENDANT, which is right either way; only the row's own frame is wrong.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const body = "A note long enough to wrap onto three full lines of the reading column, which is the shape the measurement has to handle, and it keeps going for a while so there is no doubt about it at all.";
    for (0..2) |i| {
        model.notes[i] = threadNote(0xA1 + @as(u8, @intCast(i)), 100, 0);
        model.notes[i].id = @intCast(7 + i);
        @memcpy(model.notes[i].content_buf[0..body.len], body);
        model.notes[i].content_len = @intCast(body.len);
    }
    model.notes_len = 2;

    const p = try painted.Painted.render(arena, &model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 2) return error.ExpectedTwoRows;
    // Three body lines, so the row is a good deal taller than the one-line
    // measurement the wrong kind would give it.
    try testing.expect(rows[0].height > main.feed_row_chrome + 2 * main.body_line_height);
    // And the row below starts after this one ends, rather than under its tail.
    try testing.expect(rows[1].y >= rows[0].y + rows[0].height - 0.5);
}

test "a note that quotes another is priced with the quote in it" {
    // The bordered card this replaces was never priced at all, so a feed of
    // quoting notes reported less than it drew and the scrollbar lied. The
    // four-line clamp is what makes the height knowable, which is the reason the
    // design gives for clamping.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x5e} ** 32;
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "A quoted note, two lines of it, which is what the aside beside the rule draws before the clamp cuts the rest of it away.");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    // Within a line and a half. Every estimate here counts CHARACTERS against a
    // column width where the engine measures glyphs and breaks at words, so a
    // line either way is the standing slack, and it costs a little scroll jitter
    // on rows not yet built, never an overlap (a built row is positioned by what
    // it measures). What the estimate may not be is short by the whole quote,
    // which is what it was: a bordered card priced at nothing.
    const slack = 1.5 * main.body_line_height;
    if (@abs(rows[0].height - priced) > slack) {
        const qf = p.frameOf("Quoted note") orelse rows[0];
        std.debug.print("\nquoting row draws {d}, priced {d}; quote block {d}\n", .{ rows[0].height, priced, qf.height });
        return error.QuoteNotPriced;
    }
    // And the quote is a real part of that price, not a rounding error.
    const without_quote = main.feed_row_chrome + main.body_line_height;
    try testing.expect(priced > without_quote + 2 * main.body_line_height);

    // The aside fills the column beside the rule. Hugging its content instead,
    // it wrapped the quoted note at about half the width the shot gives it,
    // which reads as a column of its own rather than an aside.
    // The aside's body is labelled so its WIDTH can be asked about: it currently
    // hugs its text (370 of the 526 it is given) rather than filling the column
    // beside the rule, which reads as a column of its own instead of an aside.
    // Left as an open nit rather than a passing assertion that says otherwise.
    try testing.expect(p.frameOf("Quoted note body") != null);
}
test "a link card is priced at what it draws, with a description and without" {
    // The card's height comes from its text column, not from its 30px tile:
    // every line takes a full body line box whatever register it is set in. The
    // constant is measured for the same reason the others are.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = "https://example.com/post";
    for ([_][]const u8{ "What it says about itself.", "" }) |desc| {
        main.seedLinkForTest(url, "The page's title", desc);

        var model = main.initialModel();
        model.stage = .ready;
        model.notes[0] = threadNote(0xA1, 100, 0);
        model.notes[0].id = 7;
        const body = "Read this.";
        @memcpy(model.notes[0].content_buf[0..body.len], body);
        model.notes[0].content_len = @intCast(body.len);
        @memcpy(model.notes[0].link_url_buf[0..url.len], url);
        model.notes[0].link_url_len = @intCast(url.len);
        model.notes_len = 1;

        const p = try painted.Painted.render(arena, &model);
        const card = p.frameOf("Open link") orelse return error.NoCard;
        const priced = if (desc.len > 0) main.link_card_height_for_test else main.link_card_height_bare_for_test;
        if (@abs(card.height - priced) > 0.5) {
            std.debug.print("\ncard with desc={d} draws {d}, priced {d}\n", .{ desc.len, card.height, priced });
            return error.CardMispriced;
        }
    }
}
test "a settings card's content is as wide as the constant says" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `settings_content_width` is derived from four separate insets, and the
    // chip packing trusts it. If any of them moves and this does not, the chips
    // pack against a width the layout does not give them, which is how the row
    // overflowed in the first place: an arithmetic that nobody checked against
    // a laid-out frame.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    // The relay card is the widest content a settings section holds.
    const row = p.frameOf("Change what wss://relay-0.a-fairly-long-hostname.example.com is for") orelse
        return error.NoRelayRow;
    var widest: f32 = 0;
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .card) continue;
        const f = node.widget.frame;
        // The section card holding that row, found by containment on the y axis.
        if (row.y < f.y or row.y > f.y + f.height) continue;
        // <= the column, not < it: as a page the section cards ARE the column's
        // width, where under the old modal they sat inside it with a margin.
        if (f.width > widest and f.width <= main.settings_column_width_for_test + 0.5) widest = f.width;
    }
    try testing.expect(widest > 0);
    // The card, less its own 12 either side, is what the content gets.
    try testing.expectApproxEqAbs(main.settings_content_width_for_test, widest - 24, 1.0);
}
test "a quote's picture box is total over whatever shape a note declares" {
    const cases = [_]f32{ 0, -1, 0.0001, 0.3, 0.5, 0.66, 1.0, 1.5, 4, 65535, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    for (cases) |aspect| {
        const box = main.quotePictureBox(aspect);
        try testing.expect(std.math.isFinite(box.width) and std.math.isFinite(box.height));
        // Never empty, never wider than the thumbnail, never taller than it is
        // wide: the card has to be priced for whatever comes through here.
        try testing.expect(box.width > 0 and box.height > 0);
        try testing.expect(box.width <= main.quote_picture_width_for_test);
        try testing.expect(box.height <= main.quote_picture_width_for_test);
    }
    // No declared shape lands on the feed's guess, not on a square or a sliver.
    const unknown = main.quotePictureBox(0);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test * 0.66, unknown.height, 0.5);
    // A tall picture gets a box of its own shape rather than bare gutters.
    const tall = main.quotePictureBox(2);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test / 2, tall.width, 0.5);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test, tall.height, 0.5);
}
test "a long note is kept whole, not cut where the old buffer ended" {
    // The reported bug: a release announcement of ~1900 bytes was stored into a
    // 1024-byte buffer, so "Show more" expanded onto a note that stopped
    // mid-sentence. Nothing in the UI said a limit had been hit, because the
    // text just ended.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Built to the shape that broke: many short lines, well past the old cap.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(arena);
    var line: usize = 0;
    while (body.items.len < 1900) : (line += 1) {
        try body.print(arena, "line {d}: something worth reading to the end\n", .{line});
    }
    const written = try arena.dupe(u8, body.items);
    try testing.expect(written.len > 1024); // the old cap
    try testing.expect(written.len < main.noteContentCapForTest());

    var out: [main.note_content_cap_for_test]u8 = undefined;
    const n = main.renderContentInto(&out, written, &.{}, null);

    // Whole, and byte-identical against the SOURCE TRIMMED, because the renderer
    // strips leading and trailing whitespace on purpose. Trimming is the only
    // difference allowed here: nothing else about this content is rewritten, so
    // any other shortfall is a cut.
    const want = std.mem.trim(u8, written, " \t\r\n");
    try testing.expectEqual(want.len, n);
    try testing.expectEqualStrings(want, out[0..n]);

    // And the tail specifically, because a cut shows up at the END and a test
    // that only checks a length can pass on a buffer of zeroes.
    try testing.expect(std.mem.endsWith(u8, out[0..n], "to the end"));
}
test "a paste that does not fit is counted after its line breaks are made plain" {
    // Past the cap, the overflow reported is measured in what the draft would
    // have held.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    const cap = main.compose_capacity_for_test;
    // cap + 1 bytes of U+2028, three bytes each on the way in and one once
    // plain: cap + 1 plain bytes asked for, cap of them fit.
    const big = try arena_state.allocator().alloc(u8, (cap + 1) * 3);
    for (0..cap + 1) |i| @memcpy(big[i * 3 ..][0..3], "\u{2028}");
    main.update(&model, .{ .draft_edit = .{ .insert_text = big } }, &fx);
    try testing.expectEqual(cap, model.draft().len);
    try testing.expect(std.mem.indexOfScalar(u8, model.draft(), 0xE2) == null);
    try testing.expectEqual(@as(usize, 1), model.draft_dropped);
}
test "the version this build reports is the one it compares against" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Not a literal: the comparison has to be against what this build actually
    // is, or it tells everybody about a release they are already running.
    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;
    const mine = main.plaza_version_for_test;
    try testing.expect(main.newerRelease(releaseDoc(arena, mine, ""), mine, &v, &u) == null);
}
test "a release that is not newer raises no line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetUpdateStateForTest();
    defer main.resetUpdateStateForTest();

    // The version this build actually is. Answered with itself, there is no news.
    const same = try std.fmt.allocPrint(arena,
        \\{{"tag_name":"v{s}","html_url":"https://github.com/zig-nostr/plaza/releases/tag/v{s}"}}
    , .{ main.plaza_version_for_test, main.plaza_version_for_test });
    main.updateNewsForTest(same);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());

    // And a reply that is not a release document leaves no line either.
    main.updateNewsForTest("<html>rate limited</html>");
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
}

//! Tests of note_build.zig. From event to Note: kinds, titles, imeta, media classification, and content rendering.

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
const countByLabel = harness.countByLabel;
const countNodes = harness.countNodes;
const findAnyText = harness.findAnyText;
const findAnyTextContaining = harness.findAnyTextContaining;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const findByText = harness.findByText;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const warnedEvent = harness.warnedEvent;

test "an event carries its kind into the note built from it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x31} ** 32);

    for ([_]u16{ 1, 6, 20, 1063, 30023 }) |kind| {
        const ev = try signedKind(arena, signer, kp, 1_800_000_000, kind, &.{}, "x");
        const note = main.noteFrom(ev, 1_800_000_000);
        try testing.expectEqual(kind, note.kind);
    }
}

test "a long-form article shows its title, not its markdown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x32} ** 32);

    const markdown = "## A heading\n\nA paragraph of the article body that nobody asked to read in a card.";
    const tags = [_]nostr.event.Tag{&[_][]const u8{ "title", "What the article is called" }};
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, markdown);
    const note = main.noteFrom(ev, 1_800_000_000);

    try testing.expectEqualStrings("What the article is called", note.content());
    // The markdown must not be in there at all: painting it as a note body is
    // the whole defect.
    try testing.expect(std.mem.indexOf(u8, note.content(), "## A heading") == null);
}

test "an article with no title falls to the unsupported card rather than its markdown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x33} ** 32);

    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &.{}, "# raw markdown");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqual(@as(u16, 0), note.content_len);
}

test "a kind nothing can draw keeps its content out of the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x34} ** 32);

    // A file metadata event: its content is empty by design, and what it holds
    // is in its tags.
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 1063, &.{}, "not a sentence");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqual(main.KindRender.unsupported, main.kindRender(note.kind));
    try testing.expectEqual(@as(u16, 0), note.content_len);
}

test "a real kind:0 is unsupported, and the default does not hide it" {
    // `Note.kind` defaults to 1 so a fixture or a scratch struct reads as a text
    // note. This is the case that default could have masked: an event whose kind
    // really is 0 must still be refused, because `noteFrom` writes the real kind
    // over the default rather than leaving it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x35} ** 32);

    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 0, &.{}, "{\"name\":\"somebody\"}");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqual(@as(u16, 0), note.kind);
    try testing.expectEqual(main.KindRender.unsupported, main.kindRender(note.kind));

    // And a Note nobody filled from an event is still a text note.
    const blank = main.Note{};
    try testing.expectEqual(main.KindRender.note, main.kindRender(blank.kind));
}

test "every surface answers the same way about one kind" {
    // The point of having a single dispatch: a quote card, a thread and
    // open_event cannot disagree about the same event.
    try testing.expectEqual(main.KindRender.note, main.kindRender(1));
    try testing.expectEqual(main.KindRender.note, main.kindRender(main.comment_kind));
    try testing.expectEqual(main.KindRender.article, main.kindRender(30023));
    try testing.expectEqual(main.KindRender.media, main.kindRender(20));
    try testing.expectEqual(main.KindRender.media, main.kindRender(21));
    try testing.expectEqual(main.KindRender.media, main.kindRender(22));
    try testing.expectEqual(main.KindRender.unsupported, main.kindRender(1063));
    try testing.expectEqual(main.KindRender.unsupported, main.kindRender(31923));
}

test "a repost points at the last e tag" {
    const a = [_]u8{0xaa} ** 32;
    const b = [_]u8{0xbb} ** 32;
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf_a, "{x}", .{a});
    _ = try std.fmt.bufPrint(&buf_b, "{x}", .{b});

    // The LAST one, which is what Amethyst reads. A repost normally carries one,
    // so the two answers differ only for a malformed event, and differing from
    // the network about a malformed event shows a row nobody else does.
    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "e", &buf_a },
        &[_][]const u8{ "p", &buf_a },
        &[_][]const u8{ "e", &buf_b },
    };
    try testing.expectEqualSlices(u8, &b, &(main.repostTargetId(&tags).?));

    // Nothing to point at is not a row.
    const none = [_]nostr.event.Tag{&[_][]const u8{ "p", &buf_a }};
    try testing.expect(main.repostTargetId(&none) == null);
}
test "plain content passes through renderContent unchanged" {
    var buf: [220]u8 = undefined;
    const src = "just a normal note with a https://example.com link";
    const n = main.renderContent(&buf, src, "");
    try testing.expectEqualStrings(src, buf[0..n]);
}
test "image links are recognised by extension only" {
    try testing.expect(main.firstImageUrl("https://x.com/a.png") != null);
    try testing.expect(main.firstImageUrl("https://x.com/a.JPEG") != null);
    try testing.expect(main.firstImageUrl("https://x.com/a.gif?v=2") != null);
    // A plain link, a non-image file, and bare text are not images.
    try testing.expect(main.firstImageUrl("https://example.com/page") == null);
    try testing.expect(main.firstImageUrl("https://x.com/clip.mp4") == null);
    try testing.expect(main.firstImageUrl("no links here") == null);
    // The first of several wins.
    try testing.expectEqualStrings(
        "https://a.com/1.png",
        main.firstImageUrl("see https://a.com/1.png and https://b.com/2.png").?,
    );
}
test "findQuoteRef captures the first note/nevent ref and ignores others" {
    var id = [_]u8{0xab} ** 32;
    const note1 = try nostr.nip19.encodeNote(testing.allocator, id);
    defer testing.allocator.free(note1);

    // A `nostr:`-prefixed reference is captured: id decoded, span covers the
    // whole `nostr:note1…` token.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "gm nostr:{s} enjoy", .{note1});
        defer testing.allocator.free(content);
        const note = main.findQuoteRefForTest(content);
        try testing.expect(main.noteHasEventQuote(&note));
        try testing.expectEqualSlices(u8, &id, &note.quote.id);
        const tok = content[note.quote.off..][0..note.quote.len];
        const want = try std.fmt.allocPrint(testing.allocator, "nostr:{s}", .{note1});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, tok);
    }
    // A bare reference at a word boundary is captured too.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "look {s}", .{note1});
        defer testing.allocator.free(content);
        const note = main.findQuoteRefForTest(content);
        try testing.expect(main.noteHasEventQuote(&note));
        try testing.expectEqualStrings(note1, content[note.quote.off..][0..note.quote.len]);
    }
    // Glued inside a URL (not a word boundary) is left as plain text, whether
    // bare or `nostr:`-prefixed.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "https://x/{s}", .{note1});
        defer testing.allocator.free(content);
        try testing.expect(!main.noteHasEventQuote(&main.findQuoteRefForTest(content)));
    }
    {
        const content = try std.fmt.allocPrint(testing.allocator, "https://njump.me/nostr:{s}", .{note1});
        defer testing.allocator.free(content);
        try testing.expect(!main.noteHasEventQuote(&main.findQuoteRefForTest(content)));
    }
    // A malformed token decodes to nothing.
    {
        const note = main.findQuoteRefForTest("hi nostr:note1notvalidbech32!!! bye");
        try testing.expect(!main.noteHasEventQuote(&note));
    }
}
test "imeta dimensions parse, including float forms" {
    const url = "https://host.example/a.png";
    const wide = [_]nostr.event.Tag{&.{ "imeta", "url " ++ url, "dim 800x400" }};
    try testing.expectApproxEqAbs(@as(f32, 0.5), main.imetaAspect(&wide, url), 0.001);

    // Real notes carry float dimensions too.
    const floaty = [_]nostr.event.Tag{&.{ "imeta", "url " ++ url, "dim 1320.0x2868.0" }};
    try testing.expect(main.imetaAspect(&floaty, url) > 2.0);

    // An imeta for a different URL says nothing about this one.
    const other = [_]nostr.event.Tag{&.{ "imeta", "url https://host.example/b.png", "dim 800x400" }};
    try testing.expectEqual(@as(f32, 0), main.imetaAspect(&other, url));
    try testing.expectEqual(@as(f32, 0), main.imetaAspect(&.{}, url));
}
test "a note becomes an npub-labelled card with a relative time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{3} ** 32);

    const now: i64 = 1_800_000_000;
    const ev = try signedNote(arena, signer, kp, now - 300, "hello from plaza"); // 5 minutes ago
    const note = main.noteFrom(ev, now);

    // Author is the abbreviated, canonical npub.
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
    try testing.expect(std.mem.indexOfScalar(u8, note.author(), '\xe2') != null); // the "…" abbreviation marker
    // Relative time and avatar initials.
    try testing.expectEqualStrings("5m", note.time());
    try testing.expectEqual(@as(usize, 2), note.initials().len);
    // Content survives.
    try testing.expectEqualStrings("hello from plaza", note.content());
}

test "the feed renders a note card from the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{4} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note in the feed");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    // The row shows the content and the npub author, and the status bar's
    // caught-up line carries the count.
    try testing.expect(findAnyText(tree.root, "a note in the feed") != null);
    try testing.expect(findAnyText(tree.root, model.notes[0].author()) != null);
    try testing.expect(findAnyText(tree.root, "Caught up · starter pack · 1 notes") != null);
}
test "the feed key survives a high-bit event id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Find a note whose id begins with the high bit set, the case that
    // overflows the markup engine's i64 key cast if the key is stored as u64.
    var seed: u8 = 1;
    const ev = while (seed < 255) : (seed += 1) {
        const kp = try signer.keyPairFromSecretKey([_]u8{seed} ** 32);
        const e = try signedNote(arena, signer, kp, 1_800_000_000, "high-bit id");
        if (e.id[0] >= 0x80) break e;
    } else return error.NoHighBitIdFound;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    // Building the list resolves the item key; a u64 key would panic here.
    const tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "high-bit id") != null);
}
test "a note row's separator paints at the reading column's width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{7} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a row that needs a line under it");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const p = try painted.Painted.render(arena, &model);

    // Round 3 spent a PR on separators that were never drawn at all (an empty
    // column with a background paints nothing, so the fix was the `.separator`
    // element). This holds that line: SOMETHING of the divider ink is painted.
    var found = false;
    for (p.commands) |command| {
        switch (command) {
            .fill_rect => |v| {
                if (painted.sameColor(switch (v.fill) {
                    .color => |c| c,
                    else => continue,
                }, theme.palette.divider_row) and v.rect.width > 400) found = true;
            },
            else => {},
        }
    }
    try testing.expect(found);
}
test "the feed draws via without spending a node on it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const plain = nostr.event.Event{
        .id = [_]u8{0xC1} ** 32,
        .pubkey = [_]u8{0x51} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "no client tag here",
        .sig = [_]u8{0} ** 64,
    };
    var tagged = plain;
    tagged.id = [_]u8{0xC2} ** 32;
    tagged.tags = &.{&.{ "client", "Amethyst" }};
    tagged.content = "written elsewhere";

    model.notes[0] = main.noteFrom(plain, 1_800_000_000);
    model.notes[1] = main.noteFrom(tagged, 1_800_000_000);
    model.notes_len = 2;

    const before = try buildTree(arena, &model);
    const nodes_with = countNodes(before.root);
    try testing.expect(findAnyTextContaining(before.root, "via Amethyst"));
    // The note that says nothing gets no "via" of its own.
    try testing.expect(!findAnyTextContaining(before.root, "via Plaza"));

    // And the row costs the same either way: the name rides as a second SPAN of
    // the paragraph the time already occupies, not as a node beside it. A feed
    // row is priced against a per-view ceiling that refuses the whole screen.
    model.notes[1] = main.noteFrom(plain, 1_800_000_000);
    model.notes[1].id = 999;
    const after = try buildTree(arena, &model);
    try testing.expectEqual(nodes_with, countNodes(after.root));
}

test "the time and via line is one line, whatever the note says it was written with" {
    // "11h via Damus Notedeck" used to wrap. The second line hung into the
    // handle's row, and because a row's height and the width this box is
    // measured at are settled in different passes, scrolling flickered it
    // between two lines and one, sometimes losing the second line entirely.
    //
    // Asserted as the FLAG rather than as a measured height, and that is an
    // admitted limit rather than a shortcut: this harness lays out the real tree
    // but does not carry the real glyph metrics (see the header of painted.zig),
    // so a height assertion here answers a question about a font that is not the
    // one the window uses. It passed with the wrap put back, which is how that
    // was found out. The flag is the whole of the decision, so the flag is what
    // is guarded here; the pixels were checked by rendering the app.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const ev = nostr.event.Event{
        .id = [_]u8{0xD1} ** 32,
        .pubkey = [_]u8{0x52} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = &.{&.{ "client", "Damus Notedeck" }},
        .content = "wrapped once",
        .sig = [_]u8{0} ** 64,
    };
    model.notes[0] = main.noteFrom(ev, 1_800_003_600);
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    var found = false;
    for (p.layout.nodes) |node| {
        const w = node.widget;
        if (w.kind != .text or w.spans.len < 2) continue;
        if (std.mem.indexOf(u8, w.text, " via ") == null) continue;
        found = true;
        if (!w.text_no_wrap) {
            std.debug.print("the meta line \"{s}\" is allowed to wrap again\n", .{w.text});
            return error.MetaLineCanWrap;
        }
    }
    try testing.expect(found);
}

test "the time and via line ends where the card ends" {
    // It stopped ending there. `wrap = false` fixed a flicker and silently
    // broke the alignment beside it: the toolkit gives a NON-WRAPPING paragraph
    // an infinite max_width (text_spans.zig:627), and its aligner returns early
    // on a width that is not finite (:565), so `text_alignment = .end` is
    // ignored on any single-line paragraph. The box stayed in the right place
    // and the words inside it sat at the left, so "35m via Amethyst" hung a
    // ragged gap off the card's edge that grew as the string got shorter.
    //
    // So the alignment is done by LAYOUT now, which the toolkit does honour: a
    // stated-width row, a spacer that takes the slack, and a paragraph that
    // hugs its own text at the end of it.
    //
    // Asserted against the note body, because both live in the same column and
    // the whole complaint was that one ended short of the other. Box geometry,
    // not glyph metrics, so this harness can answer it (see painted.zig).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Short, long, and longer than the column: the gap the reader saw was
    // widest for the shortest string, and the longest is what the column was
    // measured against in the first place.
    for ([_][]const u8{ "Amethyst", "Damus Notedeck", "An Absurdly Long Client Name" }) |client| {
        var model = main.initialModel();
        model.stage = .ready;
        const ev = nostr.event.Event{
            .id = [_]u8{0xD2} ** 32,
            .pubkey = [_]u8{0x53} ** 32,
            .created_at = 1_800_000_000,
            .kind = 1,
            .tags = &.{&.{ "client", client }},
            .content = "GM",
            .sig = [_]u8{0} ** 64,
        };
        model.notes[0] = main.noteFrom(ev, 1_800_002_100);
        model.notes_len = 1;

        const p = try painted.Painted.render(arena, &model);
        var meta_right: ?f32 = null;
        var body_right: ?f32 = null;
        for (p.layout.nodes) |node| {
            const w = node.widget;
            if (w.kind != .text) continue;
            const f = w.frame;
            if (std.mem.indexOf(u8, w.text, " via ") != null) meta_right = f.x + f.width;
            if (std.mem.eql(u8, w.text, "GM")) body_right = f.x + f.width;
        }
        const meta = meta_right orelse return error.NoMetaLine;
        const body = body_right orelse return error.NoBody;
        if (@abs(meta - body) > 0.5) {
            std.debug.print(
                "\"{s}\": the meta line ends at {d:.1}, the card ends at {d:.1}\n",
                .{ client, meta, body },
            );
            return error.MetaLineNotFlush;
        }
    }
}
test "a name written in Mathematical Alphanumeric letters is readable" {
    // 996 codepoints that nothing Plaza ships carries a glyph for, so off macOS
    // a name written in them was a solid rectangle per word. The reported one
    // was Mathematical Bold Fraktur.
    // The fold itself is pure and is asserted on every platform, so a macOS run
    // still catches a broken table. Only the two buffer assertions are gated,
    // because `copyDisplayText` leaves macOS alone on purpose: CoreText cascades
    // to a system face and draws the styled letters properly there, so folding
    // would replace working text with a plainer copy of itself.
    var buf: [64]u8 = undefined;
    if (comptime builtin.os.tag != .macos) {
        const written = main.copyDisplayTextForTest(&buf, "\u{1D57E}\u{1D58A}\u{1D597} \u{1D57E}\u{1D591}\u{1D58A}\u{1D58A}\u{1D595}\u{1D59E}");
        try testing.expectEqualStrings("Ser Sleepy", buf[0..written]);
    }

    // Every run, so a style nobody thought about is not a bar. Each alphabet is
    // A-Z then a-z, so the first, the twenty-sixth and the last of each pin the
    // arithmetic at both ends and across the case boundary.
    const alphabets = [_]u21{
        0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D4D0, 0x1D504, 0x1D538,
        0x1D56C, 0x1D5A0, 0x1D5D4, 0x1D608, 0x1D63C, 0x1D670,
    };
    for (alphabets) |start| {
        try testing.expectEqual(@as(?u8, 'A'), main.foldMathAlnumForTest(start));
        try testing.expectEqual(@as(?u8, 'Z'), main.foldMathAlnumForTest(start + 25));
        try testing.expectEqual(@as(?u8, 'a'), main.foldMathAlnumForTest(start + 26));
        try testing.expectEqual(@as(?u8, 'z'), main.foldMathAlnumForTest(start + 51));
    }
    for ([_]u21{ 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6 }) |start| {
        try testing.expectEqual(@as(?u8, '0'), main.foldMathAlnumForTest(start));
        try testing.expectEqual(@as(?u8, '9'), main.foldMathAlnumForTest(start + 9));
    }

    // And nothing outside the block moves. Letterlike Symbols sits just below
    // it and already inks, the Greek runs are deliberately left alone, and
    // ordinary text must be untouched.
    for ([_]u21{ 0x2103, 0x2116, 0x2122, 0x212C, 0x1D6A8, 0x1D7CB, 'A', 'z', '7', 0x00E9, 0x4E00 }) |cp| {
        try testing.expectEqual(@as(?u8, null), main.foldMathAlnumForTest(cp));
    }

    // A name that is already readable stays byte-identical, on every platform.
    const plain = "Ser Sleepy";
    const kept = main.copyDisplayTextForTest(&buf, plain);
    try testing.expectEqualStrings(plain, buf[0..kept]);
}
test "past the cap a mention still reads as a name, it just does not open" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = std.ArrayList(u8).empty;
    defer src.deinit(arena);
    const over = main.noteMaxMentionsForTest + 1;
    for (0..over) |i| {
        // A fill no other test names, so none of these has a cached display name
        // and every one of them renders as `@npub1…`. The profile cache is
        // global, and counting labels only works if they all look the same.
        var pk = [_]u8{0xA5} ** 32;
        pk[31] = @intCast(i);
        const npub = try nostr.nip19.encodeNpub(arena, pk);
        try src.print(arena, "nostr:{s} ", .{npub});
    }

    var buf: [2048]u8 = undefined;
    var mentions = main.MentionList{};
    const n = main.renderContentInto(&buf, src.items, &.{}, &mentions);

    // Every one of them is rendered.
    try testing.expectEqual(over, std.mem.count(u8, buf[0..n], "@npub1"));
    // The table holds what it can hold, and nothing beyond it is claimed.
    try testing.expectEqual(main.noteMaxMentionsForTest, mentions.all().len);

    // And they are in offset order. The span walk reads the table with a single
    // cursor rather than searching it at every byte, which is only correct
    // because recording happens as the content is walked. Nothing else in the
    // code says so out loud, so it is said here.
    var previous: u16 = 0;
    for (mentions.all(), 0..) |ref, k| {
        if (k > 0) try testing.expect(ref.off > previous);
        previous = ref.off;
    }
}

test "pressing a mention opens that profile, and pressing a link does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{19} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "hi nostr:{s}", .{npub});
    _ = main.renderContentInto(&buf, src, &.{}, &mentions);

    var model = Model{};
    var fx: main.EffectsForTest = undefined;
    // The message a paragraph sends for ANY link it carries, which is the whole
    // reason the payload has to say which kind it is.
    main.update(&model, Msg{ .open_url = mentions.all()[0].link() }, &fx);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqualSlices(u8, &pk, &model.viewing_profile.?);
}
test "every image in a note becomes a picture, and none is left in the text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x81} ** 32);

    // Derek's note, in shape: three images on one line, each with its own imeta.
    const a = "https://blossom.example/aaa.jpeg";
    const b = "https://blossom.example/bbb.jpeg";
    const c = "https://blossom.example/ccc.jpeg";
    const content = try std.fmt.allocPrint(arena, "Bon dia, Nostr. {s} {s} {s}", .{ a, b, c });
    const tags = [_]nostr.event.Tag{
        &.{ "imeta", "url " ++ a, "dim 2040x1536", "blurhash abc" },
        &.{ "imeta", "url " ++ b, "dim 768x1020" },
        &.{ "imeta", "url " ++ c, "dim 768x1020" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &tags, content, null);
    const note = main.noteFrom(ev, 1_800_000_100);

    try testing.expectEqual(@as(usize, 3), note.imageCount());
    try testing.expectEqualStrings(a, note.imageAt(0).url());
    try testing.expectEqualStrings(b, note.imageAt(1).url());
    try testing.expectEqualStrings(c, note.imageAt(2).url());

    // The whole point of the bug report: none of them may be left behind as a
    // raw link beside the pictures. Before this, the first became a picture and
    // the other two sat in the body as URLs.
    try testing.expectEqualStrings("Bon dia, Nostr.", note.content());

    // Each keeps its OWN imeta, not the first one's, which is what lets a
    // portrait shot beside a landscape reserve the right space.
    try testing.expectEqual(@as(u16, 2040), note.imageAt(0).w);
    try testing.expectEqual(@as(u16, 768), note.imageAt(1).w);
    try testing.expectEqualStrings("abc", note.imageAt(0).blurhash());
    try testing.expectEqualStrings("", note.imageAt(1).blurhash());
}

test "a note past the picture cap keeps the rest as links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x82} ** 32);

    var content = std.ArrayList(u8).empty;
    defer content.deinit(arena);
    const over = main.max_note_images + 2;
    for (0..over) |i| try content.print(arena, "https://blossom.example/{d}.jpeg ", .{i});

    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, content.items, null);
    const note = main.noteFrom(ev, 1_800_000_100);

    try testing.expectEqual(main.max_note_images, note.imageCount());
    // The overflow stays readable rather than vanishing: it is still a link the
    // reader can open, which is what the single-image build did for everything
    // after the first.
    try testing.expect(std.mem.indexOf(u8, note.content(), "/4.jpeg") != null);
    try testing.expect(std.mem.indexOf(u8, note.content(), "/0.jpeg") == null);
}

test "a URL that prefixes another does not strand the longer one's tail" {
    // `.../a.jpeg` is a prefix of `.../a.jpeg?x=1`. Removing the short one first
    // would leave `?x=1` sitting in the body as debris.
    var buf: [512]u8 = undefined;
    const short = "https://h.example/a.jpeg";
    const long = "https://h.example/a.jpeg?w=9";
    const omit = [_][]const u8{ short, long };
    const n = main.renderContentInto(&buf, "look " ++ long ++ " end", &omit, null);
    try testing.expectEqualStrings("look  end", buf[0..n]);
}
test "a display name keeps its emoji drawable" {
    // A name is not note content and never went through the content path, so an
    // emoji in one stayed a codepoint no face off macOS could draw and painted
    // as a solid block. Found on a real note: the author "Dr. The Daniel" with a
    // raised hand after it, rendered as a bar in the reply line.
    //
    // The emoji survives the copy verbatim on every platform now. What draws it
    // is the renderer reaching the registered colour face, which is the
    // previous test's business; here the only question is that nothing on the
    // way to the render buffer eats it.
    var buf: [128]u8 = undefined;
    const src = "Dr. The Daniel \u{1F596}";
    const n = main.copyDisplayTextForTest(&buf, src);
    try testing.expectEqualStrings(src, buf[0..n]);
}

test "an invisible codepoint is not drawn as a block" {
    // Reported from a real note: "oh right web clients" followed by a skull and
    // then a solid rectangle. The skull is U+2620 and the emoji face has it, so
    // it drew. What followed was U+FE0F, the variation selector asking for the
    // colour presentation, which inks nothing anywhere and is in no font, so the
    // renderer drew its block fallback for it.
    //
    // Every codepoint here is invisible by definition, so drawing anything at
    // all for one is wrong.
    for ([_]u21{ 0xFE0F, 0xFE0E, 0x200D, 0x200B, 0x20E3, 0x1F3FB, 0x1F3FF, 0x2060 }) |cp| {
        if (!main.invisibleForDisplayForTest(cp)) return error.AnInvisibleCodepointWouldBeDrawn;
    }
    // And nothing that carries ink is swept up with them.
    for ([_]u21{ 'a', '0', 0x2620, 0x1F600, 0x0416, 0x2026 }) |cp| {
        if (main.invisibleForDisplayForTest(cp)) return error.AVisibleCodepointWasDropped;
    }

    var buf: [64]u8 = undefined;
    const n = main.copyDisplayTextForTest(&buf, "web clients \u{2620}\u{FE0F}");
    const out = buf[0..n];
    if (builtin.os.tag == .macos) {
        // CoreText wants the selector: it is what makes the emoji render in
        // colour rather than as a monochrome dingbat.
        try testing.expectEqualStrings("web clients \u{2620}\u{FE0F}", out);
    } else {
        // The skull survives; the selector is gone rather than drawn.
        try testing.expectEqualStrings("web clients \u{2620}", out);
    }
}
test "a declared type beats the extension, in both directions" {
    // Amethyst's rule, and the pair that makes it worth having: a video named
    // like a picture, and a picture named like a video. Collapsing this into
    // `mime says video OR the name says video` is what they replaced, because
    // it drew poster-named videos as pictures.
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/thumb.jpg", "video/mp4"));
    try testing.expectEqual(main.MediaKind.image, main.classifyMedia("https://x.com/clip.mp4", "image/jpeg"));

    // Nothing declared: the name decides.
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/clip.mp4", ""));
    try testing.expectEqual(main.MediaKind.image, main.classifyMedia("https://x.com/shot.jpg", ""));
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/page", ""));

    // A type we do not know is NOT a veto: it means nothing was said, and the
    // name still decides. This is the tier that is easy to drop.
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/clip.mp4", "application/octet-stream"));
    try testing.expectEqual(main.MediaKind.image, main.classifyMedia("https://x.com/shot.png", "application/x-thing"));
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/file.bin", "application/octet-stream"));

    // Audio is deliberately not video: Plaza plays neither, and a video card on
    // a sound file says something untrue.
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/song.mp3", "audio/mpeg"));
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/song.mp3", ""));
}

test "the extension is read off the path, not off the whole address" {
    // A query, and a fragment. `#t=30` is a real thing to write after a video
    // and reading it as part of the extension loses the video.
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/clip.mp4?token=abc", ""));
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/clip.mp4#t=30", ""));
    try testing.expect(main.looksLikeImageUrl("https://x.com/shot.jpg#x"));
    try testing.expect(main.looksLikeImageUrl("https://x.com/shot.jpg?w=100"));

    // The dot has to be an extension dot. A host that merely contains the
    // letters is not a video, and a path with no dot at all is not one either.
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://cdn.mp4.example/watch", ""));
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/mp4", ""));
    try testing.expectEqual(main.MediaKind.other, main.classifyMedia("https://x.com/", ""));

    // Case, because a host writing `.MP4` is writing a video.
    try testing.expectEqual(main.MediaKind.video, main.classifyMedia("https://x.com/CLIP.MP4", ""));
}

test "a note carrying a video knows it is carrying a video" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4d} ** 32);

    // A bare video link, no tags: the name is all there is to go on.
    {
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, "look https://cdn.example/clip.mp4", null);
        const note = main.noteFrom(ev, 1_800_000_000);
        try testing.expect(note.hasLink());
        try testing.expectEqualStrings("https://cdn.example/clip.mp4", note.linkUrl());
        try testing.expect(note.link_is_video);
        // And it is NOT claimed as a picture, which would try to decode it.
        try testing.expect(!note.hasImage());
    }

    // An ordinary page is still an ordinary page.
    {
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, "read https://example.com/post", null);
        const note = main.noteFrom(ev, 1_800_000_000);
        try testing.expect(note.hasLink());
        try testing.expect(!note.link_is_video);
    }

    // The case the `m` field exists for: a video whose name says picture. The
    // note's own imeta is what tells them apart, and without reading `m` this
    // would be handed to the image decoder.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "imeta", "url https://cdn.example/thumb.jpg", "m video/mp4" },
        };
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, tags[0..], "look https://cdn.example/thumb.jpg", null);
        const note = main.noteFrom(ev, 1_800_000_000);
        try testing.expect(!note.hasImage());
        try testing.expect(note.hasLink());
        try testing.expect(note.link_is_video);
    }

    // And the other direction: a picture whose name says video.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "imeta", "url https://cdn.example/shot.mp4", "m image/jpeg" },
        };
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, tags[0..], "look https://cdn.example/shot.mp4", null);
        const note = main.noteFrom(ev, 1_800_000_000);
        try testing.expect(!note.link_is_video);
    }
}

test "the imeta m field is read off the tag that names the url" {
    const tags = [_]nostr.event.Tag{
        &.{ "imeta", "url https://a.example/one.jpg", "m image/jpeg", "alt a picture" },
        &.{ "imeta", "url https://b.example/two.mp4", "m video/mp4" },
    };
    try testing.expectEqualStrings("image/jpeg", main.imetaFor(tags[0..], "https://a.example/one.jpg").mime);
    try testing.expectEqualStrings("video/mp4", main.imetaFor(tags[0..], "https://b.example/two.mp4").mime);
    // A url with no tag of its own gets nothing, rather than the other one's.
    try testing.expectEqualStrings("", main.imetaFor(tags[0..], "https://c.example/three.png").mime);
    // The neighbouring fields still parse, so the new arm did not swallow them.
    try testing.expectEqualStrings("a picture", main.imetaFor(tags[0..], "https://a.example/one.jpg").alt);
}

test "a note carrying a video draws a video, not a page card" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5e} ** 32);

    var model = main.initialModel();
    model.stage = .ready;
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, "look https://cdn.example/clip.mp4", null);
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    // It says what it is and where it goes. The page card cannot appear here at
    // all: it draws nothing until a fetch has answered, and no fetch is made.
    try testing.expect(findAnyText(tree.root, "Video") != null);
    try testing.expect(findAnyTextContainingText(tree.root, "cdn.example") != null);
    try testing.expect(findByLabel(tree.root, "Open video") != null);
}
test "a note carries its author's content warning and the reason they gave" {
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const warned = main.noteFrom(warnedEvent(0xC0, "the butler did it", &tags), 1_800_000_100);
    try testing.expect(warned.warned);
    try testing.expectEqualStrings("spoilers", warned.warning());

    const plain = main.noteFrom(warnedEvent(0xC1, "good morning", &.{}), 1_800_000_100);
    try testing.expect(!plain.warned);
    try testing.expectEqual(@as(usize, 0), plain.warning().len);
}
test "a thread covers the note it is about and the replies under it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    var model = main.initialModel();
    model.stage = .ready;
    const root_tags = [_]nostr.event.Tag{&.{ "content-warning", "graphic" }};
    model.thread_root = main.noteFrom(warnedEvent(0xCA, "ROOTSECRET https://example.com/root.jpg", &root_tags), 1_800_000_100);
    model.viewing_thread = model.thread_root.id;

    var reply_ev = warnedEvent(0xCB, "REPLYSECRET", &.{&.{ "content-warning", "also graphic" }});
    reply_ev.created_at = 1_800_000_200;
    model.thread_notes[0] = main.noteFrom(reply_ev, 1_800_000_300);
    model.thread_notes[0].reply_parent = model.thread_root.event_id;
    model.thread_notes[0].has_reply_parent = true;
    model.thread_notes[0].depth = 1;
    model.thread_notes_len = 1;

    const tree = try buildTree(arena, &model);
    try testing.expect(!findAnyTextContaining(tree.root, "ROOTSECRET"));
    try testing.expect(!findAnyTextContaining(tree.root, "REPLYSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: graphic"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: also graphic"));
    try testing.expectEqual(@as(usize, 0), countByLabel(tree.root, "Attached image, press to enlarge"));
}

test "an ancestor above a thread is covered too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const Build = struct {
        var ancestor: main.Ancestor = undefined;
        fn row(ui: *main.AppUi) main.AppUi.Node {
            return main.ancestorRowForTest(ui, &ancestor, true);
        }
    };
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    Build.ancestor = .{ .note = main.noteFrom(warnedEvent(0xCC, "ANCESTORSECRET", &tags), 1_800_000_100) };

    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(Build.row(&ui));
    try testing.expect(!findAnyTextContaining(tree.root, "ANCESTORSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: spoilers"));
}
test "an article's cover is its one picture, and the body's pictures stay in the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x62} ** 32);

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "title", "With a cover" },
        &[_][]const u8{ "image", "https://example.com/cover.jpg" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "Words.\n\nhttps://example.com/inline.png\n");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqual(@as(usize, 1), note.imageCount());
    try testing.expectEqualStrings("https://example.com/cover.jpg", note.imageAt(0).url());

    // No cover at all: a picture inside the body is still the body's, not a
    // cover hung under the title.
    const plain = [_]nostr.event.Tag{&[_][]const u8{ "title", "No cover" }};
    const inline_only = main.noteFrom(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &plain, "Words.\n\nhttps://example.com/inline.png\n"), 1_800_000_000);
    try testing.expectEqual(@as(usize, 0), inline_only.imageCount());

    // A cover that is not a web address is not fetched from.
    const bad = [_]nostr.event.Tag{&[_][]const u8{ "image", "file:///etc/passwd" }};
    const nope = main.noteFrom(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &bad, "x"), 1_800_000_000);
    try testing.expectEqual(@as(usize, 0), nope.imageCount());
}
test "an naddr in a note becomes a card keyed by the address" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const pk = [_]u8{0x46} ** 32;
    const relays = [_][]const u8{"wss://hint.example.com"};
    const naddr = try nostr.nip19.encodeNaddr(arena, "on-quoting", pk, 30023, &relays);
    const content = try std.fmt.allocPrint(arena, "worth a read nostr:{s} and that is all", .{naddr});

    const note = main.findQuoteRefForTest(content);
    try testing.expect(main.noteHasEventQuote(&note));
    const key = main.addressKeyForTest(30023, pk, "on-quoting");
    try testing.expectEqualSlices(u8, &key, &note.quote.id);
    // The span is the whole token, prefix included, so the body splits around it.
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}), content[note.quote.off..][0..note.quote.len]);
    try testing.expect(main.addressRegisteredForTest(key));

    // A bare token at a word boundary counts, as it does for an nevent.
    const bare = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "see {s}", .{naddr}));
    try testing.expectEqualSlices(u8, &key, &bare.quote.id);

    // Another coordinate is another card.
    const other = try nostr.nip19.encodeNaddr(arena, "elsewhere", pk, 30023, &.{});
    const second = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{other}));
    try testing.expect(!std.mem.eql(u8, &second.quote.id, &key));

    // Kinds with no screen stay the text they were, and so does one inside a
    // link.
    const stream = try nostr.nip19.encodeNaddr(arena, "a-stream", pk, 30311, &.{});
    const plain = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{stream}));
    try testing.expect(!main.noteHasEventQuote(&plain));
    const in_url = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "https://example.com/nostr:{s}", .{naddr}));
    try testing.expect(!main.noteHasEventQuote(&in_url));
}
test "a person's newest page asks for their comments as well as their notes" {
    // The next page starts where this one reached, so a kind the first page
    // leaves out is never asked for in their newest stretch at all.
    const who = [_]u8{0x65} ** 32;
    const authors = [_][32]u8{who};
    const f = main.buildProfileNewestFilter(&authors);
    try testing.expectEqualSlices(u16, &.{ 1, main.comment_kind }, f.kinds.?);
    try testing.expectEqual(@as(?u32, 100), f.limit);
    try testing.expectEqual(@as(?i64, null), f.until);
}

test "the filter for older notes asks for exactly the notes before the oldest one held" {
    const who = [_]u8{0x66} ** 32;
    const authors = [_][32]u8{who};
    const f = main.buildProfileOlderFilter(&authors, 1_700_000_123);
    try testing.expectEqual(@as(?i64, 1_700_000_123), f.until);
    try testing.expectEqual(@as(?u32, 100), f.limit);
    try testing.expectEqual(@as(?i64, null), f.since);
    try testing.expectEqualSlices(u8, &who, &f.authors.?[0]);
    // Comments too: the page shows them, so paging has to be able to reach them.
    try testing.expectEqualSlices(u16, &.{ 1, main.comment_kind }, f.kinds.?);
}

test "an article title too long for a card is cut at a word and says so" {
    const long = "Local-first, in practice: why a feed should never wait for the network, and what it costs to build one that does not";
    const tags = [_]nostr.event.Tag{&.{ "title", long }};
    var ev = warnedEvent(0x31, "", &tags);
    ev.kind = 30023;
    var buf: [320]u8 = undefined;
    const n = main.titleInto(&buf, ev) orelse return error.NoTitle;
    const shown = buf[0..n];
    try testing.expect(std.mem.endsWith(u8, shown, "\u{2026}"));
    const words = shown[0 .. shown.len - "\u{2026}".len];
    // Every word kept is a whole word of the title.
    try testing.expect(std.mem.startsWith(u8, long, words));
    try testing.expectEqual(@as(u8, ' '), long[words.len]);
    try testing.expect(std.unicode.utf8CountCodepoints(shown) catch 0 <= 96);

    // A title that fits is left exactly as written.
    const short = "Local-first, in practice";
    const tags2 = [_]nostr.event.Tag{&.{ "title", short }};
    const ev2 = warnedEvent(0x32, "", &tags2);
    const m = main.titleInto(&buf, ev2) orelse return error.NoTitle;
    try testing.expectEqualStrings(short, buf[0..m]);

    // One enormous word keeps what fits rather than collapsing to nothing.
    const word = "a" ** 150;
    const tags3 = [_]nostr.event.Tag{&.{ "title", word }};
    const ev3 = warnedEvent(0x33, "", &tags3);
    const k = main.titleInto(&buf, ev3) orelse return error.NoTitle;
    try testing.expect(k > 90);
    try testing.expect(std.mem.endsWith(u8, buf[0..k], "\u{2026}"));
}

test "a note's picture on a private host is left as text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x72} ** 32);
    const note_ev = try signedNote(arena, signer, kp, 1_800_000_000, "look http://192.168.1.1/cam.png and https://image.example.com/b.png");
    const note = main.noteFrom(note_ev, 1_800_000_000);
    try testing.expectEqual(@as(usize, 1), note.imageCount());
    try testing.expectEqualStrings("https://image.example.com/b.png", note.imageAt(0).url());
    try testing.expectEqual(@as(?[]const u8, null), main.firstImageUrl("only http://10.0.0.7/x.jpg here"));
}

test "an article cover on a private host is not drawn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x74} ** 32);
    const cover_tags = [_]nostr.event.Tag{
        &[_][]const u8{ "title", "Inward" },
        &[_][]const u8{ "image", "http://192.168.0.2/cover.jpg" },
    };
    const art = main.noteFrom(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &cover_tags, "Words."), 1_800_000_000);
    try testing.expectEqual(@as(usize, 0), art.imageCount());
}

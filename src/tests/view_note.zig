//! Tests of view_note.zig. The note row: author, time, body, quote, and the verbs under it.

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
const findAnyTextContaining = harness.findAnyTextContaining;
const pressMsgByLabel = harness.pressMsgByLabel;
const threadNote = harness.threadNote;
const warnedEvent = harness.warnedEvent;

test "engagement counts format terse, and omit zero" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("", main.formatCount(arena, 0));
    try testing.expectEqualStrings("6", main.formatCount(arena, 6));
    try testing.expectEqualStrings("854", main.formatCount(arena, 854));
    try testing.expectEqualStrings("1.2k", main.formatCount(arena, 1200));
    try testing.expectEqualStrings("12.1k", main.formatCount(arena, 12100));
}

test "note text splits into link, mention, and plain runs, colored by the identity token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "hi @alice see https://example.com/x ok");
    try testing.expectEqual(@as(usize, 5), spans.len);
    // Content runs take the identity violet through the `info` token; only the
    // link is pressable, and a mention additionally sits one weight up.
    try testing.expectEqualStrings("@alice", spans[1].text);
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    try testing.expectEqual(canvas.TextSpanWeight.medium, spans[1].weight);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len);
    try testing.expectEqualStrings("https://example.com/x", spans[3].text);
    try testing.expectEqualStrings("https://example.com/x", spans[3].link);
    try testing.expect(spans[3].color != null and spans[3].color.? == .info);
    // No underline: an in-text URL is coloured and nothing more. This used to
    // assert only the REQUEST, because the renderer drew a rule under any span
    // carrying a link payload regardless. SDK 0.9.2 made the flag authoritative,
    // so the request and the pixels are the same claim again.
    try testing.expect(!spans[3].underline);
    // Plain text has no link payload.
    try testing.expectEqual(@as(usize, 0), spans[0].link.len);
}

test "a hashtag takes the identity violet only when it carries where it goes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "gm #Nostr build C# code #zig!");
    try testing.expectEqual(@as(usize, 5), spans.len);
    try testing.expectEqualStrings("#Nostr", spans[1].text);
    // The identity violet, the same as a mention and a link: it opens its topic,
    // so it is coloured like the other runs that go somewhere.
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    // And it goes somewhere now. The payload is lowercased, because
    // `contentTags` lowercases on the way out, so `#Nostr` and `#nostr` have to
    // be one topic in both directions.
    const topic = main.topicLinkValueForTest(spans[1].link) orelse return error.HashtagCarriesNoTopic;
    try testing.expectEqualStrings("nostr", topic);

    try testing.expectEqualStrings(" build C# code ", spans[2].text); // C# is not a tag
    try testing.expectEqualStrings("#zig", spans[3].text);
    try testing.expectEqualStrings("!", spans[4].text); // trailing punctuation stays plain

    // A web link keeps its own payload, so widening the channel did not put a
    // topic where a URL belongs.
    const links = main.contentSpans(&ui, "see https://example.com/x");
    try testing.expectEqual(@as(?[]const u8, null), main.topicLinkValueForTest(links[1].link));

    // A tag longer than a topic can be carries no payload, so it must not wear
    // the colour that says "press me": violet on a run that does nothing.
    const long_tag = "#" ++ "a" ** 65;
    const long = main.contentSpans(&ui, "see " ++ long_tag ++ " ok");
    try testing.expectEqual(@as(usize, 3), long.len);
    try testing.expectEqualStrings(long_tag, long[1].text);
    try testing.expectEqual(@as(usize, 0), long[1].link.len);
    try testing.expect(long[1].color == null or long[1].color.? != .info);
}

test "a bare event reference is identity-colored without a link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "see nostr:nevent1qqs example");
    // "see ", then the ref run, then " example".
    try testing.expectEqualStrings("nostr:nevent1qqs", spans[1].text);
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len);
    try testing.expect(!spans[1].underline);
}
test "a pill's label is one line, whatever the note it names" {
    // A widget that measures one line still PAINTS the newlines its text
    // carries, so a label folded from a note with line breaks drew its second
    // and third lines over the row beneath it. Caught in a screenshot, not by
    // any assertion, which is why there is one now.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const folded = main.oneLineForTest(&ui, "- one thing\n- another thing\r\n\n- a third");
    try testing.expect(std.mem.indexOfAny(u8, folded, "\r\n") == null);
    try testing.expectEqualStrings("- one thing - another thing - a third", folded);
    // Text with no breaks is handed back untouched, allocating nothing.
    const plain = "nothing to fold";
    try testing.expectEqual(plain.ptr, main.oneLineForTest(&ui, plain).ptr);
}
test "the snippet stops at one line and on a character boundary" {
    // A snippet cut mid-codepoint draws a replacement glyph, which is a worse
    // thing to show than a shorter snippet.
    const multi = "first line\nsecond line should never appear";
    try testing.expectEqualStrings("first line", main.firstLineOfForTest(multi, 200));

    // Cut inside a multi-byte character: the result must still be valid UTF-8.
    const emoji = "aaa\u{1F600}bbb";
    const cut = main.firstLineOfForTest(emoji, 5); // lands inside the 4-byte emoji
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualStrings("aaa", cut);
}
test "uncovering a note does not persist and does not leak to another" {
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const a = main.noteFrom(warnedEvent(0xC6, "a", &tags), 1_800_000_100);
    const b = main.noteFrom(warnedEvent(0xC7, "b", &tags), 1_800_000_100);
    try testing.expect(main.noteCovered(&a));
    try testing.expect(main.noteCovered(&b));
    main.uncoverNoteForTest(a.id);
    try testing.expect(!main.noteCovered(&a));
    try testing.expect(main.noteCovered(&b));
    // Session only: a new launch starts with the set empty.
    main.forgetUncoveredForTest();
    try testing.expect(main.noteCovered(&a));
}

test "a quote card, a reply line and a quoting pill do not repeat a covered note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const quoted_id = [_]u8{0x5f} ** 32;
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "QUOTEDSECRET");
    main.warnQuoteForTest(quoted_id, "spoilers");

    // The card inside a feed row.
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA2, 100, 0);
    model.notes[0].id = 8;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(tree.root, "Look at this."));
    try testing.expect(!findAnyTextContaining(tree.root, "QUOTEDSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: spoilers"));

    // The line above a reply.
    var reply = main.Note{};
    reply.id = 9;
    reply.reply_parent = quoted_id;
    reply.has_reply_parent = true;
    const line = try main.buildReplyContextForTest(arena, &reply);
    try testing.expect(std.mem.indexOf(u8, line, "QUOTEDSECRET") == null);
    try testing.expect(std.mem.indexOf(u8, line, "reply to") != null);

    // The pill that walks into a quote of a quote.
    var ui = main.AppUi.init(arena);
    const label = main.quotingPillLabelForTest(&ui, quoted_id);
    try testing.expect(std.mem.indexOf(u8, label, "QUOTEDSECRET") == null);

    // Uncovering the note anywhere uncovers it here: it is one note.
    main.uncoverNoteForTest(main.feedKeyForTest(quoted_id));
    const open_line = try main.buildReplyContextForTest(arena, &reply);
    try testing.expect(std.mem.indexOf(u8, open_line, "QUOTEDSECRET") != null);
}

test "a notification covers the words of a covered note and uncovers on a press" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const ev = warnedEvent(0xCD, "NOTIFYSECRET", &tags);
    var item = main.InboxItem{ .used = true, .author = ev.pubkey, .verb = .reply, .created_at = ev.created_at };
    main.bakeBodyForTest(&item, ev);
    try testing.expect(item.warned);

    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(main.notificationRowForTest(&ui, &item));
    try testing.expect(!findAnyTextContaining(tree.root, "NOTIFYSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: spoilers"));
    const msg = pressMsgByLabel(tree, "Show this note") orelse return error.NothingToPress;
    switch (msg) {
        .uncover_note => |key| try testing.expectEqual(main.noteIdOf(ev), key),
        else => return error.WrongPress,
    }

    main.uncoverNoteForTest(main.noteIdOf(ev));
    var ui2 = main.AppUi.init(arena);
    const open = try ui2.finalize(main.notificationRowForTest(&ui2, &item));
    try testing.expect(findAnyTextContaining(open.root, "NOTIFYSECRET"));
}
test "a pressed hashtag opens the tag that was pressed, however many were drawn after it" {
    // A hashtag's payload has to outlive the build that made it, because the
    // press is delivered against that build's tree. It used to sit in a ring of
    // sixteen that every hashtag drawn took the next slot of, so the seventeenth
    // tag on screen wrote over the first, and pressing the first opened the
    // seventeenth's page.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());
    var buf: [32]u8 = undefined;

    // Two builds away from whatever earlier tests drew, so the room is all free.
    main.beginViewBuildForTest();
    main.beginViewBuildForTest();
    const first = main.contentSpans(&ui, "#First")[0].link;
    // Twenty more distinct tags in the same build, more than the old ring held.
    for (0..20) |i| {
        const text = try std.fmt.bufPrint(&buf, "#later{d}", .{i});
        const spans = main.contentSpans(&ui, text);
        try testing.expectEqualStrings(text[1..], main.topicLinkValueForTest(spans[0].link) orelse return error.NoTopic);
    }
    try testing.expectEqualStrings("first", main.topicLinkValueForTest(first) orelse return error.NoTopic);

    // The next build may still be answering a press on the last one, so what the
    // last one drew is kept through it, even when this one draws more tags than
    // there is room for. One that finds no room is drawn without a payload: a
    // run that opens nothing, never one that opens another tag.
    main.beginViewBuildForTest();
    for (0..100) |i| {
        const text = try std.fmt.bufPrint(&buf, "#flood{d}", .{i});
        const link = main.contentSpans(&ui, text)[0].link;
        if (main.topicLinkValueForTest(link)) |topic| try testing.expectEqualStrings(text[1..], topic);
    }
    try testing.expectEqualStrings("first", main.topicLinkValueForTest(first) orelse return error.NoTopic);

    // And the press itself lands on the tag that was pressed.
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .open_url = first }, &fx);
    try testing.expectEqualStrings("first", model.viewingTopic() orelse return error.NoTopic);
    main.closeThreadForTest(&model);

    // Two builds on, nothing can press the old payloads any more, and the room
    // they held is given out again.
    main.beginViewBuildForTest();
    main.beginViewBuildForTest();
    const fresh = main.contentSpans(&ui, "#fresh")[0].link;
    try testing.expectEqualStrings("fresh", main.topicLinkValueForTest(fresh) orelse return error.NoTopic);
}

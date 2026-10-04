//! Tests of quote_cache.zig. Quoted notes: the cache and the fetches that fill it.

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
const findAnyText = harness.findAnyText;
const frameOfText = harness.frameOfText;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;
const warnedEvent = harness.warnedEvent;

test "a quoted note's time is right aligned like every other" {
    // Spotted in a screenshot: the "1d" in a quote card sat well short of the
    // card's right edge. The card's header row had no grow between the name and
    // the time, so the time was placed wherever the name left it. That is LEFT
    // alignment, and it shows because the right edge then moves with the width
    // of the text: two cards an hour apart ended seven points apart.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two quotes whose times render at different widths ("2h" and "12h"), which
    // is what tells left alignment from right.
    // The app's clock reads 0 without an `io`, which a test has none of, so an
    // age is simply `-created_at`. Negative stamps are what make the two cards
    // render "2h" and "12h" here.
    const now: i64 = 0;
    const short_id = [_]u8{0x5e} ** 32;
    const long_id = [_]u8{0x5f} ** 32;
    main.seedQuoteForTest(short_id, [_]u8{0x7a} ** 32, now - 2 * 3600, "Two hours ago.");
    main.seedQuoteForTest(long_id, [_]u8{0x7b} ** 32, now - 12 * 3600, "Twelve hours ago.");

    var model = main.initialModel();
    model.stage = .ready;
    for ([_]struct { i: usize, id: [32]u8 }{ .{ .i = 0, .id = short_id }, .{ .i = 1, .id = long_id } }) |q| {
        model.notes[q.i] = threadNote(@intCast(0xA1 + q.i), now - 5 * 3600, 0);
        model.notes[q.i].id = @intCast(7 + q.i);
        const body = "Look at this.";
        @memcpy(model.notes[q.i].content_buf[0..body.len], body);
        model.notes[q.i].content_len = @intCast(body.len);
        model.notes[q.i].quote = .{ .kind = .event, .id = q.id, .off = 0, .len = 0 };
    }
    model.notes_len = 2;

    const p = try painted.Painted.render(arena, &model);
    const short_f = frameOfText(p, "2h") orelse return error.NoShortTime;
    const long_f = frameOfText(p, "12h") orelse return error.NoLongTime;

    const short_right = short_f.x + short_f.width;
    const long_right = long_f.x + long_f.width;
    // Right aligned: the two share an edge however wide the text is. Left
    // aligned they would share an x instead, and these edges would differ by
    // exactly the width of one digit.
    if (@abs(short_right - long_right) > 1.0) {
        std.debug.print("\nquote times are not right aligned: 2h ends at {d}, 12h at {d}\n", .{ short_right, long_right });
        return error.TheQuoteTimeIsNotRightAligned;
    }
}
test "a quote of a quote is a pill, and the row is priced for it" {
    // Depth stops at one (11g). A second nested body would be a third voice in
    // one row, so the hop becomes a line that says where it goes, and the row
    // has to count it or the list reports less than it draws.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inner_id = [_]u8{0x3c} ** 32;
    const quoted_id = [_]u8{0x5e} ** 32;
    main.seedQuoteForTest(inner_id, [_]u8{0x9b} ** 32, 50, "The note at the end of the hop.");
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "A quoted note that quotes another.");
    // What the fill path learns from the event's own content.
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    e.quote_of = inner_id;
    e.has_quote_of = true;

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
    // The pill is drawn, and it names whose note it walks to.
    try testing.expect(p.frameOf("Quoted note inside it") != null);
    // The pill names whose note it walks to, which is only true once that note
    // has arrived; here it has.
    const pill = p.frameOf("Quoted note inside it").?;
    try testing.expect(pill.width > 0 and pill.height > 0);
    // No third body: exactly one quote aside in the row.
    try testing.expectEqual(@as(usize, 1), p.framesOf("Quoted note").len);

    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
        std.debug.print("\nrow with a pill draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.PillNotPriced;
    }
}
test "a quote still coming, or gone, is priced at what it draws" {
    // `quote_aside_chrome` is the LOADED aside's chrome: it includes the identity
    // block beside the disc. The skeleton and the unavailable line draw no
    // identity at all, so pricing them the same way over-charged every quoting
    // row by nearly three lines from first paint until the quote landed, which is
    // the opposite of the under-pricing this work set out to fix.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x6f} ** 32;
    for ([_]main.QuoteState{ .fetching, .missing }) |state| {
        main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "Not shown in this state.");
        const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
        e.state = state;

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
        if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
            std.debug.print("\n{s}: draws {d}, priced {d}\n", .{ @tagName(state), rows[0].height, priced });
            return error.QuietQuoteMispriced;
        }
    }
}

test "the pill asks again when its note falls out of the cache" {
    // The pill's target is asked for once, when the note holding it is filled.
    // The cache holds 64 entries and can evict that target while the pill is
    // still on screen, and nothing would ask again: the note holding it is
    // loaded, and refreshQuotes never revisits a loaded entry.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const evicted = [_]u8{0xd1} ** 32;
    main.dropQuoteForTest(evicted);
    try testing.expect(main.quoteForTest(evicted) == null);

    _ = main.quotingPillLabelForTest(&ui, evicted);
    // Asked for again, so it can come back.
    try testing.expect(main.quoteForTest(evicted) != null);
}
test "a quoted note that is only a picture says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The fill path cuts the image URL out of the body deliberately (a raw URL
    // is not something to read) and used to record nothing in its place, so a
    // note whose whole content is one picture came out with an empty body and
    // drew a card with a name, a time and a blank line under them.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{61} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quoted.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const shot = try signedNote(arena, signer, kp, 1_800_000_000, "https://i.nostr.build/aBcD1234.jpg");
    _ = try store.ingest(arena, shot, .{});

    main.dropQuoteForTest(shot.id);
    main.wantQuoteForTest(shot.id);
    main.refreshQuotesForTest(&store);

    const e = main.quoteForTest(shot.id) orelse return error.NoQuote;
    try testing.expectEqual(main.QuoteState.loaded, e.state);
    // The body really is empty: the whole note was the URL, and the URL is cut.
    try testing.expectEqual(@as(u16, 0), e.text_len);
    // So the card has to have something else to say.
    try testing.expectEqualStrings("i.nostr.build", e.image_host_buf[0..e.image_host_len]);
}

test "a quote card with nothing to read is not a blank card" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x6f} ** 32;
    main.dropQuoteForTest(quoted_id);
    main.seedQuoteForTest(quoted_id, [_]u8{0x2b} ** 32, 100, "");
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    const host = "i.nostr.build";
    @memcpy(e.image_host_buf[0..host.len], host);
    e.image_host_len = host.len;

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
    // The card says what it holds, by name and by host.
    if (findAnyText(p.tree.root, "Picture from i.nostr.build") == null) {
        std.debug.print("the quote card says nothing about the picture in it\n", .{});
        return error.SilentAboutMedia;
    }
    // And the row is priced for the line it draws, or a feed of these scrolls
    // against a scrollbar that is measuring a different page.
    //
    // Held to half a line rather than the usual line and a half. That slack
    // exists because every estimate here counts CHARACTERS against a column
    // where the engine measures glyphs and breaks at words; this quote has no
    // characters to disagree about, so the estimate should be exact and the only
    // thing the slack could hide is a line charged for a body that is not there.
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 0.5 * main.body_line_height) {
        std.debug.print("\nrow with a picture chip draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.ChipNotPriced;
    }
}
test "the fill path keeps what the card needs to draw the picture, and refuses what it should" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{62} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quotedpic.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const url = "https://i.nostr.build/aBcD1234.jpg";
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    const described = try signedKind(arena, signer, kp, 1_800_000_000, 1, &[_]nostr.event.Tag{
        &.{ "imeta", "url " ++ url, "dim 800x400", "blurhash " ++ hash },
    }, "look " ++ url);
    // A file the note itself says is a video, however it is named.
    const video_url = "https://i.nostr.build/clip.jpg";
    const video = try signedKind(arena, signer, kp, 1_800_000_001, 1, &[_]nostr.event.Tag{
        &.{ "imeta", "url " ++ video_url, "m video/mp4" },
    }, video_url);
    // An address longer than a feed picture keeps.
    const long_url = "https://i.nostr.build/" ++ "a" ** 200 ++ ".jpg";
    const long = try signedNote(arena, signer, kp, 1_800_000_002, long_url);
    // No imeta at all: a picture of unknown shape.
    const bare_url = "https://i.nostr.build/bare.png";
    const bare = try signedNote(arena, signer, kp, 1_800_000_003, bare_url);
    for ([_]nostr.event.Event{ described, video, long, bare }) |ev| {
        _ = try store.ingest(arena, ev, .{});
        main.dropQuoteForTest(ev.id);
        main.wantQuoteForTest(ev.id);
    }
    main.refreshQuotesForTest(&store);

    const d = main.quoteForTest(described.id) orelse return error.NoQuote;
    try testing.expectEqualStrings(url, d.imageUrl());
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.image_aspect, 0.0001);
    try testing.expectEqualStrings(hash, d.imageBlurhash());
    // The slot key is the one the quoted note's own feed row would use, so the
    // two share a slot when both are on screen.
    try testing.expectEqual(main.mediaKeyForTest(main.noteIdOf(described), 0), main.quoteMediaKeyForTest(described.id));

    const v = main.quoteForTest(video.id) orelse return error.NoQuote;
    try testing.expectEqual(@as(usize, 0), v.imageUrl().len);
    // Still named, as before: the card knows there is a file and where from.
    try testing.expect(v.image_host_len > 0);

    const l = main.quoteForTest(long.id) orelse return error.NoQuote;
    try testing.expectEqual(@as(usize, 0), l.imageUrl().len);
    try testing.expect(l.image_host_len > 0);

    const b = main.quoteForTest(bare.id) orelse return error.NoQuote;
    try testing.expectEqualStrings(bare_url, b.imageUrl());
    try testing.expectEqual(@as(f32, 0), b.image_aspect);
    try testing.expectEqual(@as(usize, 0), b.imageBlurhash().len);
}
test "a quote that could not be found is asked for again, and again" {
    // Three unanswered tries used to mark an entry missing for good: nothing
    // re-armed it, not a later round, not a reconnect, not reopening the thread.
    // Three tries is nothing, and they can all land while the pool is still
    // dialling, so a note sitting on the reader's OWN relays could be written
    // off in the first seconds and read "not on your relays yet" for the rest of
    // the session. That is what happened to the ancestor above a thread every
    // other client showed, and I fetched that parent from those same four relays
    // in under a second.
    const id = [_]u8{0x4c} ** 32;
    main.dropQuoteForTest(id);
    main.wantQuoteForTest(id);

    // Ask until well past the old cap of three, re-arming between rounds the way
    // the timer does.
    var tries: usize = 0;
    for (0..40) |_| {
        main.rearmWantedQuotesForTest();
        main.advanceQuoteRoundForTest(main.quoteBackoffRoundsForTest(255));
        main.requestWantedQuotesForTest();
        const e = main.quoteForTest(id) orelse return error.QuoteEvicted;
        if (e.attempts > tries) tries = e.attempts;
    }
    if (tries <= 3) {
        std.debug.print("gave up after {d} tries\n", .{tries});
        return error.GaveUpForGood;
    }

    // And it backs off rather than hammering: the first few rounds try every
    // time, then the gap grows to a ceiling.
    try testing.expectEqual(@as(u64, 1), main.quoteBackoffRoundsForTest(0));
    try testing.expectEqual(@as(u64, 1), main.quoteBackoffRoundsForTest(2));
    try testing.expect(main.quoteBackoffRoundsForTest(6) > 1);
    try testing.expect(main.quoteBackoffRoundsForTest(200) <= 30);
}

test "a relay coming up puts every unfound note back in the queue" {
    // The backoff alone would still make a reader wait out a gap for something
    // that became findable the instant a relay finished dialling. A change in
    // the pool is new information about every unanswered question.
    const id = [_]u8{0x4d} ** 32;
    main.dropQuoteForTest(id);
    main.wantQuoteForTest(id);
    main.requestWantedQuotesForTest();

    const e = main.quoteForTest(id) orelse return error.QuoteEvicted;
    // Pushed into the future by its own backoff.
    main.advanceQuoteRoundForTest(0);
    e.next_round = 999_999;
    e.requested = true;

    main.requeueMissingQuotesForTest();
    try testing.expectEqual(@as(u64, 0), e.next_round);
    try testing.expect(!e.requested);
}
test "a quote still loading looks like the card that will replace it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // It was one 34px bar, which says "something is loading" and nothing about
    // what. A quote card is a face, a name and a line or two of somebody else's
    // words, so the wait is shaped like that.
    const quoted_id = [_]u8{0x7e} ** 32;
    main.dropQuoteForTest(quoted_id);
    main.wantQuoteForTest(quoted_id);

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
    var discs: usize = 0;
    var bars: usize = 0;
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .skeleton) continue;
        const f = node.widget.frame;
        if (f.width > 0 and @abs(f.width - f.height) < 1.5) discs += 1 else bars += 1;
    }
    if (discs == 0 or bars < 2) {
        std.debug.print("the waiting quote draws {d} disc(s) and {d} bar(s)\n", .{ discs, bars });
        return error.NotACardShape;
    }

    // And the row is still priced for what it draws, or the feed jumps when the
    // quote lands. That pricing is what the skeleton's fixed height is FOR.
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
        std.debug.print("\nwaiting row draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.SkeletonNotPriced;
    }
}
test "a reply in the feed says what it answers" {
    // A feed that mixes replies in with root notes shows half a conversation:
    // an answer with no question reads as a non sequitur, or worse as something
    // the person said unprompted.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();

    const parent_id = [_]u8{0xab} ** 32;
    const parent_author = [_]u8{0xcd} ** 32;

    var note = main.Note{};
    note.id = 4242;
    note.reply_parent = parent_id;
    note.has_reply_parent = true;

    // Before the parent resolves the line is still there, holding its place,
    // saying the neutral thing rather than flickering a name in later.
    {
        const tree = try main.buildReplyContextForTest(arena, &note);
        try testing.expect(std.mem.indexOf(u8, tree, "reply to") != null);
    }

    // Once it resolves it names the author and shows the opening words.
    main.fillQuoteForTest(parent_id, parent_author, "sorry, only cold snow up here :D");
    {
        const tree = try main.buildReplyContextForTest(arena, &note);
        try testing.expect(std.mem.indexOf(u8, tree, "reply to") != null);
        if (std.mem.indexOf(u8, tree, "cold snow") == null) {
            std.debug.print("the line does not carry the answered note's words: {s}\n", .{tree});
            return error.NoSnippet;
        }
    }

    // A root note gets no line at all.
    var root = main.Note{};
    root.id = 99;
    try testing.expect(!root.has_reply_parent);
}
test "building a reply queues the note it answers, so the line can fill in" {
    // The line is only ever useful if something actually goes and fetches the
    // parent. `noteFrom` is where that has to happen, because it is the one
    // place every note in the feed passes through, and a test that fills the
    // cache by hand proves nothing about it.
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();

    const parent_hex = "ab" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "e", parent_hex, "", "reply" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0x11} ** 32,
        .pubkey = [_]u8{0x22} ** 32,
        .created_at = 1000,
        .kind = 1,
        .tags = &tags,
        .content = "answering you",
        .sig = [_]u8{0} ** 64,
    };

    const note = main.noteFrom(ev, 2000);
    try testing.expect(note.has_reply_parent);

    if (main.quoteForTest(note.reply_parent) == null) {
        std.debug.print("the answered note was never queued, so the line stays generic forever\n", .{});
        return error.ParentNeverRequested;
    }
}
test "a reply snippet stops saying npub once the name lands" {
    // The snippet is baked into text the same way a note body is: a mention
    // becomes "@Name", or an abbreviated npub when no name is known yet. A body
    // re-parses when a display name arrives, because the names generation
    // moving invalidates every card. The quote cache had no such stamp, so a
    // snippet rendered before its mentioned author's kind:0 landed kept the
    // npub for as long as the entry lived, which is the raw "@npub1..." showing
    // in a reply context line while the same person's name reads correctly two
    // rows down.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6d} ** 32);
    const mentioned = try signer.keyPairFromSecretKey([_]u8{0x6e} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quote-names.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    main.resetProfilesForTest();
    main.resetQuotesForTest();
    defer main.resetProfilesForTest();
    defer main.resetQuotesForTest();

    // A note that mentions somebody nobody has a name for yet.
    const npub = try nostr.nip19.encodeNpub(arena, mentioned.public_key);
    const body = try std.fmt.allocPrint(arena, "hello nostr:{s} how are you", .{npub});
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, body, null);
    _ = try store.ingest(arena, ev, .{});

    main.wantQuoteForTest(ev.id);
    main.refreshQuotesForTest(&store);
    const before = main.quoteTextForTest(ev.id) orelse return error.TheQuoteNeverLoaded;
    if (std.mem.indexOf(u8, before, "npub1") == null) {
        std.debug.print("expected an npub while the name is unknown, got \"{s}\"\n", .{before});
        return error.NoNpubToBeginWith;
    }

    // The name lands, exactly as it does live: a kind:0 into the store, then
    // the profile pass that reads it and moves the names generation.
    var meta_buf: [128]u8 = undefined;
    const meta = try std.fmt.bufPrint(&meta_buf, "{{\"name\":\"Rabble\"}}", .{});
    const kind0 = try nostr.event.create(arena, signer, mentioned, 1_800_000_060, 0, &.{}, meta, null);
    _ = try store.ingest(arena, kind0, .{});
    main.refreshProfilesForTest(&store);
    main.refreshQuotesForTest(&store);

    const after = main.quoteTextForTest(ev.id) orelse return error.TheQuoteWentAway;
    if (std.mem.indexOf(u8, after, "npub1") != null) {
        std.debug.print("the snippet still says npub after the name landed: \"{s}\"\n", .{after});
        return error.TheSnippetKeptTheNpub;
    }
    try testing.expect(std.mem.indexOf(u8, after, "@Rabble") != null);
}
test "a quoted note in a note body keeps the relays its address named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();

    const id = [_]u8{0x88} ** 32;
    const relays = [_][]const u8{"wss://quoted-lives-here.example"};
    const body = try std.fmt.allocPrint(arena, "look at this nostr:{s}", .{
        try nostr.nip19.encodeNevent(arena, id, &relays, [_]u8{0x99} ** 32, 1),
    });

    // The ordinary path: a note arrives in the feed carrying a quote, and the
    // scan that finds the quote is where the hints were being dropped.
    _ = main.findQuoteRefForTest(body);
    try testing.expectEqual(@as(?u8, 1), main.quoteHintCountForTest(id));
}
/// The width of a notice's label in units: one for a narrow character, two for a
/// wide one. The engine's test measure is not a glyph measure (it sizes CJK
/// narrower than a screen does), so the claim "this fits" is made on what the
/// label says, with a deliberately generous width per unit.
fn labelUnits(text: []const u8) usize {
    var units: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| units += if (cp >= 0x2E80) @as(usize, 2) else 1;
    return units;
}

/// A covered note's chip, in a column of `column`: the label cut to a short
/// line, and that line plus the "Show" and the paddings inside the column even at
/// seven pixels a unit, wider than the mono register ever draws a unit.
fn expectChipFits(p: painted.Painted, chip: native_sdk.geometry.RectF, column: native_sdk.geometry.RectF) !void {
    var label: ?[]const u8 = null;
    for (p.layout.nodes) |n| {
        if (std.mem.startsWith(u8, n.widget.text, "Content warning")) label = n.widget.text;
    }
    const text = label orelse return error.NoLabel;
    try testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
    const worst = @as(f32, @floatFromInt(labelUnits(text))) * 7.0 + 4 * 7.0 + 60.0;
    if (chip.x < column.x - 0.5 or chip.x + chip.width > column.x + column.width + 0.5 or worst > chip.width) {
        std.debug.print("\nchip {d}..{d} column {d}..{d}, label needs about {d}\n", .{ chip.x, chip.x + chip.width, column.x, column.x + column.width, worst });
        return error.ChipOutsideColumn;
    }
    const show = frameOfText(p, "Show") orelse return error.NoShow;
    try testing.expect(show.x + show.width <= chip.x + chip.width + 0.5);
}

test "a long reason stays inside the column it is drawn in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    // 48 wide characters, then 48 narrow ones: the two ways a reason runs long.
    const cjk = "警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容";
    const latin = "a reason that goes on and on and on and on and on";
    const reasons = [_][]const u8{ cjk, latin };

    for (reasons) |reason| {
        // A nested reply, at the deepest indent a thread draws, in the narrowest
        // window the app allows.
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root = main.noteFrom(warnedEvent(0xD0, "the root", &.{}), 1_800_000_100);
        model.viewing_thread = model.thread_root.id;
        const tags = [_]nostr.event.Tag{&.{ "content-warning", reason }};
        var reply = warnedEvent(0xD1, "REPLYSECRET", &tags);
        reply.created_at = 1_800_000_200;
        model.thread_notes[0] = main.noteFrom(reply, 1_800_000_300);
        model.thread_notes[0].reply_parent = model.thread_root.event_id;
        model.thread_notes[0].has_reply_parent = true;
        model.thread_notes[0].depth = 6;
        model.thread_notes_len = 1;

        const p = try painted.Painted.renderAt(arena, &model, main.window_min_width, main.window_height);
        const chips = p.framesOf("Show this note");
        try testing.expectEqual(@as(usize, 1), chips.len);
        const rows = p.framesOf("Open thread");
        try testing.expect(rows.len >= 1);
        // Inside the reply's own row, which is the column it is drawn in.
        try expectChipFits(p, chips[0], rows[rows.len - 1]);

        // A quote card in a feed row.
        const quoted_id = [_]u8{0x5e} ** 32;
        main.seedQuoteForTest(quoted_id, [_]u8{0x7b} ** 32, 100, "QUOTEDSECRET");
        main.warnQuoteForTest(quoted_id, reason[0..@min(reason.len, 96)]);
        var feed = main.initialModel();
        feed.stage = .ready;
        feed.notes[0] = threadNote(0xA3, 100, 0);
        feed.notes[0].id = 11;
        const body = "Look at this.";
        @memcpy(feed.notes[0].content_buf[0..body.len], body);
        feed.notes[0].content_len = @intCast(body.len);
        feed.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
        feed.notes_len = 1;
        const q = try painted.Painted.renderAt(arena, &feed, main.window_min_width, main.window_height);
        const qchips = q.framesOf("Show this note");
        try testing.expectEqual(@as(usize, 1), qchips.len);
        const cards = q.framesOf("Quoted note");
        try testing.expectEqual(@as(usize, 1), cards.len);
        try expectChipFits(q, qchips[0], cards[0]);
        main.resetQuotesForTest();
    }
}
test "a card for an naddr fills from the store and opens the article" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6a} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "card");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();
    main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "the-card" },
        &[_][]const u8{ "title", "The title on the card" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The article body.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    // A note in the store that names the article, parsed the way the feed does.
    const naddr = try nostr.nip19.encodeNaddr(arena, "the-card", kp.public_key, 30023, &.{});
    const text = try std.fmt.allocPrint(arena, "this one nostr:{s}", .{naddr});
    const note_ev = try signedNote(arena, signer, kp, 1_800_000_100, text);
    const note = main.noteFrom(note_ev, 1_800_000_200);
    try testing.expect(main.noteHasEventQuote(&note));

    // Loading first: the card exists and has not resolved.
    const e = main.quoteForTest(note.quote.id) orelse return error.NoCard;
    try testing.expect(e.state != .loaded);

    // Found: the store has it, so one pass fills the card with the article's title.
    main.refreshQuotesForTest(&store);
    try testing.expect(e.state == .loaded);
    try testing.expectEqualStrings("The title on the card", main.quoteTextForTest(note.quote.id) orelse "");

    // And pressing it, which is an open of the card's key, opens the article.
    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, note.quote.id);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));
}

test "an naddr card keeps its address after the table lets it go" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6e} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "cardevicted");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "kept" },
        &[_][]const u8{ "title", "Still reachable" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The article body.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    const naddr = try nostr.nip19.encodeNaddr(arena, "kept", kp.public_key, 30023, &.{});
    const text = try std.fmt.allocPrint(arena, "read this nostr:{s}", .{naddr});
    const note_ev = try signedNote(arena, signer, kp, 1_800_000_100, text);
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(note_ev, 1_800_000_200);
    model.notes_len = 1;
    const key = model.notes[0].quote.id;
    try testing.expect(main.addressRegisteredForTest(key));

    // The note stays in the feed; the address table and the quote cache both
    // move on without it, as they do under a long scroll.
    main.resetAddressesForTest();
    main.resetQuotesForTest();
    try testing.expect(!main.addressRegisteredForTest(key));

    // Drawn again, the card files its address again, so it fills and opens.
    _ = try buildTree(arena, &model);
    try testing.expect(main.addressRegisteredForTest(key));
    main.refreshQuotesForTest(&store);
    try testing.expectEqualStrings("Still reachable", main.quoteTextForTest(key) orelse "");
    var opened = main.initialModel();
    opened.stage = .ready;
    main.openEventForTest(&opened, key);
    try testing.expect(std.mem.eql(u8, &opened.thread_root.event_id, &ev.id));
}

test "a card for an naddr nobody has settles as missing, and loads if it lands later" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6b} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "cardmissing");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const naddr = try nostr.nip19.encodeNaddr(arena, "ghost", kp.public_key, 30023, &.{});
    const note = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}));
    main.wantQuoteForTest(note.quote.id);
    const e = main.quoteForTest(note.quote.id) orelse return error.NoCard;

    // Asked and unanswered enough times, the card stops showing a skeleton. The
    // store never changes here, so nothing but the asking can have said so: a
    // card that waits for the store to grow is a spinner on a quiet one.
    for (0..6) |_| {
        main.rearmWantedQuotesForTest();
        main.advanceQuoteRoundForTest(main.quoteBackoffRoundsForTest(255));
        main.requestWantedQuotesForTest();
    }
    try testing.expect(e.state == .missing);
    try testing.expect(e.attempts > 3);

    // Missing is what the row says, not a verdict: the article lands afterwards
    // and the card fills.
    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "ghost" },
        &[_][]const u8{ "title", "It was there after all" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "Late.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.refreshQuotesForTest(&store);
    try testing.expect(e.state == .loaded);
    try testing.expectEqualStrings("It was there after all", main.quoteTextForTest(note.quote.id) orelse "");
}

test "a round of quote cards asks a few addresses and dials fewer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const pk = [_]u8{0x49} ** 32;
    var keys: [6][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        const ident = try std.fmt.allocPrint(arena, "card-{d}", .{i});
        const naddr = try nostr.nip19.encodeNaddr(arena, ident, pk, 30023, &.{});
        const note = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}));
        k.* = note.quote.id;
        main.wantQuoteForTest(k.*);
    }

    main.rearmWantedQuotesForTest();
    main.requestWantedQuotesForTest();
    var asked: usize = 0;
    var dialled: usize = 0;
    for (keys) |k| {
        if (main.quoteForTest(k).?.requested) asked += 1;
        if (main.addressDialledForTest(k)) dialled += 1;
    }
    try testing.expectEqual(@as(usize, main.addressPoolBatchForTest), asked);
    try testing.expectEqual(@as(usize, main.addressDialsPerRoundForTest), dialled);

    // The ones left over are not forgotten: the next round takes them.
    main.advanceQuoteRoundForTest(1);
    main.requestWantedQuotesForTest();
    asked = 0;
    for (keys) |k| {
        if (main.quoteForTest(k).?.requested) asked += 1;
    }
    try testing.expectEqual(@as(usize, 6), asked);
}

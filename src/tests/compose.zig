//! Tests of compose.zig. Writing: compose and reply, post timing, tags, content warnings, reactions, reposts and deletes.

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
const countTags = harness.countTags;
const freshHints = harness.freshHints;
const hint_a = harness.hint_a;
const hint_b = harness.hint_b;
const hint_c = harness.hint_c;
const noteContext = harness.noteContext;
const relayListFor = harness.relayListFor;
const tagNamed = harness.tagNamed;

test "a note waits before it is signed, and pressing again takes it back" {
    // plaza#330. The pause is on the NEAR side of the signature on purpose:
    // once a note is signed and out, a kind:5 is a request a relay may ignore
    // and everyone already holding the event keeps it. An undo that ran after
    // publishing would be a button that cannot do what it says.
    // Off unless asked for. Turning it on for everybody would make a note that
    // suddenly does not post read as a fault before it reads as a safeguard.
    try testing.expectEqual(@as(i64, 0), main.postDelayForTest());

    // Nothing held, nothing due.
    try testing.expect(!main.postIsDue(0, 1_800_000_000));

    // Held, and not due until the clock runs out.
    const due: i64 = 1_800_000_005;
    try testing.expect(!main.postIsDue(due, 1_800_000_000));
    try testing.expect(!main.postIsDue(due, 1_800_000_004));
    try testing.expect(main.postIsDue(due, due));
    try testing.expect(main.postIsDue(due, due + 60));

    // What the button counts down. Never zero while something is held: a button
    // reading "Undo 0" has already gone.
    try testing.expectEqual(@as(i64, 5), main.postSecondsLeft(due, 1_800_000_000));
    try testing.expectEqual(@as(i64, 1), main.postSecondsLeft(due, 1_800_000_004));
    try testing.expectEqual(@as(i64, 1), main.postSecondsLeft(due, due + 10));
    try testing.expectEqual(@as(i64, 0), main.postSecondsLeft(0, 1_800_000_000));
}

test "the ways out of the composer all take a held note back" {
    // Both found by asking what happens on the paths that are not the happy
    // one. Pressing Post and then Cancel used to publish, seconds later, the
    // note whose composer had just been dismissed.
    main.setIdentityForTest([_]u8{0x7a} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    main.holdPostForTest(1_800_000_000);
    try testing.expect(main.postHeldForTest());
    main.update(&model, .close_compose, &fx);
    try testing.expect(!main.postHeldForTest());

    // A reply is exactly as final as a note, and it belongs to the thread being
    // left. Leaving it armed would publish it into a conversation the reader
    // had walked away from.
    main.holdReplyForTest(1_800_000_000);
    try testing.expect(main.replyHeldForTest());
    main.update(&model, .close_thread, &fx);
    try testing.expect(!main.replyHeldForTest());
}
test "a note says nothing about what wrote it unless the reader asks" {
    // OFF by default, which is the choice Sepehr made and NIP-89 hints at: the
    // tag is a small permanent fact about the reader attached to everything they
    // write, and it follows the note to every relay forever.
    const gpa = testing.allocator;
    main.setClientTag(false);
    defer main.setClientTag(false);

    const base = [_]nostr.event.Tag{&.{ "e", "ab" ** 32 }};
    {
        const out = main.withClientTag(gpa, 1, &base);
        try testing.expectEqual(@as(usize, 1), out.len);
    }

    main.setClientTag(true);
    // A note, and a repost of one: the things the reader actually wrote.
    for ([_]u16{ 1, 6 }) |kind| {
        const out = main.withClientTag(gpa, kind, &base);
        defer {
            gpa.free(out[out.len - 1]);
            gpa.free(out);
        }
        try testing.expectEqual(@as(usize, 2), out.len);
        try testing.expectEqualStrings("client", out[1][0]);
        try testing.expectEqualStrings("Plaza", out[1][1]);
    }
    // Machinery is not writing. A reaction and a deletion carry nothing: they
    // would broadcast the same fact more widely for nothing the reader can see,
    // which is the opposite of what an opt-in privacy switch is for.
    for ([_]u16{ 7, 5, 3, 0 }) |kind| {
        const out = main.withClientTag(gpa, kind, &base);
        try testing.expectEqual(@as(usize, 1), out.len);
    }
}

test "what a stranger's note claims about its client is treated as foreign text" {
    const cases = [_]struct { value: []const u8, shown: ?[]const u8 }{
        .{ .value = "Plaza", .shown = "Plaza" },
        .{ .value = "  Amethyst  ", .shown = "Amethyst" },
        // Too long for the row is CUT, not thrown away: the name is still
        // evidence about the note, and refusing it outright discarded the whole
        // fact. Fourteen characters.
        .{ .value = "x" ** 40, .shown = "x" ** 14 },
        // And cut by CHARACTER, not by byte. A byte cap is about eight
        // characters of Japanese and twenty-four of English, so it refused a
        // legitimate name in one script and accepted a far wider one in another.
        .{ .value = "クライアントの名前がとても長い", .shown = "クライアントの名前がとても長" },
        // A newline in a meta row is how a row stops looking like a row.
        .{ .value = "Damus\nHACKED", .shown = null },
        .{ .value = "", .shown = null },
        .{ .value = "   ", .shown = null },
    };
    for (cases) |c| {
        const ev = nostr.event.Event{
            .id = [_]u8{0} ** 32,
            .pubkey = [_]u8{0} ** 32,
            .created_at = 1_800_000_000,
            .kind = 1,
            .tags = &.{&.{ "client", c.value }},
            .content = "hi",
            .sig = [_]u8{0} ** 64,
        };
        if (c.shown) |want| {
            try testing.expectEqualStrings(want, main.clientOf(ev) orelse return error.NothingShown);
        } else {
            try testing.expect(main.clientOf(ev) == null);
        }
    }
    // A note with no tag at all draws nothing, never "via unknown": what a note
    // does not say is not a fact about it.
    const bare = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "hi",
        .sig = [_]u8{0} ** 64,
    };
    try testing.expect(main.clientOf(bare) == null);
}
test "a remembered follow is never written over a contact list nobody has read" {
    // The follow-safety rule outranks the convenience: this publishes a
    // replaceable list, and completing a remembered intent is exactly the moment
    // it would be tempting to skip the check, because the reader asked for it
    // minutes ago and is not watching.
    var fx: main.EffectsForTest = undefined;
    main.setIdentityForTest([_]u8{0x5B} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.pending = .{ .follow = [_]u8{0x4A} ** 32 };
    main.drivePendingIntentForTest(&model, &fx);

    // Spent either way, so it cannot retry on every tick for the rest of the
    // session, and the reader is told rather than left to guess.
    try testing.expect(!model.pending.waiting());
    try testing.expect(model.toast_until != 0);
}
test "a busy signer is named as any signer by Post, and said by Delete" {
    // Post blamed Notary for a bunker with every slot taken, and Delete closed
    // its confirm on nothing.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const mine = try signer.keyPairFromSecretKey([_]u8{33} ** 32);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/busy.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.setIdentityForTest([_]u8{33} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    const my_note = try nostr.event.create(arena, signer, mine, 1_800_000_000, 1, &.{}, "mine", null);
    _ = try main.plazaIngestForTest(arena, my_note);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    model.notes[0].event_id = my_note.id;
    model.notes[0].pubkey = mine.public_key;
    model.notes_len = 1;
    var fx: main.EffectsForTest = undefined;

    main.holdHelperSignForTest();
    defer main.releaseHelperSignForTest();
    model.composing = true;
    model.draft_buffer.set("a note");
    try testing.expect(!main.firePost(&model, &fx, null));
    try testing.expectEqualStrings(main.signer_busy_toast, model.toast_text());
    try testing.expectEqualStrings("a note", model.draft());

    model.toast_len = 0;
    main.deleteNote(&model, &fx, 1);
    try testing.expectEqualStrings(main.signer_busy_toast, model.toast_text());
    try testing.expect(main.lastPublishedForTest() == null);
}

test "delete is offered on my own note and refuses anything but a kind 1 of mine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const mine = try signer.keyPairFromSecretKey([_]u8{31} ** 32);
    const theirs = try signer.keyPairFromSecretKey([_]u8{32} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/del.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.setIdentityForTest([_]u8{31} ** 32);
    defer main.clearIdentityForTest();

    // Three events: my note, my relay list, and somebody else's note.
    const my_note = try nostr.event.create(arena, signer, mine, 1_800_000_000, 1, &.{}, "mine", null);
    _ = try main.plazaIngestForTest(arena, my_note);
    const my_list = try nostr.event.create(arena, signer, mine, 1_800_000_001, 10002, &.{&.{ "r", "wss://a.example" }}, "", null);
    _ = try main.plazaIngestForTest(arena, my_list);
    const their_note = try nostr.event.create(arena, signer, theirs, 1_800_000_002, 1, &.{}, "theirs", null);
    _ = try main.plazaIngestForTest(arena, their_note);

    var model = main.initialModel();
    model.stage = .ready;
    inline for (.{ .{ 1, my_note, mine }, .{ 2, my_list, mine }, .{ 3, their_note, theirs } }, 0..) |row, i| {
        model.notes[i] = main.Note{ .created_at = 1_800_000_000 };
        model.notes[i].id = row[0];
        model.notes[i].event_id = row[1].id;
        model.notes[i].pubkey = row[2].public_key;
    }
    model.notes_len = 3;

    // My kind 1: yes, and the kind comes back from the store rather than the card.
    if (main.deletableTargetKindForTest(&model, 1) == null) {
        std.debug.print("my own kind:1 was refused; identity or store lookup did not line up\n", .{});
        return error.OwnNoteRefused;
    }
    try testing.expectEqual(@as(?u16, 1), main.deletableTargetKindForTest(&model, 1));
    // My relay list: NO. A replaceable event is superseded, never deleted, and
    // a kind:5 aimed at one asks every relay to drop it with no way back. This
    // is the assertion that matters most in this test.
    try testing.expectEqual(@as(?u16, null), main.deletableTargetKindForTest(&model, 2));
    // Somebody else's note: no.
    try testing.expectEqual(@as(?u16, null), main.deletableTargetKindForTest(&model, 3));

    // And the row is offered on mine, absent on theirs.
    for ([_]struct { id: i64, want: bool }{ .{ .id = 1, .want = true }, .{ .id = 3, .want = false } }) |case| {
        var one = main.initialModel();
        one.stage = .ready;
        one.notes[0] = model.notes[if (case.id == 1) 0 else 2];
        one.notes_len = 1;
        const p = try painted.Painted.render(arena, &one);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        var found = false;
        for (menu.items) |item| {
            if (std.mem.eql(u8, item.label, "Delete")) found = true;
        }
        if (found != case.want) {
            std.debug.print("note {d}: Delete offered={}, wanted {}\n", .{ case.id, found, case.want });
            return error.WrongDeleteRow;
        }
    }
}
test "a note carries the tags its own text implies" {
    // The composer used to publish kind:1 with a literally empty tag array, so a
    // hashtag was violet text that no relay filter could find, a picked mention
    // notified nobody, and an image URL arrived with no imeta for a client to
    // lay out. Everything here is derived from the finished string at publish.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "shipping #Nostr today, see https://example.com/a.png");
    const t = tagNamed(tags, "t") orelse return error.NoTopicTag;
    // NIP-24 is a MUST on the value being lowercase, so the as-typed "#Nostr"
    // has to arrive folded or a relay filter for "nostr" never matches it.
    try testing.expectEqualStrings("nostr", t[1]);

    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expectEqualStrings("url https://example.com/a.png", im[1]);
    // One space between key and value, and a reader splits on the FIRST space
    // only, because a value may contain spaces of its own.
    try testing.expectEqualStrings("m image/png", im[2]);
}

test "a hash inside a URL is not a hashtag" {
    // The scanner consumes a URL run whole before it looks for a '#'. Without
    // that ordering every link with a fragment publishes a junk topic, which is
    // a bug both reference clients still have.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "see https://example.com/guide#installation for the steps");
    try testing.expectEqual(@as(usize, 0), countTags(tags, "t"));
}

test "topics fold and dedupe, and a non-ASCII one stays whole" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    // Case-folded BEFORE the duplicate check, or "#Nostr #nostr" ships twice.
    const dedup = main.contentTagsForTest(gpa, "#Nostr and #nostr and #NOSTR");
    try testing.expectEqual(@as(usize, 1), countTags(dedup, "t"));

    // The old predicate was ASCII-only, so this emitted a truncated "caf".
    const unicode = main.contentTagsForTest(gpa, "#café");
    const t = tagNamed(unicode, "t") orelse return error.NoTopicTag;
    try testing.expectEqualStrings("café", t[1]);
}

test "a mention becomes a p tag, and a bare hash does not become anything" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x2a;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    const body = try std.fmt.allocPrint(gpa, "thanks nostr:{s} for the help", .{npub});

    const tags = main.contentTagsForTest(gpa, body);
    const p = tagNamed(tags, "p") orelse return error.NoMentionTag;
    // Lowercase 64-hex, which is what NIP-01 requires of a pubkey in a tag.
    try testing.expectEqual(@as(usize, 64), p[1].len);
    try testing.expect(std.mem.startsWith(u8, p[1], "2a00"));

    // A '#' with nothing word-like after it is punctuation, not a topic.
    const bare = main.contentTagsForTest(gpa, "the # sign, and #!/bin/sh");
    try testing.expectEqual(@as(usize, 0), countTags(bare, "t"));
}

test "one long paste yields the same tags as the same text typed" {
    // The parse runs over the finished content at publish, never over
    // keystrokes, so there is no separate paste path that could drift from the
    // typing one. This pins that: everything at once, in one string, the way a
    // paste arrives.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x7f;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    var eid = [_]u8{0} ** 32;
    eid[0] = 0xc3;
    const nevent = try nostr.nip19.encodeNevent(gpa, eid, &.{}, null, 1);

    const pasted = try std.fmt.allocPrint(gpa,
        \\A long note pasted in one go, the way anything real arrives.
        \\
        \\It mentions nostr:{s}, quotes nostr:{s}, links
        \\https://example.com/docs#section which must NOT become a topic, shows
        \\https://example.com/shot.jpg and repeats https://example.com/shot.jpg,
        \\and tags #Zig and #zig and #buildinpublic.
    , .{ npub, nevent });

    const tags = main.contentTagsForTest(gpa, pasted);
    // #zig folded and deduped against #Zig, plus #buildinpublic. The URL
    // fragment contributes nothing.
    try testing.expectEqual(@as(usize, 2), countTags(tags, "t"));
    try testing.expectEqual(@as(usize, 1), countTags(tags, "q"));
    // The same picture twice is still one picture.
    try testing.expectEqual(@as(usize, 1), countTags(tags, "imeta"));
    // The mention. The quoted nevent carries no author, so it adds no second p:
    // slot 4 is a notification target and a guess there tells the wrong person.
    try testing.expectEqual(@as(usize, 1), countTags(tags, "p"));

    const q = tagNamed(tags, "q") orelse return error.NoQuoteTag;
    try testing.expectEqual(@as(usize, 64), q[1].len);
}
test "an ordinary github link is left alone" {
    // The rewrite is one host and one path shape. A repo link is not a raw
    // link, and editing what somebody typed is only defensible where the two
    // forms are the identical file.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "the source is at https://github.com/zig-nostr/plaza");
    // No image extension, so no imeta, and nothing here to rewrite either.
    try testing.expectEqual(@as(usize, 0), countTags(tags, "imeta"));
}

test "a nostr mention inside a URL path is not a mention" {
    // The prefixed form had no boundary check, so a path segment that happens
    // to read `nostr:npub1…` parsed as a mention. Harmless while nothing was
    // tagged; a notification to a stranger now that mentions become p tags.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x5b;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    const body = try std.fmt.allocPrint(gpa, "see https://example.com/nostr:{s} for details", .{npub});

    const tags = main.contentTagsForTest(gpa, body);
    try testing.expectEqual(@as(usize, 0), countTags(tags, "p"));
}
test "a tag copy that could not complete reads as no base, not as an empty one" {
    // The splice base for every replaceable write comes through `dupeTags`, and
    // the writes decide how much to keep by counting what is in it. An empty
    // slice is a true answer for a record with no tags and a destructive one for
    // a copy that ran short: the follow list's shrink guard compares against
    // this same slice, so zero to one reads as growth and passes.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const tags = [_]nostr.event.Tag{
        &.{ "p", "aa" ** 32 },
        &.{ "p", "bb" ** 32 },
    };

    // Enough memory: the copy is whole and every field survives.
    const ok = main.dupeTagsForTest(a.allocator(), &tags) orelse return error.CopyRefusedWithMemoryAvailable;
    try testing.expectEqual(@as(usize, 2), ok.len);
    try testing.expectEqualStrings("p", ok[0][0]);

    // Not enough: null, so the caller takes its store-miss path. Anything that
    // returned a short or empty slice here would be reported as a real base.
    var failing = testing.FailingAllocator.init(a.allocator(), .{ .fail_index = 1 });
    try testing.expect(main.dupeTagsForTest(failing.allocator(), &tags) == null);
}
test "a tag copy that fails part way frees what it had copied" {
    // Every allocation is failed in turn under the leak-checking allocator, so a
    // partial copy left behind fails the test. The copy is freed when it works.
    const gpa = testing.allocator;
    const tags = [_]nostr.event.Tag{
        &.{ "i", "github:someone", "a-proof-url" },
        &.{ "p", "aa" ** 32 },
        &.{"t"},
    };
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const copy = main.dupeTagsForTest(failing.allocator(), &tags) orelse continue;
        for (copy) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        gpa.free(copy);
        break;
    }
    // Ten allocations make a whole copy (one slice, three tags, six fields),
    // so the loop refused at least that many times before one went through.
    try testing.expect(fail_index >= 10 and fail_index < 32);
}
test "the content-warning tag is read with a reason, without one, and when malformed" {
    // The TAG is the warning, not the sentence in it. A bare tag, an empty reason
    // and a reason with a control character in it all ask for the note to be
    // covered, and only the first of those has no words to show.
    const none = [_]nostr.event.Tag{&.{ "t", "nostr" }};
    try testing.expect(main.contentWarningIn(&none) == null);

    const with_reason = [_]nostr.event.Tag{&.{ "content-warning", "  spoilers  " }};
    try testing.expectEqualStrings("spoilers", main.contentWarningIn(&with_reason).?);

    const bare = [_]nostr.event.Tag{&.{"content-warning"}};
    try testing.expectEqualStrings("", main.contentWarningIn(&bare).?);

    const empty = [_]nostr.event.Tag{&.{ "content-warning", "" }};
    try testing.expectEqualStrings("", main.contentWarningIn(&empty).?);

    const control = [_]nostr.event.Tag{&.{ "content-warning", "bad\x00reason" }};
    try testing.expectEqualStrings("", main.contentWarningIn(&control).?);

    // Clipped on a character boundary: 60 three-byte characters cannot be cut
    // through the middle of one.
    const long = [_]nostr.event.Tag{&.{ "content-warning", "日本語" ** 20 }};
    const clipped = main.contentWarningIn(&long).?;
    try testing.expect(clipped.len < ("日本語" ** 20).len);
    try testing.expect(std.unicode.utf8ValidateSlice(clipped));
}
test "a content warning is never published without its tag when the tag cannot be built" {
    const base = [_]nostr.event.Tag{&.{ "t", "nostr" }};
    // Every allocation point the tag needs, failing in turn: the answer is
    // "refuse", never the original tags.
    var fail_at: usize = 0;
    while (fail_at < 3) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        try testing.expect(main.withContentWarning(failing.allocator(), &base, "spoilers") == null);
    }
    // No warning asked for: the tags come back untouched, and that is not a failure.
    var never = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const same = main.withContentWarning(never.allocator(), &base, null) orelse return error.Refused;
    try testing.expectEqual(@as(usize, 1), same.len);
    // And when it can be built, it is appended.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = main.withContentWarning(arena_state.allocator(), &base, "spoilers") orelse return error.Refused;
    try testing.expectEqual(@as(usize, 2), built.len);
    try testing.expectEqualStrings("content-warning", built[1][0]);
    try testing.expectEqualStrings("spoilers", built[1][1]);
}
test "a quoted note and a mentioned person carry the hints Plaza knows" {
    freshHints();
    defer freshHints();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x59} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quote.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    _ = try main.plazaIngestForTest(gpa, try relayListFor(gpa, signer, kp, &.{hint_b}));

    const quoted_id = [_]u8{0x61} ** 32;
    main.recordSeenOnForTest(quoted_id, hint_a);

    // A pointer that names no relay: the one Plaza saw it on fills the slot, and
    // the author the pointer carries keeps its place after it.
    {
        const nevent = try nostr.nip19.encodeNevent(gpa, quoted_id, &.{}, kp.public_key, 1);
        const body = try std.fmt.allocPrint(gpa, "look at nostr:{s}", .{nevent});
        const tags = main.contentTagsForTest(gpa, body);
        const q = tagNamed(tags, "q") orelse return error.NoQuoteTag;
        try testing.expectEqual(@as(usize, 4), q.len);
        try testing.expectEqualStrings(hint_a, q[2]);
        var author_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&author_hex, "{x}", .{kp.public_key});
        try testing.expectEqualStrings(&author_hex, q[3]);
        // The quoted author is mentioned, and their `p` tag says where they publish.
        const p = tagNamed(tags, "p") orelse return error.NoMention;
        try testing.expectEqual(@as(usize, 3), p.len);
        try testing.expectEqualStrings(hint_b, p[2]);
    }

    // A pointer that names a relay of its own: that choice wins, as it does in
    // Jumble's `extractQuoteTags`.
    {
        const nevent = try nostr.nip19.encodeNevent(gpa, quoted_id, &.{hint_c}, null, 1);
        const body = try std.fmt.allocPrint(gpa, "nostr:{s}", .{nevent});
        const q = tagNamed(main.contentTagsForTest(gpa, body), "q") orelse return error.NoQuoteTag;
        try testing.expectEqual(@as(usize, 3), q.len);
        try testing.expectEqualStrings(hint_c, q[2]);
    }

    // A pointer naming a relay nobody could reach is not copied into a tag.
    {
        const nevent = try nostr.nip19.encodeNevent(gpa, quoted_id, &.{"wss://192.168.1.2"}, null, 1);
        const body = try std.fmt.allocPrint(gpa, "nostr:{s}", .{nevent});
        const q = tagNamed(main.contentTagsForTest(gpa, body), "q") orelse return error.NoQuoteTag;
        try testing.expectEqualStrings(hint_a, q[2]);
    }

    // Nothing known and no author: the tag stops at the id, as before.
    {
        const other = [_]u8{0x62} ** 32;
        const nevent = try nostr.nip19.encodeNevent(gpa, other, &.{}, null, 1);
        const body = try std.fmt.allocPrint(gpa, "nostr:{s}", .{nevent});
        const q = tagNamed(main.contentTagsForTest(gpa, body), "q") orelse return error.NoQuoteTag;
        try testing.expectEqual(@as(usize, 2), q.len);
    }

    // A plain mention of somebody whose list is known carries their relay.
    {
        const npub = try nostr.nip19.encodeNpub(gpa, kp.public_key);
        const body = try std.fmt.allocPrint(gpa, "thanks nostr:{s}", .{npub});
        const p = tagNamed(main.contentTagsForTest(gpa, body), "p") orelse return error.NoMention;
        try testing.expectEqual(@as(usize, 3), p.len);
        try testing.expectEqualStrings(hint_b, p[2]);
    }
}

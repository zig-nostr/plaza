//! Tests of navigation.zig. Moving between screens, and the fetches each screen starts.

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
const bookmarkFixture = harness.bookmarkFixture;
const countPressesOf = harness.countPressesOf;
const articleStore = harness.articleStore;
const bareRoot = harness.bareRoot;
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const isNotesFilter = harness.isNotesFilter;
const pressMsgByLabel = harness.pressMsgByLabel;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

test "a reply held under its pause stops when the reader leaves, and is kept" {
    main.setIdentityForTest([_]u8{0x81} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);
    const a = bareRoot(0xa1);
    const b = bareRoot(0xb1);

    // The second thread has a reply of its own kept from an earlier visit.
    main.enterThreadForTest(&model, b);
    model.reply_buffer.set("kept for b, not finished");
    main.closeThreadForTest(&model);

    // A reply pressed in the first thread is held, and the reader walks into the
    // second before the pause runs out. Left armed, the pause would fire there,
    // on the box the second thread just put its own unfinished reply back into.
    main.enterThreadForTest(&model, a);
    model.reply_buffer.set("held for a");
    main.holdReplyForTest(1_800_000_000);
    main.enterThreadForTest(&model, b);
    try testing.expect(!main.replyHeldForTest());
    try testing.expectEqualStrings("kept for b, not finished", model.reply_draft());
    try testing.expectEqualStrings("Reply not sent. It is kept in its thread.", model.toast_text());

    // And what was held is not lost: it is the first thread's kept reply.
    main.closeThreadForTest(&model);
    try testing.expectEqualStrings("held for a", model.reply_draft());
}

test "when the kept replies run out, the oldest one makes room" {
    main.setIdentityForTest([_]u8{0x82} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);

    // Eight threads, each left with a reply in it.
    for (0..8) |i| {
        const root = bareRoot(@intCast(0x10 + i));
        main.enterThreadForTest(&model, root);
        model.reply_buffer.set("a reply");
        main.goHomeForTest(&model);
    }
    // The first is visited again and left with its reply, so it is now the
    // NEWEST kept, in the slot its return freed.
    main.enterThreadForTest(&model, bareRoot(0x10));
    try testing.expectEqualStrings("a reply", model.reply_draft());
    model.reply_buffer.set("a reply, rewritten");
    main.goHomeForTest(&model);

    // A ninth needs a slot. It takes the second thread's, the one kept longest
    // ago, never the one kept a moment ago.
    main.enterThreadForTest(&model, bareRoot(0x30));
    model.reply_buffer.set("the ninth");
    main.goHomeForTest(&model);
    try testing.expect(main.keptReplyDraftForTest(bareRoot(0x11).event_id) == null);
    try testing.expectEqualStrings("a reply, rewritten", main.keptReplyDraftForTest(bareRoot(0x10).event_id).?);
    try testing.expectEqualStrings("the ninth", main.keptReplyDraftForTest(bareRoot(0x30).event_id).?);
}

test "quoting from inside a thread leaves the thread and its way back alone" {
    main.setIdentityForTest([_]u8{0x85} ** 32);
    defer main.clearIdentityForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x86} ** 32);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);
    model.notes[0] = main.noteFrom(try signedNote(arena, signer, kp, 1_800_000_000, "the first"), 1_800_000_000);
    model.notes[1] = main.noteFrom(try signedNote(arena, signer, kp, 1_800_000_001, "the second"), 1_800_000_000);
    model.notes_len = 2;
    const first = model.notes[0].id;
    const second = model.notes[1].id;

    // Two threads deep, with a reply typed in the open one.
    main.update(&model, Msg{ .open_thread = first }, &fx);
    main.update(&model, Msg{ .open_thread = second }, &fx);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
    model.reply_buffer.set("half a reply");

    // Quote the open thread's own note. The composer opens over the thread.
    main.update(&model, Msg{ .quote_note = second }, &fx);
    try testing.expect(model.composing);
    try testing.expect(std.mem.startsWith(u8, model.draft_buffer.text(), "nostr:nevent1"));
    try testing.expectEqual(second, model.viewing_thread);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
    try testing.expectEqualStrings("half a reply", model.reply_draft());

    // Closing the composer is back in the thread, and Back is one level up.
    model.composing = false;
    main.closeThreadForTest(&model);
    try testing.expectEqual(first, model.viewing_thread);
}
test "each thread level keeps its own page and its own held section" {
    // One shared page and one shared flag meant walking into a reply and back
    // collapsed the thread underneath, which is the opposite of why the stack
    // stays mounted at all.
    var model = main.initialModel();
    model.stage = .ready;

    var first = threadNote(0xA1, 100, 0);
    first.id = 11;
    var second = threadNote(0xB1, 200, 0xA1);
    second.id = 22;
    main.enterThreadForTest(&model, first);
    try testing.expectEqual(@as(usize, 0), model.currentLevel());

    // The reader pages through the first level and opens its held tier.
    model.thread_page[0] = 3;
    model.thread_outside_open[0] = true;

    main.enterThreadForTest(&model, second);
    try testing.expectEqual(@as(usize, 1), model.currentLevel());
    // The new level starts fresh, and the one underneath is untouched.
    try testing.expectEqual(@as(usize, 1), model.thread_page[1]);
    try testing.expect(!model.thread_outside_open[1]);
    try testing.expectEqual(@as(usize, 3), model.thread_page[0]);
    try testing.expect(model.thread_outside_open[0]);

    model.thread_page[1] = 2;
    model.thread_outside_open[1] = true;
    main.closeThreadForTest(&model);
    // Back on the first level, exactly as it was left.
    try testing.expectEqual(@as(usize, 0), model.currentLevel());
    try testing.expectEqual(@as(usize, 3), model.thread_page[0]);
    try testing.expect(model.thread_outside_open[0]);
    // And the level just left is reset for its next visit.
    try testing.expectEqual(@as(usize, 1), model.thread_page[1]);
    try testing.expect(!model.thread_outside_open[1]);
}
test "a profile is a level of the back stack, not a layer over it" {
    // The SDK tracks at most 8 virtual windows per build, an OCCLUDED level
    // still registers one, and Plaza is already at the cap: feed + 6 stacked +
    // current. A profile that layered on top of a full thread stack would be a
    // ninth window, silently dropped in a release build. Sharing the depth
    // budget is what makes that impossible rather than merely unlikely.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5a);

    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(?[32]u8, who), model.viewing_profile);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // Opening a note from a profile pushes the profile, so Back returns to it.
    var note = threadNote(0xAB, 100, 0);
    note.id = 77;
    main.enterThreadForTest(&model, note);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
    try testing.expect(model.thread_stack[0].isProfile());
    try testing.expectEqual(@as(i64, 77), model.viewing_thread);
    try testing.expect(model.viewing_profile == null);

    // Back lands on the person, not the feed.
    main.closeThreadForTest(&model);
    try testing.expectEqual(@as(?[32]u8, who), model.viewing_profile);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // And Back again lands on the feed.
    main.closeThreadForTest(&model);
    try testing.expect(model.viewing_profile == null);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
}
test "opening the person already open does not stack a second copy of them" {
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x72);

    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);
    // Pressing a face on their own page is the reachable way to do this.
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // A different person still pushes.
    var other: [32]u8 = undefined;
    @memset(&other, 0x73);
    main.enterProfileForTest(&model, other);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
}
test "a hashtag asks for the lowercase t tag, kind 1, and nothing else" {
    var model = main.initialModel();
    model.stage = .ready;
    // The page is reached from text the reader typed or pasted, and a relay
    // matches `t` values exactly. Published tags are lowercase (NIP-24), so
    // `#PlanetDyne` asked for as written finds nothing at all.
    main.openTopicForTest(&model, "PlanetDyne");
    try testing.expectEqualStrings("planetdyne", model.viewingTopic() orelse return error.NoTopic);

    const req = try main.topicReqForTest(testing.allocator, "planetdyne");
    defer testing.allocator.free(req);
    try testing.expect(std.mem.startsWith(u8, req, "[\"REQ\",\"plaza-topic\",{"));
    try testing.expect(std.mem.indexOf(u8, req, "\"kinds\":[1]") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"#t\":[\"planetdyne\"]") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"limit\":") != null);
    // No author scope: a tag belongs to nobody.
    try testing.expect(std.mem.indexOf(u8, req, "\"authors\"") == null);
}

test "a hashtag nobody has used says so instead of looking for ever" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.resetProfilesForTest();
    // The finished generation below is a made-up one far ahead of the real
    // counter, so put it back for whatever runs next.
    defer main.finishLevelFetchForTest(0);

    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "unusedtag");
    // A fetch that has not come back. With no relays in a test the real one is
    // marked finished on the spot, which would hide the wait.
    model.thread_seq += 1000;
    const opened = model.thread_open_at;

    // Waiting, in words that are about a tag. "What they have written" is a
    // person's sentence, and it was the one shown here.
    main.refreshOpenLevelForTest(&model, opened + 1);
    try testing.expect(model.thread_loading);
    const waiting = try buildTree(arena, &model);
    try testing.expect(findAnyText(waiting.root, "Looking for notes with this tag…") != null);
    try testing.expect(findAnyTextContainingText(waiting.root, "what they have written") == null);
    try testing.expect(findAnyText(waiting.root, "No notes with this tag yet.") == null);

    // Every relay answered with nothing.
    main.finishLevelFetchForTest(model.thread_seq);
    main.refreshOpenLevelForTest(&model, opened + 2);
    try testing.expect(!model.thread_loading);
    const answered = try buildTree(arena, &model);
    try testing.expect(findAnyText(answered.root, "No notes with this tag yet.") != null);
    try testing.expect(findAnyText(answered.root, "Looking for notes with this tag…") == null);

    // Or a relay never sent its EOSE, which is the case that left the line up
    // for ever: the wait ends on its own.
    main.openTopicForTest(&model, "unusedtoo");
    model.thread_seq += 1000;
    const again = model.thread_open_at;
    main.refreshOpenLevelForTest(&model, again + 1);
    try testing.expect(model.thread_loading);
    main.refreshOpenLevelForTest(&model, again + 60);
    try testing.expect(!model.thread_loading);
    const timed_out = try buildTree(arena, &model);
    try testing.expect(findAnyText(timed_out.root, "No notes with this tag yet.") != null);
}

test "a hashtag page can be left, and the mark goes home from every page" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();
    var fx: main.EffectsForTest = undefined;

    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "planetdyne");
    try testing.expect(model.levelOpen());

    // A way back, the same control a thread and a person's page carry.
    const topic_tree = try buildTree(arena, &model);
    const back = pressMsgByLabel(topic_tree, "Back") orelse return error.TopicHasNoBack;
    switch (back) {
        .close_thread => {},
        else => return error.BackGoesSomewhereElse,
    }
    main.update(&model, back, &fx);
    try testing.expect(!model.levelOpen());
    try testing.expect(model.viewingTopic() == null);

    // The mark is on the page, and it leaves it. It used to clear a person and a
    // thread and nothing else, so the page stayed exactly where it was.
    main.openTopicForTest(&model, "planetdyne");
    const home = pressMsgByLabel(try buildTree(arena, &model), "Home") orelse return error.NoMark;
    main.update(&model, home, &fx);
    try testing.expect(!model.levelOpen());
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // Two pages deep, which is the case a reader reaches: a hashtag opened from
    // a person's page.
    main.enterProfileForTest(&model, [_]u8{0x2B} ** 32);
    main.openTopicForTest(&model, "zig");
    try testing.expect(model.thread_stack_len > 0);
    main.update(&model, .go_home, &fx);
    try testing.expect(!model.levelOpen());
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // The bookmark list is the other page with the same hole.
    main.openBookmarksForTest(&model);
    const bm_tree = try buildTree(arena, &model);
    try testing.expect(pressMsgByLabel(bm_tree, "Back") != null);
    main.update(&model, .go_home, &fx);
    try testing.expect(!model.levelOpen());

    // Signing out leaves every kind of level too. A topic left set would be
    // the page the next account lands on.
    main.openTopicForTest(&model, "planetdyne");
    main.performLogoutForTest(&model, &fx);
    try testing.expect(model.viewingTopic() == null);
    try testing.expect(!model.levelOpen());
    main.openBookmarksForTest(&model);
    main.performLogoutForTest(&model, &fx);
    try testing.expect(!model.levelOpen());
}

test "a note pressed on a hashtag page opens, and Back returns to the page" {
    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "planetdyne");

    // The topic was set aside on the stack but also left set, and a topic
    // outranks a thread when the view is built: the press opened nothing.
    var root = main.Note{};
    root.id = 0xBB;
    main.enterThreadForTest(&model, root);
    try testing.expect(model.viewingTopic() == null);
    try testing.expectEqual(@as(i64, 0xBB), model.viewing_thread);

    main.closeThreadForTest(&model);
    try testing.expectEqualStrings("planetdyne", model.viewingTopic() orelse return error.TopicLost);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // The same from a person's face on a note there.
    main.enterProfileForTest(&model, [_]u8{0x2C} ** 32);
    try testing.expect(model.viewingTopic() == null);
    try testing.expect(model.viewing_profile != null);
    main.closeThreadForTest(&model);
    try testing.expectEqualStrings("planetdyne", model.viewingTopic() orelse return error.TopicLost);
    main.closeThreadForTest(&model);
    try testing.expect(!model.levelOpen());
}

test "a note on a hashtag page or the bookmark list opens and copies from its own row" {
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/levelpress.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);

    // A tagged note that is on neither the feed nor any thread: the page's
    // own rows are the only place it lives.
    const author = try signer.keyPairFromSecretKey([_]u8{0x49} ** 32);
    const tag = [_]nostr.event.Tag{&.{ "t", "planetdyne" }};
    const ev = try nostr.event.create(arena, signer, author, 1_800_000_031, 1, &tag, "only on the tag page", null);
    _ = try main.plazaIngestForTest(arena, ev);

    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    try testing.expectEqual(@as(usize, 0), model.notes_len);

    // The hashtag page, opened the way a press on `#planetdyne` opens it.
    main.update(&model, Msg{ .open_url = "t\x00planetdyne" }, &fx);
    try testing.expectEqual(@as(usize, 1), model.thread_notes_len);
    const id = model.thread_notes[0].id;
    const topic_tree = try buildTree(arena, &model);
    try testing.expect(countPressesOf(topic_tree, topic_tree.root, Msg{ .open_thread = id }) > 0);
    main.update(&model, Msg{ .copy_nevent = id }, &fx);
    try testing.expectEqualStrings("Address copied", model.toast_text());
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    main.closeThreadForTest(&model);
    main.closeThreadForTest(&model);
    try testing.expect(!model.levelOpen());

    // The bookmark list, holding the same note.
    var id_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&id_hex, "{x}", .{ev.id});
    const saved = [_]nostr.event.Tag{&.{ "e", &id_hex }};
    _ = try bookmarkFixture(arena, &signer, &store, &saved, "");
    main.update(&model, .open_bookmarks, &fx);
    try testing.expectEqual(@as(usize, 1), model.thread_notes_len);
    try testing.expectEqual(id, model.thread_notes[0].id);
    const bm_tree = try buildTree(arena, &model);
    try testing.expect(countPressesOf(bm_tree, bm_tree.root, Msg{ .open_thread = id }) > 0);
    model.toast_len = 0;
    main.update(&model, Msg{ .copy_nevent = id }, &fx);
    try testing.expectEqualStrings("Address copied", model.toast_text());
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
}
test "every engagement query asks the same bounded question" {
    // Three screens ask for replies, reposts, likes and zaps over a list of note
    // ids. They were three copies and they drifted: the feed's, which is the one
    // re-issued on every reconnect, ended up with no cap at all, so the relay
    // chose how much of four kinds across 128 note ids to send back.
    const values = [_][]const u8{ "a" ** 64, "b" ** 64 };
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = &values }};
    const f = main.engagementFilter(&tags);

    try testing.expect(f.limit != null);
    try testing.expectEqual(@as(u32, 500), f.limit.?);
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 1111, 6, 7, 9735 }, f.kinds.?);
    try testing.expectEqual(@as(usize, 1), f.tags.?.len);
    try testing.expectEqual(@as(u8, 'e'), f.tags.?[0].letter);
    try testing.expectEqual(@as(usize, 2), f.tags.?[0].values.len);
}
test "reaching the bottom asks the relays for what came before" {
    // Reaching the end of the loaded feed used to raise the store's query limit
    // and nothing else. The store answers with what it has, so once the initial
    // backfill ran out the list stopped growing: no older history, no
    // end-of-feed state, no way to reach anything from before the app was
    // opened. Grepping this file for `.until` returned nothing at all, which is
    // the whole bug: no filter Plaza ever sent carried one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total = 1200;
    const authors = try arena.alloc([32]u8, total);
    for (authors, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i / 256);
        a[1] = @intCast(i % 256);
    }

    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;
    const until: i64 = 1_700_000_000;
    const filters = main.buildOlderFilters(authors, until, &buf);

    // Chunked like the live subscription, because the same relays refuse the
    // same oversized filter.
    try testing.expectEqual(@as(usize, 3), filters.len);
    var counted: usize = 0;
    for (filters) |f| {
        try testing.expect(f.authors.?.len <= 500);
        counted += f.authors.?.len;
        // The point of the whole change.
        try testing.expectEqual(until, f.until.?);
        // Notes and reposts only: profiles and relay lists are replaceable, so
        // there is no older copy to page back to and asking for one wastes the
        // budget. Checked by what the kinds ARE rather than how many, so this
        // keeps saying what it means if the list grows again.
        try testing.expect(isNotesFilter(f));
        for (f.kinds.?) |k| {
            try testing.expect(k == 1 or k == main.repost_kind or k == main.generic_repost_kind);
        }
        try testing.expectEqual(@as(u16, 1), f.kinds.?[0]);
    }
    try testing.expectEqual(total, counted);

    // An empty follow set asks nothing rather than asking about everybody.
    try testing.expectEqual(@as(usize, 0), main.buildOlderFilters(&.{}, until, &buf).len);
}
test "the end of the feed is something relays say, not something silence says" {
    // `added == 0` was the whole test, and every failure in the paging worker
    // is a `catch continue`: a dial that could not connect, a subscribe that
    // was refused. So an offline round and a round where every relay answered
    // "nothing older" produced the same zero. The latch is write-once for the
    // life of the process, so one paging attempt made on a train dead-ended the
    // feed until the app restarted.
    main.resetFeedEndForTest();
    defer main.resetFeedEndForTest();
    try testing.expect(!main.feedEndReached());

    // Nobody reached: not an end.
    try testing.expect(!main.feedEndLatchesForTest(0, 0, 0));
    // Reached, but nobody finished answering: still not an end.
    try testing.expect(!main.feedEndLatchesForTest(3, 0, 0));
    // Asked and answered, and there was nothing older. That is an end.
    try testing.expect(main.feedEndLatchesForTest(3, 3, 0));
    // Answered and there WAS something older, so plainly not the end.
    try testing.expect(!main.feedEndLatchesForTest(3, 3, 7));
    // One relay answering is enough to know, even if others never dialled.
    try testing.expect(main.feedEndLatchesForTest(3, 1, 0));
}

test "changing who the feed asks about un-ends it" {
    // The end of history is an answer about a question. Change the question and
    // the answer stops being about anything. The reset existed only as a test
    // helper with no callers, so the latch outlived every change to the author
    // set and to the relays.
    main.resetFeedEndForTest();
    defer main.resetFeedEndForTest();
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();

    main.setFeedEndForTest();
    try testing.expect(main.feedEndReached());
    main.forgetFollowsForTest();
    if (main.feedEndReached()) return error.TheFeedStayedEndedAfterTheFollowsChanged;

    // And a relay nobody has asked yet may hold what the feed decided was not
    // there.
    main.setFeedEndForTest();
    _ = main.addRelayForTest("wss://relay.example.test", true, false);
    if (main.feedEndReached()) return error.TheFeedStayedEndedAfterANewRelay;

    // A ROOM is the same change and was the one nobody said it about. Its feed
    // is capped, so reaching the bottom of one latched the end, and going Home
    // afterwards left the reader's own feed unable to load anything older for
    // the rest of the process.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    main.setFeedEndForTest();
    main.visitPlaceForTest([_]u8{0xb7} ** 32, "roomy", "Roomy");
    main.startPlaceFeedForTest(0);
    if (main.feedEndReached()) return error.TheFeedStayedEndedInsideARoom;

    main.setFeedEndForTest();
    main.goToOwnPlazaForTest();
    if (main.feedEndReached()) return error.TheFeedStayedEndedAfterLeavingARoom;
}
test "an address for a note you do not hold opens the thread when it arrives" {
    // The reported bug. Paste an address for a note this machine does not have
    // and Plaza said "Fetching that note", genuinely fetched it, and then did
    // nothing with it. `openEvent` read the store once and, on a miss, asked
    // for the note and raised the toast; nothing recorded that the reader was
    // trying to GO somewhere, so when it landed a second later there was nobody
    // waiting on it. The toast expired, the feed stayed the feed, and the note
    // sat on disk until the same address was pasted a second time.
    //
    // An address somebody sends you is, by definition, usually a note you do
    // not have. That is the case the field exists for.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3c} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/arrives.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetQuotesForTest();
    main.forgetEventFetchForTest();
    defer main.forgetEventFetchForTest();

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "the note behind the address");

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // Pasted and submitted, with the note nowhere on this machine.
    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNote(arena, ev.id) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);
    try testing.expectEqualStrings("Fetching that note", model.toast_text());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // A tick with the note still missing moves nobody.
    main.refreshEventFetchForTest(&model);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expect(main.eventFetchArmedForTest());

    // It lands, the way the fetch lands it.
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.refreshEventFetchForTest(&model);

    // And the reader is in the thread they asked for, without pasting again.
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));
    // The window closes on arrival: left open it reads the store every tick,
    // and would take its own navigation for a walk away.
    try testing.expect(!main.eventFetchArmedForTest());
}

test "a note that never turns up says so rather than waiting forever" {
    // The other half of the fix. Giving up silently puts the reader back where
    // the bug left them: told "Fetching that note", then left on the feed with
    // no second word, unable to tell a slow relay from a note nobody has.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/nevercomes.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetQuotesForTest();
    main.forgetEventFetchForTest();
    defer main.forgetEventFetchForTest();

    const id = [_]u8{0x4e} ** 32;
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNote(arena, id) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // The whole window, with nothing ever arriving. Still watching: a relay
    // that answers on the last tick of it is still in time.
    for (0..15) |_| main.refreshEventFetchForTest(&model);
    try testing.expect(main.eventFetchArmedForTest());
    try testing.expectEqualStrings("Fetching that note", model.toast_text());

    // One past it, and the reader is told.
    main.refreshEventFetchForTest(&model);
    try testing.expect(!main.eventFetchArmedForTest());
    try testing.expectEqualStrings("That note did not turn up.", model.toast_text());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
}
test "a note that arrives after you have walked away does not drag you back" {
    // The window has to close when the reader goes somewhere else, or a note
    // fetched fifteen seconds ago yanks them out of whatever they picked up
    // instead. This is the same rule the place fetch follows when the reader
    // steps sideways out of a linked room.
    //
    // A snapshot compared on the tick rather than a cancel written into each
    // door: `enterThread` is one way out of a feed, and opening a person,
    // walking into a room and going into Settings are three more.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3d} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/walkedoff.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetQuotesForTest();
    main.forgetEventFetchForTest();
    defer main.forgetEventFetchForTest();

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "asked for, then abandoned");

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNote(arena, ev.id) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);
    try testing.expect(main.eventFetchArmedForTest());

    // The reader gives up on it and opens somebody's profile instead.
    main.update(&model, Msg{ .open_person = kp.public_key }, &fx);
    main.refreshEventFetchForTest(&model);
    try testing.expect(!main.eventFetchArmedForTest());

    // The note lands anyway, and the reader stays where they went.
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.refreshEventFetchForTest(&model);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expect(model.viewing_profile != null);
}
test "a half written reply survives a trip to a hashtag page or an article, and an article's newer copy" {
    // The reply box is parked under its thread whenever the level changes. The
    // hashtag page and the article reader are levels too, and an article swaps
    // its root in place when a newer copy lands, which is not a level change:
    // the reply being typed under it must stay where it is.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6e} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "parked");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const note = try signedNote(arena, signer, kp, 1_800_000_000, "a note with a #zig tag");
    _ = try main.plazaIngestVerifiedForTest(arena, note, signer);
    const tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "kept-reply" }};
    const first = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The first copy.");
    const second = try signedKind(arena, signer, kp, 1_800_005_000, 30023, &tags, "The copy that was edited since.");
    _ = try main.plazaIngestVerifiedForTest(arena, first, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterThreadForTest(&model, main.noteFrom(note, 1_800_000_100));
    model.reply_buffer.set("half a thought");

    // Out to the hashtag page and Back.
    main.openTopicForTest(&model, "zig");
    try testing.expectEqualStrings("", model.reply_draft());
    main.closeThreadForTest(&model);
    try testing.expectEqualStrings("half a thought", model.reply_draft());

    // Out to an article and Back.
    main.openEventForTest(&model, first.id);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &first.id));
    try testing.expectEqualStrings("", model.reply_draft());
    main.closeThreadForTest(&model);
    try testing.expectEqualStrings("half a thought", model.reply_draft());

    // A reply typed under the article stays put when a newer copy swaps in.
    main.closeThreadForTest(&model);
    main.openAddressedArticleForTest(&model, 30023, kp.public_key, "kept-reply");
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &first.id));
    model.reply_buffer.set("about the article");
    _ = try main.plazaIngestVerifiedForTest(arena, second, signer);
    _ = try buildTree(arena, &model);
    main.refreshAddressFetchForTest(&model);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &second.id));
    try testing.expectEqualStrings("about the article", model.reply_draft());
}

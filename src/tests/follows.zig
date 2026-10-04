//! Tests of follows.zig. The contact list: who the reader follows, the home scope, follow writes, and undo.

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
const FeedFixture = harness.FeedFixture;
const bareRoot = harness.bareRoot;
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const isNotesFilter = harness.isNotesFilter;
const noteContext = harness.noteContext;
const routedHolds = harness.routedHolds;
const seedRelayLists = harness.seedRelayLists;
const threadNote = harness.threadNote;

test "a refused reply goes back to its own thread, never into the open one" {
    main.setIdentityForTest([_]u8{0x83} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);
    const a = bareRoot(0xa3);
    const b = bareRoot(0xb3);

    // The reply to the first thread went to the signer, and the reader is in the
    // second when the refusal comes back. Their box is empty, and the answer to
    // somebody else does not belong in it.
    main.enterThreadForTest(&model, b);
    const kept = try std.heap.page_allocator.dupe(u8, "an answer to a");
    main.armUndoForTest(.{ .reply = .{ .text = kept, .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expect(model.reply_empty());
    try testing.expectEqualStrings("an answer to a", main.keptReplyDraftForTest(a.event_id).?);

    // It is there when the reader goes back to the first thread.
    main.closeThreadForTest(&model);
    main.enterThreadForTest(&model, a);
    try testing.expectEqualStrings("an answer to a", model.reply_draft());

    // And a refusal never writes over a reply typed since: the first thread's
    // new reply stays exactly as it was, and the late one is kept beside it.
    defer main.forgetRefused();
    model.reply_buffer.set("typed since");
    main.closeThreadForTest(&model);
    const late = try std.heap.page_allocator.dupe(u8, "the refused one");
    main.armUndoForTest(.{ .reply = .{ .text = late, .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expectEqualStrings("typed since", main.keptReplyDraftForTest(a.event_id).?);
    try testing.expectEqualStrings("the refused one", main.refusedTextForTest(0).?);
    try testing.expectEqualStrings("Not signed. Reply kept in its thread.", model.toast_text());

    // It shows under its own thread's box, and under no other.
    main.enterThreadForTest(&model, b);
    try testing.expectEqual(@as(usize, 0), main.refusedCount(&model, .reply));
    main.closeThreadForTest(&model);
    main.enterThreadForTest(&model, a);
    try testing.expectEqualStrings("typed since", model.reply_draft());
    try testing.expectEqual(@as(usize, 1), main.refusedCount(&model, .reply));
}

test "a bunker's refused reply comes back, and the like pressed after it stays" {
    // A bunker has several signatures out at once. The undo record used to be
    // one global slot, so the like pressed while the reply was still on the
    // phone freed the reply's text and took its place. When the reply was then
    // refused, the like was the one taken back, and the reply was gone.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.resetLikesForTest();
    defer main.resetLikesForTest();
    main.setIdentityForTest([_]u8{0x84} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const a = bareRoot(0xa4);
    const liked: i64 = 0x1ced;

    const kept = try std.heap.page_allocator.dupe(u8, "an answer to a");
    main.signAndPublishWithUndoForTest(&fx, 1_800_000_000, 1, "an answer to a", .{ .reply = .{ .text = kept, .root = a.event_id } });
    main.rememberLikeForTest(liked, [_]u8{0x41} ** 32);
    main.signAndPublishWithUndoForTest(&fx, 1_800_000_001, 7, "+", .{ .like = liked });

    // The reply is refused. The like is still with the signer.
    try testing.expect(main.failPendingByContentForTest("an answer to a"));
    main.scanPendingRemoteForTest(&model, &fx);
    const back = main.keptReplyDraftForTest(a.event_id) orelse return error.ReplyWasLost;
    try testing.expectEqualStrings("an answer to a", back);
    try testing.expect(main.isLikedForTest(liked));

    // And when the like is refused too, it is the like that goes back.
    try testing.expect(main.failPendingByContentForTest("+"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expect(!main.isLikedForTest(liked));
}

test "a press one account left unsigned is never undone in the next account's session" {
    // The undo record outlived the sign-out, and a failed upload token applied
    // whatever record was armed although the token never armed one. So account
    // A's unsigned like, followed by B's upload failing, un-liked the note for
    // B; a reply would have been filed as a draft in B's session.
    main.resetLikesForTest();
    defer main.resetLikesForTest();
    defer main.clearIdentityForTest();
    defer main.clearLoggedOutLatchForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    defer main.releaseHelperSignForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const note: i64 = 0x7e57;

    // A likes a note, and signs out while Notary is still asking.
    main.setIdentityForTest([_]u8{0x8b} ** 32);
    main.rememberLikeForTest(note, [_]u8{0x21} ** 32);
    main.signAndPublishWithUndoForTest(&fx, 1_800_000_000, 7, "+", .{ .like = note });
    main.performLogoutForTest(&model, &fx);

    // B likes the same note, then an upload token of B's is refused.
    main.clearLoggedOutLatchForTest();
    main.setIdentityForTest([_]u8{0x8c} ** 32);
    main.rememberLikeForTest(note, [_]u8{0x22} ** 32);
    main.requestHelperSignForTest(&fx, 1_800_000_001, 24242, "Upload a picture", false);
    main.expireHelperSignForTest();
    main.scanHelperSignForTest(&model);
    try testing.expect(main.isLikedForTest(note));
}

test "a reply waits for Notary to finish the sign it is already doing" {
    // Every other write asks `signerReady` first. A reply did not, so one sent
    // while Notary was signing something else took that request's slot, and
    // the note being signed lost the copy it would be handed back from.
    main.setIdentityForTest([_]u8{0x85} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    defer main.releaseHelperSignForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.requestHelperSignForTest(&fx, 1_800_000_000, 1, "the note being signed", true);
    main.enterThreadForTest(&model, bareRoot(0xa5));
    model.reply_buffer.set("a reply pressed meanwhile");
    main.update(&model, .reply_submit, &fx);

    try testing.expectEqualStrings("a reply pressed meanwhile", model.reply_draft());
    try testing.expectEqualStrings("Your signer is busy. Try that again in a moment.", model.toast_text());
    // The note's copy is still the one held.
    main.expireHelperSignForTest();
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("the note being signed", model.draft());
}

test "a refused reply never changes a box with something in it" {
    // It used to be joined under what the reader had typed since. The box's
    // text changed under a reader who was typing, which moved their caret to
    // the end, and when the two did not fit the clipboard was written unasked.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.setIdentityForTest([_]u8{0x84} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);
    defer main.forgetRefused();
    main.clearLastClipboardForTest();
    const a = bareRoot(0xa4);

    main.enterThreadForTest(&model, a);
    model.reply_buffer.set("started again");
    main.armUndoForTest(.{ .reply = .{ .text = try std.heap.page_allocator.dupe(u8, "the first try"), .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expectEqualStrings("started again", model.reply_draft());
    try testing.expectEqualStrings("the first try", main.refusedTextForTest(0).?);
    try testing.expectEqualStrings("Not signed. Reply kept under the box.", model.toast_text());
    try testing.expectEqualStrings("", main.lastClipboardForTest());

    // The line under the box says so, and Copy is the one way to the clipboard.
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findAnyTextContainingText(tree.root, "1 reply was not signed") != null);
    try testing.expect(harness.pressableByLabel(tree, tree.root, "Copy the replies that were not signed"));
    main.update(&model, .{ .refused_copy = .reply }, &fx);
    try testing.expectEqualStrings("the first try", main.lastClipboardForTest());
    try testing.expectEqual(@as(usize, 0), main.refusedCount(&model, .reply));
    try testing.expectEqualStrings("started again", model.reply_draft());
    const after = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findAnyTextContainingText(after.root, "was not signed") == null);

    // An empty box takes it back, as it was.
    model.reply_buffer.clear();
    main.armUndoForTest(.{ .reply = .{ .text = try std.heap.page_allocator.dupe(u8, "the second try"), .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expectEqualStrings("the second try", model.reply_draft());
    try testing.expectEqualStrings("Not signed. Your reply is back.", model.toast_text());
    try testing.expectEqual(@as(usize, 0), main.refusedCount(&model, .reply));
}

test "a reply held in its pause goes alone, and a refused one beside it is never sent" {
    main.setIdentityForTest([_]u8{0x86} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    defer main.performLogoutForTest(&model, &fx);
    defer main.forgetRefused();
    const a = bareRoot(0xa6);

    // The reader pressed Reply with the pause on, and while it counts an
    // earlier reply to the same thread comes back refused.
    main.enterThreadForTest(&model, a);
    model.reply_buffer.set("the held reply");
    main.holdReplyForTest(1_800_000_000);
    main.armUndoForTest(.{ .reply = .{ .text = try std.heap.page_allocator.dupe(u8, "the earlier reply"), .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expectEqualStrings("the held reply", model.reply_draft());

    // The pause runs out. What goes is what was held, and nothing else.
    main.fireReply(&model, &fx, null);
    const out = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqualStrings("the held reply", out.content);
    try testing.expectEqualStrings("the earlier reply", main.refusedTextForTest(0).?);

    // A box emptied while its reply is held is still holding: a refused reply
    // put in it would go out when the pause ran out, and nobody pressed Reply
    // on it.
    main.forgetLastPublishedForTest();
    model.reply_buffer.set("held again");
    main.holdReplyForTest(1_800_000_000);
    model.reply_buffer.clear();
    main.armUndoForTest(.{ .reply = .{ .text = try std.heap.page_allocator.dupe(u8, "refused again"), .root = a.event_id } });
    main.applyUndoForTest(&model);
    try testing.expect(model.reply_empty());
    main.fireReply(&model, &fx, null);
    try testing.expect(main.lastPublishedForTest() == null);
    try testing.expectEqualStrings("refused again", main.refusedTextForTest(1).?);
}

test "replies from outside the follow graph are held below, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One reply from a followed account, one from a stranger.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xB1, 110, 0xAA),
    };
    notes[0].pubkey = main.followSetForTest()[0];
    notes[1].pubkey = [_]u8{0x77} ** 32; // nobody followed
    // Whoever wrote the note being read: nobody followed here either, so the
    // test also pins that the split never holds a third party by accident.
    const root_author = [_]u8{0x66} ** 32;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    const split = main.splitByFollowGraphForTest(&ui, blocks, root_author);
    try testing.expectEqual(@as(usize, 1), split.inside.len);
    try testing.expectEqual(@as(usize, 1), split.outside.len);
    // Nothing is lost: every reply is in one tier or the other.
    try testing.expectEqual(blocks.len, split.inside.len + split.outside.len);
    try testing.expect(main.inFollowGraph(split.inside[0].parent.pubkey));
    try testing.expect(!main.inFollowGraph(split.outside[0].parent.pubkey));
}

test "somebody you follow is in your graph however far down the list they are" {
    // The thread split asked `followSet()` when it wanted membership. That slice
    // used to be a small cap, so a reader with three hundred follows was told
    // that follows 129 and up were strangers, in every thread, forever. And
    // `writeFollow` APPENDS, so the people they had followed most recently were
    // the ones most likely to be filed under "replies outside your graph".
    //
    // The feed reads the whole list now, so the two are the same set for any
    // list the table holds. What is still worth pinning is the shape of the old
    // failure: fill the table completely and the person added LAST is in the
    // graph, because that is the one an off-by-a-cap loses first.
    main.setIdentityForTest([_]u8{0xe1} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();

    // Heap, not stack: a full table is sixty-five kilobytes of pubkeys and a
    // Debug build does not economise on frames.
    var list_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer list_arena.deinit();
    const total = main.max_follows;
    const list = try list_arena.allocator().alloc([32]u8, total);
    for (0..total) |i| {
        @memset(&list[i], 0);
        list[i][0] = @intCast(i / 256);
        list[i][1] = @intCast(i % 256);
        list[i][31] = 0xe2;
    }
    try testing.expect(main.setFollowsForTest(list[0..total], 1_800_000_000));

    // The front of the list, which always worked even at the old cap.
    try testing.expect(main.inFollowGraph(list[0]));
    try testing.expect(main.inFollowGraph(list[127]));

    // THE PROPERTY: deep into the list, where the old cap cut. The last person
    // they followed, and one in the middle of the tail.
    try testing.expect(main.inFollowGraph(list[128]));
    try testing.expect(main.inFollowGraph(list[total / 2]));
    try testing.expect(main.inFollowGraph(list[total - 1]));

    // And a stranger is still a stranger, so this is not just "always true".
    const nobody = [_]u8{0x99} ** 32;
    try testing.expect(!main.inFollowGraph(nobody));

    // Your own replies are inside your conversation, though you do not follow
    // yourself.
    try testing.expect(main.inFollowGraph(main.activePubkeyForTest().?));
}
test "no follow is written before a relay has said who you already follow" {
    // The hard rule. "Nobody answered" and "you follow nobody" look identical
    // from here, and publishing under the second reading replaces a list of
    // hundreds with a handful of accounts this app chose.
    main.setIdentityForTest([_]u8{93} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();

    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    try testing.expect(!main.canWriteFollows());
    var someone: [32]u8 = undefined;
    @memset(&someone, 0xab);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.writeFollowForTest(&fx, someone, true));

    // Relay silence is NOT evidence for an imported key. Every relay in the pool
    // answering changes nothing, because on a cold import the pool is this app's
    // bootstrap five, chosen before the reader's own kind:10002 was read: five
    // clean answers happily coexist with eight hundred follows on relays this
    // app has never dialed.
    const me = main.activePubkeyForTest().?;
    for (0..5) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(!main.canWriteFollows());
    try testing.expect(!main.writeFollowForTest(&fx, someone, true));
    // Nor does it put the question: the reader's own relays have not been named,
    // so "every relay finished" is not true of the relays that matter.
    try testing.expect(!main.needsFreshConsentForTest(.follows));
    try testing.expect(main.followBlockedReason() != null);

    // A key MINTED here is different in kind: it provably has no history, so
    // there is nothing a write could destroy.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.followBlockedReason() == null);

    // And that fact belongs to the key, not the session.
    main.setIdentityForTest([_]u8{94} ** 32);
    main.setIdentityMintedForTest(false);
    try testing.expect(!main.canWriteFollows());
}

test "a contact list read from a relay becomes the feed, and an empty one does not" {
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        // A duplicate and a malformed entry: neither should reach the feed.
        &.{ "p", "11" ** 32 },
        &.{ "p", "not-hex" },
        &.{"p"},
    };
    var out: [128][32]u8 = undefined;
    const n = main.followsFromTagsForTest(&tags, &out);
    try testing.expectEqual(@as(usize, 2), n);

    // A list with no usable p tag is not a list: adopting it would empty the
    // reader's feed on the word of one malformed event.
    const empty_tags = [_]nostr.event.Tag{&.{ "p", "nope" }};
    try testing.expectEqual(@as(usize, 0), main.followsFromTagsForTest(&empty_tags, &out));
}

test "one reader's follows are never another's" {
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{95} ** 32);
    defer main.clearIdentityForTest();
    var list: [2][32]u8 = undefined;
    @memset(&list[0], 0x11);
    @memset(&list[1], 0x22);
    try testing.expect(main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expectEqual(@as(usize, 2), main.followSetForTest().len);

    // A different account, the same table: back to the pack until their own
    // list arrives. Showing them a stranger's follows would be showing them
    // somebody else's reading.
    main.setIdentityForTest([_]u8{96} ** 32);
    try testing.expectEqual(@as(usize, 9), main.followSetForTest().len);
}

test "a follow changes the generation, so the live subscriptions re-ask" {
    // Without this a follow shows nothing new until the socket happens to drop,
    // which reads as a broken button.
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{97} ** 32);
    defer main.clearIdentityForTest();
    const before = main.followGeneration();
    var list: [1][32]u8 = undefined;
    @memset(&list[0], 0x33);
    try testing.expect(main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expect(main.followGeneration() != before);

    // The same list again is not a change, and must not churn every relay.
    const after = main.followGeneration();
    try testing.expect(!main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expectEqual(after, main.followGeneration());
}

test "the feed's scope line stops calling your own follows hand-picked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetFollowsForTest();
    var guest = main.initialModel();
    try testing.expectEqualStrings("Starter pack", guest.scope_name());
    try testing.expect(std.mem.indexOf(u8, guest.scope_voices(arena), "hand-picked") != null);

    main.setIdentityForTest([_]u8{98} ** 32);
    defer main.clearIdentityForTest();
    var list: [3][32]u8 = undefined;
    for (&list, 0..) |*e, i| @memset(e, @intCast(i + 1));
    _ = main.setFollowsForTest(&list, 1_800_000_000);

    var mine = main.initialModel();
    try testing.expectEqualStrings("Following", mine.scope_name());
    const voices = mine.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, voices, "hand-picked") == null);
    try testing.expect(std.mem.indexOf(u8, voices, "3 accounts") != null);
}

test "a note's follow entry says which way it goes, and refuses when it cannot know" {
    // The one control that writes a contact list. Every state it can be in is
    // asserted here, because the harness cannot open a thread by pressing a row
    // (true on main too), and because the dangerous state is the one that must
    // NOT offer a press: a Follow that fires before the app has been told who
    // the reader already follows replaces that list with this app's guesses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const author = [_]u8{0x55} ** 32;
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = author;

    // A guest: the menu offers Follow, and pressing it raises the join sheet
    // rather than failing quietly.
    main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        try testing.expect(menu.label("Follow") != null);
    }

    // Signed in, but nobody has said who they follow yet: the entry says what it
    // is waiting for, and refuses the press.
    main.setIdentityForTest([_]u8{0x66} ** 32);
    main.setIdentityMintedForTest(false);
    defer main.clearIdentityForTest();
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        const waiting = menu.label("Looking for your follow list…") orelse return error.NotWaiting;
        try testing.expect(!waiting.enabled);
        try testing.expect(menu.label("Unfollow") == null);
    }

    // A key minted here has no history to lose: Follow.
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(true);
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        try testing.expect(menu.label("Follow") != null);
        try testing.expect(menu.label("Looking for your follow list…") == null);
    }

    // Already following: the way back out is offered.
    var list: [1][32]u8 = undefined;
    list[0] = author;
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        try testing.expect(menu.label("Unfollow") != null);
    }

    // Their own note: no follow control at all, in either direction.
    model.thread_root.pubkey = main.activePubkeyForTest().?;
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        const mine = menu.label("This is you") orelse return error.NotSelf;
        try testing.expect(!mine.enabled);
        try testing.expect(menu.label("Unfollow") == null);
    }
}
test "a contact list arriving from a relay becomes the feed's scope" {
    // The whole chain in one place: a signed kind:3 goes through the same
    // funnel every relay-fed event goes through, is recognised as the reader's
    // own, becomes the live follow set, and the feed's scope line stops saying
    // the app picked it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{101} ** 32);
    main.setIdentityForTest([_]u8{101} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.setIdentityMintedForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/scope.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Before: the pack, and nothing may be written.
    var before = main.initialModel();
    try testing.expectEqualStrings("Starter pack", before.scope_name());
    try testing.expect(!main.canWriteFollows());

    const tags = [_]nostr.event.Tag{
        &.{ "p", "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d" },
        &.{ "p", "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2" },
        &.{ "p", "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.ingestContactListForTest(ev);

    // After: theirs, three accounts, and a write is now allowed because a relay
    // has actually said what the list is.
    try testing.expectEqual(@as(usize, 3), main.followSetForTest().len);
    try testing.expect(main.canWriteFollows());
    var after = main.initialModel();
    try testing.expectEqualStrings("Following", after.scope_name());
    const voices = after.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, voices, "3 accounts · yours") != null);

    // And a stale list arriving later does not undo it.
    const older_tags = [_]nostr.event.Tag{&.{ "p", "aa" ** 32 }};
    const older = try nostr.event.create(arena, signer, kp, 1_700_000_000, 3, &older_tags, "", null);
    main.ingestContactListForTest(older);
    try testing.expectEqual(@as(usize, 3), main.followSetForTest().len);
}

test "the scope line states how many accounts the feed reads" {
    // This used to guard a second number. The feed read a slice of the list, so
    // the line said "128 of 300 accounts": stating only the first to somebody
    // who follows three hundred people is a lie about their own data.
    //
    // The feed reads the whole list now, so there is one number and it is the
    // right one. What is left to guard is that it is the LIST's number and not
    // the window's, and that a reader is never quietly told a smaller one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{102} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var many: [300][32]u8 = undefined;
    for (&many, 0..) |*e, i| {
        @memset(e, @intCast(i % 251));
        e[31] = @intCast(i & 0xff);
        e[30] = @intCast((i >> 8) & 0xff);
    }
    _ = main.setFollowsForTest(&many, 1_800_000_000);

    // Three hundred follows are all read, and stated as one number.
    try testing.expectEqual(@as(usize, 300), main.followSetForTest().len);
    var model = main.initialModel();
    const three_hundred = model.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, three_hundred, "300 accounts \u{b7} yours") != null);
    try testing.expect(std.mem.indexOf(u8, three_hundred, " of ") == null);

    // A single follow is not "1 accounts".
    var one: [1][32]u8 = undefined;
    @memset(&one[0], 7);
    _ = main.setFollowsForTest(&one, 1_800_000_001);
    try testing.expect(std.mem.indexOf(u8, model.scope_voices(arena), "1 account \u{b7} yours") != null);

    // A list that fits states one number, without the arithmetic.
    var few: [3][32]u8 = undefined;
    for (&few, 0..) |*e, i| @memset(e, @intCast(i + 40));
    _ = main.setFollowsForTest(&few, 1_800_000_000);
    const small = model.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, small, "3 accounts · yours") != null);
    try testing.expect(std.mem.indexOf(u8, small, " of ") == null);
}

test "following someone from the starter pack on a new key actually publishes" {
    // Reported: made a key, pressed Follow on people in the feed on the first
    // launch, and nothing happened. Both from a profile and from a note's menu,
    // because both end up here.
    //
    // The feed on that first screen IS the starter pack, so everyone pressed is
    // a pack member. Two different questions were both called "already
    // following": `isFollowedByMe` asks whether they are in a list the reader
    // OWNS, and answers no for the pack, so the button offers Follow. The write
    // scanned the same set with no ownership test, decided there was nothing to
    // do, and returned a status `sayFollowWrite` deliberately renders as
    // silence. A press that changes nothing and says nothing.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{104} ** 32);
    main.setIdentityForTest([_]u8{104} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    // A key MINTED here: it provably has no history, which is what allows a
    // first list to be written without reading one back.
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/pack.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var fx: main.EffectsForTest = undefined;
    const packed_in = main.followSetForTest()[0];

    // The button offers Follow, because the pack is not a list they own.
    try testing.expect(!main.isFollowedByMe(packed_in));
    try testing.expect(main.canWriteFollows());

    // So pressing it has to publish. This returned false: nothing written,
    // nothing said.
    try testing.expect(main.writeFollowForTest(&fx, packed_in, true));

    // And what was published is the pack, with that person in it, as the
    // reader's own list.
    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    var named = false;
    var people: usize = 0;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&packed_in});
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p")) {
            people += 1;
            if (std.ascii.eqlIgnoreCase(tag[1], &hex)) named = true;
        }
    }
    try testing.expect(named);
    // ONE person: the one pressed. The first list used to be seeded with the
    // whole starter pack, so a single press signed for nine accounts the reader
    // never chose and every face in the feed turned to Following at once.
    try testing.expectEqual(@as(usize, 1), people);

    // The list is theirs now, so the button says so, and a second press is the
    // genuine no-op the first one was pretending to be.
    try testing.expect(main.isFollowedByMe(packed_in));
}

test "a new key keeps reading the starter pack after its first follow" {
    // Reported alongside the follow bug: following one person must not cost the
    // reader everything they were reading. Their own list on day one is one
    // name, and a feed of one account is not a feed, so Home stays on the pack
    // until they say otherwise, and says which one it is on.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{105} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    var model = main.initialModel();

    // Before any follow there is only one feed, so the header is a label.
    try testing.expect(main.homeReadsPack());
    try testing.expect(!main.homeScopeSwitchable());
    try testing.expectEqualStrings("Starter pack", model.scope_name());

    // They follow one person. A key made here starts on the pack, and stays.
    main.setHomeScopeForTest(.starter_pack);
    const one = [_][32]u8{[_]u8{0xc1} ** 32};
    _ = main.setFollowsForTest(&one, 1_800_000_000);
    try testing.expect(main.homeReadsPack());
    try testing.expectEqualStrings("Starter pack", model.scope_name());
    try testing.expectEqual(main.starterPackLenForTest(), main.followSet().len);
    try testing.expect(std.mem.indexOf(u8, model.scope_voices(arena), "hand-picked") != null);

    // And now there IS somewhere to go, so the label becomes a switcher.
    try testing.expect(main.homeScopeSwitchable());

    // Choosing Following moves the feed to their own list, all one of it.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .choose_home_scope = 1 }, &fx);
    try testing.expect(!main.homeReadsPack());
    try testing.expectEqualStrings("Following", model.scope_name());
    try testing.expectEqual(@as(usize, 1), main.followSet().len);
    try testing.expect(std.mem.indexOf(u8, model.scope_voices(arena), "1 account · yours") != null);

    // And back, because a switcher that only goes one way is a trapdoor.
    main.update(&model, Msg{ .choose_home_scope = 0 }, &fx);
    try testing.expect(main.homeReadsPack());
    try testing.expectEqual(main.starterPackLenForTest(), main.followSet().len);
}

test "the feed menu says why there is one feed, and the refresh chip answers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{106} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // One feed: the menu is the word already on screen, so it also says what
    // would make there be a second.
    model.menu = .scope;
    const hint = "Follow someone to add your Following feed.";
    try testing.expect(findAnyTextContainingText((try buildTree(arena, &model)).root, hint) != null);

    // With a follow list there is a real choice and the line has nothing to add.
    const one = [_][32]u8{[_]u8{0xc2} ** 32};
    _ = main.setFollowsForTest(&one, 1_800_000_000);
    try testing.expect(findAnyTextContainingText((try buildTree(arena, &model)).root, hint) == null);

    // The refresh chip says it did something.
    try testing.expectEqual(@as(usize, 0), model.toast_len);
    main.update(&model, .jump_to_newest, &fx);
    try testing.expectEqualStrings("Feed refreshed", model.toast_buf[0..model.toast_len]);
}

test "one relay's silence never authorizes replacing a contact list" {
    // The failure this whole feature is built to avoid, and the one my first
    // gate let through. EOSE means "that is all I have", not "you have none".
    // A reader follows 2000 accounts whose list lives on two relays. A third
    // relay, which simply does not carry it, finishes first. If that unlocked
    // the write, pressing Follow would publish nine hard-coded accounts over
    // the real list, on every relay, and 1991 follows would be gone.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{103} ** 32);
    main.setIdentityForTest([_]u8{103} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    // An IMPORTED key: this app cannot know what it already follows.
    main.setIdentityMintedForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/silence.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var someone: [32]u8 = undefined;
    @memset(&someone, 0xde);
    var fx: main.EffectsForTest = undefined;

    // Every relay answers with nothing, and it still proves nothing: the pool
    // here is the app's bootstrap five, and the reader's list lives wherever
    // their own kind:10002 points, which has not been read either.
    for (0..5) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(main.contactsConfirmedAbsentForTest());
    try testing.expect(!main.canWriteFollows());
    try testing.expect(!main.writeFollowForTest(&fx, someone, true));
    // Nothing was published.
    {
        const kinds = [_]u16{3};
        const authors = [_][32]u8{kp.public_key};
        var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
        defer result.deinit();
        try testing.expectEqual(@as(usize, 0), result.events.len);
    }

    // Then the slow relay delivers the real list. Having it is the OTHER way to
    // be allowed to write, and the safe one: the write splices into it.
    var tags: [200]nostr.event.Tag = undefined;
    var hexes: [200][64]u8 = undefined;
    for (0..200) |i| {
        _ = try std.fmt.bufPrint(&hexes[i], "{x:0>2}{s}", .{ @as(u8, @intCast(i)), "ab" ** 31 });
        const pair = try arena.alloc([]const u8, 2);
        pair[0] = "p";
        pair[1] = &hexes[i];
        tags[i] = pair;
    }
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);
    main.ingestContactListForTest(real);

    try testing.expect(main.haveOwnContactListForTest());
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.writeFollowForTest(&fx, someone, true));

    // And the published list is 201 names, not 10.
    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var p_count: usize = 0;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p")) p_count += 1;
    }
    try testing.expectEqual(@as(usize, 201), p_count);
}

test "membership is right for every follow, and so is what the feed reads" {
    // These were two different numbers, and the bug that named this test was
    // asking the feed's bounded slice a membership question: a reader with three
    // hundred follows was told that follows 129 and up were strangers, and a new
    // follow is APPENDED, so the people they had followed most recently were the
    // ones most likely to be misfiled.
    //
    // The feed reads the whole list now, so for any list the table holds the two
    // questions agree. They can still diverge past the table, which is why they
    // are still asked separately here rather than collapsed into one.
    main.setIdentityForTest([_]u8{104} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var many: [400][32]u8 = undefined;
    for (&many, 0..) |*e, i| {
        @memset(e, @intCast(i % 251));
        e[31] = @intCast(i & 0xff);
        e[30] = @intCast((i >> 8) & 0xff);
    }
    _ = main.setFollowsForTest(&many, 1_800_000_000);

    // The feed reads all of them, and all of them are followed.
    try testing.expectEqual(@as(usize, 400), main.followSetForTest().len);
    try testing.expectEqual(@as(usize, 400), main.followTotal());
    // With a list of the reader's OWN, the two questions agree: everybody on it
    // is both read and followed.
    for ([_]usize{ 399, 200, 0 }) |i| {
        try testing.expect(main.isFollowedByMe(many[i]));
        try testing.expect(main.isInReadGraph(many[i]));
    }
    var stranger: [32]u8 = undefined;
    @memset(&stranger, 0xff);
    stranger[0] = 0xfe;
    try testing.expect(!main.isFollowedByMe(stranger));
    try testing.expect(!main.isInReadGraph(stranger));
}

test "an older contact list never undoes a newer one" {
    main.setIdentityForTest([_]u8{105} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    const newer_tags = [_]nostr.event.Tag{ &.{ "p", "11" ** 32 }, &.{ "p", "22" ** 32 } };
    const newer = nostr.event.Event{
        .id = [_]u8{1} ** 32,
        .pubkey = main.activePubkeyForTest().?,
        .created_at = 2_000,
        .kind = 3,
        .tags = &newer_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    var older = newer;
    const older_tags = [_]nostr.event.Tag{&.{ "p", "33" ** 32 }};
    older.created_at = 1_000;
    older.tags = &older_tags;

    main.ingestContactListForTest(newer);
    try testing.expectEqual(@as(usize, 2), main.followTotal());
    // A slower relay's older copy arrives second and is refused.
    main.ingestContactListForTest(older);
    try testing.expectEqual(@as(usize, 2), main.followTotal());
}

test "the follow list survives a restart" {
    // A local-first app that forgets who you follow every launch is not local
    // first. The store already holds the newest kind:3 from last session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{106} ** 32);
    main.setIdentityForTest([_]u8{106} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/restart.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const tags = [_]nostr.event.Tag{ &.{ "p", "44" ** 32 }, &.{ "p", "55" ** 32 }, &.{ "p", "66" ** 32 } };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    // A restart: the in-memory list is gone, the store is not.
    main.forgetFollowsForTest();
    try testing.expectEqual(@as(usize, 9), main.followSetForTest().len);
    main.loadFollowsFromStoreForTest();
    try testing.expectEqual(@as(usize, 3), main.followTotal());
    // And the app can write immediately, without waiting on any relay.
    try testing.expect(main.canWriteFollows());
}
test "a write that would drop more names than the press implies is refused" {
    // The shrink guard. No client in the ecosystem has one. A follow adds a
    // name and an unfollow removes exactly one, so a write that loses more is
    // this app's own bug, a stale base, or a rebase onto somebody else's
    // truncation. Refusing beats publishing and finding out later.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        &.{ "p", "33" ** 32 },
        &.{ "t", "not-a-person" },
        // The same person twice, which some clients emit. Removing both is
        // removing ONE person, so the count is of distinct people.
        &.{ "p", "33" ** 32 },
    };
    try testing.expectEqual(@as(usize, 3), main.countPeopleForTest(&tags));

    // Following may not lose anyone.
    try testing.expect(main.shrinkAllowedForTest(100, 101, true));
    try testing.expect(main.shrinkAllowedForTest(100, 100, true));
    try testing.expect(!main.shrinkAllowedForTest(100, 99, true));
    // Unfollowing may lose exactly one.
    try testing.expect(main.shrinkAllowedForTest(100, 99, false));
    try testing.expect(!main.shrinkAllowedForTest(100, 98, false));
    // The case this exists for: a stale base losing hundreds.
    try testing.expect(!main.shrinkAllowedForTest(2000, 9, false));
    try testing.expect(!main.shrinkAllowedForTest(2000, 10, true));
}

test "a second follow before the signer answers does not undo the first" {
    // `writeFollow` takes its base from the store, and a bunker or a Notary key
    // does not write the store until the signer answers: one to five seconds,
    // longer with an approval prompt in front of a human. Two presses inside
    // that window both read the SAME pre-press list, so the second published a
    // list without the first in it, at a newer stamp, and the first follow was
    // undone on every relay while both said "Following".
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3c} ** 32);
    main.setIdentityForTest([_]u8{0x3c} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.clearPendingFollowBaseForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/twofollows.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Their real list, with a petname on it so the splice has something to lose.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32, "wss://their-relay.example.com", "an old friend" },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);

    // The first press, as a remote signer leaves it: the list is SIGNED, and the
    // store still holds the pre-press one because the signer has not answered.
    // A local key writes the store inside the press, which is why that path
    // never had this bug and why the gap is set up rather than waited for.
    const signed_first = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32, "wss://their-relay.example.com", "an old friend" },
        &.{ "p", "a1" ** 32 },
    };
    main.setPendingFollowBaseForTest(&signed_first, "", 1_800_000_100);

    // The second press, driven for real.
    var bob: [32]u8 = undefined;
    @memset(&bob, 0xb2);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, bob, true));

    // THE PROPERTY: the published list has BOTH, plus the friend it started
    // with, petname and relay hint intact. Reading the STORE, because the local
    // signer this test uses does write it, so this is what actually went out.
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 3).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "a1" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "b2" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "an old friend") != null);
    try testing.expect(std.mem.indexOf(u8, written, "wss://their-relay.example.com") != null);
}

test "a contact list that cannot be read is not a contact list of nine" {
    // `canWriteFollows` asks the store whether this account has a kind:3, and
    // `writeFollow` then asked it AGAIN for the list itself. A transient failure
    // between the two reads turned "they have a list, splice onto it" into "they
    // have none, publish the nine names this app chose" over a real one. The
    // decision comes from the single read now, so nothing can disagree with it.
    main.setIdentityForTest([_]u8{0x3d} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.clearPendingFollowBaseForTest();
    // No store at all is the strongest form of "the read did not work".
    main.setStoreForTest(null);
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    var alice: [32]u8 = undefined;
    @memset(&alice, 0xa1);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.writeFollowForTest(&fx, alice, true));
    try testing.expect(main.pendingFollowCountForTest() == null);

    // A key minted in this app has provably never had a list, which is the one
    // case where reading nothing IS the answer.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.writeFollowForTest(&fx, alice, true));
}
test "nobody is told they follow the starter pack" {
    // The pack is what the app reads on a new account's behalf, not a list they
    // chose, and nothing is ever published to say otherwise. Telling a reader
    // they follow nine strangers offered them "Unfollow" on each, and pressing
    // it did nothing at all, because the write path correctly refuses to remove
    // somebody who is not on a list. Two questions, two answers.
    main.clearIdentityForTest();
    main.forgetFollowsForTest();
    const packed_in = main.followSetForTest()[0];
    try testing.expect(!main.isFollowedByMe(packed_in));
    try testing.expect(!main.isInReadGraph(packed_in));

    // Signed in with no list of their own: the pack IS what they read, so the
    // thread's ranking and the inbox still treat those authors as inside the
    // graph. They are still not followed, and the controls must not say so.
    main.setIdentityForTest([_]u8{0x74} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(main.isInReadGraph(packed_in));
    try testing.expect(!main.isFollowedByMe(packed_in));
}

test "the follow count counts people, not tags" {
    // Some clients emit the same person twice. This file already has a function
    // that knows that; the profile's count has to use it or it prints a number
    // nobody else shows.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        &.{ "p", "11" ** 32 },
        &.{ "t", "not-a-person" },
    };
    try testing.expectEqual(@as(usize, 2), main.countPeopleForTest(&tags));
}
test "a new account is offered Follow on the starter pack, not Unfollow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What a reader saw the moment they made a key: nine people they had never
    // chosen, each reported as followed, each offering "Unfollow", and each
    // press doing nothing. The offer is the bug; the silence when pressed was
    // the write path being right.
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{0x74} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);

    const packed_in = main.followSetForTest()[0];
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 77;
    model.notes[0].pubkey = packed_in;
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    const menu = noteContext(p) orelse return error.NoContextMenu;
    if (menu.label("Unfollow") != null) {
        std.debug.print("a starter-pack author is offered Unfollow\n", .{});
        return error.OfferedUnfollow;
    }
    const msg = menu.msgFor(p.tree, "Follow") orelse {
        std.debug.print("no way to follow a starter-pack author\n", .{});
        return error.NoFollowOffer;
    };
    switch (msg) {
        .follow_author => |press| {
            try testing.expectEqual(@as(u8, 1), press.direction);
            // And it names the author of the note the menu was opened on. The
            // label is computed from that person, so the message has to be too,
            // or the row offers to follow one person and follows another.
            try testing.expectEqualSlices(u8, &packed_in, &press.who);
        },
        else => return error.WrongMessage,
    }

    // And the feed still says whose choice the pack was, which is the other half
    // of not claiming it: the header has always been honest and the controls
    // were not.
    try testing.expect(findAnyText(p.tree.root, "Starter pack") != null);
    try testing.expect(findAnyTextContainingText(p.tree.root, "hand-picked") != null);
}
test "a long follow list is split across filters that relays accept, in one REQ" {
    // The reason the feed read a slice was the REQ, not the store: a filter
    // naming a few thousand authors is past what several relays take. strfry
    // refuses a filter whose field items exceed 65535 bytes, which is 2047 hex
    // pubkeys, and it is not the only one with a ceiling.
    //
    // So the authors are split across filters and sent together. This asserts
    // the split is lossless, because a subscription that silently drops its tail
    // is exactly the bug the cap was: those people just stop appearing, and
    // nothing anywhere says so.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One past four full chunks, so the last chunk holds a single author: the
    // off-by-one that a loop written for round numbers loses.
    const total = 2001;
    const authors = try arena.alloc([32]u8, total);
    for (authors, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i / 256);
        a[1] = @intCast(i % 256);
        a[31] = 0x5a;
    }

    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;
    const filters = main.buildFeedFilters(authors, null, null, &buf);

    // Two filters per chunk: the notes and the metadata.
    try testing.expectEqual(@as(usize, 10), filters.len);

    // Every author appears exactly once across the note filters, and no filter
    // is wider than a relay will take.
    const seen = try arena.alloc(usize, total);
    @memset(seen, 0);
    var counted: usize = 0;
    for (filters) |f| {
        const list = f.authors.?;
        try testing.expect(list.len <= 500);
        try testing.expect(list.len > 0);
        // Only count the note filters, or every author is seen twice by design.
        if (!isNotesFilter(f)) continue;
        for (list) |a| {
            const index = @as(usize, a[0]) * 256 + @as(usize, a[1]);
            seen[index] += 1;
            counted += 1;
        }
    }
    try testing.expectEqual(total, counted);
    for (seen, 0..) |n, i| {
        if (n != 1) {
            std.debug.print("\nauthor {d} appears in {d} filters, not 1\n", .{ i, n });
            return error.AuthorLostOrDuplicated;
        }
    }

    // The limit is NOT divided across chunks: each names different people, so
    // splitting it would starve whoever landed last.
    for (filters) |f| {
        if (isNotesFilter(f)) try testing.expectEqual(@as(u32, 300), f.limit.?);
    }

    // The metadata limit is derived from the chunk, never from a screen cache.
    //
    // These are replaceable records, so a relay holds at most one of each per
    // author: the right number to ask for is the number of authors times the
    // number of kinds, and anything else is a coincidence. Asserting it because
    // the number that used to be here was `profile_cap`, the size of the
    // in-memory profile table, which permitted a fraction of a chunk and left
    // the rest of those people nameless.
    for (filters) |f| {
        if (isNotesFilter(f)) continue;
        try testing.expectEqual(@as(u32, @intCast(f.authors.?.len * f.kinds.?.len)), f.limit.?);
    }

    // Nobody else's contact list. It is asked for in one place, the profile
    // card's follow counts, and the worker that opens a profile fetches that
    // person's kind:3 itself. Asking here asked every relay for the contact
    // list of every follow at dial: two thousand `p` tags is well over a
    // hundred kilobytes, so it was megabytes per relay for a question nobody
    // had asked about people whose profile may never be opened.
    for (filters) |f| {
        for (f.kinds.?) |k| try testing.expect(k != 3);
    }

    // A list that fits in one chunk is still one chunk, not a special case.
    const few = try arena.alloc([32]u8, 9);
    for (few, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i);
    }
    try testing.expectEqual(@as(usize, 2), main.buildFeedFilters(few, null, null, &buf).len);
    // And nobody at all asks nothing, rather than asking about everybody.
    try testing.expectEqual(@as(usize, 0), main.buildFeedFilters(&.{}, null, null, &buf).len);

    // The reader's OWN contact list is still asked for, on its own filter. That
    // one is not a nicety: nothing may write over a replaceable record it has
    // not read back, and the follow list is the one where getting that wrong
    // empties an account. Dropping kind:3 from the bulk filter is only safe
    // because this exists.
    const me = [_][32]u8{[_]u8{0xC3} ** 32};
    const with_me = main.buildFeedFilters(few, &me, null, &buf);
    // One filter per own kind, each limited to one record. A single filter with
    // a limit of five let a relay holding old versions of the contact list fill
    // the five with those and finish without sending the mute list.
    // The media server list rides with them, so an upload knows where to go.
    const own_kinds = [_]u16{ 0, 10002, 3, 10000, 10003, 10063 };
    try testing.expectEqual(@as(usize, 2 + own_kinds.len), with_me.len);
    for (own_kinds) |want| {
        var found = false;
        for (with_me[2..]) |own| {
            try testing.expectEqual(@as(usize, 1), own.authors.?.len);
            try testing.expectEqualSlices(u8, &me[0], &own.authors.?[0]);
            try testing.expectEqual(@as(usize, 1), own.kinds.?.len);
            try testing.expectEqual(@as(?u32, 1), own.limit);
            if (own.kinds.?[0] == want) found = true;
        }
        try testing.expect(found);
    }
}
test "the feed asks only for what it does not already hold" {
    // No feed filter ever carried a `since`, so every reconnect re-asked for
    // the full three hundred per chunk from every relay. A flapping relay was
    // handed a fifteen-hundred-event question every few seconds, and each of
    // those events cost a Schnorr verify before the store recognised it as a
    // duplicate. `subscribeInbox` has done this correctly since it was written.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const authors = try arena.alloc([32]u8, 600);
    for (authors, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i / 256);
        a[1] = @intCast(i % 256);
    }
    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;

    // A cold store asks for everything: bounding it would leave a new install
    // looking at an empty feed. This is Notedeck's rule.
    for (main.buildFeedFilters(authors, null, null, &buf)) |f| {
        try testing.expect(f.since == null);
    }

    const newest: i64 = 1_800_000_000;
    const filters = main.buildFeedFilters(authors, null, newest, &buf);
    var notes: usize = 0;
    var meta: usize = 0;
    for (filters) |f| {
        if (isNotesFilter(f)) {
            notes += 1;
            try testing.expectEqual(newest, f.since.?);
        } else {
            meta += 1;
            // Deliberately unbounded. A profile or relay list edited while the
            // app was closed carries an older created_at than the newest note
            // held, so a since here would hide the very update that matters.
            try testing.expect(f.since == null);
        }
    }
    try testing.expect(notes > 0);
    try testing.expect(meta > 0);
}
test "a changed follow set is read back in full" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "follows");
    defer f.deinit();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();

    _ = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    const before = main.feedWork();

    var other = nostr.keys.Signer.init();
    defer other.deinit();
    const other_kp = try other.keyPairFromSecretKey([_]u8{88} ** 32);
    const list = [_][32]u8{other_kp.public_key};
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    f.tick(1_800_000_100);

    try testing.expectEqual(before.full_reads + 1, main.feedWork().full_reads);
}
test "a narrowly better relay does not take a connected relay's place" {
    // The margin, where it actually bites: the budget is full, and a candidate
    // that reaches one more person than the relay already connected asks for
    // its socket. It does not get it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/flap.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // Everyone writes to exactly one relay, so no relay ever covers anybody
    // twice and each one's gain is simply how many people are on it.
    //
    // Enough big relays to fill every slot but one, counted off the budget. A
    // spare slot means no contention, the margin is never consulted, and the
    // test proves nothing while still passing.
    const budget = main.maxDiscoveredRelaysForTest;
    const big_writers = 7;
    const inc_writers = 5;
    const narrow_writers = 6;
    const wide_writers = 9;

    var specs = std.ArrayList([]const []const u8).empty;
    for (0..budget - 1) |g| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = try std.fmt.allocPrint(arena, "wss://big-{d}.example.com", .{g});
        for (0..big_writers) |_| try specs.append(arena, one);
    }
    const inc = try arena.alloc([]const u8, 1);
    inc[0] = "wss://incumbent.example.com";
    for (0..inc_writers) |_| try specs.append(arena, inc);
    const without_challenger = specs.items.len;

    const cha = try arena.alloc([]const u8, 1);
    cha[0] = "wss://challenger.example.com";
    for (0..wide_writers) |_| try specs.append(arena, cha);
    const narrowly_ahead = without_challenger + narrow_writers;

    const follows = try arena.alloc([32]u8, specs.items.len);
    try seedRelayLists(arena, signer, specs.items, follows);

    // Round one: without the challenger's people, `incumbent` earns the seat.
    _ = main.setFollowsForTest(follows[0..without_challenger], 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(routedHolds("wss://incumbent.example.com"));
    try testing.expect(!routedHolds("wss://challenger.example.com"));

    // Round two: six of the challenger's follows appear. Six beats five, but
    // not by a quarter, so the socket stays where it is.
    _ = main.setFollowsForTest(follows[0..narrowly_ahead], 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(routedHolds("wss://incumbent.example.com"));
    try testing.expect(!routedHolds("wss://challenger.example.com"));

    // And the margin is a margin, not a veto: a relay that reaches enough more
    // people does take the seat. Nine against five is well past a quarter.
    _ = main.setFollowsForTest(follows, 1_800_000_002);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(routedHolds("wss://challenger.example.com"));
    try testing.expect(!routedHolds("wss://incumbent.example.com"));
}
test "the pool's own relays still get a since" {
    // The other half, so the two cannot be conflated later: the pool HAS been
    // answering, so bounding it is what stops every reconnect re-downloading
    // the backlog. Only the note filter carries it; the metadata filter is
    // deliberately unbounded, because a profile edited while the app was closed
    // is older than the newest note held.
    var authors: [2][32]u8 = undefined;
    for (&authors, 0..) |*a, i| {
        a.* = [_]u8{0} ** 32;
        a[0] = @intCast(i + 1);
    }
    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;
    const filters = main.buildFeedFilters(&authors, null, 1_800_000_000, &buf);

    var with_since: usize = 0;
    for (filters) |f| {
        if (f.since != null) with_since += 1;
    }
    try testing.expect(with_since > 0);
}
test "a pool relay is asked about the follows who write there" {
    // The other half of the pivot: not everyone, just the people it can answer
    // for, plus the residual.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/poolroute.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // Two write to the reader's relay, three write only elsewhere and will be
    // picked up by a routed relay instead.
    const specs = [_][]const []const u8{
        &.{"wss://mine.example.com"},
        &.{"wss://mine.example.com"},
        &.{"wss://busy.example.com"},
        &.{"wss://busy.example.com"},
        &.{"wss://busy.example.com"},
    };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var pool_buf: [main.max_follows + 1][32]u8 = undefined;
    const pn = main.poolAuthorsForTest(0, &pool_buf);

    // The two who write here are named, and nobody is left over, so the pool's
    // question shrank from five to two.
    try testing.expectEqual(@as(usize, 0), main.residualCountForTest());
    try testing.expectEqual(@as(usize, 2), pn);
    for (pool_buf[0..pn]) |a| {
        try testing.expect(std.mem.eql(u8, &a, &follows[0]) or std.mem.eql(u8, &a, &follows[1]));
    }
}

test "before anything is routed, a pool relay still asks about everyone" {
    // The first dial happens before any relay list has been read back, so the
    // route table is empty. Asking about nobody then would open the app to a
    // blank feed that fills only once somebody's kind:10002 arrives.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();
    main.clearRoutesForTest();

    var follows: [4][32]u8 = undefined;
    for (&follows, 0..) |*f, i| {
        f.* = [_]u8{0} ** 32;
        f[0] = @intCast(i + 1);
    }
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    var buf: [main.max_follows + 1][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), main.poolAuthorsForTest(0, &buf));
    try testing.expectEqual(follows.len, main.poolAuthorsOrAllForTest(0, &buf));
}

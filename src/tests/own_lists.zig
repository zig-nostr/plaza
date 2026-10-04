//! Tests of own_lists.zig. Whether the reader's own lists can be written: what their relays have answered, and the consent to start one from nothing.

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
const findByLabel = harness.findByLabel;
const FreshStore = harness.FreshStore;
const app_sources = harness.app_sources;
const buildTree = harness.buildTree;
const findAnyTextContaining = harness.findAnyTextContaining;
const findByText = harness.findByText;
const noteContext = harness.noteContext;
const openFullSettings = harness.openFullSettings;
const signInNothingFound = harness.signInNothingFound;
const threadNote = harness.threadNote;

test "nothing the previous account typed survives a sign-out" {
    // Logout was thorough about the draft and said why, in a comment about the
    // previous account's private thinking being one keystroke from going out
    // under the next account's key. The reply box and the name field are the
    // same thing and were both left behind: logout performs no navigation, so
    // the next account landed inside the previous reader's open thread with
    // their unsent sentence still in the composer.
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    main.setIdentityForTest([_]u8{0xc3} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);

    model.reply_buffer.set("something I was in the middle of saying");
    model.name_buffer.set("Sepehr");
    model.draft_buffer.set("an unfinished note");
    model.viewing_thread = 0x1234;

    main.performLogoutForTest(&model, &fx);

    try testing.expectEqualStrings("", model.reply_draft());
    try testing.expectEqualStrings("", model.name_draft());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // And the one piece of evidence that authorizes building a list from
    // nothing. It is persisted to the session file, so left set it outlived the
    // account it was true about: mint here, log out, import an identity, and
    // nine starter-pack names could replace a real eight-hundred-follow list.
    try testing.expect(!main.identityMintedForTest());
}
test "the sheet refuses to save until it has read the profile it would replace" {
    // "The store has no kind:0 for me" means either that this account has no
    // profile or that nobody has answered yet, and those look identical. Saving
    // under the second reading replaces a real profile with three fields.
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(!model.profile_can_save());
    try testing.expect(findAnyTextIn(model.profile_status(), "Reading your current profile"));

    // "Absent" is a fact only for a key this app minted. For an imported one it
    // is what four bootstrap relays happened to say, and this line used to read
    // "only once every read relay has answered does absent become a fact",
    // which was never true of the code underneath it: one EOSE was enough.
    model.profile_stage = .absent;
    main.setIdentityMintedForTest(false);
    try testing.expect(!model.profile_can_save());
    main.setIdentityMintedForTest(true);
    try testing.expect(model.profile_can_save());
    main.setIdentityMintedForTest(false);

    model.profile_stage = .have;
    try testing.expect(model.profile_can_save());
    try testing.expectEqualStrings("", model.profile_status());

    model.profile_stage = .saving;
    try testing.expect(!model.profile_can_save());
}

fn findAnyTextIn(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
test "an imported key cannot publish a profile over one nobody has read" {
    // `absent` means a relay answered without sending a kind:0. On a cold import
    // the relays being asked are the four this app was born with, which may hold
    // none of the reader's, so that answer is not evidence. Saving from there
    // merged into a literal `{}`: a reader who typed a display name lost their
    // lightning address, their NIP-05, their banner and every NIP-39 proof.
    var model = main.initialModel();
    model.profile_stage = .absent;

    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    try testing.expect(!model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "still hearing from your relays") != null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "publishes your first one") == null);

    // A key minted in this app has no profile anywhere, which is the one case
    // where absent really is absent.
    main.setIdentityMintedForTest(true);
    try testing.expect(model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "publishes your first one") != null);
}
test "an imported key is never assumed to follow nobody, however quiet the relays" {
    // The hole every relay-completion gate has, and the reason this one is not
    // a relay gate at all. On a cold import the app has not read the reader's
    // kind:10002 yet, so the relays it is asking are its own bootstrap five.
    // They can all answer cleanly while the real list sits on relays this app
    // has never dialed. Silence from the wrong relays is not evidence.
    main.setIdentityForTest([_]u8{107} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    main.setIdentityMintedForTest(false);
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(!main.canWriteFollows());
    // The answers are not a licence to write, and with no relay list for this
    // reader they are not even grounds to ask: the relays that answered are the
    // app's, not theirs.
    try testing.expect(!main.needsFreshConsentForTest(.follows));
    try testing.expectEqualStrings("Looking for your follow list…", main.followBlockedReason().?);

    // A key minted here is the one case where "no list" is knowledge, not a
    // guess, because the key did not exist a minute ago.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.followBlockedReason() == null);
}

test "follow, mute and bookmark say what is wrong once the wait runs out, and can ask again" {
    // A control that stays grey with the same sentence for the whole session is
    // a dead end, whether the relays are slow, one of them is down or the account
    // simply has no list. The wait is bounded, the line says how far the read got,
    // and a retry is offered. None of it enables a write: not hearing back is not
    // being told there is nothing.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x68} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setStoreForTest(null);
    main.setIdentityMintedForTest(false);
    defer main.forgetOwnRecordAnswersForTest();
    const me = main.activePubkeyForTest().?;

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;

    // Within the wait: still reading, and nothing to press.
    try testing.expectEqual(main.OwnListsRead.reading, main.ownListsRead());
    try testing.expectEqualStrings("Looking for your follow list…", main.followBlockedReason().?);
    try testing.expectEqualStrings("Looking for your mute list…", main.muteBlockedReason().?);
    try testing.expectEqualStrings("Still fetching your bookmarks", main.bookmarkBlockedReason().?);

    // The wait ran out with relays still silent: it says so, in every place, and
    // the rows that were statements become the way to ask again.
    main.ownListsWaitedForTest(60);
    try testing.expectEqual(main.OwnListsRead.incomplete, main.ownListsRead());
    try testing.expectEqualStrings("Could not read your follow list. Try again", main.followBlockedReason().?);
    try testing.expectEqualStrings("Could not read your mute list. Try again", main.muteBlockedReason().?);
    try testing.expectEqualStrings("Could not read your bookmarks. Try again", main.bookmarkBlockedReason().?);
    try testing.expect(!main.canWriteFollows());
    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        const follow = menu.label("Could not read your follow list. Try again") orelse return error.NoRetryRow;
        try testing.expect(follow.enabled);
        const msg = menu.msgFor(try buildTree(arena, &model), "Could not read your follow list. Try again") orelse return error.NoRetryMsg;
        try testing.expect(msg == .retry_own_lists);
        const mark = menu.label("Could not read your bookmarks. Try again") orelse return error.NoBookmarkRetry;
        try testing.expect(mark.enabled);
        // Private bookmarks have no way to ask again of their own and stay off.
        const private = menu.label("Bookmark privately") orelse return error.NoPrivateRow;
        try testing.expect(!private.enabled);
    }

    // The profile page: Follow and Mute stay off, and the line under the counts
    // says how many relays finished and offers the retry.
    var who: [32]u8 = undefined;
    @memset(&who, 0x5e);
    model.viewing_thread = 0;
    model.viewing_profile = who;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "0 of 4 relays finished answering"));
        try testing.expect(findAnyTextContaining(tree.root, "could not finish reading your follow and mute lists"));
        try testing.expect(findByText(tree.root, .button, "Try again") != null);
    }

    // Asking again restarts the wait and drops the answers already counted.
    for (0..2) |i| main.noteContactsAnsweredByForTest(i, me);
    const gen = main.followGeneration();
    main.retryOwnListsReadForTest();
    try testing.expect(main.followGeneration() != gen);
    try testing.expectEqual(main.OwnListsRead.reading, main.ownListsRead());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "Still reading your own follow and mute lists"));
        try testing.expect(findByText(tree.root, .button, "Try again") == null);
    }

    // Every relay finished and none had a list. Not yet "none found": nothing
    // has said where this reader's lists are kept, and the pool is the app's
    // own bootstrap relays.
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expectEqual(main.OwnListsRead.reading, main.ownListsRead());
    main.ownListsWaitedForTest(60);
    try testing.expectEqual(main.OwnListsRead.incomplete, main.ownListsRead());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "has not found your relay list"));
        try testing.expect(findByText(tree.root, .button, "Try again") != null);
    }
    // Their relay list arrives and the relays they write to are the ones that
    // finished: said plainly, still no write.
    try ownRelayListIsThePool(0x68, &.{});
    try testing.expectEqual(main.OwnListsRead.none_found, main.ownListsRead());
    // The controls are live and the press asks first; none of it can write.
    try testing.expect(main.followBlockedReason() == null);
    try testing.expect(main.muteBlockedReason() == null);
    try testing.expect(main.bookmarkBlockedReason() == null);
    try testing.expect(main.needsFreshConsentForTest(.follows));
    try testing.expect(main.needsFreshConsentForTest(.mutes));
    try testing.expect(main.needsFreshConsentForTest(.bookmarks));
    try testing.expect(!main.canWriteFollows());
}

test "the press that asks to retry reaches the relays and tells the reader" {
    main.setIdentityForTest([_]u8{0x69} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    defer main.forgetOwnRecordAnswersForTest();
    var model = main.initialModel();
    model.stage = .ready;
    main.ownListsWaitedForTest(60);
    try testing.expectEqual(main.OwnListsRead.incomplete, main.ownListsRead());
    const gen = main.followGeneration();
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .retry_own_lists, &fx);
    try testing.expect(main.followGeneration() != gen);
    try testing.expectEqual(main.OwnListsRead.reading, main.ownListsRead());
    try testing.expect(model.toast_until != 0);
}

test "the profile sheet offers to ask again whenever it cannot save for want of a read" {
    var model = main.initialModel();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    model.profile_stage = .unread;
    try testing.expect(model.profile_can_retry());
    // A finished read that found nothing, for a key that was not made here: the
    // profile may have been published since, and the sheet cannot say otherwise.
    model.profile_stage = .absent;
    try testing.expect(model.profile_can_retry());
    try testing.expect(!model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "still hearing from your relays") != null);
    model.profile_stage = .have;
    try testing.expect(!model.profile_can_retry());
    // Made here, absent is a fact: nothing to ask again.
    main.setIdentityMintedForTest(true);
    model.profile_stage = .absent;
    try testing.expect(!model.profile_can_retry());
}
/// Gives the signed-in test account (secret `secret_byte`) a kind:10002 whose
/// write relays are the pool's, plus `extra`, so that every relay finishing can
/// mean every relay that could hold its lists.
pub fn ownRelayListIsThePool(secret_byte: u8, extra: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{secret_byte} ** 32);
    var tags = std.ArrayList(nostr.event.Tag).empty;
    for (0..8) |i| {
        if (main.relayAt(i) == null) continue;
        try tags.append(arena, try arena.dupe([]const u8, &.{ "r", main.relayUrlAt(i) }));
    }
    for (extra) |url| try tags.append(arena, try arena.dupe([]const u8, &.{ "r", url, "write" }));
    const ev = try nostr.event.create(arena, signer, kp, 1_700_000_000, 10002, tags.items, "", null);
    main.noteOwnOutboxForTest(ev);
}
test "the yes is only taken while every relay still has finished without the list" {
    // The question can sit on screen while the situation moves: a retry, a relay
    // added, an identity switch. A yes that no longer describes anything is not
    // taken, and it writes nothing.
    var fs: FreshStore = undefined;
    try fs.open("staleyes");
    defer fs.close();
    const me = signInNothingFound(0x6b);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const bob = [_]u8{0xb4} ** 32;
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask != null);

    // The reader (or the app) asks the relays again, and they have not answered.
    main.retryOwnListsReadForTest();
    main.update(&model, .fresh_list_confirm, &fx);
    try testing.expect(model.fresh_ask == null);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 3) == null);
    try testing.expect(!main.canWriteFollows());
    try testing.expect(model.toast_until != 0);

    // And the refusal in the other direction: with only some relays done there is
    // nothing to ask about, so the press explains instead of asking.
    for (0..2) |i| main.noteContactsAnsweredByForTest(i, me);
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask == null);
    try testing.expect(!main.confirmStartFreshForTest(.follows));

    // A different account inherits no yes.
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(main.confirmStartFreshForTest(.follows));
    try testing.expect(main.canWriteFollows());
    main.setIdentityForTest([_]u8{0x6c} ** 32);
    main.forgetFollowsForTest();
    try testing.expect(!main.canWriteFollows());
}

test "a list that is held is never asked about" {
    // Asking is for a list that is not there. One in the store is spliced onto, as
    // it always was, with no question.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("heldlist");
    defer fs.close();
    const me = signInNothingFound(0x6d);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6d} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "p", "11" ** 32 }};
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.forgetOwnListMemoForTest();
    _ = me;

    try testing.expect(!main.needsFreshConsentForTest(.follows));
    try testing.expect(main.canWriteFollows());
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .follow_author = .{ .who = [_]u8{0xb5} ** 32, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask == null);
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 3).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "11" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "b5" ** 32) != null);
}

test "mute and bookmark ask the same question about their own list" {
    defer main.resetOutboxForTest();
    var fs: FreshStore = undefined;
    try fs.open("askothers");
    defer fs.close();
    _ = signInNothingFound(0x6e);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5f);
    model.viewing_profile = who;
    model.thread_notes[0] = threadNote(0x01, 100, 0);
    model.thread_notes[0].id = 77;
    model.thread_notes[0].pubkey = who;
    model.thread_notes_len = 1;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg{ .mute_person = 1 }, &fx);
    try testing.expectEqual(main.FreshAsk.Action.mute, model.fresh_ask.?.action);
    try testing.expectEqual(main.ListKind.mutes, model.fresh_ask.?.kind());
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 10000) == null);
    main.update(&model, .fresh_list_cancel, &fx);

    main.update(&model, Msg{ .toggle_bookmark = 77 }, &fx);
    try testing.expectEqual(main.FreshAsk.Action.bookmark, model.fresh_ask.?.action);
    try testing.expectEqual(main.ListKind.bookmarks, model.fresh_ask.?.kind());
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 10003) == null);
    main.update(&model, .fresh_list_cancel, &fx);

    main.update(&model, Msg{ .bookmark_privately = 77 }, &fx);
    try testing.expectEqual(main.FreshAsk.Action.bookmark_privately, model.fresh_ask.?.action);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 10003) == null);
    main.update(&model, .fresh_list_cancel, &fx);

    // Yes on the mute list publishes a list of one and leaves the others asking.
    main.update(&model, Msg{ .mute_person = 1 }, &fx);
    main.update(&model, .fresh_list_confirm, &fx);
    const muted = main.ownRecordTagsJoinedForTest(testing.allocator, 10000) orelse return error.NothingWritten;
    defer testing.allocator.free(muted);
    try testing.expect(std.mem.indexOf(u8, muted, "5f" ** 32) != null);
    try testing.expect(main.needsFreshConsentForTest(.bookmarks));
    try testing.expect(main.needsFreshConsentForTest(.follows));
}

test "a first profile's yes is spent by its save, and a reopened sheet waits for the signer" {
    // The yes to "start a new profile" was never spent, and the sheet concluded
    // there was no profile from the store alone, while the first one was still
    // with the bunker. Reopened in that window it offered a fresh start again,
    // and a second Save published a second first profile without asking.
    var fs: FreshStore = undefined;
    try fs.open("firstprofile2");
    defer fs.close();
    const me = signInNothingFound(0x6e);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    defer main.forgetOwnProfileAnswerForTest();
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    // The bunker holds the reader's key.
    main.setRemotePubkeyForTest(me);
    main.recordOwnProfileAnswerForTest(me, true);

    var model = main.initialModel();
    model.stage = .settings;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(model.profile_stage == .absent);
    model.profile_name_buffer.set("Fresh");
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_stage == .sent);
    try testing.expect(!main.noHistoryKnownForTest(.profile));

    // Reopened while the bunker still has it: not "no profile".
    model.editing_profile = false;
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(model.profile_stage == .fetching);

    // The bunker refuses. Now there is none, and the next Save asks again.
    var idbuf: [24]u8 = undefined;
    const id = main.pendingSignIdForKindForTest(0, &idbuf) orelse return error.NoPendingSign;
    try testing.expect(main.failPendingForTest(id));
    main.scanPendingRemoteForTest(&model, &fx);
    model.editing_profile = false;
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(model.profile_stage == .absent);
    model.profile_name_buffer.set("Fresh again");
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);
    var none: [24]u8 = undefined;
    try testing.expect(main.pendingSignIdForKindForTest(0, &none) == null);
}
test "every status the Edit profile sheet can show fits the two lines it has room for" {
    // The sheet is a fixed card in a 760 high window and the status sits above the
    // buttons. Three lines pushed Save and Try again past the card and off the
    // window, so a reader in exactly the state that needs them could not press
    // them. Two lines at the sheet's width is about 104 characters.
    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    defer main.setIdentityMintedForTest(false);
    const me = main.activePubkeyForTest().?;
    const limit: usize = 104;

    var model = main.initialModel();
    const stages = [_]main.ProfileStage{ .fetching, .absent, .unread, .have, .saving, .sent, .failed };
    for ([_]bool{ false, true }) |minted| {
        main.setIdentityMintedForTest(minted);
        for ([_]u8{ 0, 1, 2 }) |relays| {
            main.forgetFollowsForTest();
            main.forgetOwnRecordAnswersForTest();
            main.resetRelaysForTest();
            switch (relays) {
                0 => {},
                1 => main.ownListsWaitedForTest(60),
                else => {
                    try ownRelayListIsThePool(0x71, &.{});
                    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
                },
            }
            for (stages) |stage| {
                for ([_]bool{ false, true }) |confirming| {
                    model.profile_stage = stage;
                    model.profile_confirm_new = confirming;
                    try testing.expect(model.profile_status().len <= limit);
                }
            }
        }
    }
}

test "the app's own relays finishing never starts a list for a reader whose relays are unknown" {
    // A cold import dials the bootstrap relays. All of them finishing without a
    // list says nothing about the relays this reader actually writes to, which
    // nobody has named yet. No question is put, a yes left over from somewhere
    // writes nothing, and the profile sheet stays shut.
    var fs: FreshStore = undefined;
    try fs.open("norelaylist");
    defer fs.close();
    main.setIdentityForTest([_]u8{0x72} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    defer main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    const me = main.activePubkeyForTest().?;
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(main.contactsConfirmedAbsentForTest());
    main.ownListsWaitedForTest(60);

    try testing.expectEqual(main.OwnListsRead.incomplete, main.ownListsRead());
    try testing.expect(!main.needsFreshConsentForTest(.follows));
    try testing.expect(!main.confirmStartFreshForTest(.follows));

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const bob = [_]u8{0xb6} ** 32;
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask == null);
    model.fresh_ask = .{ .action = .follow, .who = bob, .of = me };
    main.update(&model, .fresh_list_confirm, &fx);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 3) == null);

    var sheet = main.initialModel();
    sheet.profile_stage = .absent;
    sheet.profile_name_buffer.set("Nobody");
    try testing.expect(!sheet.profile_can_save());
}

test "a relay the reader writes to that Plaza does not read keeps the read open" {
    // NIP-65 puts the lists on the write relays. One that is not in the pool, or
    // is in it marked write-only, is never asked, so its silence is not an answer.
    const me = signInNothingFound(0x73);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    try testing.expectEqual(main.OwnListsRead.none_found, main.ownListsRead());

    main.forgetOwnRecordAnswersForTest();
    const theirs = "wss://only-theirs.example";
    try ownRelayListIsThePool(0x73, &.{theirs});
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    main.ownListsWaitedForTest(60);
    try testing.expectEqual(main.OwnListsRead.incomplete, main.ownListsRead());
    try testing.expect(!main.confirmStartFreshForTest(.mutes));

    // In the pool but write-only: still never asked.
    const seat = main.addRelayForTest(theirs, false, true) orelse return error.PoolFull;
    try testing.expect(!main.ownRelaysAllFinishedForTest());
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var model = main.initialModel();
        model.stage = .ready;
        model.viewing_profile = [_]u8{0x5d} ** 32;
        const tree = try buildTree(arena_state.allocator(), &model);
        try testing.expect(findAnyTextContaining(tree.root, "does not read from every relay you write to"));
    }

    // Read from, and finished: now every relay that could hold a list has said so.
    main.cycleRelayForTest(seat);
    try testing.expect(main.relayAt(seat).?.read);
    try testing.expect(!main.ownRelaysAllFinishedForTest());
    main.noteContactsAnsweredByForTest(seat, me);
    try testing.expect(main.ownRelaysAllFinishedForTest());
}

test "an answer from a relay that left its seat does not count for the relay that took it" {
    // Adopting the reader's relay list, or removing one relay and adding another,
    // seats a different relay at the same index. The answer the old one gave is
    // about the old one.
    main.setIdentityForTest([_]u8{0x74} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    defer main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    const me = main.activePubkeyForTest().?;

    const old_url = try testing.allocator.dupe(u8, main.relayUrlAt(0));
    defer testing.allocator.free(old_url);
    main.removeRelayForTest(0);
    const newcomer = "wss://took-the-seat.example";
    try testing.expectEqual(@as(?usize, 0), main.addRelayForTest(newcomer, true, true));
    try ownRelayListIsThePool(0x74, &.{});

    // The relay that used to sit there answered just before it left.
    main.noteContactsAnsweredFromForTest(0, old_url, me);
    for (1..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(!main.ownRelaysAllFinishedForTest());
    try testing.expect(!main.confirmStartFreshForTest(.follows));

    // The relay sitting there now answers for itself.
    main.noteContactsAnsweredByForTest(0, me);
    try testing.expect(main.ownRelaysAllFinishedForTest());
}

test "a yes is never spent on an account other than the one it was asked about" {
    var fs: FreshStore = undefined;
    try fs.open("switchyes");
    defer fs.close();
    _ = signInNothingFound(0x75);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const bob = [_]u8{0xb7} ** 32;
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask != null);

    // Another account signs in while the question is open, and it too has every
    // relay finished with nothing. The yes was about the first one.
    _ = signInNothingFound(0x76);
    try testing.expect(main.needsFreshConsentForTest(.follows));
    main.update(&model, .fresh_list_confirm, &fx);
    try testing.expect(model.fresh_ask == null);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 3) == null);
    try testing.expect(!main.noHistoryKnownForTest(.follows));
}

test "a list that arrives while the question is open is spliced onto, and arms nothing" {
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("latelist");
    defer fs.close();
    _ = signInNothingFound(0x77);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const bob = [_]u8{0xb8} ** 32;
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask != null);

    // The real list, late, from a relay that had been slow.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x77} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "p", "12" ** 32 }};
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);
    main.forgetOwnListMemoForTest();

    main.update(&model, .fresh_list_confirm, &fx);
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 3) orelse return error.NothingWritten;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "12" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "b8" ** 32) != null);
    // No yes was recorded: a later empty read is refused, not a fresh start.
    try testing.expect(!main.noHistoryKnownForTest(.follows));
}
test "a relay edit that will not be published says so on the screen" {
    // The gate is the safe half; this is the honest half. An edit that stays on
    // this device looks exactly like one that went out, and a reader who is
    // never told will believe their relays moved with them to every other
    // client. Asserting the SCREEN, because the model being right about a
    // sentence nobody renders is the failure this repo keeps meeting.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x7a} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);
    try testing.expect(findAnyTextContaining(p.tree.root, "has not read your published relay list"));

    // And it goes away once there is nothing to warn about: a key minted here
    // has no list to lose, so the edit publishes and the line would be a lie.
    main.setIdentityMintedForTest(true);
    const after = try painted.Painted.render(arena, &model);
    try testing.expect(!findAnyTextContaining(after.tree.root, "has not read your published relay list"));
}
test "a first media server list waits for the relays the reader writes to, and for a yes" {
    // The follow list's rule, for the same reason: no server list in hand is
    // only an absence once every relay the reader's own kind:10002 names for
    // writing has finished without one, and even then a press asks before a
    // list of one goes out over anything Plaza has not looked at.
    defer main.resetOutboxForTest();
    var fs: FreshStore = undefined;
    try fs.open("firstservers");
    defer fs.close();
    main.forgetBlossomForTest();
    defer main.forgetBlossomForTest();
    const me = signInNothingFound(0x6e);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    var fx: main.EffectsForTest = undefined;

    // Some write relays still answering: nothing to ask about, and nothing sent.
    main.retryOwnListsReadForTest();
    for (0..2) |i| main.noteContactsAnsweredByForTest(i, me);
    model.blossom_buffer.set("https://one.example");
    main.update(&model, .blossom_add, &fx);
    try testing.expect(model.fresh_ask == null);
    try testing.expect(main.ownRecordTagsJoinedForTest(arena, 10063) == null);
    try testing.expectEqualStrings("Plaza has not read your server list yet, so it will not replace it.", model.blossom_status());

    // All of them finished without one: the press asks, and a no sends nothing.
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    model.blossom_error = .none;
    main.update(&model, .blossom_add, &fx);
    try testing.expect(model.fresh_ask != null);
    try testing.expectEqual(main.FreshAsk.Action.add_media_server, model.fresh_ask.?.action);
    main.update(&model, .fresh_list_cancel, &fx);
    try testing.expect(main.ownRecordTagsJoinedForTest(arena, 10063) == null);

    // A yes starts the list with that one server, and spends itself: a later
    // write with nothing stored is refused rather than read as a second start.
    main.update(&model, .blossom_add, &fx);
    main.update(&model, .fresh_list_confirm, &fx);
    const tags = main.ownRecordTagsJoinedForTest(arena, 10063) orelse return error.NothingWritten;
    try testing.expect(std.mem.indexOf(u8, tags, "server https://one.example") != null);
    try testing.expect(!main.needsFreshConsentForTest(.media_servers));
}

test "the new-list question asked from Settings stands over Settings" {
    var fs: FreshStore = undefined;
    try fs.open("asksettings");
    defer fs.close();
    main.forgetBlossomForTest();
    defer main.forgetBlossomForTest();
    const me = signInNothingFound(0x6d);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_settings, &fx);
    main.retryOwnListsReadForTest();
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    model.blossom_buffer.set("https://one.example");
    main.update(&model, .blossom_add, &fx);
    try testing.expect(model.fresh_ask != null);

    // The question and the page it was asked from, both. It used to stand on
    // the feed alone, and Settings vanished from behind it.
    const tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .button, "Start a new list") != null);
    // The server field is on the Settings page and nowhere else.
    try testing.expect(findAnyTextContaining(tree.root, "one.example"));

    // And the same with the Edit profile sheet up over Settings.
    model.editing_profile = true;
    const over_sheet = try buildTree(arena, &model);
    try testing.expect(findByText(over_sheet.root, .button, "Start a new list") != null);
    try testing.expect(findByLabel(over_sheet.root, "Edit profile") != null);
}
test "every toast the app can show fits the toast whole" {
    // The toast is one line of text over a 48-byte buffer, and `setToast` cuts
    // at the buffer, so a longer sentence reaches the reader as the first half of
    // one: "Could not read your follow list from your relays", and the rest of
    // what it meant gone. The limit is the buffer and not the width: 48 bytes of
    // the toast's text size is far narrower than the window at its minimum.
    const cap = main.initialModel().toast_buf.len;

    // Every string literal handed to `setToast`, read out of the source, so a new
    // toast is checked the day it is written rather than when somebody notices.
    // Every file of the app, joined, so a toast is found wherever its call sits.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (app_sources) |s| {
        try joined.append(testing.allocator, '\n');
        try joined.appendSlice(testing.allocator, s.text);
    }
    const source = joined.items;
    var calls: usize = 0;
    var too_long: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, "setToast(")) |start| {
        at = start + "setToast(".len;
        // The call's own text, to its closing parenthesis, skipping string
        // contents so a ")" inside a sentence does not end it early.
        var depth: usize = 1;
        var i = at;
        var in_string = false;
        while (i < source.len and depth > 0) : (i += 1) {
            const c = source[i];
            if (in_string) {
                if (c == '\\') {
                    i += 1;
                } else if (c == '"') in_string = false;
            } else if (c == '"') {
                in_string = true;
            } else if (c == '(') {
                depth += 1;
            } else if (c == ')') depth -= 1;
        }
        const call = source[at..i];
        if (std.mem.startsWith(u8, call, "model: *Model")) continue; // the definition
        calls += 1;
        var j: usize = 0;
        while (std.mem.indexOfScalarPos(u8, call, j, '"')) |open| {
            const close = std.mem.indexOfScalarPos(u8, call, open + 1, '"') orelse break;
            const text = call[open + 1 .. close];
            j = close + 1;
            // An argument to a helper (`noListToast("bookmarks")`) is not itself
            // shown; the helper's sentences are checked below.
            if (std.mem.indexOf(u8, call[0..open], "noListToast(") != null) continue;
            if (text.len > cap) {
                std.debug.print("\ntoo long for the toast ({d} bytes): {s}\n", .{ text.len, text });
                too_long += 1;
            }
        }
    }
    // The walk found the calls, and is not passing because it read nothing.
    try testing.expect(calls > 50);

    for (main.noListToastsForTest()) |text| {
        if (text.len > cap) {
            std.debug.print("\ntoo long for the toast ({d} bytes): {s}\n", .{ text.len, text });
            too_long += 1;
        }
    }
    try testing.expect(main.place_looking_toast_for_test.len <= cap);
    try testing.expectEqual(@as(usize, 0), too_long);
}

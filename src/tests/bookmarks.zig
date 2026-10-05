//! Tests of bookmarks.zig. Bookmarks, public and private.

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
const bookmarkFixture = harness.bookmarkFixture;
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;

test "what the private-half refusals say fits the toast whole" {
    // The toast holds 48 bytes and `setToast` cuts at the buffer, so a longer
    // sentence reaches the reader as half of one. Every sentence here ends in a
    // full stop, and a cut one would not. The declined one is asked again by the
    // very press that shows it, so it points at the signer and not at the button.
    const declined_toast = "Signer declined. Asked again, approve it there.";
    try testing.expect(declined_toast.len <= 48);
    var model = main.initialModel();
    for ([_]main.MuteWrite{ .private_half_waiting, .private_half_declined, .private_half_unreadable }) |outcome| {
        main.sayMuteWriteForTest(&model, outcome, true);
        try testing.expect(model.toast_len > 0);
        try testing.expectEqual(@as(u8, '.'), model.toast_buf[model.toast_len - 1]);
        if (outcome == .private_half_declined) try testing.expectEqualStrings(declined_toast, model.toast_text());
        model.toast_len = 0;
    }
    for ([_]main.BookmarkWrite{ .private_half_waiting, .private_half_declined, .private_half_unreadable }) |outcome| {
        main.sayBookmarkWriteForTest(&model, outcome, true);
        try testing.expect(model.toast_len > 0);
        try testing.expectEqual(@as(u8, '.'), model.toast_buf[model.toast_len - 1]);
        if (outcome == .private_half_declined) try testing.expectEqualStrings(declined_toast, model.toast_text());
        model.toast_len = 0;
    }
}

test "an empty bookmark list says whether anything is saved" {
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmempty.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // One bookmark, for a note this machine never fetched. The list shows
    // nothing, and "nothing saved" would be wrong about why.
    var unfetched_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&unfetched_hex, "{x}", .{[_]u8{0xa7} ** 32});
    const saved = [_]nostr.event.Tag{&.{ "e", &unfetched_hex }};
    _ = try bookmarkFixture(arena, &signer, &store, &saved, "");
    try testing.expectEqual(@as(usize, 1), main.bookmarkCount());

    var model = main.initialModel();
    model.stage = .ready;
    main.openBookmarksForTest(&model);
    try testing.expectEqual(@as(usize, 0), model.thread_notes_len);
    const held = try buildTree(arena, &model);
    try testing.expect(findAnyText(held.root, "None of your saved notes are on this machine yet.") != null);
    try testing.expect(findAnyText(held.root, "Nothing saved here yet.") == null);
    try testing.expect(findAnyTextContainingText(held.root, "they have written") == null);

    // And with none at all, it says that.
    main.forgetBookmarksForTest();
    try testing.expectEqual(@as(usize, 0), main.bookmarkCount());
    const none = try buildTree(arena, &model);
    try testing.expect(findAnyText(none.root, "Nothing saved here yet.") != null);
}

test "a bookmark splices onto the list and never publishes over an unreadable half" {
    defer main.resetOutboxForTest();
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bm.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const kept = [_]u8{0xa1} ** 32;
    var kept_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&kept_hex, "{x}", .{kept});
    // A tag this app does not draw sits beside it. NIP-51 puts addressable
    // events, hashtags and URLs in this list too, and dropping what is not
    // understood would delete an article somebody saved in another client.
    const existing = [_]nostr.event.Tag{
        &.{ "e", &kept_hex },
        &.{ "a", "30023:deadbeef:an-article" },
    };
    _ = try bookmarkFixture(arena, &signer, &store, &existing, "");
    try testing.expect(main.isBookmarked(kept));

    const fresh = [_]u8{0xa2} ** 32;
    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.BookmarkWrite.published, main.writeBookmarkForTest(&fx, fresh, true));
    // Both, at once: the press fills the icon before any relay answers.
    try testing.expect(main.isBookmarked(fresh));
    try testing.expect(main.isBookmarked(kept));

    // Removing one leaves the other. Off a fresh fixture, because a splice
    // reads the STORE and the store does not hold the list above until its
    // signature comes back: asking to remove something that is only in memory
    // would be answered "nothing to do", correctly.
    main.releaseHelperSignForTest();
    main.forgetBookmarksForTest();
    var tmp_rm = testing.tmpDir(.{});
    defer tmp_rm.cleanup();
    var pbuf_rm: [128]u8 = undefined;
    const db_rm = try std.fmt.bufPrintZ(&pbuf_rm, ".zig-cache/tmp/{s}/bmrm.mdb", .{tmp_rm.sub_path});
    var store_rm = try nostr.store.Store.open(db_rm, .{});
    defer store_rm.deinit();
    _ = try bookmarkFixture(arena, &signer, &store_rm, &existing, "");
    try testing.expectEqual(main.BookmarkWrite.published, main.writeBookmarkForTest(&fx, kept, false));
    try testing.expect(!main.isBookmarked(kept));

    // Now the assertion this whole shape exists for. A list carrying a private
    // half this app cannot open must not be written over: publishing without
    // those bytes erases every private bookmark the reader has. This is the bug
    // Jumble ships on both its mute path and its bookmark path.
    main.forgetBookmarksForTest();
    main.forgetPrivateHalvesForTest();
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var pbuf2: [128]u8 = undefined;
    const db2 = try std.fmt.bufPrintZ(&pbuf2, ".zig-cache/tmp/{s}/bm2.mdb", .{tmp2.sub_path});
    var store2 = try nostr.store.Store.open(db2, .{});
    defer store2.deinit();
    main.releaseHelperSignForTest();
    _ = try bookmarkFixture(arena, &signer, &store2, &existing, "not-openable-ciphertext");
    // The keyholder looked at it and could not open it (Notary answers 422 for
    // a ciphertext that does not decrypt). That is a limit and not a refusal,
    // so it says so and no press asks again. Nothing is published either way.
    try testing.expectEqual(
        main.BookmarkWrite.private_half_unreadable,
        main.writeBookmarkForTest(&fx, fresh, true),
    );
    // And nothing moved: refusing means refusing, not refusing after changing
    // the set the icon reads from.
    try testing.expect(!main.isBookmarked(fresh));
}

test "a private bookmark is sealed, written and read back" {
    // The whole round trip: the press builds the new private tag array, the
    // keyholder seals it, the splice publishes it as the content with the
    // public half untouched, and reading the list back finds it.
    defer main.resetOutboxForTest();
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmpriv.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // A public bookmark already there, so the test also proves a private write
    // does not disturb the public half.
    const public_one = [_]u8{0xb1} ** 32;
    var public_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&public_hex, "{x}", .{public_one});
    const existing = [_]nostr.event.Tag{&.{ "e", &public_hex }};
    const kp = try bookmarkFixture(arena, &signer, &store, &existing, "");
    try testing.expect(main.isBookmarked(public_one));

    const secret_one = [_]u8{0xb2} ** 32;
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();

    // The press. The keyholder seals it inline in a test binary.
    try testing.expectEqual(
        main.BookmarkWrite.published,
        main.writePrivateBookmarkForTest(&fx, secret_one, true),
    );
    // Nothing has been written yet: a seal is a round trip, and the set must not
    // move until the ciphertext exists.
    try testing.expect(!main.isBookmarked(secret_one));

    // The ciphertext lands and the splice runs.
    main.finishPrivateBookmarkForTest(&model, &fx);
    try testing.expect(main.isBookmarked(secret_one));
    // The public half is untouched by a private write.
    try testing.expect(main.isBookmarked(public_one));

    // And it survives a reload from a published record, which is the real
    // proof: the content that was published decrypts to a list holding it.
    const sealed = main.lastSealedForTest();
    try testing.expect(sealed.len > 0);
    main.forgetBookmarksForTest();
    main.forgetPrivateHalvesForTest();
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var pbuf2: [128]u8 = undefined;
    const db2 = try std.fmt.bufPrintZ(&pbuf2, ".zig-cache/tmp/{s}/bmpriv2.mdb", .{tmp2.sub_path});
    var store2 = try nostr.store.Store.open(db2, .{});
    defer store2.deinit();
    main.setStoreForTest(&store2);
    const republished = try nostr.event.create(arena, signer, kp, 1_800_000_100, 10003, &existing, sealed, null);
    _ = try main.plazaIngestVerifiedForTest(arena, republished, signer);
    main.loadBookmarksFromStoreForTest();
    try testing.expect(main.isBookmarked(secret_one));
    try testing.expect(main.isBookmarked(public_one));
}

test "a private bookmark sealed while Notary signs a like is not sent, and says so" {
    // The press asked whether the signer was free, and then the seal took a
    // round trip. A like pressed in between held Notary's one key, the
    // bookmark's sign took the like's slot and its undo, the SDK refused the
    // second sign, and the toast said "Bookmarked privately" anyway.
    defer main.resetOutboxForTest();
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.releaseHelperSignForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmbusy.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try bookmarkFixture(arena, &signer, &store, &.{}, "");
    const secret_one = [_]u8{0xb7} ** 32;
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    // What an earlier test published and no tick said.
    main.sayPrivateBookmarkPublished(&model);
    model.toast_len = 0;

    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, secret_one, true));
    // A like goes out to Notary while the seal is away.
    main.holdHelperSignForTest();
    main.finishPrivateBookmarkForTest(&model, &fx);
    try testing.expectEqualStrings("Your signer is busy. Nothing was sent.", model.toast_text());
    try testing.expect(!main.isBookmarked(secret_one));
    try testing.expect(main.helperSignPendingForTest());

    // Free again, and handed to a signer that has not answered yet: nothing
    // is published, so nothing is said.
    main.releaseHelperSignForTest();
    model.toast_len = 0;
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, secret_one, true));
    main.silenceTestSignerForTest(true);
    main.finishPrivateBookmarkForTest(&model, &fx);
    main.silenceTestSignerForTest(false);
    main.sayPrivateBookmarkPublished(&model);
    try testing.expectEqual(@as(usize, 0), model.toast_len);

    // And one that is signed and published says so, on the tick.
    main.releaseHelperSignForTest();
    const secret_two = [_]u8{0xb8} ** 32;
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, secret_two, true));
    main.finishPrivateBookmarkForTest(&model, &fx);
    try testing.expect(main.isBookmarked(secret_two));
    try testing.expectEqual(@as(usize, 0), model.toast_len);
    main.sayPrivateBookmarkPublished(&model);
    try testing.expectEqualStrings("Bookmarked privately", model.toast_text());
}

test "a private bookmark that was never signed is not announced by a later public one" {
    // Its stamp stayed armed, and a public bookmark published with the same
    // stamp was announced as "Bookmarked privately".
    defer main.resetOutboxForTest();
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.releaseHelperSignForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmstamp.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try bookmarkFixture(arena, &signer, &store, &.{}, "");
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.sayPrivateBookmarkPublished(&model);
    model.toast_len = 0;

    // Sealed, handed to a signer that never answers, and given up on.
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xb9} ** 32, true));
    main.silenceTestSignerForTest(true);
    main.finishPrivateBookmarkForTest(&model, &fx);
    main.silenceTestSignerForTest(false);
    main.releaseHelperSignForTest();

    // A public bookmark built on the same stored list, so with the same stamp.
    const public_one = [_]u8{0xba} ** 32;
    try testing.expectEqual(main.BookmarkWrite.published, main.writeBookmarkForTest(&fx, public_one, true));
    const out = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqual(@as(u16, 10003), out.kind);
    main.sayPrivateBookmarkPublished(&model);
    try testing.expectEqual(@as(usize, 0), model.toast_len);
}

/// Private mutes sealed to the bookmark fixture's key, stored and read: the
/// reader whose cache the private bookmark tests below have to share.
fn privateMutesFixture(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, who: [32]u8, created_at: i64) ![]const u8 {
    const hex = std.fmt.bytesToHex(who, .lower);
    const plain = try std.fmt.allocPrint(arena, "[[\"p\",\"{s}\"]]", .{&hex});
    const ck = try nostr.nip44.conversationKey(signer, kp.secret_key, kp.public_key);
    const sealed = try nostr.nip44.encryptWithConversationKey(arena, ck, plain, [_]u8{@truncate(who[0])} ** 32);
    const ev = try nostr.event.create(arena, signer, kp, created_at, 10000, &.{}, sealed, null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.loadMutesFromStoreForTest();
    return sealed;
}

test "private bookmarks written one after another stay writable, and the private mutes stay readable" {
    // Every private bookmark write mints a new ciphertext, and each one read
    // back took a slot of the private-half cache for good: an opened slot was
    // never given up. With private mutes holding one slot, the fourth write's
    // half found none, and from then on every bookmark said "Cannot open
    // private bookmarks" until a restart. A mute list changed in another
    // client hit the same wall.
    defer main.resetOutboxForTest();
    main.forgetBookmarksForTest();
    main.forgetMutesForTest();
    main.forgetPrivateHalvesForTest();
    defer {
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.forgetMutesForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.forgetLastPublishedForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmfive.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    const kp = try bookmarkFixture(arena, &signer, &store, &.{}, "");

    const muted = [_]u8{0xc3} ** 32;
    const mute_half = try privateMutesFixture(arena, signer, kp, muted, 1_800_000_000);
    try testing.expect(main.isMuted(muted));
    try testing.expectEqualStrings("open", main.privateHalfStateOfForTest(mute_half));

    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    var ids: [5][32]u8 = undefined;
    for (&ids, 0..) |*id, n| {
        id.* = [_]u8{@intCast(0xd0 + n)} ** 32;
        try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, id.*, true));
        main.finishPrivateBookmarkForTest(&model, &fx);
        try testing.expect(main.isBookmarked(id.*));
        // The mute half is never what makes room.
        try testing.expectEqualStrings("open", main.privateHalfStateOfForTest(mute_half));
        try testing.expect(main.isMuted(muted));
    }

    // What went out last holds all five, and is what the store holds now.
    const out = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqual(@as(u16, 10003), out.kind);
    const opened = try nostr.nip44.decrypt(arena, signer, kp.secret_key, kp.public_key, out.content);
    for (ids) |id| {
        const hex = std.fmt.bytesToHex(id, .lower);
        try testing.expect(std.mem.indexOf(u8, opened, &hex) != null);
    }
    main.loadBookmarksFromStoreForTest();
    for (ids) |id| try testing.expect(main.isBookmarked(id));

    // The mute list changes in another client, and reads, and can be written.
    const now_muted = [_]u8{0xc4} ** 32;
    const new_mute_half = try privateMutesFixture(arena, signer, kp, now_muted, 1_900_000_000);
    try testing.expect(main.isMuted(now_muted));
    try testing.expectEqualStrings("open", main.privateHalfStateOfForTest(new_mute_half));
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, [_]u8{0xc5} ** 32, true));
}

test "a sealed private half is open the moment it is published, with nothing asked" {
    // The reader holds the plaintext it asked to have sealed. Asking the signer
    // to open the ciphertext that came back was a second round trip, on a bunker
    // a second prompt, for a list it had just written.
    main.forgetBookmarksForTest();
    main.forgetPrivateSealForTest();
    main.forgetPrivateHalvesForTest();
    defer {
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.clearPendingForTest();
        main.setSignerKindLocalForTest();
        main.forgetLastPublishedForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmseed.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    const kp = try bookmarkFixture(arena, &signer, &store, &.{}, "");

    // A bunker seals it. Nothing in a test answers a bunker's decrypt inline,
    // so a half that reads open below was opened by nothing but the seal.
    var fx: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    main.setRemotePubkeyForTest(kp.public_key);
    const note = [_]u8{0xe1} ** 32;
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, note, true));
    var threaded = std.Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const sealed = try nostr.nip44.encrypt(arena, threaded.io(), signer, kp.secret_key, kp.public_key, main.lastSealPlaintextForTest());
    main.parkSealAnswerForTest(sealed);
    main.setSignerKindLocalForTest();
    var model = main.initialModel();
    const asks = main.halfAskSeqForTest();
    main.scanPendingRemoteForTest(&model, &fx);
    const published = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqualStrings(sealed, published.content);

    try testing.expectEqualStrings("open", main.privateHalfStateOfForTest(sealed));
    try testing.expect(main.privateHalfIsReadableForTest(sealed));
    try testing.expectEqual(asks, main.halfAskSeqForTest());
    // And the next write builds on it at once, rather than waiting on a prompt.
    main.setSignerKindForTest("remote");
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xe2} ** 32, true));
}

test "a private bookmark write wipes each copy of the list before it frees it" {
    // The plaintext built for the seal, and the request that carries it to
    // Notary, were freed as they were. Every other copy of a private half is
    // wiped first; these two held the whole list, and the entry being added.
    main.forgetBookmarksForTest();
    main.forgetPrivateSealForTest();
    main.forgetPrivateHalvesForTest();
    defer {
        main.setPlainGpaForTest(null);
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmwipe.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try bookmarkFixture(arena, &signer, &store, &.{}, "");

    const note = [_]u8{0xc6} ** 32;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{note});
    var check = harness.WipeCheck{ .marker = &hex };
    main.setPlainGpaForTest(check.allocator());
    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, note, true));
    main.setPlainGpaForTest(null);
    // The seal was asked for with the entry in it, so a copy did exist.
    try testing.expect(std.mem.indexOf(u8, main.lastSealPlaintextForTest(), &hex) != null);
    try testing.expectEqual(@as(u32, 0), check.unwiped);
}

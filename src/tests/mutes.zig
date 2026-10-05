//! Tests of mutes.zig. The mute list: reading it, and writing it without losing anything.

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
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const signedNote = harness.signedNote;

test "a kind:10000 arriving names who this reader has muted" {
    main.forgetMutesForTest();
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const noisy = [_]u8{0x52} ** 32;
    const quiet = [_]u8{0x53} ** 32;
    var noisy_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&noisy_hex, "{x}", .{noisy});

    // Signed by the READER, which is the only mute list that means anything to
    // them. `p` is the public half.
    const tags = [_]nostr.event.Tag{&.{ "p", &noisy_hex }};
    const ev = try muteListEvent(arena, &signer, [_]u8{0x51} ** 32, 1_800_000_000, &tags, "");
    main.ingestMuteListForTest(ev);

    try testing.expect(main.isMuted(noisy));
    try testing.expect(!main.isMuted(quiet));
    try testing.expectEqual(@as(usize, 1), main.muteCount());
}

test "a mute the keyholder never signed is put back, stamp and all" {
    // The worst of the family. A mute that is not published means the reader
    // goes on seeing somebody they asked never to see again, while the app says
    // "Muted"; and the press stamps the list forward, so `ingestMuteList` then
    // drops their REAL kind:10000 for the rest of the session and the truth
    // cannot get back on screen.
    main.forgetMutesForTest();
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
        main.setSignerKindLocalForTest();
        main.silenceTestSignerForTest(false);
    }
    main.setSignerKindHelperForTest();
    main.silenceTestSignerForTest(true);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/muteundo.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const noisy = [_]u8{0x52} ** 32;
    var noisy_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&noisy_hex, "{x}", .{noisy});
    const tags = [_]nostr.event.Tag{&.{ "p", &noisy_hex }};
    const ev = try muteListEvent(arena, &signer, [_]u8{0x51} ** 32, 1_800_000_000, &tags, "");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.ingestMuteListForTest(ev);
    try testing.expect(main.isMuted(noisy));

    // Unmute them. The set moves at once, which is the part worth keeping.
    const quiet = [_]u8{0x53} ** 32;
    _ = quiet;
    var fx: main.EffectsForTest = undefined;
    _ = main.writeMuteForTest(&fx, noisy, false);
    try testing.expect(!main.isMuted(noisy));

    // And the keyholder refuses.
    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 403, .body = "" });
    var model = main.initialModel();
    main.scanHelperSignForTest(&model);

    // Back to muted, and told.
    try testing.expect(main.isMuted(noisy));
    try testing.expect(model.toast_text().len > 0);

    // And the stamp went back with it, so their real list is not locked out.
    // Re-ingesting the list they actually have must take.
    main.forgetMutesForTest();
    main.ingestMuteListForTest(ev);
    try testing.expect(main.isMuted(noisy));
}

test "somebody else's mute list is not this reader's" {
    main.forgetMutesForTest();
    main.setIdentityForTest([_]u8{0x54} ** 32);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const victim = [_]u8{0x55} ** 32;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{victim});
    const tags = [_]nostr.event.Tag{&.{ "p", &hex }};

    // A stranger's mute list, arriving through the same door as the reader's.
    // Adopting it would let anybody on the network hide anybody from anybody.
    const ev = try muteListEvent(arena, &signer, [_]u8{0x56} ** 32, 1_800_000_000, &tags, "");
    main.ingestMuteListForTest(ev);
    try testing.expect(!main.isMuted(victim));
    try testing.expectEqual(@as(usize, 0), main.muteCount());
}

test "an older mute list does not undo a newer one" {
    main.forgetMutesForTest();
    const me = [_]u8{0x57} ** 32;
    main.setIdentityForTest(me);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const who = [_]u8{0x58} ** 32;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{who});
    const with = [_]nostr.event.Tag{&.{ "p", &hex }};

    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_200, &with, ""));
    try testing.expect(main.isMuted(who));

    // A relay replaying an older copy. Replaceable events are decided by
    // created_at, and a stale one arriving late must not unmute somebody.
    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_100, &.{}, ""));
    try testing.expect(main.isMuted(who));

    // A newer one that unmutes them does.
    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_300, &.{}, ""));
    try testing.expect(!main.isMuted(who));
}

test "an empty mute list is an answer, not a malformed event" {
    main.forgetMutesForTest();
    const me = [_]u8{0x59} ** 32;
    main.setIdentityForTest(me);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const who = [_]u8{0x5A} ** 32;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{who});
    const with = [_]nostr.event.Tag{&.{ "p", &hex }};
    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_100, &with, ""));
    try testing.expect(main.isMuted(who));

    // This is where a mute list differs from a contact list. An empty kind:3 is
    // ignored, because a reader with no follows has no feed; an empty kind:10000
    // is somebody who unmuted everybody, and ignoring it would leave the last
    // person they unmuted hidden for good.
    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_200, &.{}, ""));
    try testing.expect(!main.isMuted(who));
    try testing.expectEqual(@as(usize, 0), main.muteCount());
}

test "signing out takes the mute list with it" {
    main.forgetMutesForTest();
    const me = [_]u8{0x5B} ** 32;
    main.setIdentityForTest(me);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const who = [_]u8{0x5C} ** 32;
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{who});
    const with = [_]nostr.event.Tag{&.{ "p", &hex }};
    main.ingestMuteListForTest(try muteListEvent(arena, &signer, me, 1_800_000_100, &with, ""));
    try testing.expect(main.isMuted(who));

    // A second account must not inherit the first one's hidden people, even
    // before its own list has arrived.
    main.setIdentityForTest([_]u8{0x5D} ** 32);
    try testing.expect(!main.isMuted(who));
}

/// A kind:10000 signed by `author_secret`, for the mute tests above.
fn muteListEvent(
    arena: std.mem.Allocator,
    signer: *nostr.keys.Signer,
    author_secret: [32]u8,
    created_at: i64,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !nostr.event.Event {
    const kp = try signer.keyPairFromSecretKey(author_secret);
    return try nostr.event.create(arena, signer.*, kp, created_at, 10000, tags, content, null);
}

test "a muted person's reply is hidden, but the thread they are in still opens" {
    main.forgetMutesForTest();
    main.setIdentityForTest([_]u8{0x67} ** 32);
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/thread.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);

    const op = try signer.keyPairFromSecretKey([_]u8{0x68} ** 32);
    const civil = try signer.keyPairFromSecretKey([_]u8{0x69} ** 32);
    const heckler = try signer.keyPairFromSecretKey([_]u8{0x6A} ** 32);

    const root = try signedNote(arena, signer, op, 1_800_000_000, "the opening note");
    _ = try store.ingest(arena, root, .{});
    var root_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&root_hex, "{x}", .{root.id});
    const reply_tags = [_]nostr.event.Tag{&.{ "e", &root_hex, "", "root" }};
    _ = try store.ingest(arena, try nostr.event.create(arena, signer, civil, 1_800_000_100, 1, &reply_tags, "a fair point", null), .{});
    _ = try store.ingest(arena, try nostr.event.create(arena, signer, heckler, 1_800_000_200, 1, &reply_tags, "noise", null), .{});

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = main.noteFrom(root, 1_800_000_300).id;
    model.thread_root = main.noteFrom(root, 1_800_000_300);

    main.refreshThreadNotesForTest(&model, 1_800_000_300);
    const before = model.thread_notes_len;
    try testing.expect(before >= 2);

    const muted = [_][32]u8{heckler.public_key};
    _ = main.setMutesForTest(&muted, 1_800_000_250);
    main.refreshThreadNotesForTest(&model, 1_800_000_300);
    try testing.expectEqual(before - 1, model.thread_notes_len);
    for (model.thread_notes[0..model.thread_notes_len]) |n| {
        try testing.expect(!std.mem.eql(u8, &n.pubkey, &heckler.public_key));
    }

    // And muting the AUTHOR of the note does not close the thread on you. Opening
    // one is asking to read that note; answering with an empty screen would be
    // the app refusing a question the reader had just asked.
    const muted_op = [_][32]u8{op.public_key};
    _ = main.setMutesForTest(&muted_op, 1_800_000_260);
    main.refreshThreadNotesForTest(&model, 1_800_000_300);
    try testing.expectEqualStrings("the opening note", model.thread_root.content());
}

// -- A client you can make quiet ----------------------------------------------

// -- Muting from here ---------------------------------------------------------

/// A store, an identity, and this account's own kind:10000 in it. Returns the
/// keypair so a test can talk about "me".
fn muteFixture(
    arena: std.mem.Allocator,
    signer: *nostr.keys.Signer,
    store: *nostr.store.Store,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !nostr.keys.KeyPair {
    const secret = [_]u8{0x81} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    // Through the keyholder, like everything else. These tests are about
    // reading the ENCRYPTED half of a NIP-51 list, which used to happen inline
    // against a secret key in this process. There is no secret key here now, so
    // the half is opened by asking Notary, and the fixture that predicted this
    // is where the change landed.
    main.setIdentityForTest(secret);
    main.setStoreForTest(store);
    const ev = try nostr.event.create(arena, signer.*, kp, 1_800_000_000, 10000, tags, content, null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer.*);
    main.loadMutesFromStoreForTest();
    return kp;
}

test "muting splices onto the list rather than replacing it" {
    defer main.resetOutboxForTest();
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/mutew.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const already = [_]u8{0x82} ** 32;
    var already_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&already_hex, "{x}", .{already});
    // A list with somebody already muted, a muted hashtag, a muted word and a
    // muted thread. NIP-51 puts all of those here and Plaza reads none of the
    // last three.
    const existing = [_]nostr.event.Tag{
        &.{ "p", &already_hex },
        &.{ "t", "politics" },
        &.{ "word", "airdrop" },
        &.{ "e", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" },
    };
    _ = try muteFixture(arena, &signer, &store, &existing, "");

    const fresh = [_]u8{0x83} ** 32;
    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, fresh, true));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(written);
    var fresh_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&fresh_hex, "{x}", .{fresh});

    // The new one is on it.
    try testing.expect(std.mem.indexOf(u8, written, &fresh_hex) != null);
    // And so is everything that was already there. THE PROPERTY: dropping what
    // this app does not read would delete filters the reader set in a client
    // that does.
    try testing.expect(std.mem.indexOf(u8, written, &already_hex) != null);
    try testing.expect(std.mem.indexOf(u8, written, "politics") != null);
    try testing.expect(std.mem.indexOf(u8, written, "airdrop") != null);
    try testing.expect(std.mem.indexOf(u8, written, "00112233445566778899aabb") != null);
}

test "unmuting removes exactly one name" {
    defer main.resetOutboxForTest();
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/unmute.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const a = [_]u8{0x84} ** 32;
    const b = [_]u8{0x85} ** 32;
    var a_hex: [64]u8 = undefined;
    var b_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&a_hex, "{x}", .{a});
    _ = try std.fmt.bufPrint(&b_hex, "{x}", .{b});
    const existing = [_]nostr.event.Tag{ &.{ "p", &a_hex }, &.{ "p", &b_hex } };
    _ = try muteFixture(arena, &signer, &store, &existing, "");
    try testing.expect(main.isMuted(a));
    try testing.expect(main.isMuted(b));

    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, a, false));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, &a_hex) == null);
    try testing.expect(std.mem.indexOf(u8, written, &b_hex) != null);
    try testing.expect(!main.isMuted(a));
    try testing.expect(main.isMuted(b));
}

test "with no mute list read back, nothing is published" {
    main.forgetMutesForTest();
    main.setIdentityForTest([_]u8{0x86} ** 32);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/nolist.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);

    // The whole point. "No mute list found" and "the fetch has not landed" are
    // the same thing from here, and one of them ends with the reader's real
    // mutes replaced by a list holding one name. So it refuses, and says so.
    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.MuteWrite.no_list_yet, main.writeMuteForTest(&fx, [_]u8{0x87} ** 32, true));
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 10000) == null);
    try testing.expect(main.muteBlockedReason() != null);
}

test "a private half this app cannot read stops the write instead of erasing it" {
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/private.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const kept = [_]u8{0x88} ** 32;
    var kept_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&kept_hex, "{x}", .{kept});
    const existing = [_]nostr.event.Tag{&.{ "p", &kept_hex }};
    // Content that is present and is not something this app can decrypt: a
    // NIP-04 payload, or a NIP-44 one sealed to a key it does not hold. Either
    // way it holds private mutes, and they are not this app's to throw away.
    _ = try muteFixture(arena, &signer, &store, &existing, "AgY7fT?iv=notreallyanythingwecanopen");

    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(
        main.MuteWrite.private_half_unreadable,
        main.writeMuteForTest(&fx, [_]u8{0x89} ** 32, true),
    );

    // Jumble's bug, not reproduced: its decrypt failure yields an empty tag list
    // and the write then publishes an empty content, taking every private mute
    // with it. Nothing was published here at all.
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, &kept_hex) != null);
    var new_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&new_hex, "{x}", .{[_]u8{0x89} ** 32});
    try testing.expect(std.mem.indexOf(u8, written, &new_hex) == null);
}

test "muting yourself is not a thing" {
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/self.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const kp = try muteFixture(arena, &signer, &store, &.{}, "");
    var fx: main.EffectsForTest = undefined;
    // It would hide your own notes from your own feed.
    try testing.expectEqual(main.MuteWrite.nothing_to_do, main.writeMuteForTest(&fx, kp.public_key, true));
}

test "a private half this app CAN read survives a public mute" {
    defer main.resetOutboxForTest();
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/privkept.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const secret = [_]u8{0x81} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    const secretly = [_]u8{0x8A} ** 32;
    var secretly_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&secretly_hex, "{x}", .{secretly});
    const plain = try std.fmt.allocPrint(arena, "[[\"p\",\"{s}\"]]", .{secretly_hex});
    // NIP-51's private half: a JSON tag array, encrypted to yourself.
    // The explicit-nonce form, so the ciphertext is the same on every run and
    // the assertion below can compare it byte for byte.
    const ck = try nostr.nip44.conversationKey(signer, kp.secret_key, kp.public_key);
    const sealed = try nostr.nip44.encryptWithConversationKey(arena, ck, plain, [_]u8{0x5C} ** 32);

    const publicly = [_]u8{0x8B} ** 32;
    var publicly_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&publicly_hex, "{x}", .{publicly});
    const existing = [_]nostr.event.Tag{&.{ "p", &publicly_hex }};
    _ = try muteFixture(arena, &signer, &store, &existing, sealed);

    // Both halves are in force before the write.
    try testing.expect(main.isMuted(publicly));
    try testing.expect(main.isMuted(secretly));

    var fx: main.EffectsForTest = undefined;
    const fresh = [_]u8{0x8C} ** 32;
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, fresh, true));

    // THE PROPERTY, and the whole reason this write is careful. The content is
    // opaque to the splice: it is somebody's private mutes, sealed. Publishing
    // a public mute must carry those bytes through untouched, and must not
    // replace them with an empty string, which is what Jumble does whenever its
    // decrypt fails.
    const content = main.ownRecordContentForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(sealed, content);

    // And they are still muted afterwards, read back through the write.
    try testing.expect(main.isMuted(secretly));
    try testing.expect(main.isMuted(publicly));
    try testing.expect(main.isMuted(fresh));
}

test "a bunker reader's private mutes are opened by the bunker and carried through a mute" {
    // The case this started from: signed in through a bunker, the private half
    // of the mute list has to be opened by a NIP-46 round trip, and a write
    // before the answer must refuse rather than publish an empty content.
    defer main.resetOutboxForTest();
    main.forgetMutesForTest();
    defer {
        main.setSignerKindForTest("helper");
        main.forgetMutesForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var model = main.initialModel();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bunkerhalf.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const secret = [_]u8{0x81} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    const secretly = [_]u8{0x8A} ** 32;
    var secretly_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&secretly_hex, "{x}", .{secretly});
    const plain = try std.fmt.allocPrint(arena, "[[\"p\",\"{s}\"]]", .{secretly_hex});
    const ck = try nostr.nip44.conversationKey(signer, kp.secret_key, kp.public_key);
    const sealed = try nostr.nip44.encryptWithConversationKey(arena, ck, plain, [_]u8{0x5C} ** 32);

    const publicly = [_]u8{0x8B} ** 32;
    var publicly_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&publicly_hex, "{x}", .{publicly});
    const existing = [_]nostr.event.Tag{&.{ "p", &publicly_hex }};
    _ = try muteFixture(arena, &signer, &store, &existing, sealed);

    // From here this reader's key is in a bunker, which answers over a relay
    // and never inline. The fixture's keyholder opened the half; forget that.
    main.setSignerKindForTest("remote");
    main.setRemotePubkeyForTest(kp.public_key);
    main.forgetPrivateHalvesForTest();
    main.loadMutesFromStoreForTest();
    try testing.expect(!main.isMuted(secretly));
    try testing.expect(main.isMuted(publicly));

    // A mute before the bunker has answered is refused, says why, and writes
    // nothing: the stored list is exactly the one that was read.
    var fx: main.EffectsForTest = undefined;
    const fresh = [_]u8{0x8C} ** 32;
    try testing.expectEqual(main.MuteWrite.private_half_waiting, main.writeMuteForTest(&fx, fresh, true));
    main.markIdleHalvesAskedForTest();
    const unchanged = main.ownRecordContentForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(unchanged);
    try testing.expectEqualStrings(sealed, unchanged);
    try testing.expect(!main.isMuted(fresh));

    // The bunker answers. The listener parks the plaintext and the tick applies
    // it, and the private mute is in force again.
    main.parkRemoteHalfAnswerForTest(0, plain);
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expect(main.isMuted(secretly));

    // Now the write goes through, and carries the bunker's ciphertext through
    // byte for byte. Signing is the other half of a bunker and is not what is
    // under test, so the keyholder signs.
    main.setSignerKindForTest("helper");
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, fresh, true));
    const content = main.ownRecordContentForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(sealed, content);
    try testing.expect(main.isMuted(secretly));
    try testing.expect(main.isMuted(publicly));
    try testing.expect(main.isMuted(fresh));
}

test "a bunker that never opens the private half leaves the mute list untouched" {
    main.forgetMutesForTest();
    defer {
        main.setSignerKindForTest("helper");
        main.forgetMutesForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var model = main.initialModel();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bunkerrefuse.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const secret = [_]u8{0x81} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    const plain = try std.fmt.allocPrint(arena, "[[\"p\",\"{s}\"]]", .{"8a" ** 32});
    const ck = try nostr.nip44.conversationKey(signer, kp.secret_key, kp.public_key);
    const sealed = try nostr.nip44.encryptWithConversationKey(arena, ck, plain, [_]u8{0x5C} ** 32);
    const kept = [_]u8{0x8B} ** 32;
    var kept_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&kept_hex, "{x}", .{kept});
    const existing = [_]nostr.event.Tag{&.{ "p", &kept_hex }};
    _ = try muteFixture(arena, &signer, &store, &existing, sealed);

    main.setSignerKindForTest("remote");
    main.setRemotePubkeyForTest(kp.public_key);
    main.forgetPrivateHalvesForTest();
    main.loadMutesFromStoreForTest();

    var fx: main.EffectsForTest = undefined;
    const fresh = [_]u8{0x8C} ** 32;
    // The ask is out, and the reader refuses it.
    try testing.expectEqual(main.MuteWrite.private_half_waiting, main.writeMuteForTest(&fx, fresh, true));
    main.markIdleHalvesAskedForTest();
    if (!main.failRemoteHalfForTest(0)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx);

    // Every press after that refuses without publishing: the first says the
    // signer declined and asks again, the next waits on that ask.
    try testing.expectEqual(main.MuteWrite.private_half_declined, main.writeMuteForTest(&fx, fresh, true));
    try testing.expectEqual(main.MuteWrite.private_half_waiting, main.writeMuteForTest(&fx, fresh, true));

    // Nothing was ever published: the list in the store is the one that was
    // read, tags and sealed content alike. An empty content here is the
    // Jumble bug.
    const content = main.ownRecordContentForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(sealed, content);
    const tags = main.ownRecordTagsJoinedForTest(testing.allocator, 10000).?;
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, &kept_hex) != null);
    var fresh_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&fresh_hex, "{x}", .{fresh});
    try testing.expect(std.mem.indexOf(u8, tags, &fresh_hex) == null);
}

test "the profile offers Mute, and says why when it cannot" {
    defer main.resetOutboxForTest();
    main.forgetMutesForTest();
    defer {
        main.forgetMutesForTest();
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/mutebtn.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const them = [_]u8{0x8D} ** 32;

    // No mute list read yet: the control is there and disabled, with a reason.
    // A control that vanishes is one the reader wonders about, and one that
    // silently does nothing is worse.
    main.setIdentityForTest([_]u8{0x8E} ** 32);
    main.setStoreForTest(&store);
    try testing.expect(main.muteBlockedReason() != null);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = them;
    var tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Mute") != null);

    // With a list in hand it becomes live, and reads back the state it is in.
    main.clearIdentityForTest();
    _ = try muteFixture(arena, &signer, &store, &.{}, "");
    try testing.expect(main.muteBlockedReason() == null);

    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, them, true));
    var model2 = main.initialModel();
    model2.stage = .ready;
    model2.viewing_profile = them;
    tree = try buildTree(arena, &model2);
    try testing.expect(findAnyText(tree.root, "Muted") != null);
}

test "a muted author's note is dropped on arrival, not just on a full read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetMutesForTest();
    defer main.forgetMutesForTest();

    const f = try FeedFixture.init(arena, "mutedsplice");
    defer f.deinit();

    var loud_signer = nostr.keys.Signer.init();
    defer loud_signer.deinit();
    const loud = try loud_signer.keyPairFromSecretKey([_]u8{0x91} ** 32);

    // Followed, so the arrival is one this feed is otherwise about, and muted.
    // BOTH set before the first tick: each of them invalidates the feed, and an
    // invalidated feed reads the whole window back, which is the other path and
    // the one already covered.
    const follows = [_][32]u8{ f.kp.public_key, loud.public_key };
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    const muted = [_][32]u8{loud.public_key};
    _ = main.setMutesForTest(&muted, 1_800_000_050);

    // One note on screen, so the NEXT tick takes the splice path rather than
    // reading the whole window back. That is the distinction this test is for:
    // the feed has two ways in and only one of them was covered.
    _ = try f.arrive(arena, 1_800_000_000, "before");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
    const before_splices = main.feedWork().splices;

    const shouted = try signedNote(arena, loud_signer, loud, 1_800_000_200, "from the muted one");
    _ = try main.plazaIngestForTest(arena, shouted);
    f.tick(1_800_000_300);

    // The splice ran, and it kept nothing.
    try testing.expect(main.feedWork().splices > before_splices);
    for (f.model.notes[0..f.model.notes_len]) |n| {
        try testing.expect(!std.mem.eql(u8, &n.pubkey, &loud.public_key));
    }
}

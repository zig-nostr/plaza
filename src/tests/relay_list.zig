//! Tests of relay_list.zig. The reader's own NIP-65 relay list: owning it, adopting it, and publishing it.

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

test "a newer relay list from another client is adopted, not refused" {
    // Ownership alone used to decide this, so the FIRST kind:10002 this app ever
    // adopted froze the pool for good: `saveRelays` recorded the owner and
    // nothing else, so every launch read the pool back as theirs and dropped
    // their real list before its stamp was ever looked at. Add a relay in Damus,
    // and the next badge press here republished Plaza's frozen copy at a stamp
    // built to win. Their own newer list lost to their own older one, silently.
    main.setIdentityForTest([_]u8{0x21} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();

    const first = [_]nostr.event.Tag{&.{ "r", "wss://first.example.com" }};
    var ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x21} ** 32,
        .created_at = 1_000,
        .kind = 10002,
        .tags = &first,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://first.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(i64, 1_000), main.relayListStampForTest());

    // The same list again, and an OLDER one: both refused, which is the property
    // the ownership check was there for.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    ev.created_at = 900;
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://first.example.com", main.relayUrlAt(0));

    // THE PROPERTY: a list they signed later, somewhere else, wins.
    const second = [_]nostr.event.Tag{&.{ "r", "wss://added-in-another-client.example.com" }};
    ev.tags = &second;
    ev.created_at = 2_000;
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://added-in-another-client.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(i64, 2_000), main.relayListStampForTest());
}

test "how new the saved pool is survives a restart" {
    // The refusal above is only worth anything if it holds across launches: the
    // file recorded WHOSE list it was and never WHEN, so every launch started
    // with a stamp of zero and the pool was frozen by whichever event landed
    // first. This drives the file's text rather than the disk, because the io is
    // not reachable from a test and the format is the part that can rot.
    main.setIdentityForTest([_]u8{0x22} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://saved.example.com", "read" }};
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x22} ** 32,
        .created_at = 1_700_000_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());

    var buf: [2048]u8 = undefined;
    const text = main.formatRelaysFileForTest(&buf).?;
    try testing.expect(std.mem.indexOf(u8, text, "stamp 1700000000") != null);

    // The relaunch: an empty pool, then the file read back.
    const saved = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(saved);
    main.clearRelaysForTest();
    try testing.expectEqual(@as(i64, 0), main.relayListStampForTest());
    main.applyRelaysFileForTest(saved);
    try testing.expectEqual(@as(i64, 1_700_000_000), main.relayListStampForTest());
    try testing.expectEqualStrings("wss://saved.example.com", main.relayUrlAt(0));

    // And the pool it read back refuses what it should and takes what it should.
    var older = ev;
    older.created_at = 1_600_000_000;
    main.stageOwnRelayListForTest(older);
    try testing.expect(!main.adoptRelayListForTest());
    var newer = ev;
    newer.created_at = 1_800_000_000;
    const newer_tags = [_]nostr.event.Tag{&.{ "r", "wss://changed-elsewhere.example.com" }};
    newer.tags = &newer_tags;
    main.stageOwnRelayListForTest(newer);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://changed-elsewhere.example.com", main.relayUrlAt(0));
}
test "a burst of relay edits publishes one list, not one per press" {
    // Walking a badge from R·W back to R·W is three presses for one decision.
    // Three replaceable events would be noise the reader's relays did not ask
    // for, so the edit settles and the last state is what goes out.
    main.resetRelaysForTest();
    main.clearRelayListPublishForTest();
    main.setIdentityForTest([_]u8{64} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    _ = main.addRelayForTest("wss://burst.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(!main.relayListDueForTest(1_000));

    main.relayListEditedForTest(1_000);
    // Still being pressed: nothing goes out yet.
    try testing.expect(!main.relayListDueForTest(1_000));
    main.relayListEditedForTest(1_001);
    try testing.expect(!main.relayListDueForTest(1_002));
    // Two seconds after the LAST press it is due, and it STAYS due: asking is
    // not what settles it. This used to be consumed by the question, which is
    // how an edit the publish then refused was lost for good.
    try testing.expect(main.relayListDueForTest(1_003));
    try testing.expect(main.relayListDueForTest(1_010));

    // The publish is what settles it, once, for the whole burst.
    var fx: main.EffectsForTest = undefined;
    main.flushRelayListForTest(&fx, 1_011);
    try testing.expect(!main.relayListPendingForTest());
    try testing.expect(!main.relayListDueForTest(1_020));

    // The file, though, is written on every edit: a crash must not lose one.
    main.relayListEditedForTest(2_000);
    try testing.expect(main.relayIsMineForTest());
}
test "the newest relay list wins, whatever order the relays answer in" {
    // kind:10002 is replaceable. Relays answer in whatever order they like, so
    // adopting the first arrival would let a slow relay holding last year's list
    // decide where this reader talks.
    const old_tags = [_]nostr.event.Tag{&.{ "r", "wss://old.example.com" }};
    const new_tags = [_]nostr.event.Tag{&.{ "r", "wss://new.example.com" }};
    const old_ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 1_000,
        .kind = 10002,
        .tags = &old_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    var new_ev = old_ev;
    new_ev.created_at = 2_000;
    new_ev.tags = &new_tags;

    // Old first, then new: the new one replaces it before either is installed.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(old_ev);
    main.stageOwnRelayListForTest(new_ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://new.example.com", main.relayUrlAt(0));

    // New first, then old: the old one is ignored.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(new_ev);
    main.stageOwnRelayListForTest(old_ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://new.example.com", main.relayUrlAt(0));
}
test "a relay list is not a note, so it never sits in the note queue" {
    // The queue's banner says "1 note did not go out". A kind:10002 in there
    // would make that sentence false, and the next edit republishes it anyway.
    try testing.expect(main.isReaderNoteForTest(1));
    try testing.expect(!main.isReaderNoteForTest(10002));
    try testing.expect(!main.isReaderNoteForTest(0));
}
test "the pool left behind by a sign-out is never published as the next account's list" {
    // The wipe this ownership record exists to stop, in order:
    //   1. signing out writes the BOOTSTRAP pool to ~/.plaza/relays
    //   2. the next launch reads that file back
    //   3. a bool called "these relays are mine" said yes
    //   4. so the account that signs in next has its real kind:10002 REFUSED
    //   5. and its first badge press publishes five default relays over it.
    // A list belongs to whoever was signed in when it was saved, so the record
    // is a pubkey, not a bool.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://their-real-relay.example.com" },
        &.{ "r", "wss://their-other-relay.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{31} ** 32,
        .created_at = 9_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };

    // Step 1 and 2: the bootstrap pool is in memory, as if just read from a file
    // written while signed out. It has no owner.
    main.resetRelaysForTest();
    try testing.expectEqual(@as(?[32]u8, null), main.relayOwnerForTest());

    // Step 3: signing in does NOT make that pool theirs.
    main.setIdentityForTest([_]u8{31} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(!main.relayListIsOwnedForTest());

    // Step 4: so their real list is adopted rather than refused.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://their-real-relay.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(usize, 2), main.relayCount());

    // And now it IS theirs, so a later stale event cannot undo it.
    try testing.expect(main.relayListIsOwnedForTest());
}

test "one account's saved relay list is not another account's" {
    // Two readers share a Mac. The first signs out, the second signs in. The
    // file on disk is the first one's, and must not silence the second's list.
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{41} ** 32);
    _ = main.addRelayForTest("wss://first-reader.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayListIsOwnedForTest());

    // The same pool, a different reader: not theirs.
    main.setIdentityForTest([_]u8{42} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(!main.relayListIsOwnedForTest());

    // Which means their own list is free to arrive.
    const tags = [_]nostr.event.Tag{&.{ "r", "wss://second-reader.example.com" }};
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{42} ** 32,
        .created_at = 9_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://second-reader.example.com", main.relayUrlAt(0));
}
test "editing a relay list does not grant permission to publish it" {
    // The hole this whole change exists to close, in its second disguise. An
    // edit claims the pool for the account, which is what stops a stale event
    // undoing it. Claiming is not reading: if an edit ALSO authorized its own
    // publish, the first badge press on a bootstrap pool would still replace a
    // real list nobody had looked at.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{61} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    // An edit: now owned.
    _ = main.addRelayForTest("wss://edited.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayListIsOwnedForTest());
    // But their own list is not here, so nothing goes out. Driving the real
    // publish, not just its predicates: "did not publish" IS the property, so a
    // test that only reads the flags proves nothing.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.publishRelayListForTest(&fx));

    // A key minted in this app moments ago has no history to lose, and that is
    // the ONE thing besides holding the list that opens the gate.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.publishRelayListForTest(&fx));
}

test "one relay's EOSE is not permission to replace a relay list" {
    // The gate used to be "some relay reached the end of its answer without
    // sending a kind:10002, so they have none". On a cold import the relays
    // being asked are the four this app was born with, which may hold none of
    // the reader's. Four clean answers coexisted with a twelve-relay list
    // somewhere else, and a single badge press published the four over it.
    //
    // There is nothing left to call: the flag and its setter are gone. What
    // this pins is the consequence, which is what a future gate would have to
    // keep true.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{63} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    _ = main.addRelayForTest("wss://bootstrap.example.com", true, true);
    main.markRelaysMineForTest();

    // Every relay in the pool has now finished answering. That is not evidence.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.canWriteRelayListForTest());
    try testing.expect(!main.publishRelayListForTest(&fx));
}
test "an edit that could not be published is still pending" {
    // The settle timer used to CONSUME the edit: it cleared the dirty flag and
    // handed the publish a chance it could refuse. An edit made before this
    // account's list had been read was refused, the flag was already gone, and
    // nothing tried again, so the edit lived on this machine and nowhere else
    // for the rest of the install.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{79} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    main.clearRelayListPublishForTest();

    _ = main.addRelayForTest("wss://typed-on-a-plane.example.com", true, true);
    main.markRelaysMineForTest();
    main.relayListEditedForTest(1_000);

    // Two seconds later the tick fires and the publish is refused.
    var fx: main.EffectsForTest = undefined;
    main.flushRelayListForTest(&fx, 1_003);
    try testing.expect(main.relayListPendingForTest());

    // The reason clears, and the same edit goes out without another press.
    main.setIdentityMintedForTest(true);
    main.flushRelayListForTest(&fx, 1_004);
    try testing.expect(!main.relayListPendingForTest());
}

test "a relay list after one the store refused is stamped past it" {
    // The stamp was only past the stored list. Built on a list that went out
    // and was not stored, it took that list's stamp, and the two tied on every
    // relay.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6e} ** 32);
    var fs: harness.FreshStore = undefined;
    try fs.open("relaystamp");
    defer fs.close();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();
    main.forgetRelayRemovalsForTest();
    main.setIdentityForTest([_]u8{0x6e} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.failIngestForTest(false);
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://one.example.com" }};
    const stored = try nostr.event.create(arena, signer, kp, 1_900_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, stored, signer);
    _ = main.addRelayForTest("wss://one.example.com", true, true);
    main.markRelaysMineForTest();
    var fx: main.EffectsForTest = undefined;

    main.failIngestForTest(true);
    try testing.expect(main.publishRelayListForTest(&fx));
    main.failIngestForTest(false);
    const first = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expect(main.heldOwnRecordForTest(10002));

    _ = main.addRelayForTest("wss://two.example.com", true, true);
    main.forgetLastPublishedForTest();
    try testing.expect(main.publishRelayListForTest(&fx));
    const second = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expect(second.created_at > first.created_at);
}

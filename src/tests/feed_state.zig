//! Tests of feed_state.zig. The feed's working state: arrivals, rebuild work, note storage, and the since stamps.

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
const FreshStore = harness.FreshStore;
const articleStore = harness.articleStore;
const auth_test_url = harness.auth_test_url;
const backText = harness.backText;
const buildTree = harness.buildTree;
const challengeAndRefuse = harness.challengeAndRefuse;
const countByLabel = harness.countByLabel;
const countNoteRows = harness.countNoteRows;
const countPressesOf = harness.countPressesOf;
const expectKeyboardReach = harness.expectKeyboardReach;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const frameOfText = harness.frameOfText;
const isDescendantOf = harness.isDescendantOf;
const modalCardIndex = harness.modalCardIndex;
const modalDialogIndex = harness.modalDialogIndex;
const modal_cases = harness.modal_cases;
const noteContext = harness.noteContext;
const oneNoteFeed = harness.oneNoteFeed;
const openFullSettings = harness.openFullSettings;
const pressMsgById = harness.pressMsgById;
const seedAuthorNotes = harness.seedAuthorNotes;
const seedRelayLists = harness.seedRelayLists;
const signInNothingFound = harness.signInNothingFound;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

const geometry = native_sdk.geometry;
/// A NIP-18 repost of `target`, tagged the way this app writes them.
fn signedRepost(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    created_at: i64,
    target: nostr.event.Event,
    content: []const u8,
) !nostr.event.Event {
    const id_hex = try std.fmt.allocPrint(arena, "{x}", .{target.id});
    const author_hex = try std.fmt.allocPrint(arena, "{x}", .{target.pubkey});
    // Allocated, not `&[_][]const u8{...}` inline in an array literal: those are
    // temporaries, and the `Tag` slices pointing at them dangle by the time the
    // store encodes the event. It shows up as a nonsense tag length inside
    // `encodeEvent` rather than as anything that names this line.
    const e_tag = try arena.dupe([]const u8, &.{ "e", id_hex, "", author_hex });
    const p_tag = try arena.dupe([]const u8, &.{ "p", author_hex });
    const tags = try arena.alloc(nostr.event.Tag, 2);
    tags[0] = e_tag;
    tags[1] = p_tag;
    return nostr.event.create(arena, signer, kp, created_at, main.repost_kind, tags, content, null);
}
test "a repost by a follow shows the note it points at, named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const me = try signer.keyPairFromSecretKey([_]u8{0x61} ** 32);
    const author = try signer.keyPairFromSecretKey([_]u8{0x62} ** 32);
    main.setIdentityForTest([_]u8{0x61} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/repost.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const note = try signedNote(arena, signer, author, 1_800_000_000, "the original words");
    _ = try store.ingest(arena, note, .{});
    const boost = try signedRepost(arena, signer, me, 1_800_000_100, note, "");
    _ = try store.ingest(arena, boost, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_200);

    // One row, and it is the REPOSTED note: its id, its author, its words. That
    // is what makes the counts under it belong to the note rather than to the
    // wrapper, because engagement is already keyed on `event_id`.
    try testing.expectEqual(@as(usize, 1), model.notes_len);
    const row = model.notes[0];
    try testing.expectEqualSlices(u8, &note.id, &row.event_id);
    try testing.expectEqualSlices(u8, &author.public_key, &row.pubkey);
    try testing.expectEqualStrings("the original words", row.content());
    try testing.expect(row.has_reposter);
    try testing.expectEqualSlices(u8, &me.public_key, &row.reposter);
}

test "a note already in the feed is not drawn again by a repost of it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const me = try signer.keyPairFromSecretKey([_]u8{0x63} ** 32);
    main.setIdentityForTest([_]u8{0x63} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/dedup.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // My own note, and my own repost of it: the note is in the window under its
    // own name already.
    const note = try signedNote(arena, signer, me, 1_800_000_000, "said once");
    _ = try store.ingest(arena, note, .{});
    const boost = try signedRepost(arena, signer, me, 1_800_000_100, note, "");
    _ = try store.ingest(arena, boost, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_200);

    try testing.expectEqual(@as(usize, 1), model.notes_len);
    try testing.expectEqualStrings("said once", model.notes[0].content());
}

test "a repost whose note nobody has draws no row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const me = try signer.keyPairFromSecretKey([_]u8{0x64} ** 32);
    const author = try signer.keyPairFromSecretKey([_]u8{0x65} ** 32);
    main.setIdentityForTest([_]u8{0x64} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/missing.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // The wrapper is stored, the note it points at is not. A row drawn from the
    // wrapper alone would be the reposter's name over an empty body, which is
    // the thing being avoided. Notedeck drops the row for the same reason.
    const note = try signedNote(arena, signer, author, 1_800_000_000, "never stored");
    const boost = try signedRepost(arena, signer, me, 1_800_000_100, note, "");
    _ = try store.ingest(arena, boost, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_200);
    try testing.expectEqual(@as(usize, 0), model.notes_len);
}
test "an unchanged note is reused across rebuilds, not re-parsed" {
    main.resetProfilesForTest();
    main.resetMediaForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{51} ** 32);
    // The feed scopes to the follow set plus the signed-in user; BE the user.
    main.setIdentityForTest([_]u8{51} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/reuse.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "the original text");
    _ = try store.ingest(arena, ev, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_100);
    try testing.expectEqual(@as(usize, 1), model.notes_len);

    // Plant a sentinel: if the next rebuild re-parses this note, the store's
    // content overwrites it; if the card is reused, it survives.
    const sentinel = "SENTINEL";
    @memcpy(model.notes[0].content_buf[0..sentinel.len], sentinel);
    model.notes[0].content_len = sentinel.len;

    // A second note arrives: the old card must carry over by id untouched.
    const ev2 = try signedNote(arena, signer, kp, 1_800_000_050, "another note");
    _ = try store.ingest(arena, ev2, .{});
    main.reconcileForTest(&model, &store, 1_800_000_100);

    try testing.expectEqual(@as(usize, 2), model.notes_len);
    var found_sentinel = false;
    for (model.notes[0..model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) found_sentinel = true;
    }
    try testing.expect(found_sentinel);

    // A profile gaining a name moves the generation, which forces a re-parse
    // (mention labels are baked into content), replacing the sentinel.
    var meta_buf: [128]u8 = undefined;
    const meta = try std.fmt.bufPrint(&meta_buf, "{{\"name\":\"reuse-test\"}}", .{});
    const kind0 = try nostr.event.create(arena, signer, kp, 1_800_000_060, 0, &.{}, meta, null);
    _ = try store.ingest(arena, kind0, .{});
    main.reconcileForTest(&model, &store, 1_800_000_100);

    var still_there = false;
    for (model.notes[0..model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) still_there = true;
    }
    try testing.expect(!still_there);
}

test "a kind:0 event is parsed once, not every reconcile" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{53} ** 32);
    // Profile queries scope to the follow set plus the signed-in user.
    main.setIdentityForTest([_]u8{53} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/meta.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const kind0 = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &.{}, "{\"name\":\"once\"}", null);
    _ = try store.ingest(arena, kind0, .{});

    var model = main.initialModel();
    main.reconcileForTest(&model, &store, 1_800_000_100);

    // Corrupt the cached name; an unchanged kind:0 must NOT overwrite it (the
    // parse is skipped), which is what proves the guard.
    const p = main.upsertProfile(kp.public_key).?;
    try testing.expectEqualStrings("once", p.name_buf[0..p.name_len]);
    p.name_buf[0] = 'X';
    main.reconcileForTest(&model, &store, 1_800_000_100);
    try testing.expectEqualStrings("Xnce", p.name_buf[0..p.name_len]);

    // A NEWER kind:0 replaces it and is parsed.
    const newer = try nostr.event.create(arena, signer, kp, 1_800_000_500, 0, &.{}, "{\"name\":\"twice\"}", null);
    _ = try store.ingest(arena, newer, .{});
    main.reconcileForTest(&model, &store, 1_800_000_600);
    try testing.expectEqualStrings("twice", p.name_buf[0..p.name_len]);
}
test "an article opened from Notifications names Notifications on its Back" {
    // The article reader draws its own header, and it worked its Back label out
    // by itself: the level underneath, else the feed's name. Opened from a row in
    // Notifications, Back returns to the sheet, so the label has to come from the
    // one place that knows that.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6b} ** 32);
    main.setIdentityForTest([_]u8{0x6c} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "article-back");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "from-the-sheet" },
        &[_][]const u8{ "title", "An article somebody mentioned me in" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "Some words.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    model.notifications_open = true;
    main.update(&model, Msg{ .open_event = ev.id }, &fx);
    try testing.expectEqual(@as(u16, 30023), model.thread_root.kind);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root) orelse return error.NoBack);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);
}
test "a signed-in feed carries no guest affordances" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{61} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    try testing.expect(!model.is_guest());

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);
    try testing.expect(findAnyText(tree.root, "Guest") == null);
}
test "building the feed does not read the contact list once per card" {
    // `followBlockedReason` is called from `noteContextItems`, which every note
    // card builds for its right-click menu. It asked `haveOwnContactList`, which
    // ran an LMDB query and then duplicated the whole record: every tag, every
    // field, each its own page_allocator call, which is its own mmap, and an
    // munmap apiece to free.
    //
    // With three hundred follows that is roughly six hundred syscalls per card
    // per frame. A stack sample of a scroll put 1437 of 1462 app-side samples
    // inside `noteContextItems`; the frame rebuild measured 22.7 ms against an
    // 8.3 ms frame, so the feed ran at about nine frames a second, and it got
    // WORSE the more people you followed.
    //
    // Counting the reads rather than timing the build, because the property is
    // the shape ("not once per card"), and a stopwatch on a CI runner is a poor
    // way to say that.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x9c} ** 32);
    main.setIdentityForTest([_]u8{0x9c} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnListMemoForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cards.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // A real-sized contact list: three hundred people, which is an ordinary
    // number and the one the slowdown was reported at.
    var tag_storage: [300][2][]const u8 = undefined;
    var tags: [300]nostr.event.Tag = undefined;
    var hexes: [300][64]u8 = undefined;
    for (0..300) |i| {
        var pk: [32]u8 = undefined;
        @memset(&pk, @intCast(i % 251 + 1));
        _ = std.fmt.bufPrint(&hexes[i], "{x}", .{pk}) catch unreachable;
        tag_storage[i] = .{ "p", &hexes[i] };
        tags[i] = &tag_storage[i];
    }
    const list = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, list, signer);

    // A feed longer than the viewport, so the window builds a real number of
    // cards. Written by SOMEBODY ELSE, which is what a feed is: the follow line
    // in a card's menu short-circuits to "This is you" on your own notes, so a
    // feed of your own would never reach the question this test is about. It
    // did, at first, and the reverted-fix check is what caught it.
    var other = nostr.keys.Signer.init();
    defer other.deinit();
    const other_kp = try other.keyPairFromSecretKey([_]u8{0x9d} ** 32);
    const ev = try signedNote(arena, other, other_kp, 1_800_000_000, "a note in a long feed");
    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    for (0..200) |i| {
        model.notes[i] = main.noteFrom(ev, 1_800_000_000);
        model.notes[i].id = @intCast(i + 1);
    }
    model.notes_len = 200;

    // Warm whatever the first build legitimately reads once, then count.
    _ = try buildTree(arena, &model);
    main.resetOwnRecordReadsForTest();
    const tree = try buildTree(arena, &model);
    const cards = countNoteRows(tree.root);
    try testing.expect(cards > 4);

    // THE PROPERTY. Not "few reads": NONE. Building a view is not a question the
    // store should be asked, and once it is asked once per card the number rises
    // with the viewport and with the size of the list being copied.
    const reads = main.ownRecordReadsForTest();
    if (reads != 0) {
        std.debug.print("\nfeed build read the whole contact list {d} times for {d} cards\n", .{ reads, cards });
    }
    try testing.expectEqual(@as(usize, 0), reads);
}
test "the name beat forwards the tags it read, the same as the sheet's save" {
    // The beat only arms on a key this app just minted, which has no kind:0 and
    // therefore no NIP-39 proofs to lose, so this is a landmine rather than a
    // live loss: `publishName` read the stored profile and then handed the write
    // seam `&.{}`. Its own doc comment says one path exists so the destructive
    // shape cannot come back, and this is the half of the shape that was still
    // there. Driving the whole write, because the merge helper never sees a tag.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5b} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/namebeat.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.setIdentityForTest([_]u8{0x5b} ** 32);
    defer main.clearIdentityForTest();

    const tags = [_]nostr.event.Tag{
        &.{ "i", "github:someone", "a-proof-url" },
        &.{ "i", "mastodon:someone@example.social", "another-proof" },
    };
    const before = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &tags, "{\"about\":\"kept\"}", null);
    _ = try main.plazaIngestVerifiedForTest(arena, before, signer);

    var model = main.initialModel();
    model.name_buffer.set("Bob");
    var fx: main.EffectsForTest = undefined;
    main.publishNameForTest(&model, &fx);

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 0).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "github:someone") != null);
    try testing.expect(std.mem.indexOf(u8, written, "mastodon:someone@example.social") != null);
}
test "the name beat says so when it cannot build the write, and sends nothing" {
    // Out of memory in the merge or the tag copy used to return true, so the
    // caller said "Name set" for a name nothing had been sent for. Every
    // allocation the build makes is failed in turn, with a stored profile that
    // has tags so both the merge and the tag copy are reached.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5d} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/namefail.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.setIdentityForTest([_]u8{0x5d} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    const tags = [_]nostr.event.Tag{
        &.{ "i", "github:someone", "a-proof-url" },
        &.{ "i", "mastodon:someone@example.social", "another-proof" },
    };
    const before = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &tags, "{\"about\":\"kept\"}", null);
    _ = try main.plazaIngestVerifiedForTest(arena, before, signer);

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    var fail_index: usize = 0;
    var refused: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        model.name_buffer.set("Bob");
        model.toast_len = 0;
        var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = fail_index });
        if (main.publishNameWithForTest(&model, &fx, failing.allocator())) break;
        refused += 1;
        try testing.expectEqualStrings("Name not set. Try again.", model.toast_text());
        try testing.expectEqualStrings("Bob", model.name_buffer.text());
        try testing.expect(main.lastPublishedForTest() == null);
    }
    // Both the merge and the tag copy were refused before one went through.
    try testing.expect(refused >= 2);
    try testing.expect(fail_index < 64);
    try testing.expect(main.lastPublishedForTest() != null);
}
test "the name beat waits for a busy signer and says so" {
    // It signed without asking, and said "Name set" for a name a busy signer
    // never took.
    main.setIdentityForTest([_]u8{0x5c} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var model = main.initialModel();
    model.naming = true;
    model.name_buffer.set("Bob");
    var fx: main.EffectsForTest = undefined;

    main.holdHelperSignForTest();
    main.update(&model, .name_save, &fx);
    try testing.expectEqualStrings(main.signer_busy_toast, model.toast_text());
    try testing.expect(model.naming);
    try testing.expectEqualStrings("Bob", model.name_buffer.text());
    try testing.expect(main.lastPublishedForTest() == null);

    main.releaseHelperSignForTest();
    main.update(&model, .name_save, &fx);
    try testing.expectEqualStrings("Name set", model.toast_text());
    try testing.expect(!model.naming);
    const out = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqual(@as(u16, 0), out.kind);
}

test "a replaced relay list is kept, and can be read back" {
    // The store enforces replaceable semantics the way relays do:
    // `ingestReplaceable` DELETES the superseded event in the same transaction.
    // That is right for other people's records and wrong for ours, because the
    // version being destroyed may be the one the reader wants back. A copy
    // nothing can read is not a copy, so this test reads it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{77} ** 32);
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/backup.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const first_tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com" },
        &.{ "r", "wss://two.example.com" },
    };
    const first = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &first_tags, "", null);
    _ = try main.plazaIngestForTest(arena, first);

    // The replacement. This is the moment the first one is destroyed.
    const second_tags = [_]nostr.event.Tag{&.{ "r", "wss://replacement.example.com" }};
    const second = try nostr.event.create(arena, signer, kp, 1_800_000_100, 10002, &second_tags, "", null);
    _ = try main.plazaIngestForTest(arena, second);

    // The store holds only the new one, exactly as a relay would.
    const kinds = [_]u16{10002};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 10 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    try testing.expect(std.mem.indexOf(u8, result.events[0].tags[0][1], "replacement") != null);

    // And the one it replaced is still here, in full, readable.
    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://one.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://two.example.com") != null);
    // It is the real event, not a summary: it can be republished as-is.
    try testing.expect(std.mem.indexOf(u8, backup, "\"sig\"") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "\"kind\":10002") != null);
}

test "the backup keeps a few versions, not a history" {
    // The store's KV has no cursor and no delete, so a growing key scheme could
    // never be read back or pruned. One rewritten key holding the last few is
    // the only shape that is both readable and bounded.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{78} ** 32);
    main.setIdentityForTest([_]u8{78} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/keep.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var i: i64 = 0;
    while (i < 6) : (i += 1) {
        const url = try std.fmt.allocPrint(arena, "wss://v{d}.example.com", .{i});
        const tags = [_]nostr.event.Tag{&.{ "r", url }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + i, 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }

    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    // The most recent replacements are here.
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v4.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v3.example.com") != null);
    // The oldest are not: this is a way back from the last mistake, not an
    // archive that grows inside the feed's database forever.
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v0.example.com") == null);
    var lines = std.mem.tokenizeScalar(u8, backup, '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try testing.expect(count <= 3);
}

test "someone else's replaced list is not backed up" {
    // The backup exists because losing OUR list is unrecoverable. Another
    // author's kind:0 is re-fetchable from any relay, and keeping every one
    // would fill the reader's disk with other people's history.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const mine = try signer.keyPairFromSecretKey([_]u8{79} ** 32);
    const theirs = try signer.keyPairFromSecretKey([_]u8{80} ** 32);
    main.setIdentityForTest([_]u8{79} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/theirs.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    _ = mine;

    const a = try nostr.event.create(arena, signer, theirs, 1_800_000_000, 0, &.{}, "{\"name\":\"old\"}", null);
    _ = try main.plazaIngestForTest(arena, a);
    const b = try nostr.event.create(arena, signer, theirs, 1_800_000_100, 0, &.{}, "{\"name\":\"new\"}", null);
    _ = try main.plazaIngestForTest(arena, b);

    try testing.expect(main.ownListBackups(testing.allocator, 0) == null);
}
test "a relay list is spliced onto the one the reader published" {
    // The publish used to build the whole event out of the pool, which holds
    // eight. A reader with thirteen relays had five deleted from their NIP-65
    // list by one badge press, along with every tag type this app does not
    // model. The event is now what they published, plus what they changed here.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{77} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/splice.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.forgetRelayRemovalsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    // Their real list: more relays than the pool has seats, plus a tag this app
    // has never heard of. The store is the only thing that can hold it, because
    // the pool structurally cannot.
    const published = [_]nostr.event.Tag{
        &.{ "r", "wss://kept-1.example.com" },
        &.{ "r", "wss://kept-2.example.com" },
        &.{ "r", "wss://kept-3.example.com" },
        &.{ "r", "wss://kept-4.example.com" },
        &.{ "r", "wss://kept-5.example.com" },
        &.{ "r", "wss://kept-6.example.com" },
        &.{ "r", "wss://kept-7.example.com" },
        &.{ "r", "wss://kept-8.example.com" },
        &.{ "r", "wss://overflow-9.example.com" },
        &.{ "r", "wss://overflow-10.example.com", "read" },
        &.{ "unmodelled", "something this app does not read" },
    };
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &published, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    // The pool as the app would hold it: the first eight, which is all it can.
    for (published[0..8]) |tag| _ = main.addRelayForTest(tag[1], true, true);
    main.markRelaysMineForTest();

    // One badge press, then the publish it settles into.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.publishRelayListForTest(&fx));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10002).?;
    defer testing.allocator.free(written);
    // The eight the pool holds.
    try testing.expect(std.mem.indexOf(u8, written, "kept-1.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "kept-8.example.com") != null);
    // THE PROPERTY: the two the pool had no seat for are still in their list,
    // with their markers, and so is the tag this app does not model.
    try testing.expect(std.mem.indexOf(u8, written, "overflow-9.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "overflow-10.example.com read") != null);
    try testing.expect(std.mem.indexOf(u8, written, "unmodelled") != null);
}
test "the store decides what a replacement is, not the backup" {
    // NIP-01 breaks a created_at tie on the id, and the store implements it. The
    // backup used to make its own call with `previous.created_at >= ev.created_at`
    // and so skipped the copy for exactly the case where the store DID replace:
    // equal stamps, lower id. Deciding after the store has spoken removes the
    // second opinion entirely.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{89} ** 32);
    main.setIdentityForTest([_]u8{89} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/tie.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Two events at the SAME second, differing only in content, so their ids
    // differ and one of them is lexicographically lower.
    const a_tags = [_]nostr.event.Tag{&.{ "r", "wss://aaa.example.com" }};
    const b_tags = [_]nostr.event.Tag{&.{ "r", "wss://bbb.example.com" }};
    const a = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &a_tags, "", null);
    const b = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &b_tags, "", null);

    // Ingest the one that will LOSE the tie first, so the other replaces it.
    const first = if (std.mem.order(u8, &a.id, &b.id) == .lt) b else a;
    const second = if (std.mem.order(u8, &a.id, &b.id) == .lt) a else b;
    _ = try main.plazaIngestVerifiedForTest(arena, first, signer);
    const result = try main.plazaIngestVerifiedForTest(arena, second, signer);
    try testing.expectEqual(nostr.store.IngestResult.replaced, result);

    // The store destroyed a version, so a copy of it exists.
    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    const lost_url: []const u8 = if (std.mem.eql(u8, &first.id, &a.id)) "aaa.example.com" else "bbb.example.com";
    try testing.expect(std.mem.indexOf(u8, backup, lost_url) != null);
}

test "following writes the newest known list plus the change, and nothing else moves" {
    // A contact list is REPLACEABLE: publishing one replaces who this reader
    // follows, on every relay, at once. So a follow is the list they already
    // have plus one name, and everything that list carried comes back with it:
    // the petnames and relay hints on other people's p tags, tag types this app
    // does not model, and the content blob, which on older clients is a relay
    // map and on none of them is ours to discard.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{91} ** 32);
    main.setIdentityForTest([_]u8{91} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/follow.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Their real list: two follows, one with a petname and a relay hint, plus a
    // tag type this app has never heard of and a content blob.
    const alice = "aa" ** 32;
    const bob = "bb" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "p", alice, "wss://alice-relay.example.com", "Alice" },
        &.{ "p", bob },
        &.{ "t", "some-future-thing" },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "{\"wss://legacy.example.com\":{\"read\":true}}", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.noteOwnContactsAnsweredForTest(kp.public_key);

    // Follow a third person.
    var carol: [32]u8 = undefined;
    @memset(&carol, 0xcc);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, carol, true));

    // The published list is the old one plus Carol.
    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    const published = result.events[0];

    var saw_alice_petname = false;
    var saw_bob = false;
    var saw_carol = false;
    var saw_unknown_tag = false;
    for (published.tags) |tag| {
        if (tag.len >= 4 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], alice)) {
            // The petname and the relay hint travelled with it.
            if (std.mem.eql(u8, tag[3], "Alice") and std.mem.eql(u8, tag[2], "wss://alice-relay.example.com")) saw_alice_petname = true;
        }
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], bob)) saw_bob = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], "cc" ** 32)) saw_carol = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "t")) saw_unknown_tag = true;
    }
    try testing.expect(saw_alice_petname);
    try testing.expect(saw_bob);
    try testing.expect(saw_carol);
    try testing.expect(saw_unknown_tag);
    // And the legacy relay map in the content is still there.
    try testing.expect(std.mem.indexOf(u8, published.content, "legacy.example.com") != null);
    // Stamped past the one it replaced, or every relay drops it in silence.
    try testing.expect(published.created_at > 1_800_000_000);
}

test "unfollowing removes exactly one name" {
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{92} ** 32);
    main.setIdentityForTest([_]u8{92} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/unfollow.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const tags = [_]nostr.event.Tag{
        &.{ "p", "aa" ** 32 },
        &.{ "p", "bb" ** 32 },
        &.{ "p", "cc" ** 32 },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.noteOwnContactsAnsweredForTest(kp.public_key);

    var bob: [32]u8 = undefined;
    @memset(&bob, 0xbb);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, bob, false));

    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var count: usize = 0;
    var saw_bob = false;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p")) {
            count += 1;
            if (std.mem.eql(u8, tag[1], "bb" ** 32)) saw_bob = true;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(!saw_bob);
}
test "a full follow list rebuilds the feed fast enough to do it every second" {
    // The store opens ONE LMDB cursor per author and then, for every event it
    // emits, linearly picks the newest across all live streams. Its own comment
    // says "stream counts are small". That is true at nine and the reason this
    // test exists: the feed rebuilds whenever the store's event count moves,
    // which the live pool makes about once a second, so a linear-per-event pick
    // over a full follow list is a frame hitch the reader feels rather than a
    // number in a benchmark.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{99} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/perf.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // A full list, each with a handful of notes, which is the shape a real
    // reader's feed has.
    const follows = 128;
    var list: [follows][32]u8 = undefined;
    var i: usize = 0;
    while (i < follows) : (i += 1) {
        var secret: [32]u8 = undefined;
        @memset(&secret, @intCast((i % 200) + 1));
        secret[31] = @intCast(i & 0xff);
        secret[30] = @intCast((i >> 8) & 0xff);
        const kp = signer.keyPairFromSecretKey(secret) catch continue;
        list[i] = kp.public_key;
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            const body = try std.fmt.allocPrint(arena, "note {d} from {d}", .{ n, i });
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i * 10 + n)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    try testing.expectEqual(@as(usize, follows), main.followSetForTest().len);

    var model = main.initialModel();
    model.stage = .ready;
    // One rebuild to warm the page cache, then time a run of them.
    main.reconcileForTest(&model, &store, 1_800_002_000);
    try testing.expect(model.notes_len > 0);

    // `std.time.Timer` is gone in 0.16; the awake clock is what the app itself
    // times relay round trips with.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const started = std.Io.Timestamp.now(io, .awake);
    const rounds = 10;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        main.invalidateFeedForTest();
        main.reconcileForTest(&model, &store, 1_800_002_000);
    }
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    const per_rebuild_ns = @as(u64, @intCast(@max(elapsed.toNanoseconds(), 0))) / rounds;

    // The budget is one frame at 60Hz, which is the honest bar: this runs on
    // the UI thread on a timer, so anything slower is a visible stutter every
    // second rather than a slow benchmark. Generous enough not to be flaky on a
    // loaded CI box, tight enough to catch the cliff.
    const budget_ns = 16 * std.time.ns_per_ms;
    std.debug.print("\n[perf] {d} follows: {d}us per feed rebuild (budget {d}us)\n", .{ follows, per_rebuild_ns / 1000, budget_ns / 1000 });
    if (per_rebuild_ns > budget_ns) {
        std.debug.print(
            "\nfeed rebuild with {d} follows took {d}us, budget {d}us\n",
            .{ follows, per_rebuild_ns / 1000, budget_ns / 1000 },
        );
        return error.FeedRebuildTooSlow;
    }
}
test "one yes starts one list, and a later empty read is refused rather than a second start" {
    defer main.resetOutboxForTest();
    var fs: FreshStore = undefined;
    try fs.open("oneyes");
    defer fs.close();
    _ = signInNothingFound(0x78);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = [_]u8{0x5c} ** 32;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .mute_person = 1 }, &fx);
    main.update(&model, .fresh_list_confirm, &fx);
    const muted = main.ownRecordTagsJoinedForTest(testing.allocator, 10000) orelse return error.NothingWritten;
    testing.allocator.free(muted);
    try testing.expect(!main.noHistoryKnownForTest(.mutes));

    // The store cannot be read for a moment. The list started a second ago is
    // still out there; a write now would replace it with a list of one.
    main.setStoreForTest(null);
    defer main.setStoreForTest(&fs.store);
    try testing.expectEqual(main.MuteWrite.no_list_yet, main.writeMuteForTest(&fx, [_]u8{0x5b} ** 32, true));
}
test "the follow splice matches on the p tag, not on any tag carrying that value" {
    // Amethyst's unfollow filters on tag[1] == pubkey without checking tag[0],
    // so it silently deletes an unrelated tag that happens to carry the same
    // value, and drops short tags like the ["-"] protected marker entirely.
    // Not copying that.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{108} ** 32);
    main.setIdentityForTest([_]u8{108} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/splice.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const victim = "cc" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", victim },
        // A different tag type carrying the same value, and a one-element tag.
        &.{ "e", victim },
        &.{"-"},
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);

    var target: [32]u8 = undefined;
    @memset(&target, 0xcc);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, target, false));

    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var saw_e = false;
    var saw_short = false;
    var saw_p_victim = false;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "e")) saw_e = true;
        if (tag.len == 1 and std.mem.eql(u8, tag[0], "-")) saw_short = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], victim)) saw_p_victim = true;
    }
    // The person is gone; the unrelated tag and the short marker are not.
    try testing.expect(!saw_p_victim);
    try testing.expect(saw_e);
    try testing.expect(saw_short);
}
test "walking somewhere from the sheet closes the sheet" {
    main.setIdentityForTest([_]u8{0xE7} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetInboxForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = [_]u8{0x44} ** 32 }, &fx);
    // Otherwise the person opens UNDERNEATH a sheet still covering the screen,
    // and the press reads as having done nothing at all.
    try testing.expect(!model.notifications_open);
    try testing.expect(model.viewing_profile != null);
}
test "the account menu offers no way to sign out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The chip this menu hangs off says how many relays are answering and
    // whether the signer is up. Ending the session is not that, and this row
    // never ended one anyway: it opened Settings with the confirmation showing,
    // which is where the control lives and where it stays.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .account;

    const p = try painted.Painted.render(arena, &model);
    // The row that stays, so a menu that failed to open cannot pass this.
    try testing.expect(findAnyText(p.tree.root, "Settings…") != null);
    if (findAnyText(p.tree.root, "Sign out") != null) {
        std.debug.print("the account menu still offers Sign out\n", .{});
        return error.SignOutStillThere;
    }
}
test "a suppressed npub does not shove the line beside it out of true" {
    // The npub row stands down for a nameless person. If it stands down by
    // becoming a zero-width spacer, the row's gap is still charged for it and
    // "follows you" lands 8px inside the left rule that the name, bio, links and
    // counts all share. `handleLine` documents that trap for the note row; this
    // is the profile card walking into it.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.setIdentityForTest([_]u8{0x4D} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/follows.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Somebody with a contact list naming me and NO kind:0 at all. A real state,
    // not a contrived one: the two arrive as separate events, and a profile that
    // only ever set a picture never gets a name.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x51} ** 32);
    var me_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&me_hex, "{x}", .{&me}) catch unreachable;
    const tags = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    const contacts = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, contacts);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = kp.public_key }, &fx);

    const p = try painted.Painted.render(arena, &model);
    const follows = frameOfText(p, "follows you") orelse return error.NoFollowsLine;
    // The npub appears twice: the header band centres it, and the card's name
    // line carries it. The card's is the lower one, and it is the left rule that
    // matters here.
    const short = main.npubShortForTest(arena, kp.public_key);
    var name: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.text, short)) continue;
        if (name == null or node.widget.frame.y > name.?.y) name = node.widget.frame;
    }
    const name_line = name orelse return error.NoNameLine;
    // Same left rule, to within a hair of rounding.
    if (@abs(follows.x - name_line.x) > 1.0) {
        std.debug.print("\"follows you\" starts at x={d}, the name line at x={d}\n", .{ follows.x, name_line.x });
        return error.OutOfTrue;
    }
}
test "every press on every screen can be reached and fired from the keyboard" {
    // The overflow sweep above visits sixteen screens as a guest. This visits the
    // ones a signed-in reader sees as well, because most of them are built by
    // different code: the composer, the notifications page, the profile editor,
    // the sheets that only open for somebody with a key. A guard that only ever
    // looked at the guest feed would pass with half the app unreachable.
    const States = enum { feed, feed_no_reply_verb, thread, thread_nested, thread_no_reply_verb, own_profile, other_profile, bookmarks, settings, settings_editing, notifications, notifications_empty, composing, naming, address, joining, bunker, deleting, menu_scope, menu_relays, menu_account, relay_auth, relays_paused };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/keys.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = [_]u8{0x2f} ** 32;
    inline for (@typeInfo(States).@"enum".fields) |f| {
        const st: States = @enumFromInt(f.value);
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Signed in, except where the screen is the guest's.
        if (st == .joining or st == .bunker) main.clearIdentityForTest() else main.setIdentityForTest(me);
        defer main.clearIdentityForTest();
        // A reader can take the Reply verb away, and it is the keyboard's usual
        // way into a thread, so those screens are walked without it as well.
        main.setHidden(.replies, st == .feed_no_reply_verb or st == .thread_no_reply_verb);
        defer main.setHidden(.replies, false);
        defer main.resetInboxForTest();
        main.resetPlacesForTest();
        main.resetProfilesForTest();
        main.clearRelaysForTest();
        _ = main.addRelayForTest("wss://relay.example.org", true, true);
        main.seedInboxUnreadForTest(if (st == .notifications_empty) 0 else 3);
        // A relay that refused something until the reader identifies to it,
        // whose question sits above the feed with an Allow and a Don't allow.
        main.resetRelayAuthForTest();
        defer main.resetRelayAuthForTest();
        var auth_index: ?usize = null;
        if (st == .relay_auth) {
            auth_index = main.addRelayForTest(auth_test_url, true, true) orelse return error.NoSeat;
            var sess = main.AuthSessionForTest{ .index = auth_index.? };
            challengeAndRefuse(&sess, auth_test_url, "chal-keys", 0);
        }

        const model = try arena.create(main.Model);
        model.* = main.initialModel();
        model.stage = .ready;
        model.notes[0] = main.noteWithLinkForTest("https://example.com/a");
        model.notes_len = 1;
        switch (st) {
            .feed, .feed_no_reply_verb, .notifications_empty => {},
            .thread => {
                model.viewing_thread = model.notes[0].id;
                model.thread_root = model.notes[0];
                model.thread_notes[0] = model.notes[0];
                model.thread_notes_len = 1;
            },
            // A reply with a reply of its own, which draws as a nested row
            // with no verbs under it.
            .thread_nested, .thread_no_reply_verb => {
                model.viewing_thread = model.notes[0].id;
                model.thread_root = model.notes[0];
                model.thread_root.event_id = [_]u8{0xAA} ** 32;
                model.thread_notes[0] = threadNote(0xB1, 200, 0xAA);
                model.thread_notes[0].id = 61;
                model.thread_notes[1] = threadNote(0xC1, 300, 0xB1);
                model.thread_notes[1].id = 62;
                model.thread_notes_len = 2;
                main.arrangeThread(model.thread_notes[0..2], model.thread_root.event_id);
            },
            .own_profile => model.viewing_profile = me,
            .other_profile => model.viewing_profile = model.notes[0].pubkey,
            .bookmarks => model.viewing_bookmarks = true,
            .settings => model.stage = .settings,
            .settings_editing => {
                model.stage = .settings;
                model.editing_profile = true;
            },
            .notifications => model.notifications_open = true,
            .composing => model.composing = true,
            .naming => model.naming = true,
            .address => model.address_open = true,
            .joining => model.joining = true,
            .bunker => {
                model.joining = true;
                model.bunker_mode = true;
            },
            .deleting => model.deleting_note = model.notes[0].id,
            .menu_scope => model.menu = .scope,
            .menu_relays => model.menu = .relays,
            .menu_account => model.menu = .account,
            .relay_auth => {},
            // The quiet strip with a Resume in it, in place of the offline one.
            .relays_paused => model.relays_paused = true,
        }
        if (st == .notifications_empty) model.notifications_open = true;

        const tree = try buildTree(arena, model);
        // A screen the setup never reached has nothing to press and passes
        // the walk below, which reads exactly like coverage.
        if (countPresses(tree, tree.root) < 8) {
            std.debug.print("\nthe {s} screen drew {d} presses: it was never reached\n", .{ f.name, countPresses(tree, tree.root) });
            return error.ScreenNeverReached;
        }
        // And the nested reply is on it, or the thread screens walk only the
        // rows that were already reachable.
        if ((st == .thread_nested or st == .thread_no_reply_verb) and countPressesOf(tree, tree.root, Msg{ .open_thread = 62 }) == 0) {
            std.debug.print("\nthe {s} screen drew no nested reply\n", .{f.name});
            return error.ScreenNeverReached;
        }
        if (st == .relays_paused and countPressesOf(tree, tree.root, Msg.toggle_relays_paused) == 0) {
            std.debug.print("\nthe {s} screen drew no Resume\n", .{f.name});
            return error.ScreenNeverReached;
        }
        if (auth_index) |i| {
            if (countPressesOf(tree, tree.root, Msg{ .auth_allow = @intCast(i) }) == 0 or
                countPressesOf(tree, tree.root, Msg{ .auth_deny = @intCast(i) }) == 0)
            {
                std.debug.print("\nthe {s} screen drew no AUTH question\n", .{f.name});
                return error.ScreenNeverReached;
            }
        }
        expectKeyboardReach(tree, tree.root, f.name) catch |err| {
            std.debug.print("\nthe {s} screen has a press the keyboard cannot use\n", .{f.name});
            return err;
        };
    }
}
fn countPresses(tree: AppUi.Tree, widget: canvas.Widget) usize {
    var n: usize = if (tree.msgFor(widget.id, .press) != null) 1 else 0;
    for (widget.children) |child| n += countPresses(tree, child);
    return n;
}
/// The outermost `.card` inside the dialog at `root`: the modal's own surface,
/// which is the boundary "outside" is measured against.
/// The settings COLUMN: the band the sections are laid out in, centred in the
/// window. Settings is a page rather than a modal now, so there is no dialog to
/// look inside and no card standing in for the content; the column states its
/// own width and that is the thing every settings rule is about.
fn settingsColumn(p: painted.Painted) ?geometry.RectF {
    for (p.layout.nodes) |node| {
        const f = node.widget.frame;
        if (@abs(f.width - main.settings_column_width) > 0.5) continue;
        if (f.height < 200) continue;
        return f;
    }
    return null;
}
test "the join sheet's dialog and card are the same box" {
    // The hole this closes was invisible in the tree and only in the frames:
    // both elements were present, correctly nested, and 48pt different in
    // width. Assert the geometry, not the markup.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);
        const root = modalDialogIndex(p, c.label) orelse return error.NoModalDialog;
        const card_index = modalCardIndex(p, root) orelse return error.NoModalCard;
        const dialog = p.layout.nodes[root].widget.frame;
        const card = p.layout.nodes[card_index].widget.frame;
        if (@abs(dialog.width - card.width) > 0.5) {
            std.debug.print(
                "{s}: the dialog is {d:.0}pt wide around a {d:.0}pt card, so {d:.0}pt of it belongs to neither\n",
                .{ c.name, dialog.width, card.width, dialog.width - card.width },
            );
            return error.DialogWiderThanItsCard;
        }
    }
}

test "the gap between a dialog and its card is not a hole through the modal" {
    // A dialog wider than the card inside it leaves a band that belongs to
    // neither: the card absorbs presses, the backdrop dismisses, and the strip
    // between them did neither. It sits above the backdrop, so a press there
    // reached the feed underneath and opened whatever it landed on.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);

        const root = modalDialogIndex(p, c.label) orelse return error.NoModalDialog;
        const card_index = modalCardIndex(p, root) orelse return error.NoModalCard;
        const dialog = p.layout.nodes[root].widget.frame;
        const card = p.layout.nodes[card_index].widget.frame;

        // Every band of the dialog the card does not cover, on both sides.
        const bands = [_]f32{
            dialog.x + (card.x - dialog.x) / 2,
            (card.x + card.width) + ((dialog.x + dialog.width) - (card.x + card.width)) / 2,
        };
        for (bands) |x| {
            const inside_dialog = x >= dialog.x and x <= dialog.x + dialog.width;
            const outside_card = x < card.x or x > card.x + card.width;
            if (!inside_dialog or !outside_card) continue;
            const y = card.y + card.height / 2;
            const msg = try p.pressMsgAt(x, y) orelse {
                std.debug.print(
                    "{s}: a press at ({d:.0}, {d:.0}), inside the dialog but outside the card, dispatches NOTHING, so it falls through to whatever is under the modal\n",
                    .{ c.name, x, y },
                );
                return error.HoleThroughTheModal;
            };
            const landed = @tagName(msg);
            const ok = std.mem.eql(u8, landed, @tagName(c.dismiss)) or
                std.mem.eql(u8, landed, "absorb_press");
            if (!ok) {
                std.debug.print("{s}: a press in the dialog's own margin dispatched {s}\n", .{ c.name, landed });
                return error.HoleThroughTheModal;
            }
        }
    }
}

test "a card that absorbs presses states its own surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Binding a press makes the card a HOVER target as well as a press claimer,
    // and the renderer resolves a card's fill through the button state channel:
    // pressed or hovered picks a different surface from the token set. An
    // explicit `style.background` wins outright over that channel
    // (`widgetBackgroundColor` is `style.background orelse fallback`), so a card
    // that states its own colour cannot flash under the pointer, and one that
    // does not will wash grey the moment the reader's cursor crosses it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var checked: usize = 0;
    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);
        for (p.layout.nodes) |node| {
            const w = node.widget;
            if (w.kind != .card) continue;
            var absorbs = false;
            for (p.tree.handlers) |h| {
                if (h.id == w.id and h.event == .press) absorbs = true;
            }
            if (!absorbs) continue;
            checked += 1;
            if (w.style.background == null) {
                std.debug.print("{s}: a pressable card paints no surface of its own\n", .{c.name});
                return error.CardWashesOnHover;
            }
        }
    }
    // One per modal at least, or the loop above proved nothing.
    try testing.expect(checked >= modal_cases.len);
}
test "the settings sheet paints its own surface the whole way down" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // As a screen, the grey behind the settings column was a panel inside the
    // scroll, and the scroll handed it the VIEWPORT's height: it stopped dead at
    // 760 while the sections ran on to 1253, so scrolling down left the rest of
    // Settings sitting on bare window. The sheet cannot do that, because the
    // scroll is inside the card rather than the card inside the scroll.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    // Down the middle of the window, top to bottom: something has to paint at
    // every height. The original bug was not a wrong colour, it was nothing at
    // all past the fold, and a page can make it exactly as easily as a screen
    // could: the background belongs on the page root, outside the scroll, or it
    // is only as tall as the viewport.
    var y: f32 = 2;
    while (y < main.window_height - 2) : (y += 8) {
        if (p.fillAt(main.window_width / 2, y) == null) {
            std.debug.print("settings paints nothing at y={d:.0}\n", .{y});
            return error.SurfaceStopsShort;
        }
    }

    // And the sections sit in the column the constant names, centred.
    const col = settingsColumn(p) orelse return error.NoSettingsColumn;
    try testing.expect(col.height > 300);
    try testing.expect(col.x > 8);
}

test "no relay suggestion is drawn outside the card that holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rows in this engine never flow-wrap, whatever `wrap` says on them, so a
    // row of chips is exactly as wide as its chips: six suggested relays used to
    // reach x=1372 in a 760 window. They are packed into rows here, and this is
    // the rule that says the packing agrees with the layout.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    const col_frame = settingsColumn(p) orelse return error.NoSettingsColumn;
    // The column, not a card: settings is a page and its sections are several
    // cards, so the band the chips must stay inside is the column itself.
    const sheet = col_frame;

    var seen: usize = 0;
    for (p.layout.nodes) |node| {
        // Found by the message they carry, not by the words on them: a label
        // filter here would silently match nothing the day the wording changes,
        // and a rule that matches nothing passes.
        const msg = pressMsgById(p, node.widget.id) orelse continue;
        if (msg != .relay_suggest) continue;
        const label = node.widget.semantics.label;
        seen += 1;
        const right = node.widget.frame.x + node.widget.frame.width;
        if (right > sheet.x + sheet.width or node.widget.frame.x < sheet.x) {
            std.debug.print(
                "\"{s}\" spans {d:.0}..{d:.0}, the sheet spans {d:.0}..{d:.0}\n",
                .{ label, node.widget.frame.x, right, sheet.x, sheet.x + sheet.width },
            );
            return error.ChipOverflows;
        }
    }
    // Every suggestion the table holds is on screen: packing must not drop one.
    try testing.expectEqual(main.relaySuggestionCount(), seen);
}
test "every verb people expect is under a note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Show them all: a row missing repost reads as a client that lost it, not
    // one that has not written it. Every one of them takes a press, so nothing
    // here answers a click with silence.
    //
    // Three, not six. A bookmark that could only ever disappoint whoever pressed
    // it is not a verb people expect, the ellipsis beside it opened a menu a
    // right-click already opens, and the bolt had no zap behind it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    var found: usize = 0;
    for ([_][]const u8{ "reply", "repeat", "like" }) |name| {
        for (p.layout.nodes) |node| {
            // Two channels, because the SDK has two icon builders: `appIcon`
            // puts the name in `Widget.icon` (so a missing app glyph draws the
            // slashed circle rather than spelling itself out), and `icon`, which
            // compile-checks a built-in name, puts it in `text`. A check that
            // knew only one of them would report half the row missing.
            const by_channel = node.widget.icon.len > 0 and std.mem.eql(u8, node.widget.icon, name);
            const by_text = node.widget.kind == .icon and std.mem.eql(u8, node.widget.text, name);
            if (!by_channel and !by_text) continue;
            found += 1;
            break;
        } else {
            std.debug.print("no \"{s}\" under a note\n", .{name});
            return error.MissingVerb;
        }
    }
    try testing.expectEqual(@as(usize, 3), found);

    // And the ones that went are really gone, by the same two channels. The bolt
    // is among them: Plaza cannot send a zap, so a bolt that answers a press with
    // nothing is a control that can only disappoint.
    for ([_][]const u8{ "bookmark", "ellipsis", "zap" }) |name| {
        for (p.layout.nodes) |node| {
            const by_channel = node.widget.icon.len > 0 and std.mem.eql(u8, node.widget.icon, name);
            const by_text = node.widget.kind == .icon and std.mem.eql(u8, node.widget.text, name);
            if (!by_channel and !by_text) continue;
            std.debug.print("\"{s}\" is still drawn under a note\n", .{name});
            return error.RemovedVerbStillThere;
        }
    }
}
fn ingestTopicNotes(arena: std.mem.Allocator, store: *nostr.store.Store, signer: nostr.keys.Signer) !void {
    main.setStoreForTest(store);
    const kp = try signer.keyPairFromSecretKey([_]u8{45} ** 32);
    const tag = [_]nostr.event.Tag{&.{ "t", "planetdyne" }};
    const other = [_]nostr.event.Tag{&.{ "t", "bitcoin" }};
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_011, 1, &tag, "first light", null));
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_012, 1, &tag, "second light", null));
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_013, 1, &other, "something else", null));
}

test "what a hashtag's relays send reaches its page" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/arrive.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    defer main.setStoreForTest(null);

    // Opened on an empty store: nothing here yet, and the page is waiting.
    main.setStoreForTest(&store);
    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "planetdyne");
    try testing.expectEqual(@as(usize, 0), model.thread_notes_len);
    try testing.expect(model.thread_loading);

    // The fetch's worker ingests into the store and tells no one. The tick is
    // the only thing that can carry it to the screen.
    try ingestTopicNotes(arena, &store, signer);
    main.forgetLevelCountForTest();
    main.refreshOpenLevelForTest(&model, 1_800_000_100);
    try testing.expectEqual(@as(usize, 2), model.thread_notes_len);
    try testing.expect(!model.thread_loading);
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (std.mem.indexOf(u8, note.content(), "something else") != null) return error.WrongNotesInTopic;
    }

    // And they are drawn.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "first light") != null);
    try testing.expect(findAnyTextContainingText(tree.root, "second light") != null);
}
test "a muted person's note is not on a hashtag page" {
    const me = [_]u8{0x46} ** 32;
    main.setIdentityForTest(me);
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/mutetopic.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);

    const loud = try signer.keyPairFromSecretKey([_]u8{0x47} ** 32);
    const fine = try signer.keyPairFromSecretKey([_]u8{0x48} ** 32);
    const tag = [_]nostr.event.Tag{&.{ "t", "planetdyne" }};
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, loud, 1_800_000_021, 1, &tag, "from the muted one", null));
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, fine, 1_800_000_022, 1, &tag, "from the other one", null));
    const muted = [_][32]u8{loud.public_key};
    try testing.expect(main.setMutesForTest(&muted, 1_800_000_000));

    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "planetdyne");
    try testing.expectEqual(@as(usize, 1), model.thread_notes_len);
    try testing.expectEqualStrings("from the other one", model.thread_notes[0].content());

    // And the same when the notes arrive after the page is open.
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, loud, 1_800_000_023, 1, &tag, "muted, later", null));
    main.forgetLevelCountForTest();
    main.refreshOpenLevelForTest(&model, 1_800_000_100);
    try testing.expectEqual(@as(usize, 1), model.thread_notes_len);
    try testing.expectEqualStrings("from the other one", model.thread_notes[0].content());
}
test "a test never dials a relay, even with a store open" {
    // The condition that segfaulted CI. Three fetch functions spawn detached
    // threads that dial relays and write into the store, and all three refused
    // when there was no store. That check was also RELIED ON to keep tests off
    // the network, on the reasoning that a test has no store.
    //
    // The topic view broke that reasoning, because reading a topic IS a store
    // query, so its test has to open one. The guard stopped firing, the worker
    // dialled real relays from a unit test, and it kept ingesting into an LMDB
    // handle the test had already closed. It is a race, so it passed far more
    // often than it failed, and when it failed it took down an unrelated test
    // that happened to be running.
    //
    // So: with a store OPEN, which is the case that broke, a fetch is still
    // refused. Reverting the guard to `g_store != null` fails this line.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/nodial.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    try testing.expect(!main.relayFetchAllowedForTest());
}
test "no post carries a bookmark or an ellipsis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both were drawn on every row and neither did anything a reader wanted.
    // The bookmark had nothing behind it at all, and the ellipsis opened a menu
    // carrying exactly what a right-click on the row already carries, so it was
    // a slot and a hit target spent on a second door to one room.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);

    const p = try painted.Painted.render(arena, &model);
    for (p.layout.nodes) |node| {
        const w = node.widget;
        if (std.mem.eql(u8, w.semantics.label, "More")) return error.EllipsisStillThere;
        if (w.icon.len > 0 and std.mem.eql(u8, w.icon, "bookmark")) return error.BookmarkStillThere;
    }

    // And what the ellipsis used to reach is still reachable, by the door that
    // was always there.
    const menu = noteContext(p) orelse return error.NoContextMenu;
    // "Open on njump.me" rather than "Open on the web": the row names the
    // host it will open, because inside a place that host is whatever the
    // community set and a reader should see it before pressing, not after.
    for ([_][]const u8{ "Copy note address", "Quote", "Copy text", "Open on njump.me" }) |want| {
        if (menu.label(want) == null) {
            std.debug.print("a right-click offers no \"{s}\"\n", .{want});
            return error.MissingContextItem;
        }
    }
}

test "a post's address is in its menu, not under its body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Sixty characters of bech32 sat under every focal note as a copyable pill.
    // It is a thing to copy, not a thing to read, so it lives where a reader
    // looks for something to copy.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);
    model.viewing_thread = 1;
    model.thread_root = model.notes[0];

    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Copy nevent") == null);
        if (findAnyTextContainingText(p.tree.root, "nevent1") != null) {
            std.debug.print("a raw nevent is still drawn under the note\n", .{});
            return error.AddressStillOnScreen;
        }
    }

    {
        const p = try painted.Painted.render(arena, &model);
        const menu = noteContext(p) orelse return error.NoContextMenu;
        const msg = menu.msgFor(p.tree, "Copy note address") orelse {
            std.debug.print("a right-click offers no way to copy the address\n", .{});
            return error.NoCopyAddress;
        };
        switch (msg) {
            .copy_nevent => |id| try testing.expectEqual(model.thread_root.id, id),
            else => return error.WrongMessage,
        }
    }
}

test "every post answers a right-click with the same actions as its menu" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);

    const p = try painted.Painted.render(arena, &model);
    var rows: usize = 0;
    for (p.layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, "Open thread")) continue;
        rows += 1;
        const items = node.widget.context_menu;
        if (items.len == 0) {
            std.debug.print("a post offers nothing on a right-click\n", .{});
            return error.NoContextMenu;
        }
        // The same actions, by name, as the menu behind the last verb.
        for ([_][]const u8{ "Open thread", "Copy note address", "Copy text", "Open on njump.me" }) |want| {
            for (items) |item| {
                if (std.mem.eql(u8, item.label, want)) break;
            } else {
                std.debug.print("a right-click offers no \"{s}\"\n", .{want});
                return error.MissingContextItem;
            }
        }
    }
    try testing.expect(rows >= 1);
}
test "every sheet takes the keyboard when it opens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Escape resolves from the FOCUSED widget up to the surface around it, with
    // a fallback that only sees ANCHORED surfaces. A sheet is neither anchored
    // nor focused by default, so Escape closed none of them, while three
    // comments in this file said it did. Driving the app is what found it.
    //
    // So each sheet takes the keyboard on the way in: its first field where it
    // has one (a composer you must click into before typing is a composer that
    // opened for no reason), and otherwise its way out, which is the only thing
    // safe to have under an accidental Return.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);
        const root = modalDialogIndex(p, c.label) orelse {
            std.debug.print("{s}: no dialog\n", .{c.name});
            return error.NoModalDialog;
        };
        var focused: usize = 0;
        for (p.layout.nodes, 0..) |node, i| {
            if (!node.widget.autofocus) continue;
            if (!isDescendantOf(p, i, root)) continue;
            focused += 1;
        }
        if (focused == 0) {
            std.debug.print("{s}: nothing in the sheet takes the keyboard\n", .{c.name});
            return error.SheetTakesNoFocus;
        }
        // Exactly one: two things asking for the caret is a race whose winner is
        // whichever the tree happens to reach first.
        if (focused > 1) {
            std.debug.print("{s}: {d} things ask for the keyboard\n", .{ c.name, focused });
            return error.TwoFocusRequests;
        }
    }
}
test "a bio's nostr: mentions are drawn as names, like a note's" {
    // A bio is written the same way a note is, so it carries the same NIP-27
    // references. The feed has drawn them as `@name` for a long time and the
    // profile printed the raw token, which is sixty-three characters of base32
    // in the middle of a sentence about a person.
    //
    // Asserted through `personAbout`, which is what both the page and the
    // height calculation call, rather than through `renderContent` directly:
    // the rewriting was never in doubt, reaching for it was.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bio.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const subject = [_]u8{0x71} ** 32;
    const friend = [_]u8{0x72} ** 32;
    const friend_npub = try nostr.nip19.encodeNpub(arena, friend);

    const bio = try std.fmt.allocPrint(arena, "Engaged to nostr:{s}", .{friend_npub});
    const meta = try std.fmt.allocPrint(arena, "{{\"name\":\"subject\",\"about\":\"{s}\"}}", .{bio});
    _ = try store.ingest(arena, .{
        .id = [_]u8{0xb1} ** 32,
        .pubkey = subject,
        .created_at = 1_800_000_000,
        .kind = 0,
        .tags = &.{},
        .content = meta,
        .sig = [_]u8{0} ** 64,
    }, .{});

    // Nobody knows the friend yet: a short npub, but never the raw token.
    {
        const shown = main.personAbout(subject);
        try testing.expect(std.mem.indexOf(u8, shown, "nostr:") == null);
        try testing.expect(std.mem.indexOf(u8, shown, "@npub1") != null);
        try testing.expect(std.mem.startsWith(u8, shown, "Engaged to @npub1"));
    }

    // Their kind:0 arrives and the app learns the name the way it really does,
    // through the profile refresh. This is the part a one-shot rewrite at parse
    // time gets wrong: the bio itself never changes, so nothing about the
    // subject's own event ever says to look at it again.
    _ = try store.ingest(arena, .{
        .id = [_]u8{0xb2} ** 32,
        .pubkey = friend,
        .created_at = 1_800_000_001,
        .kind = 0,
        .tags = &.{},
        .content = "{\"name\":\"aliza\"}",
        .sig = [_]u8{0} ** 64,
    }, .{});

    // The reader follows her, which is how her name reaches the cache at all.
    main.setIdentityForTest([_]u8{0x44} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    _ = main.setFollowsForTest(&[_][32]u8{friend}, 1_800_000_000);

    // Heap, not stack: a Model carries three hundred notes of fixed buffers.
    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(model, &store, 1_800_000_100);

    const shown = main.personAbout(subject);
    try testing.expectEqualStrings("Engaged to @aliza", shown);
}
test "the feed rebuilds inside a frame with every account a reader can follow" {
    // The other rebuild benchmark measures a typical list. This one measures the
    // ceiling, because the feed now reads the whole contact list rather than a
    // slice of it (#143), and the number that matters about that decision is
    // what it costs at the top.
    //
    // ReleaseFast only, and skipped rather than relaxed in Debug. A Debug build
    // is roughly six times slower per rebuild and would need a budget six times
    // looser, which would no longer be a frame and would stop meaning anything.
    // It also signs one event per note, and eight thousand Debug signatures is
    // minutes of CI for a number nobody ships.
    if (builtin.mode != .ReleaseFast) return;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{98} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/ceiling.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const follows = main.max_follows;
    const list = try arena.alloc([32]u8, follows);
    for (0..follows) |i| {
        var secret: [32]u8 = undefined;
        @memset(&secret, @intCast((i % 200) + 1));
        secret[31] = @intCast(i & 0xff);
        secret[30] = @intCast((i >> 8) & 0xff);
        const kp = signer.keyPairFromSecretKey(secret) catch continue;
        list[i] = kp.public_key;
        // A profile as well as notes, and the profile is OLDER than the notes,
        // which is the real shape: a bio is written once and posted over ever
        // since. That ordering is what made the profile query walk whole
        // timelines before the store indexed authors and kinds together.
        const meta = try nostr.event.create(arena, signer, kp, 1_799_000_000, 0, &.{}, "{\"name\":\"n\"}", null);
        _ = try store.ingest(arena, meta, .{});
        for (0..4) |n| {
            const body = try std.fmt.allocPrint(arena, "note {d} from {d}", .{ n, i });
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i * 10 + n)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(list, 1_800_000_000);
    try testing.expectEqual(follows, main.followSetForTest().len);

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.feed_limit = 300;
    main.reconcileForTest(model, &store, 1_800_002_000);
    try testing.expect(model.notes_len > 0);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Best of three. The stopwatch runs on a whole machine and nothing is ever
    // subtracted from a reading, so the error is one-sided and the minimum is
    // the closest estimate of the real cost available here.
    var best: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const started = std.Io.Timestamp.now(io, .awake);
        const rounds = 5;
        for (0..rounds) |_| {
            main.invalidateFeedForTest();
            main.reconcileForTest(model, &store, 1_800_002_000);
        }
        const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
        const per = @as(u64, @intCast(@max(elapsed.toNanoseconds(), 0))) / rounds;
        best = @min(best, per);
    }

    const budget_ns = 16 * std.time.ns_per_ms;
    std.debug.print("\n[perf] {d} follows (the ceiling): {d}us per feed rebuild (budget {d}us)\n", .{ follows, best / 1000, budget_ns / 1000 });
    if (best > budget_ns) {
        std.debug.print(
            "\nreading every follow costs {d}us per rebuild against a {d}us frame. The feed rebuilds on a timer, so this is a stutter every second, not a slow benchmark.\n",
            .{ best / 1000, budget_ns / 1000 },
        );
        return error.FeedRebuildTooSlow;
    }

    // And what the app actually does between two ticks, at the same ceiling, on
    // the same machine, in the same run: one note lands and the list already in
    // hand is merged with it. The number above is what that replaces, and the
    // pair is only comparable because nothing else moved between them.
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetFeedChangeDetectionForTest();
    main.tickForTest(model, 1_800_002_000);

    const own = try nostr.keys.Signer.init().keyPairFromSecretKey([_]u8{98} ** 32);
    var splice_best: u64 = std.math.maxInt(u64);
    var stamp: i64 = 1_800_003_000;
    for (0..3) |_| {
        const rounds = 5;
        var elapsed_ns: u64 = 0;
        for (0..rounds) |_| {
            stamp += 1;
            const body = try std.fmt.allocPrint(arena, "arriving at {d}", .{stamp});
            const ev = try nostr.event.create(arena, signer, own, stamp, 1, &.{}, body, null);
            _ = try main.plazaIngestForTest(arena, ev);
            // Only the tick is timed. Signing and storing are the relay
            // thread's work in the app and would swamp the thing being read.
            const t0 = std.Io.Timestamp.now(io, .awake);
            main.tickForTest(model, 1_800_003_500);
            const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
            elapsed_ns += @intCast(@max(dt.toNanoseconds(), 0));
        }
        splice_best = @min(splice_best, elapsed_ns / rounds);
    }

    std.debug.print(
        "[perf] {d} follows (the ceiling): {d}us per tick with one note arriving\n",
        .{ follows, splice_best / 1000 },
    );

    // The assertion is the counter, not the clock: the merge did not read the
    // window back. A stopwatch says what this machine was doing; this says what
    // the code did.
    const work_before = main.feedWork();
    main.tickForTest(model, 1_800_003_500);
    try testing.expectEqual(work_before.full_reads, main.feedWork().full_reads);
}
test "the feed has no bottom: it holds more notes than the old cap" {
    // The feed stopped at three hundred, and nothing about the rendering needed
    // that: the list is windowed, so what is held costs memory rather than
    // frames. The number was the size of a fixed array, and a reader who paged
    // to the end of it found the feed simply ended.
    //
    // Six hundred here, which is only meaningful because it is past the number
    // that used to be the ceiling.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{0x5b} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/deep.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const wanted = 600;
    var author: [32]u8 = undefined;
    {
        var secret: [32]u8 = [_]u8{0x2c} ** 32;
        const kp = try signer.keyPairFromSecretKey(secret);
        author = kp.public_key;
        secret[0] = 0;
        var i: usize = 0;
        while (i < wanted) : (i += 1) {
            const body = try std.fmt.allocPrint(arena, "note number {d}", .{i});
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(&[_][32]u8{author}, 1_800_000_000);

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;

    // Page down the way a reader does, rather than setting the limit in one
    // jump: this is also what proves the storage GROWS instead of being sized
    // once at the top.
    while (model.notes_len < wanted) {
        const before = model.notes_len;
        main.loadOlderForTest(model);
        main.invalidateFeedForTest();
        main.reconcileForTest(model, &store, 1_800_001_000);
        if (model.notes_len == before) break;
    }

    try testing.expectEqual(@as(usize, wanted), model.notes_len);
    try testing.expect(model.notes_len > 300);

    // Every row is a distinct note, newest first. A growth that re-pointed the
    // slice wrongly, or a reuse table that collided, would show up here as a
    // repeat rather than as a crash.
    var seen = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen.deinit();
    for (model.notes[0..model.notes_len]) |note| {
        try testing.expect(!seen.contains(note.id));
        try seen.put(note.id, {});
    }
}
test "a tick with nothing new does not read the feed back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "quiet");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
    const after_first = main.feedWork();

    // Nine more ticks with nothing arriving. This is the app at rest, and it
    // used to be nine more full reads of the whole follow list.
    for (0..9) |_| f.tick(1_800_000_100);
    const at_rest = main.feedWork();
    try testing.expectEqual(after_first.full_reads, at_rest.full_reads);
    try testing.expectEqual(after_first.splices, at_rest.splices);
    try testing.expectEqual(after_first.parses, at_rest.parses);
}

test "an event of another kind does not read the feed back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "otherkind");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    const before = main.feedWork();

    // A reaction to it. The store's event count moves, which is the only signal
    // the feed used to have, and it meant a full read every time anyone liked
    // anything anywhere.
    const like = try nostr.event.create(arena, f.signer, f.kp, 1_800_000_010, 7, &.{}, "+", null);
    _ = try main.plazaIngestForTest(arena, like);
    f.tick(1_800_000_100);

    const after = main.feedWork();
    try testing.expectEqual(before.full_reads, after.full_reads);
    try testing.expectEqual(before.splices, after.splices);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
}

test "a note that arrives is merged into the list, not fetched again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "splice");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "older");
    f.tick(1_800_000_100);
    const before = main.feedWork();
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    const newer = try f.arrive(arena, 1_800_000_050, "newer");
    f.tick(1_800_000_100);

    const after = main.feedWork();
    try testing.expectEqual(before.full_reads, after.full_reads);
    try testing.expectEqual(before.splices + 1, after.splices);
    // One note parsed, not two: the card already on screen carried over.
    try testing.expectEqual(before.parses + 1, after.parses);
    try testing.expectEqual(@as(usize, 2), f.model.notes_len);
    try testing.expectEqual(main.noteIdOf(newer), f.model.notes[0].id);
}

test "a spliced feed holds the same notes in the same order as a full read" {
    // The guard against the two paths drifting. Everything else here checks one
    // path; this one checks they agree, which is the property that matters and
    // the one a future change is most likely to break.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "agree");
    defer f.deinit();

    // Deliberately out of order, and with FIVE sharing one second. Five,
    // because the tie-break is the part most easily got wrong and one pair
    // catches it only half the time: an id order that happens to match arrival
    // order proves nothing. Ids are hashes, so five in a row matching by chance
    // is one in a hundred and twenty.
    const tie = 1_800_000_030;
    const stamps = [_]i64{ tie, 1_800_000_010, 1_800_000_070, tie, tie, 1_800_000_050, tie, 1_800_000_020, tie };
    for (stamps, 0..) |at, i| {
        const body = try std.fmt.allocPrint(arena, "note {d}", .{i});
        _ = try f.arrive(arena, at, body);
        // A tick between each, so every one of them lands as a splice into a
        // list that already exists rather than as part of one big read.
        f.tick(1_800_000_100);
    }
    try testing.expectEqual(stamps.len, f.model.notes_len);

    var spliced_buf: [16]i64 = undefined;
    const spliced = f.ids(&spliced_buf);
    var snapshot: [16]i64 = undefined;
    @memcpy(snapshot[0..spliced.len], spliced);

    // The store's rule, stated directly rather than inferred: created_at
    // descending, then id descending. Asserting it here and not only against a
    // full read means the two cannot agree on the WRONG order.
    var prev: ?main.Note = null;
    for (f.model.notes[0..f.model.notes_len]) |note| {
        if (prev) |p| {
            try testing.expect(p.created_at >= note.created_at);
            if (p.created_at == note.created_at) {
                try testing.expect(std.mem.order(u8, &p.event_id, &note.event_id) == .gt);
            }
        }
        prev = note;
    }

    main.reconcileForTest(f.model, &f.store, 1_800_000_100);
    var full_buf: [16]i64 = undefined;
    const full = f.ids(&full_buf);

    try testing.expectEqualSlices(i64, snapshot[0..spliced.len], full);
}
test "a note from someone the reader does not follow is not spliced in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "stranger");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "mine");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    // A thread fetch or a quote lookup stores notes by people the reader does
    // not follow. They go through the same door and land in the same buffer, so
    // the splice has to reject them the way the full read's author filter does.
    var other = nostr.keys.Signer.init();
    defer other.deinit();
    const other_kp = try other.keyPairFromSecretKey([_]u8{88} ** 32);
    const theirs = try signedNote(arena, other, other_kp, 1_800_000_090, "not in this feed");
    _ = try main.plazaIngestForTest(arena, theirs);
    f.tick(1_800_000_100);

    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    // And a full read agrees, which is the point: the splice is not allowed to
    // be more or less permissive than the query it replaces.
    main.reconcileForTest(f.model, &f.store, 1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
}

test "a deletion is read back in full, because a splice can only add" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "deletion");
    defer f.deinit();

    const doomed = try f.arrive(arena, 1_800_000_000, "regrettable");
    _ = try f.arrive(arena, 1_800_000_050, "fine");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 2), f.model.notes_len);
    const before = main.feedWork();

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{doomed.id}) catch unreachable;
    const tags = [_]nostr.event.Tag{&.{ "e", &hex }};
    const del = try nostr.event.create(arena, f.signer, f.kp, 1_800_000_060, 5, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, del);
    f.tick(1_800_000_100);

    const after = main.feedWork();
    try testing.expectEqual(before.full_reads + 1, after.full_reads);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
}

test "paging down is read back in full" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "paging");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    const before = main.feedWork();

    // Notes below the old window belong now, and nothing arriving says so.
    main.loadOlderForTest(f.model);
    f.tick(1_800_000_100);

    try testing.expectEqual(before.full_reads + 1, main.feedWork().full_reads);
}

test "more arrivals than the buffer holds are read back in full" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "overflow");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    const before = main.feedWork();

    // A backfill: more lands between two ticks than the buffer can name. The
    // list in hand cannot be brought up to date by splicing, and the honest
    // answer is the expensive one, not a quietly incomplete feed.
    main.overflowFeedArrivalsForTest();
    f.tick(1_800_000_100);

    const after = main.feedWork();
    try testing.expectEqual(before.full_reads + 1, after.full_reads);
    try testing.expectEqual(before.splices, after.splices);
}
test "a note announced twice appears once" {
    // `.added` fires only for an event the store did not have, so the app
    // should never announce one that is already on screen. The splice checks
    // anyway, because the failure is a note drawn twice with the same id, and
    // the row keys, the media slots and the engagement counts are all keyed on
    // that id.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "twice");
    defer f.deinit();

    const ev = try f.arrive(arena, 1_800_000_000, "one");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    main.noteFeedArrivalForTest(ev.id);
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);
}

test "a note older than a full window is not spliced into it" {
    // The window holds the newest `feed_limit`. A note that arrives older than
    // everything in a full window does not belong in it, and a splice that
    // added it anyway would push the oldest note out and disagree with a full
    // read, which is the drift these two paths must not have.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "toolate");
    defer f.deinit();

    f.model.feed_limit = 3;
    for (0..3) |i| {
        const body = try std.fmt.allocPrint(arena, "note {d}", .{i});
        _ = try f.arrive(arena, 1_800_000_100 + @as(i64, @intCast(i)), body);
    }
    f.tick(1_800_000_200);
    try testing.expectEqual(@as(usize, 3), f.model.notes_len);
    const oldest_shown = f.model.notes[2].id;

    _ = try f.arrive(arena, 1_800_000_000, "long ago");
    f.tick(1_800_000_200);

    try testing.expectEqual(@as(usize, 3), f.model.notes_len);
    try testing.expectEqual(oldest_shown, f.model.notes[2].id);
    // Parsed nothing: it was rejected before `noteFrom` ran, which is the point
    // of checking the window edge before parsing rather than after.
    const before = main.feedWork().parses;
    f.tick(1_800_000_200);
    try testing.expectEqual(before, main.feedWork().parses);

    // And a full read of the same store shows the same three.
    main.reconcileForTest(f.model, &f.store, 1_800_000_200);
    try testing.expectEqual(@as(usize, 3), f.model.notes_len);
    try testing.expectEqual(oldest_shown, f.model.notes[2].id);
}

test "a note that fills a gap below the window arrives when the reader pages down" {
    // The other half: the note rejected above is not lost, it is simply not in
    // this window. Paging down has to find it, or "not spliced in" would mean
    // "dropped".
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "pagedown");
    defer f.deinit();

    f.model.feed_limit = 2;
    for (0..2) |i| {
        const body = try std.fmt.allocPrint(arena, "recent {d}", .{i});
        _ = try f.arrive(arena, 1_800_000_100 + @as(i64, @intCast(i)), body);
    }
    f.tick(1_800_000_200);
    try testing.expectEqual(@as(usize, 2), f.model.notes_len);

    const old_one = try f.arrive(arena, 1_800_000_000, "long ago");
    f.tick(1_800_000_200);
    try testing.expectEqual(@as(usize, 2), f.model.notes_len);

    f.model.feed_limit = 4;
    f.tick(1_800_000_200);
    try testing.expectEqual(@as(usize, 3), f.model.notes_len);
    try testing.expectEqual(main.noteIdOf(old_one), f.model.notes[2].id);
}
test "a relay the reader is already on gets no second connection" {
    // It is already being asked about everybody. A discovered slot for it would
    // be a duplicate socket asking a narrower version of the same question.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{6} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/dupe.mdb", .{tmp.sub_path});
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

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://mine.example.com" }};
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(@as(usize, 0), main.discoveredCount());
}

test "rewriting the routes tells the connections to re-ask" {
    // A thread holds the generation it dialled under and drops the connection
    // when it moves. Without the bump, a slot changing hands would keep feeding
    // the store answers to a question nobody is asking any more, until the
    // socket happened to drop.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{7} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/gen.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://somewhere.example.com" }};
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    const before = main.discoveredGenerationForTest(0);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(main.discoveredGenerationForTest(0) != before);
}
test "a relay the reader is not on is asked without a since" {
    // `feedSince` is "the newest note I hold, minus an hour". On the pool's own
    // relays that is right: they have been answering this question all along,
    // so anything older is already in the store.
    //
    // A routed relay has answered nothing. It was dialled because it holds
    // notes from people whose posts the reader has never had, and every one of
    // those is older than the newest note the reader holds from anybody else.
    // A `since` there asks a relay full of missing history for the last hour of
    // it, which is how this shipped in v0.3.0 and delivered almost nothing.
    var authors: [3][32]u8 = undefined;
    for (&authors, 0..) |*a, i| {
        a.* = [_]u8{0} ** 32;
        a[0] = @intCast(i + 1);
    }

    // The feed HAS to be holding a note, or `feedSince` returns null for want
    // of one and this test passes whether or not the code asks for a bound.
    // Removing the fix failed nothing until this line existed.
    main.setFeedNewestForTest(1_800_000_000);
    defer main.setFeedNewestForTest(0);
    try testing.expect(main.feedSinceForTest() != null);

    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;
    const filters = main.buildRoutedFiltersForTest(&authors, &buf);

    try testing.expect(filters.len > 0);
    for (filters) |f| {
        try testing.expectEqual(@as(?i64, null), f.since);
    }
}
test "an author nobody was routed to lands in the residual" {
    // The case that makes the pivot safe. This author HAS a relay list, so
    // "authors with no list" would miss them, and their relay is too unpopular
    // to be chosen, so routing misses them too.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/residual.mdb", .{tmp.sub_path});
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

    // Enough distinct one-author relays to overflow the routed budget, so the
    // last ones cannot be chosen. Counted off the budget rather than written
    // out: with fewer relays than slots everybody is routed, the residual is
    // trivially empty, and the test passes without ever reaching the case.
    const budget = main.maxDiscoveredRelaysForTest;
    const spare = 3;
    const specs = try arena.alloc([]const []const u8, budget + spare);
    for (specs, 0..) |*spec, i| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = try std.fmt.allocPrint(arena, "wss://only-{d}.example.com", .{i});
        spec.* = one;
    }
    const follows = try arena.alloc([32]u8, specs.len);
    try seedRelayLists(arena, signer, specs, follows);
    _ = main.setFollowsForTest(follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Nobody shares a relay with anybody, so the budget reaches exactly its own
    // number of people and the rest have to go somewhere. A count, not "more
    // than nothing": the residual losing one person is the failure this guards.
    try testing.expectEqual(@as(usize, spare), main.residualCountForTest());
}
test "a relay the reader is already on is not dialled again, but still counts as cover" {
    // The pool is already connected. Spending a routed slot on it would be a
    // duplicate socket, and ignoring what it carries would spend the budget
    // re-reaching people who are already reachable.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/poolcover.mdb", .{tmp.sub_path});
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

    const mine = [_][]const u8{"wss://mine.example.com"};
    const specs = [_][]const []const u8{ &mine, &mine, &mine };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Nothing to dial: everyone writes where the reader already is.
    var buf: [96]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), main.discoveredUrlCopy(0, &buf));
    // And they are not residual either, because the pool covers them.
    try testing.expectEqual(@as(usize, 0), main.residualCountForTest());
}
test "a repost carries the note it repeats, so a reader needs no second fetch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4F} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/repost.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "the words being repeated");
    _ = try store.ingest(arena, ev, .{});

    const note = main.noteFrom(ev, 1_800_000_000);

    // With the store in hand, the content is the reposted event itself. NIP-18
    // says it should be, and Jumble and NDK both put it there, which is what
    // lets a reader who has never seen the note render it without asking.
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    const content = main.repostContent(arena, &note);
    try testing.expect(std.mem.indexOf(u8, content, "the words being repeated") != null);
    try testing.expect(std.mem.startsWith(u8, content, "{\"id\":\""));
    try testing.expect(std.mem.indexOf(u8, content, "\"sig\":\"") != null);

    // And with no store it is empty rather than wrong. An empty content is
    // legal, and is what those clients fall back to as well; a note the store
    // has lost still reposts, it just costs the reader a fetch.
    main.setStoreForTest(null);
    try testing.expectEqualStrings("", main.repostContent(arena, &note));
}
test "a muted author's notes never become cards" {
    main.forgetMutesForTest();
    main.forgetFollowsForTest();
    const me = [_]u8{0x61} ** 32;
    main.setIdentityForTest(me);
    defer {
        main.forgetMutesForTest();
        main.forgetFollowsForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const loud_kp = try signer.keyPairFromSecretKey([_]u8{0x62} ** 32);
    const fine_kp = try signer.keyPairFromSecretKey([_]u8{0x63} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/muted.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    _ = try store.ingest(arena, try signedNote(arena, signer, loud_kp, 1_800_000_100, "from the muted one"), .{});
    _ = try store.ingest(arena, try signedNote(arena, signer, fine_kp, 1_800_000_200, "from the other one"), .{});

    const follows = [_][32]u8{ loud_kp.public_key, fine_kp.public_key };
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    // Both, before anything is muted.
    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_300);
    try testing.expectEqual(@as(usize, 2), model.notes_len);

    // And one, after.
    const muted = [_][32]u8{loud_kp.public_key};
    try testing.expect(main.setMutesForTest(&muted, 1_800_000_250));
    main.reconcileForTest(&model, &store, 1_800_000_300);
    try testing.expectEqual(@as(usize, 1), model.notes_len);
    try testing.expectEqualStrings("from the other one", model.notes[0].content());
}
test "a thread nobody has replied to stops loading once the fetch is done or has waited long enough" {
    main.setIdentityForTest([_]u8{0x6B} ** 32);
    defer {
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
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quiet-thread.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);

    const op = try signer.keyPairFromSecretKey([_]u8{0x6C} ** 32);
    const root = try signedNote(arena, signer, op, 1_800_000_000, "nobody has answered this");
    _ = try store.ingest(arena, root, .{});

    const opened: i64 = 1_800_000_300;
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = main.noteFrom(root, opened).id;
    model.thread_root = main.noteFrom(root, opened);
    model.thread_seq = 7_000_001;
    model.thread_open_at = opened;
    // A made-up generation far ahead of the real counter, and a finished mark
    // only ever moves forward, so put it back for whatever runs next.
    defer main.finishLevelFetchForTest(0);
    model.thread_loading = true;

    // The first tick sees the store move (it has never looked) and reads it. The
    // skeletons stay: the fetch is out and the grace has not passed.
    main.tickOpenLevelForTest(&model, opened + 1);
    try testing.expect(model.thread_loading);

    // The store never changes again, because nothing is coming. The tick used to
    // settle the loading state only when the store moved, so this never ended.
    main.tickOpenLevelForTest(&model, opened + 3);
    try testing.expect(model.thread_loading);
    main.tickOpenLevelForTest(&model, opened + 8);
    try testing.expect(!model.thread_loading);
    try testing.expectEqual(@as(usize, 0), model.thread_notes_len);

    // The same when the relays answer before the grace is up.
    model.thread_loading = true;
    model.thread_open_at = opened + 100;
    main.tickOpenLevelForTest(&model, opened + 101);
    try testing.expect(model.thread_loading);
    main.markThreadFetchDoneForTest(model.thread_seq);
    main.tickOpenLevelForTest(&model, opened + 102);
    try testing.expect(!model.thread_loading);
}
test "three pictures draw as three cells across the column, not one and two links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x83} ** 32);
    defer main.clearIdentityForTest();
    main.setMediaPreviews(true);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 91;
    _ = model.notes[0].setImageForTest(0, "https://h.example/a.jpg");
    _ = model.notes[0].setImageForTest(1, "https://h.example/b.jpg");
    _ = model.notes[0].setImageForTest(2, "https://h.example/c.jpg");
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    // One pressable cell per picture. The single-image build drew exactly one
    // whatever the note carried.
    try testing.expectEqual(@as(usize, 3), countByLabel(tree.root, "Attached image, press to enlarge"));
}

test "one picture still fills the column, so nothing about a plain note moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x84} ** 32);
    defer main.clearIdentityForTest();
    main.setMediaPreviews(true);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 92;
    const img = model.notes[0].setImageForTest(0, "https://h.example/only.jpg");
    img.aspect = 0.6;
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countByLabel(tree.root, "Attached image, press to enlarge"));
}
test "only the follows nobody can be routed to are put to the indexers" {
    // The outbox bootstrap. To route to somebody you need their kind:10002, and
    // you cannot ask their write relays for it, because finding them IS the
    // question. Plaza only ever learned a relay list from a relay it was
    // already reading, so a follow whose list lives anywhere else was never
    // routed to and never appeared, with no error and no empty state.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const known = try signer.keyPairFromSecretKey([_]u8{3} ** 32);
    const unknown = try signer.keyPairFromSecretKey([_]u8{4} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/indexer.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.resetIndexerAskedForTest();
    defer main.resetIndexerAskedForTest();
    // Without an identity the follow table is not owned and `followSet` hands
    // back the starter pack, so the sweep would be measuring the wrong people.
    main.setIdentityForTest([_]u8{88} ** 32);
    defer main.clearIdentityForTest();

    const follows = [_][32]u8{ known.public_key, unknown.public_key };
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    // One of the two has published a relay list Plaza already holds.
    const tags = [_]nostr.event.Tag{&.{ "r", "wss://writes.example.com", "write" }};
    const ev = try nostr.event.create(arena, signer, known, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);

    var out: [8][32]u8 = undefined;
    const n = main.collectUnroutedForTest(&out);

    // Exactly the one with nothing on disk. Asking about the other would be
    // asking a question already answered.
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(std.mem.eql(u8, &out[0], &unknown.public_key));
}
test "a person's page keeps the notes it already parsed when the store moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/reuse.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    const who = [_]u8{0x6e} ** 32;
    const newest: i64 = 1_800_000_000;
    try seedAuthorNotes(&store, arena, who, 150, newest, false);
    // One note that names somebody, the only kind a name landing changes.
    const named = [_]u8{0x6f} ** 32;
    var mention = nostr.event.Event{
        .id = [_]u8{0x6e} ** 32,
        .pubkey = who,
        .created_at = newest - 10,
        .kind = 1,
        .tags = &.{},
        .content = try std.fmt.allocPrint(arena, "hi nostr:{s}", .{try nostr.nip19.encodeNpub(arena, named)}),
        .sig = [_]u8{0} ** 64,
    };
    mention.id[0] = 0xAA;
    _ = try store.ingest(arena, mention, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);

    // The store moved for somebody else's sake: nothing on the page is parsed.
    var before = main.profileParsesForTest();
    main.refreshProfileNotesForTest(&model);
    try testing.expectEqual(before, main.profileParsesForTest());

    // The next page from the store parses that page and nothing above it.
    before = main.profileParsesForTest();
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 151), model.thread_notes_len);
    try testing.expectEqual(before + 51, main.profileParsesForTest());

    // A newer note lands on top: it is the one parse, and everything under it
    // moved down a row intact.
    var fresh = nostr.event.Event{
        .id = [_]u8{0x6e} ** 32,
        .pubkey = who,
        .created_at = newest + 1,
        .kind = 1,
        .tags = &.{},
        .content = "just now",
        .sig = [_]u8{0} ** 64,
    };
    fresh.id[0] = 0xBB;
    _ = try store.ingest(arena, fresh, .{});
    before = main.profileParsesForTest();
    main.refreshProfileNotesForTest(&model);
    try testing.expectEqual(before + 1, main.profileParsesForTest());
    try testing.expectEqual(@as(usize, 152), model.thread_notes_len);
    var query = try store.query(arena, .{ .authors = &.{who}, .kinds = &.{1}, .limit = 152 });
    defer query.deinit();
    for (query.events, model.thread_notes[0..152]) |ev, note| {
        try testing.expectEqualSlices(u8, &ev.id, &note.event_id);
        try testing.expectEqual(ev.created_at, note.created_at);
    }
    try testing.expectEqualStrings("just now", model.thread_notes[0].content());

    // A name landing re-reads the one note that names somebody, and only it.
    before = main.profileParsesForTest();
    main.setProfileNameForTest(named, "Grace");
    main.refreshProfileNotesForTest(&model);
    try testing.expectEqual(before + 1, main.profileParsesForTest());
    var found = false;
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (std.mem.eql(u8, &note.event_id, &mention.id)) {
            try testing.expectEqualStrings("hi @Grace", note.content());
            found = true;
        }
    }
    try testing.expect(found);
}

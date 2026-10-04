//! Tests of profile_notes.zig. A person's notes, page by page: which relays to ask, and when the end is reached.

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
const seedAuthorNotes = harness.seedAuthorNotes;

test "a person's page pages down through the store, then asks the relays for older notes" {
    // A profile read one page from the store and one from the relays and stopped.
    // The list had no end to reach, so the notes under the first hundred (sixty
    // or so on the Notes tab, once the replies are taken out) were out of reach.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/paging.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x61} ** 32;
    const newest: i64 = 1_800_000_000;
    try seedAuthorNotes(&store, arena, who, 250, newest, false);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    // The first page is what it always was.
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);

    // Reaching the end reads the next page from disk. No relay is involved.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 200), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // The store has fifty more, then it has no more.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Newest first, no repeats, and every row is theirs.
    for (model.thread_notes[0..250], 0..) |note, i| {
        try testing.expectEqual(newest - @as(i64, @intCast(i)), note.created_at);
        try testing.expectEqualSlices(u8, &who, &note.pubkey);
    }

    // Now the relays are asked, from as far back as they have brought this
    // person's notes: here the first page, their newest hundred.
    main.noteProfileReachForTest(who, newest - 99);
    main.loadOlderProfileForTest(&model);
    const ask = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqualSlices(u8, &who, &ask.pubkey);
    try testing.expectEqual(newest - 99, ask.until);
}

test "older notes are asked from where the relays reached, not from an old note the store happened to hold" {
    // The store holds what any surface fetched. Beside the run the relays paged
    // through, it can hold one old note of theirs from a thread or a quote, and
    // paging from the oldest note in hand jumped straight past everything in
    // between. On the next visit that note was still the oldest in hand, so the
    // gap was skipped every time.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/gap.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x6b} ** 32;
    const newest: i64 = 1_800_000_000;
    try seedAuthorNotes(&store, arena, who, 40, newest, false);
    // A year older, and nothing in between.
    var old = nostr.event.Event{
        .id = [_]u8{0x6b} ** 32,
        .pubkey = who,
        .created_at = newest - 365 * 24 * 3600,
        .kind = 1,
        .tags = &.{},
        .content = "an old note somebody quoted",
        .sig = [_]u8{0} ** 64,
    };
    old.id[0] = 0xEE;
    _ = try store.ingest(arena, old, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 41), model.thread_notes_len);

    // No round has brought a note yet, so there is no run to continue: the page
    // asks for their newest, from the moment it opened.
    main.loadOlderProfileForTest(&model);
    const first = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(model.thread_open_at, first.until);

    // The relays brought the forty. The next page starts under them, not under
    // the note from a year ago.
    main.noteProfileReachForTest(who, newest - 39);
    main.loadOlderProfileForTest(&model);
    const next = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(newest - 39, next.until);

    // A round for somebody else says nothing about this person.
    main.noteProfileReachForTest([_]u8{0x6c} ** 32, newest - 5000);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));
    // A later round can only take it further back.
    main.noteProfileReachForTest(who, newest - 10);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));

    // Back from a thread keeps how far the relays got; a fresh visit does not.
    main.enterThreadForTest(&model, model.thread_notes[0]);
    main.closeThreadForTest(&model);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));
    main.enterProfileForTest(&model, [_]u8{0x6c} ** 32);
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(?i64, null), main.profileReachForTest(who));
}

test "a round reaches as far as every relay asked has answered for" {
    // Each relay sends its newest page under the cursor. Under the oldest note
    // of the shortest page, another relay may hold notes nobody sent yet, so the
    // cut is the hundredth newest distinct note across all of them.
    var seen: [200]main.ProfileSeen = undefined;
    // Relay one: a full page, one note a second from 1000 down to 901.
    for (0..100) |i| seen[i] = .{ .at = 1000 - @as(i64, @intCast(i)), .key = @intCast(i + 1) };
    // Relay two: the same newest fifty, then fifty far older ones.
    for (0..50) |i| seen[100 + i] = seen[i];
    for (0..50) |i| seen[150 + i] = .{ .at = 500 - @as(i64, @intCast(i)), .key = @intCast(1000 + i) };
    // Under 901 only relay two has answered: relay one stopped at its hundredth
    // and may hold everything between 901 and 451. So the cut is 901, and a note
    // both relays sent counts once (twice, and the cut would stop at 951).
    const cut = main.roundReachForTest(&seen) orelse return error.NoReach;
    try testing.expectEqual(@as(i64, 901), cut);

    // Fewer than a page in all: every relay sent what it had, so the oldest.
    var few = [_]main.ProfileSeen{ .{ .at = 30, .key = 3 }, .{ .at = 10, .key = 1 }, .{ .at = 20, .key = 2 } };
    try testing.expectEqual(@as(?i64, 10), main.roundReachForTest(&few));
    var none: [0]main.ProfileSeen = .{};
    try testing.expectEqual(@as(?i64, null), main.roundReachForTest(&none));
}

test "back from a note keeps a person's page as deep as it was paged" {
    // Back rebuilt the page from its first hundred, so a reader three pages down
    // came back to a list cut short under them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/depth.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x6d} ** 32;
    try seedAuthorNotes(&store, arena, who, 250, 1_800_000_000, false);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    main.loadOlderProfileForTest(&model);
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);

    main.enterThreadForTest(&model, model.thread_notes[220]);
    main.closeThreadForTest(&model);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);
}

test "a person's history ends when the relays say it does, and the page says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/ending.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x62} ** 32;
    const other = [_]u8{0x63} ** 32;
    try seedAuthorNotes(&store, arena, who, 2, 1_800_000_000, false);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 2), model.thread_notes_len);

    // Not at the end until a relay has said so: nothing says it yet, and a list
    // that claims an end it has not found would hide the rest of the history.
    try testing.expectEqual(@as(u8, 0), main.profileFooterForTest(&model, who, 2));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(!findAnyTextContaining(tree.root, "That is everything"));
    }

    main.setProfileEndForTest(who);
    try testing.expect(main.profileEndReachedForTest(who));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "That is everything the relays have from them."));
    }

    // And it is THEIR end, not the page's: it says nothing about anybody else.
    try testing.expect(!main.profileEndReachedForTest(other));

    // At the end the reader's scroll asks nobody anything.
    main.resetProfileEndForTest();
    main.setProfileEndForTest(who);
    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Opening the page again is asking again.
    main.enterProfileForTest(&model, other);
    main.enterProfileForTest(&model, who);
    try testing.expect(!main.profileEndReachedForTest(who));
}

test "a list whose bottom is in view asks for more, even when it is too short to scroll" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/fill.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // Someone who only ever answers other people: every one of their notes is a
    // reply, so the Notes tab is empty however much history there is, and an
    // empty list has no end to scroll to.
    const who = [_]u8{0x64} ** 32;
    try seedAuthorNotes(&store, arena, who, 150, 1_800_000_000, true);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);
    var buf: [200]usize = undefined;
    try testing.expectEqual(@as(usize, 0), model.profileNotesFor(&buf, who).len);

    // Bottom out of view: nothing to do.
    main.loadAtProfileBottomForTest(&model, false);
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);

    // In view: from the store first.
    main.loadAtProfileBottomForTest(&model, true);
    try testing.expectEqual(@as(usize, 150), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Then from the relays, once the store has nothing more, from as far back as
    // they have brought this person's notes.
    main.noteProfileReachForTest(who, 1_800_000_000 - 99);
    main.loadAtProfileBottomForTest(&model, true);
    const ask = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(@as(i64, 1_800_000_000 - 99), ask.until);

    // And not again from the same place. A round that left the list as it was
    // would otherwise be asked for once a second for as long as the page is open.
    main.resetProfileEndForTest();
    main.loadAtProfileBottomForTest(&model, true);
    try testing.expect(main.profileOlderAskForTest() == null);
}

test "a short tab fills itself a few pages and then leaves the rest to the reader" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bounded.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // A thousand replies and no notes: the Notes tab stays empty however far
    // back it goes, which is what the bound is for.
    const who = [_]u8{0x6a} ** 32;
    try seedAuthorNotes(&store, arena, who, 1000, 1_800_000_000, true);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);

    for (0..20) |_| main.loadAtProfileBottomForTest(&model, true);
    // 100 to open, plus a page for each automatic ask.
    try testing.expectEqual(@as(usize, 100 + 5 * 100), model.thread_notes_len);

    // The reader scrolling to the end still gets another.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 100 + 6 * 100), model.thread_notes_len);
}
test "history is not declared over by a round that was only second to the first fetch" {
    // Opening a page races two fetches for the same notes. Whichever lands
    // second finds every one of them already stored, and "nothing was new to the
    // store" read as "nothing older exists". On a person with two hundred notes
    // that put "That is everything" under the first hundred.
    try testing.expect(!main.profileRoundEndedForTest(1, 1, 0, 99));
    // A relay that answered and had nothing older is the only thing that ends it.
    try testing.expect(main.profileRoundEndedForTest(1, 1, 0, 0));
    // One that never answered says nothing at all.
    try testing.expect(!main.profileRoundEndedForTest(1, 0, 0, 0));
    try testing.expect(!main.profileRoundEndedForTest(0, 0, 0, 0));
}

test "a short page does not page while its own first fetch is still out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/racing.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // One note held, the way it is when the first fetch has not come back: the
    // list is short, so it is "at its end" the moment it opens.
    const who = [_]u8{0x69} ** 32;
    try seedAuthorNotes(&store, arena, who, 1, 1_800_000_000, false);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    main.setFirstProfileFetchOutForTest(&model, true);

    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Once the first fetch has landed, reaching the end asks.
    main.setFirstProfileFetchOutForTest(&model, false);
    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() != null);
}

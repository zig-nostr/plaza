//! Tests of thread_model.zig. Threads as data: NIP-10 and NIP-22 parents and roots, arrival order, ancestor chains, and graph splits.

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
const threadNote = harness.threadNote;

test "nip10Parent picks the marked reply, root, or positional parent" {
    const root_hex = "01" ** 32;
    const mid_hex = "02" ** 32;
    const deep_hex = "03" ** 32;
    const root_id = [_]u8{0x01} ** 32;
    const mid_id = [_]u8{0x02} ** 32;
    const deep_id = [_]u8{0x03} ** 32;

    // A marked `reply` wins over the marked root and any unmarked tag.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "", "root" },
            &.{ "e", deep_hex, "" },
            &.{ "e", mid_hex, "", "reply" },
        };
        try testing.expectEqualSlices(u8, &mid_id, &(main.nip10Parent(&tags).?));
    }
    // Only a `root` marker: the note answers the root directly.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex, "wss://r", "root" }};
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // No markers (deprecated positional): the LAST `e` tag is the parent.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex },
            &.{ "e", deep_hex },
        };
        try testing.expectEqualSlices(u8, &deep_id, &(main.nip10Parent(&tags).?));
    }
    // The commonest deprecated form in the wild: ONE unmarked `e` tag, which
    // is both the root and the parent.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex }};
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // A marked root beside an unmarked tag, no reply marker: the root wins
    // (the middle of the reply-orelse-root-orelse-positional chain).
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "", "root" },
            &.{ "e", deep_hex },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // A lone `mention` never makes the note a reply.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex, "", "mention" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // A short id is rejected by the length guard, not a parent.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "zz", "", "reply" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // A 64-char NON-hex id passes the length guard and must be rejected by the
    // decode itself.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "zz" ** 32, "", "reply" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // Uppercase hex decodes: the wire has both casings, and parents match on
    // decoded bytes, not on the raw string.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "AB" ** 32, "", "reply" }};
        try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 32), &(main.nip10Parent(&tags).?));
    }
    // No e tags at all.
    try testing.expect(main.nip10Parent(&.{}) == null);
}
test "arrangeThread seats replies under their parents, siblings oldest-first" {
    const root = [_]u8{0xAA} ** 32;
    // Chronological input: a (to root), b (to root), c (to a), d (to c),
    // e (to root), f (orphan parent never fetched).
    var notes = [_]main.Note{
        threadNote(1, 100, 0xAA),
        threadNote(2, 200, 0xAA),
        threadNote(3, 300, 1),
        threadNote(4, 400, 3),
        threadNote(5, 500, 0xAA),
        threadNote(6, 600, 0x77),
    };
    main.arrangeThread(&notes, root);
    // Conversation order: a, then a's subtree (c, then d), then b, e, f.
    const want_order = [_]u8{ 1, 3, 4, 2, 5, 6 };
    const want_depth = [_]u8{ 1, 2, 3, 1, 1, 1 };
    for (notes, 0..) |note, i| {
        try testing.expectEqual(want_order[i], note.event_id[0]);
        try testing.expectEqual(want_depth[i], note.depth);
    }
}

test "arrangeThread never loops on a parent cycle" {
    const root = [_]u8{0xAA} ** 32;
    // x and y answer each other; z answers the root.
    var notes = [_]main.Note{
        threadNote(1, 100, 2),
        threadNote(2, 200, 1),
        threadNote(3, 300, 0xAA),
    };
    main.arrangeThread(&notes, root);
    // The cycle strands x and y; both surface at the top level after z,
    // still oldest-first (x before y).
    try testing.expectEqual(@as(u8, 3), notes[0].event_id[0]);
    try testing.expectEqual(@as(u8, 1), notes[1].event_id[0]);
    try testing.expectEqual(@as(u8, 2), notes[2].event_id[0]);
    try testing.expectEqual(@as(u8, 1), notes[0].depth);
    try testing.expectEqual(@as(u8, 1), notes[1].depth);
    try testing.expectEqual(@as(u8, 1), notes[2].depth);
}

test "arrangeThread stamps a lone reply without a full pass" {
    const root = [_]u8{0xAA} ** 32;
    var one = [_]main.Note{threadNote(1, 100, 0xAA)};
    main.arrangeThread(&one, root);
    try testing.expectEqual(@as(u8, 1), one[0].depth);
    var none = [_]main.Note{};
    main.arrangeThread(&none, root);
}
fn threadEvent(id_byte: u8, created_at: i64, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0x11} ** 32,
        .created_at = created_at,
        .kind = 1,
        .tags = tags,
        .content = "note",
        .sig = [_]u8{0} ** 64,
    };
}

test "collectThreadIds keeps the thread, anchors orphans, rejects quotes and foreign replies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/thread.mdb", .{dir_buf[0..dir_len]});
    var store = try nostr.store.Store.open(path.ptr, .{});
    defer store.deinit();

    const root_hex = "aa" ** 32;
    const gpa = testing.allocator;
    // The root itself, then a small thread: A answers the root, B answers A,
    // F answers B; E answers a parent that never reached the store but also
    // carries the usual root tag; C only QUOTES the root (mention); D is a
    // reply in a FOREIGN thread that quotes our root in passing.
    _ = try store.ingest(gpa, threadEvent(0xAA, 100, &.{}), .{});
    _ = try store.ingest(gpa, threadEvent(0x01, 110, &.{&.{ "e", root_hex, "", "root" }}), .{});
    _ = try store.ingest(gpa, threadEvent(0x02, 120, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "01" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x06, 130, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "02" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x05, 140, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "99" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x03, 150, &.{&.{ "e", root_hex, "", "mention" }}), .{});
    _ = try store.ingest(gpa, threadEvent(0x04, 160, &.{ &.{ "e", root_hex, "", "mention" }, &.{ "e", "ee" ** 32, "", "root" }, &.{ "e", "dd" ** 32, "", "reply" } }), .{});

    var ids: [100][32]u8 = undefined;
    const n = main.collectThreadIds(&store, [_]u8{0xAA} ** 32, &ids);
    // A, B, F, and the anchored orphan E; never the quote or the foreign reply.
    try testing.expectEqual(@as(usize, 4), n);
    const want = [_]u8{ 0x01, 0x02, 0x06, 0x05 };
    for (want, 0..) |b, i| try testing.expectEqual(b, ids[i][0]);
}

test "nip10References sees ancestor ties, never mentions" {
    const root_hex = "aa" ** 32;
    const root_id = [_]u8{0xAA} ** 32;
    try testing.expect(main.nip10References(&.{&.{ "e", root_hex, "", "root" }}, root_id));
    try testing.expect(main.nip10References(&.{&.{ "e", root_hex }}, root_id));
    try testing.expect(!main.nip10References(&.{&.{ "e", root_hex, "", "mention" }}, root_id));
    try testing.expect(!main.nip10References(&.{&.{ "e", "bb" ** 32, "", "root" }}, root_id));
}
test "a thread groups into one block per conversation, with the branch counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // root
    //  +- a          (depth 1)  a conversation
    //  |   +- c      (depth 2)  shown in place under a
    //  |       +- d  (depth 3)  out of sight, counted against c
    //  +- b          (depth 1)  a second conversation, nothing under it
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xB1, 110, 0xAA),
        threadNote(0xC1, 120, 0xA1),
        threadNote(0xD1, 130, 0xC1),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    // Two conversations, not four notes: that is what a page of a thread counts.
    try testing.expectEqual(@as(usize, 2), blocks.len);

    // The first carries its one visible child, and the child reports the reply
    // hanging below it that the block does not draw.
    try testing.expectEqual(@as(usize, 1), blocks[0].children.len);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &blocks[0].children[0].event_id);
    try testing.expectEqual(@as(usize, 1), blocks[0].deeper[0]);

    // The second is a leaf: no children, nothing counted.
    try testing.expectEqual(@as(usize, 0), blocks[1].children.len);
    try testing.expectEqual(@as(usize, 0), blocks[1].deeper.len);
}

test "a branch several levels deep counts every hidden reply against the child it hangs from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One conversation, five levels down. Only the first child shows; the three
    // below it are the branch.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xC1, 110, 0xA1),
        threadNote(0xD1, 120, 0xC1),
        threadNote(0xE1, 130, 0xD1),
        threadNote(0xF1, 140, 0xE1),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 1), blocks[0].children.len);
    try testing.expectEqual(@as(usize, 3), blocks[0].deeper[0]);
}

test "two children of one reply each keep their own branch count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // a has two replies; only the second continues.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xC1, 110, 0xA1),
        threadNote(0xC2, 120, 0xA1),
        threadNote(0xD1, 130, 0xC2),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 2), blocks[0].children.len);
    // The count follows the child it belongs to, not the block.
    try testing.expectEqual(@as(usize, 0), blocks[0].deeper[0]);
    try testing.expectEqual(@as(usize, 1), blocks[0].deeper[1]);
}

test "a late reply lands after what is already read, however old it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // Two replies read in the first batch, then one that arrives later but was
    // WRITTEN before both. Chronology alone would slot it at the top, moving the
    // ground under a reader mid-thread; arrival order appends it.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 200, 0xAA),
        threadNote(0xB1, 300, 0xAA),
        threadNote(0xC1, 100, 0xAA),
    };
    // Stamped by the REAL stamper, in the order the app would see them: the
    // first two while the thread was still settling, the third afterwards.
    var table = main.arrivalTableForTest();
    main.stampArrivalForTest(&table, notes[0..2], true);
    main.stampArrivalForTest(&table, &notes, true);
    try testing.expectEqual(notes[0].arrival, notes[1].arrival);
    try testing.expect(notes[2].arrival > notes[0].arrival);
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 3), blocks.len);
    // The first batch keeps its chronological order, and the straggler is last.
    try testing.expectEqualSlices(u8, &[_]u8{0xA1} ** 32, &blocks[0].parent.event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xB1} ** 32, &blocks[1].parent.event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &blocks[2].parent.event_id);
}

test "a thread still loading is one batch, however the relays interleave it" {
    // The bug this pins: batching from the first build split a thread's OPENING
    // read into one batch per tick, so the conversation froze into the order the
    // relays happened to answer in rather than the order it was written.
    var table = main.arrivalTableForTest();
    var first = [_]main.Note{threadNote(0xA1, 300, 0xAA)};
    main.stampArrivalForTest(&table, &first, false);

    // A second relay answers with an OLDER reply while the fetch is still out.
    var both = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
    };
    main.stampArrivalForTest(&table, &both, false);
    // Same batch, so the sort put the older one first.
    try testing.expectEqual(both[0].arrival, both[1].arrival);
    try testing.expectEqualSlices(u8, &[_]u8{0xB1} ** 32, &both[0].event_id);

    // The build that settles is still the last build of the opening read, so
    // what it brings is chronological too: the oldest reply leads.
    var settling = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xC1, 50, 0xAA),
    };
    main.stampArrivalForTest(&table, &settling, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &settling[0].event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xA1} ** 32, &settling[2].event_id);

    // NOW a reply that turns up lands after everything already read, however
    // long ago it was written.
    var late = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xC1, 50, 0xAA),
        threadNote(0xD1, 10, 0xAA),
    };
    main.stampArrivalForTest(&table, &late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xD1} ** 32, &late[3].event_id);
    // And re-seeing the same set does not move it back.
    main.stampArrivalForTest(&table, &late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xD1} ** 32, &late[3].event_id);
}

test "the held line counts replies, not conversations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One stranger's reply with two answers under it: ONE conversation, THREE
    // replies. The line says "N replies", so N is three.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xB2, 110, 0xB1),
        threadNote(0xB3, 120, 0xB1),
    };
    for (&notes) |*note| note.pubkey = [_]u8{0x77} ** 32;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 3), main.heldReplies(blocks));
}

test "the thread's own author is never held below their own thread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // Opening a stranger's reply as a thread: their continuation of it must read
    // inline, not behind a collapsed line, or the thread opens with no body.
    const root = [_]u8{0xAA} ** 32;
    const author = [_]u8{0x77} ** 32;
    var notes = [_]main.Note{threadNote(0xB1, 100, 0xAA)};
    notes[0].pubkey = author;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    const split = main.splitByFollowGraphForTest(&ui, blocks, author);
    try testing.expectEqual(@as(usize, 1), split.inside.len);
    try testing.expectEqual(@as(usize, 0), split.outside.len);
}

test "every thread row is planned exactly once" {
    // The row plan is one function so the builder and the estimator cannot drift,
    // and this walks every shape it can take: with and without ancestors, a
    // hidden tail, a held tier open and closed, skeletons, and the empty line.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    var note = threadNote(0xA1, 100, 0);
    var notes = [_]main.Note{
        threadNote(0xB1, 110, 0xA1),
        threadNote(0xB2, 120, 0xA1),
        threadNote(0xB3, 130, 0xA1),
    };
    main.arrangeThread(&notes, [_]u8{0xA1} ** 32);
    const blocks = main.groupThreadBlocks(&ui, &notes);
    const ancestors = [_]main.Ancestor{ .{ .ghost = .missing }, .{} };
    var model = main.Model{};

    const shapes = [_]main.ThreadRows{
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = blocks, .shown = blocks.len, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &ancestors, .blocks = blocks, .shown = 1, .hidden = blocks.len - 1, .hidden_held = blocks.len - 1, .outside = blocks[0..1], .outside_held = 1, .outside_open = false, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &ancestors, .blocks = blocks, .shown = 1, .hidden = blocks.len - 1, .hidden_held = blocks.len - 1, .outside = blocks[0..2], .outside_held = 2, .outside_open = true, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = &.{}, .shown = 0, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = true, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = &.{}, .shown = 0, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = false, .empty = true, .footer = false },
    };

    for (shapes, 0..) |rows, shape| {
        var seen_focal: usize = 0;
        var seen_composer: usize = 0;
        var seen_footer: usize = 0;
        var ancestors_seen: usize = 0;
        var blocks_seen: usize = 0;
        var outside_seen: usize = 0;
        for (0..rows.count()) |i| {
            switch (rows.rowAt(i)) {
                // Each index into a slice must be in range, and each must appear
                // exactly once and in order.
                .ancestor => |ai| {
                    try testing.expectEqual(ancestors_seen, ai);
                    ancestors_seen += 1;
                },
                .focal => seen_focal += 1,
                .composer => seen_composer += 1,
                .block => |bi| {
                    try testing.expectEqual(blocks_seen, bi);
                    blocks_seen += 1;
                },
                .outside_block => |oi| {
                    try testing.expectEqual(outside_seen, oi);
                    outside_seen += 1;
                },
                .footer => seen_footer += 1,
                .show_more, .outside_line, .skeleton, .empty => {},
            }
        }
        errdefer std.debug.print("shape {d}\n", .{shape});
        try testing.expectEqual(@as(usize, 1), seen_focal);
        try testing.expectEqual(@as(usize, 1), seen_composer);
        try testing.expectEqual(@as(usize, @intFromBool(rows.footer)), seen_footer);
        try testing.expectEqual(rows.ancestors.len, ancestors_seen);
        try testing.expectEqual(rows.shown, blocks_seen);
        try testing.expectEqual(if (rows.outside_open) rows.outside.len else 0, outside_seen);
    }
}
test "nip10Root names what the ghost row is missing" {
    // The ghost row says "Root note not on your relays yet" only when the id the
    // chain stops below IS the thread's root, so the claim is only as good as
    // this.
    const root_hex = "01" ** 32;
    const mid_hex = "02" ** 32;
    const quote_hex = "03" ** 32;
    const root_id = [_]u8{0x01} ** 32;

    // A marked root wins wherever it sits, and a marked reply is never the root.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", mid_hex, "", "reply" },
            &.{ "e", root_hex, "wss://r", "root" },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Root(&tags).?));
    }
    // Positional (the deprecated scheme): the FIRST e tag is the root, which is
    // the opposite end from the parent.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "" },
            &.{ "e", mid_hex, "" },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Root(&tags).?));
    }
    // A quoted note is not an ancestor, so it never stands in for the root.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", quote_hex, "", "mention" }};
        try testing.expect(main.nip10Root(&tags) == null);
    }
    // A root's own tags name no root, which is how the walk knows it arrived.
    {
        const tags = [_]nostr.event.Tag{&.{ "p", "ab" ** 32 }};
        try testing.expect(main.nip10Root(&tags) == null);
    }
}
test "one level's arrival order does not disturb another's" {
    // The table was per-app, so opening a reply wiped the order of the thread
    // underneath and it came back reshuffled.
    var a = main.arrivalTableForTest();
    var b = main.arrivalTableForTest();

    // Level A reads two replies, then a late one arrives.
    var a_first = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0) };
    main.stampArrivalForTest(&a, &a_first, true);
    var a_late = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0), threadNote(0xA3, 50, 0) };
    main.stampArrivalForTest(&a, &a_late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xA3} ** 32, &a_late[2].event_id);

    // Level B runs its own opening read in between, which must not move A.
    var b_notes = [_]main.Note{ threadNote(0xB1, 10, 0), threadNote(0xB2, 20, 0) };
    main.stampArrivalForTest(&b, &b_notes, false);

    var a_again = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0), threadNote(0xA3, 50, 0) };
    main.stampArrivalForTest(&a, &a_again, true);
    // The late reply is still last, not back in its written place.
    try testing.expectEqualSlices(u8, &[_]u8{0xA3} ** 32, &a_again[2].event_id);
}
test "every pressable row in a thread washes under the pointer" {
    // One row washing proves the token is bound; this proves each row that got
    // converted actually reads it, since the conversion is per call site and a
    // row left as a layout kind paints nothing at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    const author = [_]u8{0x55} ** 32;
    model.thread_root.pubkey = author;
    // Two conversations, one with a nested child, so a reply block, a nested
    // reply and a branch line are all on screen.
    model.thread_notes[0] = threadNote(0x10, 200, 0xAA);
    model.thread_notes[0].pubkey = author;
    model.thread_notes[0].id = 10;
    model.thread_notes[1] = threadNote(0x11, 300, 0x10);
    model.thread_notes[1].pubkey = author;
    model.thread_notes[1].id = 11;
    model.thread_notes_len = 2;
    // Seat the second under the first, which is what makes one of them a NESTED
    // reply rather than a second conversation.
    main.arrangeThread(model.thread_notes[0..2], model.thread_root.event_id);
    try testing.expectEqual(@as(u8, 2), model.thread_notes[1].depth);

    // A hovered reply washes ITS OWN row and stops. The reply nested under it is
    // a row of its own with its own wash; one band over both is one highlight
    // over two rows, which is the mirror of the two-highlights-on-one-row the
    // design rules out.
    const row = try painted.Painted.renderHovered(arena, &model, "Open thread");
    const frames = row.framesOf("Open thread");
    if (frames.len < 2) return error.ExpectedNestedReply;
    const parent = frames[0];
    const nested = frames[1];
    const wash = row.fillRectOf(theme.palette.surface_hover) orelse return error.NoHoverWash;
    try testing.expectApproxEqAbs(parent.y, wash.y, 0.5);
    // The snap grid rounds the fill up by a pixel.
    try testing.expectApproxEqAbs(parent.width, wash.width, 1.5);
    // It ends before the reply under it begins.
    try testing.expect(wash.y + wash.height <= nested.y + 0.5);

    // A verb inside it does NOT wash: the redesign washes the row, not the
    // control the pointer happens to be over (locked decision 2, and 11e draws
    // the engagement strip at its resting state under a hovered row).
    const verb = try painted.Painted.renderHovered(arena, &model, "Reply");
    const verb_frame = verb.frameOf("Reply") orelse return error.NoVerb;
    try testing.expect(!verb.hasFillAt(
        verb_frame.x + verb_frame.width / 2,
        verb_frame.y + verb_frame.height / 2,
        theme.palette.surface_hover,
    ));
    // And NEITHER DOES THE ROW, which is a limit rather than a choice: the
    // runtime hovers exactly one widget, the nearest that claims a press, so
    // while the pointer is over a verb the row it belongs to is not hovered at
    // all. 11e washes the row with its actions at full strength. Only
    // `data_cell` hands its hover up to `data_row` today, so there is no way to
    // lift it app-side without giving up the verbs' own presses. Asserted so the
    // gap is a recorded state and not a surprise.
    try testing.expect(verb.fillRectOf(theme.palette.surface_hover) == null);
}
test "opening a reply asks about the conversation, not just that reply" {
    // NIP-10 is what makes this necessary. A reply carries an `e` tag for the
    // ROOT and one for its immediate parent, so a grandchild of the note in the
    // reader's hand names its parent and the root, and never the note in
    // between. Asking only about the note pressed therefore returned its direct
    // children and nothing else: no siblings, no parent, no root post, and
    // nothing under those children.
    const focal = [_]u8{0xf0} ** 32;
    const root = [_]u8{0x0a} ** 32;
    var root_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&root_hex, "{x}", .{root}) catch unreachable;

    var out: [2][32]u8 = undefined;

    // A reply in the middle of a thread: both ids, the pressed note first.
    const marked = [_]nostr.event.Tag{
        &.{ "e", &root_hex, "", "root" },
        &.{ "e", "b" ** 64, "", "reply" },
    };
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, 1, &marked, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);
    try testing.expectEqualSlices(u8, &root, &out[1]);

    // A root post has nothing above it, so there is nothing to add.
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &.{}, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);

    // A note that names ITSELF as its root is one id, not the same id twice.
    var focal_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&focal_hex, "{x}", .{focal}) catch unreachable;
    const self_rooted = [_]nostr.event.Tag{&.{ "e", &focal_hex, "", "root" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &self_rooted, &out));

    // A quote is not an ancestor: a mention-marked tag must not be taken as the
    // root, or pressing a note that quotes another opens the wrong thread.
    const quoting = [_]nostr.event.Tag{&.{ "e", &root_hex, "", "mention" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &quoting, &out));

    // An old-style positional reply, with no marker at all, still resolves.
    const positional = [_]nostr.event.Tag{&.{ "e", &root_hex }};
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, 1, &positional, &out));
    try testing.expectEqualSlices(u8, &root, &out[1]);
}
test "thread replies order by arrival then time, and ties keep their order" {
    // sortThreadNotes sorts an array of indices and permutes the notes by
    // following cycles, because a Note is kilobytes and the standard library
    // refuses to sort an element type that large at all. The permutation is the
    // part worth pinning: a cycle walked wrong loses or duplicates a reply.
    var notes: [6]main.Note = .{ .{}, .{}, .{}, .{}, .{}, .{} };

    // Deliberately not already sorted, and with a tie in the middle: two notes
    // sharing (arrival, created_at) must come out in the order they went in.
    const seed = [_]struct { id: i64, arrival: u32, created_at: i64 }{
        .{ .id = 10, .arrival = 2, .created_at = 500 },
        .{ .id = 11, .arrival = 1, .created_at = 900 },
        .{ .id = 12, .arrival = 1, .created_at = 100 },
        .{ .id = 13, .arrival = 3, .created_at = 50 },
        .{ .id = 14, .arrival = 1, .created_at = 900 }, // ties with id 11
        .{ .id = 15, .arrival = 2, .created_at = 400 },
    };
    for (seed, 0..) |sd, i| {
        notes[i].id = sd.id;
        notes[i].arrival = sd.arrival;
        notes[i].created_at = sd.created_at;
    }

    main.sortThreadNotes(&notes);

    // arrival 1: 12 (t=100), then 11 and 14 (both t=900, input order kept).
    // arrival 2: 15 (t=400), then 10 (t=500). arrival 3: 13.
    const want = [_]i64{ 12, 11, 14, 15, 10, 13 };
    for (want, 0..) |id, i| {
        if (notes[i].id != id) {
            std.debug.print("position {d}: want id {d}, got {d}\n", .{ i, id, notes[i].id });
            return error.WrongOrder;
        }
    }

    // Every note still present exactly once: a mishandled cycle drops one and
    // duplicates another, which an order check alone can miss.
    var seen: [6]bool = @splat(false);
    for (notes) |n| {
        const idx: usize = @intCast(n.id - 10);
        if (seen[idx]) return error.DuplicatedNote;
        seen[idx] = true;
    }
    for (seen) |ok| try testing.expect(ok);
}

test "a whole batch arriving at once keeps the order it arrived in" {
    // A thread that loads in one go gives every reply the same arrival stamp,
    // and relays answer in whatever order they please, so this is the case that
    // decides whether a conversation can reshuffle under the reader between
    // rebuilds.
    //
    // Honest about what this test is: it pins the behaviour, it does not catch a
    // regression. Swapping the stable sort for the unstable one leaves it green,
    // because the unstable sort happens to preserve equal elements at these
    // sizes too. That is exactly why the comparator carries no tiebreak: a
    // second mechanism no probe can falsify is one to delete, not to keep.
    const n = 40;
    var notes: [n]main.Note = @splat(.{});
    for (0..n) |i| {
        notes[i].id = @intCast(1000 + i);
        notes[i].arrival = 7; // one batch
        notes[i].created_at = 12345; // written the same second
    }

    main.sortThreadNotes(&notes);

    for (0..n) |i| {
        const want: i64 = @intCast(1000 + i);
        if (notes[i].id != want) {
            std.debug.print("tie at {d}: want id {d}, got {d}\n", .{ i, want, notes[i].id });
            return error.TiesReordered;
        }
    }
}
test "a comment's parent and root are read from its own vocabulary" {
    // NIP-22 has no marker vocabulary at all, and field 4 of its `e` is the
    // AUTHOR pubkey where NIP-10 puts a marker. Reading one as the other is how
    // a reader quietly starts mistaking every comment for an unmarked
    // positional reply, so the two readers stay separate and a dispatcher picks.
    const root_id = [_]u8{0xE1} ** 32;
    const parent_id = [_]u8{0xE2} ** 32;
    var root_hex: [64]u8 = undefined;
    var parent_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&root_hex, "{x}", .{root_id}) catch unreachable;
    _ = std.fmt.bufPrint(&parent_hex, "{x}", .{parent_id}) catch unreachable;

    // The ordinary shape: uppercase names the root, lowercase the note being
    // answered, and the fourth field is a pubkey rather than a marker.
    const nested = [_]nostr.event.Tag{
        &.{ "E", &root_hex, "wss://relay.example", "f" ** 64 },
        &.{ "K", "1" },
        &.{ "e", &parent_hex, "wss://relay.example", "a" ** 64 },
        &.{ "k", "1111" },
    };
    try testing.expectEqualSlices(u8, &parent_id, &(main.nip22Parent(&nested).?));
    try testing.expectEqualSlices(u8, &root_id, &(main.nip22Root(&nested).?));

    // A top-level comment answers the root directly and carries no lowercase
    // `e` at all, so the parent falls back to the uppercase.
    const top = [_]nostr.event.Tag{
        &.{ "E", &root_hex, "", "f" ** 64 },
        &.{ "K", "30023" },
    };
    try testing.expectEqualSlices(u8, &root_id, &(main.nip22Parent(&top).?));

    // A comment on a URL or a hashtag has no event parent at all. Calling one
    // of those a reply to something would be inventing a tie.
    const on_a_url = [_]nostr.event.Tag{
        &.{ "I", "https://example.com/a" },
        &.{ "K", "web" },
    };
    try testing.expect(main.nip22Parent(&on_a_url) == null);
    try testing.expect(main.nip22Root(&on_a_url) == null);

    // And the dispatcher keeps the two vocabularies apart. These same tags read
    // as NIP-10 would answer with the LAST plain `e`, which is the parent here
    // by luck; the root is what separates them, because NIP-10 has no `E`.
    try testing.expectEqualSlices(u8, &parent_id, &(main.replyParent(main.comment_kind, &nested).?));
    try testing.expectEqualSlices(u8, &root_id, &(main.replyRoot(main.comment_kind, &nested).?));

    // And this is why the dispatcher exists rather than one reader with a
    // branch inside it. Handed the SAME tags, the NIP-10 reader finds no `root`
    // marker (field 4 is a pubkey), takes the first unmarked `e`, and answers
    // that the root is the PARENT. Not null, not an error: a confident wrong
    // answer, which is the shape of bug that survives review.
    try testing.expectEqualSlices(u8, &parent_id, &(main.replyRoot(1, &nested).?));
}

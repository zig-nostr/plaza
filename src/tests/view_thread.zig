//! Tests of view_thread.zig. The thread screen: rows, extents, replies and ancestors.

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

test "threadIndentLevels caps the visual indent" {
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(0));
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(1));
    try testing.expectEqual(@as(usize, 1), main.threadIndentLevels(2));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(4));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(255));
}
test "a list's retained extent context survives the arena that built it" {
    // The SDK keeps `extent_context` and calls the estimator through it long
    // after the build returned: in a post-layout measure pass, and since 0.7.2
    // from inside `virtualWindow` on a LATER build. Both lists handed it an
    // arena-allocated view context full of slices. The runtime rotates a small
    // set of arenas and resets the one it is about to build into, so a context
    // handed over on build N is read on build N+2 with its slices pointing at
    // whatever the new build has since put there. It segfaulted in
    // `noteRowEstimateWith` on a mouse-up over a person's page.
    //
    // This builds a view, DROPS the arena entirely, and then calls the estimator
    // exactly as the SDK would. Under the old shape that reads freed memory;
    // under a table of numbers with process lifetime it cannot.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const author = [_]u8{0x55} ** 32;
    const Case = struct { name: []const u8, arm: *const fn (*Model) void };
    const cases = [_]Case{
        .{ .name = "a person", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_profile = [_]u8{0x55} ** 32;
            }
        }.f },
        .{ .name = "a thread", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
            }
        }.f },
    };

    for (cases) |c| {
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root.pubkey = author;
        for (0..40) |i| {
            model.thread_notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
            model.thread_notes[i].id = @intCast(600 + i);
            model.thread_notes[i].pubkey = author;
            model.thread_notes[i].event_id = [_]u8{@intCast(i + 1)} ** 32;
        }
        model.thread_notes_len = 40;
        c.arm(&model);

        const context = if (model.viewing_profile != null)
            main.profileExtentTableForTest(0)
        else
            main.threadExtentTableForTest(0);

        {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            // NOT deferred: the arena is destroyed on purpose below, before the
            // estimator is called, which is the whole point.
            const arena = arena_state.allocator();
            _ = try painted.Painted.render(arena, &model);
            arena_state.deinit();
        }

        const rows = main.extentTableLenForTest(context);
        if (rows < 5) {
            std.debug.print("{s}: only {d} rows, too few to prove anything\n", .{ c.name, rows });
            return error.TooFewRows;
        }
        // Every row, after the arena is gone. A table of zeroes would also be
        // "safe", so the total has to be a real height.
        var total: f32 = 0;
        for (0..rows) |i| total += main.rowExtentFromTableForTest(context, @intCast(i));
        if (!(total > 100)) {
            std.debug.print("{s}: {d} rows measure {d:.1} in total\n", .{ c.name, rows, total });
            return error.ExtentsLostWithTheArena;
        }
    }
}

test "an extent context that is not a table is refused, not read" {
    // The estimator is typed now, so the wrong FUNCTION will not compile. The
    // wrong CONTEXT still would: `extent_context` is `?*const anyopaque` and
    // takes any pointer, so wiring the table's reader to a view context would
    // read one struct as the other and hand the list garbage heights without
    // saying anything. The table carries a tag for exactly that.
    var not_a_table: [64]u8 = [_]u8{0xAB} ** 64;
    const height = main.rowExtentFromTableForTest(&not_a_table, 3);
    try testing.expectApproxEqAbs(main.quiet_row_extent, height, 0.001);

    // And a real table still answers with a real height.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;
    _ = try painted.Painted.render(arena_state.allocator(), &model);
    const table = main.threadExtentTableForTest(0);
    try testing.expect(main.extentTableLenForTest(table) > 0);
    try testing.expect(main.rowExtentFromTableForTest(table, 0) > 0);
}

test "the thread header counts notes below, not replies, so it never contradicts the stat row" {
    // The header counts every descendant and the root's stat row counts direct
    // replies. Both said "replies", so a root with two answers and one answer to
    // an answer read "3 replies" over "2 replies" on one screen.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Build = struct {
        var model: Model = .{};
        fn header(ui: *main.AppUi) main.AppUi.Node {
            return main.threadHeader(ui, &model);
        }
    };
    Build.model = .{};
    Build.model.viewing_thread = 1;
    Build.model.thread_root.id = 1;
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    const cases = [_]struct { n: usize, text: []const u8 }{
        .{ .n = 1, .text = "1 note below" },
        .{ .n = 3, .text = "3 notes below" },
    };
    for (cases) |c| {
        Build.model.thread_notes_len = c.n;
        const p = try painted.Painted.renderPiece(arena, &Build.model, Build.header, main.window_width, 200);
        var found = false;
        for (p.layout.nodes) |node| {
            const t = node.widget.text;
            if (std.mem.indexOf(u8, t, "repl") != null) return error.HeaderSaysReplies;
            if (std.mem.eql(u8, t, c.text)) found = true;
        }
        try testing.expect(found);
    }
}

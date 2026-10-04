//! Tests of relay_table.zig. The relay table: its slots, the bootstrap set, and the relays file.

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
const findAnyText = harness.findAnyText;
const hint_a = harness.hint_a;
const hint_b = harness.hint_b;
const hint_c = harness.hint_c;
const seedInbox = harness.seedInbox;
const seedRelayLists = harness.seedRelayLists;
const threadNote = harness.threadNote;
const ui_fmt_pool = harness.ui_fmt_pool;

test "the status bar summarises the relay pool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Some relays live: the status bar shows the live count out of the pool
    // (the dot beside it carries the color; the text carries the fact).
    main.resetRelaysForTest();
    var live = main.initialModel();
    live.stage = .ready;
    live.live_relays = 3;
    live.relay_count = main.relayCount();
    const live_tree = try buildTree(arena, &live);
    try testing.expect(findAnyText(live_tree.root, ui_fmt_pool(arena, 3)) != null);

    // The whole pool down: the empty body says so while the bar keeps the count.
    var down = main.initialModel();
    down.stage = .ready;
    down.offline_relays = main.bootstrap_relay_count_for_test;
    down.relay_count = main.relayCount();
    const down_tree = try buildTree(arena, &down);
    try testing.expect(findAnyText(down_tree.root, "Can't reach any relay. Retrying…") != null);
    try testing.expect(findAnyText(down_tree.root, ui_fmt_pool(arena, 0)) != null);
}
test "a deep back-stack still lays out" {
    // The SDK REFUSES a view past `max_canvas_widget_nodes_per_view`, whole: not
    // a truncated frame, no frame at all. Every mounted level used to build its
    // own rows, so six levels of a busy thread crossed the ceiling and the window
    // went blank. Occluded levels build nothing now, and this is the guard.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    const author = [_]u8{0x55} ** 32;
    model.thread_root.pubkey = author;

    // A page of conversation: twenty replies with two nested children each, all
    // by the thread's own author so none of them are held below the graph line.
    var n: usize = 0;
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        model.thread_notes[n] = threadNote(0x10 + i, 200 + @as(i64, i), 0xAA);
        model.thread_notes[n].pubkey = author;
        model.thread_notes[n].id = @as(i64, i) + 10;
        n += 1;
        var k: u8 = 0;
        while (k < 2) : (k += 1) {
            model.thread_notes[n] = threadNote(0x60 + i * 2 + k, 300 + @as(i64, i), 0x10 + i);
            model.thread_notes[n].pubkey = author;
            model.thread_notes[n].id = 1000 + @as(i64, i) * 2 + @as(i64, k);
            n += 1;
        }
    }
    model.thread_notes_len = n;

    for (0..main.thread_depth_max) |d| {
        model.thread_stack[d] = .{ .note = threadNote(0xC0 + @as(u8, @intCast(d)), 50, 0) };
        model.thread_stack[d].note.id = 500 + @as(i64, @intCast(d));
        model.thread_stack[d].note.pubkey = author;
    }
    // Settings at its LARGEST, not its default: eight relays is the cap, six
    // suggestions is the cap, and a local key adds the backup card with the
    // secret revealed. Measuring the sheet a fresh install happens to build
    // would be measuring the easy case, and the ceiling is not crossed by the
    // easy case.
    main.resetRelaysForTest();
    for (0..main.max_relays_for_test) |r| {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "wss://relay-{d}.a-fairly-long-hostname.example.com", .{r});
        _ = main.addRelayForTest(url, true, true);
    }
    const suggestion_tags = [_]nostr.event.Tag{
        &.{ "r", "wss://suggested-one.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-two.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-three.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-four.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-five.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-six.a-fairly-long-hostname.example.com", "write" },
    };
    main.ingestRelayListForTest(.{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &suggestion_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    });
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    // Every depth the stack can reach, including full, and with the Settings
    // sheet over it. Settings is a SHEET now rather than a screen, so it no
    // longer replaces this tree, it is added to it: the deepest stack plus the
    // largest sheet is the worst frame the app can be asked to build, and it is
    // the one that has to fit.
    main.resetInboxForTest();
    seedInbox(main.inbox_page * 2, 0xB0, 1_800_000_000);
    defer main.resetInboxForTest();
    // A feed as long as the buffer holds, under the thread. The windowed list
    // is supposed to build only what the viewport needs, and a thread over it
    // occludes even that, so this should cost nothing; it is here so that if
    // either ever stops being true, this is where it is caught.
    for (0..200) |k| {
        model.notes[k] = threadNote(0x77, 1_800_000_000, 0);
        model.notes[k].id = @intCast(k + 5000);
        model.notes[k].pubkey = author;
    }
    model.notes_len = 200;

    // Everything that can be on screen at once, over every depth the stack can
    // reach. A sheet is LAYERED on the feed rather than swapping it out, so the
    // frame the app has to draw is the base plus the sheet, and the base at
    // depth six is the most expensive tree in the app.
    const Frame = struct { name: []const u8, arm: *const fn (*Model) void };
    const frames = [_]Frame{
        .{ .name = "feed", .arm = struct {
            fn f(_: *Model) void {}
        }.f },
        .{ .name = "settings", .arm = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
            }
        }.f },
        .{ .name = "notifications", .arm = struct {
            fn f(m: *Model) void {
                m.notifications_open = true;
            }
        }.f },
        .{ .name = "compose", .arm = struct {
            fn f(m: *Model) void {
                m.composing = true;
            }
        }.f },
        .{ .name = "join", .arm = struct {
            fn f(m: *Model) void {
                m.joining = true;
            }
        }.f },
        .{ .name = "edit profile", .arm = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
                m.editing_profile = true;
            }
        }.f },
    };

    const thread_root = model.thread_root;
    for (frames) |frame| {
        // Depth 0 here means NO thread at all, not a thread at the bottom of the
        // stack: with a thread open the feed's own rows are occluded and cost
        // nothing, so a sweep that always has one open never measures the feed.
        // Live, a sheet over a plain loaded feed is the second most expensive
        // frame in the app, and it was the one this loop could not see.
        for (0..main.thread_depth_max + 2) |step| {
            model.stage = .ready;
            model.notifications_open = false;
            model.composing = false;
            model.joining = false;
            model.editing_profile = false;
            const depth = if (step == 0) 0 else step - 1;
            model.viewing_thread = if (step == 0) 0 else 1;
            model.thread_root = if (step == 0) .{} else thread_root;
            model.thread_stack_len = depth;
            frame.arm(&model);
            const p = painted.Painted.render(arena, &model) catch |err| {
                std.debug.print("{s} at step {d} refused: {s}\n", .{ frame.name, step, @errorName(err) });
                return err;
            };
            // A tenth of the ceiling has to be left over. Not because the
            // eleventh-hour node is special, but because the ceiling is a CLIFF
            // (the view is refused whole, so the window stops drawing) and a
            // frame that clears it by fifty nodes is one relay row, one section
            // or one more list item away from the app going blank in a state
            // nobody will think to test. The most expensive frame here is
            // notifications over the deepest thread, and it clears by 133.
            const headroom = native_sdk.runtime.max_canvas_widget_nodes_per_view / 10;
            if (p.layout.nodes.len + headroom >= native_sdk.runtime.max_canvas_widget_nodes_per_view) {
                std.debug.print(
                    "{s} at step {d}: {d} nodes, ceiling is {d}, and {d} of it has to stay free\n",
                    .{ frame.name, step, p.layout.nodes.len, native_sdk.runtime.max_canvas_widget_nodes_per_view, headroom },
                );
                return error.NodeCeilingCrossed;
            }
        }
    }
}
test "a relay badge walks the three things a relay can be for" {
    // NIP-65's whole vocabulary is read and write. The badge walks both, then
    // read, then write, and back: a relay that is neither is a relay you have
    // removed, and there is a button for that.
    main.resetRelaysForTest();
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = false }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = false, .write = true }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
}

test "a removed relay leaves its seat, and the next add takes it back" {
    // A slot index is a promise: the outbox's ack bits and the per-note relay
    // marks both name one. Removing must therefore empty a seat, never shift
    // the seats after it.
    main.resetRelaysForTest();
    const before = main.relaySlots();
    main.removeRelayForTest(1);
    try testing.expect(main.relayAt(1) == null);
    // The relay in slot 2 did not slide down into the hole.
    try testing.expect(main.relayAt(2) != null);
    try testing.expectEqual(before, main.relaySlots());

    // And the empty seat is reused, so remove-then-add does not consume the pool.
    try testing.expectEqual(@as(?usize, 1), main.addRelayForTest("wss://relay.example.com", true, true));
    try testing.expectEqual(before, main.relaySlots());
}

test "the pool refuses what is not a relay, and refuses to overflow" {
    main.resetRelaysForTest();
    try testing.expect(!main.isRelayUrl("https://relay.example.com"));
    try testing.expect(!main.isRelayUrl("wss://localhost"));
    try testing.expect(!main.isRelayUrl("wss://user:pass@relay.example.com"));
    // A follow's published list really does carry plain `ws://` relays, and
    // taking one would put every filter this reader sends on the wire in clear.
    try testing.expect(!main.isRelayUrl("ws://relay.example.com"));
    try testing.expect(main.isRelayUrl("wss://relay.example.com"));

    // The pool fills to its cap and then refuses, rather than silently
    // dropping, because the card says so. Counted from the bootstrap list's own
    // size and the cap, so changing either is one edit here and not a hunt for
    // whichever letter of the alphabet happened to be the last accepted one.
    const room = main.max_relays_for_test - main.bootstrap_relay_count_for_test;
    const names = [_][]const u8{
        "wss://a.example.com", "wss://b.example.com", "wss://c.example.com",
        "wss://d.example.com", "wss://e.example.com", "wss://f.example.com",
    };
    try testing.expect(names.len > room);
    for (names[0..room]) |url| try testing.expect(main.addRelayForTest(url, true, true) != null);
    try testing.expectEqual(main.max_relays_for_test, main.relayCount());
    try testing.expect(main.addRelayForTest(names[room], true, true) == null);
    // Adding one already in the pool returns its seat rather than taking a new one.
    try testing.expectEqual(@as(?usize, 0), main.addRelayForTest("wss://relay.damus.io", true, true));
}

test "their published relay list becomes the pool, once, and never over an edit" {
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com" },
        &.{ "r", "wss://two.example.com", "read" },
        &.{ "r", "wss://three.example.com", "write" },
        // Junk in a tag is not a relay: it is skipped, not dialed.
        &.{ "r", "http://four.example.com" },
        &.{"p"},
    };
    var ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };

    // Ownership is meaningless without an account: it is the whole point of the
    // record that it says WHOSE list this is.
    main.setIdentityForTest([_]u8{5} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://one.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = false }), main.relayReadWriteForTest(1));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = false, .write = true }), main.relayReadWriteForTest(2));
    try testing.expectEqual(@as(usize, 3), main.relayCount());
    try testing.expect(main.relayIsMineForTest());

    // A second list does not get to arrive: the pool is theirs now, and a later
    // event must not undo what they set here.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());

    // An edit made while an event was in flight wins over the event.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(!main.adoptRelayListForTest());

    // A list with nothing usable in it is not a list: keeping five relays beats
    // being left with none.
    const empty_tags = [_]nostr.event.Tag{&.{ "r", "http://nope.example.com" }};
    ev.tags = &empty_tags;
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.relayCount());
}
test "the ack denominator counts only relays a note is actually sent to" {
    // An outbox entry is owed to the relays that take writes. A relay the reader
    // set to read-only was never asked to hold the note, so counting it would
    // leave every note permanently short of its acks.
    main.resetRelaysForTest();
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.writeRelayCount());
    main.cycleRelayForTest(0); // R·W -> R
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.writeRelayCount());
    main.cycleRelayForTest(0); // R -> W
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.writeRelayCount());
    main.removeRelayForTest(0);
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.writeRelayCount());
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.relayCount());
}
test "an unknown NIP-65 marker narrows nothing" {
    // NIP-65 knows "read" and "write". Reading any other word as "neither" would
    // produce a relay this app still dials and still counts while claiming it is
    // for nothing.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com", "readwrite" },
        &.{ "r", "wss://two.example.com", "" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 5,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(1));
    try testing.expectEqualStrings("R·W", main.relayBadgeTextForTest(0));
}

test "one relay under two spellings takes one seat" {
    main.resetRelaysForTest();
    const first = main.addRelayForTest("wss://relay.example.com", true, true).?;
    // A trailing slash and the scheme's case are noise, and addRelay must dedupe
    // the way the rest of the pool does, or the reader gets two rows for one
    // relay and the app dials it twice.
    try testing.expectEqual(@as(?usize, first), main.addRelayForTest("wss://relay.example.com/", true, true));
    try testing.expectEqual(@as(?usize, first), main.addRelayForTest("WSS://Relay.example.com", true, true));
    try testing.expectEqual(main.bootstrap_relay_count_for_test + 1, main.relayCount());
}
test "signing out leaves the account's relay list with the account" {
    // The list came from their kind:10002 and names where they read and write.
    // Carrying it into the next account would route a stranger's notes through
    // the previous reader's relays.
    main.resetRelaysForTest();
    _ = main.addRelayForTest("wss://theirs.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayIsMineForTest());

    main.resetRelaysToBootstrapForTest();
    try testing.expect(!main.relayIsMineForTest());
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.relayCount());
    try testing.expectEqualStrings("wss://relay.damus.io", main.relayUrlAt(0));
    try testing.expectEqual(@as(usize, 0), main.relaySuggestionCount());
}
test "a removed relay is not put back by the splice that protects the rest" {
    // The splice carries forward every relay the pool has no seat for, and a
    // relay the reader just removed looks exactly like one of those. Without a
    // ledger of removals the splice would undo every removal press.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{78} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/removed.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.forgetRelayRemovalsForTest();
    main.setIdentityForTest([_]u8{78} ** 32);
    defer main.clearIdentityForTest();

    const published = [_]nostr.event.Tag{
        &.{ "r", "wss://staying.example.com" },
        &.{ "r", "wss://going.example.com" },
    };
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &published, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    _ = main.addRelayForTest("wss://staying.example.com", true, true);
    const going = main.addRelayForTest("wss://going.example.com", true, true).?;
    main.markRelaysMineForTest();

    // The press. `removeRelayForTest` drives the same function the button does,
    // so the ledger is written by the code under test rather than by the test.
    main.removeRelayForTest(going);

    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.publishRelayListForTest(&fx));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10002).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "staying.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "going.example.com") == null);
}
test "a relay that kept its seat keeps its connection" {
    // Signing out reads `0/5 relays` forever, on a pool where nothing is wrong.
    //
    // The status table is written by the ingest threads, and each of them spends
    // almost all of its life parked in a blocking read. Clearing a slot's status
    // from the UI thread is therefore not a value that goes stale and refreshes:
    // it is a value nothing will ever put back, because the thread only looks up
    // when its relay speaks, and a quiet relay does not. So a pool reset that
    // wiped every row left the bar reading nothing-is-connected over five live
    // sockets.
    main.resetRelaysToBootstrapForTest();
    const total = main.relayCount();
    try testing.expect(total >= 2);

    // Every relay reporting in, the way the threads do once dialed.
    for (0..total) |i| main.setRelayStatusForTest(i, true);
    try testing.expectEqual(total, main.liveRelayCountForTest());

    // A sign-out resets the pool to the bootstrap list. It ALREADY is the
    // bootstrap list, so not one seat changes hands and not one socket is
    // touched. The count has to survive that.
    main.resetRelaysToBootstrapForTest();
    try testing.expectEqual(total, main.liveRelayCountForTest());
    try testing.expectEqual(total, main.relayCount());

    // And the rule still holds where it should. Adopting the reader's own
    // kind:10002 puts DIFFERENT relays in those seats, so every row recorded
    // against them is about the previous occupant and has to go: a status left
    // at connected would count a socket that was never opened.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://mine-one.example.com" },
        &.{ "r", "wss://mine-two.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.setIdentityForTest([_]u8{9} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();
    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://mine-one.example.com", main.relayUrlAt(0));
    var live_after: usize = 0;
    for (0..main.relaySlots()) |i| {
        if (main.relayStatusConnectedForTest(i)) live_after += 1;
    }
    try testing.expectEqual(@as(usize, 0), live_after);

    main.resetRelaysToBootstrapForTest();
}

test "signing out drops the rows of the relays it is signing out of" {
    // The KEEP half of the sign-out path is covered above, by a pool that is
    // already the bootstrap list. This is the other half on the same path, and
    // it is the one the whole guard could be deleted from while the suite
    // stayed green: an account with a list of its OWN signs out, every seat
    // changes hands, and every row has to go with them.
    main.setIdentityForTest([_]u8{0x52} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.resetRelaysForTest();

    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://only-mine-one.example.com" },
        &.{ "r", "wss://only-mine-two.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x52} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://only-mine-one.example.com", main.relayUrlAt(0));

    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);
    try testing.expectEqual(main.relayCount(), main.liveRelayCountForTest());

    // Sign out. Not one of those relays is in the bootstrap list, so not one
    // seat keeps its occupant, and the bar must not report a single live
    // connection to relays this reader no longer talks to.
    main.resetRelaysToBootstrapForTest();
    try testing.expectEqual(@as(usize, 0), main.liveRelayCountForTest());
}
test "the pool the app is born with holds no retired relay" {
    // relay.nostr.band was retired, and a bootstrap list is the one place a dead
    // relay costs every first run a connection attempt that can never succeed.
    // Written as a rule over the list rather than an assertion about one name,
    // so the next one that goes is caught by the same line.
    main.resetRelaysForTest();
    const retired = [_][]const u8{"nostr.band"};
    for (0..main.relayCount()) |i| {
        const url = main.relayUrlAt(i);
        for (retired) |dead| {
            if (std.mem.indexOf(u8, url, dead) != null) {
                std.debug.print("bootstrap pool still carries {s}\n", .{url});
                return error.RetiredRelayInBootstrap;
            }
        }
    }
    try testing.expect(main.relayCount() >= 3);
}
test "the status bar is on the floor of the canvas at every height" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reported as an intermittent crop of the bottom bar. It is NOT the layout:
    // this holds the bar to the floor of whatever canvas the app is handed, at
    // every height from below the window's own minimum to well past its default,
    // with the pool healthy and with it dead (the offline banner is extra height
    // above the bar, which is the shape most likely to push it off). If the crop
    // is ever traced to Plaza rather than to the size the platform hands it, this
    // is the line that should have caught it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    for ([_]bool{ true, false }) |pool_up| {
        main.resetRelaysForTest();
        for (0..main.max_relays_for_test) |r| main.setRelayStatusForTest(r, pool_up);
        var model = main.initialModel();
        model.stage = .ready;

        var first_gap: ?f32 = null;
        var h: f32 = 600;
        while (h <= 900) : (h += 25) {
            const p = try painted.Painted.renderAt(arena, &model, main.window_width, h);
            const chip = p.frameOf("Relays") orelse {
                std.debug.print("no relay chip at height {d:.0}\n", .{h});
                return error.NoStatusBar;
            };
            const gap = h - (chip.y + chip.height);
            if (gap < 0) {
                std.debug.print(
                    "at height {d:.0} the status bar ends at {d:.1}, past the floor\n",
                    .{ h, chip.y + chip.height },
                );
                return error.StatusBarOffTheFloor;
            }
            // And it is the SAME distance from the floor every time: a bar that
            // drifts up as the window grows is one the reader loses at some
            // other size, which is what "sometimes" would look like.
            if (first_gap) |g0| {
                if (@abs(gap - g0) > 0.5) {
                    std.debug.print(
                        "the status bar sits {d:.1} above the floor at {d:.0} and {d:.1} at 600\n",
                        .{ gap, h, g0 },
                    );
                    return error.StatusBarDrifts;
                }
            } else first_gap = gap;
        }
    }
}
test "asking the pool with nothing connected asks nobody, and does not dial" {
    // The whole point is that it uses sockets that already exist. With no live
    // connection there is nothing to write to, and the honest result is zero
    // relays asked rather than a connection opened to make the number look
    // better. A test binary must never reach the network.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example.com", true, true);

    const kinds = [_]u16{0};
    const authors = [_][32]u8{[_]u8{7} ** 32};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    try testing.expectEqual(@as(usize, 0), main.askPoolForTest(main.oneShotSubPrefixForTest ++ "profiles", &filters));
}

test "a write-only relay is not asked a question" {
    // Asking a relay that takes writes and answers no filters is asking it the
    // wrong thing. It keeps its socket, for publishing.
    //
    // Asserted on WHICH SLOTS are chosen, not on how many were asked. With no
    // live socket in a test every slot is skipped anyway, so a count passes
    // whether or not the read marker is honoured: removing the check failed
    // nothing when this test was first written.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://reads.example.com", true, false);
    _ = main.addRelayForTest("wss://writeonly.example.com", false, true);
    _ = main.addRelayForTest("wss://both.example.com", true, true);

    var slots: [8]usize = undefined;
    const n = main.askableSlotsForTest(&slots);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 0), slots[0]);
    try testing.expectEqual(@as(usize, 2), slots[1]);
}
test "a relay carrying only people the pool already covers twice is not dialled" {
    // What the pre-seed is for. The reader's own relays are already connected,
    // so whoever they carry is already reached; a routed slot spent on a relay
    // carrying only those people is a thread and a socket that reach nobody
    // new. Without counting the pool's coverage first, the greedy sees a big
    // number and takes it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/preseed.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    // TWO of the reader's own relays, so the crowd on them reaches the coverage
    // target without any routed relay at all.
    _ = main.addRelayForTest("wss://m1.example.com", true, true);
    _ = main.addRelayForTest("wss://m2.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The crowd writes to both of the reader's relays AND to a third the reader
    // is not on. That third one reaches nobody new. One more person writes only
    // somewhere else, and IS worth a slot.
    const crowd = [_][]const u8{ "wss://m1.example.com", "wss://m2.example.com", "wss://redundant.example.com" };
    const alone = [_][]const u8{"wss://only-here.example.com"};
    const specs = [_][]const []const u8{ &crowd, &crowd, &crowd, &crowd, &alone };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var saw_redundant = false;
    var saw_only_here = false;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        const u = main.discoveredUrlCopy(i, &buf) orelse continue;
        if (std.mem.eql(u8, u, "wss://redundant.example.com")) saw_redundant = true;
        if (std.mem.eql(u8, u, "wss://only-here.example.com")) saw_only_here = true;
    }
    // The one that reaches somebody new is dialled; the one that does not is
    // not, even though four follows write there and only one writes to the
    // other. Popularity would have picked it first.
    try testing.expect(saw_only_here);
    try testing.expect(!saw_redundant);
}
test "the indexers are asked, never joined, and never published as ours" {
    // They answer one question and are not part of the reader's identity. The
    // failure to avoid is Notedeck's, where the bootstrap set is spliced into
    // the user's own advertised relays the first time they edit their list, so
    // editing one relay publishes four you never chose.
    main.resetRelaysForTest();

    const before = main.relaySlots();
    for (main.indexerRelaysForTest()) |url| {
        try testing.expect(std.mem.startsWith(u8, url, "wss://"));
    }
    // Naming them does not dial them into the pool.
    try testing.expectEqual(before, main.relaySlots());

    // And the chunk stays inside what a relay will accept in one filter: an
    // unchunked 2000-author array is past the limit on most, and they truncate
    // or CLOSE without saying which.
    try testing.expect(main.indexerChunkForTest() <= 100);
    try testing.expect(main.indexerChunkForTest() > 0);
}
test "copying your profile address names the relays you publish to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{0x54} ** 32;
    main.setIdentityForTest(pk);
    defer main.clearIdentityForTest();
    const mine = main.activePubkeyForTest() orelse return error.NoIdentity;

    // The pool is whatever the process holds: pin it to two write relays, one
    // read-only relay and one nobody else could reach.
    main.clearRelaysForTest();
    defer main.resetRelaysForTest();
    _ = main.addRelayForTest(hint_a, true, true);
    _ = main.addRelayForTest(hint_b, true, false);
    _ = main.addRelayForTest("wss://127.0.0.1:7777", true, true);
    _ = main.addRelayForTest(hint_c, false, true);

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.copy_nprofile, &fx);
    const ptr = try nostr.nip19.decodeNprofile(arena, main.lastClipboardForTest());
    try testing.expectEqualSlices(u8, &mine, &ptr.pubkey);
    try testing.expectEqual(@as(usize, 2), ptr.relays.len);
    try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    try testing.expectEqualStrings(hint_c, ptr.relays[1]);

    // Settings still copies the bare npub, which is what a tool that takes a key
    // wants.
    main.update(&model, Msg.copy_npub, &fx);
    try testing.expect(std.mem.startsWith(u8, main.lastClipboardForTest(), "npub1"));
}
test "older notes are asked of the relays the person publishes to, then the reader's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/targets.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.clearRelaysForTest();
    defer main.clearRelaysForTest();
    _ = main.addRelayForTest("wss://reader.example.com", true, true);
    _ = main.addRelayForTest("wss://writeonly.example.com", false, true);

    const who = [_]u8{0x67} ** 32;
    const list = nostr.event.Event{
        .id = [_]u8{0x67} ** 32,
        .pubkey = who,
        .created_at = 1_800_000_000,
        .kind = 10002,
        .tags = &.{
            &.{ "r", "wss://their.example.com" },
            &.{ "r", "wss://readonly.example.com", "read" },
            &.{ "r", "wss://reader.example.com", "write" },
            &.{ "r", "wss://their.example.com" },
        },
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    _ = try store.ingest(arena, list, .{});

    var out: [12][96]u8 = undefined;
    var lens: [12]u8 = undefined;
    const n = main.profileTargetsForTest(who, &out, &lens);
    // Their write relays in the order they listed them (a repeat and a read-only
    // relay left out), then the reader's read relays they did not already name:
    // the reader's own relay is named by both and asked once.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("wss://their.example.com", out[0][0..lens[0]]);
    try testing.expectEqualStrings("wss://reader.example.com", out[1][0..lens[1]]);

    // Somebody whose list has not arrived is asked of the reader's relays alone.
    const stranger = [_]u8{0x68} ** 32;
    const m = main.profileTargetsForTest(stranger, &out, &lens);
    try testing.expectEqual(@as(usize, 1), m);
    try testing.expectEqualStrings("wss://reader.example.com", out[0][0..lens[0]]);
}
test "a relay address with a control byte, a space or a bad port is refused" {
    // The address is written to the relays file one relay per line and sent in
    // the handshake's request line, so a BEL in it was listed, counted, dialled
    // and saved.
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/\x07"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/a\nb"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/a b"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io\x7f"));
    try testing.expect(!main.isRelayUrl("wss://relay.example.com:notaport"));
    try testing.expect(main.isRelayUrl("wss://relay.damus.io/"));
    try testing.expect(main.isRelayUrl("wss://relay.example.com:7447/path"));

    // And through the Add press, which is the door the reader uses.
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    const before = main.relayCount();
    model.relay_buffer.set("wss://relay.damus.io/\x07");
    main.update(&model, .relay_add, &fx);
    try testing.expectEqual(before, main.relayCount());
    try testing.expect(model.relay_error);
    try testing.expectEqualStrings("A relay address starts with wss:// and names a host.", model.relay_status());
}

test "the last relay cannot be removed, and the press says why" {
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    // Down to one by the same function the button calls.
    var i: usize = 0;
    while (main.relayCount() > 1) : (i += 1) {
        if (main.relayAt(i) != null) main.removeRelayForTest(i);
    }
    var last: usize = 0;
    while (main.relayAt(last) == null) : (last += 1) {}

    main.update(&model, Msg{ .relay_remove = @intCast(last) }, &fx);
    try testing.expectEqual(@as(usize, 1), main.relayCount());
    try testing.expect(model.relay_last);
    try testing.expect(std.mem.indexOf(u8, model.relay_status(), "at least one relay") != null);

    // Adding another is what makes room, and the complaint goes with it.
    model.relay_buffer.set("wss://relay.example.com");
    main.update(&model, .relay_add, &fx);
    try testing.expectEqual(@as(usize, 2), main.relayCount());
    try testing.expect(!model.relay_last);
    main.update(&model, Msg{ .relay_remove = @intCast(last) }, &fx);
    try testing.expectEqual(@as(usize, 1), main.relayCount());
}

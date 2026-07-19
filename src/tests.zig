const std = @import("std");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        // Name the app.native position instead of a bare error trace: the
        // usual cause is a binding without a matching Model field or an
        // on-* message without a Msg arm.
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// Like `findByText`, but matches on text content regardless of widget kind.
fn findAnyText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findAnyText(child, text)) |found| return found;
    }
    return null;
}

/// A signed kind:1 note with the given timestamp and content.
fn signedNote(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, created_at: i64, content: []const u8) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, 1, &.{}, content, null);
}

test "first run shows the onboarding welcome, not the feed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Default stage is onboarding (a fresh install with no identity on disk).
    var model = main.initialModel();
    const tree = try buildTree(arena, &model);

    try testing.expect(findAnyText(tree.root, "Welcome to Nostr") != null);
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    // The sign-in paths (import a key or connect a signer) share one field with a
    // Continue action.
    try testing.expect(findAnyText(tree.root, "Continue") != null);
    // The feed's connecting header does not show on the welcome screen.
    try testing.expect(findAnyText(tree.root, "Connecting…") == null);
}

test "login text is classified by prefix" {
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("nsec1abcdef"));
    try testing.expectEqual(main.LoginTarget.bunker, main.classifyLogin("bunker://pubkey?relay=wss://r"));
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("  nsec1withspace  "));
    // An npub (read-only) is not a sign-in path yet, nor is arbitrary text.
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("npub1abcdef"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("hello"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin(""));
}

test "the settings screen shows the identity, key backup, and logout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    try testing.expect(findByText(tree.root, .text, "Settings") != null);
    try testing.expect(findAnyText(tree.root, "Signed in as") != null);
    // Default signer kind is a local key, so the key-backup card and its reveal
    // control render.
    try testing.expect(findAnyText(tree.root, "Local key") != null);
    try testing.expect(findAnyText(tree.root, "Reveal secret key") != null);
    // The logout entry point is present; the confirmation is not yet.
    try testing.expect(findAnyText(tree.root, "Log out") != null);
    try testing.expect(findAnyText(tree.root, "Cancel") == null);
    // The version line renders.
    try testing.expect(findAnyText(tree.root, "Plaza 0.1.0") != null);
}

test "the logout confirmation replaces the log-out button" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    model.logout_pending = true;
    const tree = try buildTree(arena, &model);

    // The confirmation shows a warning and a Cancel/Log out pair.
    try testing.expect(findAnyText(tree.root, "Cancel") != null);
    try testing.expect(findAnyText(tree.root, "Log out") != null);
}

test "the empty feed renders the brand and a connecting header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);

    try testing.expect(findByText(tree.root, .text, "Plaza") != null);
    try testing.expect(findByText(tree.root, .text, "Connecting…") != null);
}

test "a note becomes an npub-labelled card with a relative time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{3} ** 32);

    const now: i64 = 1_800_000_000;
    const ev = try signedNote(arena, signer, kp, now - 300, "hello from plaza"); // 5 minutes ago
    const note = main.noteFrom(ev, now);

    // Author is the abbreviated, canonical npub.
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
    try testing.expect(std.mem.indexOfScalar(u8, note.author(), '\xe2') != null); // the "…" abbreviation marker
    // Relative time and avatar initials.
    try testing.expectEqualStrings("5m", note.time());
    try testing.expectEqual(@as(usize, 2), note.initials().len);
    // Content survives.
    try testing.expectEqualStrings("hello from plaza", note.content());
}

test "the feed renders a note card from the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{4} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note in the feed");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    // The card shows the content, the npub author, and the count in the footer.
    try testing.expect(findByText(tree.root, .text, "a note in the feed") != null);
    try testing.expect(findByText(tree.root, .text, model.notes[0].author()) != null);
    try testing.expect(findByText(tree.root, .status_bar, "1 notes") != null);
}

test "the header summarises the relay pool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Some relays live: the header shows the live count out of the pool.
    var live = main.initialModel();
    live.stage = .ready;
    live.live_relays = 3;
    const live_tree = try buildTree(arena, &live);
    try testing.expect(findByText(live_tree.root, .text, "Live · 3/5 relays") != null);

    // The whole pool down: the header says so.
    var down = main.initialModel();
    down.stage = .ready;
    down.offline_relays = 5;
    const down_tree = try buildTree(arena, &down);
    try testing.expect(findByText(down_tree.root, .text, "Offline, reconnecting…") != null);
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 440, 680), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "one-process: a signed note round-trips through the local store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{9} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "stored in-process");

    // A throwaway store under the test tmp dir (self-cleaning).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/feed.mdb", .{tmp.sub_path});

    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // Ingest verifies (secp256k1) and stores (LMDB), the whole in-process path.
    const result = try store.ingest(arena, ev, .{ .verify_with = signer });
    try testing.expectEqual(nostr.store.IngestResult.added, result);

    // Query it back and confirm the content survived the round-trip.
    const kinds = [_]u16{1};
    var q = try store.query(arena, .{ .kinds = &kinds, .limit = 10 });
    defer q.deinit();
    try testing.expectEqual(@as(usize, 1), q.events.len);
    try testing.expectEqualStrings("stored in-process", q.events[0].content);
}

test "the composer renders a Post action and, without a key, an identity prompt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);

    // Building the tree exercises the composer markup (input-group, textarea,
    // button). The Post label renders, and with no identity loaded in the test
    // process the "posting as" line shows the setup prompt.
    try testing.expect(findAnyText(tree.root, "Post") != null);
    try testing.expect(findAnyText(tree.root, "Preparing your key…") != null);
}

test "a fresh draft is empty and disables Post" {
    var model = main.initialModel();
    try testing.expect(model.draft_empty());
    try testing.expectEqualStrings("", model.draft());
}

test "the feed key survives a high-bit event id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Find a note whose id begins with the high bit set, the case that
    // overflows the markup engine's i64 key cast if the key is stored as u64.
    var seed: u8 = 1;
    const ev = while (seed < 255) : (seed += 1) {
        const kp = try signer.keyPairFromSecretKey([_]u8{seed} ** 32);
        const e = try signedNote(arena, signer, kp, 1_800_000_000, "high-bit id");
        if (e.id[0] >= 0x80) break e;
    } else return error.NoHighBitIdFound;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    // Building the list resolves the item key; a u64 key would panic here.
    const tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "high-bit id") != null);
}

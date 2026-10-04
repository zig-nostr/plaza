const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");
const painted = @import("painted.zig");
const long_form = @import("article.zig");
const theme = @import("theme.zig");
const tests_addresses = @import("tests/addresses.zig");
const tests_bookmarks = @import("tests/bookmarks.zig");
const tests_compose = @import("tests/compose.zig");
const tests_drafts = @import("tests/drafts.zig");
const tests_engagement = @import("tests/engagement.zig");
const tests_feed_media = @import("tests/feed_media.zig");
const tests_feed_state = @import("tests/feed_state.zig");
const tests_follows = @import("tests/follows.zig");
const tests_hiding = @import("tests/hiding.zig");
const tests_image_cache = @import("tests/image_cache.zig");
const tests_image_pool = @import("tests/image_pool.zig");
const tests_inbox = @import("tests/inbox.zig");
const tests_ingest = @import("tests/ingest.zig");
const tests_keyholder = @import("tests/keyholder.zig");
const tests_link_preview = @import("tests/link_preview.zig");
const tests_links = @import("tests/links.zig");
const tests_login = @import("tests/login.zig");
const tests_media_servers = @import("tests/media_servers.zig");
const tests_mutes = @import("tests/mutes.zig");
const tests_navigation = @import("tests/navigation.zig");
const tests_note_build = @import("tests/note_build.zig");
const tests_outbox = @import("tests/outbox.zig");
const tests_own_lists = @import("tests/own_lists.zig");
const tests_own_profile = @import("tests/own_profile.zig");
const tests_people_search = @import("tests/people_search.zig");
const tests_places = @import("tests/places.zig");
const tests_prefs = @import("tests/prefs.zig");
const tests_private_lists = @import("tests/private_lists.zig");
const tests_profile_cache = @import("tests/profile_cache.zig");
const tests_profile_notes = @import("tests/profile_notes.zig");
const tests_quote_cache = @import("tests/quote_cache.zig");
const tests_relay_auth = @import("tests/relay_auth.zig");
const tests_relay_conn = @import("tests/relay_conn.zig");
const tests_relay_hints = @import("tests/relay_hints.zig");
const tests_relay_list = @import("tests/relay_list.zig");
const tests_relay_table = @import("tests/relay_table.zig");
const tests_remote_signer = @import("tests/remote_signer.zig");
const tests_routing = @import("tests/routing.zig");
const tests_store_glue = @import("tests/store_glue.zig");
const tests_thread_model = @import("tests/thread_model.zig");
const tests_tuning = @import("tests/tuning.zig");
const tests_updates = @import("tests/updates.zig");
const tests_uploads = @import("tests/uploads.zig");
const tests_view_article = @import("tests/view_article.zig");
const tests_view_chrome = @import("tests/view_chrome.zig");
const tests_view_compose = @import("tests/view_compose.zig");
const tests_view_media = @import("tests/view_media.zig");
const tests_view_note = @import("tests/view_note.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

/// Builds the real view for `model`: the same root the app runs, so a test sees
/// the markup screens (compiled in) and the hand-written feed exactly as shipped.
pub fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    // The app's own icon table, installed the same way `main` installs it, so a
    // test tree draws Plaza's glyphs rather than the missing-icon fallback.
    main.registerIcons();
    var ui = AppUi.init(arena);
    const node = main.appView(&ui, model);
    if (ui.failed) return error.ViewBuild;
    return ui.finalize(node);
}

pub fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// How many note rows the tree actually built (the windowed list materialises
/// only the rows near the viewport). Each note row has exactly one avatar, so
/// avatars are the stable per-row marker now that the rows are not cards.
pub fn countNoteRows(widget: canvas.Widget) usize {
    var n: usize = if (widget.kind == .avatar) 1 else 0;
    for (widget.children) |child| n += countNoteRows(child);
    return n;
}

/// Like `findByText`, but matches on text content regardless of widget kind.
pub fn findAnyText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findAnyText(child, text)) |found| return found;
    }
    return null;
}

/// Whether any widget's text CONTAINS this needle (span-joined paragraphs).
/// The first text in the tree containing `needle`, so a test can assert about
/// the string itself rather than only its presence.
pub fn findAnyTextContainingText(widget: canvas.Widget, needle: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return widget.text;
    for (widget.children) |child| {
        if (findAnyTextContainingText(child, needle)) |found| return found;
    }
    return null;
}

pub fn findAnyTextContaining(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (findAnyTextContaining(child, needle)) return true;
    }
    return false;
}

/// How many widgets the tree holds, which is what the view budget counts.
pub fn countNodes(widget: canvas.Widget) usize {
    var n: usize = 1;
    for (widget.children) |child| n += countNodes(child);
    return n;
}

/// How many widgets carry this exact label. A row count, when the rows are
/// alike: `findByLabel` says one exists, this says how many were built.
pub fn countByLabel(widget: canvas.Widget, label: []const u8) usize {
    var n: usize = if (std.mem.eql(u8, widget.semantics.label, label)) 1 else 0;
    for (widget.children) |child| n += countByLabel(child, label);
    return n;
}

/// The frame of the first widget carrying this exact text.
pub fn frameOfText(p: painted.Painted, text: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, text)) return node.widget.frame;
    }
    return null;
}

/// The frame of the first widget of this kind, in painted order.
fn frameOfKind(p: painted.Painted, kind: canvas.WidgetKind) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |node| {
        if (node.widget.kind == kind) return node.widget.frame;
    }
    return null;
}

/// Finds a widget by its accessibility label (for icon-only controls like the
/// rail tiles, which carry no text).
pub fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

/// "N/M relays", with M the size of the pool the app is born with, so a change
/// to the bootstrap list does not have to be chased through the assertions.
pub fn ui_fmt_pool(arena: std.mem.Allocator, live: usize) []const u8 {
    return std.fmt.allocPrint(arena, "{d}/{d} relays", .{ live, main.bootstrap_relay_count_for_test }) catch unreachable;
}

/// A signed kind:1 note with the given timestamp and content.
/// Whether a filter is one of the feed's note filters rather than a metadata one.
///
/// By whether it asks for kind 1, not by how many kinds it names. It used to be
/// `kinds.len == 1`, which stopped meaning anything the moment the feed asked
/// for reposts as well: the notes filter names three kinds now and the metadata
/// filters name several, so counting them tells the two apart by accident.
pub fn isNotesFilter(f: nostr.filter.Filter) bool {
    for (f.kinds orelse return false) |k| {
        if (k == 1) return true;
    }
    return false;
}

pub fn signedNote(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, created_at: i64, content: []const u8) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, 1, &.{}, content, null);
}

/// A signed event of any kind, with tags. `signedNote` is the kind-1 case.
pub fn signedKind(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    created_at: i64,
    kind: u16,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, kind, tags, content, null);
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

test "the empty feed renders the rail and a connecting body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);

    // The nav rail's Home tile (the mark) stands in for the old wordmark.
    try testing.expect(findByLabel(tree.root, "Home") != null);
    // With no notes yet, the body says what it is waiting for.
    try testing.expect(findAnyText(tree.root, "Connecting to the relay pool…") != null);
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);

    // Sized from the runtime's own per-view ceiling, not a literal. A view past
    // the cap is REFUSED, not truncated (error.WidgetNodeLimitReached from the
    // runtime, error.WidgetLayoutListFull from the layout call), and a buffer
    // that merely fits today would fail this smoke test on the next row of
    // chrome instead of on a real bug. Arena-allocated: a thousand nodes is more
    // than a test stack should carry.
    const nodes = try arena_state.allocator().alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 440, 680), nodes);
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

/// The words on the Back control of whichever level is open, or null if there is
/// none on screen.
pub fn backText(root: canvas.Widget) ?[]const u8 {
    const back = findByLabel(root, "Back") orelse return null;
    var last: ?[]const u8 = null;
    for (back.children) |child| {
        if (child.text.len > 0) last = child.text;
    }
    return last;
}

test "Back names where it actually goes, from every place a level opens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.setIdentityForTest([_]u8{0x7d} ** 32);
    defer {
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x7e} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note someone replied to");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/back.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try store.ingest(arena, ev, .{});
    main.setStoreForTest(&store);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_100);
    model.notes_len = 1;
    const id = model.notes[0].id;
    var fx: main.EffectsForTest = undefined;
    const feed = model.scope_name();

    // From the feed, Back goes to the feed.
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);

    // From a row in Notifications, a thread's Back goes to Notifications. It
    // used to name the feed and then land on the sheet.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_event = ev.id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // And so does a person's page opened from there.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);

    // Once the reader goes deeper, Back names the level it returns to, not the
    // sheet. A thread opened from the feed, then its author's page: Back from
    // the page lands on the thread.
    main.update(&model, .close_notifications, &fx);
    main.update(&model, Msg{ .open_thread = id }, &fx);
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    try testing.expectEqualStrings(model.thread_stack[0].note.author(), backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);

    // A topic names itself the way its own header does, and the bookmark list
    // by its title.
    var topic_level = main.Screen{ .topic_len = 3 };
    @memcpy(topic_level.topic_buf[0..3], "zig");
    try testing.expectEqualStrings("#zig", topic_level.backLabel(arena));
    try testing.expectEqualStrings("Bookmarks", (main.Screen{ .bookmarks = true }).backLabel(arena));

    // Deeper from the sheet: a thread opened from a row, then its author, then
    // Back. That is the thread again, and its Back is still the sheet, because
    // the walk into the author's page did not start from the feed.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_event = ev.id }, &fx);
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);
    main.update(&model, .close_notifications, &fx);

    // A visit to Notifications that never got back to the sheet (the reader went
    // Home instead) must not turn the next ordinary thread into a way back to it.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    main.goHomeForTest(&model);
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(!model.notifications_open);
}

test "a reply half written in a thread is still there when the reader comes back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.setIdentityForTest([_]u8{0x7f} ** 32);
    defer main.clearIdentityForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x80} ** 32);
    const first = try signedNote(arena, signer, kp, 1_800_000_000, "the first note");
    const second = try signedNote(arena, signer, kp, 1_800_000_100, "the second note");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(first, 1_800_000_200);
    model.notes[1] = main.noteFrom(second, 1_800_000_200);
    model.notes_len = 2;
    const a = model.notes[0].id;
    const b = model.notes[1].id;
    var fx: main.EffectsForTest = undefined;

    // Back to the feed and in again: the sentence is where the reader left it.
    main.update(&model, Msg{ .open_thread = a }, &fx);
    model.reply_buffer.set("I was about to say");
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.reply_empty());
    main.update(&model, Msg{ .open_thread = a }, &fx);
    try testing.expectEqualStrings("I was about to say", model.reply_draft());

    // It belongs to that thread. Another one opens with an empty box, and its own
    // draft is kept apart.
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());
    model.reply_buffer.set("and over here");
    // Back from the second thread lands on the first, and its box is full again.
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(a, model.viewing_thread);
    try testing.expectEqualStrings("I was about to say", model.reply_draft());
    main.update(&model, Msg.close_thread, &fx);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());

    // A person's page in between, and Home, keep it as well.
    main.update(&model, Msg{ .open_person = first.pubkey }, &fx);
    try testing.expect(model.reply_empty());
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());
    main.goHomeForTest(&model);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());

    // Emptying the box on purpose is also a draft: nothing comes back.
    model.reply_buffer.clear();
    main.update(&model, Msg.close_thread, &fx);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());

    // Signing out takes every kept reply with it, as it does the open one.
    model.reply_buffer.set("private thinking");
    main.update(&model, Msg.close_thread, &fx);
    main.performLogoutForTest(&model, &fx);
    main.setIdentityForTest([_]u8{0x7f} ** 32);
    model.notes[1] = main.noteFrom(second, 1_800_000_200);
    model.notes_len = 2;
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());
}

/// A thread root with nothing behind it but its id, for tests of the level
/// bookkeeping that never read a reply.
pub fn bareRoot(byte: u8) main.Note {
    var note = main.Note{ .id = @as(i64, byte) + 1000, .created_at = 1_800_000_000 };
    note.event_id = [_]u8{byte} ** 32;
    return note;
}

test "a fresh draft is empty and disables Post" {
    var model = main.initialModel();
    try testing.expect(model.draft_empty());
    try testing.expectEqualStrings("", model.draft());
}

// ---- NIP-46 client hardening: request correlation, timeout, teardown --------

test "the join screen always offers the way back to reading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .onboarding;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Keep browsing") != null);
    try testing.expect(findAnyText(tree.root, "Reading never needs an identity.") != null);
}

// ---- C1: the first-intent sheet ---------------------------------------------

// ---- C2: bunker connect states ----------------------------------------------

pub fn threadNote(event_byte: u8, created_at: i64, parent_byte: u8) main.Note {
    var note = main.Note{ .created_at = created_at };
    note.event_id = [_]u8{event_byte} ** 32;
    if (parent_byte != 0) {
        note.reply_parent = [_]u8{parent_byte} ** 32;
        note.has_reply_parent = true;
    }
    return note;
}

test "threadIndentLevels caps the visual indent" {
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(0));
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(1));
    try testing.expectEqual(@as(usize, 1), main.threadIndentLevels(2));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(4));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(255));
}

test "every registered app icon resolves, so no view draws the missing glyph" {
    main.registerIcons();
    // The names Plaza's views ask for by `ui.appIcon`. A typo or a dropped
    // registration would silently draw the slashed-circle fallback in the app,
    // so the resolution is asserted here instead.
    for ([_][]const u8{ "reply", "like", "zap", "notary", "bell", "mark" }) |name| {
        try testing.expect(canvas.icons.resolve(name) != null);
    }
    // The built-in names the Working set reuses (the redesign's icon set is the
    // SDK's own set), so a future SDK bump that renames one fails here.
    for ([_][]const u8{
        "alert",        "archive",      "arrow-right",   "arrow-up",   "check",         "check-circle",
        "chevron-down", "chevron-left", "chevron-right", "chevron-up", "circle-dot",    "clock",
        "copy",         "download",     "edit",          "ellipsis",   "external-link", "eye",
        "plus",         "repeat",       "search",        "settings",   "terminal",      "volume",
        "x",            "x-circle",
    }) |name| {
        try testing.expect(canvas.icons.find(name) != null);
    }
    // An unregistered name must NOT resolve, or the assertions above prove nothing.
    try testing.expect(canvas.icons.resolve("plaza-no-such-icon") == null);
}

test "the identity violet is what the info token actually resolves to" {
    // The views name the violet two ways: element foregrounds take
    // `palette.accent_identity` directly, and text spans reference the `info`
    // token (a span names a token field, not a Color). Both must land on the same
    // color, or a handle and a mention in the same row would disagree.
    const model = Model{};
    const tokens = theme.tokens(Model)(&model);
    try testing.expectEqual(theme.palette.accent_identity, tokens.colors.info);
    // And the violet is a violet: blue-dominant, with red above green.
    const v = theme.palette.accent_identity;
    try testing.expect(v.b > v.r and v.r > v.g);
}

// -------------------------------------------------------- painted surfaces
//
// These assert the COLOUR the renderer emits, not the widget tree. Four features
// of this redesign shipped invisible while their trees looked perfect (see
// painted.zig), so every surface that must show its own fill is pinned here.

test "every chrome surface actually paints its fill" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const p = try painted.Painted.render(arena_state.allocator(), &model);
    const pal = theme.palette;

    // The rail's home plate. This is the assertion that would have caught the
    // rail painting as bare window for the whole life of the rail.
    try painted.expectFillAt(p, 28, 28, pal.surface_rail_tile);

    // A quiet rail tile has NO PLATE: what covers it is the rail's own colour,
    // not a tile surface. Worth asserting, because a panel with no stated
    // background falls back to the house card fill and would draw a plate the
    // design does not have.
    //
    // This asked for NOTHING painted until SDK 0.6.2, which made explicit
    // backgrounds on rows and columns paint for the first time: the rail column
    // states the window colour and now draws it, where before the host's clear
    // showed through instead. Identical on screen, and a different question to
    // ask, so the question changed rather than the expectation being widened.
    try painted.expectFillAt(p, 28, 506, pal.surface_window);
}

test "the compose tile is the one bright surface in the window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const p = try painted.Painted.render(arena_state.allocator(), &model);

    // 11a's whole point about the rail: compose is the single bright tile. It had
    // never once painted.
    const fill = p.fillAtCenterOf("New note") orelse return error.NoComposeTile;
    try testing.expect(painted.sameColor(fill, theme.palette.accent));

    // And it wears no border. A panel strokes its frame whether or not one was
    // asked for, falling back to the house hairline, which put a #26262c ring
    // around the bright tile until it was told not to.
    const frame = p.frameOf("New note") orelse return error.NoComposeTile;
    try testing.expect(!p.hasStrokeAt(frame.x, frame.y + frame.height / 2, theme.palette.border_hairline));
}

test "the guest banner paints behind its own copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    // The banner only exists for a guest, which `initialModel` already is (no
    // active pubkey), and only until it is dismissed.
    try testing.expect(model.is_guest() and model.show_guest_strip());

    const p = try painted.Painted.render(arena_state.allocator(), &model);
    const pal = theme.palette;

    // Inside the banner, left of its copy: the banner's own surface, which was
    // stated on a column and therefore never drawn.
    try painted.expectFillAt(p, 300, 20, pal.surface_subbar);

    // The filled pill, and the fact that it carries no borrowed hairline.
    const pill = p.frameOf("Create identity") orelse return error.NoPill;
    const pill_fill = p.fillAt(pill.x + pill.width / 2, pill.y + pill.height / 2) orelse return error.PillNotPainted;
    try testing.expect(painted.sameColor(pill_fill, pal.accent));
    try testing.expect(!p.hasStrokeAt(pill.x, pill.y + pill.height / 2, pal.border_hairline));
}

/// Every codepoint in a widget's own text, and in each of its paragraph spans,
/// checked against `ok`. Returns the first character that fails, with the string
/// it came from, so a failure names the copy rather than a number.
const BadGlyph = struct { codepoint: u21, in: []const u8 };

fn firstUnrenderable(widget: canvas.Widget) ?BadGlyph {
    if (scanRun(widget.text)) |bad| return bad;
    for (widget.spans) |span| {
        if (scanRun(span.text)) |bad| return bad;
    }
    for (widget.children) |child| {
        if (firstUnrenderable(child)) |bad| return bad;
    }
    return null;
}

fn scanRun(text: []const u8) ?BadGlyph {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .codepoint = text[i], .in = text };
        if (i + len > text.len) return .{ .codepoint = text[i], .in = text };
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return .{ .codepoint = text[i], .in = text };
        if (!chromeGlyphIsSafe(cp)) return .{ .codepoint = cp, .in = text };
        i += len;
    }
    return null;
}

/// The characters Plaza's own chrome may use. ASCII, plus the typographic marks
/// the bundled Geist faces carry and the redesign's copy actually asks for.
///
/// The bar is deliberately an ALLOWLIST rather than a list of known-bad glyphs:
/// the SDK ships a coverage table naming ⌘, ✓ and friends as the recurring tofu
/// class, but it is private to the canvas module and only warns at debug level in
/// Debug builds, so an uncovered character reaches a release window as a silent
/// box. (It did: the relay menu's ⌘ hint drew as tofu until this test.)
fn chromeGlyphIsSafe(cp: u21) bool {
    if (cp >= 0x20 and cp < 0x7F) return true; // printable ASCII
    return switch (cp) {
        0x00B7, // · the metadata separator
        0x2026, // … an elision
        0x2018,
        0x2019,
        0x201C,
        0x201D, // curly quotes
        0x2013, // en dash
        => true,
        else => false,
    };
}

test "the chrome never asks for a glyph the bundled faces cannot draw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Chrome only: an empty feed, so no note content (which is the user's, may be
    // any language or emoji, and is not ours to constrain) is in the tree.
    var model = main.initialModel();
    model.stage = .ready;

    // Each chrome menu in turn, since a closed menu builds nothing.
    for ([_]main.ChromeMenu{ .none, .scope, .relays, .account }) |menu| {
        model.menu = menu;
        const tree = try buildTree(arena, &model);
        if (firstUnrenderable(tree.root)) |bad| {
            std.debug.print(
                "\n  chrome text contains U+{X:0>4} in \"{s}\" (menu: {s}). The bundled faces do not" ++
                    " carry it, so it draws as a tofu box. Use a vector icon or plain words.\n",
                .{ bad.codepoint, bad.in, @tagName(menu) },
            );
            return error.UnrenderableChromeGlyph;
        }
    }
}

test "an open chrome menu paints a real surface above the bar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .relays;
    const p = try painted.Painted.render(arena_state.allocator(), &model);

    // The popover is anchored, so it leaves the row's flow entirely and paints in
    // a late window-level pass. Both halves matter: it must PAINT (a menu that
    // renders nothing is the rail bug again) and it must sit ABOVE the 30px bar
    // it hangs off rather than being clipped into it.
    const pause = p.frameOf("Pause Relays") orelse return error.NoPopover;
    try testing.expect(pause.y + pause.height < main.window_height - 30);

    const fill = p.fillAt(pause.x + pause.width / 2, pause.y + pause.height / 2) orelse return error.PopoverNotPainted;
    try testing.expect(painted.sameColor(fill, theme.palette.surface_menu));
}

test "only one chrome menu is open at a time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;

    // A trigger toggles its own menu and replaces any other, so two floating
    // surfaces can never overlap in the chrome.
    var fx: main.EffectsForTest = undefined;
    model.menu = .relays;
    main.update(&model, Msg{ .toggle_menu = .account }, &fx);
    try testing.expectEqual(main.ChromeMenu.account, model.menu);
    main.update(&model, Msg{ .toggle_menu = .account }, &fx);
    try testing.expectEqual(main.ChromeMenu.none, model.menu);
}

test "a hovered note row washes, and only when hovered" {
    // The redesign has exactly one hover state: a wash under the whole row
    // (11e, locked decision 2). It shipped nowhere. The token was defined and
    // unused, the pressable rows were layout kinds the renderer paints nothing
    // for, and the ones that were list items set `quiet_hover`, which the SDK
    // reads as "no hover fill". None of that is visible in a widget tree.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    // At rest the row paints the window, not a wash.
    const rest = try painted.Painted.render(arena, &model);
    const frame = rest.frameOf("Open thread") orelse return error.NoRow;
    const x = frame.x + frame.width / 2;
    const y = frame.y + frame.height / 2;
    try testing.expect(!rest.hasFillAt(x, y, theme.palette.surface_hover));

    // Under the pointer it washes.
    const hovered = try painted.Painted.renderHovered(arena, &model, "Open thread");
    try painted.expectFillAt(hovered, x, y, theme.palette.surface_hover);

    // Corner to corner, square: 11e's wash is the row's whole band, and a
    // `list_item` rounds its fill to the control radius unless the row says
    // otherwise. A rounded wash inside a square band shows at the corners.
    try painted.expectFillAt(hovered, frame.x + 1, frame.y + 1, theme.palette.surface_hover);
    try painted.expectFillAt(hovered, frame.x + frame.width - 1, frame.y + frame.height - 1, theme.palette.surface_hover);
}

test "a pressed row reads deeper than a hovered one" {
    // Binding the hover colour alone silently repaints the PRESS too: the fill
    // resolves as `active orelse hover orelse background`, so a press with no
    // channel of its own becomes the hover colour, and every row whose only
    // painted state was the press (the rail seat, both Back rows, the fold, the
    // picture tile) loses its feedback. Nothing about that is visible in a
    // widget tree or in a hover test.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    const pressed = try painted.Painted.renderPressed(arena, &model, "Open thread");
    const frame = pressed.frameOf("Open thread") orelse return error.NoRow;
    const x = frame.x + frame.width / 2;
    const y = frame.y + frame.height / 2;
    try painted.expectFillAt(pressed, x, y, theme.palette.surface_chip);
    // And it is a different colour from the hover, or the press says nothing.
    try testing.expect(!pressed.hasFillAt(x, y, theme.palette.surface_hover));
}

test "the outbox zone appears only when something is owed" {
    // The zone is absent most of the time on purpose: one that is always there
    // teaches nothing, and an empty popover under it would be worse.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    const quiet = try painted.Painted.render(arena, &model);
    try testing.expect(quiet.frameOf("Notes on their way") == null);

    model.outbox_pending = 2;
    const owed = try painted.Painted.render(arena, &model);
    const zone = owed.frameOf("Notes on their way") orelse return error.NoZone;
    try testing.expect(zone.width > 0);
    // It says how many, in the shot's own words.
    try testing.expectEqualStrings("posting 2 notes…", model.outbox_label(arena));
    model.outbox_pending = 1;
    try testing.expectEqualStrings("posting 1 note…", model.outbox_label(arena));
}

test "a note that gave up is not called posting" {
    // The zone's words follow the state, because "posting" over a note that will
    // never go is the same lie the queue was built to stop telling.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.outbox_pending = 0;
    model.outbox_stuck = 1;
    try testing.expectEqualStrings("1 note did not go out", model.outbox_label(arena));
    model.outbox_stuck = 3;
    try testing.expectEqualStrings("3 notes did not go out", model.outbox_label(arena));

    // Still trying wins the label: what is moving matters more than what stalled.
    model.outbox_pending = 2;
    try testing.expectEqualStrings("posting 2 notes…", model.outbox_label(arena));
}

test "an empty composer cannot be posted, by button or by key" {
    // The button is disabled when the draft is empty, so before Cmd+Enter the
    // message could never arrive with nothing to send. A key can, and closing
    // the sheet with a "Posted" toast over an empty composer would be the
    // plainest lie in the app.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    try testing.expect(model.draft_empty());

    var fx: main.EffectsForTest = undefined;
    main.update(&model, .post, &fx);
    // Still open, and nothing claimed.
    try testing.expect(model.composing);
    try testing.expectEqual(@as(usize, 0), main.outboxPending());

    // Whitespace is empty too: a note of three spaces is not a note.
    model.draft_buffer = @TypeOf(model.draft_buffer).init("   \n ");
    try testing.expect(model.draft_empty());
    main.update(&model, .post, &fx);
    try testing.expect(model.composing);
}

test "a dormant seat in the middle does not leave the popover a hole" {
    // The popover used to index rows by SLOT, so a removed relay left a row
    // nobody wrote, and the arena hands out uninitialised memory that the
    // widget walker then follows. Removing a middle relay and opening the
    // popover is the exact press that reached it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetRelaysForTest();
    main.removeRelayForTest(1);
    main.cycleRelayForTest(2); // R·W -> R, the other way a row used to be skipped

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .relays;
    const tree = try buildTree(arena, &model);
    // The four survivors are named; the removed one is not.
    try testing.expect(findAnyText(tree.root, "relay.damus.io") != null);
    try testing.expect(findAnyText(tree.root, "nos.lol") == null);
    // And a read-only relay is listed rather than hidden: the chip counts it, so
    // a list that dropped it would disagree with the number beside it.
    try testing.expect(findAnyText(tree.root, "relay.primal.net") != null);
}

test "a field no other client could read is not published" {
    var model = main.initialModel();
    model.profile_stage = .have;
    try testing.expect(model.profile_can_save());
    try testing.expectEqualStrings("", model.profile_invalid());

    // A sentence in the lightning address field is the case worth catching: it
    // saves cleanly, and then nothing can pay you and nothing says why.
    model.profile_lud16_buffer.set("ask me on telegram");
    try testing.expect(model.profile_invalid().len > 0);
    try testing.expect(!model.profile_can_save());

    model.profile_lud16_buffer.set("alice@getalby.com");
    try testing.expectEqualStrings("", model.profile_invalid());
    try testing.expect(model.profile_can_save());

    // Empty is not an error. It removes the key, which is how somebody says
    // they do not have one.
    model.profile_lud16_buffer.set("");
    try testing.expectEqualStrings("", model.profile_invalid());

    model.profile_website_buffer.set("alice.example");
    try testing.expect(model.profile_invalid().len > 0);
    model.profile_website_buffer.set("https://alice.example");
    try testing.expectEqualStrings("", model.profile_invalid());

    model.profile_nip05_buffer.set("nope");
    try testing.expect(model.profile_invalid().len > 0);
}

test "the shape checks accept what works and refuse what cannot" {
    // Only the shape. A lightning address that looks right can still have no
    // endpoint behind it, and this cannot know that without asking.
    for ([_][]const u8{ "", "a@b.co", "alice@getalby.com", "a.b@sub.domain.org" }) |good| {
        var m = main.initialModel();
        m.profile_lud16_buffer.set(good);
        try testing.expectEqualStrings("", m.profile_invalid());
    }
    for ([_][]const u8{ "alice", "@getalby.com", "alice@", "a@b@c.com", "alice@nodot" }) |bad| {
        var m = main.initialModel();
        m.profile_lud16_buffer.set(bad);
        try testing.expect(m.profile_invalid().len > 0);
    }
    for ([_][]const u8{ "", "https://a.example", "http://a.example/x?y=1", "HTTPS://A.EXAMPLE" }) |good| {
        var m = main.initialModel();
        m.profile_website_buffer.set(good);
        try testing.expectEqualStrings("", m.profile_invalid());
    }
    for ([_][]const u8{ "a.example", "ftp://a.example", "www.a.example" }) |bad| {
        var m = main.initialModel();
        m.profile_website_buffer.set(bad);
        try testing.expect(m.profile_invalid().len > 0);
    }
}

/// Every editable field in a built tree, with whether it has a submit handler.
fn assertFieldsEditable(tree: AppUi.Tree, where: []const u8) !void {
    _ = where;
    var stack: [64]canvas.Widget = undefined;
    var depth: usize = 0;
    stack[depth] = tree.root;
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        const w = stack[depth];
        if (w.kind == .textarea or w.kind == .text_field or w.kind == .input or w.kind == .search_field) {
            var has_submit = false;
            for (tree.handlers) |h| {
                if (h.id == w.id and h.event == .submit) has_submit = true;
            }
            try testing.expect(has_submit);
        }
        for (w.children) |child| {
            if (depth < stack.len) {
                stack[depth] = child;
                depth += 1;
            }
        }
    }
}

test "every text field in the app has a submit handler, because without one it is not editable" {
    // A textarea with `on_input` but NO `on_submit` renders, focuses, reports
    // `set_text` in its actions, and accepts nothing: not a keystroke, not a
    // paste, not an automated set_text. It reads as a live field and is inert.
    // The Edit profile sheet shipped that way until it was driven for real, so
    // this walks every screen rather than trusting a reading of one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var settings = main.initialModel();
    settings.stage = .settings;
    try assertFieldsEditable(try buildTree(arena, &settings), "settings");

    var sheet = main.initialModel();
    sheet.stage = .settings;
    sheet.editing_profile = true;
    sheet.profile_stage = .have;
    try assertFieldsEditable(try buildTree(arena, &sheet), "edit profile");

    var composing = main.initialModel();
    composing.stage = .ready;
    composing.composing = true;
    try assertFieldsEditable(try buildTree(arena, &composing), "composer");

    var joining = main.initialModel();
    joining.stage = .ready;
    joining.joining = true;
    try assertFieldsEditable(try buildTree(arena, &joining), "join");

    var naming = main.initialModel();
    naming.stage = .ready;
    naming.naming = true;
    try assertFieldsEditable(try buildTree(arena, &naming), "name");
}

test "a relay that never answers leaves the sheet unable to save, not eager to" {
    // `relay.receive()` has no deadline, so a relay that accepts a subscription
    // and then says nothing would hold the round open forever. Waiting has to
    // end in "could not read it", never in "you have no profile".
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(!model.profile_can_save());
    model.profile_stage = .unread;
    try testing.expect(!model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "Could not read") != null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "no profile") == null);
}

test "a late profile does not overwrite what the reader is typing" {
    // The fetch lands a few seconds after the sheet opens. Seeding then would
    // replace the sentence they are in the middle of writing.
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(model.profile_untouched());
    model.profile_about_buffer.set("halfway through a th");
    try testing.expect(!model.profile_untouched());
}

test "saving says what is true, and stays available for the next correction" {
    // Nothing here can know a relay took it: signAndPublish returns no verdict,
    // the remote and helper paths have not even signed yet, and a kind:0 that
    // reaches nobody is not retried. And a typo in the name just saved must be
    // fixable without closing the sheet.
    var model = main.initialModel();
    model.profile_stage = .sent;
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "Published") == null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "sent to your relays") != null);
    try testing.expect(model.profile_can_save());
}

test "a short welcome does not reserve a tall empty card" {
    // The card used to reserve a fixed 380 points whatever the host wrote, so a
    // two-line welcome sat above three hundred points of nothing with the Close
    // button stranded at the bottom of an empty box.
    const short = "## Welcome!\n\nTwo lines, that is all.";
    const tall = main.placeHomeHeightForTest(short);
    try testing.expect(tall > 0);
    try testing.expect(tall < 140);

    // And a long one is still capped, so a host cannot push the buttons off the
    // screen with an essay.
    var long_buf: [2000]u8 = undefined;
    @memset(&long_buf, 'x');
    try testing.expectEqual(@as(f32, 380), main.placeHomeHeightForTest(&long_buf));
}

test "measuring a markdown line counts what is drawn, not what is written" {
    // This is what made the first estimate useless. One paragraph of the Monero
    // welcome carries a link whose address is two hundred characters that are
    // never drawn, so the line measured four times longer than it reads.
    const link = "See [the client](/nevent1qvzqqqqqqypzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053va) here";
    try testing.expectEqual(@as(usize, "See the client here".len), main.visibleLenForTest(link));

    // Heading markers are syntax, not text.
    try testing.expectEqual(@as(usize, "Welcome!".len), main.visibleLenForTest("## Welcome!"));
    // Plain text is itself.
    try testing.expectEqual(@as(usize, 5), main.visibleLenForTest("hello"));
}

test "walking into a room with no logo does not leave the last room's mark behind" {
    // Reported: entered Monero Hallway, then opened the BASSPISTOL link, and
    // Monero's logo was sitting on BASSPISTOL's Info card.
    //
    // The identity check sat BELOW the "this place ships no logo" early return,
    // so a room with nothing of its own never reached the line that drops the
    // last room's mark. Walking OUT to your own feed cleared it, which is why
    // only room-to-room could show it.
    var fx = main.inertEffectsForTest();
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    defer main.setPlaceLogoIdForTest(0);

    // A slot nothing else in this process holds: these tests share the pool.
    var slot: u64 = 0;
    var i: u64 = 1;
    while (i <= 16) : (i += 1) {
        if (std.mem.eql(u8, main.imageIdOwnerNameForTest(i), "free")) {
            slot = i;
            break;
        }
    }
    if (slot == 0) return error.NoFreeSlot;

    // Standing in a room whose mark is loaded and on screen.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa1} ** 32, "moneroh");
    try testing.expect(main.placeLogoShownForTest());

    // Straight into a different room, one that ships no logo at all.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());

    // And one host running two rooms: the host alone is not a place, so the
    // second room does not inherit the first one's mark either.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa3} ** 32, "room-one");
    try testing.expect(main.placeLogoShownForTest());
    main.visitPlaceForTest([_]u8{0xa3} ** 32, "room-two", "Second Room");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());
}

test "an image with no alt text leaves nothing behind" {
    // The renderer draws an image as its ALT text, which is right for a client
    // that spends its image budget on faces. `![](url)` has no alt, so the
    // renderer does not take it as an image at all and the reader gets a
    // literal `![]` and the raw URL as a link. Seen in fiatjaf's Monero
    // welcome, which is written exactly that way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const src =
        "Welcome!\n\n![](https://example.test/sticker.png)\n\nRead on.";
    const out = main.stripEmptyImagesForTest(arena_state.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, out, "![]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.test") == null);
    // And the host's actual words are untouched.
    try testing.expect(std.mem.indexOf(u8, out, "Welcome!") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read on.") != null);

    // An image that DOES name itself is left alone: the renderer draws that alt
    // text, which is the whole point of the format.
    const kept = "see ![a sticker](https://example.test/s.png) here";
    try testing.expectEqualStrings(kept, main.stripEmptyImagesForTest(arena_state.allocator(), kept));

    // And syntax that is not an image is not touched either.
    const unclosed = "![](broken";
    try testing.expectEqualStrings(unclosed, main.stripEmptyImagesForTest(arena_state.allocator(), unclosed));
}

/// A store in a temp dir, installed as the app's, for a test that drives a real
/// write and reads back what went out.
pub const FreshStore = struct {
    tmp: std.testing.TmpDir,
    store: nostr.store.Store,

    pub fn open(self: *FreshStore, name: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ self.tmp.sub_path, name });
        self.store = try nostr.store.Store.open(db_path, .{});
        main.setStoreForTest(&self.store);
    }

    pub fn close(self: *FreshStore) void {
        main.setStoreForTest(null);
        self.store.deinit();
        self.tmp.cleanup();
    }
};

/// Signs in an imported key (not made here) whose every relay has finished
/// without sending any of its lists: the state the dead-end hunt found.
pub fn signInNothingFound(secret_byte: u8) [32]u8 {
    main.setIdentityForTest([_]u8{secret_byte} ** 32);
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    const me = main.activePubkeyForTest().?;
    ownRelayListIsThePool(secret_byte, &.{}) catch unreachable;
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    return me;
}

test "the profile's tabs mean exactly what they say" {
    // Notes is what they wrote; Replies is what they wrote at somebody. A tab
    // that mixed them would be a tab that lies about what it holds.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5b);
    model.viewing_profile = who;

    model.thread_notes[0] = threadNote(0x01, 100, 0); // a note
    model.thread_notes[1] = threadNote(0x02, 90, 0xAA); // a reply
    model.thread_notes[2] = threadNote(0x03, 80, 0); // a note
    // Somebody else's note, sharing the buffer the way a stacked level does.
    model.thread_notes[3] = threadNote(0x04, 70, 0);
    var other: [32]u8 = undefined;
    @memset(&other, 0x99);
    model.thread_notes[3].pubkey = other;
    model.thread_notes_len = 4;
    for (0..3) |i| model.thread_notes[i].pubkey = who;

    var buf: [8]usize = undefined;
    model.profile_tab = .notes;
    const notes = model.profileNotesFor(&buf, who);
    try testing.expectEqual(@as(usize, 2), notes.len);

    model.profile_tab = .replies;
    var buf2: [8]usize = undefined;
    const replies = model.profileNotesFor(&buf2, who);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(@as(usize, 1), replies[0]);

    // The stranger's row belongs to neither tab of THIS person.
    model.profile_tab = .notes;
    var buf3: [8]usize = undefined;
    const mine = model.profileNotesFor(&buf3, who);
    for (mine) |i| try testing.expect(!std.mem.eql(u8, &model.thread_notes[i].pubkey, &other));
}

test "a press on a profile's own note row resolves" {
    // `noteById` searched `thread_notes` only while a THREAD was open, so every
    // per-note action on a profile (open it, like it, expand its picture) was a
    // press that looked live and did nothing.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x71);
    model.viewing_profile = who;
    model.thread_notes[0] = threadNote(0x01, 100, 0);
    model.thread_notes[0].id = 4242;
    model.thread_notes[0].pubkey = who;
    model.thread_notes_len = 1;

    try testing.expect(model.noteById(4242) != null);
    try testing.expect(model.noteById(9999) == null);
}

pub fn inboxEvent(kind: u16, author: u8, tags: []const nostr.event.Tag, created_at: i64) nostr.event.Event {
    return inboxEventBy(kind, [_]u8{author} ** 32, tags, created_at);
}

/// Fills the inbox with `n` mentions of the reader from distinct authors.
pub fn seedInbox(n: usize, first_byte: u8, base_time: i64) void {
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    for (0..n) |i| {
        const who: u8 = first_byte +% @as(u8, @intCast(i % 200));
        var ev = inboxEvent(1, who, &mine, base_time + @as(i64, @intCast(i)));
        // Distinct ids, so the dedupe does not swallow them.
        ev.id[0] = who;
        ev.id[1] = @intCast(i % 256);
        _ = main.inboxAddForTest(ev, base_time + 100_000);
    }
}

test "a press closes the sheet even when it cannot go anywhere" {
    // Every route out of the sheet has an early return in front of it: a store
    // miss for a note nobody fetched, an identity check for a person already on
    // screen. Closing on ARRIVAL therefore left the sheet up in exactly the cases
    // where the reader has least idea why nothing moved.
    main.setIdentityForTest([_]u8{0xED} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetInboxForTest();

    // A note the store has never heard of.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        var fx: main.EffectsForTest = undefined;
        main.update(&model, .{ .open_event = [_]u8{0x5E} ** 32 }, &fx);
        try testing.expect(!model.notifications_open);
        // And it says something, rather than swallowing the press.
        try testing.expect(model.toast_until != 0);
    }

    // The person whose page is already open.
    {
        var model = main.initialModel();
        model.stage = .ready;
        const alice = [_]u8{0x6F} ** 32;
        var fx: main.EffectsForTest = undefined;
        main.update(&model, .{ .open_person = alice }, &fx);
        model.notifications_open = true;
        main.update(&model, .{ .open_person = alice }, &fx);
        try testing.expect(!model.notifications_open);
    }
}

test "a keyboard shortcut fired under the sheet does not arm something invisible" {
    // These are declared shortcuts, so the shell delivers them whatever is on
    // screen, and the sheet is drawn above both destinations.
    main.setIdentityForTest([_]u8{0xEE} ** 32);
    defer main.clearIdentityForTest();

    var fx: main.EffectsForTest = undefined;
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        main.update(&model, .open_compose, &fx);
        // Otherwise the composer arms itself unseen and appears on its own the
        // moment the sheet is dismissed.
        try testing.expect(!model.notifications_open);
        try testing.expect(model.composing);
    }
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        main.update(&model, .open_settings, &fx);
        try testing.expect(!model.notifications_open);
        try testing.expect(model.stage == .settings);
    }
}

test "the notifications page draws its rows in the reading column" {
    // This replaces a test that asserted the rows sat inside a modal card. There
    // is no card: notifications is an opaque level now, like threads, profiles,
    // settings and the composer, because a scrim repaints the whole window every
    // frame and the cost grows with it.
    //
    // What still matters is that a row lands in the column and not spread across
    // a wide window, so the same note is the same width wherever it is shown.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x2f} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    main.seedInboxUnreadForTest(6);

    const tree = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);
    var widest: f32 = 0;
    for (tree.layout.nodes) |n| {
        if (n.widget.kind != .data_row and n.widget.kind != .list_item) continue;
        widest = @max(widest, n.widget.frame.width);
    }
    try testing.expect(widest > 0);
    // The column, not the window. A row wider than the column means the centring
    // row collapsed and every notification is running the full width.
    try testing.expect(widest <= main.notifications_column_width_for_test + 1);
}

// ------------------------------------------------------- NIP-89 the client tag

test "nothing that calls itself a button is dead" {
    // The recurring failure in this app is not a broken control, it is a control
    // that LOOKS live and does nothing: a badge saying "W" while filters still
    // went out, a textarea that renders and accepts no keys, a Repost verb drawn
    // beside a working Like. Each was found by hand, late, and only after it had
    // been reviewed and snapshot-checked. So the invariant is stated once here:
    // if a widget announces itself to the reader as a button, something has to
    // happen when it is pressed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();

    // Every screen the app can be on, including the ones layered over others.
    const Screen = struct { name: []const u8, prepare: *const fn (*main.Model) void };
    const screens = [_]Screen{
        .{ .name = "feed", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
            }
        }.f },
        .{ .name = "thread", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.viewing_thread = 1;
                m.thread_root = threadNote(0xAA, 100, 0);
                m.thread_root.id = 1;
            }
        }.f },
        .{ .name = "profile", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.viewing_profile = [_]u8{0x33} ** 32;
            }
        }.f },
        .{ .name = "settings", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .settings;
            }
        }.f },
        .{ .name = "compose", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.composing = true;
            }
        }.f },
        .{
            .name = "a thread",
            .prepare = struct {
                fn f(m: *main.Model) void {
                    m.stage = .ready;
                    m.viewing_thread = 1;
                    m.thread_root = threadNote(0xAA, 100, 0);
                    m.thread_root.id = 1;
                }
            }.f,
        },
        .{ .name = "notifications", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.notifications_open = true;
            }
        }.f },
        .{ .name = "onboarding", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .onboarding;
            }
        }.f },
        // The first-intent sheet and what follows it, which nothing covered until
        // now. Note what this guard can and cannot see: for a hand-built row the
        // SDK advertises `press` only BECAUSE `on_press` was set, which is the
        // same condition that registers the handler, so deleting `.on_press` from
        // `joinCard` makes all three rungs inert AND invisible to this walk. That
        // is what "the ladder's three rungs are wired" below is for.
        .{ .name = "join sheet", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
            }
        }.f },
        .{ .name = "join sheet with a waiting verb", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
                m.pending = .{ .like = 7 };
            }
        }.f },
        .{ .name = "bunker card", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
                m.bunker_mode = true;
            }
        }.f },
        .{ .name = "name card", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.naming = true;
            }
        }.f },
    };

    for (screens) |screen| {
        var per_screen = std.heap.ArenaAllocator.init(testing.allocator);
        defer per_screen.deinit();
        var model = main.initialModel();
        screen.prepare(&model);
        const tree = try buildTree(per_screen.allocator(), &model);
        var dead: usize = 0;
        countDeadButtons(tree, tree.root, &dead);
        if (dead != 0) {
            std.debug.print("{s}: {d} widget(s) announce a button role with nothing behind them\n", .{ screen.name, dead });
            return error.DeadControl;
        }
    }
}

/// Counts widgets that announce a button role but carry no handler of any kind.
fn countDeadButtons(tree: AppUi.Tree, widget: canvas.Widget, out: *usize) void {
    // Ask the SDK what this widget ADVERTISES, never what the app happened to
    // declare. `semanticActions` is the same function the platform bridge calls
    // to build the accessibility node, so it is the actual promise made to the
    // reader: it folds in the widget's KIND (a `ui.button` announces a press
    // without the app writing `.role = .button` anywhere), and it returns nothing
    // at all for a disabled widget, which is how an unavailable control says so
    // honestly.
    //
    // The first version of this guard read `widget.semantics.role` instead. Plaza
    // declares that role almost nowhere, because the kinds already imply it, so
    // the guard inspected a fraction of the controls it claimed to cover and
    // matched zero checkboxes in an app with two.
    const advertised = canvas.semanticActions(widget);
    if (advertised.press or advertised.toggle) {
        var wired = false;
        for (tree.handlers) |h| {
            if (h.id == widget.id) wired = true;
        }
        if (!wired) {
            out.* += 1;
            std.debug.print("  DEAD: label='{s}' kind={s} role={s}\n", .{ widget.semantics.label, @tagName(widget.kind), @tagName(widget.semantics.role) });
        }
    }
    for (widget.children) |child| countDeadButtons(tree, child, out);
}

test "what a guest reached for is remembered, whatever the verb was" {
    // The app carried two ad-hoc pending fields, a bool for the composer and an
    // id for a like. Every verb added after them either grew a third or quietly
    // remembered nothing: pressing Follow as a guest opened the sheet, signed you
    // in, and dropped the follow, and a guest could type a whole reply and press
    // send to no effect at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;
    main.clearIdentityForTest();

    const alice = [_]u8{0x4A} ** 32;

    // Reaching for the composer.
    {
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, .open_compose, &fx);
        try testing.expect(model.joining);
        try testing.expect(model.pending == .post);
        try testing.expect(!model.composing);
    }

    // Reaching for a like.
    {
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, .{ .like = 77 }, &fx);
        try testing.expect(model.joining);
        try testing.expectEqual(@as(i64, 77), model.pending.like);
    }

    // Reaching for Follow on somebody's page. This one used to remember nothing.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.viewing_profile = alice;
        main.update(&model, .{ .follow_person = 1 }, &fx);
        try testing.expect(model.joining);
        try testing.expectEqualSlices(u8, &alice, &model.pending.follow);
    }

    // Reaching for Reply. This one was gated nowhere: the press reached a signer
    // that does not exist and returned, doing and saying nothing.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.viewing_thread = 42;
        main.update(&model, .reply_submit, &fx);
        try testing.expect(model.joining);
        try testing.expectEqual(@as(i64, 42), model.pending.reply);
    }

    // And the sheet says which one it is waiting on, in the reader's terms.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        model.pending = .post;
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your note is waiting.") != null);
        model.pending = .{ .reply = 42 };
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your reply is waiting.") != null);
        model.pending = .{ .follow = alice };
        try testing.expect(findAnyTextContaining((try buildTree(arena, &model)).root, "is waiting."));
    }
}

test "closing the join sheet is an answer, so the verb is dropped" {
    // Otherwise the thing they declined lies in wait and fires at whatever later
    // sign-in they make for some other reason entirely.
    var fx: main.EffectsForTest = undefined;
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    main.update(&model, .open_compose, &fx);
    try testing.expect(model.pending.waiting());

    main.update(&model, .close_join, &fx);
    try testing.expect(!model.joining);
    try testing.expect(!model.pending.waiting());
}

/// Whether the widget carrying this accessibility label has a handler behind it.
///
/// The dead-control guard walks the tree asking what each widget ADVERTISES, which
/// catches a `ui.button` or a `.checkbox` whose handler went missing. It cannot
/// catch a hand-built row losing its `on_press`: for a plain row the SDK derives
/// the advertised press FROM `on_press`, so removing it removes the advertisement
/// too and the widget stops being a button the guard is looking for. Naming the
/// control is the only way to assert it still exists AND still does something.
pub fn pressableByLabel(tree: AppUi.Tree, widget: canvas.Widget, label: []const u8) bool {
    if (std.mem.eql(u8, widget.semantics.label, label)) {
        for (tree.handlers) |h| {
            if (h.id == widget.id) return true;
        }
    }
    for (widget.children) |child| {
        if (pressableByLabel(tree, child, label)) return true;
    }
    return false;
}

/// The right-click items the first note in the tree offers, and the message
/// behind one of them by label.
///
/// The note's actions used to live in an anchored surface behind an ellipsis, so
/// tests reached them by opening that surface and looking for rendered text.
/// There is one list now and the runtime presents it, so what a test can see is
/// the declared items rather than drawn rows.
const ContextItems = struct {
    id: canvas.ObjectId,
    items: []const canvas.WidgetContextMenuItem,

    pub fn label(self: ContextItems, want: []const u8) ?canvas.WidgetContextMenuItem {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.label, want)) return item;
        }
        return null;
    }

    pub fn msgFor(self: ContextItems, tree: AppUi.Tree, want: []const u8) ?Msg {
        for (self.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.label, want)) return tree.msgForContextMenu(self.id, i);
        }
        return null;
    }
};

pub fn noteContext(p: painted.Painted) ?ContextItems {
    for (p.layout.nodes) |node| {
        if (node.widget.context_menu.len == 0) continue;
        return .{ .id = node.widget.id, .items = node.widget.context_menu };
    }
    return null;
}

/// The message behind the press on the widget carrying this accessibility label.
///
/// `pressableByLabel` asks whether SOMETHING is wired there. This asks what, which
/// is the difference between "the seat still works" and "the seat still goes where
/// it is supposed to".
pub fn pressMsgByLabel(tree: AppUi.Tree, label: []const u8) ?Msg {
    const w = findByLabel(tree.root, label) orelse return null;
    for (tree.handlers) |h| {
        if (h.id != w.id or h.event != .press) continue;
        return switch (h.action) {
            .message => |m| m,
            else => null,
        };
    }
    return null;
}

test "your own page is written for you, not about you" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x5A} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // Your own page, freshly minted: no notes, no contact list read yet. This is
    // the exact state a reader who just pressed "Create your identity" arrives in,
    // and it is entirely made of the sentences that used to say "they".
    main.update(&model, .{ .open_person = me }, &fx);
    const mine = try buildTree(arena, &model);
    if (findAnyTextContainingText(mine.root, "they have written")) |s| {
        std.debug.print("own page talks about the reader in the third person: \"{s}\"\n", .{s});
        return error.WrongPerson;
    }
    try testing.expect(findAnyTextContainingText(mine.root, "you have written") != null);
    try testing.expect(findAnyText(mine.root, "Your follow list has not arrived yet") != null);

    // The line above is the LOADING one, and it is the only empty-tab string a
    // freshly opened profile can reach: `enterProfile` sets `thread_loading` from
    // an empty note count, and with no store it never clears. Settling it reaches
    // the other two, which otherwise sit behind an assertion that cannot see them
    // and could each be reverted to "they" with the suite still green.
    model.thread_loading = false;
    for ([_]struct { tab: @TypeOf(model.profile_tab), want: []const u8 }{
        .{ .tab = .notes, .want = "Nothing you have written is here yet." },
        .{ .tab = .replies, .want = "Nothing you have written at anyone is here yet." },
    }) |c| {
        model.profile_tab = c.tab;
        const settled = try buildTree(arena, &model);
        if (findAnyText(settled.root, c.want) == null) {
            std.debug.print("own page is missing \"{s}\"\n", .{c.want});
            return error.WrongPerson;
        }
        try testing.expect(findAnyTextContainingText(settled.root, "they have written") == null);
    }
    model.profile_tab = .notes;

    // A stranger's page is unchanged: it is about somebody else, and saying "you"
    // there would be the same mistake pointed the other way.
    main.update(&model, .{ .open_person = [_]u8{0x33} ** 32 }, &fx);
    const theirs = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(theirs.root, "they have written") != null);
    try testing.expect(findAnyText(theirs.root, "Their follow list has not arrived yet") != null);
    try testing.expect(findAnyTextContainingText(theirs.root, "you have written") == null);
}

/// Whether anything at or under `widget` is a focus stop.
fn holdsFocusStop(widget: canvas.Widget) bool {
    if (canvas.widgetIsFocusable(widget)) return true;
    for (widget.children) |child| {
        if (holdsFocusStop(child)) return true;
    }
    return false;
}

/// A sheet's backdrop, which closes the sheet when it is clicked. It is a
/// panel, dialog or card that does not call itself a button, and it holds the
/// sheet's own controls, which the keyboard does reach (and Escape closes it
/// besides). It is the pointer's shortcut and has no reason to be a stop of its
/// own. A row that merely CONTAINS focusable controls is not one: a note row
/// holds a like and a reply and still has to be reachable itself.
fn isBackdrop(widget: canvas.Widget) bool {
    switch (widget.kind) {
        .panel, .dialog, .card => {},
        else => return false,
    }
    if (widget.semantics.role != .none) return false;
    for (widget.children) |child| {
        if (holdsFocusStop(child)) return true;
    }
    return false;
}

/// Whether a focusable descendant of `widget` is bound to the very press it is.
/// A note row opens its thread when clicked, and so does the Reply verb inside
/// it; the row is the pointer's larger target for something the keyboard
/// already reaches, and a second stop beside it would read the note twice.
fn hasKeyboardTwin(tree: AppUi.Tree, widget: canvas.Widget, msg: Msg) bool {
    for (widget.children) |child| {
        if (canvas.widgetIsFocusable(child)) {
            if (tree.msgFor(child.id, .press)) |m| {
                if (std.meta.eql(m, msg)) return true;
            }
        }
        if (hasKeyboardTwin(tree, child, msg)) return true;
    }
    return false;
}

/// Walks one screen and fails on any press the keyboard cannot use. There are
/// three ways to be out of reach, and the first two shipped: a row bound to a
/// press with no focus stop (Tab walks past it); a row with a focus stop that is
/// a layout kind (the toolkit answers Return and Space, and draws a focus ring,
/// only for its own controls and `list_item`, so a `row` given `focusable` takes
/// focus, paints nothing and does nothing on either key); and a focus stop that
/// answers neither key.
pub fn expectKeyboardReach(tree: AppUi.Tree, widget: canvas.Widget, screen: []const u8) !void {
    if (tree.msgFor(widget.id, .press)) |msg| out: {
        if (widget.state.disabled or widget.semantics.hidden) break :out;
        // The card inside a sheet swallows presses so the backdrop does not
        // close it from under you. It is not a control.
        if (msg == .absorb_press) break :out;
        if (!canvas.widgetIsFocusable(widget)) {
            if (isBackdrop(widget) or hasKeyboardTwin(tree, widget, msg)) break :out;
            std.debug.print(
                "\n{s}: a {s} \"{s}\" answers a press and the keyboard cannot reach it (build it with pressRow)\n",
                .{ screen, @tagName(widget.kind), widget.semantics.label },
            );
            return error.PressNotReachableByKeyboard;
        }
        // An inline link is the toolkit's own text hit-area. It is a focus stop
        // that draws no ring (upstream), and `keyActivation` is what makes Return
        // open it. Everything else must be a kind the toolkit rings and answers.
        const inline_link = widget.kind == .text and widget.semantics.role == .link;
        for ([_][]const u8{ "enter", "space" }) |name| {
            const key = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = name, .focused_id = widget.id };
            const answered = if (inline_link)
                main.keyActivation(tree, key) != null
            else
                canvas.widgetKeyboardControlIntent(widget, key) != null;
            if (!answered) {
                std.debug.print(
                    "\n{s}: a {s} \"{s}\" takes focus and {s} does nothing on it, and it draws no focus ring (build it with pressRow)\n",
                    .{ screen, @tagName(widget.kind), widget.semantics.label, name },
                );
                return error.FocusedPressDoesNothing;
            }
        }
    }
    for (widget.children) |child| try expectKeyboardReach(tree, child, screen);
}

test "return and space press a focused inline link" {
    // The toolkit puts a Tab stop on every link inside a paragraph and answers
    // neither key on it, so a reader could tab onto a link in a note and nothing
    // would happen. `keyActivation` is what presses it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest("");
    const body = "see https://example.com/a/page for the details";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes_len = 1;
    const tree = try buildTree(arena, &model);

    const link = findLinkWidget(tree.root) orelse return error.NoLinkInTheNote;
    const press = tree.msgFor(link.id, .press) orelse return error.LinkHasNoPress;
    for ([_][]const u8{ "enter", "space" }) |name| {
        const key = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = name, .focused_id = link.id };
        const got = main.keyActivation(tree, key) orelse return error.KeyDidNotPressTheLink;
        try testing.expect(std.meta.eql(got, press));
    }
    // Only the activation keys, only on key down, and not with a chord.
    const tab = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "tab", .focused_id = link.id };
    try testing.expect(main.keyActivation(tree, tab) == null);
    const up = canvas.WidgetKeyboardEvent{ .phase = .key_up, .key = "enter", .focused_id = link.id };
    try testing.expect(main.keyActivation(tree, up) == null);
    const chord = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .focused_id = link.id, .modifiers = .{ .super = true } };
    try testing.expect(main.keyActivation(tree, chord) == null);
    // And nothing at all when nothing has the keyboard.
    const nowhere = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expect(main.keyActivation(tree, nowhere) == null);
}

pub fn countPressesOf(tree: AppUi.Tree, widget: canvas.Widget, msg: Msg) usize {
    var n: usize = 0;
    if (tree.msgFor(widget.id, .press)) |m| {
        if (std.meta.eql(m, msg)) n += 1;
    }
    for (widget.children) |child| n += countPressesOf(tree, child, msg);
    return n;
}

fn findLinkWidget(widget: canvas.Widget) ?canvas.Widget {
    if (widget.kind == .text and widget.semantics.role == .link) return widget;
    for (widget.children) |child| {
        if (findLinkWidget(child)) |found| return found;
    }
    return null;
}

/// Whether layout node `i` sits under node `ancestor`, following the parent
/// links the layout records rather than comparing rectangles.
pub fn isDescendantOf(p: painted.Painted, i: usize, ancestor: usize) bool {
    var cursor = p.layout.nodes[i].parent_index;
    var hops: usize = 0;
    while (cursor) |parent| : (hops += 1) {
        if (parent == ancestor) return true;
        if (hops > 64) return false;
        cursor = p.layout.nodes[parent].parent_index;
    }
    return false;
}

test "a note the queue had no room for is said out loud" {
    // `g_outbox_overflow` was set here and read nowhere, so the one case it
    // exists for, a note written to this machine and offered to nobody, was the
    // one case the status bar stayed silent about. That is the promise under the
    // offline banner broken exactly where it matters.
    var model = main.initialModel();
    model.outbox_pending = 0;
    model.outbox_stuck = 0;
    model.outbox_overflowed = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a note could not be queued", model.outbox_label(arena));

    // And it outranks the others: a queue that is both busy and overflowing has
    // one thing worth saying.
    model.outbox_pending = 3;
    try testing.expectEqualStrings("a note could not be queued", model.outbox_label(arena));

    // It also has to REACH the bar. The zone returns a spacer when it thinks
    // there is nothing to report, and overflow used to count as nothing.
    model.stage = .ready;
    model.outbox_pending = 0;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "a note could not be queued") != null);
}

test "the mark in the rail goes home" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // It looked like the app's own button in the corner of the rail and did
    // nothing at all when pressed, which is the one thing a mark in that
    // position must never do.
    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const msg = pressMsgByLabel(tree, "Home") orelse return error.MarkHasNoPress;
    switch (msg) {
        .go_home => {},
        else => return error.MarkGoesSomewhereElse,
    }

    // And it is a destination, not a step back: from a person opened from a
    // thread opened from the feed, one press lands on the feed, not one level up.
    //
    // The stack is built with `enterThreadForTest`, NOT by dispatching
    // `.open_thread`. That message looks the note up in the model first and
    // returns when it is not there, so a made-up id leaves the stack empty and
    // this whole test passes against a one-level Back. Which it did.
    var fx: main.EffectsForTest = undefined;
    var root = main.Note{};
    root.id = 0xAA;
    main.enterThreadForTest(&model, root);
    try testing.expectEqual(@as(i64, 0xAA), model.viewing_thread);
    main.update(&model, .{ .open_person = [_]u8{0x2B} ** 32 }, &fx);
    try testing.expect(model.viewing_profile != null);
    // Two levels deep: the thread is on the stack under the person.
    try testing.expect(model.thread_stack_len > 0);

    main.update(&model, .go_home, &fx);
    try testing.expect(model.viewing_profile == null);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);
    try testing.expect(model.stage == .ready);

    // Settings is a screen too, and Home leaves it.
    main.update(&model, .open_settings, &fx);
    main.update(&model, .go_home, &fx);
    try testing.expect(model.stage == .ready);

    // But a question the app has ASKED is not dismissed by navigating: the
    // remembered intent behind it would go with it.
    model.joining = true;
    main.update(&model, .go_home, &fx);
    try testing.expect(model.joining);
}

test "the window is square where the reading happens" {
    // A feed is a column of rows. The wide-and-short default spent its extra
    // width on margin while showing four notes at a time.
    //
    // The square is the READING AREA, not the window. It was the same thing
    // until the second rail existed; now the window carries 238pt of chrome
    // down its left side, and asserting the window itself would either shrink
    // the room by that much or quietly stop meaning anything.
    try testing.expectEqual(main.window_width - main.rails_width, main.window_height);
}

// ---- P1: a click outside a modal closes it ----------------------------------

/// One modal the app can raise: how to open it, what it is called, what closing
/// it means, and one control inside it that has to keep working.
const ModalCase = struct {
    name: []const u8,
    /// The dialog's accessibility label, which is how the backdrop is found.
    label: []const u8,
    dismiss: Msg,
    /// A control inside the card, by accessibility label. Absorbing the press on
    /// the card is what stops a click there reaching the backdrop, and an
    /// absorber that also swallowed the buttons would satisfy the dismissal rule
    /// perfectly while leaving the sheet impossible to use.
    control: []const u8,
    open: *const fn (*Model) void,
};

pub const modal_cases = [_]ModalCase{
    .{
        .name = "join",
        .label = "Join",
        .dismiss = .close_join,
        .control = "Keep browsing",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.joining = true;
            }
        }.f,
    },
    .{
        // The same sheet, second step: a distinct card behind the same label, and
        // the one the reader is on while pasting a bunker URL.
        .name = "bunker",
        .label = "Join",
        .dismiss = .close_join,
        .control = "Back",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.joining = true;
                m.bunker_mode = true;
            }
        }.f,
    },
    .{
        .name = "name",
        .label = "Name",
        .dismiss = .name_skip,
        .control = "Skip",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.naming = true;
            }
        }.f,
    },
    .{
        .name = "edit profile",
        .label = "Edit profile",
        .dismiss = .close_profile_edit,
        .control = "Close",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
                m.editing_profile = true;
            }
        }.f,
    },
};

/// The node index of the dialog labelled `label`.
/// A modal SURFACE by its accessible label: the panel or dialog that carries it,
/// never a text node that happens to share the wording. A card's heading is
/// usually the same words as its dialog's label ("Edit profile" both names the
/// sheet and titles it), and matching that instead found a 62x18 label where the
/// backdrop should be.
fn modalSurfaceIndex(p: painted.Painted, label: []const u8) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        switch (node.widget.kind) {
            .panel, .dialog => {},
            else => continue,
        }
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        return i;
    }
    return null;
}

pub fn modalDialogIndex(p: painted.Painted, label: []const u8) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .dialog) continue;
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        return i;
    }
    return null;
}

pub fn modalCardIndex(p: painted.Painted, root: usize) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .card) continue;
        if (!isDescendantOf(p, i, root)) continue;
        return i;
    }
    return null;
}

/// A control by the words on it, however it carries them: `ui.button` puts its
/// words in the widget's TEXT, while a hand-built row carries them as an
/// accessibility label. A lookup that knows only one of the two silently misses
/// half the controls in the app, and a miss here reads as "no such control".
fn controlNode(p: painted.Painted, root: usize, name: []const u8) ?canvas.Widget {
    for (p.layout.nodes, 0..) |node, i| {
        const w = node.widget;
        // Scoped to the sheet under test, not the whole window. Two sheets can
        // be on screen at once (edit profile sits over Settings) and both carry
        // a button called "Close"; an unscoped lookup found the one BEHIND the
        // sheet and then asked what a press at its coordinates did, which is a
        // question about the sheet on top.
        if (!isDescendantOf(p, i, root)) continue;
        if (std.mem.eql(u8, w.semantics.label, name) or std.mem.eql(u8, w.text, name)) {
            for (p.tree.handlers) |h| {
                if (h.id == w.id and h.event == .press) return w;
            }
        }
    }
    return null;
}

pub fn pressMsgById(p: painted.Painted, id: canvas.ObjectId) ?Msg {
    for (p.tree.handlers) |h| {
        if (h.id != id or h.event != .press) continue;
        return switch (h.action) {
            .message => |m| m,
            else => null,
        };
    }
    return null;
}

test "a press outside a modal's card closes it, and a press inside never does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);

        const root = modalDialogIndex(p, c.label) orelse {
            std.debug.print("{s}: no dialog labelled \"{s}\"\n", .{ c.name, c.label });
            return error.NoModalDialog;
        };
        const card_index = modalCardIndex(p, root) orelse {
            std.debug.print("{s}: no card inside the dialog labelled \"{s}\"\n", .{ c.name, c.label });
            return error.NoModalCard;
        };
        const card = p.layout.nodes[card_index].widget.frame;
        // Cards are centred and far narrower than the window, so the band to the
        // left of one is backdrop at every height.
        try testing.expect(card.x > 8);

        // The BACKDROP fills the window. This is the property SDK 0.9.2 broke and
        // the reason these five surfaces were restructured: a dialog is placed
        // and sized by the runtime now, so the dim and the dismiss target had to
        // stop being the dialog. Asserting the frame rather than trusting the
        // markup, because the whole failure mode was markup that still read as
        // full-window while laying out as a 420pt box.
        const scrim = p.layout.nodes[modalSurfaceIndex(p, c.label) orelse root].widget.frame;
        if (scrim.width < main.window_width or scrim.height < main.window_height) {
            std.debug.print(
                "{s}: the backdrop is {d:.0}x{d:.0} inside a {d:.0}x{d:.0} window, so it does not cover it\n",
                .{ c.name, scrim.width, scrim.height, main.window_width, main.window_height },
            );
            return error.BackdropDoesNotCoverTheWindow;
        }

        // Outside: halfway between the window edge and the card, at three
        // heights, so a rule that happens to hold level with the card's middle
        // is not mistaken for one that holds.
        const outside_x = card.x / 2;
        for ([_]f32{ 0.25, 0.5, 0.75 }) |fraction| {
            const y = main.window_height * fraction;
            const msg = try p.pressMsgAt(outside_x, y) orelse {
                std.debug.print(
                    "{s}: a press at ({d:.0}, {d:.0}), outside the card, dispatches NOTHING\n",
                    .{ c.name, outside_x, y },
                );
                return error.BackdropIsDead;
            };
            try testing.expectEqualStrings(@tagName(c.dismiss), @tagName(msg));
        }

        // Inside: a grid over the whole card, asking where each press LANDS
        // rather than what it dispatches. The rule is that it stops at the card
        // or at something the card contains; what a control inside then does
        // with a press aimed at it is that control's own business, and a modal
        // is allowed to carry a close control of its own (this ladder's "Keep
        // browsing" is one).
        //
        // Stated as containment rather than "is not the dialog" because a card
        // is not always the thing that stops the press: Settings is a scroll
        // filling its card, and a scroll view claims presses on its own. Either
        // answer is correct; escaping the card is not.
        //
        // A grid rather than the centre alone: whether the centre happens to sit
        // on a control is an accident of the layout, and the rule is about every
        // point on the card.
        var landed_inside: usize = 0;
        for (1..8) |ix| {
            for (1..8) |iy| {
                const x = card.x + card.width * (@as(f32, @floatFromInt(ix)) / 8.0);
                const y = card.y + card.height * (@as(f32, @floatFromInt(iy)) / 8.0);
                const target = try p.pressTargetAt(x, y) orelse continue;
                if (target.index != card_index and !isDescendantOf(p, target.index, card_index)) {
                    std.debug.print(
                        "{s}: a press at ({d:.0}, {d:.0}), INSIDE the card, lands on a {s} outside it\n",
                        .{ c.name, x, y, @tagName(target.kind) },
                    );
                    return error.CardFallsThrough;
                }
                landed_inside += 1;
            }
        }
        // And the grid actually sampled something: a card laid out at nothing
        // would satisfy the rule above by never entering the loop body.
        if (landed_inside == 0) {
            std.debug.print("{s}: no sampled point landed anywhere at all\n", .{c.name});
            return error.NothingSampled;
        }

        // And the card still works: the control named for this modal answers to
        // its own message where it is drawn. An absorber that swallowed the
        // buttons too would satisfy every rule above and leave the sheet inert.
        const control = controlNode(p, root, c.control) orelse {
            std.debug.print("{s}: no control called \"{s}\"\n", .{ c.name, c.control });
            return error.NoSuchControl;
        };
        const wired = pressMsgById(p, control.id) orelse {
            std.debug.print("{s}: \"{s}\" has no press bound\n", .{ c.name, c.control });
            return error.ControlNotWired;
        };
        const landed = try p.pressMsgAt(
            control.frame.x + control.frame.width / 2,
            control.frame.y + control.frame.height / 2,
        ) orelse {
            std.debug.print("{s}: a press on \"{s}\" dispatches nothing\n", .{ c.name, c.control });
            return error.ControlSwallowed;
        };
        try testing.expectEqualStrings(@tagName(wired), @tagName(landed));
    }
}

test "the expanded picture closes on a press anywhere it is not a control" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No card here, and that is the point: the viewer fills the window, so
    // "outside the picture" is the whole dark surround and there is nothing to
    // absorb. Neither an image nor plain text claims a press, so every point
    // that is not a button walks up to the viewer itself.
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    const url = "https://example.com/a.jpg";
    _ = model.notes[0].setImageForTest(0, url);
    model.notes_len = 1;
    model.expanded_note = 1;

    const p = try painted.Painted.render(arena, &model);
    // By LABEL, not by kind: the viewer is a panel rather than a dialog, because
    // a picture wants the whole window and a dialog is centred at its preferred
    // size. What the test cares about is the surface that closes on a press.
    const viewer = modalSurfaceIndex(p, "Expanded image") orelse return error.NoViewer;
    const centre = try p.pressMsgAt(main.window_width / 2, main.window_height / 2) orelse
        return error.ViewerBackdropIsDead;
    try testing.expectEqualStrings(@tagName(Msg.close_image), @tagName(centre));

    // The two controls it carries still answer for themselves.
    for ([_][]const u8{ "Close", "Open original" }) |name| {
        const control = controlNode(p, viewer, name) orelse {
            std.debug.print("the viewer has no control called \"{s}\"\n", .{name});
            return error.NoSuchControl;
        };
        const wired = pressMsgById(p, control.id) orelse return error.ControlNotWired;
        const landed = try p.pressMsgAt(
            control.frame.x + control.frame.width / 2,
            control.frame.y + control.frame.height / 2,
        ) orelse {
            std.debug.print("a press on \"{s}\" dispatches nothing\n", .{name});
            return error.ControlSwallowed;
        };
        try testing.expectEqualStrings(@tagName(wired), @tagName(landed));
    }
}

test "the viewer opens the picture that was pressed, not the first one" {
    // The gallery cell dispatched the right index and the update stored it, and
    // then the viewer was called with the note alone and read picture zero. So
    // this is not "the second image opens the first": EVERY cell opened the
    // first, and a one-picture note hid it because zero was the only answer.
    //
    // Asserted through "Open original", because that is the one place the
    // choice reaches something a test can read: an image node carries a
    // registered id, and nothing in a headless render registers one, so the
    // picture itself is "Still loading…" either way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    _ = model.notes[0].setImageForTest(0, "https://example.com/first.jpg");
    _ = model.notes[0].setImageForTest(1, "https://example.com/second.jpg");
    model.notes_len = 1;
    model.expanded_note = 1;
    model.expanded_image = 1;

    const p = try painted.Painted.render(arena, &model);
    const viewer = modalSurfaceIndex(p, "Expanded image") orelse return error.NoViewer;
    const original = controlNode(p, viewer, "Open original") orelse return error.NoSuchControl;
    const msg = pressMsgById(p, original.id) orelse return error.ControlNotWired;
    switch (msg) {
        .open_url => |u| try testing.expectEqualStrings("https://example.com/second.jpg", u),
        else => {
            std.debug.print("\"Open original\" dispatches {s}, not open_url\n", .{@tagName(msg)});
            return error.WrongMessage;
        },
    }
}

// ---- P3: settings is a sheet -------------------------------------------------

/// Settings with everything in it that can be in it: eight relays, six
/// suggestions with hostnames long enough to overrun a row, and a local key.
pub fn openFullSettings(model: *Model) void {
    main.resetRelaysForTest();
    for (0..main.max_relays_for_test) |r| {
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "wss://relay-{d}.a-fairly-long-hostname.example.com", .{r}) catch continue;
        _ = main.addRelayForTest(url, true, true);
    }
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://suggested-one.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-two.a-fairly-long-hostname.example.com", "write" },
        // Longer than a row of its own can hold. A relay URL is accepted up to
        // 96 bytes, so this is representable data, not a stunt: without it the
        // shortening below is code no test can tell from its absence.
        &.{ "r", "wss://a-suggested-relay-with-an-absurdly-long-hostname.somewhere.deep.example.com", "write" },
        &.{ "r", "wss://four.example.com", "write" },
        &.{ "r", "wss://five.example.org", "write" },
        &.{ "r", "wss://six.example.net", "write" },
    };
    main.ingestRelayListForTest(.{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    });
    model.stage = .settings;
}

// ---- P8: the verb row --------------------------------------------------------

// ---- P10: a quoted picture ---------------------------------------------------

/// The frame of the first laid-out node whose text contains `needle`.
pub fn frameOfTextContaining(p: painted.Painted, needle: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, needle) != null) return n.widget.frame;
    }
    return null;
}

// ---- a quote card draws the picture it quotes ---------------------------------

/// A model with one feed row quoting `quoted_id`, whose cache entry says the
/// quoted note carries `quote_picture_url`.
pub fn quotePictureModel(quoted_id: [32]u8, aspect: f32) !main.Model {
    main.dropQuoteForTest(quoted_id);
    main.seedQuoteForTest(quoted_id, [_]u8{0x2b} ** 32, 100, "");
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    const host = "127.0.0.1:9";
    @memcpy(e.image_host_buf[0..host.len], host);
    e.image_host_len = host.len;
    @memcpy(e.image_url_buf[0..quote_picture_url.len], quote_picture_url);
    e.image_url_len = quote_picture_url.len;
    e.image_aspect = aspect;
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    @memcpy(e.image_blur_buf[0..hash.len], hash);
    e.image_blur_len = hash.len;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;
    return model;
}

// ---- P13: a door to the thing holding the key --------------------------------

// ---- P5b: the status bar sits on the floor -----------------------------------

// ---- the menu under every post -----------------------------------------------

/// A feed of one note, with an identity, so a row's menu can be opened.
pub fn oneNoteFeed(model: *Model) void {
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 4242;
    model.notes[0].event_id = [_]u8{0x5a} ** 32;
    model.notes[0].pubkey = [_]u8{0x2b} ** 32;
    const body = "Something worth copying.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes_len = 1;
}

test "the status bar is on screen wherever the reader is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // It was the last row of the FEED's own column, and every level layered over
    // the feed is opaque, so opening a note took the pool's health, the outbox
    // and the signer off screen. Those three are least dispensable exactly when
    // a reader is reading something and about to answer it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const author = [_]u8{0x55} ** 32;
    const Where = struct { name: []const u8, arm: *const fn (*Model) void };
    const places = [_]Where{
        .{ .name = "the feed", .arm = struct {
            fn f(_: *Model) void {}
        }.f },
        .{ .name = "a thread", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
            }
        }.f },
        .{ .name = "a person", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_profile = [_]u8{0x55} ** 32;
            }
        }.f },
        .{ .name = "a thread three levels deep", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
                for (0..3) |d| {
                    m.thread_stack[d] = .{ .note = .{ .created_at = 100 } };
                    m.thread_stack[d].note.id = @intCast(500 + d);
                }
                m.thread_stack_len = 3;
            }
        }.f },
    };

    for (places) |place| {
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root.pubkey = author;
        place.arm(&model);
        const p = try painted.Painted.render(arena, &model);
        const chip = p.frameOf("Relays") orelse {
            std.debug.print("no status bar on {s}\n", .{place.name});
            return error.StatusBarMissing;
        };
        // On the floor of the window rather than pushed off the bottom.
        const bottom = chip.y + chip.height;
        if (bottom > main.window_height or bottom < main.window_height - 60) {
            std.debug.print(
                "on {s} the status bar ends at {d:.1}, and the window is {d:.0} tall\n",
                .{ place.name, bottom, main.window_height },
            );
            return error.StatusBarNotOnTheFloor;
        }

        // And NOT UNDER anything. Present and correctly placed is not the same
        // as visible: a thread is an opaque card laid over the feed, and while
        // the bar was the last row of the feed's own column it kept its frame,
        // kept its position, and was painted over. The first version of this
        // test asked the widget tree and passed on the broken code, which is the
        // whole reason the painted layer exists.
        for (p.layout.nodes) |node| {
            if (node.widget.kind != .card) continue;
            const f = node.widget.frame;
            const covers = f.x <= chip.x and f.y <= chip.y and
                f.x + f.width >= chip.x + chip.width and
                f.y + f.height >= chip.y + chip.height;
            if (!covers) continue;
            std.debug.print(
                "on {s} the status bar is under an opaque {d:.0}x{d:.0} surface\n",
                .{ place.name, f.width, f.height },
            );
            return error.StatusBarCovered;
        }
    }
}

// ---- a dismissal has to clear the state that opened it ------------------------

// ---- the retained extent context ---------------------------------------------

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

// ---- a note that could not be found is not written off forever ---------------

// ---- waiting, and failing, look like themselves -------------------------------

// ---- pressing Follow before the list has arrived says so --------------------

// ---- nothing paints past the edge of the smallest window allowed ------------

test "the accessibility audit is switched on, not just present" {
    // The sweep above asserts every screen passes this audit. A guard that
    // cannot fail says the same thing as a guard that passes, so this hands it
    // a tree it must reject: two sibling buttons announced under one name, which
    // a screen reader reads as the same control twice.
    //
    // Three separate guards this session passed while measuring nothing. This is
    // the cheapest possible way to know this one is not the fourth.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var ui = main.AppUi.init(arena);
    const node = ui.column(.{ .gap = 0 }, .{
        ui.el(.button, .{ .width = 80, .height = 30, .semantics = .{ .role = .button, .label = "Same" } }, .{}),
        ui.el(.button, .{ .width = 80, .height = 30, .semantics = .{ .role = .button, .label = "Same" } }, .{}),
    });
    const tree = try ui.finalizeWithTokens(node, .{});

    // `auditWidgetA11y` rather than the sweep, because the sweep prints its
    // findings, and a test that expects to fail would print a page of teaching
    // voice about a fake tree on every green run.
    const nodes = try arena.alloc(canvas.WidgetLayoutNode, 64);
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, native_sdk.geometry.RectF.init(0, 0, 400, 300), .{}, nodes);
    var findings: [8]canvas.a11y.A11yAuditFinding = undefined;
    const issues = canvas.a11y.auditWidgetA11y(layout, &findings);
    try testing.expect(issues.total > 0);
    try testing.expectEqual(canvas.a11y.A11yAuditRuleKind.duplicate_sibling_label, issues.findings[0].rule);
}

test "the window cannot be declared smaller than its own floor" {
    // Both numbers come from app.zon now, so they cannot drift apart in the
    // source. They can still be declared inconsistently IN the manifest, and a
    // startup size below the floor is a window that opens smaller than it is
    // allowed to be dragged, which is the same class of mistake as the floor
    // sitting seven pixels under what the layout needs (#138).
    try testing.expect(main.window_width >= main.window_min_width);

    // And they are real numbers, not a silently defaulted zero. A parse that
    // quietly returned 0 would satisfy the comparison above and make the
    // overflow sweep measure an empty window.
    try testing.expect(main.window_min_width > 0);
    try testing.expect(main.window_width > 0);
    try testing.expect(main.window_height > 0);
}

test "the composer holds a whole announcement, and says when it will not" {
    // 512 bytes was the old capacity, and an ordinary announcement is longer
    // than that. Pasting one came back cut mid-sentence with nothing on screen
    // admitting it, while the footer read "no length limit". The note this test
    // uses is the real one: at 512 it lost the end of its own URL, so the post
    // would have carried a dead link.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    const note =
        "Plaza is out.\n\nA Nostr client for macOS written in Zig. No Electron, no WebView, no " ++
        "browser hiding in the binary. The toolkit draws every pixel.\n\nThe feed is a local " ++
        "query. It renders from disk before the network answers, and a 500 note feed query is " ++
        "0.28ms against 100k stored events.\n\nYour key can stay out of it entirely: sign through " ++
        "Notary over NIP-46 and the client never sees it.\n\nEarly, and honest about it. No DMs, " ++
        "no zaps, no search yet. Those are the next milestones and they are public.\n\n" ++
        "https://zignostr.com/plaza";
    try testing.expect(note.len > 512);

    model.draft_buffer = @TypeOf(model.draft_buffer).init(note);
    try testing.expectEqualStrings(note, model.draft());

    // The tail is the part that used to go missing, and the part whose loss is
    // hardest to notice: a URL that still looks like a URL.
    try testing.expect(std.mem.endsWith(u8, model.draft(), "https://zignostr.com/plaza"));
}

test "the note field states its own width" {
    // A text element measures at its natural width whatever its ancestors say,
    // so a field that inherits width from a `grow` parent wraps for LAYOUT at
    // one width and measures for PAINT at another. Two wrappings of the same
    // paragraph then land on the same rows, which is what shredded a pasted
    // note on screen.
    //
    // The rule this holds is not "the number is 498". It is that the field
    // carries a definite width of its own, and that the number agrees with the
    // box it sits in.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x5c} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(
        "A paragraph long enough to wrap more than once in the composer, " ++
            "followed by another one.\n\nAnd a second paragraph, so the field has " ++
            "several source lines to lay out and not merely several visual ones.",
    );

    const p = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);
    var found = false;
    for (p.layout.nodes) |n| {
        if (n.widget.kind != .textarea) continue;
        found = true;
        // The frame the engine gave it, against the width the app asked for.
        try testing.expectApproxEqAbs(main.compose_editor_width_for_test, n.widget.frame.width, 1.0);
    }
    try testing.expect(found);
}

test "the thread's reply box takes more than one line" {
    // A reply used to be a 34pt pill, which is a shape that can only hold one
    // line. People answer notes with paragraphs, so the box has to be a
    // `textarea`: that is the widget where Enter inserts a newline and the
    // primary chord submits, while a `text_field` submits on Enter instead.
    //
    // What this pins is the pair, not the number. The reply box is the widget
    // kind that can hold a newline, and it is tall enough to show more than one
    // line of it. A regression to `text_field` fails on the kind; a regression
    // to a one-line box fails on the frame.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const p = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);

    var reply: ?@TypeOf(p.layout.nodes[0].widget) = null;
    for (p.layout.nodes) |n| {
        if (!std.mem.startsWith(u8, n.widget.placeholder, "Reply to")) continue;
        reply = n.widget;
    }
    // Found by its own placeholder, so this cannot pass on some other editor
    // that happens to be on screen.
    try testing.expect(reply != null);
    try testing.expectEqual(canvas.WidgetKind.textarea, reply.?.kind);
    try testing.expectApproxEqAbs(main.reply_editor_height_for_test, reply.?.frame.height, 1.0);
    // Two lines of room at minimum, or "multiline" is a claim the layout does
    // not honour whatever the widget kind says.
    try testing.expect(reply.?.frame.height > 34);
}

/// Finds the first tag whose name is `name`, or null.
pub fn tagNamed(tags: []const nostr.event.Tag, name: []const u8) ?nostr.event.Tag {
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) return t;
    }
    return null;
}

pub fn countTags(tags: []const nostr.event.Tag, name: []const u8) usize {
    var n: usize = 0;
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) n += 1;
    }
    return n;
}

test "a reply whose parent is missing says so instead of posing as a direct reply" {
    // Three different things used to render identically: a genuine direct reply
    // to the root, a reply tagged to the root, and a reply that names a parent
    // nobody has. The third asserted it answered the opening note, which is a
    // claim about the conversation that nothing in the event supports.
    //
    // Taken from a real thread: two replies named parents that returned nothing
    // from damus, nos.lol, primal and nostr.band, and both drew as first-level
    // replies to a note they were not answering.
    const root_id = [_]u8{0xa0} ** 32;

    var notes: [3]main.Note = .{ .{}, .{}, .{} };
    // A direct reply: names the root.
    notes[0].event_id = [_]u8{0xb1} ** 32;
    notes[0].created_at = 1_800_000_001;
    notes[0].reply_parent = root_id;
    notes[0].has_reply_parent = true;
    // A reply to that one, whose parent IS in the set.
    notes[1].event_id = [_]u8{0xb2} ** 32;
    notes[1].created_at = 1_800_000_002;
    notes[1].reply_parent = notes[0].event_id;
    notes[1].has_reply_parent = true;
    // An orphan: names a parent that is nowhere in the set.
    notes[2].event_id = [_]u8{0xb3} ** 32;
    notes[2].created_at = 1_800_000_003;
    notes[2].reply_parent = [_]u8{0xcc} ** 32;
    notes[2].has_reply_parent = true;

    main.arrangeThread(&notes, root_id);

    var direct: ?*main.Note = null;
    var nested: ?*main.Note = null;
    var orphan: ?*main.Note = null;
    for (&notes) |*note| {
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb1} ** 32)) direct = note;
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb2} ** 32)) nested = note;
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb3} ** 32)) orphan = note;
    }

    // The orphan still sits at the top level, because there is nowhere better,
    // but it is no longer indistinguishable from a real first-level reply.
    try testing.expectEqual(@as(u8, 1), orphan.?.depth);
    try testing.expect(orphan.?.parent_missing);

    // And neither of the honest ones is marked.
    try testing.expectEqual(@as(u8, 1), direct.?.depth);
    try testing.expect(!direct.?.parent_missing);
    try testing.expectEqual(@as(u8, 2), nested.?.depth);
    try testing.expect(!nested.?.parent_missing);
}

// -- The feed brings itself up to date without re-reading the store ----------
//
// The feed used to answer "has anything changed" by asking the store for the
// whole window again, once a second, on the render thread. Measured in the
// library's benchmark at 2049 authors, ReleaseFast, best of fifty: 1.46 ms for a
// screenful, 10.8 ms twenty pages down, against a 16.7 ms frame.
//
// These assert on WHICH PATH RAN and how much it parsed, never on a stopwatch.
// The test binary is Debug and the machine is shared, so a timing assertion here
// measures the machine. A counter measures the code.

/// A store, an identity, a follow set and a model, wired the way the app wires
/// them, with change detection reset so a test starts from a known place.
pub const FeedFixture = struct {
    tmp: std.testing.TmpDir,
    store: nostr.store.Store,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    model: *main.Model,

    pub fn init(arena: std.mem.Allocator, name: []const u8) !*FeedFixture {
        const f = try arena.create(FeedFixture);
        f.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ f.tmp.sub_path, name });
        f.store = try nostr.store.Store.open(db_path, .{});
        f.signer = nostr.keys.Signer.init();
        f.kp = try f.signer.keyPairFromSecretKey([_]u8{77} ** 32);
        main.resetProfilesForTest();
        main.resetMediaForTest();
        main.setIdentityForTest([_]u8{77} ** 32);
        main.setStoreForTest(&f.store);
        main.resetFeedChangeDetectionForTest();
        main.resetFeedWork();
        f.model = try arena.create(main.Model);
        f.model.* = main.initialModel();
        f.model.stage = .ready;
        return f;
    }

    pub fn deinit(f: *FeedFixture) void {
        main.setStoreForTest(null);
        main.clearIdentityForTest();
        main.resetProfilesForTest();
        f.signer.deinit();
        f.store.deinit();
        f.tmp.cleanup();
    }

    /// Stores an event the way the app does: through the one door, which is
    /// where an arrival announces itself.
    pub fn arrive(f: *FeedFixture, arena: std.mem.Allocator, created_at: i64, content: []const u8) !nostr.event.Event {
        const ev = try signedNote(arena, f.signer, f.kp, created_at, content);
        _ = try main.plazaIngestForTest(arena, ev);
        return ev;
    }

    pub fn tick(f: *FeedFixture, now_s: i64) void {
        main.tickForTest(f.model, now_s);
    }

    pub fn ids(f: *FeedFixture, out: []i64) []i64 {
        for (f.model.notes[0..f.model.notes_len], 0..) |n, i| out[i] = n.id;
        return out[0..f.model.notes_len];
    }
};

test "a card already on screen survives a splice unparsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "sentinel");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "the original text");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    const sentinel = "SENTINEL";
    @memcpy(f.model.notes[0].content_buf[0..sentinel.len], sentinel);
    f.model.notes[0].content_len = sentinel.len;

    _ = try f.arrive(arena, 1_800_000_050, "another note");
    f.tick(1_800_000_100);

    try testing.expectEqual(@as(usize, 2), f.model.notes_len);
    var found = false;
    for (f.model.notes[0..f.model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) found = true;
    }
    try testing.expect(found);
}

// -- A connection that stopped answering ------------------------------------
//
// A relay's ingest thread blocks in `receive` until the relay speaks. A peer
// that goes away without closing leaves that thread waiting forever behind a
// green dot: no error, no timeout, no reconnect, and nothing able to tell it
// apart from a quiet night. The keeper is a separate thread precisely because
// the waiting one cannot notice anything.
//
// When it pings and when it gives up is `nostr.liveness`, tested there. What
// is asserted here is what this app does with that decision.

// -- Reading where your follows actually write -------------------------------
//
// The pool asks every relay in it about every person the reader follows, so a
// follow who writes only to relays the reader is not on is invisible: no error,
// no empty state, they simply are not there. These connect to the top few
// relays the ranking found that the reader is NOT already on, and ask each only
// about the people who write there.

/// Whether any routed slot is pointed at this relay.
pub fn routedHolds(url: []const u8) bool {
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        const u = main.discoveredUrlCopy(i, &buf) orelse continue;
        if (std.mem.eql(u8, u, url)) return true;
    }
    return false;
}

// -- Asking on a socket that is already open ---------------------------------
//
// A one-shot used to dial its own connection to every relay in turn: eight TLS
// handshakes and a parked thread to learn one display name. The pool already
// holds those sockets, and no shipping client dials for a one-shot.
//
// The property that makes sharing safe is that there is nothing to route back.
// Every event goes to the store on the thread that owns the socket, whoever
// asked, and the render thread reads the store. A subscription id names a
// question, never a caller waiting on an answer.

// -- Every socket asks only about the people it can answer for ---------------
//
// The pool used to ask all eight of its relays about every followed author. Now
// each is asked about the follows who write there, plus the residual: everyone
// no relay in either set is being asked about.
//
// Defining the residual correctly is the whole risk. It is NOT "authors with no
// relay list": an author who publishes only to a relay that did not make the
// cut has a list and is still asked of nobody, and vanishes with no error and
// no empty state. That is the exact failure the outbox model exists to fix.

/// Seeds a store with one kind:10002 per author and returns the follow set.
pub fn seedRelayLists(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    specs: []const []const []const u8,
    out: [][32]u8,
) !void {
    for (specs, 0..) |urls, i| {
        var secret = [_]u8{21} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        out[i] = kp.public_key;
        if (urls.len == 0) continue;
        var tags = try arena.alloc(nostr.event.Tag, urls.len);
        for (urls, 0..) |u, j| {
            const t = try arena.alloc([]const u8, 2);
            t[0] = "r";
            t[1] = u;
            tags[j] = t;
        }
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 10002, tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
}

// -- A mention is a person, and pressing one says so --------------------------

test "a mention's link payload is a person and an http link is not" {
    const pk = [_]u8{9} ** 32;
    var mentions = main.MentionList{};
    var buf: [64]u8 = undefined;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const npub = try nostr.nip19.encodeNpub(arena_state.allocator(), pk);
    const src = try std.fmt.allocPrint(arena_state.allocator(), "nostr:{s}", .{npub});
    _ = main.renderContentInto(&buf, src, &.{}, &mentions);

    try testing.expect(main.mentionLinkPubkey(mentions.all()[0].link()) != null);
    // Everything a paragraph's one link handler can otherwise be given. The two
    // share a message, so telling them apart is not a nicety: getting it wrong
    // means either a profile press shelling out to the browser, or a stranger's
    // URL being read as thirty-two bytes of pubkey.
    try testing.expect(main.mentionLinkPubkey("https://example.com/x") == null);
    try testing.expect(main.mentionLinkPubkey("") == null);
    // Exactly the payload's length, and starting with the same letter, and still
    // not a mention, because the byte after it is not zero.
    try testing.expect(main.mentionLinkPubkey("p" ++ ("a" ** 33)) == null);
    // Carrying the tag is not enough either. Without the length checked first,
    // these two read a pubkey out of a buffer that is not one: the short one
    // reaches past its end, and the long one takes the wrong thirty-two bytes.
    try testing.expect(main.mentionLinkPubkey("p\x00short") == null);
    try testing.expect(main.mentionLinkPubkey("p\x00" ++ ("z" ** 40)) == null);
}

/// WCAG relative luminance, for the one question a colour table cannot answer
/// by inspection: is this readable on the window it has to survive?
fn relativeLuminance(c: canvas.Color) f64 {
    const ch = struct {
        fn lin(v: f32) f64 {
            const x: f64 = @floatCast(v);
            return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * ch.lin(c.r) + 0.7152 * ch.lin(c.g) + 0.0722 * ch.lin(c.b);
}

fn contrastRatio(a: canvas.Color, b: canvas.Color) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

test "every community colour is readable as text on this window" {
    // `on_dark` is the one column in the table that is OURS rather than
    // Hallway's, and it exists for exactly one reason: Hallway's `primary` is a
    // fill, and several of the eighteen are unreadable as text on #0a0a0b
    // (INDIGO is about 2.5:1). The lightness floor that fixes that is not a
    // taste, it is the lowest one at which all eighteen clear 4.5:1, so it is
    // pinned here rather than left to whoever next edits a hex.
    const window = theme.palette.surface_window;
    var worst: f64 = 1000;
    var worst_name: []const u8 = "";
    for (theme.place_colors) |c| {
        const ratio = contrastRatio(c.on_dark, window);
        if (ratio < worst) {
            worst = ratio;
            worst_name = c.name;
        }
        if (ratio < 4.5) {
            std.debug.print("{s} reads at {d:.2}:1 on the window, under 4.5:1\n", .{ c.name, ratio });
            return error.UnreadableCommunityColour;
        }
        // And the ink has to survive the fill it is knocked out of. This is the
        // assertion that caught six rows where Hallway's own near-black ink is
        // unreadable on its own colour (VIOLET at 2.08:1). 4.0 rather than 4.5
        // because the floor is DEFAULT at 4.16:1, and lifting that would mean
        // altering the FILL -- the community's actual colour, which is theirs
        // and not ours to correct.
        const on_fill = contrastRatio(c.on_primary, c.primary);
        if (on_fill < 4.0) {
            std.debug.print("{s}: label reads at {d:.2}:1 on its own fill\n", .{ c.name, on_fill });
            return error.UnreadableLabelOnFill;
        }
    }
    // Worth knowing which one is closest to the edge when this next moves.
    try testing.expect(worst >= 4.5);
}

test "a logo body that arrives after you walk out is not painted on the new room" {
    // The fetch is keyed by a constant, so the answer carries no clue which room
    // asked. Taking `activePlace()` at delivery meant a body fetched for room A
    // and landing after a walk into room B was decoded into B's slot AND cached
    // under B's logo URL, so the wrong mark came back on every later visit and
    // every later launch. `handleBannerFetched` has carried this guard for
    // faces all along.
    var fx = main.inertEffectsForTest();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // Asked for by Monero, delivered while standing in BASSPISTOL.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.setPlaceLogoAskedForTest([_]u8{0xa1} ** 32, "moneroh");
    main.deliverPlaceLogoBodyForTest(&fx, "a body that is not this room's");

    // Dropped, and left idle so this room's own mark is still asked for. Not
    // `failed`: nothing about THIS room's logo has been tried yet.
    try testing.expectEqualStrings("idle", main.placeLogoStateNameForTest());
    try testing.expect(!main.placeLogoShownForTest());
}

test "the emoji face the Linux build registers parses, and carries colour emoji" {
    // The toolkit refuses a face whose `maxp` declares ANY glyph past its
    // outline budgets, and refuses the whole file rather than the one picture,
    // so a single over-detailed emoji costs every other one in it.
    //
    // This shipped that way once and I only found it by running the app on
    // Linux and reading the log: three glyphs of the face I was building then
    // were past the 1024-point budget, registration refused the face, text
    // silently fell back to plain Geist, and every emoji drew as a solid block.
    // The screenshot looked fine because nothing in view had an emoji in it.
    //
    // Embedded HERE rather than read through theme.zig on purpose: the app does
    // not embed this face on macOS (it has CoreText and does not need it), so
    // reading it from there would make this test check an empty string on the
    // platform most of the work happens on.
    const emoji = @embedFile("fonts/Twemoji.ttf");
    const font_ttf = native_sdk.canvas.font_ttf;
    const face = font_ttf.Face.parse(emoji) catch {
        if (font_ttf.parseFailureReason(emoji)) |why| std.debug.print("\nthe emoji face was refused: {s}\n", .{why});
        return error.TheEmojiFaceIsPastTheToolkitsBudget;
    };

    // Registering it is only half of it. The renderer falls back to a
    // registered face for a glyph the text face lacks ONLY when that face
    // carries colour, so a build that quietly swapped in a monochrome emoji
    // font would register fine and still draw blocks.
    if (!face.hasColorGlyphs()) return error.TheEmojiFaceIsNotAColourFace;

    // The pictures a note actually carries, including the ones above U+FFFF
    // that need a format-12 cmap to reach at all.
    for ([_]u21{ 0x1F600, 0x1F525, 0x1F389, 0x2764, 0x1F596, 0x2620, 0x1F44D }) |cp| {
        const glyph = face.glyphIndex(cp);
        if (glyph == 0) return error.AnEmojiIsMissingFromTheFace;
        if (face.colorLayerCount(glyph) == 0) return error.AnEmojiWouldDrawInOneColour;
    }

    // And it never shadows plain text. An emoji face claims the keycap bases
    // (the digits, `#`, `*`) because a keycap is built from one, so "2" IS in
    // this face as a picture. What keeps a digit a digit is that the renderer
    // asks the text face FIRST and only falls through for a codepoint it has
    // no glyph for, so the guarantee to check is Geist's coverage, not
    // Twemoji's.
    const geist = font_ttf.geist_regular;
    for ([_]u21{ 'A', 'z', '0', '9', '#', '*' }) |cp| {
        if (geist.glyphIndex(cp) == 0) return error.TheTextFaceWouldYieldPlainTextToTheEmojiFace;
    }
}

test "the scripts Geist cannot draw are covered by a face the Linux build registers" {
    // Off macOS there is no platform text provider, so the registered faces are
    // the only glyph source and a codepoint none of them carries is painted as
    // a SOLID FILLED RECTANGLE, not a placeholder outline. Geist covers Latin
    // and Cyrillic; its Greek is four maths symbols. Everything below used to
    // be blocks.
    //
    // Embedded here rather than read through theme.zig for the same reason the
    // emoji test does it: the app does not embed these on macOS, so reading
    // them from there would check empty strings on the platform this runs on.
    const font_ttf = native_sdk.canvas.font_ttf;
    const latin = font_ttf.Face.parse(@embedFile("fonts/NotoSans-Regular.ttf")) catch
        return error.TheNotoSansFaceIsRefused;
    const sc = font_ttf.Face.parse(@embedFile("fonts/NotoSansSC-Regular.ttf")) catch
        return error.TheNotoSansSCFaceIsRefused;
    const kr = font_ttf.Face.parse(@embedFile("fonts/NotoSansKR-Hangul.ttf")) catch
        return error.TheNotoSansKRFaceIsRefused;

    const geist = font_ttf.geist_regular;
    // One real word per script, not one character: a face can carry a stray
    // codepoint from a block it does not otherwise cover.
    const cases = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "Greek", .text = "Ελληνικά" },
        .{ .name = "Japanese hiragana", .text = "こんにちは" },
        .{ .name = "Japanese katakana", .text = "ナカムラ" },
        .{ .name = "Japanese kanji", .text = "日本語" },
        .{ .name = "Chinese", .text = "你好世界" },
        .{ .name = "Korean", .text = "안녕하세요" },
        .{ .name = "Cyrillic", .text = "Привет" },
    };
    for (cases) |case| {
        var i: usize = 0;
        while (i < case.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(case.text[i]) catch return error.BadFixture;
            const cp = std.unicode.utf8Decode(case.text[i .. i + len]) catch return error.BadFixture;
            i += len;
            if (geist.glyphIndex(cp) != 0) continue; // the text face draws it
            if (latin.glyphIndex(cp) != 0) continue;
            if (sc.glyphIndex(cp) != 0) continue;
            if (kr.glyphIndex(cp) != 0) continue;
            std.debug.print("\nno registered face carries U+{X:0>4} ({s})\n", .{ cp, case.name });
            return error.AScriptWouldStillDrawAsSolidBlocks;
        }
    }

    // The other half: these faces must not TAKE anything from Geist. The
    // renderer asks the text face first, so Latin stays Geist whatever else is
    // registered, and this pins the premise that makes that true.
    for ("The quick brown fox 0123456789") |ch| {
        if (geist.glyphIndex(ch) == 0) return error.TheTextFaceWouldYieldLatinToANotoFace;
    }
}

test "the weight faces the Linux build registers parse, and differ from regular" {
    // Off macOS the toolkit maps a span's weight onto reserved font ids and
    // bundles no face for any of them, so medium and bold ink REGULAR outlines
    // unless the app fills those ids. Plaza fills them from the same two files
    // CoreText is handed on macOS (main.zig `registered_fonts`).
    //
    // The failure this guards is silent: registration refuses a face whole if
    // its `maxp` is past the outline budgets, and the app then falls back to
    // regular and simply looks flat. Nothing crashes and no test would notice.
    const font_ttf = native_sdk.canvas.font_ttf;
    inline for (.{
        .{ "Geist-Medium.ttf", theme.geist_medium_ttf },
        .{ "Geist-Bold.ttf", theme.geist_bold_ttf },
    }) |entry| {
        const face = font_ttf.Face.parse(entry[1]) catch {
            if (font_ttf.parseFailureReason(entry[1])) |why| std.debug.print("\n{s} was refused: {s}\n", .{ entry[0], why });
            return error.AWeightFaceIsPastTheToolkitsBudget;
        };

        // A weight that draws the same outlines as regular is the defect, not
        // the fix. `M` is the widest Latin glyph, so a real weight step shows
        // in its advance; identical advances would mean the same face twice.
        const glyph = face.glyphIndex('M');
        if (glyph == 0) return error.AWeightFaceIsMissingTheLatinAlphabet;
        const regular = font_ttf.Face.parse(theme.geist_ttf) catch return error.TheRegularFaceIsRefused;
        const regular_m = regular.glyphIndex('M');
        const width = face.advance(glyph) * regular.units_per_em;
        const regular_width = regular.advance(regular_m) * face.units_per_em;
        if (width <= regular_width) return error.AWeightFaceIsNoHeavierThanRegular;
    }
}

test "a shortcut sends the message its tile sends" {
    // A key that reimplements what a control does is a second implementation to
    // keep in step, and this app has one already declared for compose and
    // settings. The places keys go through the same messages.
    try testing.expectEqual(main.Msg.toggle_places_rail, main.onCommandForTest("places-rail").?);
    try testing.expectEqual(main.Msg.place_bounce, main.onCommandForTest("place-bounce").?);
    try testing.expectEqual(main.Msg{ .place_step = -1 }, main.onCommandForTest("place-prev").?);
    try testing.expectEqual(main.Msg{ .place_step = 1 }, main.onCommandForTest("place-next").?);
    try testing.expect(main.onCommandForTest("no-such-key") == null);
}

test "every bundled face agrees about where the baseline is" {
    // The macOS host draws a run with `drawAtPoint:(x, baseline - size)` into a
    // flipped context, and AppKit then puts the baseline `round(ascender)`
    // below that point. Subtracting the point SIZE asserts "ascent == size",
    // which is a per-FACE number, so two faces on one line diverge by the
    // difference in their ascents.
    //
    // Ours did: Geist-Regular ships 920/-220/100 and the other three shipped
    // 1005/-295/0, which at a 14.5pt body put every medium, bold and mono run
    // exactly 2pt BELOW the regular text beside it. Mentions, the reply
    // context label, bold names next to regular meta: all of them sat low, and
    // nothing on the Zig side could see it, because the display list carries
    // one baseline for the whole line and is correct.
    //
    // scripts/harmonize-font-metrics.py made the four agree. This is what
    // notices if a font update ever pulls them apart again.
    const faces = [_]struct { name: []const u8, ttf: []const u8 }{
        .{ .name = "Geist-Regular", .ttf = theme.geist_ttf },
        .{ .name = "Geist-Medium", .ttf = theme.geist_medium_ttf },
        .{ .name = "Geist-Bold", .ttf = theme.geist_bold_ttf },
        .{ .name = "GeistMono-Regular", .ttf = theme.geist_mono_ttf },
    };

    var want: ?[6]i16 = null;
    for (faces) |face| {
        const m = try verticalMetrics(face.ttf);
        if (want) |w| {
            if (!std.mem.eql(i16, &w, &m)) {
                std.debug.print(
                    "\n{s} has vertical metrics {any}, and Geist-Regular has {any}.\n" ++
                        "Two faces that disagree draw on two different baselines. Run\n" ++
                        "  python3 scripts/harmonize-font-metrics.py\n",
                    .{ face.name, m, w },
                );
                return error.FacesDisagreeAboutTheBaseline;
            }
        } else want = m;
    }
    // And they agree on numbers that are actually there, not on all zeroes.
    try testing.expect(want.?[0] > 0);
}

/// hhea ascender/descender/lineGap and OS/2 sTypoAscender/Descender/LineGap,
/// read straight out of the sfnt. Six numbers, because macOS picks the typo set
/// when USE_TYPO_METRICS is on and the hhea set when it is not, and a face is
/// only safe if both agree with everyone else's.
fn verticalMetrics(ttf: []const u8) ![6]i16 {
    if (ttf.len < 12) return error.NotAFont;
    const count = std.mem.readInt(u16, ttf[4..6], .big);
    var hhea: ?usize = null;
    var os2: ?usize = null;
    for (0..count) |i| {
        const entry = 12 + i * 16;
        if (entry + 16 > ttf.len) return error.NotAFont;
        const tag = ttf[entry..][0..4];
        const off = std.mem.readInt(u32, ttf[entry + 8 ..][0..4], .big);
        if (std.mem.eql(u8, tag, "hhea")) hhea = off;
        if (std.mem.eql(u8, tag, "OS/2")) os2 = off;
    }
    const h = hhea orelse return error.NoHhea;
    const o = os2 orelse return error.NoOs2;
    if (h + 10 > ttf.len or o + 74 > ttf.len) return error.NotAFont;
    return .{
        std.mem.readInt(i16, ttf[h + 4 ..][0..2], .big),
        std.mem.readInt(i16, ttf[h + 6 ..][0..2], .big),
        std.mem.readInt(i16, ttf[h + 8 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 68 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 70 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 72 ..][0..2], .big),
    };
}

test "a paste that does not fit says so instead of vanishing" {
    // The composer caps the draft at 4096 and the retained editor caps at half
    // a megabyte, so a longer paste is clamped on the way in. Nothing read the
    // buffer's `truncated` flag, whose own documentation calls it a "loud seam
    // for paste", so the overflow disappeared without a word: the counter read
    // "0 left", which says the box is exactly full, not that a third of what
    // was just pasted is gone. Measured live at 6064 bytes pasted, 4096 kept,
    // 1968 lost, cut mid-word.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    // Something that fits: nothing to report.
    main.update(&model, .{ .draft_edit = .{ .insert_text = "a short note" } }, &fx);
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);

    // And something that does not.
    const cap = main.compose_capacity_for_test;
    const big = try arena_state.allocator().alloc(u8, cap + 500);
    @memset(big, 'x');
    main.update(&model, .{ .draft_edit = .{ .insert_text = big } }, &fx);
    if (model.draft_dropped == 0) {
        std.debug.print("{d} bytes went in over a {d} cap and nothing was reported\n", .{ big.len, cap });
        return error.TheOverflowVanishedInSilence;
    }
    // The draft is full, and what did not fit is exactly what was refused.
    try testing.expectEqual(cap, model.draft().len);
    try testing.expectEqual(big.len - (cap - "a short note".len), model.draft_dropped);

    // The composer says it, rather than "0 left".
    const line = main.composeReachForTest(arena_state.allocator(), model.draft().len, model.draft_dropped);
    if (std.mem.indexOf(u8, line, "did not fit") == null) {
        std.debug.print("the composer says \"{s}\"\n", .{line});
        return error.TheComposerNeverSaidSo;
    }

    // Clearing the box clears the warning with it.
    main.update(&model, .close_compose, &fx);
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);
}

test "every line break macOS draws and the layout does not becomes a plain LF" {
    // The toolkit breaks a line only at LF, and on macOS the host draws each
    // row through AppKit, which also breaks at these. A paste separated by any
    // of them drew the words after the break a row lower, on top of the next
    // row (#165). Reproduced live with CR, U+2028 and vertical tab.
    const Case = struct { in: []const u8, want: []const u8, changed: bool };
    const cases = [_]Case{
        .{ .in = "one\rtwo", .want = "one\ntwo", .changed = true },
        .{ .in = "one\r\rtwo", .want = "one\n\ntwo", .changed = true },
        .{ .in = "one\x0btwo\x0cthree", .want = "one\ntwo\nthree", .changed = true },
        .{ .in = "one\u{0085}two", .want = "one\ntwo", .changed = true },
        .{ .in = "one\u{2028}two\u{2029}three", .want = "one\ntwo\nthree", .changed = true },
        .{ .in = "trailing\r", .want = "trailing\n", .changed = true },
        .{ .in = "one\r\r\ntwo", .want = "one\n\r\ntwo", .changed = true },
        // Left alone. CRLF draws correctly, since its CR ends a row, and a
        // change would cost the caret and undo for nothing.
        .{ .in = "one\r\ntwo", .want = "one\r\ntwo", .changed = false },
        .{ .in = "one\r\n\r\ntwo", .want = "one\r\n\r\ntwo", .changed = false },
        .{ .in = "one\n\ntwo", .want = "one\n\ntwo", .changed = false },
        // Characters that share a leading byte with a separator.
        .{ .in = "caf\u{e9} \u{2026} \u{2022} \u{1F600}", .want = "caf\u{e9} \u{2026} \u{2022} \u{1F600}", .changed = false },
        // Truncated sequences at the very end are copied, not misread.
        .{ .in = "a\xe2\x80", .want = "a\xe2\x80", .changed = false },
        .{ .in = "a\xc2", .want = "a\xc2", .changed = false },
        .{ .in = "", .want = "", .changed = false },
    };
    for (cases) |c| {
        var out: [64]u8 = undefined;
        const got = main.plainLineBreaks(c.in, &out);
        testing.expectEqualStrings(c.want, got.text) catch |err| {
            std.debug.print("for input {any}\n", .{c.in});
            return err;
        };
        try testing.expectEqual(c.want.len, got.full_len);
        try testing.expectEqual(c.changed, got.changed);
    }
}

test "a full buffer stops at a character boundary and still counts the rest" {
    // "ab" then a three-byte character: with room for four bytes, the
    // character does not fit whole, so it is left out rather than cut, and
    // "cd", which would fit, is not written after the gap.
    var out: [4]u8 = undefined;
    const got = main.plainLineBreaks("ab\u{2026}cd", &out);
    try testing.expectEqualStrings("ab", got.text);
    try testing.expectEqual(@as(usize, 7), got.full_len);
}

test "a paste with CR line breaks lands in every multi-line box as LF" {
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    const pasted = "Alpha one.\rBravo two.\r\rCharlie three.\u{2028}Delta four.";
    const plain = "Alpha one.\nBravo two.\n\nCharlie three.\nDelta four.";

    main.update(&model, .{ .draft_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.draft());
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);

    main.update(&model, .{ .reply_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.reply_buffer.text());

    main.update(&model, .{ .profile_about_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.profile_about_buffer.text());
}

test "a paste that had to change leaves the caret where the editor puts it" {
    // The editor takes the model's text when the two differ, and then puts
    // its caret at the end, with no way for the app to say otherwise. The
    // model's caret has to be there too, or the next key goes in somewhere
    // the reader cannot see: found live, typing after a mid-text paste.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.update(&model, .{ .draft_edit = .{ .insert_text = "Hello world" } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);

    main.update(&model, .{ .draft_edit = .{ .insert_text = "A\rB" } }, &fx);
    try testing.expectEqualStrings("HelloA\nB world", model.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(model.draft().len), model.draft_buffer.selection);
    main.update(&model, .{ .draft_edit = .{ .insert_text = "x" } }, &fx);
    try testing.expectEqualStrings("HelloA\nB worldx", model.draft());

    // A paste that needed no change is an ordinary edit, caret and all.
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .insert_text = "C\r\nD" } }, &fx);
    try testing.expectEqualStrings("HelloC\r\nDA\nB worldx", model.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(9), model.draft_buffer.selection);
}

test "a paste cut to fit keeps the caret where the editor puts it, and no lone CR" {
    // The editor holds the whole paste, the draft only what fits, so the
    // editor takes the draft's text and moves its caret to the end. A cut can
    // also land between a CR and its LF, which would leave exactly the lone CR
    // that #165 is about.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cap = main.compose_capacity_for_test;
    const start = "Hello world\nSecond line";
    const room = cap - start.len;

    // The cut lands between CR and LF.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.update(&model, .{ .draft_edit = .{ .insert_text = start } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const split = try arena_state.allocator().alloc(u8, room + 5);
    @memset(split, 'x');
    split[room - 1] = '\r';
    split[room] = '\n';
    main.update(&model, .{ .draft_edit = .{ .insert_text = split } }, &fx);
    try testing.expectEqual(cap, model.draft().len);
    if (std.mem.indexOfScalar(u8, model.draft(), '\r') != null) return error.ALoneCrSurvivedTheCut;
    try testing.expectEqual(canvas.TextSelection.collapsed(cap), model.draft_buffer.selection);

    // A plain paste cut to fit, in the middle of the text.
    var model2 = main.initialModel();
    model2.stage = .ready;
    model2.composing = true;
    main.update(&model2, .{ .draft_edit = .{ .insert_text = start } }, &fx);
    main.update(&model2, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const long = try arena_state.allocator().alloc(u8, room + 100);
    @memset(long, 'y');
    main.update(&model2, .{ .draft_edit = .{ .insert_text = long } }, &fx);
    try testing.expectEqual(canvas.TextSelection.collapsed(cap), model2.draft_buffer.selection);

    // Refused outright, into a full draft: nothing here changes, and the
    // caret stays where it was.
    main.update(&model2, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const full = try arena_state.allocator().dupe(u8, model2.draft());
    main.update(&model2, .{ .draft_edit = .{ .insert_text = "p\rq" } }, &fx);
    try testing.expectEqualStrings(full, model2.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(5), model2.draft_buffer.selection);
}

test "an address Plaza cannot read keeps the field open with what was typed in it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    try testing.expect(model.address_open);

    // Starts like an address and does not decode. Plain words would not do: the
    // same field finds people by name, so those are a search and not a refusal.
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "npub1notreal" } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // Open, with the text still there: the reader is about to fix a character,
    // and a field that empties itself on a refusal makes them paste again.
    try testing.expect(model.address_open);
    try testing.expectEqualStrings("npub1notreal", model.address_draft());
    try testing.expectEqual(main.AddressError.unreadable, model.address_error);

    // And the sheet says so, rather than still offering the hint.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "not an address Plaza can read") != null);

    // Typing is the answer to the refusal, so the refusal goes at once.
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "n" } }, &fx);
    try testing.expectEqual(main.AddressError.none, model.address_error);
}

test "opening an address puts the field away before it navigates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]u8{0x55} ** 32;
    const note1 = try nostr.nip19.encodeNote(arena, id);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = note1 } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // Closed, and emptied. Every destination behind this has an early return in
    // front of it, so closing on arrival would leave the sheet up in exactly
    // the cases where the reader has least idea why nothing moved.
    try testing.expect(!model.address_open);
    try testing.expectEqualStrings("", model.address_draft());

    // Nothing holds this note, so it was asked for rather than silently dropped.
    try testing.expect(main.quoteHintCountForTest(id) != null);
}

test "the relays an address named reach the fetch that goes looking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();

    const id = [_]u8{0x66} ** 32;
    const pk = [_]u8{0x77} ** 32;
    const relays = [_][]const u8{ "wss://hinted.example", "wss://also.example" };

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNevent(arena, id, &relays, pk, 1) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // This is the whole of #259 on the event side: without it the fetch asks
    // only relays the reader already reads, and the card settles on "no relay
    // has" a note that one of these two is holding.
    try testing.expectEqual(@as(?u8, 2), main.quoteHintCountForTest(id));

    // An nprofile names a person the same way.
    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNprofile(arena, pk, &relays) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);
    try testing.expectEqual(@as(?u8, 2), main.profileHintCountForTest(pk));
}

/// A store in a temp dir and a model at the feed, with a way to paste into
/// the address field: what the address tests below start from.
pub const AddressFixture = struct {
    tmp: testing.TmpDir,
    store: nostr.store.Store,
    model: main.Model,
    fx: main.EffectsForTest = undefined,

    pub fn up(self: *AddressFixture, name: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ self.tmp.sub_path, name });
        self.store = try nostr.store.Store.open(db_path, .{});
        main.setStoreForTest(&self.store);
        main.resetPlacesForTest();
        main.resetQuotesForTest();
        self.model = main.initialModel();
        self.model.stage = .ready;
    }

    pub fn down(self: *AddressFixture) void {
        main.resetPlacesForTest();
        main.setStoreForTest(null);
        self.store.deinit();
        self.tmp.cleanup();
    }

    pub fn paste(self: *AddressFixture, text: []const u8) void {
        main.update(&self.model, Msg.open_address, &self.fx);
        main.update(&self.model, Msg{ .address_edit = .{ .insert_text = text } }, &self.fx);
        main.update(&self.model, Msg.address_submit, &self.fx);
    }
};

test "an address opened over Settings leaves Settings so the result is seen" {
    // Cmd+L works over Settings, and the destination is drawn UNDER it. Press
    // Open and the dialog closed, Settings stayed up, and nothing visible
    // happened; the page only appeared after Close.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("oversettings");
    defer f.down();

    const who = [_]u8{0x3f} ** 32;
    main.update(&f.model, Msg.open_settings, &f.fx);
    try testing.expectEqual(main.Stage.settings, f.model.stage);
    f.paste(try nostr.nip19.encodeNpub(arena, who));

    try testing.expectEqual(main.Stage.ready, f.model.stage);
    try testing.expect(!f.model.address_open);
    try testing.expectEqual(@as(?[32]u8, who), f.model.viewing_profile);

    // A refusal is not a destination: the sheet stays up over Settings with
    // what was typed, and Settings stays put under it.
    main.update(&f.model, Msg.open_settings, &f.fx);
    f.paste("not an address");
    try testing.expectEqual(main.Stage.settings, f.model.stage);
    try testing.expect(f.model.address_open);
}

/// The app's own Zig files, for the tests that read the source rather than run
/// it. Listed by hand because `@embedFile` needs a literal path; the network
/// gate test fails when main.zig imports a file that is not on this list.
const AppSource = struct { name: []const u8, text: []const u8 };
pub const app_sources = [_]AppSource{
    .{ .name = "main.zig", .text = @embedFile("main.zig") },
    .{ .name = "theme.zig", .text = @embedFile("theme.zig") },
    .{ .name = "plaza_icons.zig", .text = @embedFile("plaza_icons.zig") },
    .{ .name = "search.zig", .text = @embedFile("search.zig") },
    .{ .name = "article.zig", .text = @embedFile("article.zig") },
    .{ .name = "blossom.zig", .text = @embedFile("blossom.zig") },
    .{ .name = "tuning.zig", .text = @embedFile("tuning.zig") },
    .{ .name = "hiding.zig", .text = @embedFile("hiding.zig") },
    .{ .name = "prefs.zig", .text = @embedFile("prefs.zig") },
    .{ .name = "updates.zig", .text = @embedFile("updates.zig") },
    .{ .name = "links.zig", .text = @embedFile("links.zig") },
    .{ .name = "login.zig", .text = @embedFile("login.zig") },
    .{ .name = "places.zig", .text = @embedFile("places.zig") },
    .{ .name = "relay_table.zig", .text = @embedFile("relay_table.zig") },
    .{ .name = "relay_list.zig", .text = @embedFile("relay_list.zig") },
    .{ .name = "routing.zig", .text = @embedFile("routing.zig") },
    .{ .name = "relay_conn.zig", .text = @embedFile("relay_conn.zig") },
    .{ .name = "store_glue.zig", .text = @embedFile("store_glue.zig") },
    .{ .name = "feed_state.zig", .text = @embedFile("feed_state.zig") },
    .{ .name = "thread_model.zig", .text = @embedFile("thread_model.zig") },
    .{ .name = "note_build.zig", .text = @embedFile("note_build.zig") },
    .{ .name = "profile_cache.zig", .text = @embedFile("profile_cache.zig") },
    .{ .name = "person_card.zig", .text = @embedFile("person_card.zig") },
    .{ .name = "quote_cache.zig", .text = @embedFile("quote_cache.zig") },
    .{ .name = "addresses.zig", .text = @embedFile("addresses.zig") },
    .{ .name = "link_preview.zig", .text = @embedFile("link_preview.zig") },
    .{ .name = "relay_hints.zig", .text = @embedFile("relay_hints.zig") },
    .{ .name = "engagement.zig", .text = @embedFile("engagement.zig") },
    .{ .name = "inbox.zig", .text = @embedFile("inbox.zig") },
    .{ .name = "image_cache.zig", .text = @embedFile("image_cache.zig") },
    .{ .name = "image_pool.zig", .text = @embedFile("image_pool.zig") },
    .{ .name = "feed_media.zig", .text = @embedFile("feed_media.zig") },
    .{ .name = "own_lists.zig", .text = @embedFile("own_lists.zig") },
    .{ .name = "follows.zig", .text = @embedFile("follows.zig") },
    .{ .name = "mutes.zig", .text = @embedFile("mutes.zig") },
    .{ .name = "bookmarks.zig", .text = @embedFile("bookmarks.zig") },
    .{ .name = "private_lists.zig", .text = @embedFile("private_lists.zig") },
    .{ .name = "keyholder.zig", .text = @embedFile("keyholder.zig") },
    .{ .name = "remote_signer.zig", .text = @embedFile("remote_signer.zig") },
    .{ .name = "drafts.zig", .text = @embedFile("drafts.zig") },
    .{ .name = "session.zig", .text = @embedFile("session.zig") },
    .{ .name = "own_profile.zig", .text = @embedFile("own_profile.zig") },
    .{ .name = "uploads.zig", .text = @embedFile("uploads.zig") },
    .{ .name = "media_servers.zig", .text = @embedFile("media_servers.zig") },
    .{ .name = "view_upload.zig", .text = @embedFile("view_upload.zig") },
    .{ .name = "compose.zig", .text = @embedFile("compose.zig") },
    .{ .name = "outbox.zig", .text = @embedFile("outbox.zig") },
    .{ .name = "people_search.zig", .text = @embedFile("people_search.zig") },
    .{ .name = "profile_notes.zig", .text = @embedFile("profile_notes.zig") },
    .{ .name = "navigation.zig", .text = @embedFile("navigation.zig") },
    .{ .name = "relay_auth.zig", .text = @embedFile("relay_auth.zig") },
    .{ .name = "ingest.zig", .text = @embedFile("ingest.zig") },
    .{ .name = "view_media.zig", .text = @embedFile("view_media.zig") },
    .{ .name = "view_note.zig", .text = @embedFile("view_note.zig") },
    .{ .name = "view_chrome.zig", .text = @embedFile("view_chrome.zig") },
    .{ .name = "view_place.zig", .text = @embedFile("view_place.zig") },
    .{ .name = "view_rail.zig", .text = @embedFile("view_rail.zig") },
    .{ .name = "view_feed.zig", .text = @embedFile("view_feed.zig") },
    .{ .name = "view_profile.zig", .text = @embedFile("view_profile.zig") },
    .{ .name = "view_article.zig", .text = @embedFile("view_article.zig") },
    .{ .name = "view_thread.zig", .text = @embedFile("view_thread.zig") },
    .{ .name = "view_compose.zig", .text = @embedFile("view_compose.zig") },
    .{ .name = "view_notifications.zig", .text = @embedFile("view_notifications.zig") },
    .{ .name = "view_search.zig", .text = @embedFile("view_search.zig") },
    .{ .name = "view_sheets.zig", .text = @embedFile("view_sheets.zig") },
    .{ .name = "view_settings.zig", .text = @embedFile("view_settings.zig") },
    .{ .name = "view_app.zig", .text = @embedFile("view_app.zig") },
};

test "no thread that dials a relay is spawned without a gate above it" {
    // The September segfault was a detached worker dialling real relays from a
    // unit test and writing into a store the test was tearing down. The fix
    // reached three fetchers. Five more had the same shape, and one of them was
    // not latent: driving `.place_feed` in this very file opened eight real
    // sockets a run, to nos.lol and offchain.pub among others.
    //
    // So this asserts the RULE rather than those five call sites. It reads the
    // source, finds every function that reaches `nostr.relay.dial`, finds every
    // place one of them is spawned, and requires a gate between the start of
    // the spawning function and the spawn itself. Add a network worker with no
    // gate and this fails by name, whether or not a test happens to reach it.
    // The scan below is only as good as its list of files.
    var lines = std.mem.splitScalar(u8, app_sources[0].text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "const ")) continue;
        const open = "= @import(\"";
        const at = std.mem.indexOf(u8, line, open) orelse continue;
        const rest = line[at + open.len ..];
        const file = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse continue];
        if (!std.mem.endsWith(u8, file, ".zig")) continue;
        for (app_sources) |s| {
            if (std.mem.eql(u8, s.name, file)) break;
        } else {
            std.debug.print("\n  main.zig imports {s}, which app_sources in tests.zig does not list.\n", .{file});
            return error.UnlistedSource;
        }
    }

    const alloc = testing.allocator;

    // Every file of the app, joined: a worker and the code that spawns it can
    // sit in different files, and both have to be seen.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (app_sources) |s| {
        try joined.append(alloc, '\n');
        try joined.appendSlice(alloc, s.text);
    }

    // `pub fn` folded into `fn` so one split finds both.
    const flat = try std.mem.replaceOwned(u8, alloc, joined.items, "\npub fn ", "\nfn ");
    defer alloc.free(flat);

    // Every function whose body reaches the network. Derived, not listed: a
    // list here would be the next thing to drift.
    var dialers: std.ArrayList([]const u8) = .empty;
    defer dialers.deinit(alloc);
    var fns = std.mem.splitSequence(u8, flat, "\nfn ");
    _ = fns.next();
    while (fns.next()) |chunk| {
        const paren = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const name = chunk[0..paren];
        if (std.mem.indexOfAny(u8, name, " \n\t") != null) continue;
        if (std.mem.indexOf(u8, chunk, "nostr.relay.dial") != null) {
            try dialers.append(alloc, name);
        }
    }
    try testing.expect(dialers.items.len > 0);

    for (dialers.items) |worker| {
        const needle = try std.fmt.allocPrint(alloc, "std.Thread.spawn(.{{}}, {s},", .{worker});
        defer alloc.free(needle);

        var from: usize = 0;
        while (std.mem.indexOfPos(u8, flat, from, needle)) |at| {
            from = at + needle.len;
            // The enclosing function: the last `\nfn ` before the spawn.
            const start = std.mem.lastIndexOf(u8, flat[0..at], "\nfn ") orelse 0;
            const body = flat[start..at];
            const gated = std.mem.indexOf(u8, body, "relayFetchAllowed()") != null or
                std.mem.indexOf(u8, body, "networkAllowed()") != null;
            if (!gated) {
                const fn_end = std.mem.indexOfScalar(u8, flat[start + 4 ..], '(') orelse 0;
                std.debug.print(
                    "\n  {s} reaches nostr.relay.dial and is spawned by {s} with no" ++
                        " relayFetchAllowed() or networkAllowed() above it.\n" ++
                        "  A unit test that reaches this opens a real socket.\n",
                    .{ worker, flat[start + 4 ..][0..fn_end] },
                );
                return error.UngatedNetworkThread;
            }
        }
    }
}

test "every glyph the rail asks for is a real glyph" {
    // `ui.icon` does not fail on a name nobody registered: `resolveOrMissing`
    // hands back a placeholder, so a typo or a glyph that left the toolkit
    // draws a box and every tree assertion still passes. The tile test below
    // finds the press and would not notice.
    //
    // Both tables, because the rail draws from both: `railTile` takes a BUILT-IN
    // by name through `ui.icon`, `railDest` takes one of Plaza's own through
    // `ui.appIcon`.
    main.registerIcons();
    const builtin_names = [_][]const u8{ "search", "edit", "settings", "play" };
    for (builtin_names) |name| {
        if (canvas.icons.find(name) == null) {
            std.debug.print("\n  the toolkit has no built-in glyph named \"{s}\"\n", .{name});
            return error.RailAsksForAMissingGlyph;
        }
    }
    const app_names = [_][]const u8{ "mark", "bell", "places" };
    for (app_names) |name| {
        if (canvas.icons.resolve(name) == null) {
            std.debug.print("\n  no registered app glyph named \"{s}\"\n", .{name});
            return error.RailAsksForAMissingGlyph;
        }
    }
}

// ------------------------------------------------------ noticing a new release

pub fn releaseDoc(arena: std.mem.Allocator, tag: []const u8, extra: []const u8) []const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"tag_name":"{s}","html_url":"https://github.com/zig-nostr/plaza/releases/tag/{s}","name":"Plaza {s}"{s}}}
    , .{ tag, tag, tag, extra }) catch unreachable;
}

// ------------------------------------------------------- a video is a video

// ---- NIP-22: a reply of either kind reaches me ------------------------------

// ---- NIP-36 content warnings --------------------------------------------------

pub fn warnedEvent(id_byte: u8, content: []const u8, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0x61} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = tags,
        .content = content,
        .sig = [_]u8{0} ** 64,
    };
}

// ---------------------------------------------------------------- NIP-42 AUTH
//
// A relay may ask who the reader is. These drive the whole exchange at the level
// the reader thread sees it: the messages a relay sends, a stand-in for the
// socket it answers on, and the real signer path in between. What they pin is
// the consent rule (ask once per relay, never for a guest, never after "no"),
// what is sent (a kind:22242 naming the dialed address and the challenge), and
// that a refusal is a finished subscription and not an answer.

pub const auth_test_url = "wss://auth.example.com";

pub fn closedMsg(sub: []const u8, reason: []const u8) nostr.message.RelayMessage {
    return .{ .closed = .{ .subscription_id = sub, .message = reason } };
}

/// What a gating relay does: it sends its challenge and then refuses the feed
/// for want of an answer. A challenge on its own asks nothing of the reader.
pub fn challengeAndRefuse(sess: *main.AuthSessionForTest, url: []const u8, challenge: []const u8, now_ms: i64) void {
    _ = main.authReactForTest(sess, url, authMsg(challenge), now_ms);
    _ = main.authReactForTest(sess, url, closedMsg("plaza-feed", "auth-required: log in first"), now_ms);
}

// ------------------------------------------------------------ long-form articles

/// A markdown body of `paragraphs` paragraphs, each its own distinctive line, with
/// a heading every tenth and a fenced block and a list in the middle.
pub fn longArticleBody(arena: std.mem.Allocator, paragraphs: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (0..paragraphs) |i| {
        if (i % 10 == 0) try out.print(arena, "## Section {d}\n\n", .{i / 10});
        try out.print(arena, "Paragraph number {d} says something about the subject at a length that wraps onto a second line when it is drawn in a reading column.\n\n", .{i});
        if (i == paragraphs / 2) {
            try out.appendSlice(arena, "```zig\nconst a = 1;\n\nconst b = 2;\n```\n\n");
            try out.appendSlice(arena, "1. first item\n\n2. second item\n\n3. third item\n\n");
        }
    }
    return out.items;
}

/// The blocks the toolkit's Markdown view makes of `source`, counted the plain
/// way: a run of non-blank lines after a blank one. Exact for text whose blocks
/// are set apart by blank lines, which is what the tests below hand it.
fn blocksIn(source: []const u8) usize {
    var n: usize = 0;
    var blank = true;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const empty = std.mem.trim(u8, line, " \t\r").len == 0;
        if (!empty and blank) n += 1;
        blank = empty;
    }
    return n;
}

/// The row whose bytes hold all of `needle`, if one does.
fn rowHolding(source: []const u8, rows: []const long_form.Chunk, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, source, needle) orelse return null;
    for (rows, 0..) |c, i| {
        if (at >= c.start and at + needle.len <= c.end) return i;
    }
    return null;
}

test "an article's tags are read the way the reader needs them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x61} ** 32);

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "a-slug" },
        &[_][]const u8{ "title", "  The title  " },
        &[_][]const u8{ "summary", "One line about it." },
        &[_][]const u8{ "image", "https://example.com/cover.jpg" },
        &[_][]const u8{ "published_at", "1700000000" },
        &[_][]const u8{ "t", "Zig" },
        &[_][]const u8{ "t", "zig" },
        &[_][]const u8{ "t", "nostr" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "body");
    const meta = long_form.metaOf(ev);
    try testing.expectEqualStrings("The title", meta.title);
    try testing.expectEqualStrings("One line about it.", meta.summary);
    try testing.expectEqualStrings("https://example.com/cover.jpg", meta.image);
    try testing.expectEqual(@as(i64, 1_700_000_000), meta.published_at);
    // Two spellings of one topic are one chip.
    try testing.expectEqual(@as(usize, 2), meta.tag_count);

    // An article cannot have been published after the event carrying it was made.
    const future = [_]nostr.event.Tag{&[_][]const u8{ "published_at", "1900000000" }};
    const late = long_form.metaOf(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &future, "body"));
    try testing.expectEqual(@as(i64, 1_800_000_000), late.published_at);
    const junk = [_]nostr.event.Tag{&[_][]const u8{ "published_at", "yesterday" }};
    const unparsed = long_form.metaOf(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &junk, "body"));
    try testing.expectEqual(@as(i64, 1_800_000_000), unparsed.published_at);

    try testing.expect(long_form.isWebUrl("https://example.com/a.png"));
    try testing.expect(!long_form.isWebUrl("javascript:alert(1)"));
    try testing.expect(!long_form.isWebUrl("https://exa mple.com/a.png"));
    try testing.expectEqual(@as(u32, 1), long_form.readingMinutes("a few words"));
    try testing.expectEqual(@as(u32, 2), long_form.readingMinutes("word " ** 226));
}

test "an article body is cut where cutting cannot change how it reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try longArticleBody(arena, 400);
    var chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const cut = long_form.chunk(body, &chunks);
    try testing.expect(!cut.truncated);
    // Many rows, not one: the list can only skip what is cut into pieces.
    try testing.expect(cut.len > 10);

    // In order, inside the body, and with no row a few kilobytes past the target
    // unless it holds something that must stay whole.
    var prev_end: u32 = 0;
    for (chunks[0..cut.len]) |c| {
        try testing.expect(c.start >= prev_end);
        try testing.expect(c.end > c.start);
        try testing.expect(c.end <= body.len);
        try testing.expect(c.height > 0);
        prev_end = c.end;
    }

    // The fenced block, blank line and all, is inside exactly one row.
    const fence_at = std.mem.indexOf(u8, body, "const a = 1;").?;
    for (chunks[0..cut.len]) |c| {
        if (fence_at >= c.start and fence_at < c.end) {
            try testing.expect(std.mem.indexOf(u8, body[c.start..c.end], "const b = 2;") != null);
            try testing.expect(std.mem.indexOf(u8, body[c.start..c.end], "```\n") != null);
        }
    }
    // A fenced block longer than a whole row, with a blank line deep inside it:
    // the blank line is code, not a paragraph break.
    var big = std.ArrayList(u8).empty;
    try big.appendSlice(arena, "Before.\n\n```\n");
    for (0..300) |_| try big.appendSlice(arena, "let x = 1;\n");
    try big.appendSlice(arena, "\nTAIL_OF_THE_BLOCK\n```\n\nAfter.\n");
    var big_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const big_cut = long_form.chunk(big.items, &big_chunks);
    const tail_at = std.mem.indexOf(u8, big.items, "TAIL_OF_THE_BLOCK").?;
    for (big_chunks[0..big_cut.len]) |c| {
        if (tail_at >= c.start and tail_at < c.end) {
            try testing.expect(std.mem.indexOf(u8, big.items[c.start..c.end], "let x = 1;") != null);
        }
    }

    // A list longer than a whole row, its items set apart by blank lines. The
    // toolkit draws 64 blocks of a row and drops the rest, and a blank line ends
    // a list there, so each item is a block: one row holding all eighty lost the
    // last sixteen and the line after them. Each item is cut whole, and keeps the
    // number its author wrote.
    var items = std.ArrayList(u8).empty;
    try items.appendSlice(arena, "Steps:\n\n");
    for (1..81) |n| try items.print(arena, "{d}. step number {d} is described here at some length\n\n", .{ n, n });
    try items.appendSlice(arena, "Done.\n");
    var item_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const item_cut = long_form.chunk(items.items, &item_chunks);
    for (item_chunks[0..item_cut.len]) |c| {
        try testing.expect(blocksIn(items.items[c.start..c.end]) <= long_form.max_row_weight);
    }
    for (1..81) |n| {
        const line = try std.fmt.allocPrint(arena, "{d}. step number {d} is described here at some length\n", .{ n, n });
        try testing.expect(rowHolding(items.items, item_chunks[0..item_cut.len], line) != null);
    }

    // Short paragraphs, the way a poem is set: two thousand bytes of them is a
    // hundred blocks. The byte target alone made that one row.
    var poem = std.ArrayList(u8).empty;
    for (0..300) |n| try poem.print(arena, "Verse {d} goes here\n\n", .{n});
    var poem_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const poem_cut = long_form.chunk(poem.items, &poem_chunks);
    for (poem_chunks[0..poem_cut.len]) |c| {
        try testing.expect(blocksIn(poem.items[c.start..c.end]) <= long_form.max_row_weight);
    }

    // Headings on consecutive lines are a block each with no blank line between
    // them, so the row ends before a block rather than only at a blank line.
    var heads = std.ArrayList(u8).empty;
    for (0..200) |n| try heads.print(arena, "## Heading {d}\n", .{n});
    var head_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const head_cut = long_form.chunk(heads.items, &head_chunks);
    try testing.expect(head_cut.len > 1);
    for (head_chunks[0..head_cut.len]) |c| {
        try testing.expect(std.mem.count(u8, heads.items[c.start..c.end], "## ") <= long_form.max_row_weight);
    }

    // `<details>` written as an example in prose is not a details block, the
    // toolkit's own test being a line that starts with it. Read as one, it was
    // never closed, and nothing after it could be cut.
    var prose = std.ArrayList(u8).empty;
    try prose.appendSlice(arena, "Wrap it in a `<details>` element to fold it.\n\n");
    try prose.appendSlice(arena, body);
    var prose_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const prose_cut = long_form.chunk(prose.items, &prose_chunks);
    try testing.expect(prose_cut.len > 10);

    // Whatever a row is in the middle of, it ends by `row_hard_bytes`: a fence
    // that never closes, a details block that never closes, one line that never
    // ends. A cut inside the fence says so, so the row can be drawn as code.
    const hostile = [_][]const u8{ "```\n", "<details>\n", "# " };
    for (hostile) |opening| {
        var wall = std.ArrayList(u8).empty;
        try wall.appendSlice(arena, opening);
        for (0..6000) |n| try wall.print(arena, "w{d} ", .{n});
        if (opening[0] != '#') {
            for (0..3000) |n| try wall.print(arena, "\nline {d}", .{n});
        }
        var wall_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
        const wall_cut = long_form.chunk(wall.items, &wall_chunks);
        try testing.expect(!wall_cut.truncated);
        try testing.expect(wall_cut.len > 3);
        var at: u32 = 0;
        for (wall_chunks[0..wall_cut.len], 0..) |c, i| {
            try testing.expectEqual(at, c.start);
            try testing.expect(c.end - c.start <= long_form.row_hard_bytes);
            try testing.expectEqual(i > 0 and opening[0] == '`', c.in_fence);
            at = c.end;
        }
        try testing.expectEqual(@as(u32, @intCast(wall.items.len)), at);
    }

    // A body past the cap is cut and says so, rather than silently running on.
    var few: [3]long_form.Chunk = undefined;
    const clipped = long_form.chunk(body, &few);
    try testing.expectEqual(@as(usize, 3), clipped.len);
    try testing.expect(clipped.truncated);
}

/// A store in a temp directory with `ev` ingested, and the app pointed at it.
pub fn articleStore(tmp: *std.testing.TmpDir, pbuf: []u8, name: []const u8) !nostr.store.Store {
    const db_path = try std.fmt.bufPrintZ(pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ tmp.sub_path, name });
    return nostr.store.Store.open(db_path, .{});
}

// ---- an naddr opens the article it names ---------------------------------------

// ------------------------------------------------------------------ relay hints
//
// What Plaza writes into the relay slot of the tags and addresses it publishes.
// The reading half (an `nevent1` that names relays gets them asked) has its own
// tests; these pin the writing half, where a wrong answer is worse than none.

pub const hint_a = "wss://relay.alpha.example";
pub const hint_b = "wss://relay.bravo.example";
pub const hint_c = "wss://relay.charlie.example";

/// Resets the delivered-by table around a test, because it is process-wide and
/// the suite shares one process.
pub fn freshHints() void {
    main.resetSeenOnForTest();
}

/// A kind:10002 for `kp`, writing to each of `urls`.
pub fn relayListFor(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, urls: []const []const u8) !nostr.event.Event {
    const tags = try arena.alloc(nostr.event.Tag, urls.len);
    for (urls, 0..) |u, i| {
        const t = try arena.alloc([]const u8, 3);
        t[0] = "r";
        t[1] = u;
        t[2] = "write";
        tags[i] = t;
    }
    return signedKind(arena, signer, kp, 1_800_000_000, 10002, tags, "");
}

test "every relay-fed note ingest remembers which relay it came from" {
    // The helper being right is half of it. A new fetch path that ingests with the
    // bare funnel quietly stops teaching the hint table, and nothing else fails:
    // notes from it just publish with an empty hint. The six left on the bare
    // funnel read profiles, places, relay lists and media server lists, which
    // are never hinted at.
    // An article fetched by its address is a note like any other and is counted
    // with the rest.
    var bare: usize = 0;
    var from: usize = 0;
    for (app_sources) |s| {
        var it = std.mem.splitScalar(u8, s.text, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "plazaIngest(gpa, e.event, .{ .verify_with = signer })") != null) bare += 1;
            if (std.mem.indexOf(u8, line, "plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, ") != null) from += 1;
        }
    }
    try testing.expectEqual(@as(usize, 6), bare);
    try testing.expectEqual(@as(usize, 11), from);
}

test "the three ways to hand out a note address all carry the hint" {
    freshHints();
    defer freshHints();
    var model = main.initialModel();
    oneNoteFeed(&model);
    main.recordSeenOnForTest(model.notes[0].event_id, hint_a);
    var fx: main.EffectsForTest = undefined;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Copy note address.
    main.update(&model, Msg{ .copy_nevent = model.notes[0].id }, &fx);
    {
        const ptr = try nostr.nip19.decodeNevent(arena, main.lastClipboardForTest());
        try testing.expectEqual(@as(usize, 1), ptr.relays.len);
        try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    }

    // Quote: the address is typed into the draft after `nostr:`.
    main.setIdentityForTest([_]u8{0x53} ** 32);
    defer main.clearIdentityForTest();
    main.update(&model, Msg{ .quote_note = model.notes[0].id }, &fx);
    {
        const text = model.draft_buffer.text();
        try testing.expect(std.mem.startsWith(u8, text, "nostr:nevent1"));
        const ptr = try nostr.nip19.decodeNevent(arena, text["nostr:".len..]);
        try testing.expectEqual(@as(usize, 1), ptr.relays.len);
        try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    }
}

// ---------------------------------------------------------- finding a person
//
// The field that opens an address finds people by name too. Two halves answer:
// every profile already on this machine, instantly and offline, then NIP-50
// search relays, folded in as they land and each marked with where it came from.
// These cover the matching and the ranking (`search.zig`), the field's decision
// about what a string is, and the hand-off from the relay threads to the list.

pub const search = main.search;

test "a term matches at the start, at a word, or anywhere, and says which" {
    try testing.expectEqual(search.Quality.exact, search.quality("jack", "JACK").?);
    try testing.expectEqual(search.Quality.prefix, search.quality("Jackson", "jack").?);
    try testing.expectEqual(search.Quality.word, search.quality("Black Jack", "jack").?);
    // The domain half of an address is a word of its own: `@` is a boundary.
    try testing.expectEqual(search.Quality.word, search.quality("bob@jack.example", "jack").?);
    try testing.expectEqual(search.Quality.within, search.quality("Hijack", "jack").?);
    try testing.expect(search.quality("Alice", "jack") == null);
    // The best occurrence wins, not the first.
    try testing.expectEqual(search.Quality.word, search.quality("Hijack jack", "jack").?);
}

test "the people who follow are listed before the people who are followed back before everyone" {
    const gpa = testing.allocator;
    var b = search.Builder.init(gpa);
    defer b.deinit();
    const pk = struct {
        fn of(n: u8) [32]u8 {
            return [_]u8{n} ** 32;
        }
    }.of;
    // Added newest-last on purpose, so order cannot come from insertion.
    try b.add(pk(1), .seen, 100, "Jackson", "", "");
    try b.add(pk(2), .seen, 100, "Hijack", "", "");
    try b.add(pk(3), .follows_me, 100, "Jack", "", "");
    try b.add(pk(4), .follows, 100, "Black Jack", "", "");
    try b.add(pk(5), .seen, 100, "Bob", "", "bob@jack.example");
    try b.add(pk(6), .seen, 100, "Nobody Relevant", "", "");
    var index = try b.finish();
    defer index.deinit(gpa);

    var hits: [8]search.Hit = undefined;
    const n = index.find("JACK", &hits);
    try testing.expectEqual(@as(usize, 5), n);
    const order = [_]u8{ 4, 3, 1, 5, 2 };
    for (order, 0..) |want, i| {
        try testing.expectEqual(want, index.entries[hits[i].entry].pubkey[0]);
    }

    // A short list keeps the best, not the first: the cap never costs the top.
    var two: [2]search.Hit = undefined;
    try testing.expectEqual(@as(usize, 2), index.find("jack", &two));
    try testing.expectEqual(@as(u8, 4), index.entries[two[0].entry].pubkey[0]);
    try testing.expectEqual(@as(u8, 3), index.entries[two[1].entry].pubkey[0]);
}

test "a term is cleaned the way it is sent" {
    var buf: [search.term_max]u8 = undefined;
    try testing.expectEqualStrings("Jack dorsey", search.cleanTerm(&buf, "  @Jack\n  dorsey  ").?);
    try testing.expect(search.cleanTerm(&buf, " \n\t ") == null);
    try testing.expect(search.cleanTerm(&buf, "@@") == null);
    // Cut at the cap, and never in the middle of a character.
    const long = "a" ** (search.term_max - 1) ++ "\u{00e9}";
    const cut = search.cleanTerm(&buf, long).?;
    try testing.expect(cut.len <= search.term_max);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "the search request is the NIP-50 shape and survives a hostile term" {
    const gpa = testing.allocator;
    const text = try search.requestText(gpa, "al\"ice\\ \u{00e9}\n");
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqualStrings("REQ", arr[0].string);
    try testing.expectEqualStrings(search.sub_id, arr[1].string);
    const filter = arr[2].object;
    try testing.expectEqualStrings("al\"ice\\ \u{00e9}\n", filter.get("search").?.string);
    try testing.expectEqual(@as(i64, 0), filter.get("kinds").?.array.items[0].integer);
    try testing.expectEqual(@as(i64, search.relay_limit), filter.get("limit").?.integer);
}

test "a search relay that asks for a login on connect is still read, and one that refuses is declined" {
    // The challenge alone ends nothing: the relay may well answer anyway.
    try testing.expect(search.settle(.auth, 0) == null);
    try testing.expect(search.settle(.event, 0) == null);
    try testing.expectEqual(search.RelayState.answered, search.settle(.eose, 0).?);
    try testing.expectEqual(search.RelayState.answered, search.settle(.eose, 4).?);
    // A CLOSED in place of results, `auth-required:` among them, is a refusal.
    try testing.expectEqual(search.RelayState.declined, search.settle(.closed, 0).?);
    try testing.expectEqual(search.RelayState.answered, search.settle(.closed, 2).?);
    try testing.expectEqual(search.RelayState.declined, search.settle(.notice, 0).?);
    try testing.expect(search.settle(.notice, 3) == null);
}

test "a relay's state and count travel as one word" {
    const s = search.Status{ .gen = 7, .state = .answered, .count = 12 };
    const back = search.Status.unpack(s.pack());
    try testing.expectEqual(@as(u32, 7), back.gen);
    try testing.expectEqual(search.RelayState.answered, back.state);
    try testing.expectEqual(@as(u16, 12), back.count);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("found no one", search.describe(&buf, .answered, 0));
    try testing.expectEqualStrings("1 person", search.describe(&buf, .answered, 1));
    try testing.expectEqualStrings("3 people", search.describe(&buf, .answered, 3));
    try testing.expectEqualStrings("could not connect", search.describe(&buf, .unreachable_, 0));
    try testing.expectEqualStrings("did not answer", search.describe(&buf, .silent, 0));
}

test "one field: the button says what Enter will do with what is in it" {
    var model = main.initialModel();
    model.stage = .ready;
    main.searchResetForTest();
    defer main.searchResetForTest();
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.open_address, &fx);

    main.update(&model, Msg{ .address_edit = .{ .insert_text = "alice" } }, &fx);
    try testing.expectEqualStrings("Search relays", model.address_action());
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "@example.com" } }, &fx);
    try testing.expectEqualStrings("Look up", model.address_action());

    var addr = main.initialModel();
    addr.stage = .ready;
    main.update(&addr, Msg.open_address, &fx);
    main.update(&addr, Msg{ .address_edit = .{ .insert_text = "npub1abc" } }, &fx);
    try testing.expectEqualStrings("Open", addr.address_action());
}

// ------------------------------------------------------------ picture upload

pub const blossom = @import("blossom.zig");

/// Waits for an upload job to reach `phase`, which is moved by a worker thread.
pub fn awaitUpload(phase: []const u8) !void {
    var waited: usize = 0;
    while (waited < 1000) : (waited += 1) {
        if (std.mem.eql(u8, main.uploadStateForTest(), phase)) return;
        // A job that has failed will not reach anything else.
        if (std.mem.eql(u8, main.uploadStateForTest(), "failed") and !std.mem.eql(u8, phase, "failed")) return error.UploadFailed;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    std.debug.print("\nupload stuck in {s}, wanted {s}\n", .{ main.uploadStateForTest(), phase });
    return error.UploadStuck;
}

/// A picture on disk for the file dialog to hand back.
pub fn writeTestPicture(name: []const u8, w: u32, h: u32, extra: []const u8) ![]const u8 {
    const png = try blossom.testPng(testing.allocator, w, h, extra);
    defer testing.allocator.free(png);
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = png });
    return path;
}

/// Puts `count` kind:1 notes by `author` into the store, newest first by
/// construction: note `i` is dated `newest - i`. With `reply`, each one answers
/// somebody, which is what makes the Notes tab count them as replies.
pub fn seedAuthorNotes(store: *nostr.store.Store, arena: std.mem.Allocator, author: [32]u8, count: usize, newest: i64, reply: bool) !void {
    for (0..count) |i| {
        var id = [_]u8{0} ** 32;
        std.mem.writeInt(u32, id[0..4], @intCast(i + 1), .big);
        id[31] = author[0];
        var parent_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&parent_hex, "{s}", .{"ab" ** 32}) catch unreachable;
        const tags: []const nostr.event.Tag = if (reply) &.{&.{ "e", &parent_hex, "", "reply" }} else &.{};
        const ev = nostr.event.Event{
            .id = id,
            .pubkey = author,
            .created_at = newest - @as(i64, @intCast(i)),
            .kind = 1,
            .tags = tags,
            .content = "a note",
            .sig = [_]u8{0} ** 64,
        };
        _ = try store.ingest(arena, ev, .{});
    }
}

// ---- settings, relays and signing in: the dead ends --------------------------

fn findKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findKind(child, kind)) |found| return found;
    }
    return null;
}

test "asking to log out brings the question into view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    model.stage = .settings;
    // The reader has scrolled to the foot of the page to find the button.
    main.update(&model, Msg{ .settings_scrolled = .{ .offset_y = 120, .viewport_extent_y = 500, .content_extent_y = 620 } }, &fx);
    try testing.expectEqual(@as(f32, 120), model.settings_scroll_y);

    main.update(&model, .logout_request, &fx);
    try testing.expect(model.logout_pending);
    try testing.expectEqual(main.settings_scroll_end, model.settings_scroll_y);
    // And the scroll view is told, which is what moves the page.
    const tree = try buildTree(arena, &model);
    const scroll = findKind(tree.root, .scroll_view) orelse return error.NoScroll;
    try testing.expectEqual(main.settings_scroll_end, scroll.value);

    // Reopening Settings starts at the top, not where the last visit asked for.
    main.update(&model, .close_settings, &fx);
    main.update(&model, .open_settings, &fx);
    try testing.expectEqual(@as(f32, 0), model.settings_scroll_y);
}

test "copying the npub says it was copied" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.recordingEffectsForTest(&fx, testing.allocator);
    defer fx.deinit();
    main.setIdentityForTest([_]u8{82} ** 32);
    defer main.clearIdentityForTest();
    main.update(&model, .copy_npub, &fx);
    try testing.expectEqualStrings("npub copied", model.toast_text());
}

test {
    _ = tests_addresses;
    _ = tests_bookmarks;
    _ = tests_compose;
    _ = tests_drafts;
    _ = tests_engagement;
    _ = tests_feed_media;
    _ = tests_feed_state;
    _ = tests_follows;
    _ = tests_hiding;
    _ = tests_image_cache;
    _ = tests_image_pool;
    _ = tests_inbox;
    _ = tests_ingest;
    _ = tests_keyholder;
    _ = tests_link_preview;
    _ = tests_links;
    _ = tests_login;
    _ = tests_media_servers;
    _ = tests_mutes;
    _ = tests_navigation;
    _ = tests_note_build;
    _ = tests_outbox;
    _ = tests_own_lists;
    _ = tests_own_profile;
    _ = tests_people_search;
    _ = tests_places;
    _ = tests_prefs;
    _ = tests_private_lists;
    _ = tests_profile_cache;
    _ = tests_profile_notes;
    _ = tests_quote_cache;
    _ = tests_relay_auth;
    _ = tests_relay_conn;
    _ = tests_relay_hints;
    _ = tests_relay_list;
    _ = tests_relay_table;
    _ = tests_remote_signer;
    _ = tests_routing;
    _ = tests_store_glue;
    _ = tests_thread_model;
    _ = tests_tuning;
    _ = tests_updates;
    _ = tests_uploads;
    _ = tests_view_article;
    _ = tests_view_chrome;
    _ = tests_view_compose;
    _ = tests_view_media;
    _ = tests_view_note;
}

// re-exports: tests/feed_media.zig
pub const quote_picture_url = tests_feed_media.quote_picture_url;

// re-exports: tests/inbox.zig
pub const inboxEventBy = tests_inbox.inboxEventBy;

// re-exports: tests/own_lists.zig
pub const ownRelayListIsThePool = tests_own_lists.ownRelayListIsThePool;

// re-exports: tests/relay_auth.zig
pub const authMsg = tests_relay_auth.authMsg;

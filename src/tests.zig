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
const tests_view_place = @import("tests/view_place.zig");
const tests_view_rail = @import("tests/view_rail.zig");
const tests_view_settings = @import("tests/view_settings.zig");
const tests_view_thread = @import("tests/view_thread.zig");
const tests_app = @import("tests/app.zig");

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

/// A thread root with nothing behind it but its id, for tests of the level
/// bookkeeping that never read a reply.
pub fn bareRoot(byte: u8) main.Note {
    var note = main.Note{ .id = @as(i64, byte) + 1000, .created_at = 1_800_000_000 };
    note.event_id = [_]u8{byte} ** 32;
    return note;
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

pub fn countPressesOf(tree: AppUi.Tree, widget: canvas.Widget, msg: Msg) usize {
    var n: usize = 0;
    if (tree.msgFor(widget.id, .press)) |m| {
        if (std.meta.eql(m, msg)) n += 1;
    }
    for (widget.children) |child| n += countPressesOf(tree, child, msg);
    return n;
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

// ---------------------------------------------------------- finding a person
//
// The field that opens an address finds people by name too. Two halves answer:
// every profile already on this machine, instantly and offline, then NIP-50
// search relays, folded in as they land and each marked with where it came from.
// These cover the matching and the ranking (`search.zig`), the field's decision
// about what a string is, and the hand-off from the relay threads to the list.

pub const search = main.search;

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

pub fn bookmarkFixture(
    arena: std.mem.Allocator,
    signer: *nostr.keys.Signer,
    store: *nostr.store.Store,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !nostr.keys.KeyPair {
    const secret = [_]u8{0x84} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    main.setIdentityForTest(secret);
    main.setStoreForTest(store);
    const ev = try nostr.event.create(arena, signer.*, kp, 1_800_000_000, 10003, tags, content, null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer.*);
    main.loadBookmarksFromStoreForTest();
    return kp;
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
    _ = tests_view_place;
    _ = tests_view_rail;
    _ = tests_view_settings;
    _ = tests_view_thread;
    _ = tests_app;
}

// re-exports: tests/feed_media.zig
pub const quote_picture_url = tests_feed_media.quote_picture_url;

// re-exports: tests/inbox.zig
pub const inboxEventBy = tests_inbox.inboxEventBy;

// re-exports: tests/own_lists.zig
pub const ownRelayListIsThePool = tests_own_lists.ownRelayListIsThePool;

// re-exports: tests/relay_auth.zig
pub const authMsg = tests_relay_auth.authMsg;

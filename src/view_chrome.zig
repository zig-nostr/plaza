//! Menus, popovers, banners and the status chips around the content.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");
const relay_conn = @import("relay_conn.zig");
const remote_signer = @import("remote_signer.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const npubShortOf = main.npubShortOf;
const AppUi = main.AppUi;
const Conn = main.Conn;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const OutboxEntry = main.OutboxEntry;
const RelayEntry = main.RelayEntry;
const activePlace = main.activePlace;
const activePubkey = main.activePubkey;
const authAskingSummary = main.authAskingSummary;
const bookmarkBlockedReason = main.bookmarkBlockedReason;
const bookmarkCount = main.bookmarkCount;
const chrome_inset = main.chrome_inset;
const connHolds = main.connHolds;
const followBlockedReason = main.followBlockedReason;
const helperState = main.helperState;
const hgap = main.hgap;
const isBookmarked = main.isBookmarked;
const isFollowedByMe = main.isFollowedByMe;
const keyholderMissing = main.keyholderMissing;
const liveRelayCount = main.liveRelayCount;
const lookupProfile = main.lookupProfile;
const menu_scale = main.menu_scale;
const meta_scale = main.meta_scale;
const mono_badge_scale = main.mono_badge_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const openNotaryAvailable = main.openNotaryAvailable;
const outboxSnapshot = main.outboxSnapshot;
const outbox_cap = main.outbox_cap;
const ownListsRead = main.ownListsRead;
const pendingUpdateVersion = main.pendingUpdateVersion;
const plaza_version = main.plaza_version;
const pressRow = main.pressRow;
const relayAt = main.relayAt;
const relayCount = main.relayCount;
const relayRttMs = main.relayRttMs;
const relayShortName = main.relayShortName;
const relaySlots = main.relaySlots;
const shareHost = main.shareHost;
const status_scale = main.status_scale;
const vgap = main.vgap;
const writeRelayCount = main.writeRelayCount;
const youAvatar = main.youAvatar;

/// The web gateway a note is shared through: the community's when the place you
/// are reading in names one, and njump otherwise.
///
/// njump is not a fallback here so much as the app's own answer, and a place
/// that states nothing is not asking for a different one.
pub fn shareBase() []const u8 {
    const m = activePlace() orelse return default_share_base;
    if (m.share_len == 0) return default_share_base;
    return m.share();
}

const default_share_base = "https://njump.me/";

/// What a note offers beyond its verbs: where it is, what it says, and what to
/// do about whoever wrote it. Reached by right-clicking anywhere on the row.
///
/// This is the only list. There used to be a second one behind an ellipsis in
/// the verb row, carrying the same actions, which meant two lists to keep in
/// step and a reader finding different things depending on which way they
/// reached. The runtime presents these as the platform's own menu where there is
/// one, and as an anchored surface where there is not.
/// Every row this menu can carry, so the count is stated once instead of being
/// the sum of the branches below.
///
/// It was 7, and eight rows could be written. In the feed (`in_thread` false)
/// inside a place declaring a handler for kind 1, the tally runs: open thread,
/// copy address, quote, copy text, open on the web, open in the handler,
/// separator, follow. The eighth landed at index 7 of a seven-element
/// allocation and the function then returned `items[0..8]` from it.
///
/// One row was bounds-checked, the handler row, and the two written after it
/// were not, so the guard sat directly above the overrun it did not prevent.
/// That is the actual lesson and it is why `push` below exists: a rule applied
/// at one call site is not a rule. Debug catches this as a panic; ReleaseFast,
/// which is what ships, has no bounds check and writes past the allocation.
const note_context_capacity = 10;

pub fn noteContextItems(ui: *AppUi, note: *const Note, in_thread: bool) []const AppUi.ContextMenuItem {
    const items = ui.arena.alloc(AppUi.ContextMenuItem, note_context_capacity) catch return &.{};
    var n: usize = 0;
    // The only way a row is written. Adding one is adding a `push`, and a row
    // too many is a row dropped rather than memory scribbled on.
    const push = struct {
        fn f(dst: []AppUi.ContextMenuItem, at: *usize, item: AppUi.ContextMenuItem) void {
            if (at.* >= dst.len) return;
            dst[at.*] = item;
            at.* += 1;
        }
    }.f;

    if (!in_thread) push(items, &n, .{ .label = "Open thread", .msg = Msg{ .open_thread = note.id } });
    push(items, &n, .{ .label = "Copy note address", .msg = Msg{ .copy_nevent = note.id } });
    push(items, &n, .{ .label = "Quote", .msg = Msg{ .quote_note = note.id } });
    push(items, &n, .{ .label = "Copy text", .msg = Msg{ .copy_note_text = note.id } });
    push(items, &n, .{ .label = ui.fmt("Open on {s}", .{shareHost(shareBase())}), .msg = Msg{ .open_web = note.id } });
    // And where THIS community reads its notes, when it says. Beside the app's
    // own row rather than instead of it: a place naming a handler is telling
    // the reader where it lives, not taking njump away from them.
    if (activePlace()) |place| {
        if (place.handlerFor(1)) |h| {
            push(items, &n, .{ .label = ui.fmt("Open in {s}", .{h.name()}), .msg = Msg{ .open_place_handler = note.id } });
        }
    }
    push(items, &n, .{ .separator = true });
    push(items, &n, bookmarkContextItem(note));
    push(items, &n, privateBookmarkContextItem(note));
    if (isMine(note.pubkey)) {
        push(items, &n, .{ .label = "Delete", .msg = Msg{ .delete_note_request = note.id } });
    }
    push(items, &n, followContextItem(note.pubkey));
    return items[0..n];
}

/// The bookmark row, in whatever state it is honestly in.
///
/// Disabled with the reason on it rather than silently dead, the way Follow is.
/// A reader whose own list has not arrived yet is looking at a button this app
/// must not press, and saying so is the point: pressing it would publish a list
/// of one note over everything they had saved.
fn bookmarkContextItem(note: *const Note) AppUi.ContextMenuItem {
    if (activePubkey() == null) return .{ .label = "Bookmark", .enabled = false };
    if (bookmarkBlockedReason()) |reason| return blockedListItem(reason);
    if (isBookmarked(note.event_id)) {
        return .{ .label = "Remove bookmark", .msg = Msg{ .toggle_bookmark = note.id } };
    }
    return .{ .label = "Bookmark", .msg = Msg{ .toggle_bookmark = note.id } };
}

/// The private-bookmark row.
///
/// Only offered for ADDING. Removing one is the same press as removing a public
/// one: `toggle_bookmark` looks at where the entry actually is, so a reader is
/// never asked to remember which half they put it in.
///
/// Absent once the note is already bookmarked either way, because "bookmark
/// privately" on something already saved is a question about moving it between
/// halves, and that is a different feature.
fn privateBookmarkContextItem(note: *const Note) AppUi.ContextMenuItem {
    if (activePubkey() == null) return .{ .label = "Bookmark privately", .enabled = false };
    if (bookmarkBlockedReason() != null) return .{ .label = "Bookmark privately", .enabled = false };
    if (isBookmarked(note.event_id)) return .{ .label = "Bookmark privately", .enabled = false };
    return .{ .label = "Bookmark privately", .msg = Msg{ .bookmark_privately = note.id } };
}

/// Whether this account wrote it. Absent rather than disabled is the right
/// treatment for Delete on somebody else's note: a greyed row offers a thing
/// that is not on offer, where a greyed Follow explains a state the reader is
/// actually in.
fn isMine(author: [32]u8) bool {
    const me = activePubkey() orelse return false;
    return std.mem.eql(u8, &me, &author);
}

/// A menu row for a list that cannot be written yet. While Plaza is still
/// reading it is a statement; once the wait ran out the same row is the way to
/// ask the relays again, so the reader is never left with a dead row.
fn blockedListItem(reason: []const u8) AppUi.ContextMenuItem {
    if (ownListsRead() == .incomplete) return .{ .label = reason, .msg = Msg.retry_own_lists };
    return .{ .label = reason, .enabled = false };
}

/// The follow entry for a right-click, in whatever state it is honestly in.
///
/// Disabled rather than absent where it cannot act, so the reason is visible
/// instead of the action silently missing. Not "Follow", greyed: the app is
/// still looking for a list it must not write over, and saying so is the point.
/// A silently dead Follow is what every client that got this safety right got
/// wrong.
fn followContextItem(author: [32]u8) AppUi.ContextMenuItem {
    const me = activePubkey();
    if (me) |pk| {
        if (std.mem.eql(u8, &pk, &author)) return .{ .label = "This is you", .enabled = false };
    } else return .{ .label = "Follow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 0 } } };
    if (followBlockedReason()) |reason| return blockedListItem(reason);
    if (isFollowedByMe(author)) return .{ .label = "Unfollow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 2 } } };
    return .{ .label = "Follow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 1 } } };
}

/// A rule between groups of menu items.
fn menuSeparatorRow(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 4),
        ui.el(.panel, .{ .height = 1, .padding = 0.01, .style = .{ .background = p.divider_card, .radius = 0, .stroke_width = 0 } }, .{}),
        vgap(ui, 4),
    });
}

/// The chrome's floating surface: a menu anchored to the trigger it hangs off.
///
/// Anchoring makes the surface leave its parent's flow entirely: it takes no
/// space in the row, paints in a late window-level pass above everything, and
/// escapes every ancestor clip, which is what lets a 30px status bar open a
/// 340px panel. It opens ABOVE, since the bar sits on the floor of the window,
/// and the runtime flips it if there is no room.
///
/// `on_dismiss` is what makes Escape and a press outside close it, so the model
/// never needs to hear about the click that landed elsewhere.
fn menuSurface(ui: *AppUi, width: f32, children: []const AppUi.Node) AppUi.Node {
    // A status-bar menu hangs off the right end of its chip, above the bar.
    return menuSurfacePlaced(ui, width, .above, .end, children);
}

/// The same surface with its placement stated, for a trigger that is not on the
/// floor of the window.
pub fn menuSurfacePlaced(ui: *AppUi, width: f32, placement: canvas.WidgetAnchorPlacement, alignment: canvas.WidgetAnchorAlignment, children: []const AppUi.Node) AppUi.Node {
    return menuSurfacePlacedDismissing(ui, width, placement, alignment, Msg.close_menu, children);
}

/// The same surface, told what to send when the reader clicks away. A menu whose
/// dismiss clears somebody else's state stays open and flickers back.
pub fn menuSurfacePlacedDismissing(ui: *AppUi, width: f32, placement: canvas.WidgetAnchorPlacement, alignment: canvas.WidgetAnchorAlignment, dismiss: Msg, children: []const AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dropdown_menu, .{
        .width = width,
        .anchor = placement,
        .anchor_alignment = alignment,
        .anchor_offset = 6,
        .padding = 5,
        .on_dismiss = dismiss,
        .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 9, .stroke_width = 1 },
    }, .{
        ui.column(.{ .gap = 0 }, .{children}),
    });
}

/// One row in a chrome menu: a label, an optional glyph and an optional trailing
/// hint, at the redesign's 6 by 9 padding.
pub fn menuRow(ui: *AppUi, label: []const u8, glyph: ?[]const u8, hint: ?[]const u8, press: ?Msg) AppUi.Node {
    const p = theme.palette;
    // A plain row, deliberately: the `menu_item` kind is what the renderer would
    // wash on hover, but it lays its children out and then draws none of them
    // (the rows measured 330x32 and painted nothing at all). So a menu row has
    // no hover state until that is understood; the design specifies a SELECTED
    // row surface, which is a different state and is drawn.
    return pressRow(ui, .{
        .cross = .center,
        .gap = 0,
        .on_press = press,
        // Some rows in this menu are statements, not choices: "This is you", and
        // the line explaining why following is not offered yet. Those carry no
        // press, so they are not buttons and must not say they are.
        .semantics = .{
            .role = if (press != null) .button else .none,
            .label = label,
            .focusable = press != null,
        },
    }, .{
        hgap(ui, 9),
        vgap(ui, 25),
        if (glyph) |name| ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_secondary } }, name) else ui.spacer(0),
        if (glyph != null) hgap(ui, 9) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = p.text_body } }, &.{.{ .text = label, .scale = menu_scale }}),
        ui.spacer(1),
        if (hint) |text|
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = text, .monospace = true, .scale = mono_hint_scale }})
        else
            ui.spacer(0),
        hgap(ui, 9),
    });
}

/// A rule between groups of menu rows.
fn menuSeparator(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 4),
        ui.row(.{ .gap = 0 }, .{ hgap(ui, 7), ui.separator(.{ .grow = 1, .style = .{ .foreground = p.border_menu, .background = p.border_menu } }), hgap(ui, 7) }),
        vgap(ui, 4),
    });
}

/// The relay popover: every relay in the pool, what it is doing, and how fast it
/// answers, then the two things a reader can do about it.
fn relayPopover(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const slots = relaySlots();
    const rows = ui.arena.alloc(AppUi.Node, slots + 4) catch return ui.spacer(0);
    // The header says what the list means, so nobody reads it as a picker.
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 24),
        ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Relays", .weight = .medium, .scale = menu_scale }}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "reads & writes route automatically", .monospace = true, .scale = mono_meta_scale }}),
        ui.spacer(1),
        hgap(ui, 9),
    });
    // Compacted, NEVER indexed by slot: a dormant slot in the middle would
    // otherwise leave a row nobody wrote, and the arena hands out uninitialised
    // memory that the widget walker would then follow.
    var n: usize = 1;
    for (0..slots) |i| {
        const entry = relayAt(i) orelse continue;
        // Every relay the reader has, marked with what it is for. Hiding the
        // read-only ones would make this list disagree with both the chip
        // counting them and the Settings card listing them.
        rows[n] = relayRow(ui, entry.url(), i, relayBadgeText(entry), model);
        n += 1;
    }
    rows[n] = menuSeparator(ui);
    rows[n + 1] = menuRow(ui, if (model.relays_paused) "Resume Relays" else "Pause Relays", null, null, .toggle_relays_paused);
    rows[n + 2] = menuRow(ui, "Relay Settings…", null, "Cmd+,", .open_settings);
    return menuSurface(ui, 340, rows[0 .. n + 3]);
}

/// One relay in the popover: its state as a dot, its host, what it is for, and
/// how long it took to answer.
fn relayRow(ui: *AppUi, url: []const u8, index: usize, badge: []const u8, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const state: Conn = @enumFromInt(relay_conn.g_relay_status[index].load(.monotonic));
    // A relay leaves within a wake, so during a pause some rows are still
    // genuinely connected. Each row reports ITSELF: claiming the whole list is
    // paused while notes are still arriving on it is the dishonesty this is for.
    // Holding a socket, whichever way. The row still reads as a working relay
    // (its round trip is real, its badge means something), and only the dot and
    // the word say that the last evidence of life is a minute old.
    const connected = connHolds(state);
    const paused = model.relays_paused and !connected;
    const dot = if (paused)
        p.text_faint_alt
    else if (state == .connected)
        p.status_success
    else if (state == .connecting or state == .quiet)
        p.status_warning
    else
        p.status_offline;
    // The host alone: the scheme is the same on every row and carries no news.
    const host = if (std.mem.startsWith(u8, url, "wss://")) url["wss://".len..] else url;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 21),
        ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = dot, .radius = 3, .stroke_width = 0 } }, .{}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = if (connected) p.text_body else p.text_muted_alt } }, &.{.{ .text = host, .monospace = true, .scale = mono_row_scale }}),
        ui.spacer(1),
        // What the relay is for is true whether or not it is answering, so the
        // badge stays put when it drops. A row that loses its marker while
        // offline would read as a relay whose purpose changed.
        relayBadge(ui, badge),
        hgap(ui, 8),
        // A connected relay reports its round trip; one that is still dialling or
        // has dropped says so in words instead of showing a stale number.
        ui.paragraph(
            .{ .style = .{ .foreground = if (connected) p.text_muted_alt else p.status_warning_text } },
            &.{.{
                .text = if (paused)
                    "paused"
                else if (state == .quiet)
                    "quiet"
                else if (connected)
                    (if (relayRttMs(index)) |ms| ui.fmt("{d}ms", .{ms}) else "…")
                else if (state == .connecting)
                    "connecting"
                else
                    "offline",
                .monospace = true,
                .scale = mono_meta_scale,
            }},
        ),
        hgap(ui, 9),
    });
}

/// What a relay is for, in NIP-65's own two letters.
pub fn relayBadgeText(e: *const RelayEntry) []const u8 {
    if (e.read and e.write) return "R·W";
    if (e.read) return "R";
    if (e.write) return "W";
    // A relay that is neither is not reachable in the UI (the badge cycles
    // through three live states), but a list read from disk or from a
    // kind:10002 with an unknown marker can land here. Saying so beats
    // claiming a direction it does not have.
    return "off";
}

/// The R·W chip on a relay row: what the relay is used for.
fn relayBadge(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_menu, .border = p.border_dashed, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = text, .monospace = true, .scale = mono_badge_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// The signed-in account's display name, or its npub until a kind:0 arrives.
pub fn accountName() []const u8 {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| {
            if (profile.name_len > 0) return profile.name();
        }
    }
    return npubShort();
}

/// Whether a kind:0 name is known, so the npub is worth showing beneath it.
pub fn accountHasName() bool {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| return profile.name_len > 0;
    }
    return false;
}

pub fn npubShort() []const u8 {
    return keyholder.g_identity_npub_buf[0..keyholder.g_identity_npub_len];
}

/// The account menu: who you are, and the two things to do about it. No mock
/// draws this, so it is the menu recipe with the identity row on top; flagged in
/// the PR for review.
fn accountMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    // Both conditions are read ONCE, here, and the allocation is counted from
    // the same two booleans that gate the writes below.
    //
    // Written as a bare number this was correct three times and wrong once. It
    // was 5, shrank to 5-1 when a row was removed (right, at the time), and then
    // "Bookmarks" was added back without it moving, so the ordinary signed-in
    // menu wrote "Settings..." one node past the end of its own allocation. In
    // Debug that is a panic; the shipping build is ReleaseFast and has no bounds
    // check, so it was a silent write into the arena.
    //
    // A count that is a separate number from the writes it bounds only agrees
    // with them by coincidence. This one cannot drift: another conditional row
    // means another boolean and another term, in the same expression.
    const show_notary = openNotaryAvailable();
    const show_bookmarks = activePubkey() != null;
    const show_profile_address = activePubkey() != null;
    const row_count: usize = 4 + @as(usize, @intFromBool(show_notary)) + @as(usize, @intFromBool(show_bookmarks)) +
        @as(usize, @intFromBool(show_profile_address));
    const rows = ui.arena.alloc(AppUi.Node, row_count) catch return ui.spacer(0);
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 34),
        youAvatar(ui),
        hgap(ui, 9),
        ui.column(.{ .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = accountName(), .weight = .medium, .scale = menu_scale }}),
            // The npub only when it is not already the name above it: an account
            // with no kind:0 yet would otherwise read its own key twice.
            if (accountHasName())
                ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = npubShort(), .monospace = true, .scale = mono_meta_scale }})
            else
                ui.spacer(0),
        }),
        ui.spacer(1),
        hgap(ui, 9),
    });
    rows[1] = menuSeparator(ui);
    var n: usize = 2;
    // The chip this menu hangs off says "Notary ready", so the way to Notary
    // belongs here as well as in Settings: this is where a reader looks when
    // they are wondering about their signer, because it is the thing that just
    // told them about it.
    if (show_notary) {
        rows[n] = menuRow(ui, "Open Notary", null, null, .open_notary_window);
        n += 1;
    }
    // Where a bookmark can be found again, which is the half of the feature that
    // makes the other half worth having. Signed-in only: a guest cannot have a
    // list, and a row that opens an empty screen is a worse answer than no row.
    if (show_bookmarks) {
        rows[n] = menuRow(ui, ui.fmt("Bookmarks ({d})", .{bookmarkCount()}), null, null, .open_bookmarks);
        n += 1;
    }
    // The account's address with the relays it publishes to in it. Signed-in
    // only: a guest has no account to address. Settings keeps the bare npub.
    if (show_profile_address) {
        rows[n] = menuRow(ui, "Copy profile address", null, null, .copy_nprofile);
        n += 1;
    }
    // No glyph. "Open Notary" carries none either, and one icon among two reads
    // as a mistake rather than as emphasis.
    //
    // No "Sign out" here. It only ever opened Settings with the confirmation
    // showing, so it was a second door to a room this menu already has a door
    // to, and the one thing on a status menu that could end a session is a
    // strange thing to keep a press away from the relay count.
    // Guests too, deliberately. Opening an address is reading, and reading
    // needs no key: a link somebody sent is one of the first things a person
    // who has not signed in arrives with.
    rows[n] = menuRow(ui, "Search…", null, "Cmd+L", .open_address);
    n += 1;
    rows[n] = menuRow(ui, "Settings…", null, "Cmd+,", .open_settings);
    n += 1;
    return menuSurface(ui, 240, rows[0..n]);
}

/// The banner 11p draws when no relay is answering. It says what still works,
/// which is nearly everything: the store is the app, so reading continues, and a
/// note written now is queued rather than refused. A spinner would say the
/// opposite.
pub fn offlineBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (liveRelayCount() > 0) return ui.spacer(0);
    const queued = model.outbox_pending;
    // A pause is the reader's own doing, so it is not worded or coloured as a
    // fault, and it carries the way out.
    if (model.relays_paused) return pausedBanner(ui, queued);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_offline, .border = p.border_offline, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.status_warning } }, "alert"),
                            hgap(ui, 8),
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.status_warning_text } },
                                &.{.{ .text = offlineBannerText(ui, queued, relayCount() == 0), .scale = meta_scale }},
                            ),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The line saying a newer Plaza exists.
///
/// TOLD, not done: it names the version and gives one press to the release
/// page, where the notes and the downloads are. It does not download anything
/// and it does not replace the app, because an ad-hoc signed bundle installed
/// by a script is not something to swap out from under somebody.
///
/// The offline banner's shape, one tone quieter. That banner is about something
/// broken right now; this is news, and it can wait. It is also the only one of
/// the three strips a reader can put away.
pub fn updateBanner(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const version = pendingUpdateVersion();
    if (version.len == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{ .text = ui.fmt("Plaza {s} is out. You are on {s}.", .{ version, plaza_version }), .scale = meta_scale }},
                            ),
                            hgap(ui, 8),
                            // The verb, and it says where it goes rather than
                            // "Update": nothing here updates anything.
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.open_update,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "See what is new", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "See what is new", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.dismiss_update,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "Dismiss the update notice", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_muted } },
                                    &.{.{ .text = "Not now", .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The line asking whether a relay may know who the reader is.
///
/// Shown only for a relay that has refused something for want of AUTH, once per
/// relay: the answer is kept, so it does not come back on the next launch or the
/// next reconnect, and it can be changed from the relay's row. A relay that
/// sends a challenge and gates nothing never raises it. It blocks nothing. The feed on every other relay carries on while it stands, and
/// so does this relay's own socket; the subscriptions it refused wait for the
/// answer.
///
/// The update banner's shape, because that is the register this app already
/// uses for something worth saying that is not broken: a quiet panel, plain
/// words, and the two verbs as underlined text rather than as buttons.
pub fn relayAuthBanner(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const asking = authAskingSummary() orelse return ui.spacer(0);
    const index = asking.first;
    const e = relayAt(index) orelse return ui.spacer(0);
    const name = relayShortName(e.url());
    const more = asking.count - 1;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{
                                    .text = if (more == 0)
                                        ui.fmt("{s} asks you to identify yourself to it.", .{name})
                                    else if (more == 1)
                                        ui.fmt("{s} asks you to identify yourself to it. 1 more is waiting.", .{name})
                                    else
                                        ui.fmt("{s} asks you to identify yourself to it. {d} more are waiting.", .{ name, more }),
                                    .scale = meta_scale,
                                }},
                            ),
                            hgap(ui, 8),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg{ .auth_allow = @intCast(index) },
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = ui.fmt("Let {s} know who you are", .{name}), .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "Allow", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg{ .auth_deny = @intCast(index) },
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = ui.fmt("Do not identify yourself to {s}", .{name}), .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_muted } },
                                    &.{.{ .text = "Don't allow", .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The strip shown while the reader has paused the relays. The update notice's
/// quieter tone, because nothing is broken, and one press to undo it.
fn pausedBanner(ui: *AppUi, queued: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{ .text = pausedBannerText(ui, queued), .scale = meta_scale }},
                            ),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.toggle_relays_paused,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "Resume relays", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "Resume", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

pub fn pausedBannerText(ui: *AppUi, queued: usize) []const u8 {
    if (queued == 0) return "Relays are paused. Reading continues from this machine, and anything you write is kept until you resume.";
    return ui.fmt("Relays are paused. Reading continues from this machine, and {d} {s} waiting to go out until you resume.", .{ queued, if (queued == 1) "note is" else "notes are" });
}
/// What the banner says, which depends on whether anything is owed, and on
/// whether the pool is empty: "no relay is answering" is wrong about a list
/// with nobody in it, and sends the reader looking for a fault.
pub fn offlineBannerText(ui: *AppUi, queued: usize, none_set: bool) []const u8 {
    if (none_set) return "No relays are set up, so nothing can be fetched or sent. Add one in Settings.";
    if (queued == 0) return "No relay is answering. Reading continues from this machine; anything you write is kept until one does.";
    return ui.fmt("No relay is answering. Reading continues from this machine, and {d} {s} waiting to go out.", .{ queued, if (queued == 1) "note is" else "notes are" });
}
/// What the app still owes the reader. Absent when nothing is queued, which is
/// most of the time: a zone that is always there teaches nothing, and an empty
/// popover under it would be worse.
///
/// Amber, because this is work in progress rather than a warning: a note on its
/// way is the ordinary case. The glyph takes the text's own hex, not the
/// brighter alert amber.
pub fn outboxZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (model.outbox_pending == 0 and model.outbox_stuck == 0 and !model.outbox_overflowed) return ui.spacer(0);
    const stuck = model.outbox_overflowed or (model.outbox_pending == 0 and model.outbox_stuck > 0);
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = 22,
            .cross = .center,
            .on_press = Msg{ .toggle_menu = .outbox },
            .style = .{ .radius = 6, .background = if (model.menu == .outbox) p.surface_chip else null },
            .semantics = .{ .role = .button, .label = "Notes on their way", .focusable = true },
        }, .{
            hgap(ui, 7),
            // A runtime choice of glyph, so `appIcon` rather than the
            // comptime-checked `icon`.
            ui.appIcon(.{ .width = 11, .height = 11, .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } }, if (stuck) "alert" else "arrow-up"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } },
                &.{.{ .text = model.outbox_label(ui.arena), .scale = status_scale }},
            ),
            hgap(ui, 7),
        }),
        if (model.menu == .outbox) outboxMenu(ui) else ui.spacer(0),
        hgap(ui, 4),
    });
}

/// One card per note on its way, newest first. No mock exists for this surface;
/// it is the smallest thing that answers the question the zone raises, which is
/// "which note, and how far did it get".
fn outboxMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    var entries: [outbox_cap]OutboxEntry = undefined;
    const n = outboxSnapshot(&entries);
    if (n == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, n) catch return ui.spacer(0);
    for (rows, entries[0..n]) |*row, e| {
        const title = switch (e.state()) {
            .queued => "Waiting for a relay",
            .sending => "Sending",
            .sent => "Sent",
            .stuck => "No relay took it",
        };
        row.* = ui.column(.{ .gap = 0 }, .{
            vgap(ui, 6),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 9),
                ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{
                    .background = switch (e.state()) {
                        .queued => p.status_offline,
                        .sending => p.status_warning_text,
                        .sent => p.status_success,
                        .stuck => p.status_offline,
                    },
                    .radius = 3,
                    .stroke_width = 0,
                } }, .{}),
                hgap(ui, 8),
                ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = title, .weight = .medium, .scale = menu_scale }}),
                ui.spacer(1),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = ui.fmt("{d}/{d} relays", .{ e.ackCount(), writeRelayCount() }), .monospace = true, .scale = mono_hint_scale }},
                ),
                hgap(ui, 9),
            }),
            vgap(ui, 6),
        });
    }
    return menuSurface(ui, 240, rows);
}

/// The relay zone: the pool's health, and the popover that explains it. The chip
/// is highlighted while the pool is healthy, because that is when the number is
/// worth reading at a glance; a degraded pool speaks through its dot instead.
pub fn relayZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const paused = model.relays_paused;
    // Both halves of the ratio come from the SAME sample. `model.live_relays`
    // and `model.relay_count` are read together once a second in `refresh`;
    // pairing that numerator with a live `relayCount()` reads "5/3 relays" for a
    // second after a removal, because the count drops the instant they press and
    // the live tally waits for the next tick.
    const total = model.relay_count;
    const live = @min(model.live_relays, total);
    // A paused pool that still has a socket open is PAUSING, not paused: a relay
    // leaves at its next message, and the bar refuses to claim otherwise.
    const settling = paused and live > 0;
    const dot = if (paused)
        p.text_faint_alt
    else if (live == 0)
        p.status_offline
    else if (!poolIsHealthyOf(live, total))
        p.status_warning
    else
        p.status_success;
    // No latency on the bar. A round-trip figure that swings with whichever
    // relay answered last is a number nobody acts on, and it sat where the
    // reader looks for whether the pool is up. The per-relay pings are still in
    // the card this chip opens, next to the relay each one belongs to, which is
    // the only place the number means anything.
    const label = if (settling)
        ui.fmt("pausing · {d}/{d} relays", .{ live, total })
    else if (paused)
        ui.fmt("paused · 0/{d} relays", .{total})
    else
        ui.fmt("{d}/{d} relays", .{ live, total });
    // And no plate. The dot already carries the pool's health, so the surface
    // behind it was a second voice saying the same thing, in the busiest corner
    // of the window.
    const plated = false;
    // The trigger and its floating surface are siblings in a stack: that is the
    // sanctioned shape, and the anchored surface takes no space in the row.
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = Msg{ .toggle_menu = .relays },
            .label = label,
            .semantics = "Relays",
            .dot = dot,
            .chevron = true,
            .highlighted = plated,
            .ink = if (plated) p.text_secondary else p.text_muted,
        }),
        if (model.menu == .relays) relayPopover(ui, model) else ui.spacer(0),
    });
}

/// The signer zone: whether Plaza can sign right now, and the account menu.
pub fn signerZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const guest = model.is_guest();
    // Name the signer that is actually in use, and say whether it can sign right
    // now. Claiming "Notary ready" for a local key or an unreachable bunker would
    // be a chip that lies about where the reader's key lives.
    const signer = signerStatus();
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = if (guest) .open_join else Msg{ .toggle_menu = .account },
            .label = if (guest) "Guest" else signer.label,
            .semantics = if (guest) "Join" else "Account",
            .glyph = if (guest) "plus" else signer.glyph,
            .glyph_color = if (guest) p.text_faint_alt else signer.color,
        }),
        if (model.menu == .account) accountMenu(ui) else ui.spacer(0),
    });
}
pub fn poolIsHealthy(live: usize) bool {
    return poolIsHealthyOf(live, relayCount());
}

/// The same line, against a total the caller already has, so a chip judges its
/// health on the pair of numbers it is about to print.
///
/// Stated as "one straggler is fine", which is what the rule above says it means,
/// rather than as four fifths. Those agree for a pool of five or more and part
/// company below it: at four relays, four fifths demands FOUR of four, so one
/// relay down turns the dot amber and leaves it there. That went unnoticed when
/// the bootstrap list dropped from five to four in this same change, and the
/// four-fifths test kept passing while asserting the opposite of its own name,
/// because the arithmetic had moved under it.
///
/// The second clause is not decoration. Without it a ONE relay pool with nothing
/// connected reads healthy, since `0 + 1 >= 1`.
pub fn poolIsHealthyOf(live: usize, total: usize) bool {
    if (total == 0) return false;
    return live + 1 >= total and live * 2 >= total;
}

/// What the status bar says about signing: which signer holds the key, and
/// whether it can be reached.
const SignerStatus = struct { label: []const u8, glyph: []const u8, color: canvas.Color };

/// Whether the thing that signs is actually able to sign right now. The chrome
/// carries this as a colour; the identity card needs it as a fact.
pub fn signerIsHealthy() bool {
    return switch (keyholder.g_signer_kind) {
        .helper => helperState() == .ready,
        .remote => !remote_signer.g_remote_sign_notice.load(.acquire),
    };
}

pub fn signerStatus() SignerStatus {
    const p = theme.palette;
    return switch (keyholder.g_signer_kind) {
        // Notary: a separate process, so its health is a real question.
        //
        // Not installed is its own answer, ahead of the state machine. A session
        // restored onto an install with no Notary in it signs back in before the
        // probe has even run, and "unreachable" would send that reader looking
        // for a daemon that has crashed or a port that is busy. Nothing is
        // coming up; the install is short a file.
        .helper => if (keyholderMissing())
            .{ .label = "Notary is not installed", .glyph = "notary", .color = p.status_warning }
        else switch (helperState()) {
            .ready => .{ .label = "Notary ready", .glyph = "notary", .color = p.status_success },
            // It HOLDS your key. Saying "has no key" here was the bug: it reads
            // as an empty keyholder waiting to be set up, when what it wants is
            // a passphrase.
            .locked => .{ .label = "Notary is locked", .glyph = "notary", .color = p.status_warning },
            .empty => .{ .label = "Notary has no key", .glyph = "notary", .color = p.status_warning },
            .unreachable_ => .{ .label = "Notary unreachable", .glyph = "notary", .color = p.text_faint_alt },
            .starting => .{ .label = "Notary starting", .glyph = "notary", .color = p.status_warning },
        },
        // A remote bunker: reachable is the whole question, and the remote path
        // already tracks a failed round trip.
        .remote => if (remote_signer.g_remote_sign_notice.load(.acquire))
            .{ .label = "Signer unreachable", .glyph = "notary", .color = p.status_warning }
        else
            .{ .label = "Signer connected", .glyph = "notary", .color = p.status_success },
    };
}

/// One status-bar zone: a quiet pressable chip, highlighted only when it is
/// carrying live state the reader should look at.
const StatusChip = struct {
    press: Msg,
    label: []const u8,
    semantics: []const u8,
    /// A leading dot, for the relay zone's health.
    dot: ?canvas.Color = null,
    /// A leading glyph, for the signer zone and the offline warning.
    glyph: ?[]const u8 = null,
    glyph_color: canvas.Color = theme.palette.text_muted,
    /// A trailing chevron, for a chip that opens a menu.
    chevron: bool = false,
    highlighted: bool = false,
    ink: canvas.Color = theme.palette.text_muted,
};

pub fn statusChip(ui: *AppUi, chip: StatusChip) AppUi.Node {
    const p = theme.palette;
    // Gap 0 and explicit steps: a `gap` would space around the absent parts too,
    // so a chip with no dot and no chevron would carry their spacing anyway.
    const body = ui.row(.{ .cross = .center, .gap = 0 }, .{
        if (chip.dot) |color|
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = color, .radius = 3, .stroke_width = 0 } }, .{})
        else
            ui.spacer(0),
        if (chip.dot != null) hgap(ui, 6) else ui.spacer(0),
        if (chip.glyph) |name|
            // `appIcon` takes a RUNTIME name and resolves built-ins first, then
            // the app table, so one call serves both vocabularies.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = chip.glyph_color } }, name)
        else
            ui.spacer(0),
        if (chip.glyph != null) hgap(ui, 6) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = chip.ink } }, &.{.{ .text = chip.label, .scale = status_scale }}),
        if (chip.chevron) hgap(ui, 6) else ui.spacer(0),
        if (chip.chevron)
            ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_muted } }, "chevron-up")
        else
            ui.spacer(0),
    });
    // A highlighted chip carries a plate, so it needs a surface that paints; a
    // quiet one is text on the bar.
    const inner = if (chip.highlighted)
        ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_chip, .radius = 6, .stroke_width = 0 } }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), vgap(ui, 22), body, hgap(ui, 8) }),
        })
    else
        ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), body, hgap(ui, 8) });
    return pressRow(ui, .{
        .cross = .center,
        .on_press = chip.press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = chip.semantics, .focusable = true },
    }, .{inner});
}

/// The ink identity takes: a handle, a mention, a link inside a note.
///
/// Violet outside a place, and the community's own colour inside one. This is
/// the half of a place's colour a reader actually notices. A feed is mostly
/// handles and links, so recolouring them is the difference between one tinted
/// button and a room that reads as somebody's. The rule the violet enforces is
/// not suspended by that, it is applied: colour here means identity, and a
/// place is an identity.
///
/// `on_dark` and not the fill colour, because this is TEXT on the near-black
/// window and Hallway's `primary` is a background value. See `theme.PlaceColor`.
pub fn identityInk() canvas.Color {
    const m = activePlace() orelse return theme.palette.accent_identity;
    const c = m.color orelse return theme.palette.accent_identity;
    return c.on_dark;
}

/// The fill under the room's bright verb, and the ink knocked out of it.
///
/// Porcelain outside a place. Inside one this is the community's colour, and
/// the ink is HALLWAY'S `primary-foreground` rather than Plaza's `on_accent`:
/// those agree on a dark fill and disagree loudly on a light one, and YELLOW is
/// a light one.
///
/// Only the verbs that belong to the ROOM take it: composing into this place,
/// replying in it. The name sheet's Done, the join ladder and the notification
/// unread dot stay porcelain: they are the app talking, not the community, and
/// the dot in particular means a STATE, which no room gets to repaint.
pub fn roomVerbFill() canvas.Color {
    const m = activePlace() orelse return theme.palette.accent;
    const c = m.color orelse return theme.palette.accent;
    return c.primary;
}

pub fn roomVerbInk() canvas.Color {
    const m = activePlace() orelse return theme.palette.on_accent;
    const c = m.color orelse return theme.palette.on_accent;
    return c.on_primary;
}

/// The warm avatar tint for an author, chosen deterministically from the
/// pubkey so a face keeps the same color across sessions. Neutral graphite is
/// the last entry and the natural fallback for an all-zero key.
pub fn avatarTint(pubkey: [32]u8) theme.palette.Tint {
    const key = @as(usize, pubkey[0]) +% pubkey[15] +% pubkey[31];
    return theme.palette.avatar_tints[key % theme.palette.avatar_tints.len];
}

/// The corner an avatar takes at this size: Hallway's `avatarStyleDefault`.
///
/// Half the size is a disc, which is Plaza's own shape and what every surface
/// outside a place keeps. A place asking for "square" gets a rounded square
/// rather than a hard corner, because the faces sit against 1px rules at 32px
/// and a true 0 radius reads as a rendering fault at that size.
///
/// Asked of the OPEN place rather than stored per note: the shape belongs to
/// the room being read, so walking out restores the disc without touching a
/// single note.
pub fn avatarRadius(size: f32) f32 {
    const m = activePlace() orelse return size / 2;
    return if (m.square_avatars) size * 0.18 else size / 2;
}

/// A chrome pill: the redesign's 26px-high button, filled for the primary verb
/// and outlined for the quiet one. The house button is a different shape (28 high
/// on its own scale), so the chrome states its own.
pub fn pillButton(ui: *AppUi, label: []const u8, press: Msg, filled: bool, on_surface: canvas.Color) AppUi.Node {
    const p = theme.palette;
    // The outlined variant paints the surface it sits on, not "nothing": a panel
    // with no stated background falls back to the house card fill, which would
    // draw a plate the redesign's ghost button does not have.
    const style: canvas.WidgetStyle = if (filled)
        .{ .background = p.accent, .radius = 7, .stroke_width = 0 }
    else
        .{ .background = on_surface, .border = p.border_control, .radius = 7, .stroke_width = 1 };
    const ink = if (filled) p.on_accent else p.text_secondary;
    // The shot sets the filled label at 600 and the ghost at 500; the bundled
    // family steps 400 / 500 / 700, so both land on medium.
    const weight: canvas.TextSpanWeight = .medium;
    // The fill and the outline live on a `.panel`: a row paints no background at
    // all (the renderer draws nothing for the layout kinds), which is why the
    // filled pill was reading as dark-on-dark text with no button under it.
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        ui.el(.panel, .{ .padding = 0.01, .style = style }, .{
            ui.row(.{ .height = 26, .cross = .center, .gap = 0 }, .{
                hgap(ui, 11),
                ui.paragraph(.{ .style = .{ .foreground = ink } }, &.{.{ .text = label, .weight = weight, .scale = meta_scale }}),
                hgap(ui, 11),
            }),
        }),
    });
}

pub fn relayBadgeTextForTest(i: usize) []const u8 {
    const e = relayAt(i) orelse return "(removed)";
    return relayBadgeText(e);
}
pub fn poolIsHealthyOfForTest(live: usize, total: usize) bool {
    return poolIsHealthyOf(live, total);
}
pub fn signerStatusLabelForTest() []const u8 {
    return signerStatus().label;
}
/// The abbreviated npub exactly as the view renders it, so a test can count how
/// many times a screen says it without hard-coding the truncation. For tests.
pub fn npubShortForTest(arena: std.mem.Allocator, pubkey: [32]u8) []const u8 {
    return npubShortOf(arena, pubkey);
}
pub fn pausedBannerTextForTest(arena: std.mem.Allocator, queued: usize) []const u8 {
    var ui = AppUi.init(arena);
    return pausedBannerText(&ui, queued);
}

pub fn offlineBannerTextForTest(arena: std.mem.Allocator, queued: usize, none_set: bool) []const u8 {
    var ui = AppUi.init(arena);
    return offlineBannerText(&ui, queued, none_set);
}

/// Whether the pool counts as healthy: MOST of it answering, not all of it. The
/// redesign's at-rest bar reads "4/5 relays" in green while its working bar reads
/// "3/5" in amber, so the line sits at four fifths. A relay pool always has a
/// straggler, and a bar that goes amber for one is a bar nobody reads.
pub fn poolIsHealthyForTest(live: usize) bool {
    return poolIsHealthy(live);
}
pub fn identityInkForTest() canvas.Color {
    return identityInk();
}

pub fn roomVerbFillForTest() canvas.Color {
    return roomVerbFill();
}

pub fn avatarRadiusForTest(size: f32) f32 {
    return avatarRadius(size);
}

//! The notifications sheet.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const inbox = @import("inbox.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const InboxItem = main.InboxItem;
const MentionRef = main.MentionRef;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const body_line_height = main.body_line_height;
const clampSpansToLines = main.clampSpansToLines;
const contentSpansIn = main.contentSpansIn;
const coverNotice = main.coverNotice;
const cover_notice_height = main.cover_notice_height;
const feed_column_width = main.feed_column_width;
const hgap = main.hgap;
const inboxItems = main.inboxItems;
const inboxReadThrough = main.inboxReadThrough;
const inbox_cap = main.inbox_cap;
const list_row_height = main.list_row_height;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const nested_avatar_size = main.nested_avatar_size;
const nested_meta_scale = main.nested_meta_scale;
const notification_age_height = main.notification_age_height;
const notification_body_lines = main.notification_body_lines;
const nowSeconds = main.nowSeconds;
const personAvatar = main.personAvatar;
const personName = main.personName;
const pressRow = main.pressRow;
const profileTab = main.profileTab;
const profileTabFocused = main.profileTabFocused;
const resolveInboxBodies = main.resolveInboxBodies;
const settings_title_scale = main.settings_title_scale;
const stat_scale = main.stat_scale;
const status_scale = main.status_scale;
const vgap = main.vgap;
const wantInboxProfiles = main.wantInboxProfiles;
const warningCovered = main.warningCovered;
const window_height = main.window_height;

/// What people did that was aimed at the reader.
///
/// A plain capped column, deliberately NOT a virtual list. The runtime tracks at
/// most eight virtual windows per build and the app already declares all eight
/// at a full back stack, so a ninth here would be dropped: the list would render
/// once and then stop rebuilding as the reader scrolled, which reads as content
/// that vanishes. A page is capped and replaced rather than appended, which is
/// the same answer the thread reached for the same reason.
pub fn notificationsSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    var buf: [inbox_cap]InboxItem = undefined;
    resolveInboxBodies();
    const shown = inboxItems(&buf, !model.notifications_everyone);

    // A windowed list, not pages. Paging existed because every row was mounted
    // at once and the whole view is priced against a 1024-node ceiling that
    // refuses a frame WHOLE when crossed, so twenty rows was the arithmetic that
    // fit. A window mounts only what is on screen, which removes the ceiling as
    // a constraint and the pager with it: two hundred notifications are one
    // scroll rather than ten presses of a Next button.
    const options: AppUi.VirtualListOptions = .{
        .id = "notifications",
        .item_count = shown.len,
        .item_extent = 0,
        .extent_estimate = notificationExtentEstimate,
        .extent_context = &shown_ctx,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Notifications list" },
    };
    shown_ctx = .{ .items = shown };
    const window = ui.virtualWindow(options);
    inbox.g_inbox_visible = .{
        .first = @intCast(window.first_visible_index),
        .last = @intCast(window.last_visible_index),
        .len = shown.len,
    };
    // After the window, because it asks on behalf of the rows the window chose.
    wantInboxProfiles(shown);
    const rows = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.spacer(0);
    // Centred ONCE, around the list, never per row. A spacer-column-spacer
    // wrapper on each row is four nodes apiece, and fourteen mounted rows of
    // that is fifty-six nodes spent on horizontal alignment: enough on its own
    // to push this view through the 1024 ceiling that refuses a frame whole.
    for (rows, 0..) |*row, offset| {
        const i = window.start_index + offset;
        row.* = if (i < shown.len) notificationRow(ui, &shown[i]) else ui.spacer(0);
    }

    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Notifications" },
    }, .{
        notificationsHeader(ui),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        notificationsTabs(ui, model),
        if (shown.len == 0) notificationsEmpty(ui, model) else ui.spacer(0),
        ui.row(.{ .grow = 1, .gap = 0 }, .{
            ui.spacer(1),
            // Width only, never grow. In a row, grow claims the remaining
            // horizontal space and beats the fixed width: 620 resolved to 853
            // and ran 153px past the edge of the narrowest allowed window.
            // The row's cross-axis stretch is what gives it its height.
            ui.column(.{ .width = notifications_column_width }, .{
                ui.virtualList(options, window, .{rows}),
            }),
            ui.spacer(1),
        }),
        notificationsFooter(ui, shown.len),
    });
}

/// The rows the notifications window is measuring, so the extent callback can
/// price one without the view handing it a closure.
const NotificationCtx = struct { items: []const InboxItem = &.{} };
var shown_ctx: NotificationCtx = .{};

/// A cheap height for the notification at `index`, from the item alone: the
/// row's chrome plus however many lines its body wraps to.
fn notificationExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const ctx: *const NotificationCtx = @ptrCast(@alignCast(context orelse return 64));
    const i: usize = @intCast(index);
    if (i >= ctx.items.len) return 64;
    const item = &ctx.items[i];
    // 12 padding top and bottom, the name line, the time line, and the body.
    var extent: f32 = 12 * 2 + body_line_height + body_line_height + 6;
    if (warningCovered(item.warned, item.body_key)) {
        extent += cover_notice_height;
    } else if (item.body_len > 0) {
        const per_line: f32 = 58;
        const lines = @max(1.0, @ceil(@as(f32, @floatFromInt(item.body_len)) / per_line));
        extent += lines * body_line_height;
    }
    return extent;
}

/// The reading column for notifications, matching the feed's so a row is the
/// same width whichever screen it is on.
pub const notifications_column_width: f32 = feed_column_width;
/// How many rows the sheet draws at once.
///
/// This is a NODE budget, not a taste in page sizes. The sheet is stacked over
/// the feed rather than replacing it, because the feed's scroll offset lives in
/// its mounted list, so both trees are priced against the same 1024-node view
/// ceiling and a view past it is refused WHOLE: no frame at all, a window that
/// stops updating. The base costs about 413 nodes on the feed and about 573 over
/// a full back stack, the sheet's own chrome about 40, and a row eleven. Twenty
/// rows is 832 in the worst case, which leaves real margin rather than the nine
/// nodes the first arithmetic here left.
///
/// Pages REPLACE rather than accumulate, so this is the cost whether the reader
/// holds five notifications or two hundred, and all two hundred are reachable
/// instead of the first forty-eight.
///
/// Twenty, until the verb row under a note grew from four glyphs to six and the
/// base under this sheet grew with it. That is what this number IS: a budget,
/// not a taste in page sizes, and a budget whose inputs moved. Measured rather
/// than estimated this time, over every frame the app can draw: at twenty this
/// sheet over the deepest thread came to 922 of 1024, which is inside the
/// ceiling and outside the tenth of it the suite insists stays free.
pub const inbox_page = 16;

fn notificationsHeader(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 10, .height = 38, .padding = 0.01 }, .{
            hgap(ui, 10),
            // A page needs a way out. As a sheet this had the scrim to press and
            // Escape to dismiss; an opaque level has neither, so closing it was
            // the bell in a rail the page was covering.
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = list_row_height,
                .cross = .center,
                .on_press = Msg.close_notifications,
                .style = .{ .radius = 6, .quiet_hover = true },
                .semantics = .{ .role = .button, .label = "Back", .focusable = true },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 6),
                    ui.icon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
                    hgap(ui, 4),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "Back", .scale = stat_scale }}),
                    hgap(ui, 8),
                    vgap(ui, 26),
                }),
            }),
            hgap(ui, 4),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Notifications", .weight = .bold, .scale = settings_title_scale }},
            ),
            ui.spacer(1),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg.notifications_read_all,
                .style = .{ .radius = 4 },
                .semantics = .{ .role = .button, .label = "Mark all read", .focusable = true },
            }, .{
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "Mark all read", .scale = status_scale }}),
            }),
            hgap(ui, 14),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

/// Two tabs, and the reason there are two: an inbox is the one surface where a
/// stranger decides what the reader sees, so the default holds only people they
/// already read.
fn notificationsTabs(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.row(.{ .cross = .center, .gap = 6, .padding = 0.01 }, .{
        hgap(ui, 14),
        vgap(ui, 42),
        profileTabFocused(ui, "Everyone", model.notifications_everyone, Msg{ .notifications_tab = 1 }, true),
        profileTab(ui, "People you follow", !model.notifications_everyone, Msg{ .notifications_tab = 0 }),
        ui.spacer(1),
    });
}

fn notificationsEmpty(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const text: []const u8 = if (model.notifications_everyone)
        "Nothing yet. When somebody replies, mentions, likes, reposts or zaps you, it lands here."
    else
        "Nothing from the people you follow yet. Everyone is in the other tab.";
    return ui.row(.{ .gap = 0, .padding = 14 }, .{
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
    });
}

fn notificationsFooter(ui: *AppUi, count: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
        ui.row(.{ .cross = .center, .gap = 0, .height = 30, .padding = 0.01 }, .{
            hgap(ui, 14),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = ui.fmt("{d} here", .{count}), .monospace = true, .scale = mono_meta_scale }},
            ),
            ui.spacer(1),
            // Said plainly, because it is a real limitation rather than a
            // detail: another client will not know what has been read here.
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "read state stays on this Mac", .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 14),
        }),
    });
}

/// How long ago this landed, in the app's one spelling of it.
fn inboxAge(ui: *AppUi, created_at: i64) []const u8 {
    var buf: [16]u8 = undefined;
    const written = Note.ageInto(&buf, created_at, nowSeconds()) catch return "";
    return ui.arena.dupe(u8, written) catch "";
}

/// One thing somebody did.
/// A notification's words as spans: styled the way the feed styles a note, and
/// carrying no link payloads.
///
/// The row is drawn from a copy the sheet made on its own stack (`inboxItems`
/// into a local buffer). A paragraph copies its span text into the frame, but
/// not a span's `link`: the runtime copies that after the view has returned,
/// when the stack it pointed into is gone. And this paragraph has no link
/// handler, so a payload pressed nothing anyway. A press anywhere on the row
/// opens the note.
fn inboxBodySpans(ui: *AppUi, body: []const u8, mentions: []const MentionRef) []const canvas.TextSpan {
    const styled = contentSpansIn(ui, body, mentions, 0);
    const spans = ui.arena.dupe(canvas.TextSpan, styled) catch return &.{};
    for (spans) |*span| span.link = "";
    return spans;
}

pub fn notificationRow(ui: *AppUi, item: *const InboxItem) AppUi.Node {
    const p = theme.palette;
    const read = item.created_at <= inboxReadThrough();
    const glyph: []const u8 = switch (item.verb) {
        .reply, .mention => "reply",
        .like => "like",
        .repost => "repeat",
        .zap => "zap",
    };
    const tint = switch (item.verb) {
        .zap => p.status_warning,
        .repost => p.status_success,
        .like => p.status_like,
        else => p.text_muted_alt,
    };
    // A reply says only the name. "replied to you" above a row that already
    // shows their reply is the same fact twice.
    const verb_text: []const u8 = switch (item.verb) {
        .reply => "",
        .mention => "mentioned you in a note",
        .like => "reacted to your note",
        .repost => "reposted your note",
        .zap => "zapped your note",
    };
    const body = item.body();
    const emoji = item.reactionGlyph();
    const open: Msg = if (item.hasTarget()) Msg{ .open_event = item.target_id } else Msg{ .open_person = item.author };

    // Name, verb and amount are SPANS of one paragraph, not three paragraphs.
    // The row is priced in widget nodes against a per-view ceiling that refuses
    // the whole screen when crossed, and the first cut of this row spent five
    // extra nodes apiece on things that are only text: twenty rows of that put
    // the notifications view at 924 against a ceiling of 1024 with 102 that has
    // to stay free. Spans cost nothing.
    var head: [3]canvas.TextSpan = undefined;
    var head_len: usize = 0;
    head[head_len] = .{ .text = personName(ui, item.author), .weight = .medium, .scale = nested_meta_scale };
    head_len += 1;
    if (verb_text.len > 0) {
        head[head_len] = .{ .text = ui.fmt(" {s}", .{verb_text}), .scale = nested_meta_scale };
        head_len += 1;
    }
    if (item.verb == .zap and item.msat > 0) {
        head[head_len] = .{ .text = ui.fmt("  {d} sats", .{item.msat / 1000}), .weight = .medium, .scale = nested_meta_scale };
        head_len += 1;
    }

    // Built by hand rather than with an `else ui.spacer(0)` per optional child,
    // because an empty spacer is still a node and this row has three of them.
    var kids: [3]AppUi.Node = undefined;
    var kids_len: usize = 0;
    kids[kids_len] = ui.el(.list_item, .{
        .padding = 0.01,
        .height = list_row_height,
        .on_press = Msg{ .open_person = item.author },
        .style = .{ .radius = 4, .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
    }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_body_soft } }, head[0..head_len]),
    });
    kids_len += 1;
    if (warningCovered(item.warned, item.body_key)) {
        // The note's words are covered, so the row says so in their place, and
        // the chip uncovers them without leaving the list.
        kids[kids_len] = coverNotice(ui, item.warning_buf[0..item.warning_len], item.body_key);
        kids_len += 1;
    } else if (body.len > 0) {
        // Theirs for a reply, yours for everything else, and dimmer when it is
        // yours: you wrote it, so the new fact is who did what to it.
        const own = item.verb != .reply and item.verb != .mention;
        // Two lines and stop, cut in the spans before layout because the SDK
        // has no multi-line clamp. The same rule an ancestor's body follows, so
        // a long note cannot turn one notification into half a screen.
        // The words were rendered when the row was admitted (`bakeInboxBody`),
        // the way the feed renders a note, so a `nostr:npub…` is already a name
        // here and a `nostr:nevent…` is already a short label. What is left to
        // do is mark the names, from the offsets that bake recorded.
        const spans = clampSpansToLines(ui, inboxBodySpans(ui, body, item.mentions.all()), notification_body_lines);
        kids[kids_len] = ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = if (own) p.text_muted_alt else p.text_body } },
            spans,
        );
        kids_len += 1;
    }
    // What the row itself opens, as a stop the keyboard can reach. The row's
    // paragraphs wrap, and the toolkit measures a wrapping paragraph correctly
    // only inside a `row` or `data_row`, so the row stays one and cannot take
    // the focus ring itself. The age sits under the text and is one line, which
    // a list row measures correctly.
    //
    // Only when the row opens a note. A mention that answers nothing has no
    // target, so the row opens the person, and the name above is already that
    // stop: a third one to the same profile, called "Open note", would say the
    // wrong thing about where it goes.
    const opens_note = item.hasTarget();
    kids[kids_len] = pressRow(ui, .{
        .padding = 0.01,
        .height = notification_age_height,
        .on_press = if (opens_note) open else null,
        .style = .{ .radius = 4, .quiet_hover = true },
        .semantics = if (opens_note) .{ .role = .button, .label = "Open note", .focusable = true } else .{},
    }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = inboxAge(ui, item.created_at), .monospace = true, .scale = mono_meta_scale }},
        ),
    });
    kids_len += 1;

    return ui.column(.{ .gap = 0 }, .{
        ui.el(.data_row, .{
            .padding = 12,
            .gap = 10,
            // Top aligned: the row is several lines now, and a gutter glyph
            // floating beside the middle of a paragraph belongs to nothing.
            .cross = .start,
            // `open_event`, never `open_thread`. The thread route resolves an id
            // against the LOADED FEED, which is scoped to follows and holds at
            // most a few hundred notes; what a notification points at is almost
            // always an older note of the reader's own, or a stranger's note the
            // feed would never carry. So the obvious route made the common press
            // a silent no-op. This one asks the store by name.
            .on_press = open,
            .style = .{ .quiet_hover = true },
            .semantics = .{ .role = .button, .label = if (verb_text.len > 0) verb_text else "replied to you" },
        }, .{
            // The unread dot holds its width either way, so a row does not shift
            // sideways the moment it is read.
            ui.el(.panel, .{
                .width = 6,
                .height = 6,
                .padding = 0.01,
                .style = .{
                    .background = if (read) p.surface_window else p.accent,
                    .border = if (read) p.surface_window else p.accent,
                    .radius = 3,
                    .stroke_width = 0,
                },
            }, .{}),
            // Glyph and face together, centred against EACH OTHER, and that pair
            // top-aligned against the text. The row's own `.cross = .start` is
            // right for the avatar, which should hang beside the name and the
            // first line of the body, and wrong for a 14pt glyph, which then
            // floated at the very top with nothing beside it.
            ui.row(.{ .cross = .center, .gap = 10 }, .{
                // The reaction they actually sent, where a generic heart used to
                // be. A shortcode with no image would print as `:shakingeyes:`,
                // so only something short enough to read as a glyph is drawn.
                if (item.verb == .like and emoji.len > 0 and emoji.len <= 8)
                    ui.paragraph(.{ .style = .{ .foreground = p.text_body } }, &.{.{ .text = emoji, .scale = nested_meta_scale }})
                else
                    ui.appIcon(.{ .width = 14, .height = 14, .style = .{ .foreground = tint } }, glyph),
                // The face and the name go to the person, everything else goes
                // to the note. That is what the feed does and what Jumble does,
                // and without it the one thing a notification is most likely to
                // make you want (who IS this) was the one thing you could not
                // press.
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .on_press = Msg{ .open_person = item.author },
                    .style = .{ .radius = 999, .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
                }, .{
                    personAvatar(ui, item.author, nested_avatar_size),
                }),
            }),
            ui.column(.{ .gap = 3, .grow = 1 }, kids[0..kids_len]),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

pub fn notificationRowForTest(ui: *AppUi, item: *const InboxItem) AppUi.Node {
    return notificationRow(ui, item);
}
pub const notifications_column_width_for_test = notifications_column_width;

//! The feed screen.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const feed_media = @import("feed_media.zig");
const places = @import("places.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const activePlace = main.activePlace;
const articlePanel = main.articlePanel;
const backupNudge = main.backupNudge;
const bookmarks_level_key = main.bookmarks_level_key;
const feedOptions = main.feedOptions;
const guestBanner = main.guestBanner;
const isArticleRoot = main.isArticleRoot;
const noteCard = main.noteCard;
const offlineBanner = main.offlineBanner;
const placeHeader = main.placeHeader;
const placesRail = main.placesRail;
const profileLevelKey = main.profileLevelKey;
const profilePanel = main.profilePanel;
const railView = main.railView;
const relayAuthBanner = main.relayAuthBanner;
const scopeHeader = main.scopeHeader;
const statusBar = main.statusBar;
const threadLevelKey = main.threadLevelKey;
const threadOccluder = main.threadOccluder;
const threadPanel = main.threadPanel;
const threadRepliesFromStore = main.threadRepliesFromStore;
const topicLevelKey = main.topicLevelKey;
const updateBanner = main.updateBanner;

/// The feed screen, and everything layered on it.
///
/// `levels` is what the Settings sheet passes false: see `settingsSheet`. The
/// thread stack is the most expensive thing this app builds, and a view past
/// `max_canvas_widget_nodes_per_view` is refused WHOLE, so the deepest stack
/// under the largest sheet is the frame that decides whether the window can
/// draw at all. Settings used to REPLACE this tree, which unmounted every level
/// and lost its scroll offset anyway, so not building them behind the sheet
/// costs nothing that was not already gone and buys back most of the ceiling.
/// Every other sheet keeps its levels, because for those the offsets survive
/// today and dropping them would be a real loss.
pub fn feedView(ui: *AppUi, model: *const Model, levels: bool) AppUi.Node {
    const p = theme.palette;
    // The feed is always built (so it is always mounted): a thread is layered
    // OVER it, not swapped in, so the feed's scroll offset survives and closing
    // a thread returns the reader to where they were, not the top. EACH open
    // thread level is layered too (occluded ancestors under the current one), so
    // every level keeps its own scroll offset and Back never lands a parent
    // thread at the top.
    const feed = feedContent(ui, model);
    const content = if (levels and model.levelOpen()) blk: {
        // feed + one panel per level: the back-stacked levels (oldest first),
        // then the current one on top. A level is a thread or a person; both
        // spend one virtual window either way, which is why they share a stack.
        const kids = ui.arena.alloc(AppUi.Node, 2 + model.thread_stack_len) catch break :blk feed;
        kids[0] = feed;
        for (0..model.thread_stack_len) |d| {
            const screen = &model.thread_stack[d];
            if (screen.bookmarks) {
                const lk = bookmarks_level_key + d;
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .bookmarks, &.{}, false, lk, d, true));
                continue;
            }
            if (screen.topic()) |t| {
                const lk = topicLevelKey(d, t);
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .topic = t }, &.{}, false, lk, d, true));
                continue;
            }
            if (screen.profile) |pk| {
                const lk = profileLevelKey(d, pk);
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .person = pk }, &.{}, false, lk, d, true));
                continue;
            }
            const root = &screen.note;
            const lk = threadLevelKey(d, root.id);
            kids[1 + d] = threadOccluder(ui, lk, if (isArticleRoot(root))
                articlePanel(ui, model, root, lk, d, true)
            else
                threadPanel(ui, model, root, threadRepliesFromStore(ui, d, root.event_id), false, lk, d, true));
        }
        if (model.viewing_bookmarks) {
            const lk = bookmarks_level_key + model.thread_stack_len;
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .bookmarks, model.thread_notes[0..model.thread_notes_len], false, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        if (model.viewingTopic()) |t| {
            const lk = topicLevelKey(model.thread_stack_len, t);
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .topic = t }, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        if (model.viewing_profile) |pk| {
            const lk = profileLevelKey(model.thread_stack_len, pk);
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .person = pk }, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        const lk = threadLevelKey(model.thread_stack_len, model.thread_root.id);
        kids[kids.len - 1] = threadOccluder(ui, lk, if (isArticleRoot(&model.thread_root))
            articlePanel(ui, model, &model.thread_root, lk, model.thread_stack_len, false)
        else
            threadPanel(ui, model, &model.thread_root, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
        break :blk ui.stack(.{ .grow = 1 }, .{kids});
    } else feed;

    // The window is the rail plus the content. The old titlebar of buttons is
    // gone: home, compose, settings, and the account seat live on the rail, so
    // the feed owns the full width below the OS titlebar.
    const second_rail = places.g_rail_open;
    return ui.row(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        railView(ui, model),
        // A 1px vertical rule between the rail and the content. No `grow`: in a
        // row that would stretch it along the WIDTH and eat the feed's space; it
        // fills the height on its own via the row's cross-axis stretch.
        ui.separator(.{ .width = 1, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        // The second rail, and its own rule. Contents are a pure function of
        // which primary section is selected, so there is nothing to consult here
        // beyond that: Home has no second rail, Places is a list of yours.
        if (second_rail) placesRail(ui) else ui.spacer(0),
        if (second_rail)
            ui.separator(.{ .width = 1, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } })
        else
            ui.spacer(0),
        // The bar sits BESIDE the rail and BELOW everything else, which is the
        // only place it is always visible. It used to be the last row of the
        // feed's own column, so every level layered over the feed (a thread, a
        // person) covered it: the pool's health, the outbox and the signer
        // vanished the moment a reader opened a note, which is not a moment to
        // stop telling them whether their notes can go out.
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            content,
            statusBar(ui, model),
        }),
    });
}

/// The feed content column: the guest banner, the scope line, the note list, and
/// the status bar.
fn feedContent(ui: *AppUi, model: *const Model) AppUi.Node {
    // The data-window seam: the runtime resolves scroll offset and viewport
    // into a visible index range, and only those rows are built. A feed of any
    // length then costs what the handful on screen costs.
    var options = feedOptions(model);
    // Nothing to cover when nothing is drawn. The runtime re-runs the WHOLE build
    // and layout a second time whenever a declared window reports fewer built
    // rows than its item count and viewport imply, which an occluded list does by
    // construction: it declares two hundred items and builds none, so it is
    // permanently "undercovered" and every rebuild costs two. That is the exact
    // opposite of what occluding it was for, and it lands on the most ordinary
    // state in the app: one thread open over the feed, rebuilt on every tick,
    // every scroll and every keystroke.
    //
    // A count of zero is the runtime's own early-out (`item_count == 0` skips the
    // coverage check). The retained scroll offset rides on the list's ID and the
    // extent table behind it, neither of which this touches, so the feed is still
    // where the reader left it on the way back.
    const window = ui.virtualWindow(options);
    // A SHEET counts too, and for a long time it did not. Settings, the
    // composer, the notifications panel and the join ladder all sit over the
    // feed on a scrim, and the feed underneath was being built in full on every
    // frame of scrolling one of them.
    //
    // Measured on a real 105 MB store: scrolling settings cost 1775us to rebuild
    // and 6806us to lay out, with 747 nodes mounted. Without the feed beneath
    // it: 142us, 933us, 240 nodes. Seven times the layout work, for rows behind
    // a 55% scrim and a blur.
    //
    // The trade is visible and worth naming: those bands either side of a sheet
    // now show the app's background rather than a blurred, dimmed feed.
    const occluded = model.levelOpen() or
        model.stage == .settings or model.composing or model.notifications_open or model.joining;
    if (occluded) options.item_count = 0;
    // A level drawn opaquely over the feed hides every one of these rows, and
    // building them anyway spent about a third of the whole 1024-node view
    // budget on things nobody can see. The thread and the profile have taken an
    // `occluded` parameter since they were written; the feed never did, because
    // for a long time it was the only list there was.
    //
    // The list stays MOUNTED, so its scroll offset survives exactly as an occluded
    // level's does: the offset rides on the id and the retained extents, not on
    // the rows built this frame.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch {
            ui.failed = true;
            return ui.column(.{}, .{});
        };
        for (built, 0..) |*row, offset| row.* = noteCard(ui, &model.notes[window.start_index + offset]);
        break :blk built;
    };

    // Exactly which rows are on screen, which is what decides where the image
    // budget goes. Recorded here because the runtime resolves it during the
    // build, while the fetch pass runs later, in `update`. Left alone while
    // occluded: the picture passes have their own branches for the level that
    // is actually being read, and zeroing this would make the feed reload every
    // face on the way back.
    if (!occluded) {
        feed_media.g_visible_first = window.first_visible_index;
        feed_media.g_visible_last = window.last_visible_index;
    }

    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (model.show_guest_strip()) guestBanner(ui, model) else ui.spacer(0),
        // Under the guest strip, because being signed out is the bigger fact.
        offlineBanner(ui, model),
        // A relay is waiting on an answer only the reader can give.
        relayAuthBanner(ui),
        // Under all of them. A newer version existing is the least urgent and
        // the only one the reader can put away.
        updateBanner(ui),
        // ONE header, not two. A place stacked its own banner on top of the
        // scope line, so the top of the room was the place's name over the
        // place's feed name over a rule, in two different rhythms. In a place
        // the place header IS the scope line, and it keeps the same 11/9 insets
        // so nothing jumps on the way in or out.
        if (activePlace()) |m| placeHeader(ui, model, m) else scopeHeader(ui, model),
        if (model.notes_len == 0)
            ui.column(.{ .gap = 12, .main = .center, .cross = .center, .grow = 1, .padding = 24 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.empty_text()),
            })
        else
            // The list owns its scroll state, keyed by the id in `feedOptions`,
            // so the offset survives every rebuild (and the image viewer
            // opening over it) without the model mirroring it.
            ui.virtualList(options, window, .{rows}),
        if (model.backup_nudge) backupNudge(ui) else ui.spacer(0),
    });
}

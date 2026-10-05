//! The root view: which screen and which layers are up.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const places = @import("places.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const activePlace = main.activePlace;
const addressSheet = main.addressSheet;
const composeSheet = main.composeSheet;
const deleteConfirm = main.deleteConfirm;
const feedView = main.feedView;
const freshListConfirm = main.freshListConfirm;
const imageViewer = main.imageViewer;
const joinSheet = main.joinSheet;
const nameSheet = main.nameSheet;
const notificationsSheet = main.notificationsSheet;
const placeInfoCard = main.placeInfoCard;
const profileSheet = main.profileSheet;
const settingsSheet = main.settingsSheet;
const toastOverlay = main.toastOverlay;

// The two static screens stay declarative markup, compiled into the view at
// build time (so their bindings are still checked, now by the compiler). The
// feed is hand-written below: an inline image needs a runtime `ImageId`
// reference, which the markup grammar deliberately does not carry, so a media
// feed has to be a Zig view.
const OnboardingView = canvas.CompiledMarkupView(Model, Msg, @embedFile("onboarding.native"));

/// The root view: one screen at a time, chosen by the stage, with an expanded
/// picture layered over it when one is open.
pub fn appView(ui: *AppUi, model: *const Model) AppUi.Node {
    // A new tree, so the payloads the one before last handed out are free.
    main.g_view_build +%= 1;
    const view = appViewLayers(ui, model);
    return view;
}

fn appViewLayers(ui: *AppUi, model: *const Model) AppUi.Node {
    const base = switch (model.stage) {
        .onboarding => OnboardingView.build(ui, model),
        // Settings layers OVER the feed rather than replacing it, like every
        // other sheet: the feed stays mounted and keeps its scroll offset, and
        // it is what the sheet's scrim has to blur to look like glass. Without
        // its thread levels, for the node-budget reason `feedView` states.
        .settings => feedView(ui, model, false),
        .ready => feedView(ui, model, true),
    };
    if (model.deleting_note) |_| {
        return ui.stack(.{ .grow = 1 }, .{ base, deleteConfirm(ui) });
    }
    if (model.fresh_ask) |ask| {
        // Settings raises this one too (a first media server), and Settings is
        // a sheet over the feed: stacked straight on the feed, the question
        // made the page it was asked from disappear behind it.
        if (model.stage == .settings) {
            if (model.editing_profile) {
                return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), profileSheet(ui, model), freshListConfirm(ui, ask) });
            }
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), freshListConfirm(ui, ask) });
        }
        return ui.stack(.{ .grow = 1 }, .{ base, freshListConfirm(ui, ask) });
    }
    if (model.expanded_note) |note_id| {
        if (model.noteById(note_id)) |note| {
            // Layered OVER the feed rather than replacing it, so the scroll
            // region stays mounted and holds its offset. Swapping the tree out
            // unmounts it, and closing would drop the reader back at the top.
            return ui.stack(.{ .grow = 1 }, .{ base, imageViewer(ui, note, model.expanded_image) });
        }
    }
    if (model.stage == .ready and model.joining) {
        return ui.stack(.{ .grow = 1 }, .{ base, joinSheet(ui, model) });
    }
    if (model.stage == .ready and model.naming) {
        return ui.stack(.{ .grow = 1 }, .{ base, nameSheet(ui, model) });
    }
    if (model.stage == .ready and model.address_open) {
        return ui.stack(.{ .grow = 1 }, .{ base, addressSheet(ui, model) });
    }
    if (model.notifications_open) {
        return ui.stack(.{ .grow = 1 }, .{ base, notificationsSheet(ui, model) });
    }
    // Over the room it describes, so closing it puts the reader back exactly
    // where they were rather than at the top of a rebuilt feed.
    if (places.g_place_info != .closed) {
        if (activePlace()) |m| return ui.stack(.{ .grow = 1 }, .{ base, placeInfoCard(ui, m) });
    }
    if (model.stage == .settings) {
        // Both sheets, in order, when a profile is being edited: dropping the
        // one underneath would make Settings blink out and back as the reader
        // opens and closes the editor it was opened from.
        //
        // The address field is reachable here too, by its shortcut, and needs
        // the same treatment for the same reason.
        if (model.address_open) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), addressSheet(ui, model) });
        }
        if (model.editing_profile) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), profileSheet(ui, model) });
        }
        // The toast rides over Settings as well as over the feed. It was gated on
        // the feed alone, from when nothing in Settings could raise one; the
        // "Open Notary" control can, and its whole job on a refused press is to
        // say why nothing happened. A message that only appears on a screen the
        // reader is not looking at is the silent press it exists to prevent.
        if (model.toast_until != 0) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), toastOverlay(ui, model) });
        }
        return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model) });
    }
    if (model.stage == .ready and model.composing) {
        return ui.stack(.{ .grow = 1 }, .{ base, composeSheet(ui, model) });
    }
    if (model.stage == .ready and model.toast_until != 0) {
        return ui.stack(.{ .grow = 1 }, .{ base, toastOverlay(ui, model) });
    }
    return base;
}

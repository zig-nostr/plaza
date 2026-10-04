//! Upload cards and the media servers card.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const media_servers = @import("media_servers.zig");
const blossom = @import("blossom.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const BlossomEdit = main.BlossomEdit;
const Model = main.Model;
const Msg = main.Msg;
const UploadJob = main.UploadJob;
const UploadTarget = main.UploadTarget;
const activePubkey = main.activePubkey;
const blossomProbeAsking = main.blossomProbeAsking;
const byteSize = main.byteSize;
const canWriteBlossomList = main.canWriteBlossomList;
const haveOwnBlossomList = main.haveOwnBlossomList;
const hgap = main.hgap;
const menu_scale = main.menu_scale;
const mono_chip_scale = main.mono_chip_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const settingsCard = main.settingsCard;
const settingsLink = main.settingsLink;
const settings_card_radius = main.settings_card_radius;
const uploadJobFor = main.uploadJobFor;
const uploadServers = main.uploadServers;
const vgap = main.vgap;

// -------------------------------------------------------------------- views

/// What sits in the composer, or beside a profile field, for putting a picture
/// in: a button while there is nothing going on, and the card for the job while
/// there is.
pub fn uploadStrip(ui: *AppUi, model: *const Model, target: UploadTarget) AppUi.Node {
    const p = theme.palette;
    if (uploadJobFor(target)) |job| return uploadCard(ui, model, job);
    const servers = uploadServers();
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 2),
        ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .upload_pick = @intFromEnum(target) } }, "Add picture"),
        hgap(ui, 8),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = ui.fmt("Uploads to {s}", .{blossom.serverLabel(servers.at(0))}), .monospace = true, .scale = mono_meta_scale }},
        ),
    });
}

/// Where the servers are said, in the reader's terms. Named before anything is
/// sent, and the same words whether they chose the servers or the app did.
fn uploadWhere(ui: *AppUi, job: *const UploadJob) []const u8 {
    if (job.server_count == 0) return "No media server is set up.";
    const first = blossom.serverLabel(job.server(0));
    if (job.from_list) {
        if (job.server_count == 1) return ui.fmt("Uploads to {s}, from your server list.", .{first});
        return ui.fmt("Uploads to {s}, from your server list. If it refuses, {s} is next.", .{ first, blossom.serverLabel(job.server(1)) });
    }
    if (job.server_count == 1) return ui.fmt("You have no server list, so this goes to {s}.", .{first});
    return ui.fmt("You have no server list, so this goes to {s}, then {s} if it refuses. Settings has the list.", .{ first, blossom.serverLabel(job.server(1)) });
}

fn uploadCard(ui: *AppUi, model: *const Model, job: *UploadJob) AppUi.Node {
    const p = theme.palette;
    var rows: [9]AppUi.Node = undefined;
    var n: usize = 0;
    const name = job.fileName();
    switch (job.phase()) {
        .preparing => {
            rows[n] = uploadLine(ui, ui.fmt("Reading {s}...", .{name}), p.text_secondary);
            n += 1;
            rows[n] = uploadButtons(ui, null, "", "Cancel");
            n += 1;
        },
        .ready => {
            const prepared = job.prepared.?;
            var detail: []const u8 = byteSize(ui.arena, @intCast(@min(prepared.bytes.len, std.math.maxInt(u32))));
            // A profile sheet is a fixed card with no room to spare, so its
            // version of this is the short one.
            if (prepared.width > 0 and prepared.height > 0 and job.target == .note) detail = ui.fmt("{s}, {d} x {d}", .{ detail, prepared.width, prepared.height });
            rows[n] = uploadLine(ui, ui.fmt("{s}  {s}", .{ name, detail }), p.text_primary);
            n += 1;
            rows[n] = uploadNote(ui, uploadWhere(ui, job), p.text_muted);
            n += 1;
            if (prepared.stripped and job.target == .note) {
                rows[n] = uploadNote(ui, "Location and camera details in the file are removed first.", p.text_faint);
                n += 1;
            }
            if (job.message().len > 0) {
                rows[n] = uploadNote(ui, job.message(), p.status_warning_text);
                n += 1;
            }
            if (job.target == .note) {
                rows[n] = ui.el(.textarea, .{
                    .text = model.upload_alt(),
                    .placeholder = "Describe the picture (optional)",
                    .on_input = AppUi.inputMsg(.upload_alt_edit),
                    .height = 34,
                    .semantics = .{ .label = "Picture description" },
                }, .{});
                n += 1;
            }
            rows[n] = uploadButtons(ui, Msg.upload_go, "Upload", "Cancel");
            n += 1;
        },
        .signing => {
            rows[n] = uploadLine(ui, "Waiting for your signer to approve the upload...", p.text_secondary);
            n += 1;
            rows[n] = uploadButtons(ui, null, "", "Cancel");
            n += 1;
        },
        .signed, .sending, .sent => {
            const total = @max(job.progress.total, 1);
            const sent = @min(job.progress.sent.load(.acquire), total);
            const percent: usize = sent * 100 / total;
            const at: usize = @min(job.progress.server.load(.acquire), @max(job.server_count, 1) - 1);
            rows[n] = uploadLine(ui, ui.fmt("Uploading {s} to {s}", .{ name, blossom.serverLabel(job.server(at)) }), p.text_secondary);
            n += 1;
            rows[n] = uploadBar(ui, percent);
            n += 1;
            rows[n] = uploadButtons(ui, null, "", "Cancel");
            n += 1;
        },
        .failed => {
            rows[n] = uploadNote(ui, if (job.message().len > 0) job.message() else "The upload did not work.", p.status_warning_text);
            n += 1;
            // The file read fine and the failure was the network or a server:
            // the same picture can be sent again without choosing it again.
            const sent_ok = if (job.outcome) |o| o == .ok else false;
            const again: ?Msg = if (job.prepared != null and !sent_ok) Msg.upload_retry else null;
            rows[n] = uploadButtons(ui, again, "Try again", "Dismiss");
            n += 1;
        },
    }
    return ui.el(.card, .{
        .padding = 12,
        .style = .{ .background = p.surface_settings_card, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 },
        .semantics = .{ .label = "Picture upload" },
    }, .{
        ui.column(.{ .gap = 8, .grow = 1 }, .{rows[0..n]}),
    });
}

fn uploadLine(ui: *AppUi, text: []const u8, color: canvas.Color) AppUi.Node {
    return ui.paragraph(.{ .wrap = true, .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = menu_scale }});
}

fn uploadNote(ui: *AppUi, text: []const u8, color: canvas.Color) AppUi.Node {
    return ui.paragraph(.{ .wrap = true, .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = mono_hint_scale }});
}

/// A thin bar and the number beside it.
fn uploadBar(ui: *AppUi, percent: usize) AppUi.Node {
    const p = theme.palette;
    const track: f32 = 240;
    const fill = track * @as(f32, @floatFromInt(@min(percent, 100))) / 100.0;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.row(.{ .gap = 0, .width = track, .height = 4 }, .{
            if (fill >= 1)
                ui.el(.panel, .{ .width = fill, .height = 4, .padding = 0.01, .style = .{ .background = p.accent, .radius = 2, .stroke_width = 0 } }, .{})
            else
                ui.spacer(0),
            ui.el(.panel, .{ .width = @max(track - fill, 0.01), .height = 4, .padding = 0.01, .style = .{ .background = p.border_control, .radius = 2, .stroke_width = 0 } }, .{}),
        }),
        hgap(ui, 10),
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = ui.fmt("{d}%", .{percent}), .monospace = true, .scale = mono_meta_scale }}),
    });
}

fn uploadButtons(ui: *AppUi, primary: ?Msg, primary_label: []const u8, cancel_label: []const u8) AppUi.Node {
    return ui.row(.{ .gap = 8, .cross = .center }, .{
        if (primary) |msg|
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = msg }, primary_label)
        else
            ui.spacer(0),
        ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.upload_cancel }, cancel_label),
        ui.spacer(1),
    });
}

/// The label row of a profile field that can take a picture: the name, and on
/// the right the way to upload one. While a job for this field is on screen, the
/// card stands where the text box was.
pub fn profilePictureField(ui: *AppUi, model: *const Model, label: []const u8, value: []const u8, comptime tag: std.meta.Tag(Msg), target: UploadTarget) AppUi.Node {
    const p = theme.palette;
    if (uploadJobFor(target)) |job| {
        return ui.column(.{ .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
            vgap(ui, 5),
            uploadCard(ui, model, job),
        });
    }
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
            ui.spacer(1),
            settingsLink(ui, "Upload...", Msg{ .upload_pick = @intFromEnum(target) }),
        }),
        vgap(ui, 5),
        ui.el(.textarea, .{
            .text = value,
            .placeholder = "https://",
            .on_input = AppUi.inputMsg(tag),
            .on_submit = Msg.profile_save,
            .height = 34,
            .semantics = .{ .label = label },
        }, .{}),
    });
}

/// Settings: the servers pictures go to, and how to change them.
pub fn mediaServersCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const servers = uploadServers();
    const rows = ui.arena.alloc(AppUi.Node, servers.count + 4) catch return ui.spacer(0);
    var n: usize = 0;
    rows[n] = ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
        &.{.{ .text = if (servers.own)
            "A picture goes to the first of these that takes it."
        else
            "You have not published a list, so a picture goes to the first of these that takes it. Adding one publishes your list.", .scale = mono_hint_scale }},
    );
    n += 1;
    rows[n] = vgap(ui, 10);
    n += 1;
    for (0..servers.count) |i| {
        rows[n] = ui.column(.{ .gap = 0 }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = blossom.serverLabel(servers.at(i)), .monospace = true, .scale = mono_row_scale }}),
                ui.spacer(1),
                if (servers.own)
                    ui.el(.list_item, .{
                        .padding = 0.01,
                        .height = 20,
                        .cross = .center,
                        .on_press = Msg{ .blossom_remove = @intCast(i) },
                        .style = .{ .radius = 4 },
                        .semantics = .{ .role = .button, .label = ui.fmt("Remove {s}", .{servers.at(i)}), .focusable = true },
                    }, .{
                        hgap(ui, 4),
                        ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_dim } }, "x"),
                        hgap(ui, 4),
                    })
                else
                    ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = "built in", .monospace = true, .scale = mono_chip_scale }}),
            }),
            vgap(ui, 9),
        });
        n += 1;
    }
    rows[n] = ui.inputGroup(
        .{ .semantics = .{ .label = "Add a media server" } },
        ui.el(.textarea, .{
            .text = model.blossom_draft(),
            .placeholder = "https://",
            .on_input = AppUi.inputMsg(.blossom_edit),
            .on_submit = Msg.blossom_add,
            .height = 30,
        }, .{}),
        ui.inputGroupActions(.{}, .{
            ui.paragraph(
                .{ .wrap = true, .grow = 1, .style = .{ .foreground = if (model.blossom_error != .none) p.status_warning_text else p.text_dim } },
                &.{.{ .text = model.blossom_status(), .scale = mono_meta_scale }},
            ),
            ui.button(.{ .size = .sm, .on_press = Msg.blossom_add }, "Add"),
        }),
    );
    n += 1;
    return settingsCard(ui, .{rows[0..n]});
}

/// What the line under the add field says.
pub fn blossomStatusText(error_kind: BlossomEdit) []const u8 {
    return switch (error_kind) {
        .invalid => "A server address starts with https:// and names a host.",
        .busy => "Your signer is busy. Try again in a moment.",
        .unread => "Plaza has not read your server list yet, so it will not replace it.",
        .full => "Plaza sends to up to 4 servers.",
        .failed => "That did not go through.",
        .none => if (blossomProbeAsking() and !haveOwnBlossomList())
            "Reading your server list..."
        else if (media_servers.g_blossom_saving != 0 and media_servers.g_blossom_saving > media_servers.g_blossom_created_at)
            "Saving..."
        else if (activePubkey() != null and !canWriteBlossomList())
            // Said before the press, as the relay list does: an edit that will not
            // be published must not look as though it will.
            "Plaza has not read your server list yet, so it will not replace it."
        else
            "",
    };
}

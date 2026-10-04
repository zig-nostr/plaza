//! The smaller sheets: name, profile edit, join, address, delete, image viewer, feed options.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const uploads = @import("uploads.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const pickRefusedFor = main.pickRefusedFor;
const AppUi = main.AppUi;
const FreshAsk = main.FreshAsk;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const backControl = main.backControl;
const body_line_height = main.body_line_height;
const bunkerConnecting = main.bunkerConnecting;
const classifySearch = main.classifySearch;
const clipToChars = main.clipToChars;
const hgap = main.hgap;
const join_card_sub_scale = main.join_card_sub_scale;
const join_card_title_scale = main.join_card_title_scale;
const join_label_scale = main.join_label_scale;
const join_sheet_width = main.join_sheet_width;
const join_sub_scale = main.join_sub_scale;
const join_title_scale = main.join_title_scale;
const keyholderMissing = main.keyholderMissing;
const list_row_height = main.list_row_height;
const menu_scale = main.menu_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const name_card_width = main.name_card_width;
const name_title_scale = main.name_title_scale;
const noteExtentEstimate = main.noteExtentEstimate;
const personName = main.personName;
const pressRow = main.pressRow;
const profilePictureField = main.profilePictureField;
const profile_edit_card_width = main.profile_edit_card_width;
const searchBody = main.searchBody;
const search_sheet_width = main.search_sheet_width;
const vgap = main.vgap;
const window_height = main.window_height;

/// The name beat: one optional ask after creating an identity, so the account
/// is not blank. Fully skippable; the remembered intent replays either way.
pub fn nameSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalScrim(ui, "Name", .name_skip, ui.el(.dialog, .{
        .width = name_card_width,
        .on_dismiss = .name_skip,
        .semantics = .{ .label = "Name" },
    }, .{
        modalCard(ui, name_card_width, ui.column(.{ .grow = 1, .gap = 10, .padding = 16 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Want a name on it?", .weight = .bold, .scale = name_title_scale }},
            ),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = "Shown with your notes. Change it any time.", .scale = join_sub_scale }},
            ),
            ui.el(.textarea, .{
                .text = model.name_draft(),
                .placeholder = "A name people will see",
                .on_input = AppUi.inputMsg(.name_edit),
                .autofocus = true,
                .on_submit = .name_save,
                .height = 38,
                .style = .{ .background = p.surface_input, .border = p.border_focus, .radius = 9, .stroke_width = 1.5 },
            }, .{}),
            ui.row(.{ .gap = 0, .cross = .center }, .{
                // Never disabled. Blank is a valid answer to "want a name on
                // it?", and it means the same thing as Skip, so Done takes it
                // and moves on rather than sitting there greyed out while the
                // reader wonders what is wrong with an empty field.
                // Painted by a `.panel`, pressed by the row around it. A
                // `.list_item` given a background draws none, so the first
                // version of this button was white text on the card's own
                // dark surface: present, pressable, and unreadable.
                pressRow(ui, .{
                    .grow = 1,
                    .gap = 0,
                    .on_press = Msg.name_save,
                    .semantics = .{ .role = .button, .label = "Done", .focusable = true },
                }, .{
                    ui.el(.panel, .{
                        .grow = 1,
                        .padding = 0.01,
                        .style = .{ .background = p.accent, .radius = 8 },
                    }, .{
                        ui.row(.{ .height = 32, .cross = .center, .main = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .style = .{ .foreground = p.on_accent } },
                                &.{.{ .text = "Done", .weight = .medium, .scale = menu_scale }},
                            ),
                        }),
                    }),
                }),
                hgap(ui, 12),
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .height = list_row_height,
                    .on_press = Msg.name_skip,
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Skip", .focusable = true },
                }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_muted } },
                        &.{.{ .text = "Skip", .underline = true, .scale = menu_scale }},
                    ),
                }),
            }),
        })),
    }));
}

/// The Edit profile sheet. No mock draws it, so it is the modal-card recipe with
/// three fields; flagged in the PR for review.
///
/// The status line under the fields is the point of the sheet, not decoration: a
/// profile is REPLACEABLE, so saving rewrites the whole thing, and the sheet must
/// be able to say whether it actually has the reader's current profile to rewrite.
pub fn profileSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const status = model.profile_status();

    // The lines under the fields, only the ones that have something to say. A
    // column charges its gap for every child, an empty spacer included, so the
    // three that are usually empty used to cost the sheet 30pt of nothing.
    var notes: [3]AppUi.Node = undefined;
    var notes_n: usize = 0;
    var notes_lines: usize = 0;
    const lines: [3]struct { text: []const u8, color: canvas.Color } = .{
        .{ .text = model.profile_invalid(), .color = p.status_warning_text },
        .{ .text = if (uploads.g_profile_upload_unsaved) "The new picture is not published until you press Save." else "", .color = p.text_dim },
        .{ .text = status, .color = if (model.profile_stage == .failed) p.status_warning_text else p.text_dim },
    };
    for (lines) |line| {
        if (line.text.len == 0) continue;
        notes[notes_n] = ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = line.color } },
            &.{.{ .text = line.text, .scale = mono_hint_scale }},
        );
        notes_n += 1;
        notes_lines += profileNoteLines(line.text);
    }

    var kids: [6]AppUi.Node = undefined;
    var n: usize = 0;
    kids[n] = ui.paragraph(
        .{ .style = .{ .foreground = p.text_primary } },
        &.{.{ .text = "Edit profile", .weight = .bold, .scale = 1.15 }},
    );
    n += 1;
    // The fields scroll inside a box the sheet can always hold, so Close and
    // Save stay inside the sheet and on screen at the window's smallest height.
    // A note under the fields takes its room out of the box, not the window.
    const notes_room: f32 = @as(f32, @floatFromInt(notes_n)) * profile_sheet_gap + @as(f32, @floatFromInt(notes_lines)) * profile_note_line_height;
    kids[n] = ui.scroll(.{ .height = @max(profile_fields_height - notes_room, profile_fields_min_height) }, .{
        ui.column(.{ .gap = profile_sheet_gap }, .{
            // The introduction gives way to whatever else needs the room. Seven
            // fields, three lines of introduction and a two-line status do not fit
            // a window at its minimum height: the button row was drawn below the
            // bottom edge, so Try again and Save could not be pressed in exactly
            // the states that need them. Nor while a picture is being added: the
            // card that takes the field's place is taller than the field, nor
            // while a refused Upload says why beside its field.
            if (status.len == 0 and (if (uploads.g_upload) |job| job.target == .note else true) and
                pickRefusedFor(.avatar) == null and pickRefusedFor(.banner) == null)
                profileIntro(ui)
            else
                ui.spacer(0),
            profileField(ui, "Name", model.profile_name(), "A name people will see", .profile_name_edit),
            profileField(ui, "About", model.profile_about(), "A line about you", .profile_about_edit),
            profilePictureField(ui, model, "Picture", model.profile_picture(), .profile_picture_edit, .avatar),
            profilePictureField(ui, model, "Banner", model.profile_banner(), .profile_banner_edit, .banner),
            profileField(ui, "Website", model.profile_website(), "https://", .profile_website_edit),
            // The one with a consequence. `lud16` is how NIP-57 finds somebody's
            // LNURL callback, so an account set up only here could not be zapped
            // by anyone, in any client, until its owner opened something else.
            profileField(ui, "Lightning address", model.profile_lud16(), "you@wallet.example", .profile_lud16_edit),
            profileField(ui, "NIP-05 identifier", model.profile_nip05(), "you@example.com", .profile_nip05_edit),
        }),
    });
    n += 1;
    for (notes[0..notes_n]) |note| {
        kids[n] = note;
        n += 1;
    }
    kids[n] = ui.row(.{ .gap = 8, .cross = .center }, .{
        ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = Msg.close_profile_edit }, "Close"),
        ui.spacer(1),
        if (model.profile_can_retry())
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.profile_retry }, "Try again")
        else
            ui.spacer(0),
        if (model.profile_can_retry()) hgap(ui, 8) else ui.spacer(0),
        ui.button(.{
            .size = .sm,
            .variant = .primary,
            .disabled = !model.profile_can_save(),
            .on_press = Msg.profile_save,
        }, if (model.profile_confirm_new) "Publish first profile" else "Save"),
    });
    n += 1;

    return modalScrim(ui, "Edit profile", Msg.close_profile_edit, ui.el(.dialog, .{
        .width = profile_edit_card_width,
        .on_dismiss = Msg.close_profile_edit,
        .semantics = .{ .label = "Edit profile" },
    }, .{
        // The card pads itself. A second 20 inside it was 44 on every side,
        // and those 40 rows were what pushed the buttons off the card.
        modalCard(ui, profile_edit_card_width, ui.column(.{ .grow = 1, .gap = profile_sheet_gap }, .{kids[0..n]})),
    }));
}

const profile_sheet_gap: f32 = 10;
/// The fields' box, sized so the whole sheet fits the 632pt a modal gets inside
/// the window's smallest height (680, less the scrim's 24 above and below):
/// 632 less the card's 24 on both sides, the 21pt title, two 10pt gaps and the
/// 28pt button row. Every field but the last shows whole; the rest is a short
/// scroll away.
pub const profile_fields_height: f32 = 514;
/// Never less than this, however much the notes under the fields say: two
/// fields stay in view to type in.
const profile_fields_min_height: f32 = 140;
const profile_note_line_height: f32 = 18;

/// How many lines a note under the fields wraps to in the sheet's column, at
/// about 52 characters to a line of the hint register.
fn profileNoteLines(text: []const u8) usize {
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @max(1, (chars + 51) / 52);
}

fn profileIntro(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = theme.palette.text_faint } },
        &.{.{ .text = "Everything this app can read from a profile, it can now write. Anything else your other clients put there is kept exactly as it is.", .scale = mono_hint_scale }},
    );
}

/// One labelled field in the sheet.
fn profileField(ui: *AppUi, label: []const u8, value: []const u8, placeholder: []const u8, comptime tag: std.meta.Tag(Msg)) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
        vgap(ui, 5),
        ui.el(.textarea, .{
            .text = value,
            .placeholder = placeholder,
            .on_input = AppUi.inputMsg(tag),
            // REQUIRED, and not decoration: a textarea with on_input but no
            // on_submit renders, focuses, advertises set_text, and accepts
            // nothing. It reads as a live field and is inert.
            .on_submit = Msg.profile_save,
            .height = 34,
            .semantics = .{ .label = label },
        }, .{}),
    });
}
/// A small confirming toast, bottom center, retired by the tick.
pub fn toastOverlay(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .padding = 24 }, .{
        ui.row(.{ .padding = 10, .style = .{ .background = p.surface_toast, .border = p.border_modal, .radius = 10, .stroke_width = 1 } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_body } }, model.toast_text()),
        }),
    });
}

pub fn joinSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    return modalScrim(ui, "Join", .close_join, ui.el(.dialog, .{
        .width = join_sheet_width,
        .on_dismiss = .close_join,
        .semantics = .{ .label = "Join" },
    }, .{
        if (model.bunker_mode) bunkerCard(ui, model) else joinLadderCard(ui, model),
    }));
}

/// The field that finds a person and takes an address.
///
/// It began as the place to paste an address (Plaza could put one on the
/// clipboard and had no way to take one back), and it is also where somebody
/// says who they mean. One field does both because the two never collide: a
/// string that starts `npub1` or has an `@` between two names is an address, and
/// anything else is a name. What Enter will do is said on the button, so the
/// reader is never guessing which of the two they have got.
pub fn addressSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const kind = classifySearch(model.address_draft());
    return modalScrim(ui, "Search", .close_address, ui.el(.dialog, .{
        .width = search_sheet_width,
        .on_dismiss = .close_address,
        .semantics = .{ .label = "Search" },
    }, .{
        modalCard(ui, search_sheet_width, ui.column(.{ .gap = 12 }, .{
            ui.row(.{ .cross = .center, .gap = 6 }, .{
                backControl(ui, "Back", .close_address),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = "Search", .weight = .bold, .scale = 1.3 }},
                ),
            }),
            ui.el(.textarea, .{
                .text = model.address_draft(),
                .placeholder = "A name, an npub or nprofile, name@domain, or a link",
                .on_input = AppUi.inputMsg(.address_edit),
                .autofocus = true,
                .on_submit = .address_submit,
                // Enter submits, as it does in every search box. Shift+Enter is
                // the newline, which nothing here has any use for. A pasted
                // address is long enough to wrap, so the field holds two lines.
                .submit_on_enter = true,
                .height = 56,
                .semantics = .{ .label = "Search" },
            }, .{}),
            // The refusal replaces the hint rather than sitting under it: two
            // lines where one is stale reads as the app disagreeing with itself.
            if (model.address_status().len > 0)
                ui.text(
                    .{ .size = .sm, .wrap = true, .style = .{ .foreground = if (model.address_error == .none) p.text_muted else p.status_warning_text } },
                    model.address_status(),
                )
            else
                ui.spacer(0),
            searchBody(ui, kind),
            ui.button(.{ .variant = .primary, .disabled = model.address_empty() or kind == .key, .on_press = .address_submit }, model.address_action()),
            vgap(ui, 5),
        })),
    }));
}

/// Why the sheet appeared, in the reader's own terms: the thing they reached for
/// is waiting, and named where naming it is possible.
///
/// A note that has scrolled out of the loaded window falls back to the plain
/// sentence rather than guessing, and a person whose kind:0 has not arrived reads
/// as their short npub, which is what every other surface in the app calls them
/// until it knows better.
pub fn pendingText(ui: *AppUi, model: *const Model) []const u8 {
    return switch (model.pending) {
        .none => "",
        .post => "Your note is waiting.",
        .reply => "Your reply is waiting.",
        // Clipped, because a display name is a stranger's string with no length
        // in it and no alphabet either. The pill wraps as well (see intentPill):
        // a codepoint cap bounds COUNT, not WIDTH, and fourteen full-width CJK
        // characters are about twice fourteen Latin ones, so the clip alone still
        // overran the card in some scripts.
        .like => |id| if (model.noteById(id)) |note|
            std.fmt.allocPrint(ui.arena, "Your like on {s}'s note is waiting.", .{personLabel(ui, note.author())}) catch "Your like is waiting."
        else
            "Your like is waiting.",
        .repost => |id| if (model.noteById(id)) |note|
            std.fmt.allocPrint(ui.arena, "Your repost of {s}'s note is waiting.", .{personLabel(ui, note.author())}) catch "Your repost is waiting."
        else
            "Your repost is waiting.",
        .follow => |pk| std.fmt.allocPrint(ui.arena, "Following {s} is waiting.", .{personLabel(ui, personName(ui, pk))}) catch "Your follow is waiting.",
    };
}

/// A person's name, short enough for one line of a pill.
///
/// The npub fallback is passed through UNCLIPPED. It is already an abbreviation,
/// `npub1abcdefghi…wxyz5`, and its whole job is the tail: clipping it to fourteen
/// codepoints ate three of the five identifying characters at the end and left
/// something that looks specific and is not.
fn personLabel(ui: *AppUi, name: []const u8) []const u8 {
    _ = ui;
    // The abbreviated npub carries an ellipsis, and it is the only thing in this
    // app that does. Substring, not scalar: the character is three bytes.
    if (std.mem.indexOf(u8, name, "…") != null) return name;
    return clipToChars(name, 14, 48);
}

/// The glyph for the verb that opened the sheet: the reader sees what they
/// reached for before they read a word.
///
/// A switch rather than a name looked up from a table, because both icon
/// builders take their name at COMPTIME (that is what compile-checks it), so a
/// glyph chosen at runtime has to be chosen as a whole node.
fn pendingGlyph(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const size = 11;
    return switch (model.pending) {
        .none, .post => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "edit"),
        .reply => ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "reply"),
        .like => ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = p.status_like } }, "like"),
        .repost => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.status_success } }, "repeat"),
        .follow => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "plus"),
    };
}

/// What the reader reached for, as a pill above the question.
fn intentPill(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{ .background = p.surface_chip, .border = p.border_hairline, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 10),
                vgap(ui, 22),
                pendingGlyph(ui, model),
                hgap(ui, 6),
                // Bounded AND wrapping. `wrap` on its own does nothing to a
                // paragraph that is a plain flow child of a row (it takes its
                // intrinsic width and lays out past the card), and a clip on its
                // own bounds characters rather than pixels. Both, so no name in
                // any script can push this line out of the sheet.
                ui.column(.{ .grow = 1, .gap = 0 }, .{
                    ui.paragraph(
                        .{ .wrap = true, .style = .{ .foreground = p.text_muted_alt } },
                        &.{.{ .text = model.pending_text(ui), .scale = join_sub_scale }},
                    ),
                }),
                hgap(ui, 10),
            }),
        }),
        // The pill is as wide as its words and no wider, so the row it sits in
        // takes the slack rather than the pill stretching across the card.
        ui.spacer(1),
    });
}

/// One rung of the ladder: a glyph, what it is, and what it costs you.
///
/// `filled` is the recommended one, and there is exactly one. The other two are
/// outlines with a chevron, which is the shape this app uses everywhere else for
/// "this leads somewhere".
///
/// A null `press` is a rung this install cannot climb (see `keyholderMissing`).
/// It keeps the card's geometry so the ladder does not jump, and gives up
/// everything that says "press me": the accent fill, the chevron, the button
/// role, the focus stop. A rung that looks identical and does nothing is the
/// exact failure this whole change is about, so it must not merely stop working,
/// it has to stop LOOKING like it works.
fn joinCard(ui: *AppUi, comptime glyph: []const u8, comptime app: bool, title: []const u8, sub: []const u8, press: ?Msg, filled: bool) AppUi.Node {
    const p = theme.palette;
    const live = press != null;
    const ink = if (filled) p.on_accent else if (live) p.text_body_strong else p.text_muted;
    const sub_ink = if (filled) p.text_dim_on_light else p.text_muted;
    // The press is on the ROW and the paint is on a `.panel` inside it. A
    // `.list_item` carrying a background draws nothing at all (the same rule
    // `modalCard` is built around), so the first version of this card had the
    // recommended rung rendering as invisible white-on-black text.
    return pressRow(ui, .{
        .gap = 0,
        .on_press = press,
        .semantics = .{ .role = if (live) .button else .text, .label = title, .focusable = live },
    }, .{
        ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{
                .background = if (filled) p.accent else p.surface_card,
                .border = if (filled) p.accent else p.border_control,
                .radius = 11,
                .stroke_width = 1,
            },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 13),
                if (app)
                    ui.appIcon(.{ .width = 16, .height = 16, .style = .{ .foreground = ink } }, glyph)
                else
                    ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = ink } }, glyph),
                hgap(ui, 11),
                ui.column(.{ .grow = 1, .gap = 0 }, .{
                    vgap(ui, 11),
                    ui.paragraph(
                        .{ .style = .{ .foreground = ink } },
                        &.{.{ .text = title, .weight = .medium, .scale = join_card_title_scale }},
                    ),
                    vgap(ui, 3),
                    ui.paragraph(
                        .{ .wrap = true, .style = .{ .foreground = sub_ink } },
                        &.{.{ .text = sub, .scale = join_card_sub_scale }},
                    ),
                    vgap(ui, 11),
                }),
                hgap(ui, 11),
                // Only on the rungs that lead to another step. The filled card
                // finishes here: pressing it makes a key. A dead rung leads
                // nowhere at all, so it gets no chevron either.
                if (filled or !live) ui.spacer(0) else ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "chevron-right"),
                hgap(ui, 13),
            }),
        }),
    });
}

/// The mono section labels over each half of the ladder.
fn joinLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.paragraph(
        .{ .style = .{ .foreground = p.text_faint_alt } },
        &.{.{ .text = text, .monospace = true, .weight = .medium, .scale = join_label_scale }},
    );
}

/// The shared modal card: the SDK `.card` element paints the rounded, bordered
/// surface (a plain column does not paint its background at all), holding a
/// single content column so the sheet reads as a raised, bordered panel.
///
/// The press it absorbs is load-bearing, not decoration: the sheet around it is
/// a full-window dialog that closes when pressed, and a `.card` claims no press
/// of its own, so without this a click on the sheet's own background walks past
/// the card to the dialog and closes the sheet mid-use. See `Msg.absorb_press`.
/// The full-window dim behind a modal, and the press target that closes it.
///
/// The SDK owns where a `.dialog` sits: since 0.9.2 a dialog, drawer or sheet is
/// placed against the ROOT surface and centred there, its proposed frame
/// discarded, so `.grow = 1` on one does nothing at all. Plaza used to be the
/// dialog AND the backdrop in one element, which meant the upgrade quietly
/// shrank every scrim to a 420pt box: the dim stopped covering the window and a
/// press outside that box stopped closing anything.
///
/// So the two jobs are two elements now. This is the backdrop: a plain panel
/// that fills the window, carries the dim, and closes on a press. The `.dialog`
/// goes inside it and is nothing but the card, which is the shape the SDK's own
/// examples use.
///
/// `.grow = 1` here is belt and braces and I checked: removing it keeps every
/// test green, because the layer stack these sheets are mounted in stretches its
/// children anyway. It stays because a backdrop that only fills the window when
/// its parent happens to stretch it is one reparenting away from the bug this
/// function exists to fix. The dismiss press is the part a probe does catch.
pub fn modalScrim(ui: *AppUi, label: []const u8, dismiss: Msg, child: AppUi.Node) AppUi.Node {
    return ui.el(.panel, .{
        .grow = 1,
        .on_press = dismiss,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = label },
    }, .{child});
}

/// What a `.card` insets its content by on every side.
const modal_card_padding: f32 = 24;

pub fn modalCard(ui: *AppUi, width: f32, inner: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.card, .{
        .width = width,
        .on_press = Msg.absorb_press,
        .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 },
    }, .{inner});
}

fn joinHeading(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .style = .{ .foreground = theme.palette.text_primary } },
        &.{.{ .text = "How do you want to join?", .weight = .bold, .scale = join_title_scale }},
    );
}

fn joinSubheading(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = theme.palette.text_muted } },
        &.{.{ .text = "Everything here is signed with a key of your own, not an account someone holds for you.", .scale = join_sub_scale }},
    );
}

/// The join ladder: three ways in, most confident first, always the way back.
fn joinLadderCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Gaps, not hand-placed spacers, and the card's own padding rather than a
    // second one inside it. The sheet used to inset itself with a vgap/hgap
    // frame around a gap:0 column, so every space in it was a separate number
    // nobody could see next to its neighbours: 16, 6, 13, 6, 7, 13, 8, 13, 16.
    //
    // It then had `.padding = 20` on top of the `.card`'s own 24, which is a
    // 44pt inset on a 420pt sheet, and `.grow = 1` stretched the column past
    // what its children needed so the last row overflowed 18pt into the bottom
    // padding: 50pt of air above the title and 26 below the way out. The card
    // pads itself; this column only says how far apart its groups sit.
    return modalCard(ui, join_sheet_width, ui.column(.{ .gap = 16 }, .{
        // Two shapes rather than one with a `spacer(0)` in it. A zero-size
        // child is still a child, so the gap above it was paid whether or not
        // there was a pill to separate: 6pt of air on top of the card's own
        // padding, which is why the title sat lower than the rungs sat left.
        if (model.pending.waiting())
            ui.column(.{ .gap = 6 }, .{
                intentPill(ui, model),
                joinHeading(ui),
                joinSubheading(ui),
            })
        else
            ui.column(.{ .gap = 6 }, .{
                joinHeading(ui),
                joinSubheading(ui),
            }),
        ui.column(.{ .gap = 8 }, .{
            joinLabel(ui, "NEW HERE"),
            // Making a key means the keyholder daemon making it, so with no
            // keyholder installed there is no route to a new identity at all:
            // this rung is not degraded, it is impossible. Say that, and say
            // what fixes it, rather than leaving the app's primary call to
            // action sitting there swallowing presses.
            //
            // The WHY goes under the card, not in it. A rung's subtitle is one
            // line: the row that holds it centres a column it has already been
            // sized against, so a subtitle that wraps to three lines runs past
            // the card's own bottom edge and paints the last line half outside
            // it. The tree cannot see that and every structural assertion
            // passed over it. Only the frames say so. Down here it is a plain
            // flow child, where wrapping is bounded and behaves.
            if (keyholderMissing())
                joinCard(ui, "plus", false, "Create your identity", "Not possible in this copy of Plaza.", null, false)
            else
                joinCard(ui, "plus", false, "Create your identity", "Ready in seconds. Nothing to write down.", .join_create, true),
            if (keyholderMissing())
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                    &.{.{ .text = "Notary, the part of Plaza that holds your key, is missing from this install, so Plaza cannot make one. Reinstalling Plaza fixes it.", .scale = join_card_sub_scale }},
                )
            else
                ui.spacer(0),
        }),
        ui.column(.{ .gap = 8 }, .{
            joinLabel(ui, "ALREADY ON NOSTR"),
            // With no keyholder there is nowhere for a key to go, and this rung
            // says so instead of offering a field.
            //
            // It used to fall back to pasting into Plaza, and the subtitle said
            // so honestly. That fallback is gone: Plaza has no field that can
            // hold a secret key, so the rung led to a screen that refuses every
            // key it is given. A dead end with an encouraging label on it is
            // worse than a disabled rung.
            if (keyholderMissing())
                joinCard(ui, "download", false, "Bring your key", "Not possible in this copy of Plaza.", null, false)
            else
                joinCard(ui, "download", false, "Bring your key", "Opens Notary. Plaza itself never sees it.", .open_notary_import, false),
            // The other answer to the same question, and the one that stays
            // here: your key is somewhere else already, so nothing has to move.
            joinCard(ui, "notary", true, "Use your own signer", "Already have one? Paste its bunker link.", .open_bunker, false),
        }),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = list_row_height,
                .on_press = Msg.close_join,
                .style = .{ .quiet_hover = true },
                .autofocus = true,
                .semantics = .{ .role = .button, .label = "Keep browsing", .focusable = true },
            }, .{
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_secondary } },
                    &.{.{ .text = "Keep browsing", .weight = .medium, .underline = true, .scale = menu_scale }},
                ),
            }),
            ui.spacer(1),
        }),
        // The way out is a list item, which carries its own slack for the press
        // target, and that slack is not padding: it left the underline sitting
        // 6pt off the card's edge while every other side had 24. This is the
        // difference, measured from a screenshot rather than guessed.
        vgap(ui, 2),
    }));
}

/// The focused bunker step: the user already chose to use their own signer, so
/// this is one field, not the whole ladder again. Paste the link, connect.
fn bunkerCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalCard(ui, join_sheet_width, ui.column(.{ .gap = 12 }, .{
        ui.row(.{ .cross = .center, .gap = 6 }, .{
            backControl(ui, "Back", .close_bunker),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Connect your signer", .weight = .bold, .scale = 1.3 }},
            ),
        }),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Paste the bunker link your signer gave you. Your key stays in your signer, Plaza never sees it."),
        ui.el(.textarea, .{
            .text = model.login_draft(),
            .placeholder = "bunker://…",
            .on_input = AppUi.inputMsg(.login_edit),
            .autofocus = true,
            .on_submit = .login_submit,
            .height = 56,
        }, .{}),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, model.login_status()),
        ui.button(.{ .variant = .primary, .disabled = model.login_empty() or bunkerConnecting(), .on_press = .login_submit }, if (bunkerConnecting()) "Connecting…" else "Connect"),
        // Same as the ladder's way out: a button's own press slack is not
        // padding, so without this the Connect button sits 7pt off the card's
        // edge against 24 on the other three sides.
        vgap(ui, 5),
    }));
}
/// The one question this app asks before doing something it cannot undo.
///
/// The wording is the part worth getting right. A deletion is a REQUEST: relays
/// may honour it or ignore it, and the note may already sit on relays that will
/// never see the request. Saying "deleted" would be a promise Nostr cannot
/// keep, so this says what actually happens and lets the reader decide with
/// that in front of them.
pub fn deleteConfirm(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .padding = 20,
        .on_press = .delete_note_cancel,
        .semantics = .{ .label = "Delete this note?" },
    }, .{
        ui.column(.{ .gap = 12, .cross = .stretch }, .{
            ui.text(.{}, "Delete this note?"),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = "This asks the relays you publish to drop it. Most will. Any that already passed it on, or that ignore the request, may keep serving it, so this cannot be undone and cannot be guaranteed." }},
            ),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .delete_note_cancel }, "Cancel"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .variant = .destructive, .on_press = .delete_note_confirm }, "Delete"),
            }),
        }),
    });
}

/// The question asked before a list is started from nothing.
///
/// Every relay Plaza reads from has finished and none sent this list, which is
/// the strongest thing the app can know and still not proof: the list may sit on
/// a relay Plaza has never dialed. So it asks the one party who can know, and says
/// what a wrong yes costs. A list is replaceable, and the new one would hold only
/// what this press adds.
pub fn freshListConfirm(ui: *AppUi, ask: FreshAsk) AppUi.Node {
    const p = theme.palette;
    const list = switch (ask.action) {
        .follow => "follow list",
        .mute => "mute list",
        .bookmark, .bookmark_privately => "bookmark list",
        .add_media_server => "media server list",
    };
    const holds = switch (ask.action) {
        .follow => "this one person",
        .mute => "this one person",
        .bookmark, .bookmark_privately => "this one note",
        .add_media_server => "this one server",
    };
    // A set width, and the panel drawn by a card that pads itself around one
    // column, like the join sheet. The dialog sizes what it holds as if a
    // paragraph were a single line, so a bare dialog (and then a card in one)
    // kept a one-line height while the text wrapped to five, and the buttons
    // fell out of the bottom of the box. So the card is given its height: the
    // lines the text wraps to at the inner width, priced a little wider per
    // character than the feed prices a note body so it errs toward air, plus
    // the title, the buttons and the gaps between them.
    const inner = join_sheet_width - 2 * modal_card_padding;
    const text = ui.fmt("None of your relays has a {s} for you. If you already have one somewhere Plaza has not looked, a new one would replace it with a list holding only {s}. Go on only if this account is new, or you know it has no {s}.", .{ list, holds, list });
    const lines = @max(1, @ceil(@as(f32, @floatFromInt(text.len)) / @floor(inner / 8)));
    const height = 2 * modal_card_padding + 18 + 12 + lines * body_line_height + 12 + 28;
    return modalScrim(ui, "Start a new list?", .fresh_list_cancel, ui.el(.dialog, .{
        .width = join_sheet_width,
        .on_dismiss = .fresh_list_cancel,
        .semantics = .{ .label = "Start a new list?" },
    }, .{
        ui.el(.card, .{
            .width = join_sheet_width,
            .height = height,
            .on_press = Msg.absorb_press,
            .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 },
        }, .{ui.column(.{ .gap = 12 }, .{
            ui.text(.{}, ui.fmt("Start a new {s}?", .{list})),
            ui.paragraph(
                .{ .wrap = true, .width = inner, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = text }},
            ),
            ui.row(.{ .width = inner, .cross = .center, .gap = 8 }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .fresh_list_cancel }, "Cancel"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .variant = .destructive, .on_press = .fresh_list_confirm }, "Start a new list"),
            }),
        })}),
    }));
}

/// The expanded picture, filling the window over the feed. The registry decodes
/// at most 512 pixels on a side, so rather than upscale a small copy into a
/// blur, this shows it as large as it honestly goes and offers the
/// full-resolution original in the browser. Pressing the backdrop closes it,
/// which also stops presses reaching the feed underneath.
pub fn imageViewer(ui: *AppUi, note: *const Note, index: u8) AppUi.Node {
    // WHICH picture, which the viewer used to have no opinion about. The
    // gallery cell dispatches the index it was drawn for and the update stores
    // it, and then this function was called with the note alone, so the index
    // was written twice and read nowhere. `media_id()` and `imageUrl()` are
    // both index 0, so every cell in a gallery opened the first picture.
    //
    // Clamped rather than trusted: the model outlives a rebuild, so a note that
    // came back from a relay with fewer pictures than the one that was pressed
    // would index past the end.
    const i: u8 = if (index < note.imageCount()) index else 0;
    const image_id = note.mediaIdAt(i);
    // A dialog, not a bare column: modal surfaces paint their own opaque
    // surface and always claim their own input, so the feed underneath neither
    // shows through nor scrolls, and Escape or a click outside closes it.
    // Stacking kinds layer their children, so the contents go in a column.
    // A PANEL rather than a dialog, and it is the one modal here that is not a
    // card. A picture wants the whole window; a `.dialog` since 0.9.2 is centred
    // at its preferred size inside a 24pt margin, which would frame the viewer
    // with a border of feed showing around it. The cost is Escape: dismissal is
    // a modal-surface event, so it goes with the dialog. A press anywhere still
    // closes, which is how the viewer was mostly used anyway.
    return ui.el(.panel, .{
        .grow = 1,
        .padding = 16,
        .on_press = .close_image,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Expanded image" },
    }, .{
        ui.column(.{ .grow = 1, .gap = 12, .cross = .stretch }, .{
            // The picture needs a definite box: an image is a leaf with no
            // intrinsic size, so it draws nothing unless a stretching parent
            // hands it one (a centred column collapses its width to zero).
            ui.row(.{ .grow = 1, .cross = .stretch }, .{
                if (image_id != 0) blk: {
                    var node = ui.image(.{
                        .image = image_id,
                        .grow = 1,
                        .semantics = .{ .label = "Expanded image" },
                    });
                    node.widget.image_fit = .contain;
                    break :blk node;
                } else ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Still loading…"),
            }),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .close_image }, "Close"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg{ .open_url = note.imageAt(i).url() } }, "Open original"),
            }),
        }),
    });
}

/// The one options value both `virtualWindow` and `virtualList` read. The MODEL
/// owns the notes; the runtime only ever sees how many there are, an estimate
/// per row, and the window it asked for.
pub fn feedOptions(model: *const Model) AppUi.VirtualListOptions {
    return .{
        .id = "feed",
        .item_count = model.notes_len,
        // Variable-extent mode: cards are as tall as their wrapped text and
        // their picture. The estimate prices unbuilt rows; the engine patches in
        // measured heights as rows mount, and anchors the viewport so those
        // corrections never move what the reader is looking at.
        .item_extent = 0,
        .extent_estimate = noteExtentEstimate,
        .extent_context = model,
        // No gap between rows: the hairline under each row is the separation,
        // so a border can mean something (a quote, a reply) and rows do not
        // float apart with the divider lost in the space.
        .gap = 0,
        // No list inset: the row inset was narrower than the reading column, so
        // the column overflowed it on the right (flush) while the left inset read
        // as a gap. At 0 the centered reading column sits symmetric in the feed.
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        // Only bare builds (tests, previews) read this: under the app the
        // runtime supplies the real viewport. Without it a test resolves an
        // empty window and renders no rows at all.
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Feed" },
        .on_reach_end = .load_older,
    };
}

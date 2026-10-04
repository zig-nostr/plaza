//! The settings sheet and the relay card.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const hiding = @import("hiding.zig");
const relay_conn = @import("relay_conn.zig");
const relay_table = @import("relay_table.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Conn = main.Conn;
const Model = main.Model;
const Msg = main.Msg;
const RelayEntry = main.RelayEntry;
const accountHasName = main.accountHasName;
const accountName = main.accountName;
const authBadgeText = main.authBadgeText;
const authRowNote = main.authRowNote;
const authSlotReset = main.authSlotReset;
const clearRelayRtt = main.clearRelayRtt;
const forgetRelaySeen = main.forgetRelaySeen;
const hgap = main.hgap;
const hideables = main.hideables;
const lockRelayTable = main.lockRelayTable;
const max_relays = main.max_relays;
const meAvatar = main.meAvatar;
const mediaServersCard = main.mediaServersCard;
const menu_scale = main.menu_scale;
const meta_scale = main.meta_scale;
const mono_badge_scale = main.mono_badge_scale;
const mono_chip_scale = main.mono_chip_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const noteRelayRemoved = main.noteRelayRemoved;
const npubShort = main.npubShort;
const relayAt = main.relayAt;
const relayBadgeText = main.relayBadgeText;
const relayCount = main.relayCount;
const relayRttMs = main.relayRttMs;
const relaySlots = main.relaySlots;
const relaySuggestionCopy = main.relaySuggestionCopy;
const relaySuggestionCount = main.relaySuggestionCount;
const relayUrlEql = main.relayUrlEql;
const scope_title_scale = main.scope_title_scale;
const setRelayStatus = main.setRelayStatus;
const settings_card_radius = main.settings_card_radius;
const settings_column_width = main.settings_column_width;
const settings_content_width = main.settings_content_width;
const settings_header_height = main.settings_header_height;
const settings_label_gap = main.settings_label_gap;
const settings_section_gap = main.settings_section_gap;
const settings_title_scale = main.settings_title_scale;
const signerIsHealthy = main.signerIsHealthy;
const signerStatus = main.signerStatus;
const unlockRelayTable = main.unlockRelayTable;
const vgap = main.vgap;

/// Settings, built in Zig. It was markup until the relay list needed a row that
/// carries its own index into three different messages, which a binding cannot
/// express: the same wall the feed hit. Cards below read top to bottom the way
/// the screen does.
///
/// It is a SHEET over the feed rather than a screen instead of it. As a screen
/// it had two faults that were really one fault: a 440 column centred on a bare
/// window reads as a modal that forgot to be one, and the grey behind that
/// column was a panel stretched by the scroll viewport, so it stopped dead at
/// the window's height and everything past the fold sat on bare black. A card
/// with the scroll INSIDE it cannot do that: the surface is the card's own, and
/// the scroll is bounded by it rather than the other way round.
pub fn settingsSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Exactly the number of `sections[n] =` lines below. It was full when this
    // screen grew a section, and the bounds check is what said so. Eight with
    // the media servers; an oversize array is legal and a lie.
    var sections: [8]AppUi.Node = undefined;
    var n: usize = 0;

    sections[n] = identitySection(ui, model);
    n += 1;
    sections[n] = settingsSection(
        ui,
        "RELAYS",
        "reads & writes route automatically · NIP-65",
        relayCard(ui, model),
    );
    n += 1;
    if (!model.is_guest()) {
        sections[n] = settingsSection(ui, "MEDIA SERVERS", "where pictures you add are uploaded", mediaServersCard(ui, model));
        n += 1;
    }
    sections[n] = settingsSection(ui, "APPEARANCE", "", appearanceCard(ui));
    n += 1;
    sections[n] = settingsSection(ui, "FEED", "", feedCard(ui, model));
    n += 1;
    sections[n] = settingsSection(ui, "NOTES", "what each one shows · what the feed stops asking for", notesCard(ui, model));
    n += 1;
    sections[n] = logoutSection(ui, model);
    n += 1;
    sections[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = model.version_line(), .scale = mono_hint_scale }}),
    });
    n += 1;

    // A PAGE, not a modal, and the reason is measured rather than stylistic.
    //
    // A modal is a translucent scrim across the whole window. Anything that
    // changes underneath one has to be repainted along with the scrim over it,
    // so every frame of scrolling inside a sheet repaints the entire window and
    // the cost grows with the window. On a 1600x1000 window, presenting a frame
    // took 117ms with settings open as a sheet and 18ms with a thread open,
    // which is the same screen area drawn as an opaque level. The feed alone was
    // 17ms. Eight frames a second against sixty, for a dimmed backdrop.
    //
    // Threads and profiles have always been opaque full-screen levels and have
    // always scrolled properly. This is settings joining them.
    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Settings" },
    }, .{
        settingsHeader(ui),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        ui.scroll(.{ .grow = 1, .value = model.settings_scroll_y, .on_scroll = AppUi.scrollMsg(.settings_scrolled) }, .{
            ui.row(.{ .gap = 0 }, .{
                ui.spacer(1),
                ui.column(.{ .gap = settings_section_gap, .width = settings_column_width }, .{
                    vgap(ui, 16),
                    ui.column(.{ .gap = settings_section_gap, .grow = 1 }, .{sections[0..n]}),
                    vgap(ui, 18),
                }),
                ui.spacer(1),
            }),
        }),
    });
}

/// The 38px header band. "Settings" sits centred in it, with the way out on the
/// left, so the title belongs to the sheet rather than to the column beneath it.
fn settingsHeader(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0, .height = settings_header_height, .padding = 0.01 }, .{
        hgap(ui, 10),
        // "Close", not "Back": this is a sheet over the feed now, and Back is
        // what the thread and profile headers say when there is a place behind
        // to return to. There is nothing behind this but the feed it covers.
        ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = Msg.close_settings }, "Close"),
        ui.spacer(1),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_sheet_title } },
            &.{.{ .text = "Settings", .weight = .medium, .scale = settings_title_scale }},
        ),
        ui.spacer(1),
        // The same width the Close button takes, so the title is centred in the
        // band rather than in what is left of it.
        hgap(ui, 62),
    });
}

/// A labelled section: the mono label, an optional caption beside it, then the
/// card. The label is mono per the design; the engine draws mono at one weight,
/// so it carries its emphasis through colour and size rather than through w600.
fn settingsSection(ui: *AppUi, label: []const u8, caption: []const u8, card: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
            if (caption.len > 0) hgap(ui, 8) else ui.spacer(0),
            if (caption.len > 0)
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = caption, .scale = mono_hint_scale }})
            else
                ui.spacer(0),
        }),
        vgap(ui, settings_label_gap),
        card,
    });
}

/// One settings card: the house card chrome, so every section on the screen
/// wears the same edge.
pub fn settingsCard(ui: *AppUi, children: anytype) AppUi.Node {
    const p = theme.palette;
    // Padding, not scaffolding. This was a row, two columns and four spacers
    // around the children: seven nodes per card to express an inset that the
    // card can state in one. Settings is the heaviest screen in the app and
    // half its nodes were whitespace like this.
    //
    // The inset is uniform 12 where it used to be 12 horizontal and 11
    // vertical, because the builder takes one number. One pixel, against six
    // nodes a card.
    return ui.el(.card, .{ .padding = 12, .style = .{ .background = p.surface_settings_card, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 } }, .{
        ui.column(.{ .gap = 0, .grow = 1 }, children),
    });
}

/// A card's internal rule: what separates who you are from what signs for you.
fn cardDivider(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 10),
        ui.el(.panel, .{ .height = 1, .padding = 0.01, .style = .{ .background = p.divider_card, .radius = 0, .stroke_width = 0 } }, .{}),
        vgap(ui, 10),
    });
}

/// The identity section: who you are, what signs for you, and, when the key is
/// on this machine, how to take a copy of it away with you.
fn identitySection(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    var rows: [5]AppUi.Node = undefined;
    var n: usize = 0;

    rows[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        meAvatar(ui, 38),
        hgap(ui, 10),
        ui.column(.{ .gap = 0, .grow = 1 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = accountName(), .weight = .medium, .scale = scope_title_scale }}),
            // The npub only when it is not already the line above it: an account
            // with no kind:0 yet would otherwise read its own key twice.
            if (accountHasName()) vgap(ui, 2) else ui.spacer(0),
            if (accountHasName())
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = npubShort(), .monospace = true, .scale = mono_meta_scale }})
            else
                ui.spacer(0),
        }),
        hgap(ui, 8),
        settingsLink(ui, "Copy npub", Msg.copy_npub),
        hgap(ui, 10),
        if (model.is_guest()) ui.spacer(0) else settingsLink(ui, "Edit profile", Msg.open_profile_edit),
    });
    n += 1;

    rows[n] = cardDivider(ui);
    n += 1;

    // What holds the key, said as a fact about this machine rather than as a
    // badge. The dot is green only for a signer that is answering.
    // The dot reports the signer. Painting it green unconditionally would say
    // "this is working" while a dead Notary daemon quietly refused every note.
    const signer_state = signerStatus();
    const signer_healthy = signerIsHealthy();
    rows[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.panel, .{ .width = 7, .height = 7, .padding = 0.01, .style = .{
            .background = signer_state.color,
            .radius = 4,
            .stroke_width = 0,
        } }, .{}),
        hgap(ui, 9),
        ui.column(.{ .gap = 0, .grow = 1 }, .{
            // The line says what signs for you; the sub-line says how that is
            // going. When the signer is unhealthy its own words take the
            // sub-line, because "Notary unreachable" is the thing worth reading
            // and a fixed reassurance underneath it would be a lie.
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = model.signer_line(), .weight = .medium, .scale = menu_scale }}),
            vgap(ui, 2),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = if (signer_healthy) p.text_faint else p.status_warning_text } },
                &.{.{ .text = if (signer_healthy) model.signer_sub() else signer_state.label, .scale = mono_hint_scale }},
            ),
        }),
        // The design puts a "Change…" here. There is no change-signer flow to
        // send it to: changing what signs means signing out and signing back in
        // differently, and the control for that is at the bottom of the screen
        // wearing the word it deserves. A gentler-looking link that opens a
        // confirmation about removing your key is the dishonest option.
        //
        // What DOES belong in that seat is a way to go and look at the thing this
        // row is a sentence about. Notary is a separate process holding the key
        // this account is, and until now the only time a reader ever saw it was
        // the few seconds of the ceremony that made the key.
        if (model.can_open_notary()) settingsLink(ui, "Open Notary", Msg.open_notary_window) else ui.spacer(0),
    });
    n += 1;

    // The backup used to be here, and could not work: a key minted in Plaza is
    // moved into the keyholder in the background, which clears the in-process
    // copy, so this panel vanished the moment it became relevant and its reveal
    // read a keypair that was gone.
    //
    // It lives in the signer's own window now, which is the process that holds
    // the key. Plaza asking for a key to show would be Plaza holding one, and
    // "the key never enters the client" is the sentence this whole arrangement
    // exists to keep true. The row above is what opens that window.

    return settingsSection(ui, "IDENTITY", "", settingsCard(ui, .{rows[0..n]}));
}

/// A quiet inline action: the design's "Copy npub", "Edit profile", "Change…".
/// Text, not a button, because a card full of buttons reads as a form.
pub fn settingsLink(ui: *AppUi, label: []const u8, msg: Msg) AppUi.Node {
    const p = theme.palette;
    return ui.el(.list_item, .{
        .padding = 0.01,
        .height = 18,
        .cross = .center,
        .on_press = msg,
        .style = .{ .radius = 4 },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = label, .scale = meta_scale }}),
    });
}

/// Appearance. Nothing here is adjustable yet, and the section says so by
/// showing where the app stands on each axis with the alternatives disabled: a
/// statement about the app rather than a row of dead controls.
fn appearanceCard(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return settingsCard(ui, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            themeRadio(ui, "Dark", true),
            hgap(ui, 14),
            themeRadio(ui, "System", false),
            hgap(ui, 14),
            themeRadio(ui, "Light", false),
            ui.spacer(1),
        }),
        vgap(ui, 9),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Plaza is dark only for now, at a comfortable density. Both are on the list.", .scale = mono_hint_scale }},
        ),
    });
}

/// One appearance choice. Only the selected one is live, and the others are
/// disabled rather than absent, so the axis is legible.
fn themeRadio(ui: *AppUi, label: []const u8, selected: bool) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.radio, .{
            .size = .sm,
            .selected = selected,
            // Even the selected one takes no press: there is nothing to switch
            // to. `disabled` also stops the control claiming a press it would
            // then drop, which is what a live-looking dead control does.
            .disabled = true,
            .opacity = if (selected) 1.0 else 0.55,
            .style = .{
                .border = if (selected) p.surface_control_solid else p.border_radio,
                .accent = p.surface_control_solid,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = label },
        }, .{}),
        hgap(ui, 6),
        ui.paragraph(
            .{ .style = .{ .foreground = if (selected) p.text_body_strong else p.text_muted_alt }, .opacity = if (selected) 1.0 else 0.55 },
            &.{.{ .text = label, .scale = menu_scale }},
        ),
    });
}

/// What the reader can take away, and what is gone right now.
///
/// The WHOLE registry is listed, not only what is hidden, and that is the point
/// of the screen rather than a detail of it. Hide something in the feed and
/// there is nothing left there to press to get it back; a list that showed only
/// what was hidden would be empty exactly when somebody came looking for it.
///
/// Each row says what hiding it does to the fetching, in its own words, because
/// two of these stop the app asking relays for anything and one does not, and a
/// screen that let you assume they were the same would be making a promise the
/// app does not keep.
fn notesCard(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    const p = theme.palette;
    var kids: [hideables.len * 3]AppUi.Node = undefined;
    var n: usize = 0;
    for (hideables, 0..) |h, i| {
        if (n > 0) {
            kids[n] = vgap(ui, 10);
            n += 1;
        }
        kids[n] = ui.el(.checkbox, .{
            .size = .sm,
            // Checked means SHOWN. The registry stores what is hidden, which is
            // the right way round for a file and the wrong way round for a
            // person: a box you tick to make something disappear reads as a
            // switch that does the opposite of what it says.
            .checked = !hiding.g_hidden[i],
            .text = h.label,
            .on_toggle = Msg{ .hide_toggle = @intCast(i) },
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = h.label, .focusable = true },
        }, .{});
        n += 1;
        kids[n] = ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = h.detail, .scale = mono_hint_scale }},
        );
        n += 1;
    }
    return settingsCard(ui, .{kids[0..n]});
}

/// The feed section: what the app is allowed to fetch on the reader's behalf,
/// and where pictures are resized. Both are privacy settings before they are
/// anything else, which is why each keeps its sentence.
fn feedCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return settingsCard(ui, .{
        // A real checkbox: it owns its whole row, because a control nested in a
        // pressable row claims the press and drops it.
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.previews_on(),
            .text = "Load media previews",
            .on_toggle = Msg.previews_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Load media previews", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.previews_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.sensitive_on(),
            .text = "Show sensitive notes without a warning",
            .on_toggle = Msg.sensitive_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Show sensitive notes without a warning", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.sensitive_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.client_tag_on(),
            .text = "Say notes were written in Plaza",
            .on_toggle = Msg.client_tag_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Say notes were written in Plaza", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.client_tag_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.update_check_on(),
            .text = "Tell me when a newer Plaza exists",
            .on_toggle = Msg.update_check_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Tell me when a newer Plaza exists", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.update_check_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.paragraph(
                .{ .grow = 1, .wrap = true },
                &.{.{ .text = "Hold notes and replies before sending", .scale = 1.0 }},
            ),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .post_delay_cycle }, model.post_delay_label()),
        }),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.post_delay_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.proxy_on(),
            .text = "Load pictures through a proxy",
            .on_toggle = Msg.proxy_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Load pictures through a proxy", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.proxy_explainer(), .scale = mono_hint_scale }},
        ),
        vgap(ui, 9),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.direct_fallback_on(),
            .text = "Ask the host when the proxy refuses",
            .on_toggle = Msg.direct_fallback_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Ask the host when the proxy refuses", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.direct_fallback_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.paragraph(.{ .style = .{ .foreground = p.text_body_soft } }, &.{.{ .text = "Media proxy", .scale = menu_scale }}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Which service does the resizing. Point it at your own instance if you would rather not use a public one.", .scale = mono_hint_scale }},
        ),
        vgap(ui, 9),
        ui.inputGroup(
            .{ .semantics = .{ .label = "Media proxy" } },
            ui.el(.textarea, .{
                .text = model.proxy_draft(),
                .placeholder = "https://wsrv.nl/",
                .on_input = AppUi.inputMsg(.proxy_edit),
                .on_submit = Msg.proxy_save,
                .height = 30,
            }, .{}),
            ui.inputGroupActions(.{}, .{
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg.proxy_save }, "Save"),
            }),
        ),
        fieldNote(ui, model.proxy_status(), model.proxy_invalid),
    });
}

/// What a settings field has to say about itself, under the field rather than
/// beside its button. A sentence squeezed into the strip next to a button wraps
/// into a box that has a fixed height, and its second line ends up drawn over
/// whatever follows; under the field it has the card's whole width and pushes
/// the rest down instead. Nothing at all when there is nothing to say.
fn fieldNote(ui: *AppUi, text: []const u8, refusal: bool) AppUi.Node {
    if (text.len == 0) return ui.spacer(0);
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = if (refusal) p.status_warning_text else p.text_dim } },
            &.{.{ .text = text, .scale = mono_hint_scale }},
        ),
    });
}

/// A scroll offset past any page Settings can be. The scroll view clamps a
/// requested offset to the end of its content, so this means "the bottom".
pub const settings_scroll_end: f32 = 1.0e6;

/// Signing out: one press to ask, one card to confirm. The card is the whole
/// section when it is up, because a confirmation that shares a row with other
/// controls is a confirmation nobody reads.
fn logoutSection(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.logout_idle()) {
        return ui.row(.{ .gap = 0 }, .{
            ui.button(.{ .variant = .destructive, .on_press = Msg.logout_request }, "Log out"),
            ui.spacer(1),
        });
    }
    return settingsCard(ui, .{
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = theme.palette.text_primary } }, &.{.{ .text = model.logout_warning(), .scale = menu_scale }}),
        vgap(ui, 12),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.logout_cancel }, "Cancel"),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.logout_confirm }, "Log out"),
        }),
    });
}

/// Walks a relay through what it is for. Both, then read, then write, then both
/// again: three states, because a relay that is neither is a relay you have
/// removed, and there is a button for that.
pub fn cycleRelay(i: usize) void {
    if (i >= relay_table.g_relays.len) return;
    const e = &relay_table.g_relays[i];
    if (!e.used) return;
    if (e.read and e.write) {
        e.write = false;
    } else if (e.read) {
        e.read = false;
        e.write = true;
    } else {
        e.read = true;
        e.write = true;
    }
}

/// Whether a relay may be taken out of the list: only while another remains.
pub fn mayRemoveRelay() bool {
    return relayCount() > 1;
}

/// Drops a relay. The SLOT stays claimed and dormant: its index is a promise to
/// everything that recorded one, and its thread simply finds nothing to dial.
pub fn removeRelay(i: usize) void {
    if (i >= relay_table.g_relays.len) return;
    // Recorded BEFORE the seat is wiped, because the publish splices onto the
    // list this account already published and "the pool has no seat for it" is
    // what decides a relay is carried forward. A removal looks exactly like
    // that from the outside.
    if (relayAt(i)) |e| noteRelayRemoved(e.url());
    lockRelayTable();
    relay_table.g_relays[i] = .{};
    unlockRelayTable();
    // The seat keeps its index, but nothing about the relay that sat in it: a
    // status left at `.connected` would keep counting toward "4/6 relays", and a
    // latency left behind would be shown beside whoever takes the seat next.
    forgetRelaySlotState(i);
}

/// Drops everything recorded ABOUT a slot rather than about the pool: its
/// connection state, its latency samples, and the per-note marks saying this
/// slot was the one that carried a note.
fn forgetRelaySlotState(i: usize) void {
    if (i >= max_relays) return;
    setRelayStatus(i, .offline);
    clearRelayRtt(i);
    forgetRelaySeen(i);
    // What a relay asked of the last occupant is not a question for the next.
    authSlotReset(i);
}

/// The URLs currently in the slots, so a table swap can tell which seats
/// actually changed hands.
pub fn snapshotRelayUrls(out: *[max_relays][96]u8, lens: *[max_relays]u8) void {
    lockRelayTable();
    defer unlockRelayTable();
    for (&relay_table.g_relays, 0..) |*e, i| {
        lens[i] = if (e.used) e.url_len else 0;
        if (e.used) @memcpy(out[i][0..e.url_len], e.url_buf[0..e.url_len]);
    }
}

/// Drops what was recorded against every slot whose OCCUPANT changed, and
/// leaves alone the slots still holding the same relay.
///
/// The whole-table version of this was `for (0..max_relays) |i|
/// forgetRelaySlotState(i)`, and it is why the pool read `0/5` forever after a
/// sign-out. Status, latency and seen-ness describe a LIVE CONNECTION, and the
/// thread that owns that connection is parked in a blocking read almost all of
/// the time: it cannot put a status back that somebody else cleared until its
/// relay next says something, and a quiet relay never does. So clearing the row
/// for a relay that is still perfectly connected does not go stale, it stays
/// wrong, and the bar reads nothing-is-working over a pool that is working.
///
/// The seat metaphor the per-slot state is built on still holds: it is about the
/// occupant, so it is dropped when the occupant changes and kept when it does
/// not. Signing out replaces a list with the bootstrap five, and most of the
/// time most of those seats do not change hands at all.
pub fn forgetChangedRelaySlotStates(before: *const [max_relays][96]u8, lens: *const [max_relays]u8) void {
    for (0..max_relays) |i| {
        const was: []const u8 = before[i][0..lens[i]];
        const now: []const u8 = if (relayAt(i)) |e| e.url() else "";
        // Same relay in the same seat: its connection, its latency and its
        // status all still describe something true.
        if (was.len != 0 and now.len != 0 and relayUrlEql(was, now)) continue;
        forgetRelaySlotState(i);
    }
}

/// The relay list: which relays this app talks to, and in which direction.
///
/// The badge is the control, not a label. Pressing it walks R and W, which is
/// the whole of NIP-65's vocabulary: a relay you read from, a relay you write
/// to, or both. Reads and writes actually follow it, so a relay set to R never
/// sees a note and a relay set to W is never asked a question.
fn relayCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const slots = relaySlots();
    const rows = ui.arena.alloc(AppUi.Node, slots + 4) catch return ui.spacer(0);
    var n: usize = 0;
    // No heading here: the section above the card already says RELAYS, and the
    // caption beside it already says what the markers do.
    rows[n] = ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
        &.{.{ .text = "Press a badge to change what a relay is for.", .scale = mono_hint_scale }},
    );
    n += 1;
    rows[n] = vgap(ui, 10);
    n += 1;
    for (0..slots) |i| {
        const e = relayAt(i) orelse continue;
        const state: Conn = @enumFromInt(relay_conn.g_relay_status[i].load(.monotonic));
        rows[n] = relayListRow(ui, e, i, state);
        n += 1;
    }
    rows[n] = relayAddRow(ui, model);
    n += 1;
    return settingsCard(ui, .{rows[0..n]});
}

/// One relay: how it is doing, where it is, what it is for, and a way out.
fn relayListRow(ui: *AppUi, e: *const RelayEntry, index: usize, state: Conn) AppUi.Node {
    const p = theme.palette;
    const dot: canvas.Color = switch (state) {
        .connected => p.status_success,
        // Amber, not green. The socket is open and nothing has failed, but the
        // last word from this relay is a minute old and a keepalive is out with
        // no answer. Green here is the lie this state exists to stop telling.
        .quiet => p.status_warning_text,
        .connecting => p.status_warning_text,
        .offline => p.status_offline,
    };
    const badge = relayBadgeText(e);
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.el(.panel, .{ .width = 7, .height = 7, .padding = 0.01, .style = .{ .background = dot, .radius = 4, .stroke_width = 0 } }, .{}),
            hgap(ui, 9),
            ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = e.url(), .monospace = true, .scale = mono_row_scale }}),
            hgap(ui, 9),
            // Reconnecting is worth saying: an amber dot alone reads as a fault
            // rather than as the app already doing something about it.
            if (state == .connecting)
                ui.paragraph(.{ .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = "reconnecting", .monospace = true, .scale = mono_chip_scale }})
            else if (state == .quiet)
                ui.paragraph(.{ .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = "quiet", .monospace = true, .scale = mono_chip_scale }})
            else if (relayRttMs(index)) |ms|
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = ui.fmt("{d} ms", .{ms}), .monospace = true, .scale = mono_chip_scale }})
            else
                ui.spacer(0),
            ui.spacer(1),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg{ .relay_cycle = @intCast(index) },
                .style = .{ .radius = 4, .border = p.border_chip, .stroke_width = 1 },
                .semantics = .{ .role = .button, .label = ui.fmt("Change what {s} is for", .{e.url()}), .focusable = true },
            }, .{
                hgap(ui, 5),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = badge, .monospace = true, .scale = mono_badge_scale }}),
                hgap(ui, 5),
            }),
            // Whether this relay may know who the reader is. Only once the
            // relay has asked or the reader has said, so a row that never
            // mentions identity does not grow a control about it.
            if (authBadgeText(index, e.url())) |text| ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 6),
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .height = 20,
                    .cross = .center,
                    .on_press = Msg{ .auth_cycle = @intCast(index) },
                    .style = .{ .radius = 4, .border = p.border_chip, .stroke_width = 1 },
                    .semantics = .{ .role = .button, .label = ui.fmt("Change whether {s} may know who you are", .{e.url()}), .focusable = true },
                }, .{
                    hgap(ui, 5),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = text, .monospace = true, .scale = mono_badge_scale }}),
                    hgap(ui, 5),
                }),
            }) else ui.spacer(0),
            hgap(ui, 8),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg{ .relay_remove = @intCast(index) },
                .style = .{ .radius = 4 },
                .semantics = .{ .role = .button, .label = ui.fmt("Remove {s}", .{e.url()}), .focusable = true },
            }, .{
                hgap(ui, 4),
                ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_dim } }, "x"),
                hgap(ui, 4),
            }),
        }),
        // A relay that is connected and giving nothing is the state this line
        // exists for: the dot is green, so without it the row reads as a relay
        // with nothing to say.
        if (authRowNote(index)) |note| ui.column(.{ .gap = 0 }, .{
            vgap(ui, 3),
            ui.row(.{ .gap = 0 }, .{
                hgap(ui, 16),
                ui.paragraph(.{ .wrap = true, .grow = 1, .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = note, .scale = mono_chip_scale }}),
            }),
        }) else ui.spacer(0),
        vgap(ui, 9),
    });
}

/// The relays this reader's follows write to, offered as one press each. Empty
/// until a follow's kind:10002 has actually been read, because a suggestion the
/// app invented would just be another default wearing a recommendation's face.
///
/// The chips are packed into rows HERE rather than left to the layout, because
/// rows and columns in this engine never flow-wrap their children: `wrap` is a
/// line policy for text leaves and is silently inert on a container. This row
/// carried `.wrap = true` and a comment describing wrapping that never
/// happened, so six suggested relays ran to x=1372 in a 760 window, straight
/// off the right edge of the card and the window with it.
fn relaySuggestions(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const count = relaySuggestionCount();
    if (count == 0) return ui.spacer(0);
    const chips = ui.arena.alloc(AppUi.Node, count) catch return ui.spacer(0);
    const widths = ui.arena.alloc(f32, count) catch return ui.spacer(0);
    const tokens = theme.tokens(Model)(model);
    var n: usize = 0;
    for (0..count) |i| {
        var buf: [96]u8 = undefined;
        const url = relaySuggestionCopy(i, &buf) orelse continue;
        // The arena copy is what the frame renders: `buf` dies with this loop.
        var shown: []const u8 = ui.arena.dupe(u8, relayShortName(url)) catch continue;
        // Measured with the engine's own sizing, against the same tokens the
        // frame is laid out with, so the packing below agrees with what the
        // layout will actually do rather than with an estimate of it. A name too
        // long for a row of its own is shortened until it fits, rather than
        // allowed to hang off the card: the text is monospace, so cutting
        // characters cuts width in proportion, and each cut is re-measured so
        // the loop cannot talk itself into a width the engine disagrees with.
        var chip = suggestionChip(ui, i, shown, tokens);
        var attempts: usize = 0;
        while (chip.width > settings_content_width and shown.len > 8 and attempts < 8) : (attempts += 1) {
            const room: usize = @intFromFloat(@max(1, settings_content_width - relay_chip_chrome));
            const have: usize = @intFromFloat(@max(1, chip.width - relay_chip_chrome));
            const keep = @max(@as(usize, 7), (shown.len * room) / have -| 1);
            if (keep >= shown.len) break;
            shown = ui.fmt("{s}\u{2026}", .{shown[0..keep]});
            chip = suggestionChip(ui, i, shown, tokens);
        }
        chips[n] = chip.node;
        widths[n] = chip.width;
        n += 1;
    }
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 10),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = "Relays the people you read write to", .scale = mono_meta_scale }},
        ),
        vgap(ui, 6),
        chipRows(ui, chips[0..n], widths[0..n], settings_content_width, relay_chip_gap),
    });
}

/// A gap between suggestion chips, across and down.
const relay_chip_gap: f32 = 6;

/// Everything a chip is wider than its words: seven either side of the label
/// and the hairline border. Stated rather than measured, because the engine
/// does not measure a `.list_item` from its children at all: asking it for an
/// intrinsic size returns the chrome alone, which is how the first version of
/// this packing measured every chip at 24 points and put six of them on one
/// row. The label is measured for real; this is added to it, and the rule in
/// the suite holds the sum against a laid-out frame.
const relay_chip_chrome: f32 = 15;

/// One suggestion, as a chip, with the width it will actually take.
fn suggestionChip(ui: *AppUi, index: usize, shown: []const u8, tokens: canvas.DesignTokens) struct { node: AppUi.Node, width: f32 } {
    const p = theme.palette;
    const label = ui.paragraph(
        .{ .style = .{ .foreground = p.text_muted_alt } },
        &.{.{ .text = ui.fmt("+ {s}", .{shown}), .monospace = true, .scale = mono_chip_scale }},
    );
    const node = ui.el(.list_item, .{
        .padding = 0.01,
        .height = 22,
        .cross = .center,
        .on_press = Msg{ .relay_suggest = @intCast(index) },
        .style = .{ .radius = 5, .border = p.border_chip, .stroke_width = 1 },
        .semantics = .{ .role = .button, .label = ui.fmt("Add {s}", .{shown}), .focusable = true },
    }, .{
        hgap(ui, 7),
        label,
        hgap(ui, 7),
    });
    return .{ .node = node, .width = canvas.intrinsicWidgetSize(label.widget, tokens).width + relay_chip_chrome };
}

/// Packs pre-measured children into rows no wider than `limit`, greedily: the
/// flow layout the engine does not do. A child wider than the limit on its own
/// still gets a row to itself, because the alternative is dropping it.
fn chipRows(ui: *AppUi, chips: []const AppUi.Node, widths: []const f32, limit: f32, gap: f32) AppUi.Node {
    // At worst one chip per row, plus a gap row between each.
    const lines = ui.arena.alloc(AppUi.Node, chips.len * 2) catch return ui.spacer(0);
    var line_count: usize = 0;
    var first: usize = 0;
    var used: f32 = 0;
    var i: usize = 0;
    while (i < chips.len) {
        const next = if (i == first) widths[i] else used + gap + widths[i];
        if (i > first and next > limit) {
            if (line_count > 0) {
                lines[line_count] = vgap(ui, gap);
                line_count += 1;
            }
            lines[line_count] = ui.row(.{ .gap = gap }, .{chips[first..i]});
            line_count += 1;
            first = i;
            used = widths[i];
            i += 1;
            continue;
        }
        used = next;
        i += 1;
    }
    if (first < chips.len) {
        if (line_count > 0) {
            lines[line_count] = vgap(ui, gap);
            line_count += 1;
        }
        lines[line_count] = ui.row(.{ .gap = gap }, .{chips[first..chips.len]});
        line_count += 1;
    }
    return ui.column(.{ .gap = 0 }, .{lines[0..line_count]});
}

/// A relay URL with the scheme and any trailing slash taken off. The scheme is
/// the same on every row, so it is the part that carries no information.
pub fn relayShortName(url: []const u8) []const u8 {
    var out = url;
    if (std.mem.startsWith(u8, out, "wss://")) out = out["wss://".len..];
    return std.mem.trimEnd(u8, out, "/");
}

/// Where a relay is added, and where the ones your follows use are offered.
fn relayAddRow(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .gap = 0 }, .{
        ui.inputGroup(
            .{ .semantics = .{ .label = "Add a relay" } },
            ui.el(.textarea, .{
                .text = model.relay_draft(),
                .placeholder = "wss://",
                .on_input = AppUi.inputMsg(.relay_edit),
                .on_submit = Msg.relay_add,
                .height = 30,
            }, .{}),
            ui.inputGroupActions(.{}, .{
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg.relay_add }, "Add"),
            }),
        ),
        fieldNote(ui, model.relay_status(), model.relay_error or model.relay_full or model.relay_last),
        relaySuggestions(ui, model),
    });
}

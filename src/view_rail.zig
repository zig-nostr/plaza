//! The primary rail and the places rail.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const places = @import("places.zig");
const session = @import("session.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Place = main.Place;
const activePlaceIndex = main.activePlaceIndex;
const activePubkey = main.activePubkey;
const avatarTint = main.avatarTint;
const chrome_inset = main.chrome_inset;
const hgap = main.hgap;
const inboxUnread = main.inboxUnread;
const lookupProfile = main.lookupProfile;
const meta_scale = main.meta_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const pillButton = main.pillButton;
const pressRow = main.pressRow;
const rail_gap = main.rail_gap;
const roomVerbFill = main.roomVerbFill;
const roomVerbInk = main.roomVerbInk;
const scope_title_scale = main.scope_title_scale;
const vgap = main.vgap;
const visitingPlace = main.visitingPlace;

/// The 56px primary rail: the destinations up top, then the compose verb, the
/// Settings gear, and the "you" seat pinned to the bottom. This replaces the old
/// titlebar of buttons: destinations on the edge, the feed owns the width. A
/// guest's gated tiles (compose, settings, you) route to the join sheet.
///
/// Three of the five destinations the design names. Search and Messages are not
/// built and are therefore not here: a rail item that goes nowhere is worse than
/// one fewer, which is the same rule that keeps Groups off until NIP-29 ships.
///
/// Our split is inverted from the strongest prior art and that is a choice.
/// Flotilla and Discord put the COMMUNITIES on the primary rail with three or
/// four fixed destinations pinned under them; we put destinations primary and
/// places secondary, which is Slack's shape. The deciding factor is how many
/// top-level things the app ends up with: Discord has essentially one, so
/// servers earn the outer rail, and Plaza is heading for five or six.
pub fn railView(ui: *AppUi, model: *const Model) AppUi.Node {
    const guest = model.is_guest();
    const compose_press: Msg = if (guest) .open_join else .open_compose;
    const settings_press: Msg = if (guest) .open_join else .open_settings;
    // Gap 0 with explicit steps: the rail insets are 10 above and 12 below, which
    // one uniform padding cannot state. The 10 on each side is exactly what
    // centring a 36px tile in the 56px rail leaves, so it stays as padding.
    return ui.column(.{ .width = 56, .cross = .center, .gap = 0, .padding = 10, .style_tokens = .{ .background = .background } }, .{
        // Home: the mark, and the way back to your own feed from wherever the
        // reader has got to, INCLUDING out of a place. It looked like the app's
        // own button for a long time and did nothing when pressed, which is the
        // one thing a mark in that position should never be.
        railDest(ui, "mark", 21, Msg.go_home, "Home", places.g_place == null),
        vgap(ui, rail_gap),
        // The bell, with what is waiting on it. Signed out there is no inbox to
        // have, so there is no bell: a tile that could only ever say zero is a
        // tile that says nothing.
        //
        // It takes no selected plate, and that is not an oversight: it opens a
        // SHEET over whatever is underneath rather than being a section of its
        // own, so a plate would claim a selection the app does not have.
        if (guest) ui.spacer(0) else railBell(ui),
        if (guest) ui.spacer(0) else vgap(ui, rail_gap),
        // Places: the switcher rail, out or folded away. Shown even with an
        // empty list, because the rail's empty state is how somebody learns
        // what a place is and that a link opens one, which in v1 is the only
        // way in. The plate says you are IN a place, which is the fact worth
        // showing; whether the rail happens to be out is visible on its own.
        railDest(ui, "places", 17, Msg.toggle_places_rail, "Places", places.g_place != null),
        vgap(ui, rail_gap),
        // An address, and the way in for anything somebody hands you.
        //
        // The design names five rail destinations and Search is one of the two
        // that were left out, because a tile that goes nowhere is worse than one
        // fewer. It goes somewhere now.
        //
        // No selected plate, for the bell's reason rather than as an oversight:
        // it opens a SHEET over whatever is underneath rather than being a
        // section of its own, and a plate would claim a selection the app does
        // not have.
        //
        // Shown to guests too. Reading needs no key, and a link somebody sent is
        // one of the first things a person who has not signed in arrives with.
        // That is the same call the account menu's row makes.
        railTile(ui, "search", 16, .open_address, "Search", false),
        // The bottom cluster hangs off the floor of the rail: verbs, then meta.
        ui.spacer(1),
        // Compose: the one bright tile.
        railTile(ui, "edit", 15, compose_press, "New note", true),
        vgap(ui, rail_gap),
        // Settings.
        railTile(ui, "settings", 16, settings_press, "Settings", false),
        vgap(ui, rail_gap),
        // The account seat: a dashed "you" as a guest, the account once signed in.
        railYou(ui, guest),
        vgap(ui, 2),
    });
}

/// A primary-rail destination: the same 36px tile as a verb, plus the one thing
/// a destination has that a verb does not, which is being where you are.
///
/// The plate says where you are, and the two that have one are exclusive by
/// construction: Home is plated out of a place, the pin is plated in one, and
/// there is no third state. Discord's left-edge indicator bar reads better but
/// has nowhere to live here: the 56px rail is a 36px tile between two 10px
/// insets, and a bar inside the tile's own box paints on top of the plate
/// instead of beside it.
fn railDest(ui: *AppUi, comptime icon: []const u8, size: f32, press: Msg, label: []const u8, selected: bool) AppUi.Node {
    const p = theme.palette;
    const tint = if (selected) p.text_primary else p.text_muted;
    const glyph = ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = tint } }, icon);
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        if (selected)
            tilePlate(ui, .{ .background = p.surface_rail_tile, .border = p.border_hairline, .radius = 9, .stroke_width = 1 }, "", glyph)
        else
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The width of the second rail. Every point of it is added to the window's
/// floor in `app.zon`, because a floor cannot be conditional and the narrowest
/// window has to hold the widest arrangement.
const places_rail_width: f32 = 180;
/// Everything to the left of the reading area when both rails are out: the two
/// rails and the 1pt rule after each. The window's default size is stated in
/// terms of this, so a rail that changes width takes the window with it.
pub const rails_width: f32 = 56 + 1 + places_rail_width + 1;
const place_row_height: f32 = 34;
const place_tile_size: f32 = 24;
const places_rail_inset: f32 = 12;
/// What is left for a name once the inset, the tile and the gap are spent. A
/// DEFINITE width, so a long one ellipsizes instead of pushing the rail wide.
const place_name_width: f32 = places_rail_width - places_rail_inset * 2 - place_tile_size - 8;

/// The second rail: the places you have entered, and the one you are visiting.
///
/// Contents are a pure function of which primary section is selected, which is
/// why this takes nothing but the arena: Places is the only section with a
/// second rail, so being drawn at all is the whole of the condition.
///
/// It does not scroll and needs no overflow rule. Flotilla computes an item
/// limit from the window height and moves the rest into a popover, which is the
/// right answer at its scale; eight places at 34 points fit inside the 680pt
/// window floor with room to spare, and a rule for a case that cannot happen is
/// a rule nobody can check.
pub fn placesRail(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const visiting = visitingPlace();
    const rows = ui.arena.alloc(AppUi.Node, places.g_places_len) catch {
        ui.failed = true;
        return ui.column(.{ .width = places_rail_width }, .{});
    };
    for (rows, 0..) |*row, i| {
        const open = if (activePlaceIndex()) |c| c == i else false;
        row.* = placeRow(ui, &places.g_places[i], Msg{ .place_open = @intCast(i) }, open);
    }
    return ui.column(.{ .width = places_rail_width, .gap = 0, .style = .{ .background = p.surface_subbar } }, .{
        vgap(ui, 14),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, places_rail_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Places", .weight = .bold, .scale = scope_title_scale }},
            ),
        }),
        vgap(ui, 10),
        // The visit sits above the list and outside it, because that is exactly
        // what a visit is: you are in this place, and it is not one of yours.
        if (visiting != null) railSectionLabel(ui, "Visiting") else ui.spacer(0),
        if (visiting) |m| placeRow(
            ui,
            m,
            // Nothing to press while you are already in it.
            if (places.g_place != null and !places.g_place_kept) null else Msg.place_resume,
            places.g_place != null and !places.g_place_kept,
        ) else ui.spacer(0),
        if (visiting != null and places.g_places_len > 0) vgap(ui, 10) else ui.spacer(0),
        if (visiting != null and places.g_places_len > 0) railSectionLabel(ui, "Entered") else ui.spacer(0),
        ui.column(.{ .gap = 0 }, .{rows}),
        if (places.g_places_len == 0 and visiting == null) placesRailEmpty(ui) else ui.spacer(0),
        ui.spacer(1),
    });
}

/// A small quiet label over a group of rail rows.
fn railSectionLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, places_rail_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint } },
                &.{.{ .text = text, .monospace = true, .scale = mono_meta_scale }},
            ),
        }),
        vgap(ui, 4),
    });
}

/// The tile a place wears on the rail, and the whole of what makes that rail
/// legible rather than a column of identical grey squares with a letter in each.
///
/// Two sources, in order. A place that states `defaultPrimaryColor` gets
/// exactly that, so the rail matches the branding the community uses everywhere
/// else. A place that states nothing falls back to the SAME pubkey-keyed
/// rotation a face gets: it costs nothing, needs no configuration, and still
/// tells two places apart, which the flat `surface_link_tile` never did.
pub fn placeTileColors(m: *const Place) struct { bg: canvas.Color, ink: canvas.Color } {
    if (m.color) |c| return .{ .bg = c.primary, .ink = c.on_primary };
    const tint = avatarTint(m.author);
    return .{ .bg = tint.bg, .ink = tint.glyph };
}
/// One place on the second rail: a letter tile and a name.
///
/// A LETTER tile, not the host's picture, and that is a budget decision rather
/// than a taste one. The canvas registers sixteen images at a time, and a rail
/// of eight would spend half of them on chrome that is always on screen, taken
/// from the faces in the feed. `image_src` (a source-crop rect) would let one
/// 512x512 slot hold sixty-four tiles at 64x64; it exists on the internal widget
/// and is not exposed on the app-facing options, which is filed upstream as
/// vercel-labs/native#387. Until that lands, letters.
fn placeRow(ui: *AppUi, m: *const Place, press: ?Msg, selected: bool) AppUi.Node {
    const p = theme.palette;
    const name = if (m.name_len > 0) m.name() else "A place";
    // The first BYTE, uppercased when it is a lowercase ASCII letter. A name
    // starting with a multi-byte character would be cut mid-codepoint by a
    // one-byte slice, so anything that is not printable ASCII falls back to a
    // dot rather than to half a character.
    const head = name[0];
    const initial: []const u8 = if (head >= 'a' and head <= 'z')
        ui.fmt("{c}", .{head - 32})
    else if (head > 0x20 and head < 0x7f)
        ui.fmt("{c}", .{head})
    else
        "\u{2022}";
    const tile = placeTileColors(m);
    return pressRow(ui, .{
        .width = places_rail_width,
        .height = place_row_height,
        .cross = .center,
        .padding = 0,
        .on_press = press,
        // Square, as the `data_row` this was drew it: a list row rounds its wash
        // unless told otherwise.
        .style = if (selected)
            .{ .background = p.surface_menu_selected, .radius = 0 }
        else
            .{ .quiet_hover = true, .radius = 0 },
        .semantics = .{
            .role = if (press == null) .none else .button,
            .label = if (press == null) name else ui.fmt("Open {s}", .{name}),
            .focusable = press != null,
        },
    }, .{
        ui.row(.{ .cross = .center, .gap = 0, .height = place_row_height }, .{
            hgap(ui, places_rail_inset),
            ui.el(.panel, .{
                .width = place_tile_size,
                .height = place_tile_size,
                .padding = 0.01,
                .style = .{ .background = tile.bg, .radius = 6, .stroke_width = 0 },
            }, .{
                ui.column(.{ .width = place_tile_size, .height = place_tile_size, .main = .center, .cross = .center }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = tile.ink } },
                        &.{.{ .text = initial, .monospace = true, .weight = .medium, .scale = mono_meta_scale }},
                    ),
                }),
            }),
            hgap(ui, 8),
            ui.paragraph(
                .{ .width = place_name_width, .style = .{ .foreground = if (selected) p.text_primary else p.text_muted } },
                &.{.{ .text = name, .scale = meta_scale }},
            ),
        }),
    });
}

/// What the rail says before there is anything in it.
///
/// It names the one way in that v1 has. A link is the only door, so a rail that
/// simply looked empty would be the feature failing to explain itself on the
/// only screen where it could.
fn placesRailEmpty(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .start, .gap = 0 }, .{
        hgap(ui, places_rail_inset),
        ui.paragraph(
            .{ .wrap = true, .width = places_rail_width - places_rail_inset * 2, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "No places yet. A plaza:// link opens one, and entering it keeps it here. Only you can see this list.", .scale = mono_hint_scale }},
        ),
    });
}

/// A 36px rail plate with one centered glyph.
///
/// The plate is a `.panel`, not a styled column. The renderer draws NOTHING for
/// the layout kinds (stack, row, column and friends), which is why every rail tile
/// had been painting as bare window, the bright compose tile included. A `.card`
/// paints but carries a 240x120 intrinsic size that blew the rail apart; `.panel`
/// paints AND sizes to its children. It layers its children, so the sizing column
/// inside does the centring, and the 0.01 padding is belt and braces: the house
/// padding substitution only reaches kinds that declare a default layout, which a
/// panel does not, so the plate sits flush either way.
fn tilePlate(ui: *AppUi, style: canvas.WidgetStyle, label: []const u8, glyph: AppUi.Node) AppUi.Node {
    // An empty label leaves the plate anonymous, which is what a plate inside a
    // named pressable row wants: two nodes with one name read as two controls.
    // Every caller is inside one now, so every caller passes "".
    return ui.el(.panel, .{ .padding = 0.01, .style = style, .semantics = .{ .label = label } }, .{
        ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The bell tile, with its count.
///
/// No mock draws the badge anywhere, so this is the smallest thing that reads as
/// one: a small light pill on the tile's top-right corner, absent at zero,
/// capped at "9+". Flagged in the PR.
fn railBell(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const unread = inboxUnread();
    return pressRow(ui, .{
        .width = 36,
        .height = 36,
        .main = .center,
        .cross = .center,
        .padding = 0,
        .on_press = Msg.toggle_notifications,
        .style = .{ .quiet_hover = true },
        .semantics = .{
            .role = .button,
            .label = if (unread == 0) "Notifications" else ui.fmt("Notifications, {d} unread", .{unread}),
            .focusable = true,
        },
    }, .{
        ui.stack(.{ .width = 36, .height = 36 }, .{
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{
                ui.appIcon(.{ .width = 17, .height = 17, .style = .{ .foreground = p.text_muted } }, "bell"),
            }),
            if (unread == 0) ui.spacer(0) else badgePill(ui, unread),
        }),
    });
}

/// The count itself, pinned to the tile's top-right.
fn badgePill(ui: *AppUi, count: usize) AppUi.Node {
    const p = theme.palette;
    const label = if (count > 9) "9+" else ui.fmt("{d}", .{count});
    return ui.column(.{ .width = 36, .height = 36, .main = .start, .cross = .end }, .{
        // The digit sits in a ROW inside the panel, not in the panel.
        //
        // `.panel` is a stacking kind: it hands every child the whole content box
        // and takes the MAX of them for its own size rather than the sum. The two
        // four-pixel spacers were therefore layered behind the digit instead of
        // inset either side of it, and contributed nothing at all. The pill's
        // width was the glyph advance, about five and a half points, so the
        // declared radius of 7 clamped to half of that and the "pill" painted as
        // a narrow lozenge with the number running edge to edge.
        ui.el(.panel, .{
            .padding = 0.01,
            .height = 13,
            // A floor, so one digit and two are the same shape rather than the
            // badge changing width with the count. It sets only the minimum, so a
            // wider label still grows: "9+" hugs to about nineteen, and anything
            // longer has room inside the 36-point rail column.
            .min_width = 19,
            .style = .{ .background = p.accent, .border = p.accent, .radius = 7, .stroke_width = 1 },
        }, .{
            // Centred on purpose: the stack gives this row the panel's whole
            // width, so once `min_width` exceeds what the digit needs, the row is
            // what keeps the number in the middle instead of against the left
            // edge.
            ui.row(.{ .main = .center, .cross = .center, .gap = 0 }, .{
                hgap(ui, 4),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.on_accent } },
                    &.{.{ .text = label, .monospace = true, .weight = .medium, .scale = 9.0 / 14.5 }},
                ),
                hgap(ui, 4),
            }),
        }),
    });
}

/// One pressable rail tile: a 36px plate with a centered icon. `bright` paints
/// the accent fill (the compose verb); the rest are quiet with a muted glyph.
fn railTile(ui: *AppUi, comptime icon: []const u8, size: f32, press: Msg, label: []const u8, bright: bool) AppUi.Node {
    const p = theme.palette;
    const tint = if (bright) roomVerbInk() else p.text_muted;
    const glyph = ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = tint } }, icon);
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        // Only the compose tile carries a plate. The quiet tiles are a glyph on
        // the rail itself, so they take no panel at all: a panel with no stated
        // background falls back to the house card fill and would draw a plate the
        // redesign does not have.
        if (bright)
            tilePlate(ui, .{ .background = roomVerbFill(), .radius = 9, .stroke_width = 0 }, "", glyph)
        else
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The account seat at the bottom of the rail. A guest gets a dashed circle
/// marked "you" that opens the join sheet; a signed-in user gets a small tinted
/// initials avatar that opens their own page.
fn railYou(ui: *AppUi, guest: bool) AppUi.Node {
    const p = theme.palette;
    // The seat is the reader's own face, so it goes where every other face in
    // the app goes: that person's page. It pointed at Settings for as long as
    // there was no profile screen to point at, which quietly taught that "you"
    // means "your preferences". Settings keeps its own tile one row up, and
    // editing still lives there, which is what the profile's own "This is you"
    // says instead of standing up a second door to it.
    //
    // The key comes from `activePubkey` rather than from the `guest` flag so the
    // branch and the payload cannot disagree: with no identity there is no
    // `.open_person` carrying thirty-two bytes that belong to nobody.
    const press: Msg = if (activePubkey()) |me| Msg{ .open_person = me } else .open_join;
    return pressRow(ui, .{
        .on_press = press,
        // The tile's own box, stated. Left unsized, this row measured ZERO wide
        // (a `data_row` hugs its content and the seat inside it is centred, not
        // stretched), so the account seat floated free of the rail's column
        // while every glyph tile sat squarely in its 36. It was the one tile on
        // the rail that did not line up.
        .width = 36,
        .height = 36,
        .main = .center,
        .cross = .center,
        .padding = 0,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "You", .focusable = true },
    }, .{
        // The same 36x36 centring box every other rail tile uses. Without it the
        // 28px seat sat at the row's natural position while the 36px glyph tiles
        // sat centred in theirs, so the account avatar hung 4px off the rail's
        // shared centre line: the one tile on the rail that did not line up.
        ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{
            if (guest)
                // The seat reads as an outline waiting to be filled, so its ring
                // is dashed. The canvas has no dashed strokes, so the ring is an
                // icon whose dashes are baked into its geometry, with the label
                // stacked over it.
                ui.stack(.{ .width = 28, .height = 28 }, .{
                    ui.appIcon(.{ .width = 28, .height = 28, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                    ui.column(.{ .width = 28, .height = 28, .main = .center, .cross = .center }, .{
                        ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "you", .monospace = true, .scale = 8.5 / 14.5 }}),
                    }),
                })
            else
                youAvatar(ui),
        }),
    });
}

/// The signed-in account avatar for the rail: a 28px tinted circle with the
/// pubkey's initials (the same warm tint the feed uses for that key).
pub fn youAvatar(ui: *AppUi) AppUi.Node {
    return meAvatar(ui, 28);
}

/// The registered avatar image id for `pubkey`, or 0 to draw initials.
///
/// The `.loaded` gate is load-bearing rather than cautious. The renderer takes
/// the image branch for ANY non-zero id and draws the initials only in the else,
/// so an id that has been lent but whose bytes have not arrived paints an EMPTY
/// disc instead of falling back. A slot is claimed before the fetch and survives
/// a failed one, so both of those states have to report zero.
pub fn avatarImageId(pubkey: [32]u8) u64 {
    const p = lookupProfile(pubkey) orelse return 0;
    if (p.avatar_state != .loaded) return 0;
    return p.image_id;
}

/// The signed-in reader's own disc at a stated size: the rail seats a 28, the
/// thread's reply row a 36 to match the note it answers.
///
/// It drew initials and only initials, because it never passed an image. Every
/// other link already worked: the reader's own kind:0 is asked for by the feed
/// subscription and by `ownProfileWorker`, `refreshProfiles` puts their pubkey
/// in the author list explicitly, and `assignAvatarSlots` pushes them FIRST so
/// they get one of the scarce ids ahead of any feed author. All of that ran, and
/// then the widget was built without the id it had earned.
pub fn meAvatar(ui: *AppUi, size: f32) AppUi.Node {
    const pk = activePubkey() orelse return ui.spacer(0);
    const tint = avatarTint(pk);
    const hexdigits = "0123456789abcdef";
    return ui.avatar(.{
        .width = size,
        .height = size,
        .image = avatarImageId(pk),
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
    }, ui.fmt("{c}{c}", .{ hexdigits[pk[0] >> 4], hexdigits[pk[0] & 0x0f] }));
}

/// The backup nudge: calm, dismissible, the stakes stated plainly. Rises once,
/// after the first local-key post of a session.
pub fn backupNudge(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .style = .{ .background = p.surface_subbar } }, .{
        ui.column(.{ .height = 1, .style = .{ .background = p.divider_chrome } }, .{}),
        ui.row(.{ .cross = .center, .gap = 10, .padding = 10 }, .{
            ui.text(
                .{ .size = .sm, .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.",
            ),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .backup_now }, "Back up"),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .backup_later }, "Not now"),
        }),
    });
}

/// The guest banner: a full-width top bar over the feed with the invitation and
/// the two join CTAs, always present here so sign-in is never more than one bar
/// away. Dismissible, and safely so: the rail's compose and account tiles and
/// the status bar's Guest chip all keep a way in after it is closed.
pub fn guestBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    const p = theme.palette;
    // On a `.panel`, not a column: a column paints no background at all, so the
    // banner had been reading as plain window behind its own copy.
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_subbar, .stroke_width = 0, .radius = 0 } }, .{
        ui.column(.{ .gap = 0 }, .{
            vgap(ui, 8),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, chrome_inset),
                ui.paragraph(
                    .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                    &.{.{ .text = "Browsing as a guest. Reading is yours forever. Join in when something moves you.", .scale = meta_scale }},
                ),
                hgap(ui, 10),
                pillButton(ui, "Create identity", .open_join, true, p.surface_subbar),
                hgap(ui, 10),
                pillButton(ui, "Sign in", .open_join, false, p.surface_subbar),
                hgap(ui, 10),
                // An icon press, not a text button: the built-in x glyph (the
                // U+2715 codepoint is outside Geist's coverage, rendered tofu).
                // Padded well past the 12px glyph: the target is the press, not the
                // drawing.
                pressRow(ui, .{
                    .padding = 6,
                    .on_press = .dismiss_guest_strip,
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Dismiss", .focusable = true },
                }, .{
                    ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "x"),
                }),
                hgap(ui, chrome_inset),
            }),
            vgap(ui, 8),
            ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        }),
    });
}

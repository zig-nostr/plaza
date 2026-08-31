//! Plaza's design tokens: the dark, cool-grey, Geist-set look ratified in the
//! M10 redesign. This is the single source of truth for the app's palette,
//! type, and geometry, transcribed from the spec so no view carries a literal
//! color.
//!
//! Two deliberate, load-bearing choices:
//!   - The CHROME has no colored primary: its one working accent is a porcelain
//!     white (`accent`) on near-black (`on_accent`), and the interface lives on
//!     typography and spacing. Color enters in exactly one place, identity and
//!     content: `accent_identity`, a violet, carries @handles, @mentions and
//!     in-text URLs. Status colors (success, like, zap amber) are the only other
//!     hues, and each one means a state rather than a brand.
//!   - The type is Geist (prose) and Geist Mono (metadata, labels, code), in
//!     REAL weights. The SDK's default sans IS Geist, and span weights route
//!     to the reserved medium/bold font ids ONLY on the default ids (a
//!     custom-registered canvas id pins every span to its one face, which is
//!     why the app no longer registers Geist with the canvas registry). The
//!     typography tokens therefore stay on the built-in ids, and `main.zig`
//!     registers the faces below with CoreText from these embedded bytes at
//!     startup, so the macOS host resolves the reserved medium/bold ids by
//!     PostScript name ("Geist-Medium", "Geist-Bold") on every launch path:
//!     live window, dev run from any directory, and headless session replay
//!     alike, with no working-directory dependence.
//!
//!     The regular faces are byte-identical to the ones the SDK embeds for
//!     its estimator and CPU reference renderer, so regular-run measurement
//!     matches across every platform exactly as it did before. The weighted
//!     faces are real only where text resolves host-side (macOS): the CPU
//!     reference (portability builds, automation screenshots) inks the
//!     reserved weight ids with the regular outlines, by SDK design.
//!
//! Violet used to be brand-signal only (the app icon, the mark). The redesign
//! gives it one working job: `accent_identity` marks IDENTITY and CONTENT, which
//! is to say @handles, @mentions and in-text links. Chrome stays porcelain, so a
//! violet run in the interface always means "a person, or something they wrote".
//!
//! ONE EXCEPTION, and it is a narrow one: inside a PLACE, both accents become
//! the community's own colour (see `PlaceColor` and `place_color_fn`). The rule
//! above is not suspended, it is applied. A place is an identity, and the room
//! you are standing in is exactly the sort of thing colour is reserved for here.
//! What does NOT move is anything meaning a STATE: the status colours, the
//! unread dot, the disabled ramp. A yellow room must never make an error look
//! like weather. Out of a place the palette is porcelain and violet again.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// The bundled faces (SIL OFL, see src/fonts/OFL.txt): the regulars are the
/// SDK's own bytes (measurement parity, see the module doc), the medium and
/// bold are the matching v1.4.01 statics. Registered with CoreText by
/// `main.zig` at startup; never registered with the canvas font registry
/// (that would pin spans to one face and kill weight routing).
pub const geist_ttf = @embedFile("fonts/Geist-Regular.ttf");
pub const geist_medium_ttf = @embedFile("fonts/Geist-Medium.ttf");
pub const geist_bold_ttf = @embedFile("fonts/Geist-Bold.ttf");
pub const geist_mono_ttf = @embedFile("fonts/GeistMono-Regular.ttf");

fn hex(comptime s: []const u8) Color {
    // #rrggbb -> Color. Comptime so a bad literal is a compile error.
    const r = (nibble(s[1]) << 4) | nibble(s[2]);
    const g = (nibble(s[3]) << 4) | nibble(s[4]);
    const b = (nibble(s[5]) << 4) | nibble(s[6]);
    return Color.rgb8(r, g, b);
}

fn nibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("bad hex digit"),
    };
}

/// The full app palette, named as in the spec so a view reads by intent. Views
/// that need a color the SDK's token slots do not carry (a note-row divider, an
/// avatar tint) reference these constants directly, never a call-site literal.
pub const palette = struct {
    // Surfaces (cool-grey family).
    pub const surface_window = hex("#0a0a0b");
    pub const surface_card = hex("#0d0d0f");
    // The elevated sheet surface. Clearly lighter than the window so a modal
    // reads as a raised panel over the (now firmly dimmed) feed, not a floating
    // cluster of controls.
    pub const surface_modal = hex("#202028");
    pub const surface_inset = hex("#17171b");
    pub const surface_subbar = hex("#121216");
    pub const surface_input = hex("#0f0f13");
    pub const surface_chip = hex("#1a1a1f");
    pub const surface_toast = hex("#232327");
    // The in-window sheet and card surface: the composer sheet and the settings
    // card column. Distinct in intent from `surface_modal` (the raised join and
    // name sheets), and from the notifications sheet, which the redesign draws on
    // the window's own near-black.
    pub const surface_sheet = hex("#101012");
    // The rail's home plate: a tile just above the window, so the mark reads as
    // seated rather than floating.
    pub const surface_rail_tile = hex("#1c1c22");
    // A menu or popover: the relay popover, the repost and overflow menus, the
    // mention picker. `surface_toast` happens to share the hex today; the
    // intents differ, so moving one must never drag the other.
    pub const surface_menu = hex("#232327");
    pub const surface_menu_selected = hex("#2c2c34");
    // The settings section card and the quieter fill of its add-a-relay row.
    pub const surface_settings_card = hex("#16161a");
    pub const surface_settings_row = hex("#131317");
    // A toggle group and its selected item: the profile's Notes/Replies tabs and
    // the notifications All/Mentions/Zaps tabs. (Settings' density control is a
    // third, smaller recipe that sits on `surface_settings_card` instead.)
    pub const surface_toggle = hex("#111116");
    pub const surface_toggle_active = hex("#26262e");
    // An embedded card inside a note body: link preview, quote card.
    pub const surface_embed = hex("#101013");
    // The wash a hovered feed row takes. The SDK gives hover as a background
    // step on the hovered widget alone, with no model-visible hover and no way to
    // restyle children, so a row's fill is the only hover state we can express:
    // the redesign's hover-revealed verbs and brightened rules are out of reach.
    pub const surface_hover = hex("#111115");
    // The offline banner: warm and dim, so it reads as information rather than
    // as an error wall.
    pub const surface_offline = hex("#16130c");

    // Borders and dividers.
    //
    // Two divider intents, because the design separates notes differently per
    // surface: `divider_row` between feed rows (the same value the chrome
    // hairlines use, kept as its own name so a change to one cannot move the
    // other), and `divider_reply` between thread reply blocks, profile list
    // rows, and along the quote margin rule, where the line carries more
    // weight. Round 3 brightened the feed value because #26262c vanished at
    // 1px over the near-black window; #1f1f24 is what the Working set draws, so
    // it is verified live per PR and revisited only if it disappears again.
    pub const divider_row = hex("#1f1f24");
    pub const divider_reply = hex("#34343d");
    pub const divider_chrome = hex("#1f1f24");
    // A card's internal rule (the settings identity card, the composer footer).
    pub const divider_card = hex("#1f1f25");
    pub const border_hairline = hex("#26262c");
    pub const border_window = hex("#2a2a30");
    pub const border_control = hex("#2c2c33");
    // A copyable badge pill (npub, nevent) and a settings card outline.
    pub const border_chip = hex("#232329");
    /// 11g's depth-1 pill: the seat a quote-of-a-quote gets instead of a third
    /// nested body.
    pub const surface_pill = hex("#17171b");
    /// The scrim a chip laid over a photograph sits on, dark enough to read
    /// against anything under it, and the hairline around it.
    pub const scrim_chip = canvas.Color.rgba8(10, 10, 11, 179);
    pub const border_chip_alt = hex("#2c2c33");
    /// The two bands of a loading picture's stripe.
    /// 11o's link preview card and the letter tile on it.
    pub const surface_link_card = hex("#101013");
    pub const surface_link_tile = hex("#1f1f25");
    pub const surface_stripe_a = hex("#17171c");
    pub const surface_stripe_b = hex("#1b1b21");
    pub const border_pill = hex("#2c2c33");
    pub const border_menu = hex("#333338");
    pub const border_offline = hex("#3d3320");
    // The sheet outline. Deliberately a clear step above the surface so a modal
    // reads as a bordered, rounded panel, not an edgeless dark shape.
    pub const border_modal = hex("#43434f");
    pub const border_focus = hex("#4a4a56");
    /// 11c's unselected radio ring. A hair off `border_focus` on purpose: a ring
    /// that says "not chosen" and a ring that says "keyboard is here" must be
    /// able to move apart without dragging each other.
    pub const border_radio = hex("#4a4a54");
    pub const border_dashed = hex("#3a3a44");

    /// The one solid light FILL in the app: a checked box, a selected radio's
    /// ring and dot, the Add button's plate. Shares its value with
    /// `text_body_strong` and is deliberately named apart from it, because a
    /// text ramp and a control fill answer to different reasons to change.
    pub const surface_control_solid = hex("#e9e9ec");

    // The chrome accent (the one working accent) and text on it.
    pub const accent = hex("#f2f2f4");
    pub const on_accent = hex("#141416");

    // The IDENTITY accent: violet, and the only colored accent in the app. It
    // is reserved for identity and content, never for chrome: @handles,
    // @mentions inside a note body, and in-text URLs. Chrome stays porcelain.
    // Reaching it from a TextSpan goes through the `info` color token (see
    // `tokens` below), because a span names a token field, not a Color.
    // A light-mode counterpart (#6c53c9) is recorded in the round-5 plan for a
    // future milestone; the app is dark-only today.
    pub const accent_identity = hex("#a08ff7");

    // Text ramp.
    pub const text_primary = hex("#f2f2f4");
    pub const text_body_strong = hex("#e9e9ec");
    pub const text_body = hex("#e4e4e8");
    pub const text_body_soft = hex("#e0e0e5");
    pub const text_focal = hex("#eaeaee");
    pub const text_nested = hex("#dcdce1");
    pub const text_sheet_title = hex("#d6d6dc");
    pub const text_secondary = hex("#c9c9d1");
    pub const text_secondary_alt = hex("#b9b9c2");
    /// A link card's title, a step brighter than the body around it.
    pub const text_link_title = hex("#e4e4e8");
    pub const text_muted = hex("#8f8f99");
    pub const text_muted_alt = hex("#9a9aa4");
    pub const text_faint = hex("#7c7c86");
    pub const text_faint_alt = hex("#6f6f78");
    // The two quietest voices: a mono meta line and a mono section label.
    pub const text_dim = hex("#5c5c66");
    pub const text_label = hex("#77777f");
    pub const text_dim_on_light = hex("#55555e");
    pub const text_offline = hex("#c9b285");

    // The idle engagement metric. The redesign dims the verb cluster with an
    // opacity layer over #8f8f99, but an opacity layer also fades the states that
    // must stay saturated (a liked heart, a zapped bolt), so the dimming is baked
    // into the ink instead: this is #8f8f99 at 75%% over the window.
    pub const text_metric = hex("#6e6e76");

    // The thread's focal verbs: brighter than a feed row's metrics, because these
    // are the actions on the note being read.
    pub const text_verb = hex("#a5a5af");

    // Status.
    pub const status_success = hex("#45c168");
    pub const status_like = hex("#e57373");
    pub const status_warning = hex("#e8a13c");
    // Amber TEXT on a dark surface: the fill amber is too bright to read as a
    // word, so a warning STRING (posting, reconnecting, retry) takes this.
    pub const status_warning_text = hex("#c0964f");
    // Every relay down. Distinct from the like red: this is a hard-stop dot,
    // and the Working set draws it with the traffic-light red.
    pub const status_offline = hex("#ff5f57");

    // Avatar tints: a four-way rotation keyed off the pubkey. Each is a
    // background, a border, and a glyph (initials) color.
    pub const Tint = struct { bg: Color, border: Color, glyph: Color };
    pub const avatar_tints = [_]Tint{
        .{ .bg = hex("#2b2133"), .border = hex("#3a2d49"), .glyph = hex("#cbb3e3") }, // violet
        .{ .bg = hex("#1f2b22"), .border = hex("#2c3f31"), .glyph = hex("#a9d4b4") }, // green
        .{ .bg = hex("#2e2419"), .border = hex("#443626"), .glyph = hex("#e3c39a") }, // amber
        .{ .bg = hex("#232329"), .border = hex("#2c2c33"), .glyph = hex("#b9b9c2") }, // graphite
    };
};

/// Hallway's `defaultPrimaryColor`, transcribed EXACTLY.
///
/// THE NAMES AND THE VALUES ARE HALLWAY'S, for the same reason the place
/// document's field names are: fiatjaf's deployer offers eighteen NAMED colours
/// rather than a free hex, and a place that picks VIOLET has to mean the same
/// violet in both clients or the document stops meaning one thing.
///
/// Each name resolves in Hallway to an HSL triple per colour scheme. These are
/// the DARK rows converted to sRGB, because Plaza is dark-only: the primary,
/// its hover step, and the ink Hallway knocks out of it
/// (`primary-foreground`).
///
/// THE FILLS ARE HALLWAY'S EXACTLY. The INK is not, and that is the one place
/// this table knowingly departs from the source.
///
/// Hallway's dark `primary-foreground` is the same near-black for every row but
/// DEFAULT, and on six fills it loses to the near-white DEFAULT already uses.
/// Two of those are not a shade to argue about but a button whose label is
/// invisible (VIOLET at 2.08:1, INDIGO at 2.39:1), and two more are plainly
/// under (BLUE 3.16:1, PURPLE 3.22:1). CYAN (3.92:1) and RED (4.01:1) are
/// marginal rather than broken, and flip for consistency: the rule is "whichever
/// ink reads better on this fill", applied to all eighteen, not a list of
/// exceptions somebody has to maintain. Worst case afterwards is 4.16:1.
///
/// The colour a community CHOSE is untouched. The fill is still exactly the
/// hex their Hallway deploy paints, so a place still looks like itself in both
/// clients. Only what is written ON it changes, and only where the alternative
/// is unreadable. Copying a legibility bug is not compatibility.
///
/// One thing transcribed rather than corrected: DEFAULT is a magenta, not a
/// neutral. A place that STATES it is asking for that magenta, so it is treated
/// like any other name; only an ABSENT key leaves Plaza's porcelain accent
/// alone.
pub const PlaceColor = struct {
    name: []const u8,
    primary: Color,
    hover: Color,
    on_primary: Color,
    /// The same colour as READABLE TEXT on this app's near-black window, which
    /// is Plaza's own derivation and not a column Hallway has.
    ///
    /// Hallway's `primary` is a FILL: it is painted as a background with
    /// `primary-foreground` knocked out of it, and the web app never sets it as
    /// body text on a dark page. Used that way here it fails: INDIGO (#193ce6)
    /// on #0a0a0b is about 2.5:1, which is not text, it is a rumour of text.
    ///
    /// So the hue and saturation are Hallway's and only the LIGHTNESS is ours,
    /// raised to a floor of 66%. That floor is not a taste: it is the lowest one
    /// at which all eighteen clear 4.5:1 against the window (VIOLET is the
    /// worst at 4.57:1, and 62% would drop it to 3.77:1). The community's hue
    /// still reads as itself; only its brightness is negotiated with the
    /// background it has to survive.
    on_dark: Color,
};

pub const place_colors = [_]PlaceColor{
    .{ .name = "DEFAULT", .primary = hex("#e32b6f"), .hover = hex("#e9538a"), .on_primary = hex("#fafafa"), .on_dark = hex("#eb6696") },
    .{ .name = "RED", .primary = hex("#d74242"), .hover = hex("#e06c6c"), .on_primary = hex("#fafafa"), .on_dark = hex("#e17070") },
    .{ .name = "ORANGE", .primary = hex("#ff8000"), .hover = hex("#ff9933"), .on_primary = hex("#18181b"), .on_dark = hex("#ffa852") },
    .{ .name = "AMBER", .primary = hex("#ffb200"), .hover = hex("#ffc233"), .on_primary = hex("#18181b"), .on_dark = hex("#ffcb52") },
    .{ .name = "YELLOW", .primary = hex("#ffe500"), .hover = hex("#ffeb33"), .on_primary = hex("#18181b"), .on_dark = hex("#ffee52") },
    .{ .name = "LIME", .primary = hex("#80cc33"), .hover = hex("#99d65c"), .on_primary = hex("#18181b"), .on_dark = hex("#a8dc74") },
    .{ .name = "GREEN", .primary = hex("#29a352"), .hover = hex("#33cc66"), .on_primary = hex("#18181b"), .on_dark = hex("#74dc97") },
    .{ .name = "EMERALD", .primary = hex("#1fad7e"), .hover = hex("#26d99d"), .on_primary = hex("#18181b"), .on_dark = hex("#6ce5bd") },
    .{ .name = "TEAL", .primary = hex("#1fadad"), .hover = hex("#26d9d9"), .on_primary = hex("#18181b"), .on_dark = hex("#6ce5e5") },
    .{ .name = "CYAN", .primary = hex("#1f7ead"), .hover = hex("#269dd9"), .on_primary = hex("#fafafa"), .on_dark = hex("#6cbde5") },
    .{ .name = "SKY", .primary = hex("#267fd9"), .hover = hex("#5299e0"), .on_primary = hex("#18181b"), .on_dark = hex("#6ca8e5") },
    .{ .name = "BLUE", .primary = hex("#195de6"), .hover = hex("#477eeb"), .on_primary = hex("#fafafa"), .on_dark = hex("#6391ee") },
    .{ .name = "INDIGO", .primary = hex("#193ce6"), .hover = hex("#4763eb"), .on_primary = hex("#fafafa"), .on_dark = hex("#637aee") },
    .{ .name = "VIOLET", .primary = hex("#3b19e6"), .hover = hex("#6347eb"), .on_primary = hex("#fafafa"), .on_dark = hex("#7a63ee") },
    .{ .name = "PURPLE", .primary = hex("#a219e6"), .hover = hex("#b447eb"), .on_primary = hex("#fafafa"), .on_dark = hex("#bf63ee") },
    .{ .name = "FUCHSIA", .primary = hex("#e619c3"), .hover = hex("#eb47cf"), .on_primary = hex("#18181b"), .on_dark = hex("#ee63d7") },
    .{ .name = "PINK", .primary = hex("#eb4799"), .hover = hex("#f075b3"), .on_primary = hex("#18181b"), .on_dark = hex("#ee63a8") },
    .{ .name = "ROSE", .primary = hex("#eb4763"), .hover = hex("#f0758a"), .on_primary = hex("#18181b"), .on_dark = hex("#ee637a") },
};

/// The colour a `defaultPrimaryColor` names, or null when it names none.
///
/// Case-insensitive: the deployer writes upper case, but a place document is a
/// stranger's JSON and a hand-written one may not. An unknown name is null
/// rather than a guess, which is what keeps a typo from silently repainting the
/// app in whatever colour sorted first.
pub fn placeColor(name: []const u8) ?PlaceColor {
    for (place_colors) |c| {
        if (std.ascii.eqlIgnoreCase(name, c.name)) return c;
    }
    return null;
}

/// What the open place's colour is, asked of the app rather than remembered
/// here.
///
/// A function pointer and not a `pub var` colour, because a cached copy is a
/// copy that can go stale: `g_place` moves on a link, on a rail press, on
/// leaving, on resuming a visit and on boot, and a theme that has to be TOLD
/// about each one is a theme that eventually paints the last room's colour over
/// this one. main.zig installs this once at boot and the answer is read fresh
/// every rebuild.
pub var place_color_fn: ?*const fn () ?PlaceColor = null;

fn activePlaceColor() ?PlaceColor {
    const f = place_color_fn orelse return null;
    return f();
}

/// The theme, consulted every rebuild through `Options.tokens_fn`. It starts
/// from the SDK dark house register (so control tables, motion, and pixel
/// snapping come for free) and overrides the palette, the accent, and the type
/// to Plaza's own. Model-derived appearance (reduced motion, high contrast)
/// will hang off the `model` argument in a later step; for now the look is
/// fixed dark.
pub fn tokens(comptime Model: type) fn (*const Model) canvas.DesignTokens {
    return struct {
        fn build(model: *const Model) canvas.DesignTokens {
            _ = model;
            const p = palette;
            var t = canvas.DesignTokens.theme(.{ .pack = .house, .color_scheme = .dark, .contrast = .standard });

            t.colors.background = p.surface_window;
            t.colors.surface = p.surface_card;
            t.colors.surface_pressed = p.surface_chip;
            // The ONE hover state the redesign has (11e, and locked decision 2):
            // a wash under the whole row, nothing else. The rows that wear it are
            // `data_row`s, and a data row's wash reads THIS token with no control
            // channel of its own, so the wash colour is stated here.
            //
            // It replaces #121216 with #111115, one unit per channel, so every
            // other surface that falls back to it (secondary and ghost buttons,
            // toggles) is unchanged to the eye. Going through the `list_item`
            // control token instead would have been worse than it looks: the
            // press fill resolves as `active orelse HOVER orelse background`, so
            // binding hover there silently repaints every pressed row too.
            t.colors.surface_subtle = p.surface_hover;
            t.colors.text = p.text_primary;
            t.colors.text_muted = p.text_muted;
            t.colors.border = p.border_hairline;
            t.colors.accent = p.accent;
            t.colors.accent_text = p.on_accent;
            t.colors.focus_ring = p.border_focus;
            t.colors.disabled = p.surface_inset;

            // The default scrim is a 10% wash that leans on a backdrop blur for
            // modality; on the real GPU renderer that leaves a sheet barely
            // separated from the feed. Dim the backdrop firmly so every modal
            // (join, compose, name) reads as a raised panel. The value is the
            // redesign's own rgba(5,5,7,.55).
            t.colors.scrim = canvas.Color.rgba8(5, 5, 7, 140);

            // And no backdrop blur, which is the other half of what raising
            // that alpha is for. The toolkit's own note on the token says a
            // theme that firms up the wash should zero this, and Plaza had only
            // ever done the first half.
            //
            // The cost is not the blur itself. Any damage that touches a
            // backdrop blur forces a FULL-SURFACE repaint, because the blur
            // reads pixels around its output as they were at that point in draw
            // order and retained pixels cannot supply them. A modal scrim covers
            // the whole window, so every frame of scrolling inside a sheet
            // repainted the entire window, and the cost grew with the window:
            // present measured 55ms at 760x760 and 183ms at 1600x1000. That is
            // five frames a second on a large window, for a 4 point softness
            // sitting under a 55 percent dim where nobody can see it.
            t.blur.scrim = 0;

            // The identity violet, carried by the `info` slot. A TextSpan names
            // a token FIELD rather than a Color, so a violet @mention needs a
            // channel in this table; `info` is the one slot the app never spends
            // otherwise, and the house default for it is already a violet, so
            // the borrowing is honest rather than a smuggled override. Element
            // foregrounds use `palette.accent_identity` directly.
            t.colors.info = p.accent_identity;

            t.colors.success = p.status_success;
            t.colors.success_text = p.on_accent;
            t.colors.destructive = p.status_like;
            t.colors.destructive_text = p.on_accent;
            t.colors.warning = p.status_warning;
            t.colors.warning_text = p.on_accent;

            // Geist for prose, Geist Mono for the metadata voice, on the
            // BUILT-IN ids, which is what keeps span weights routing to the
            // reserved medium/bold ids (see the module doc). The faces are
            // registered with CoreText from the embedded bytes at startup.
            t.typography.font_id = canvas.default_sans_font_id;
            t.typography.mono_font_id = canvas.default_mono_font_id;
            // A touch larger than the house 14 for a more readable feed body,
            // matching the redesign.
            t.typography.body_size = 14.5;

            // The place's own colour, while the reader is standing in one.
            //
            // This is the ONE deliberate exception to the rule at the top of
            // this file that the chrome carries no coloured primary. The rule's
            // REASON is that a colour in this interface must mean something
            // rather than decorate: violet means a person, amber means a zap.
            // A place is an identity too, somebody's room with their name on
            // it, so the accent saying which room you are standing in is the
            // same job `accent_identity` does for a person, not a brand splash.
            // Out of a place it is porcelain again, and a place that states no
            // colour never reaches here at all.
            //
            // No invalidation of its own: `tokens_fn` is consulted every
            // rebuild, so the first frame after the place moves is already the
            // frame that reads the new colour.
            if (activePlaceColor()) |c| {
                t.colors.accent = c.primary;
                t.colors.accent_text = c.on_primary;
                // The IDENTITY channel, and this is the one that actually makes
                // a room feel like somebody's. The accent reaches a couple of
                // buttons; `info` is what every @handle, @mention and in-text
                // URL in the feed is inked with, so it is the difference
                // between one coloured control and a room that reads as the
                // community's. The violet is Plaza's, and inside a place it has
                // no business overruling the people who live there.
                //
                // `on_dark`, not `primary`: this is TEXT on the near-black
                // window, and Hallway's value is a fill.
                t.colors.info = c.on_dark;
                // And the CONTROL table, which is not redundant with the two
                // lines above: a filled primary resolves its fill from
                // `controls.button_primary` FIRST and only falls through to
                // `colors.accent` when that table's channel is null. The house
                // dark pack fills it, so setting the colour alone would repaint
                // everything except the one control the reader actually presses.
                t.controls.button_primary.background = c.primary;
                t.controls.button_primary.hover_background = c.hover;
                t.controls.button_primary.active_background = c.hover;
                t.controls.button_primary.pressed_background = c.hover;
                t.controls.button_primary.foreground = c.on_primary;
            }

            return t;
        }
    }.build;
}

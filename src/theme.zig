//! Plaza's design tokens: the dark, cool-grey, Geist-set look ratified in the
//! M10 redesign. This is the single source of truth for the app's palette,
//! type, and geometry, transcribed from the spec so no view carries a literal
//! color.
//!
//! Two deliberate, load-bearing choices:
//!   - There is NO colored primary anywhere. The one working accent is a
//!     porcelain white (`accent`) on near-black (`on_accent`). The interface
//!     lives on typography and spacing, not on color.
//!   - The type is Geist (prose) and Geist Mono (metadata, labels, code),
//!     bundled and registered, so the app renders in its own face on every
//!     platform rather than the host system font.
//!
//! Purple is a reserved brand-signal token (the app icon, the mark) and never
//! a fill in the running UI, so it is not among the working tokens here.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// The registered face ids. `native_sdk.canvas.min_registered_font_id` is the
/// first id an app may claim; the built-in ids sit below it.
pub const geist_font_id: canvas.FontId = canvas.min_registered_font_id;
pub const geist_mono_font_id: canvas.FontId = canvas.min_registered_font_id + 1;

/// Raw face bytes, registered on the installing frame (see `main.zig`).
pub const geist_ttf = @embedFile("fonts/Geist-Regular.ttf");
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
    pub const surface_modal = hex("#141419");
    pub const surface_inset = hex("#17171b");
    pub const surface_subbar = hex("#121216");
    pub const surface_input = hex("#0f0f13");
    pub const surface_chip = hex("#1a1a1f");
    pub const surface_toast = hex("#232327");

    // Borders and dividers.
    pub const divider_feedrow = hex("#26262c");
    pub const divider_chrome = hex("#1f1f24");
    pub const border_hairline = hex("#26262c");
    pub const border_window = hex("#2a2a30");
    pub const border_control = hex("#2c2c33");
    pub const border_modal = hex("#33333c");
    pub const border_focus = hex("#4a4a56");
    pub const border_dashed = hex("#3a3a44");

    // Accent (the one working accent) and text on it.
    pub const accent = hex("#f2f2f4");
    pub const on_accent = hex("#141416");
    pub const tab_active_bg = hex("#2a2a31");

    // Text ramp.
    pub const text_primary = hex("#f2f2f4");
    pub const text_body_strong = hex("#e9e9ec");
    pub const text_body = hex("#e4e4e8");
    pub const text_secondary = hex("#c9c9d1");
    pub const text_secondary_alt = hex("#b9b9c2");
    pub const text_muted = hex("#8f8f99");
    pub const text_muted_alt = hex("#9a9aa4");
    pub const text_faint = hex("#7c7c86");
    pub const text_faint_alt = hex("#6f6f78");
    pub const text_dim_on_light = hex("#55555e");

    // Status.
    pub const status_success = hex("#45c168");
    pub const status_like = hex("#e57373");
    pub const status_warning = hex("#e8a13c");

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
            t.colors.surface_subtle = p.surface_subbar;
            t.colors.surface_pressed = p.surface_chip;
            t.colors.text = p.text_primary;
            t.colors.text_muted = p.text_muted;
            t.colors.border = p.border_hairline;
            t.colors.accent = p.accent;
            t.colors.accent_text = p.on_accent;
            t.colors.focus_ring = p.border_focus;
            t.colors.disabled = p.surface_inset;

            t.colors.success = p.status_success;
            t.colors.success_text = p.on_accent;
            t.colors.destructive = p.status_like;
            t.colors.destructive_text = p.on_accent;
            t.colors.warning = p.status_warning;
            t.colors.warning_text = p.on_accent;

            // Geist for prose, Geist Mono for the metadata voice.
            t.typography.font_id = geist_font_id;
            t.typography.mono_font_id = geist_mono_font_id;

            return t;
        }
    }.build;
}

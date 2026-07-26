//! Plaza's registered vector icons: the glyphs the SDK's built-in set does not
//! carry. They are Lucide-style single-color strokes (`currentColor`), tinted by
//! the view's foreground token, and parsed once at comptime.
//!
//! Registered at boot with `canvas.icons.registerAppIcons(app_icons)` and drawn
//! with `ui.appIcon(options, "reply" | "like" | "zap" | "signet" | "bell")`.
//!
//! The redesign's icon set turned out to BE the SDK's built-in set (the same
//! 24x24, stroke-2, round-cap dialect, exported with explicit closing tags), so
//! every lucide-style glyph the Working set uses (chevrons, copy, check-circle,
//! ellipsis, eye, plus, repeat, search, settings, terminal, volume, x, alert,
//! archive, clock, circle-dot, download, edit, external-link, arrows) resolves
//! through `ui.icon`, which compile-checks the name. Comparing the two sets
//! geometrically, 26 of the 31 glyphs the Working set draws are byte-identical to
//! their built-in counterpart; the five below are the ones with no counterpart.
//! `mark` joins them as Plaza's own brand glyph, which no icon set would carry.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const svg_icon = canvas.svg_icon;

const reply_icon = svg_icon.parseComptime(@embedFile("icons/app-reply.svg"));
const like_icon = svg_icon.parseComptime(@embedFile("icons/app-heart.svg"));
const zap_icon = svg_icon.parseComptime(@embedFile("icons/app-zap.svg"));
// The Signet mark: the signer's own boundary glyph, shown wherever a key
// ceremony or the signer's health is in question.
const signet_icon = svg_icon.parseComptime(@embedFile("icons/app-signet.svg"));
// The notifications bell.
const bell_icon = svg_icon.parseComptime(@embedFile("icons/app-bell.svg"));
// The crossroads mark: four filled blocks framing the central void. Single
// color, tinted by the foreground token, resized never redrawn.
const mark_icon = svg_icon.parseComptime(@embedFile("icons/mark.svg"));

pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "reply", .icon = &reply_icon },
    .{ .name = "like", .icon = &like_icon },
    .{ .name = "zap", .icon = &zap_icon },
    .{ .name = "signet", .icon = &signet_icon },
    .{ .name = "bell", .icon = &bell_icon },
    .{ .name = "mark", .icon = &mark_icon },
};

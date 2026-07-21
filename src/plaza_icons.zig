//! Plaza's registered vector icons: the action glyphs the built-in set does
//! not carry (reply, like, zap). Repost reuses the built-in "repeat". They are
//! Lucide-style single-color strokes (`currentColor`), tinted by the view's
//! foreground token, and parsed once at comptime.
//!
//! Registered at boot with `canvas.icons.registerAppIcons(app_icons)` and drawn
//! with `ui.appIcon("reply" | "like" | "zap", ...)`.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const svg_icon = canvas.svg_icon;

const reply_icon = svg_icon.parseComptime(@embedFile("icons/app-reply.svg"));
const like_icon = svg_icon.parseComptime(@embedFile("icons/app-heart.svg"));
const zap_icon = svg_icon.parseComptime(@embedFile("icons/app-zap.svg"));

pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "reply", .icon = &reply_icon },
    .{ .name = "like", .icon = &like_icon },
    .{ .name = "zap", .icon = &zap_icon },
};

//! The one glyph this window draws that the SDK's built-in set does not carry:
//! Notary's own mark. Every other icon here (check, check-circle, terminal,
//! alert) resolves through `ui.icon`, which compile-checks the name.
//!
//! A copy of Plaza's `src/icons/app-notary.svg` rather than a shared file: these
//! are separate build roots and `@embedFile` cannot reach outside its module, so
//! the alternative would be a build-time asset path threaded between two apps for
//! one 200-byte file. If the mark is ever redrawn, both copies change.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const svg_icon = canvas.svg_icon;

const notary_icon = svg_icon.parseComptime(@embedFile("icons/app-notary.svg"));

pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "notary", .icon = &notary_icon },
};

//! Plaza — the flagship native Nostr client.
//!
//! M0 is a minimal native-rendered Native SDK app: a branded window that
//! builds green and opens. The real UI (a local-first feed, community
//! "places", compose) and the `nostr` library integration land in later
//! milestones. The view lives in `app.native` (embedded into the binary and
//! hot-reloaded in dev); this file is the logic: `Model`, `Msg`, and `update`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 440;
const window_height: f32 = 680;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Plaza canvas", .accessibility_label = "Plaza", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Plaza",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

/// No interactions yet — the M0 window is a static splash. Real messages
/// (load feed, switch place, compose, …) arrive with the UI milestones.
pub const Msg = union(enum) {
    noop,
};

pub const Model = struct {};

pub fn update(model: *Model, msg: Msg) void {
    _ = model;
    switch (msg) {
        .noop => {},
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const PlazaApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "plaza",
        .window_title = "Plaza",
        .bundle_id = "com.zig-nostr.plaza",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}

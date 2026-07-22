//! The Signet ceremony window. A small, separate SDK app Plaza spawns for the
//! import ceremony: the nsec is typed HERE, in Signet's own process, and POSTed
//! to the plaza-signer daemon over loopback. Plaza's UI process never sees it.
//! Plaza watches the daemon's /pubkey and signs in the moment the key lands, so
//! this window just does the ceremony and closes.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const canvas_label = "main-canvas";
const daemon_port: u16 = 8790;
const import_key: u64 = 1;
const copy_key: u64 = 2;
const import_command = "/Applications/Plaza.app/Contents/MacOS/plaza-signer import";

// The bearer token for the daemon, read once at boot from ~/.plaza/signer.token.
var g_token_buf: [128]u8 = undefined;
var g_token_len: usize = 0;
fn token() []const u8 {
    return g_token_buf[0..g_token_len];
}

const Stage = enum { paste, importing, done, failed };

const Model = struct {
    stage: Stage = .paste,
    key_buffer: canvas.TextBuffer(200) = .{},
    pass_buffer: canvas.TextBuffer(200) = .{},
    npub_buf: [64]u8 = undefined,
    npub_len: usize = 0,
    msg_buf: [96]u8 = undefined,
    msg_len: usize = 0,

    pub const view_unbound = .{ "stage", "key_buffer", "pass_buffer", "key", "pass", "is_ncryptsec", "npub_hint", "notice", "can_import" };

    pub fn key(self: *const Model) []const u8 {
        return std.mem.trim(u8, self.key_buffer.text(), " \t\r\n");
    }
    pub fn pass(self: *const Model) []const u8 {
        return self.pass_buffer.text();
    }
    pub fn is_ncryptsec(self: *const Model) bool {
        return std.mem.startsWith(u8, self.key(), "ncryptsec1");
    }
    pub fn can_import(self: *const Model) bool {
        const k = self.key();
        if (std.mem.startsWith(u8, k, "nsec1")) return true;
        if (std.mem.startsWith(u8, k, "ncryptsec1")) return self.pass_buffer.text().len > 0;
        return false;
    }
    /// A live "signs as npub1..." for a valid nsec (an ncryptsec needs its
    /// passphrase, so it is confirmed at import instead).
    pub fn npub_hint(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const k = self.key();
        if (!std.mem.startsWith(u8, k, "nsec1")) return "";
        const secret = nostr.nip19.decodeNsec(arena, k) catch return "Not a valid nsec yet.";
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        const kp = signer.keyPairFromSecretKey(secret) catch return "";
        const npub = nostr.nip19.encodeNpub(arena, kp.public_key) catch return "";
        return std.fmt.allocPrint(arena, "Signs as {s}", .{npub}) catch "";
    }
    pub fn notice(self: *const Model) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

const Msg = union(enum) {
    key_edit: canvas.TextInputEvent,
    pass_edit: canvas.TextInputEvent,
    do_import,
    copy_command,
    import_done: native_sdk.EffectResponse,
    close,

    pub const view_unbound = .{ "key_edit", "pass_edit", "do_import", "copy_command", "close" };
};

pub const AppUi = canvas.Ui(Msg);
const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

fn setNotice(model: *Model, text: []const u8) void {
    const n = @min(text.len, model.msg_buf.len);
    @memcpy(model.msg_buf[0..n], text[0..n]);
    model.msg_len = n;
}

fn tokensFn(model: *const Model) canvas.DesignTokens {
    _ = model;
    const C = canvas.Color;
    var t = canvas.DesignTokens.theme(.{ .pack = .house, .color_scheme = .dark, .contrast = .standard });
    // Signet's own register: green-warm ink, so the boundary with Plaza's cool
    // grey is felt. You have left Plaza.
    t.colors.background = C.rgb8(11, 13, 12);
    t.colors.surface = C.rgb8(14, 17, 15);
    t.colors.surface_subtle = C.rgb8(13, 15, 14);
    t.colors.text = C.rgb8(207, 216, 209);
    t.colors.text_muted = C.rgb8(152, 162, 155);
    t.colors.border = C.rgb8(41, 48, 43);
    t.colors.accent = C.rgb8(69, 193, 104); // Signet green
    t.colors.accent_text = C.rgb8(11, 13, 12);
    t.colors.focus_ring = C.rgb8(69, 193, 104);
    return t;
}

fn boot(model: *Model, fx: *Effects) void {
    _ = model;
    _ = fx;
}

fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .key_edit => |e| {
            model.key_buffer.apply(e);
            model.msg_len = 0;
        },
        .pass_edit => |e| model.pass_buffer.apply(e),
        .copy_command => fx.writeClipboard(.{ .key = copy_key, .text = import_command }),
        .do_import => {
            if (!model.can_import()) return;
            if (g_token_len == 0) {
                model.stage = .failed;
                setNotice(model, "Signet isn't running. Start Plaza first.");
                return;
            }
            model.stage = .importing;
            var body_buf: [512]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"method\":\"import\",\"secret\":\"{s}\",\"passphrase\":\"{s}\"}}", .{ model.key(), model.pass() }) catch return;
            var url_buf: [48]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/setup", .{daemon_port}) catch return;
            var auth_buf: [160]u8 = undefined;
            const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token()}) catch return;
            fx.fetch(.{
                .key = import_key,
                .url = url,
                .method = .POST,
                .headers = &.{.{ .name = "Authorization", .value = auth }},
                .body = body,
                .on_response = Effects.responseMsg(.import_done),
            });
        },
        .import_done => |response| {
            // Wipe the typed key: the ceremony is over, and it lives in the
            // daemon now.
            model.key_buffer.clear();
            model.pass_buffer.clear();
            if (response.outcome != .ok or response.status != 200) {
                model.stage = .failed;
                setNotice(model, if (response.status == 409) "A key is already set up." else "Could not import that key.");
                return;
            }
            // Read the pubkey the daemon now holds, to confirm which key landed.
            const gpa = std.heap.page_allocator;
            if (nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body)) |p| {
                var parsed = p;
                defer parsed.deinit();
                var pk: [32]u8 = undefined;
                if (parsed.value.pubkey.len == 64 and (std.fmt.hexToBytes(&pk, parsed.value.pubkey) catch null) != null) {
                    if (nostr.nip19.encodeNpub(gpa, pk)) |npub| {
                        defer gpa.free(npub);
                        const n = @min(npub.len, model.npub_buf.len);
                        @memcpy(model.npub_buf[0..n], npub[0..n]);
                        model.npub_len = n;
                    } else |_| {}
                }
            } else |_| {}
            model.stage = .done;
        },
        .close => fx.closeWindow("main"),
    }
}

fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .grow = 1, .padding = 22, .gap = 12, .style_tokens = .{ .background = .background } }, .{
        ui.text(.{ .size = .heading }, "Signet · Plaza"),
        switch (model.stage) {
            .paste => pasteView(ui, model),
            .importing => ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Handing your key to Signet…"),
            .done => doneView(ui, model),
            .failed => failedView(ui, model),
        },
    });
}

fn pasteView(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .gap = 10, .grow = 1 }, .{
        ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "This key goes to Signet, Plaza's built-in signer. Plaza itself never sees it."),
        ui.el(.textarea, .{
            .text = model.key(),
            .placeholder = "nsec1… or ncryptsec1…",
            .on_input = AppUi.inputMsg(.key_edit),
            .height = 60,
        }, .{}),
        if (model.is_ncryptsec())
            ui.el(.textarea, .{ .text = model.pass(), .placeholder = "Passphrase", .on_input = AppUi.inputMsg(.pass_edit), .height = 36 }, .{})
        else
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.npub_hint(ui.arena)),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .disabled = !model.can_import(), .on_press = .do_import }, "Bring this key in"),
            ui.spacer(1),
            ui.button(.{ .variant = .ghost, .on_press = .close }, "Cancel"),
        }),
        ui.separator(.{}),
        ui.text(.{ .size = .sm, .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "Prefer the terminal? Import without your key ever touching the clipboard or the screen:"),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.text(.{ .size = .sm }, import_command),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .copy_command }, "Copy"),
        }),
    });
}

fn doneView(ui: *AppUi, model: *const Model) AppUi.Node {
    const line = if (model.npub_len > 0)
        std.fmt.allocPrint(ui.arena, "Imported {s}", .{model.npub_buf[0..model.npub_len]}) catch "Imported"
    else
        "Imported";
    return ui.column(.{ .gap = 10 }, .{
        ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .success } }, line),
        ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .text_muted } }, "You're all set. Plaza has picked it up."),
        ui.button(.{ .variant = .primary, .on_press = .close }, "Done"),
    });
}

fn failedView(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .gap = 10 }, .{
        ui.text(.{ .wrap = true, .style_tokens = .{ .foreground = .destructive } }, model.notice()),
        ui.button(.{ .variant = .ghost, .on_press = .close }, "Close"),
    });
}

fn readToken(io: std.Io, environ: *const std.process.Environ.Map) void {
    const home = environ.get("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.plaza/signer.token", .{home}) catch return;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var r = f.reader(io, &buf);
    const n = r.interface.readSliceShort(&buf) catch return;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const len = @min(trimmed.len, g_token_buf.len);
    @memcpy(g_token_buf[0..len], trimmed[0..len]);
    g_token_len = len;
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_view, native_sdk.security.permission_clipboard, native_sdk.security.permission_network };
const shell_views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Signet canvas", .accessibility_label = "Signet", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true }};
const shell_windows = [_]native_sdk.ShellWindow{.{ .label = "main", .title = "Signet · Plaza", .width = 460, .height = 420, .restore_state = false, .views = &shell_views }};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn main(init: std.process.Init) !void {
    readToken(init.io, init.environ_map);
    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "signet-window",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = view,
        .tokens_fn = tokensFn,
    });
    defer app_state.destroy();
    app_state.model = .{};
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "signet-window",
        .window_title = "Signet · Plaza",
        .bundle_id = "com.zig-nostr.signet-window",
        .default_frame = geometry.RectF.init(0, 0, 460, 420),
        .restore_state = false,
        .js_window_api = false,
        .security = .{ .permissions = &app_permissions, .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } } },
    }, init);
}

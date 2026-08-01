//! The Signet window. A small, separate SDK app Plaza spawns whenever a key is
//! about to exist, or whenever the reader wants to look at the one that does: an
//! import, where the nsec is typed HERE in Signet's own process and POSTed to the
//! plaza-signer daemon over loopback; a create, where the daemon mints a fresh
//! key and this window is what says so; and a read-only status, opened from
//! Plaza's settings, which asks the daemon whose key it holds and shows it.
//!
//! Plaza's UI process never sees key material on any path. Plaza watches the
//! daemon's /pubkey and signs in the moment a key lands, so this window just does
//! the ceremony and waits to be dismissed.
//!
//! Its own visual register on purpose: green-warm ink, its own titlebar, its own
//! typeface. You have left Plaza, and it should look like it. That is the whole
//! point of the separate process, so it is worth one window's worth of difference.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const signet_icons = @import("signet_icons.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const canvas_label = "main-canvas";
const daemon_port: u16 = 8790;
const import_key: u64 = 1;
const copy_key: u64 = 2;
const create_key: u64 = 3;
const status_key: u64 = 4;
const import_command = "/Applications/Plaza.app/Contents/MacOS/plaza-signer import";

// 452 wide per the design, and one height for every state rather than a window
// that resizes under the reader. A ceremony window that jumps size between its
// steps reads as two windows.
//
// The height is the TALLEST state's, which is the import once a valid key is in
// the field: the confirmation box appears between the field and the terminal
// card and pushes everything down. Sized for the state without it, the card ran
// off the bottom and the footer band painted straight over it, because a column
// that overflows still lays its children out and still paints them. Measured at
// 467px of content plus the 31px footer, so this is that with room to spare.
const window_width: f32 = 452;
const window_height: f32 = 512;

/// The design's sizes are in px against Plaza's 14.5px body, so they are written
/// as the ratio and stay legible next to the spec.
fn px(size: f32) f32 {
    return size / 14.5;
}

// The bearer token for the daemon, read once at boot from ~/.plaza/signer.token.
var g_token_buf: [128]u8 = undefined;
var g_token_len: usize = 0;
fn token() []const u8 {
    return g_token_buf[0..g_token_len];
}

/// Which ceremony this window was launched for. Set once from argv, before the
/// app exists, because it decides the very first frame.
const Mode = enum { import_key, create_key, status };
var g_mode: Mode = .import_key;

/// How long a finished ceremony stays on screen before the window closes itself.
///
/// Long enough to be read, short enough not to be a step. The terminal states
/// carry no button by design: the ceremony is over, and the only honest thing
/// left to do is get out of the way.
/// The exit code this window uses to say "I minted a key", and the global that
/// remembers whether it did.
///
/// This is the whole channel back to Plaza, and it is deliberately narrow. Plaza
/// cannot tell a key the ceremony made from a key that simply appeared at the
/// daemon's /pubkey (an import, a `plaza-signer import` in a terminal, a leftover
/// from a session that did not shut down cleanly). Only this process knows, and
/// only because it is the one that asked. Guessing from timing instead put "Want
/// a name on it?" in front of imported accounts and rewrote their kind:0.
const created_exit_code: u8 = 9;
var g_created_key = false;

const Stage = enum {
    /// Import: waiting for a key to be pasted.
    paste,
    /// Import: the key is on its way to the daemon.
    importing,
    /// Import: done, holding, then closing.
    imported,
    /// Create: the daemon is minting.
    minting,
    /// Create: done, waiting to be read.
    made,
    /// Status: asking the daemon what it holds.
    looking,
    /// Status: it holds a key, and this is whose.
    holding,
    failed,
};

const Model = struct {
    stage: Stage = .paste,
    key_buffer: canvas.TextBuffer(200) = .{},
    pass_buffer: canvas.TextBuffer(200) = .{},
    npub_buf: [64]u8 = undefined,
    npub_len: usize = 0,
    msg_buf: [96]u8 = undefined,
    msg_len: usize = 0,
    pub const view_unbound = .{ "stage", "key_buffer", "pass_buffer", "key", "pass", "is_ncryptsec", "npub_hint", "notice", "can_import", "key_problem", "npub" };

    pub fn key(self: *const Model) []const u8 {
        return std.mem.trim(u8, self.key_buffer.text(), " \t\r\n");
    }
    pub fn pass(self: *const Model) []const u8 {
        return self.pass_buffer.text();
    }
    pub fn is_ncryptsec(self: *const Model) bool {
        return std.mem.startsWith(u8, self.key(), "ncryptsec1");
    }
    /// Whether there is something here worth sending to the daemon.
    ///
    /// An nsec has to DECODE, not merely start with "nsec1". The prefix alone let
    /// a paste that lost its last characters light the primary button up, and
    /// pressing it walked the reader into the terminal failure state with their
    /// typed key already wiped. An ncryptsec cannot be checked without its
    /// passphrase, so that one is still confirmed on the far side.
    pub fn can_import(self: *const Model, arena: std.mem.Allocator) bool {
        const k = self.key();
        // `npub_hint` IS the decode: it returns the npub this key signs as, and
        // empty when the bech32 does not decode. One check, and it is the same one
        // the reader can see the result of.
        if (std.mem.startsWith(u8, k, "nsec1")) return self.npub_hint(arena).len > 0;
        if (std.mem.startsWith(u8, k, "ncryptsec1")) return self.pass_buffer.text().len > 0;
        return false;
    }

    /// What to say about a key that is present but unusable. Empty when there is
    /// nothing to say: an empty field is not an error, it is the starting state.
    pub fn key_problem(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const k = self.key();
        if (k.len == 0) return "";
        if (std.mem.startsWith(u8, k, "ncryptsec1")) return "";
        if (!std.mem.startsWith(u8, k, "nsec1")) return "That is not an nsec or an ncryptsec.";
        if (self.npub_hint(arena).len > 0) return "";
        // Reached by the ordinary accident: a paste that lost its tail. Saying
        // nothing here (which is what the first version of this window did after
        // its error string was dropped) leaves an enabled button over a key that
        // cannot work.
        return "Not a valid nsec yet.";
    }
    pub fn npub(self: *const Model) []const u8 {
        return self.npub_buf[0..self.npub_len];
    }
    /// A live "signs as npub1..." for a valid nsec (an ncryptsec needs its
    /// passphrase, so it is confirmed at import instead).
    pub fn npub_hint(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const k = self.key();
        if (!std.mem.startsWith(u8, k, "nsec1")) return "";
        const secret = nostr.nip19.decodeNsec(arena, k) catch return "";
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        const kp = signer.keyPairFromSecretKey(secret) catch return "";
        return nostr.nip19.encodeNpub(arena, kp.public_key) catch "";
    }
    pub fn notice(self: *const Model) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

const Msg = union(enum) {
    key_edit: canvas.TextInputEvent,
    pass_edit: canvas.TextInputEvent,
    do_import,
    do_create,
    copy_command,
    import_done: native_sdk.EffectResponse,
    create_done: native_sdk.EffectResponse,
    status_done: native_sdk.EffectResponse,
    close,

    pub const view_unbound = .{ "key_edit", "pass_edit", "do_import", "do_create", "copy_command", "close" };
};

pub const AppUi = canvas.Ui(Msg);
const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

// ---------------------------------------------------------------- the palette
//
// Signet's own, stated as the design states it. Not design tokens: the ceremony
// window's whole job is to look like somewhere else, and a token set that tracks
// Plaza's would quietly undo that on the next theme change.
const C = canvas.Color;
const ink = struct {
    const bg = C.rgb8(11, 13, 12);
    const border = C.rgb8(41, 48, 43);
    const hairline = C.rgb8(28, 33, 29);
    const chrome_text = C.rgb8(170, 181, 173);
    const signet = C.rgb8(69, 193, 104);
    const title = C.rgb8(207, 216, 209);
    const body = C.rgb8(152, 162, 155);
    const field_bg = C.rgb8(14, 17, 15);
    const field_border = C.rgb8(44, 51, 46);
    const good_bg = C.rgb8(16, 22, 15);
    const good_border = C.rgb8(36, 53, 42);
    const good_text = C.rgb8(143, 191, 158);
    const card_bg = C.rgb8(13, 15, 14);
    const card_border = C.rgb8(35, 41, 37);
    const card_text = C.rgb8(143, 154, 146);
    const command_bg = C.rgb8(9, 11, 10);
    const command_border = C.rgb8(30, 36, 32);
    const command_text = C.rgb8(194, 204, 197);
    const footnote = C.rgb8(106, 117, 109);
    const footer = C.rgb8(95, 106, 99);
    const white = C.rgb8(242, 242, 244);
    const on_white = C.rgb8(20, 20, 22);
    const bad = C.rgb8(229, 115, 115);
};

fn setNotice(model: *Model, text: []const u8) void {
    const n = @min(text.len, model.msg_buf.len);
    @memcpy(model.msg_buf[0..n], text[0..n]);
    model.msg_len = n;
}

fn tokensFn(model: *const Model) canvas.DesignTokens {
    _ = model;
    var t = canvas.DesignTokens.theme(.{ .pack = .house, .color_scheme = .dark, .contrast = .standard });
    // Same body size as Plaza, so a shared px figure means the same thing in both
    // windows even though the faces differ.
    t.typography.body_size = 14.5;
    t.colors.background = ink.bg;
    t.colors.surface = ink.field_bg;
    t.colors.surface_subtle = ink.card_bg;
    t.colors.text = ink.title;
    t.colors.text_muted = ink.body;
    t.colors.border = ink.border;
    // The primary action is WHITE, not Signet green. Green here means identity:
    // the mark, and the key that checked out. A green button would put the same
    // signal on "press this", and the one place a reader must not misread is the
    // button that hands over a key.
    t.colors.accent = ink.white;
    t.colors.accent_text = ink.on_white;
    t.colors.focus_ring = ink.signet;
    return t;
}

fn boot(model: *Model, fx: *Effects) void {
    canvas.icons.registerAppIcons(&signet_icons.app_icons);
    if (g_mode == .create_key) {
        model.stage = .minting;
        requestCreate(model, fx);
    }
    if (g_mode == .status) {
        model.stage = .looking;
        requestStatus(model, fx);
    }
}

/// Asks the daemon for a fresh key. This window OWNS the create, rather than
/// watching one Plaza started, because only the side that made the request can
/// tell a key it just minted from a key that happened to already be there: a
/// watcher polling /pubkey sees "ready" either way and would announce a stranger's
/// leftover key as the reader's new identity. The response here is the answer.
fn requestCreate(model: *Model, fx: *Effects) void {
    if (g_token_len == 0) {
        model.stage = .failed;
        setNotice(model, "Signet isn't running. Start Plaza first.");
        return;
    }
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/setup", .{daemon_port}) catch return;
    var auth_buf: [160]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token()}) catch return;
    fx.fetch(.{
        .key = create_key,
        .url = url,
        .method = .POST,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .body = "{\"method\":\"create\"}",
        .on_response = Effects.responseMsg(.create_done),
    });
}

/// Asks the daemon whose key it is holding, for the window opened from Plaza's
/// settings rather than from a ceremony. Read-only: this mode never sets a key
/// up, imports one or resets one, so the worst it can do is report.
fn requestStatus(model: *Model, fx: *Effects) void {
    if (g_token_len == 0) {
        model.stage = .failed;
        setNotice(model, "Signet isn't running. Start Plaza first.");
        return;
    }
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/pubkey", .{daemon_port}) catch return;
    var auth_buf: [160]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token()}) catch return;
    fx.fetch(.{
        .key = status_key,
        .url = url,
        .method = .GET,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .on_response = Effects.responseMsg(.status_done),
    });
}

/// Reads the pubkey the daemon reports back and remembers it as an npub. Returns
/// false when the body is not a pubkey, which is the daemon answering something
/// this window does not understand.
fn adoptPubkey(model: *Model, body: []const u8) bool {
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, body) catch return false;
    defer parsed.deinit();
    if (parsed.value.pubkey.len != 64) return false;
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, parsed.value.pubkey) catch return false;
    const npub = nostr.nip19.encodeNpub(gpa, pk) catch return false;
    defer gpa.free(npub);
    const n = @min(npub.len, model.npub_buf.len);
    @memcpy(model.npub_buf[0..n], npub[0..n]);
    model.npub_len = n;
    return true;
}

fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .key_edit => |e| {
            model.key_buffer.apply(e);
            model.msg_len = 0;
        },
        .pass_edit => |e| model.pass_buffer.apply(e),
        .copy_command => fx.writeClipboard(.{ .key = copy_key, .text = import_command }),
        .do_create => {
            model.stage = .minting;
            requestCreate(model, fx);
        },
        .do_import => {
            // Re-checked here, not only where the button is drawn: a keyboard
            // submit reaches this arm without passing the disabled state.
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            if (!model.can_import(scratch.allocator())) return;
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
            _ = adoptPubkey(model, response.body);
            model.stage = .imported;
        },
        .create_done => |response| {
            if (response.outcome != .ok or response.status != 200) {
                model.stage = .failed;
                setNotice(model, if (response.status == 409)
                    "A key is already set up."
                else if (response.outcome != .ok)
                    "Signet isn't answering yet."
                else
                    "Signet could not make a key.");
                return;
            }
            _ = adoptPubkey(model, response.body);
            // Said once, here, where the daemon has just answered 200 to a create
            // this process sent. Nothing else in either program can establish it.
            g_created_key = true;
            model.stage = .made;
        },
        .status_done => |response| {
            // A daemon that is up but holding nothing answers 200 with no key,
            // or 404, depending on how it says "not set up". Either way there is
            // no npub to show, and saying so is the honest report.
            if (response.outcome != .ok or response.status != 200 or !adoptPubkey(model, response.body)) {
                model.stage = .failed;
                setNotice(model, if (response.outcome != .ok)
                    "Signet isn't answering."
                else
                    "Signet is running, and holds no key yet.");
                return;
            }
            model.stage = .holding;
        },
        .close => fx.closeWindow("main"),
    }
}

// ---------------------------------------------------------------- the window

fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .grow = 1, .gap = 0, .style = .{ .background = ink.bg } }, .{
        titleBar(ui),
        rule(ui),
        switch (model.stage) {
            .paste => pasteView(ui, model),
            .importing => waitingView(ui, "Handing your key to Signet"),
            .minting => waitingView(ui, "Making your key"),
            .imported => importedView(ui, model),
            .made => madeView(ui, model),
            .looking => waitingView(ui, "Asking Signet"),
            .holding => holdingView(ui, model),
            .failed => failedView(ui, model),
        },
        // The footer belongs to the ceremony, not to its result: on the terminal
        // states the sentence has already been proved and repeating it there
        // would be the window arguing with itself.
        if (model.stage == .paste or model.stage == .importing) footerBand(ui) else ui.spacer(0),
    });
}

fn titleBar(ui: *AppUi) AppUi.Node {
    return ui.row(.{ .height = 40, .cross = .center, .main = .center, .gap = 0 }, .{
        ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = ink.signet } }, "signet"),
        hgap(ui, 6),
        ui.paragraph(
            .{ .style = .{ .foreground = ink.chrome_text } },
            &.{.{ .text = "Signet · Plaza", .monospace = true, .weight = .medium, .scale = px(11) }},
        ),
    });
}

fn footerBand(ui: *AppUi) AppUi.Node {
    return ui.column(.{ .gap = 0 }, .{
        rule(ui),
        ui.row(.{ .height = 30, .cross = .center, .main = .center, .gap = 0 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = ink.footer } },
                // Two clauses, not the design's three. The dropped one claimed
                // "encrypted at rest", which the daemon does not do: the key is a
                // raw 32-byte secret in a 0600 file. Process isolation IS the
                // property this window provides, and it is the one worth stating.
                //
                // Short because this band does not wrap and the window is 452
                // wide: a longer line does not shrink, it walks off the right
                // edge, which the first draft's did. The clause it lost is
                // already in the explainer above, where there is room for it.
                &.{.{ .text = "isolated signer process · closes when done", .monospace = true, .scale = px(10) }},
            ),
        }),
    });
}

fn rule(ui: *AppUi) AppUi.Node {
    return ui.separator(.{ .style = .{ .foreground = ink.hairline, .background = ink.hairline } });
}

fn hgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .width = size }, .{});
}

fn vgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .height = size }, .{});
}

/// The body's horizontal inset, as a row that holds a growing column.
fn inset(ui: *AppUi, pad: f32, inner: AppUi.Node) AppUi.Node {
    return ui.row(.{ .gap = 0 }, .{ hgap(ui, pad), inner, hgap(ui, pad) });
}

// ---------------------------------------------------------------- IMPORT

fn pasteView(ui: *AppUi, model: *const Model) AppUi.Node {
    const hint = model.npub_hint(ui.arena);
    const problem = model.key_problem(ui.arena);
    return ui.column(.{ .grow = 1, .gap = 0 }, .{
        vgap(ui, 20),
        inset(ui, 22, ui.column(.{ .grow = 1, .gap = 11 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = ink.title } },
                &.{.{ .text = "Bring your key in", .weight = .bold, .scale = px(18) }},
            ),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = ink.body } },
                &.{
                    .{ .text = "This key goes to ", .scale = px(12.5) },
                    .{ .text = "Signet", .weight = .bold, .color = .text, .scale = px(12.5) },
                    .{ .text = ", the separate process that holds it and does the signing. Plaza's own window never sees it.", .scale = px(12.5) },
                },
            ),
            ui.el(.textarea, .{
                .text = model.key(),
                .placeholder = "nsec1… or ncryptsec1…",
                .on_input = AppUi.inputMsg(.key_edit),
                .height = 56,
                .style = .{ .background = ink.field_bg, .border = ink.field_border, .radius = 9, .stroke_width = 1 },
            }, .{}),
            if (model.is_ncryptsec())
                ui.el(.textarea, .{
                    .text = model.pass(),
                    .placeholder = "Passphrase",
                    .on_input = AppUi.inputMsg(.pass_edit),
                    .height = 36,
                    .style = .{ .background = ink.field_bg, .border = ink.field_border, .radius = 9, .stroke_width = 1 },
                }, .{})
            else if (hint.len > 0)
                validKeyBox(ui, hint)
            else if (problem.len > 0)
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = ink.bad } },
                    &.{.{ .text = problem, .scale = px(11.5) }},
                )
            else
                ui.spacer(0),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.button(.{ .variant = .primary, .disabled = !model.can_import(ui.arena), .on_press = .do_import }, "Import this key"),
                ui.spacer(1),
                ui.button(.{ .variant = .ghost, .on_press = .close }, "Cancel"),
            }),
            terminalCard(ui),
        })),
        ui.spacer(1),
    });
}

/// The live confirmation: which identity this key signs as, before it is handed
/// over. Only for a plain nsec; an ncryptsec cannot be read without its
/// passphrase, so that one is confirmed on the other side of the import.
fn validKeyBox(ui: *AppUi, npub: []const u8) AppUi.Node {
    return ui.el(.panel, .{
        .padding = 0.01,
        .style = .{ .background = ink.good_bg, .border = ink.good_border, .radius = 9, .stroke_width = 1 },
    }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 11),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 9),
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = ink.good_text } }, "check"),
                    hgap(ui, 9),
                    ui.paragraph(
                        .{ .style = .{ .foreground = ink.title } },
                        &.{.{ .text = "Valid key. It signs as", .scale = px(12) }},
                    ),
                }),
                vgap(ui, 4),
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = ink.good_text } },
                    &.{.{ .text = npub, .monospace = true, .scale = px(11) }},
                ),
                vgap(ui, 9),
            }),
            hgap(ui, 11),
        }),
    });
}

/// The stronger path, offered rather than hidden: a key typed into a terminal
/// never touches the clipboard, the screen, or this window's text buffer.
fn terminalCard(ui: *AppUi) AppUi.Node {
    return ui.el(.panel, .{
        .padding = 0.01,
        .style = .{ .background = ink.card_bg, .border = ink.card_border, .radius = 10, .stroke_width = 1 },
    }, .{
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 12),
            ui.column(.{ .grow = 1, .gap = 7 }, .{
                vgap(ui, 11),
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = ink.card_text } }, "terminal"),
                    hgap(ui, 7),
                    ui.paragraph(
                        .{ .style = .{ .foreground = ink.card_text } },
                        &.{.{ .text = "Prefer the terminal? Nothing is pasted anywhere:", .scale = px(11.5) }},
                    ),
                    ui.spacer(1),
                    // Beside the LABEL, not beside the command. Sharing the
                    // command's row left it about 300px, and the path is 58
                    // monospace characters, so it wrapped: not at the one space
                    // in it, but mid-token, splitting the binary's name across
                    // two lines. A command a reader might retype has to be
                    // readable as one string.
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .copy_command }, "Copy"),
                }),
                ui.el(.panel, .{
                    .padding = 0.01,
                    .style = .{ .background = ink.command_bg, .border = ink.command_border, .radius = 7, .stroke_width = 1 },
                }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 9),
                        ui.column(.{ .grow = 1, .gap = 0 }, .{
                            vgap(ui, 7),
                            ui.paragraph(
                                .{ .wrap = true, .style = .{ .foreground = ink.command_text } },
                                &.{.{ .text = import_command, .monospace = true, .scale = px(10) }},
                            ),
                            vgap(ui, 7),
                        }),
                        hgap(ui, 9),
                    }),
                }),
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = ink.footnote } },
                    &.{.{ .text = "Run it in Terminal while Plaza is open.", .monospace = true, .scale = px(10) }},
                ),
                vgap(ui, 11),
            }),
            hgap(ui, 12),
        }),
    });
}

// ---------------------------------------------------------------- the results

/// The shape both terminal states share: a mark, a line, a sub, and
/// the sentence saying the window is about to leave.
fn resultView(ui: *AppUi, model: *const Model, mark: AppUi.Node, title: []const u8, sub: []const u8, tail: []const u8) AppUi.Node {
    return ui.column(.{ .grow = 1, .gap = 0, .cross = .center }, .{
        ui.spacer(1),
        mark,
        vgap(ui, 12),
        ui.paragraph(
            .{ .style = .{ .foreground = ink.title } },
            &.{.{ .text = title, .weight = .medium, .scale = px(15) }},
        ),
        vgap(ui, 8),
        // The 330px column the design gives this text, as a GROWING column between
        // two fixed insets. `wrap` alone does nothing here: a paragraph that is a
        // plain flow child of a row takes its intrinsic width, which for one long
        // sentence is wider than the window, so it ran straight off the right edge
        // with the wrap flag set and obeyed. Something has to bound it.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 61),
            ui.column(.{ .grow = 1, .gap = 8 }, .{
                ui.paragraph(
                    .{ .wrap = true, .text_alignment = .center, .style = .{ .foreground = ink.body } },
                    &.{.{ .text = sub, .scale = px(12.5) }},
                ),
                // An npub is 63 monospace characters, which is wider than this
                // window at any size it is legible at, so it always wraps.
                if (model.npub_len > 0)
                    ui.paragraph(
                        .{ .wrap = true, .text_alignment = .center, .style = .{ .foreground = ink.good_text } },
                        &.{.{ .text = model.npub(), .monospace = true, .scale = px(11) }},
                    )
                else
                    ui.spacer(0),
            }),
            hgap(ui, 61),
        }),
        vgap(ui, 18),
        // The way out is a press, not a countdown. This window exists so the key
        // ceremony can be WATCHED happening outside Plaza, and it used to answer
        // that by showing the result for two seconds and closing itself: from the
        // reader's side a window appeared, flashed something, and was gone,
        // followed by Plaza asking for a name. A ceremony you cannot finish
        // reading is not one you were shown.
        ui.button(.{ .variant = .primary, .on_press = .close }, tail),
        ui.spacer(1),
    });
}

fn importedView(ui: *AppUi, model: *const Model) AppUi.Node {
    return resultView(
        ui,
        model,
        ui.icon(.{ .width = 30, .height = 30, .style = .{ .foreground = ink.signet } }, "check-circle"),
        "Your key is in Signet",
        "Signet holds it now and does the signing. Plaza asks; it never has the key.",
        "Continue to Plaza",
    );
}

fn madeView(ui: *AppUi, model: *const Model) AppUi.Node {
    return resultView(
        ui,
        model,
        ui.appIcon(.{ .width = 30, .height = 30, .style = .{ .foreground = ink.signet } }, "signet"),
        "Your identity is ready",
        "Signet made the key and keeps it. Nothing to write down, nothing to remember.",
        "Continue to Plaza",
    );
}

/// What Signet holds, for a reader who came to look rather than to do anything.
/// The same shape as a finished ceremony, because it is the same fact: this
/// process has the key, and here is whose it is.
fn holdingView(ui: *AppUi, model: *const Model) AppUi.Node {
    return resultView(
        ui,
        model,
        ui.appIcon(.{ .width = 30, .height = 30, .style = .{ .foreground = ink.signet } }, "signet"),
        "Signet is holding your key",
        "It signs when Plaza asks. The key is on this Mac, in this process, and has never been in Plaza.",
        "Close",
    );
}

fn waitingView(ui: *AppUi, line: []const u8) AppUi.Node {
    return ui.column(.{ .grow = 1, .gap = 0, .cross = .center }, .{
        ui.spacer(1),
        ui.paragraph(
            .{ .style = .{ .foreground = ink.body } },
            &.{.{ .text = line, .scale = px(12.5) }},
        ),
        ui.spacer(1),
    });
}

fn failedView(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .grow = 1, .gap = 0, .cross = .center }, .{
        ui.spacer(1),
        ui.icon(.{ .width = 24, .height = 24, .style = .{ .foreground = ink.bad } }, "alert"),
        vgap(ui, 12),
        // Bounded, for the same reason the result view's sub is: a centered column
        // gives its children their intrinsic width, and an unbounded sentence is
        // as wide as it wants to be.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 61),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.paragraph(
                    .{ .wrap = true, .text_alignment = .center, .style = .{ .foreground = ink.bad } },
                    &.{.{ .text = model.notice(), .scale = px(12.5) }},
                ),
            }),
            hgap(ui, 61),
        }),
        vgap(ui, 14),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            // A create has nothing to go back to in this window, so the retry is
            // here. An import still has the typed field behind this state, which
            // is why it only offers the way out.
            if (g_mode == .create_key)
                ui.button(.{ .variant = .primary, .on_press = .do_create }, "Try again")
            else
                ui.spacer(0),
            ui.button(.{ .variant = .ghost, .on_press = .close }, "Close"),
        }),
        ui.spacer(1),
    });
}

// ---------------------------------------------------------------- boot

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

/// `--create` selects the create ceremony, `--status` the read-only look at what
/// Signet is holding, and anything else is the import. Read
/// through `std.process.Args`, because `std.os.argv` no longer exists.
fn readMode(init: std.process.Init) void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv0
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--create")) g_mode = .create_key;
        if (std.mem.eql(u8, arg, "--status")) g_mode = .status;
    }
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_view, native_sdk.security.permission_clipboard, native_sdk.security.permission_network };
const shell_views = [_]native_sdk.ShellView{.{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Signet canvas", .accessibility_label = "Signet", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true }};
const shell_windows = [_]native_sdk.ShellWindow{.{ .label = "main", .title = "Signet · Plaza", .width = window_width, .height = window_height, .restore_state = false, .views = &shell_views }};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn main(init: std.process.Init) !void {
    readToken(init.io, init.environ_map);
    readMode(init);
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
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{ .permissions = &app_permissions, .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } } },
    }, init);
    // After the window is down and the app is torn down, so this is the last
    // thing the process does. An import, a cancel, a failure and a crash all
    // leave the code at 0 and tell Plaza nothing, which is correct: none of them
    // made a key.
    if (g_created_key) std.process.exit(created_exit_code);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Walks the built tree for a control with this accessibility label or these
/// words on it, which is how a test asks whether the reader has a way out.
fn hasControl(widget: canvas.Widget, label: []const u8) bool {
    if (std.mem.eql(u8, widget.semantics.label, label)) return true;
    if (widget.kind == .button and std.mem.eql(u8, widget.text, label)) return true;
    for (widget.children) |child| {
        if (hasControl(child, label)) return true;
    }
    return false;
}

test "a finished ceremony waits for the reader" {
    // It used to show the result for two seconds and close itself, so from the
    // reader's side a window appeared, flashed something, and was gone, with
    // Plaza's "Want a name on it?" arriving in its place. This window exists so
    // the key ceremony can be watched happening outside Plaza; a ceremony you
    // cannot finish reading is not one you were shown.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]Stage{ .made, .imported }) |stage| {
        var model = Model{};
        model.stage = stage;
        var ui = AppUi.init(arena);
        const tree = try ui.finalize(view(&ui, &model));
        if (!hasControl(tree.root, "Continue to Plaza")) {
            std.debug.print("the {s} state offers the reader no way on\n", .{@tagName(stage)});
            return error.NoWayOut;
        }
    }

    // And the states that are NOT finished do not offer it: a way out of a
    // ceremony still in flight would close the window mid-mint.
    for ([_]Stage{ .minting, .importing }) |stage| {
        var model = Model{};
        model.stage = stage;
        var ui = AppUi.init(arena);
        const tree = try ui.finalize(view(&ui, &model));
        try testing.expect(!hasControl(tree.root, "Continue to Plaza"));
    }
}

test "the import button is only offered when there is something to import" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    try testing.expect(!model.can_import(arena));
    // An empty field is the starting state, not a mistake, so it says nothing.
    try testing.expectEqualStrings("", model.key_problem(arena));

    // An ncryptsec cannot be read without its passphrase, so offering the button
    // before one is typed would be offering a press that fails.
    model.key_buffer.set("ncryptsec1qqqqq");
    try testing.expect(!model.can_import(arena));
    model.pass_buffer.set("hunter2");
    try testing.expect(model.can_import(arena));

    // Anything that is neither is not a key, whatever it looks like.
    model.key_buffer.set("npub1qqqqq");
    model.pass_buffer.clear();
    try testing.expect(!model.can_import(arena));
    try testing.expectEqualStrings("That is not an nsec or an ncryptsec.", model.key_problem(arena));
}

test "an nsec that does not decode is refused, and said so" {
    // The prefix is not the key. A paste that lost its tail still starts with
    // "nsec1", and checking only that lit the primary button up over something
    // the daemon would reject, after which the window's terminal failure state
    // had already wiped what was typed. Worse, the line that used to say "Not a
    // valid nsec yet." had been dropped, so the reader saw NOTHING: no
    // confirmation, no error, and an enabled button.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The secret 0x00..01, encoded. A published constant, not anybody's key, and
    // deterministic so this test does not depend on a generator.
    const valid_nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsmhltgl";
    var model = Model{};
    model.key_buffer.set(valid_nsec);
    const whole_valid = model.can_import(arena);

    // The same key with its last character gone, which is what a clipped paste
    // looks like.
    model.key_buffer.set(valid_nsec[0 .. valid_nsec.len - 1]);
    try testing.expect(!model.can_import(arena));
    try testing.expectEqualStrings("Not a valid nsec yet.", model.key_problem(arena));
    try testing.expectEqualStrings("", model.npub_hint(arena));

    // And the intact one is still accepted, so the check is not simply refusing
    // everything.
    try testing.expect(whole_valid);
}

//! Plaza — the flagship native Nostr client.
//!
//! M1 is the architecture spike: it proves the one-process bet end to end.
//! `nostr` (which vendors secp256k1 + LMDB) links directly into this app, the
//! local store opens in the render process, a background thread dials a relay
//! and writes matching notes into that same store, and the UI thread renders a
//! live list straight from `store.query`. No IPC, no second process — the
//! local-first feed reads from disk with zero copies. The real product (a relay
//! pool with the outbox model, community "places", compose, onboarding) lands
//! in the milestones ahead; here one relay and a read-only feed are enough to
//! retire the architecture risk.
//!
//! The view lives in `app.native`; this file is the logic. The window and the
//! background ingest are wired in `main`. `update` stays a pure state
//! transition, driven by a repeating timer that re-queries the store.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 440;
const window_height: f32 = 680;

// The one relay this spike dials, and how many recent notes to keep on screen.
// A real client resolves relays from the outbox model (NIP-65) across a pool —
// that is a later milestone; here a single hardcoded relay proves the pipeline.
const relay_url = "wss://relay.damus.io";
const feed_capacity = 40;
// Timer keys are their own namespace; one repeating refresh is all we need.
const refresh_timer_key: u64 = 1;
const refresh_interval_ms: u64 = 1_000;

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

// ------------------------------------------------- one-process runtime wiring
//
// A native app is a single process and a single instance, so the one shared
// store and the ingest thread's connection state live as process globals. This
// keeps the Model pure view state (the framework reflects Model/Msg for markup
// checking, so it stays free of runtime pointers). Sharing the store across the
// UI and ingest threads is safe: LMDB serialises its own writers and hands
// readers an MVCC snapshot, and every `nostr.store` call is a self-contained
// transaction on its calling thread.

const Conn = enum(u8) { connecting = 0, connected = 1, offline = 2 };

var g_store: ?*nostr.store.Store = null;
var g_conn = std.atomic.Value(u8).init(@intFromEnum(Conn.connecting));

// ------------------------------------------------------------------ model

/// One note as the feed renders it: an abbreviated author, the (truncated)
/// content, and a stable key. Strings are copied into fixed buffers so a row
/// never aliases the transient query arena it was built from.
pub const Note = struct {
    // A stable-per-event key for `<for each key="id">`. The markup engine holds
    // an integer key as i64 and then casts it to u64, so the key must be a
    // NON-NEGATIVE i64 — `noteFrom` takes the id's high 63 bits (sign bit
    // masked off), which stays plenty unique across a screenful of notes.
    id: i64 = 0,
    author_buf: [11]u8 = [_]u8{0} ** 11,
    author_len: u8 = 0,
    content_buf: [200]u8 = [_]u8{0} ** 200,
    content_len: u16 = 0,
    created_at: i64 = 0,

    pub fn author(self: *const Note) []const u8 {
        return self.author_buf[0..self.author_len];
    }
    pub fn content(self: *const Note) []const u8 {
        return self.content_buf[0..self.content_len];
    }
};

pub const Model = struct {
    notes: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity,
    notes_len: usize = 0,
    conn: Conn = .connecting,

    // These fields reach the view only through methods — `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, `conn` through
    // `status`/`empty_text` — so the raw fields are never bound by name.
    pub const view_unbound = .{ "notes", "notes_len", "conn" };

    /// The feed, iterated by `<for each="note_list">`, newest first.
    pub fn note_list(self: *const Model, arena: std.mem.Allocator) []const Note {
        _ = arena;
        return self.notes[0..self.notes_len];
    }
    pub fn has_notes(self: *const Model) bool {
        return self.notes_len > 0;
    }
    pub fn empty(self: *const Model) bool {
        return self.notes_len == 0;
    }
    /// Connection line under the title.
    pub fn status(self: *const Model) []const u8 {
        return switch (self.conn) {
            .connecting => "Connecting to " ++ relay_url ++ " …",
            .connected => "Connected to " ++ relay_url,
            .offline => "Offline — reconnecting…",
        };
    }
    /// Body message while the feed is empty.
    pub fn empty_text(self: *const Model) []const u8 {
        return switch (self.conn) {
            .connected => "Waiting for notes…",
            else => "Connecting…",
        };
    }
    /// Status-bar count.
    pub fn footer(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d} notes", .{self.notes_len}) catch "";
    }

    /// Refills the feed from the shared store: the most recent kind:1 notes,
    /// newest first. Runs on the UI thread each timer tick; copies each note's
    /// text into the Model so it outlives the transient query result.
    fn refresh(self: *Model) void {
        self.conn = @enumFromInt(g_conn.load(.acquire));
        const store = g_store orelse return;
        const kinds = [_]u16{1};
        var result = store.query(std.heap.page_allocator, .{ .kinds = &kinds, .limit = feed_capacity }) catch return;
        defer result.deinit();
        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= feed_capacity) break;
            self.notes[n] = noteFrom(ev);
            n += 1;
        }
        self.notes_len = n;
    }
};

/// Builds a `Note` view-model from a stored event.
pub fn noteFrom(ev: nostr.event.Event) Note {
    var note = Note{
        .created_at = ev.created_at,
        .id = @intCast(std.mem.readInt(u64, ev.id[0..8], .big) & std.math.maxInt(i64)),
    };
    // Author: the first four pubkey bytes as hex, then an ellipsis (8 + 3 = 11).
    const hexdigits = "0123456789abcdef";
    for (0..4) |i| {
        note.author_buf[i * 2] = hexdigits[ev.pubkey[i] >> 4];
        note.author_buf[i * 2 + 1] = hexdigits[ev.pubkey[i] & 0x0f];
    }
    @memcpy(note.author_buf[8..11], "…"); // U+2026, three bytes
    note.author_len = 11;
    // Content: copied up to the buffer, trimmed back to a UTF-8 boundary so a
    // split multi-byte codepoint never reaches the text shaper.
    const clen = utf8SafeLen(ev.content, note.content_buf.len);
    @memcpy(note.content_buf[0..clen], ev.content[0..clen]);
    note.content_len = @intCast(clen);
    return note;
}

/// The largest prefix of `s` no longer than `max` that ends on a UTF-8
/// codepoint boundary (never mid-sequence).
fn utf8SafeLen(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

// -------------------------------------------------------------------- msg

pub const Msg = union(enum) {
    /// The repeating refresh timer fired: re-query the store into the Model.
    tick: native_sdk.EffectTimer,

    // `tick` is dispatched by the refresh timer in Zig, never from markup.
    pub const view_unbound = .{"tick"};
};

// ---------------------------------------------------------------- app + view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

const PlazaApp = native_sdk.UiApp(Model, Msg);
const Effects = PlazaApp.Effects;

/// Boot: seed the feed once, then arm the repeating refresh timer.
pub fn boot(model: *Model, fx: *Effects) void {
    model.refresh();
    fx.startTimer(.{
        .key = refresh_timer_key,
        .interval_ms = refresh_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = fx;
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) model.refresh();
        },
    }
}

pub fn initialModel() Model {
    return .{};
}

// -------------------------------------------------------------------- app run

pub fn main(init: std.process.Init) !void {
    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    // Open the local store and start the background relay ingest before the
    // window comes up. Best-effort: if either fails the window still opens with
    // an empty feed (see `startFeed`).
    startFeed(init);

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

/// Opens the local-first store and spawns the background ingest thread. The
/// store is heap-allocated and the thread detached, both living for the whole
/// process: LMDB commits each event durably, and the ingest thread can be
/// blocked in a relay read at quit, so we deliberately never tear them down —
/// process exit reclaims them without racing the detached thread. A failure
/// here is non-fatal: the app runs with an empty feed that reads "offline".
fn startFeed(init: std.process.Init) void {
    const gpa = std.heap.page_allocator;
    const store = gpa.create(nostr.store.Store) catch return;
    store.* = openFeedStore(init.io, init.environ_map) catch |err| {
        std.debug.print("plaza: local store unavailable: {s}\n", .{@errorName(err)});
        gpa.destroy(store);
        return;
    };
    g_store = store;

    const thread = std.Thread.spawn(.{}, ingestForever, .{gpa}) catch |err| {
        std.debug.print("plaza: could not start relay ingest: {s}\n", .{@errorName(err)});
        return;
    };
    thread.detach();
}

/// Opens (creating if needed) the feed store at `$HOME/.plaza/feed.mdb`.
fn openFeedStore(io: std.Io, environ: *const std.process.Environ.Map) !nostr.store.Store {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    dir.close(io);

    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/feed.mdb", .{dir_path});
    return nostr.store.Store.open(db_path, .{});
}

// ----------------------------------------------------------- background ingest
//
// The ingest loop runs on its own thread with its own `std.Io.Threaded` and its
// own secp256k1 context — the io backend and the signer are not shared across
// threads, the exact shape the Signet daemon uses per relay. It dials,
// subscribes for recent kind:1, verifies each event, and writes it into the
// shared store; the UI thread reads it back through `Model.refresh`.

/// Relay ingest loop: dial, serve, and reconnect after a short delay, forever.
fn ingestForever(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    while (true) {
        g_conn.store(@intFromEnum(Conn.connecting), .monotonic);
        ingestOnce(gpa, io, signer) catch |err| {
            std.debug.print("plaza: [{s}] {s}\n", .{ relay_url, @errorName(err) });
        };
        g_conn.store(@intFromEnum(Conn.offline), .monotonic);
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials the relay, subscribes for recent kind:1, and ingests each event into
/// the store until the connection closes.
fn ingestOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer) !void {
    var relay = try nostr.relay.dial(gpa, io, relay_url);
    defer relay.deinit();
    g_conn.store(@intFromEnum(Conn.connected), .monotonic);

    const kinds = [_]u16{1};
    const filters = [_]nostr.filter.Filter{.{ .kinds = &kinds, .limit = feed_capacity }};
    try relay.subscribe("plaza-feed", &filters);

    while (true) {
        var msg = (try relay.receive()) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| {
                const store = g_store orelse continue;
                // Verify (secp256k1) before storing; silently drop a bad event.
                _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
            },
            else => {},
        }
    }
}

test {
    _ = @import("tests.zig");
}

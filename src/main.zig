//! Plaza, the flagship native Nostr client.
//!
//! M2 turns M1's raw architecture proof into a feed that reads like a client.
//! The background thread still ingests notes from a relay into the local store;
//! the UI now renders them as proper cards, an avatar, the author's npub, a
//! relative timestamp, and the note, and reconciles smoothly: it only
//! re-queries the store when something actually changed, and refreshes the
//! relative times every tick. Everything still runs in one process, reading
//! straight from disk. Real names (kind:0 profiles), a relay pool with the
//! outbox model, and community "places" come in the milestones ahead.
//!
//! The view lives in `app.native`; this file is the logic.

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

// The one relay this milestone dials, and how many recent notes to keep on
// screen. A relay pool with the outbox model (NIP-65) is a later milestone.
const relay_url = "wss://relay.damus.io";
const feed_capacity = 60;
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
// A native app is a single process and a single instance, so the shared store,
// the ingest thread's connection state, and the wall clock live as process
// globals, the Model stays pure view state (the framework reflects Model/Msg
// for markup checking). Sharing the store across the UI and ingest threads is
// safe: LMDB serialises its own writers and hands readers an MVCC snapshot, and
// every `nostr.store` call is a self-contained transaction on its calling
// thread.

const Conn = enum(u8) { connecting = 0, connected = 1, offline = 2 };

var g_store: ?*nostr.store.Store = null;
var g_conn = std.atomic.Value(u8).init(@intFromEnum(Conn.connecting));
// The UI thread's Io, for wall-clock time when rendering relative timestamps
// (set once in `main`, read only on the UI thread).
var g_io: ?std.Io = null;
// The event count at the last feed rebuild, a cheap "did the store change?"
// signal so a tick that changed nothing skips the query and note rebuild.
var g_last_count: usize = std.math.maxInt(usize);

/// Wall-clock seconds on the UI thread, or 0 before `main` wires the clock.
fn nowSeconds() i64 {
    const io = g_io orelse return 0;
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

// ------------------------------------------------------------------ model

/// One note as the feed renders it: a two-letter avatar, the author's
/// abbreviated npub, a relative timestamp, and the (truncated) content. Strings
/// are copied into fixed buffers so a card never aliases the query arena it was
/// built from.
pub const Note = struct {
    // Non-negative i64: the markup engine holds a `for each` integer key as i64
    // then casts it to u64, so a raw u64 (or negative i64) from the id's high
    // bytes would overflow and panic. Mask off the sign bit.
    id: i64 = 0,
    created_at: i64 = 0,
    initials_buf: [2]u8 = [_]u8{0} ** 2,
    author_buf: [24]u8 = [_]u8{0} ** 24,
    author_len: u8 = 0,
    time_buf: [12]u8 = [_]u8{0} ** 12,
    time_len: u8 = 0,
    content_buf: [220]u8 = [_]u8{0} ** 220,
    content_len: u16 = 0,

    pub fn initials(self: *const Note) []const u8 {
        return &self.initials_buf;
    }
    pub fn author(self: *const Note) []const u8 {
        return self.author_buf[0..self.author_len];
    }
    pub fn time(self: *const Note) []const u8 {
        return self.time_buf[0..self.time_len];
    }
    pub fn content(self: *const Note) []const u8 {
        return self.content_buf[0..self.content_len];
    }

    /// (Re)computes the relative timestamp against `now_s`. Cheap and
    /// allocation-free, so the UI can freshen every tick without a re-query.
    fn setTime(self: *Note, now_s: i64) void {
        const dt = now_s - self.created_at;
        const written = (if (dt < 60)
            std.fmt.bufPrint(&self.time_buf, "now", .{})
        else if (dt < 3600)
            std.fmt.bufPrint(&self.time_buf, "{d}m", .{@divTrunc(dt, 60)})
        else if (dt < 86_400)
            std.fmt.bufPrint(&self.time_buf, "{d}h", .{@divTrunc(dt, 3600)})
        else if (dt < 604_800)
            std.fmt.bufPrint(&self.time_buf, "{d}d", .{@divTrunc(dt, 86_400)})
        else
            std.fmt.bufPrint(&self.time_buf, "{d}w", .{@divTrunc(dt, 604_800)})) catch return;
        self.time_len = @intCast(written.len);
    }
};

pub const Model = struct {
    notes: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity,
    notes_len: usize = 0,
    conn: Conn = .connecting,

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, `conn` through the state
    // predicates, so the raw fields are never bound by name.
    pub const view_unbound = .{ "notes", "notes_len", "conn" };

    /// The feed, iterated by `<for each="note_list">`, newest first.
    pub fn note_list(self: *const Model, arena: std.mem.Allocator) []const Note {
        _ = arena;
        return self.notes[0..self.notes_len];
    }
    pub fn has_notes(self: *const Model) bool {
        return self.notes_len > 0;
    }
    /// No notes yet, show the centered connecting/offline state (the message
    /// itself, `empty_text`, differentiates dialing from a dropped relay).
    pub fn empty(self: *const Model) bool {
        return self.notes_len == 0;
    }
    /// Header connection line.
    pub fn status(self: *const Model) []const u8 {
        return switch (self.conn) {
            .connecting => "Connecting…",
            .connected => "Live · " ++ relay_url,
            .offline => "Offline, reconnecting…",
        };
    }
    pub fn empty_text(self: *const Model) []const u8 {
        return switch (self.conn) {
            .offline => "Can't reach the relay. Retrying…",
            else => "Connecting to " ++ relay_url ++ " …",
        };
    }
    /// Status-bar summary.
    pub fn footer(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notes_len == 0) return "";
        return std.fmt.allocPrint(arena, "{d} notes", .{self.notes_len}) catch "";
    }

    /// Reconciles the feed with the store. Updates the connection line every
    /// tick; re-queries and rebuilds the note cards only when the store's event
    /// count changed since the last rebuild; and re-computes relative times for
    /// the notes on screen. `now_s` is the current wall-clock second.
    fn refresh(self: *Model, now_s: i64) void {
        self.conn = @enumFromInt(g_conn.load(.acquire));
        const store = g_store orelse return;

        const count = store.eventCount() catch return;
        if (count != g_last_count) {
            g_last_count = count;
            rebuildNotes(self, store, now_s);
        }
        for (self.notes[0..self.notes_len]) |*note| note.setTime(now_s);
    }

    fn rebuildNotes(self: *Model, store: *nostr.store.Store, now_s: i64) void {
        const kinds = [_]u16{1};
        var result = store.query(std.heap.page_allocator, .{ .kinds = &kinds, .limit = feed_capacity }) catch return;
        defer result.deinit();
        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= feed_capacity) break;
            self.notes[n] = noteFrom(ev, now_s);
            n += 1;
        }
        self.notes_len = n;
    }
};

/// Builds a `Note` view-model from a stored event.
pub fn noteFrom(ev: nostr.event.Event, now_s: i64) Note {
    var note = Note{
        .created_at = ev.created_at,
        .id = @intCast(std.mem.readInt(u64, ev.id[0..8], .big) & std.math.maxInt(i64)),
    };

    // Avatar initials: the first pubkey byte as two hex digits, stable and
    // distinct per author until real kind:0 profiles land.
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[ev.pubkey[0] >> 4], hexdigits[ev.pubkey[0] & 0x0f] };

    setAuthor(&note, ev.pubkey);

    // Content: copied up to the buffer, trimmed back to a UTF-8 boundary so a
    // split multi-byte codepoint never reaches the text shaper.
    const clen = utf8SafeLen(ev.content, note.content_buf.len);
    @memcpy(note.content_buf[0..clen], ev.content[0..clen]);
    note.content_len = @intCast(clen);

    note.setTime(now_s);
    return note;
}

/// Formats the author as an abbreviated npub (`npub1p9x8h…7k2q`), the canonical
/// Nostr identifier, falling back to a short hex prefix if bech32 encoding
/// fails. bech32's encoder grows an ArrayList and hands back an owned slice, so
/// on a fixed buffer the intermediate reallocations accumulate well past the
/// ~63-char result; 1 KiB of stack covers that churn without touching the heap.
fn setAuthor(note: *Note, pubkey: [32]u8) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch {
        const hexdigits = "0123456789abcdef";
        for (0..8) |i| {
            note.author_buf[i * 2] = hexdigits[pubkey[i] >> 4];
            note.author_buf[i * 2 + 1] = hexdigits[pubkey[i] & 0x0f];
        }
        note.author_len = 16;
        return;
    };
    const abbreviated = if (npub.len > 18)
        std.fmt.bufPrint(&note.author_buf, "{s}…{s}", .{ npub[0..12], npub[npub.len - 5 ..] }) catch npub[0..@min(npub.len, note.author_buf.len)]
    else
        std.fmt.bufPrint(&note.author_buf, "{s}", .{npub}) catch npub[0..@min(npub.len, note.author_buf.len)];
    note.author_len = @intCast(abbreviated.len);
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
    /// The repeating refresh timer fired: reconcile the feed with the store.
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
    model.refresh(nowSeconds());
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
            if (t.outcome == .fired) model.refresh(nowSeconds());
        },
    }
}

pub fn initialModel() Model {
    return .{};
}

// -------------------------------------------------------------------- app run

pub fn main(init: std.process.Init) !void {
    g_io = init.io;

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
    // window comes up. Best-effort: if either fails the window still opens.
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
/// blocked in a relay read at quit, so we deliberately never tear them down,
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
// own secp256k1 context, the io backend and the signer are not shared across
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

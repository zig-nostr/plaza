//! Plaza, the flagship native Nostr client.
//!
//! M4 adds composing. A local identity (a keypair generated and persisted on
//! first run) signs a kind:1 note, which is stored locally at once so it shows
//! in the feed immediately, then published to the relay pool on a background
//! thread so it propagates to the network. The feed still runs as a pool (each
//! relay on its own thread ingesting into the one shared store, deduped by event
//! id), rendering cards (avatar, npub, relative time, note) reconciled on a
//! timer, all in one process reading straight from disk. Real names (kind:0
//! profiles), NIP-65 outbox routing, connecting an external signer (Signet, over
//! NIP-46, so the key never enters the client), and community "places" come in
//! the milestones ahead.
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

// The relay pool this milestone dials, and how many recent notes to keep on
// screen. Each relay runs on its own thread and ingests into the one shared
// store, which dedupes by event id. NIP-65 outbox routing (reading each author
// from their own write relays) needs a follow list, so it arrives with a later
// milestone; here a fixed pool is the relay engine.
const relays = [_][]const u8{
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://relay.nostr.band",
    "wss://relay.snort.social",
};
const feed_capacity = 60;
// The composer's fixed text capacity. Comfortably longer than a typical note;
// the display buffer (`Note.content_buf`) truncates for rendering, but the
// published event carries the full draft.
const compose_capacity = 512;
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
// each relay's connection state, and the wall clock live as process globals,
// the Model stays pure view state (the framework reflects Model/Msg for markup
// checking). Sharing the store across the UI thread and the several ingest
// threads is safe: LMDB serialises its writers (the pool's ingests take the
// write lock one at a time) and hands readers an MVCC snapshot, and every
// `nostr.store` call is a self-contained transaction on its calling thread.

const Conn = enum(u8) { connecting = 0, connected = 1, offline = 2 };

var g_store: ?*nostr.store.Store = null;
// One connection state per relay in the pool, flipped by that relay's ingest
// thread and read by the UI thread to summarise the pool.
var g_relay_status = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(@intFromEnum(Conn.connecting))} ** relays.len;

/// Sets relay `index`'s live connection state.
fn setRelayStatus(index: usize, state: Conn) void {
    g_relay_status[index].store(@intFromEnum(state), .monotonic);
}
// The UI thread's Io, for wall-clock time when rendering relative timestamps
// (set once in `main`, read only on the UI thread).
var g_io: ?std.Io = null;
// The event count at the last feed rebuild, a cheap "did the store change?"
// signal so a tick that changed nothing skips the query and note rebuild.
var g_last_count: usize = std.math.maxInt(usize);

// Plaza's local identity: the keypair that signs composed notes. Loaded once on
// the UI thread in `main` and read only there, so no synchronisation is needed.
// The signer holds a secp256k1 context (not shared across threads); the publish
// path never signs, it forwards an already-signed event, so it needs neither.
// This is the zero-config local signer; connecting an external signer (Signet,
// over NIP-46, so the key never touches the client) is the onboarding path in a
// later milestone, and swaps in at `signNote` below.
var g_identity_signer: ?nostr.keys.Signer = null;
var g_identity_kp: ?nostr.keys.KeyPair = null;
var g_identity_npub_buf: [24]u8 = undefined;
var g_identity_npub_len: usize = 0;

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
    live_relays: usize = 0,
    offline_relays: usize = 0,
    // The composer's edit state (text + caret + selection). The view binds the
    // text through `draft()`, never the buffer itself, and every edit event is
    // mirrored here in `update`.
    draft_buffer: canvas.TextBuffer(compose_capacity) = .{},

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, so the raw fields
    // are never bound by name.
    pub const view_unbound = .{ "notes", "notes_len", "live_relays", "offline_relays", "draft_buffer" };

    /// The composer's current text (what `text="{draft}"` binds).
    pub fn draft(self: *const Model) []const u8 {
        return self.draft_buffer.text();
    }
    /// Whether the draft is blank (only whitespace), which disables Post.
    pub fn draft_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.draft_buffer.text(), " \t\r\n").len == 0;
    }
    /// The composer's "posting as" line: the local identity's abbreviated npub,
    /// or a setup note while the key is still being prepared.
    pub fn identity(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        if (g_identity_npub_len == 0) return "Preparing your key…";
        const npub = g_identity_npub_buf[0..g_identity_npub_len];
        return std.fmt.allocPrint(arena, "Posting as {s}", .{npub}) catch npub;
    }

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
    /// Header status line: how much of the relay pool is live.
    pub fn status(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.live_relays > 0)
            return std.fmt.allocPrint(arena, "Live · {d}/{d} relays", .{ self.live_relays, relays.len }) catch "Live";
        if (self.offline_relays >= relays.len) return "Offline, reconnecting…";
        return "Connecting…";
    }
    pub fn empty_text(self: *const Model) []const u8 {
        if (self.offline_relays >= relays.len) return "Can't reach any relay. Retrying…";
        return "Connecting to the relay pool…";
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
        var live: usize = 0;
        var offline: usize = 0;
        for (&g_relay_status) |*s| {
            switch (@as(Conn, @enumFromInt(s.load(.acquire)))) {
                .connected => live += 1,
                .offline => offline += 1,
                .connecting => {},
            }
        }
        self.live_relays = live;
        self.offline_relays = offline;

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

fn setAuthor(note: *Note, pubkey: [32]u8) void {
    const s = abbreviateNpub(&note.author_buf, pubkey);
    note.author_len = @intCast(s.len);
}

/// Writes an abbreviated npub (`npub1p9x8h…7k2q`), the canonical Nostr
/// identifier, for `pubkey` into `out`, returning the written slice; falls back
/// to a short hex prefix if bech32 encoding fails. The result always lives in
/// `out` (never the scratch buffer), so the caller can hold it safely. `out`
/// should be at least 20 bytes for the abbreviated form. bech32's encoder grows
/// an ArrayList and hands back an owned slice, so on a fixed buffer the
/// intermediate reallocations accumulate well past the ~63-char result; 1 KiB of
/// scratch covers that churn without touching the heap.
fn abbreviateNpub(out: []u8, pubkey: [32]u8) []const u8 {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch {
        const hexdigits = "0123456789abcdef";
        var n: usize = 0;
        while (n < 16 and n + 1 < out.len) : (n += 2) {
            out[n] = hexdigits[pubkey[n / 2] >> 4];
            out[n + 1] = hexdigits[pubkey[n / 2] & 0x0f];
        }
        return out[0..n];
    };
    if (npub.len > 18) {
        if (std.fmt.bufPrint(out, "{s}…{s}", .{ npub[0..12], npub[npub.len - 5 ..] })) |s| return s else |_| {}
    }
    const n = @min(npub.len, out.len);
    @memcpy(out[0..n], npub[0..n]);
    return out[0..n];
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
    /// A text edit in the composer, mirrored into the draft buffer.
    draft_edit: canvas.TextInputEvent,
    /// Post the current draft: sign, store locally, and publish to the pool.
    post,

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
        .draft_edit => |edit| model.draft_buffer.apply(edit),
        .post => submitPost(model),
    }
}

pub fn initialModel() Model {
    return .{};
}

// -------------------------------------------------------------- compose & post
//
// Posting is local-first: a composed note is signed, written to the local store
// straight away (so it shows in the feed on the next tick), and published to the
// pool on a detached thread. The feed dedupes by event id, so when a relay later
// echoes our own note back through the ingest subscriptions it collapses onto
// the local copy.

/// Posts the current draft: sign a kind:1 note, store it locally at once, and
/// publish it to the pool in the background. A blank draft or a not-yet-ready
/// identity is a no-op.
fn submitPost(model: *Model) void {
    const text = std.mem.trim(u8, model.draft_buffer.text(), " \t\r\n");
    if (text.len == 0) return;
    const store = g_store orelse return;
    const gpa = std.heap.page_allocator;

    // The signed event references its content slice rather than copying it, and
    // both the local store write and the detached publisher read it after the
    // draft buffer is cleared and reused. Keep a process-lifetime copy (never
    // freed, like the store and the ingest threads): posts are rare and small.
    const owned = gpa.dupe(u8, text) catch return;
    const ev = signNote(gpa, owned) orelse {
        gpa.free(owned);
        return;
    };

    // Local-first: our own note lands in the store immediately (no re-verify, we
    // just produced the signature), then propagates to relays off the UI thread.
    _ = store.ingest(gpa, ev, .{}) catch {};

    const thread = std.Thread.spawn(.{}, publishEvent, .{ gpa, ev }) catch {
        // Couldn't start the publisher; the note is still stored locally.
        model.draft_buffer.clear();
        return;
    };
    thread.detach();

    model.draft_buffer.clear();
}

/// Signs a kind:1 note with the local identity. This is the signing seam: a
/// later milestone routes it through an external signer (Signet, over NIP-46, so
/// the key never enters the client) instead, leaving the rest of the compose and
/// publish path unchanged. `content` must outlive the returned event (it is
/// referenced, not copied). Returns null if no identity is ready.
fn signNote(gpa: std.mem.Allocator, content: []const u8) ?nostr.event.Event {
    const signer = g_identity_signer orelse return null;
    const kp = g_identity_kp orelse return null;
    return nostr.event.create(gpa, signer, kp, nowSeconds(), 1, &.{}, content, null) catch null;
}

/// Publishes `ev` to every relay in the pool, each on a throwaway connection,
/// best-effort. Posting is a rare, human-paced action, so a fresh dial per post
/// keeps the ingest loops untouched; the note is already in the local store, so
/// the feed shows it regardless of publish latency. Runs on a detached thread
/// with its own io backend, never the UI thread's.
fn publishEvent(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        relay.publish(ev) catch continue;
        // Read the relay's OK so the frame is flushed and acknowledged before we
        // close the connection; best-effort, its verdict is not surfaced yet.
        var msg = (relay.receive() catch continue) orelse continue;
        msg.deinit();
    }
}

// -------------------------------------------------------------------- app run

pub fn main(init: std.process.Init) !void {
    g_io = init.io;

    // Load (or, on first run, generate) the local identity before the first
    // paint, so the composer knows who it posts as. Best-effort: on failure the
    // app still runs, with posting disabled until an identity exists.
    loadOrCreateIdentity(init.io, init.environ_map);

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

    // One ingest thread per relay in the pool. Each dials independently, so a
    // slow or down relay never holds up the others, and all write into the one
    // shared store (LMDB serialises the concurrent writers).
    for (0..relays.len) |i| {
        const thread = std.Thread.spawn(.{}, ingestRelay, .{ gpa, i }) catch |err| {
            std.debug.print("plaza: [{s}] could not start: {s}\n", .{ relays[i], @errorName(err) });
            setRelayStatus(i, .offline);
            continue;
        };
        thread.detach();
    }
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

// ----------------------------------------------------------------- identity
//
// Plaza's local signing identity lives beside the feed store, at
// `$HOME/.plaza/identity.key` (the raw 32-byte secret, mode 0600), generated on
// first run. This is the zero-config local signer so the app posts out of the
// box; connecting an external signer (Signet, over NIP-46) so the key never
// touches the client is the onboarding path in a later milestone.

/// Loads the local identity into the process globals, generating and persisting
/// a fresh key on first run. Best-effort: on any failure the globals stay unset
/// and posting is disabled, but the app still runs.
fn loadOrCreateIdentity(io: std.Io, environ: *const std.process.Environ.Map) void {
    var signer = nostr.keys.Signer.init();
    const secret = identitySecret(io, environ, signer) catch |err| {
        std.debug.print("plaza: identity unavailable: {s}\n", .{@errorName(err)});
        signer.deinit();
        return;
    };
    const kp = signer.keyPairFromSecretKey(secret) catch |err| {
        std.debug.print("plaza: identity key invalid: {s}\n", .{@errorName(err)});
        signer.deinit();
        return;
    };
    g_identity_signer = signer;
    g_identity_kp = kp;
    const npub = abbreviateNpub(&g_identity_npub_buf, kp.public_key);
    g_identity_npub_len = npub.len;
}

/// Returns the identity's 32-byte secret, reading `$HOME/.plaza/identity.key` or
/// generating and persisting it on first run (mode 0600). `signer` provides the
/// entropy for a freshly generated key.
fn identitySecret(io: std.Io, environ: *const std.process.Environ.Map, signer: nostr.keys.Signer) ![32]u8 {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "identity.key", gpa, std.Io.Limit.limited(64)) catch |err| switch (err) {
        error.FileNotFound => {
            // First run: generate a key and persist it, refusing to clobber a
            // key another instance may have written between the read and here.
            const kp = try signer.generateKeyPair(io);
            dir.writeFile(io, .{
                .sub_path = "identity.key",
                .data = &kp.secret_key,
                .flags = .{ .exclusive = true, .permissions = std.Io.File.Permissions.fromMode(0o600) },
            }) catch |werr| std.debug.print("plaza: could not persist identity: {s}\n", .{@errorName(werr)});
            return kp.secret_key;
        },
        else => return err,
    };
    defer gpa.free(raw);
    if (raw.len != 32) return error.BadIdentityFile;
    var secret: [32]u8 = undefined;
    @memcpy(&secret, raw[0..32]);
    return secret;
}

// ----------------------------------------------------------- background ingest
//
// Each relay's ingest loop runs on its own thread with its own `std.Io.Threaded`
// and its own secp256k1 context, the io backend and the signer are not shared
// across threads, the exact shape the Signet daemon uses per relay. It dials,
// subscribes for recent kind:1, verifies each event, and writes it into the
// shared store; the UI thread reads it back through `Model.refresh`.

/// One relay's ingest loop: dial, serve, and reconnect after a short delay,
/// forever.
fn ingestRelay(gpa: std.mem.Allocator, index: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    while (true) {
        setRelayStatus(index, .connecting);
        ingestOnce(gpa, io, signer, index) catch |err| {
            std.debug.print("plaza: [{s}] {s}\n", .{ relays[index], @errorName(err) });
        };
        setRelayStatus(index, .offline);
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials relay `index`, subscribes for recent kind:1, and ingests each event
/// into the shared store until the connection closes.
fn ingestOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, index: usize) !void {
    var relay = try nostr.relay.dial(gpa, io, relays[index]);
    defer relay.deinit();
    setRelayStatus(index, .connected);

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

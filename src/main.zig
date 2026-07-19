//! Plaza, the flagship native Nostr client.
//!
//! A first run opens a welcome screen with three ways in: create a fresh
//! identity, paste an existing `nsec` to import a key, or paste a `bunker://`
//! link to connect an external signer (Signet) over NIP-46 so the secret key
//! never enters Plaza. The choice is persisted as a session, so a returning user
//! is signed straight back in (a local key from disk, or a silent bunker
//! reconnect). A Settings screen shows who you are signed in as, lets a local
//! user back up their secret key, and logs out without locking anyone in: your
//! key is always yours to copy and take elsewhere.
//!
//! Signed in, you land in a follow-based feed seeded by a curated starter pack
//! (the `starter_pack` authors). Composing signs a kind:1 (locally, or by a
//! `sign_event` round-trip to the bunker), which is stored locally and published
//! to the pool. The feed runs as a pool (each relay on its own thread ingesting
//! into the one shared store, deduped by event id), scoped to the follow set,
//! rendered from disk on a timer, all in one process. Real names (kind:0
//! profiles) and NIP-65 outbox routing come in the milestones ahead.
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

// The curated starter pack a newcomer follows on first run: a handful of
// well-known, active accounts so the feed is alive from the first second. The
// feed is scoped to these authors (plus the user's own notes); follow
// management and NIP-51 lists come later. Pubkeys are hex, decoded to bytes at
// comptime.
const starter_pack_hex = [_][]const u8{
    "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", // fiatjaf
    "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", // jack
    "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245", // jb55
    "04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9", // ODELL
    "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93", // gigi
    "84dee6e676e5bb67b4ad4e042cf70cbd8681155db535942fcc6a0533858a7240", // Snowden
    "fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52", // Vitor (Amethyst)
    "eab0e756d32b80bcd464f3d844b8040303075a13eabc3599a762c9ac7ab91f4f", // hodlbod
    "460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c", // Lyn Alden
};
const starter_pack = blk: {
    var pks: [starter_pack_hex.len][32]u8 = undefined;
    for (starter_pack_hex, 0..) |h, i| {
        _ = std.fmt.hexToBytes(&pks[i], h) catch unreachable;
    }
    break :blk pks;
};

const feed_capacity = 60;
// The composer's fixed text capacity. Comfortably longer than a typical note;
// the display buffer (`Note.content_buf`) truncates for rendering, but the
// published event carries the full draft.
const compose_capacity = 512;
const refresh_timer_key: u64 = 1;
const refresh_interval_ms: u64 = 1_000;
// The app version shown in Settings. Keep in step with app.zon's `.version`.
const plaza_version = "0.1.0";
// Effect keys for the two Settings clipboard copies (npub, nsec). Clipboard
// effects share the effect key space, so these stay distinct from the timer key.
const copy_npub_key: u64 = 100;
const copy_nsec_key: u64 = 101;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view, native_sdk.security.permission_clipboard };
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
// The process environment, stashed in `main` so the onboarding "create identity"
// action can resolve `$HOME` and open the store off the UI thread event loop.
var g_environ: ?*const std.process.Environ.Map = null;
// The event count at the last feed rebuild, a cheap "did the store change?"
// signal so a tick that changed nothing skips the query and note rebuild.
var g_last_count: usize = std.math.maxInt(usize);

// Plaza's local identity: the keypair that signs composed notes. Loaded in
// `main` (returning user) or created by the onboarding action, both on the UI
// thread, and read only there, so no synchronisation is needed. The signer holds
// a secp256k1 context (not shared across threads); the publish path never signs,
// it forwards an already-signed event, so it needs neither. This is the
// zero-config local signer; connecting an external signer (Signet, over NIP-46,
// so the key never touches the client) is the next onboarding option, and swaps
// in at `signNote` below.
var g_identity_signer: ?nostr.keys.Signer = null;
var g_identity_kp: ?nostr.keys.KeyPair = null;
var g_identity_npub_buf: [24]u8 = undefined;
var g_identity_npub_len: usize = 0;

// How composed notes are signed: with the local key, or remotely over NIP-46 by
// an external signer (Signet) so the secret key never enters Plaza. `submitPost`
// branches on this; it is set once during onboarding.
const SignerKind = enum { local, remote };
var g_signer_kind: SignerKind = .local;

// Remote-signer (NIP-46) connection state, set at connect time and read by the
// background threads. The ephemeral client keypair is Plaza's transport identity
// with the bunker (never the user's key); the user's identity is the bunker's
// own pubkey. Each worker thread makes its own secp256k1 signer, only these
// bytes are shared.
var g_remote_client_kp: ?nostr.keys.KeyPair = null;
var g_remote_pubkey: [32]u8 = undefined;
var g_remote_relay_buf: [256]u8 = undefined;
var g_remote_relay_len: usize = 0;
var g_remote_secret_buf: [128]u8 = undefined;
var g_remote_secret_len: usize = 0;
// 0 idle, 1 connecting, 2 connected, 3 failed. Drives the onboarding status line.
var g_remote_status = std.atomic.Value(u8).init(0);
// Monotonic source of unique NIP-46 request ids.
var g_req_counter = std.atomic.Value(u64).init(0);

// A synchronous error from the unified login field (nsec / bunker), shown under
// it. `.none` while idle or when the async bunker path is in charge (its state
// comes from `g_remote_status`). See `LoginError` and `Model.login_status`.
const LoginError = enum(u8) { none = 0, format = 1, bad_key = 2 };
var g_login_error = std.atomic.Value(u8).init(0);

/// What the pasted login text is: a secret key to import, a signer to connect,
/// or neither.
pub const LoginTarget = enum { nsec, bunker, invalid };

/// Classifies pasted login text by its prefix. Pure, so it is unit-tested.
pub fn classifyLogin(text: []const u8) LoginTarget {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "nsec1")) return .nsec;
    if (std.mem.startsWith(u8, t, "bunker://")) return .bunker;
    return .invalid;
}

/// Wall-clock seconds on the UI thread, or 0 before `main` wires the clock.
fn nowSeconds() i64 {
    const io = g_io orelse return 0;
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// The pubkey Plaza posts as: the local key, or the remote signer's, or null
/// before an identity is established. The feed includes it so your own notes
/// show alongside the follows you read.
fn activePubkey() ?[32]u8 {
    return switch (g_signer_kind) {
        .local => if (g_identity_kp) |kp| kp.public_key else null,
        .remote => g_remote_pubkey,
    };
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

/// Which top-level screen the app shows.
const Stage = enum { onboarding, ready, settings };

pub const Model = struct {
    notes: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity,
    notes_len: usize = 0,
    live_relays: usize = 0,
    offline_relays: usize = 0,
    // The composer's edit state (text + caret + selection). The view binds the
    // text through `draft()`, never the buffer itself, and every edit event is
    // mirrored here in `update`.
    draft_buffer: canvas.TextBuffer(compose_capacity) = .{},
    // Which screen shows. A returning user (session on disk) starts at `.ready`;
    // a newcomer starts at `.onboarding` and moves to `.ready` when they sign in.
    // `.settings` is reached from the feed and returns to it.
    stage: Stage = .onboarding,
    // The onboarding sign-in field: an existing `nsec` to import a key, or a
    // `bunker://` URL to pair with an external NIP-46 signer (Signet).
    login_buffer: canvas.TextBuffer(220) = .{},
    // Settings: whether the "log out" confirmation is showing, and whether the
    // local secret key is revealed for backup.
    logout_pending: bool = false,
    reveal_nsec: bool = false,

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, the stage through
    // `show_onboarding`/`show_feed`/`show_settings`, the login field through
    // `login_draft`, so the raw fields are never bound by name.
    pub const view_unbound = .{ "notes", "notes_len", "live_relays", "offline_relays", "draft_buffer", "stage", "login_buffer", "logout_pending", "reveal_nsec" };

    /// Whether the first-run welcome screen shows (no session yet).
    pub fn show_onboarding(self: *const Model) bool {
        return self.stage == .onboarding;
    }
    /// Whether the main feed shows (signed in).
    pub fn show_feed(self: *const Model) bool {
        return self.stage == .ready;
    }
    /// Whether the Settings screen shows.
    pub fn show_settings(self: *const Model) bool {
        return self.stage == .settings;
    }

    /// The composer's current text (what `text="{draft}"` binds).
    pub fn draft(self: *const Model) []const u8 {
        return self.draft_buffer.text();
    }
    /// Whether the draft is blank (only whitespace), which disables Post.
    pub fn draft_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.draft_buffer.text(), " \t\r\n").len == 0;
    }
    /// The composer's "posting as" line: the identity's abbreviated npub, marked
    /// when signing is routed through an external signer, or a setup note while
    /// the key is still being prepared.
    pub fn identity(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        if (g_identity_npub_len == 0) return "Preparing your key…";
        const npub = g_identity_npub_buf[0..g_identity_npub_len];
        const prefix = if (g_signer_kind == .remote) "Signing via your signer · " else "Posting as ";
        return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, npub }) catch npub;
    }

    /// The onboarding sign-in field text (what `text="{login_draft}"` binds).
    pub fn login_draft(self: *const Model) []const u8 {
        return self.login_buffer.text();
    }
    /// Whether the sign-in field is blank, which disables Continue.
    pub fn login_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.login_buffer.text(), " \t\r\n").len == 0;
    }
    /// The status line under the sign-in field: a synchronous parse error, or
    /// the async bunker-connect state.
    pub fn login_status(self: *const Model) []const u8 {
        _ = self;
        switch (@as(LoginError, @enumFromInt(g_login_error.load(.acquire)))) {
            .format => return "Paste an nsec or a bunker link.",
            .bad_key => return "That doesn't look like a valid key.",
            .none => {},
        }
        return switch (g_remote_status.load(.acquire)) {
            1 => "Connecting to your signer…",
            3 => "Couldn't read that bunker link.",
            else => "",
        };
    }

    // -- Settings ------------------------------------------------------------

    /// The abbreviated npub of the signed-in identity (empty before sign-in).
    pub fn active_npub(self: *const Model) []const u8 {
        _ = self;
        return g_identity_npub_buf[0..g_identity_npub_len];
    }
    /// How the identity signs: a local key on this device, or a remote signer.
    pub fn identity_kind_label(self: *const Model) []const u8 {
        _ = self;
        return switch (g_signer_kind) {
            .local => "Local key",
            .remote => "Remote signer",
        };
    }
    /// Whether the identity is a local key (so its secret can be backed up here).
    pub fn is_local_key(self: *const Model) bool {
        _ = self;
        return g_signer_kind == .local;
    }
    /// Whether the local secret key is hidden (the reveal toggle's off state).
    pub fn nsec_hidden(self: *const Model) bool {
        return !self.reveal_nsec;
    }
    /// Whether the secret key is currently revealed.
    pub fn nsec_shown(self: *const Model) bool {
        return self.reveal_nsec;
    }
    /// The revealed nsec (bech32 secret key), or empty when hidden or not local.
    pub fn revealed_nsec(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!self.reveal_nsec or g_signer_kind != .local) return "";
        const kp = g_identity_kp orelse return "";
        return nostr.nip19.encodeNsec(arena, kp.secret_key) catch "";
    }
    /// Whether the logout confirmation is not yet showing.
    pub fn logout_idle(self: *const Model) bool {
        return !self.logout_pending;
    }
    /// Whether the logout confirmation is showing.
    pub fn logout_confirming(self: *const Model) bool {
        return self.logout_pending;
    }
    /// The logout confirmation warning, sharper for a local key (it is deleted).
    pub fn logout_warning(self: *const Model) []const u8 {
        _ = self;
        return switch (g_signer_kind) {
            .local => "Your secret key will be removed from this device. Copy it first if you want to keep this identity.",
            .remote => "You'll be signed out and returned to the welcome screen. Your signer keeps your key.",
        };
    }
    /// The app version line for the Settings footer.
    pub fn version_line(self: *const Model) []const u8 {
        _ = self;
        return "Plaza " ++ plaza_version;
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
        // Scope the feed to the follow set (the starter pack) plus the user's own
        // notes, so it reads as a real follow feed, not a firehose. Filtering
        // here (not just at the subscription) also hides notes an earlier,
        // unscoped run may have left in the store.
        var authors: [starter_pack.len + 1][32]u8 = starter_pack ++ [_][32]u8{undefined};
        var authors_len: usize = starter_pack.len;
        if (activePubkey()) |pk| {
            authors[authors_len] = pk;
            authors_len += 1;
        }
        var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = feed_capacity }) catch return;
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
    /// Onboarding: create a fresh local identity and enter the feed.
    create_identity,
    /// A text edit in the onboarding sign-in field.
    login_edit: canvas.TextInputEvent,
    /// Onboarding: sign in with the pasted nsec or bunker link and enter the feed.
    login_submit,
    /// Open the Settings screen.
    open_settings,
    /// Return from Settings to the feed.
    close_settings,
    /// Reveal (or hide) the local secret key for backup.
    toggle_nsec,
    /// Copy the signed-in npub to the clipboard.
    copy_npub,
    /// Copy the local secret key (nsec) to the clipboard.
    copy_nsec,
    /// Ask to log out: show the confirmation.
    logout_request,
    /// Dismiss the logout confirmation.
    logout_cancel,
    /// Confirm logout: wipe the session (and a local key) and return to onboarding.
    logout_confirm,

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
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) model.refresh(nowSeconds());
        },
        .draft_edit => |edit| model.draft_buffer.apply(edit),
        .post => submitPost(model),
        .create_identity => {
            // Generate the local key, then bring the feed up and switch screens.
            if (!createLocalIdentity()) return;
            persistSession();
            enterFeed(model);
        },
        .login_edit => |edit| model.login_buffer.apply(edit),
        .login_submit => {
            g_login_error.store(@intFromEnum(LoginError.none), .release);
            const raw = std.mem.trim(u8, model.login_buffer.text(), " \t\r\n");
            switch (classifyLogin(raw)) {
                // Import an existing key: it lands on disk (0600) as the local
                // identity. A bad nsec keeps us on onboarding with an error.
                .nsec => {
                    if (!importNsec(raw)) return;
                    persistSession();
                    enterFeed(model);
                },
                // Pair with the external signer from the bunker URL; on success
                // the feed comes up and posts route through it. A bad URL keeps
                // us on onboarding with an error (see `login_status`).
                .bunker => {
                    if (!connectRemoteSigner(raw)) return;
                    persistSession();
                    enterFeed(model);
                },
                .invalid => g_login_error.store(@intFromEnum(LoginError.format), .release),
            }
        },
        .open_settings => model.stage = .settings,
        .close_settings => {
            model.logout_pending = false;
            model.reveal_nsec = false;
            model.stage = .ready;
        },
        .toggle_nsec => model.reveal_nsec = !model.reveal_nsec,
        .copy_npub => {
            const pk = activePubkey() orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const npub = nostr.nip19.encodeNpub(fba.allocator(), pk) catch return;
            fx.writeClipboard(.{ .key = copy_npub_key, .text = npub });
        },
        .copy_nsec => {
            if (g_signer_kind != .local) return;
            const kp = g_identity_kp orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const nsec = nostr.nip19.encodeNsec(fba.allocator(), kp.secret_key) catch return;
            fx.writeClipboard(.{ .key = copy_nsec_key, .text = nsec });
        },
        .logout_request => model.logout_pending = true,
        .logout_cancel => model.logout_pending = false,
        .logout_confirm => performLogout(model),
    }
}

/// Switches to the feed and brings the store + ingest pool up if they are not
/// already running. Shared by all sign-in paths (create, import, remote signer).
/// A fresh identity means the feed's author filter changed, so force a rebuild
/// on the next tick by invalidating the change guard.
fn enterFeed(model: *Model) void {
    model.stage = .ready;
    g_last_count = std.math.maxInt(usize);
    if (g_store == null) {
        if (g_io) |io| if (g_environ) |env| startFeed(io, env);
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
    const gpa = std.heap.page_allocator;

    // A process-lifetime copy of the content: `event.create` references its
    // content slice rather than copying it, and the store write and either the
    // publisher or the NIP-46 round-trip read it after the draft is cleared.
    const owned = gpa.dupe(u8, text) catch return;
    switch (g_signer_kind) {
        .local => postLocally(gpa, owned),
        .remote => requestRemoteSign(gpa, owned),
    }
    model.draft_buffer.clear();
}

/// Local path: sign with the local key, store the note at once (so it shows in
/// the feed on the next tick), and publish it to the pool off the UI thread.
fn postLocally(gpa: std.mem.Allocator, owned: []const u8) void {
    const store = g_store orelse {
        gpa.free(owned);
        return;
    };
    const ev = signNote(gpa, owned) orelse {
        gpa.free(owned);
        return;
    };
    // No re-verify: we just produced the signature.
    _ = store.ingest(gpa, ev, .{}) catch {};
    const thread = std.Thread.spawn(.{}, publishEvent, .{ gpa, ev }) catch return;
    thread.detach();
}

/// Signs a kind:1 note with the local key. `SignerKind` selects this or the
/// remote path (`requestRemoteSign`). `content` must outlive the returned event
/// (it is referenced, not copied). Null if no local identity is ready.
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

// ------------------------------------------------------- remote signer (NIP-46)
//
// Signing can be routed to an external signer (Signet) over NIP-46 so the user's
// secret key never enters Plaza. Plaza is the CLIENT: it holds an ephemeral
// transport keypair, and the user's identity is the bunker's own pubkey. The
// wire is kind:24133 events whose content is a NIP-44-encrypted request/response
// `p`-tagged to the recipient. A persistent listener thread holds the bunker
// relay and processes responses; each request (connect, then one per post) goes
// out on its own short-lived connection, so a blocked receive never stalls a
// send. A signed note returns as a response `result`, stored and published to
// the feed pool exactly like a locally signed one.

/// Pairs with an external signer from a `bunker://` URL: parses it, mints an
/// ephemeral client key, starts the response listener, and sends the connect
/// request. Returns false (and marks the status failed) on a bad URL.
fn connectRemoteSigner(url_raw: []const u8) bool {
    const url = std.mem.trim(u8, url_raw, " \t\r\n");
    const io = g_io orelse return false;
    const gpa = std.heap.page_allocator;

    var parsed = nostr.nip46.parseBunkerUri(gpa, url) catch {
        g_remote_status.store(3, .release);
        return false;
    };
    defer parsed.deinit();
    const bunker = parsed.value;
    if (bunker.relays.len == 0 or bunker.relays[0].len > g_remote_relay_buf.len) {
        g_remote_status.store(3, .release);
        return false;
    }
    const relay_url = bunker.relays[0];

    // Mint the ephemeral transport key (never the user's key).
    var signer = nostr.keys.Signer.init();
    const client_kp = signer.generateKeyPair(io) catch {
        signer.deinit();
        g_remote_status.store(3, .release);
        return false;
    };
    signer.deinit();

    // Stash the connection details for the worker threads.
    g_remote_pubkey = bunker.remote_signer_pubkey;
    @memcpy(g_remote_relay_buf[0..relay_url.len], relay_url);
    g_remote_relay_len = relay_url.len;
    if (bunker.secret) |s| {
        const n = @min(s.len, g_remote_secret_buf.len);
        @memcpy(g_remote_secret_buf[0..n], s[0..n]);
        g_remote_secret_len = n;
    } else g_remote_secret_len = 0;
    g_remote_client_kp = client_kp;

    // The user's identity is the bunker's pubkey.
    const npub = abbreviateNpub(&g_identity_npub_buf, g_remote_pubkey);
    g_identity_npub_len = npub.len;
    g_signer_kind = .remote;
    g_remote_status.store(1, .release);

    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{gpa}) catch {
        g_remote_status.store(3, .release);
        return false;
    };
    thread.detach();

    sendConnect(gpa);
    return true;
}

/// Sends the NIP-46 `connect` request (remote pubkey + optional secret).
fn sendConnect(gpa: std.mem.Allocator) void {
    var hexbuf: [64]u8 = undefined;
    hexLower(&hexbuf, g_remote_pubkey);
    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "req-{d}", .{g_req_counter.fetchAdd(1, .monotonic)}) catch return;
    const params = [_][]const u8{ &hexbuf, g_remote_secret_buf[0..g_remote_secret_len] };
    sendRequest(gpa, .{ .id = req_id, .method = "connect", .params = &params });
}

/// Remote path: build the unsigned kind:1 event and send a `sign_event` request.
/// The signed event returns to the listener, which stores and publishes it.
fn requestRemoteSign(gpa: std.mem.Allocator, content_owned: []const u8) void {
    defer gpa.free(content_owned);
    const created_at = nowSeconds();
    // A canonical unsigned event (the bunker fills in the signature). The id is
    // computed against the user's pubkey so the bunker's result matches it.
    const id = nostr.event.computeId(gpa, g_remote_pubkey, created_at, 1, &.{}, content_owned) catch return;
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = g_remote_pubkey,
        .created_at = created_at,
        .kind = 1,
        .tags = &.{},
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch return;
    defer gpa.free(unsigned_json);

    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "req-{d}", .{g_req_counter.fetchAdd(1, .monotonic)}) catch return;
    const params = [_][]const u8{unsigned_json};
    sendRequest(gpa, .{ .id = req_id, .method = "sign_event", .params = &params });
}

/// Serializes `request` and spawns a one-shot thread to seal and publish it.
fn sendRequest(gpa: std.mem.Allocator, request: nostr.nip46.Request) void {
    const req_json = request.toJson(gpa) catch return;
    const thread = std.Thread.spawn(.{}, nip46Send, .{ gpa, req_json }) catch {
        gpa.free(req_json);
        return;
    };
    thread.detach();
}

/// Seals `req_json` to the remote signer and publishes it on a throwaway
/// connection to the bunker relay. Owns `req_json`. Its own io and signer.
fn nip46Send(gpa: std.mem.Allocator, req_json: []const u8) void {
    defer gpa.free(req_json);
    const client_kp = g_remote_client_kp orelse return;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const created_at = std.Io.Timestamp.now(io, .real).toSeconds();
    var sealed = nostr.nip46.seal(gpa, io, signer, client_kp, g_remote_pubkey, req_json, created_at) catch return;
    defer sealed.deinit();

    var relay = nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]) catch return;
    defer relay.deinit();
    relay.publish(sealed.event) catch return;
    // Read the relay's OK so the frame flushes before we close; best-effort.
    var msg = (relay.receive() catch return) orelse return;
    msg.deinit();
}

/// The response listener: holds the bunker relay and processes responses,
/// reconnecting forever. Its own io backend and signer, never the UI thread's.
fn nip46ReceiveLoop(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const client_kp = g_remote_client_kp orelse return;

    while (true) {
        nip46ReceiveOnce(gpa, io, signer, client_kp) catch |err| {
            std.debug.print("plaza: [signer] {s}\n", .{@errorName(err)});
        };
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials the bunker relay, subscribes for responses addressed to our client key
/// (`#p` = the ephemeral pubkey, which only our bunker knows), and handles each.
fn nip46ReceiveOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair) !void {
    var relay = try nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]);
    defer relay.deinit();

    var client_hex: [64]u8 = undefined;
    hexLower(&client_hex, client_kp.public_key);
    const pvals = [_][]const u8{&client_hex};
    const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &pvals }};
    const kinds = [_]u16{nostr.nip46.kind};
    const filters = [_]nostr.filter.Filter{.{ .kinds = &kinds, .tags = &tag_filters }};
    try relay.subscribe("plaza-nip46", &filters);

    while (true) {
        var msg = (try relay.receive()) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| handleNip46Response(gpa, signer, client_kp, e.event),
            else => {},
        }
    }
}

/// Decrypts and parses a NIP-46 response. Any valid response marks the signer
/// connected; a response whose `result` is a signed event is stored and
/// published to the feed pool, the remote equivalent of the local post path.
fn handleNip46Response(gpa: std.mem.Allocator, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, ev: nostr.event.Event) void {
    const plaintext = nostr.nip46.open(gpa, signer, client_kp.secret_key, ev) catch return;
    defer gpa.free(plaintext);
    var resp = nostr.nip46.parseResponse(gpa, plaintext) catch return;
    defer resp.deinit();
    if (resp.value.err.len != 0) {
        std.debug.print("plaza: [signer] {s}\n", .{resp.value.err});
        return;
    }
    g_remote_status.store(2, .release);

    // A sign_event result is a full event JSON; the connect ack is a plain string
    // and simply fails to parse here, which is fine, it only marks us connected.
    var parsed = nostr.event.fromJson(gpa, resp.value.result) catch return;
    defer parsed.deinit();
    const store = g_store orelse return;
    // Verify the bunker actually signed it before trusting it into the feed.
    _ = store.ingest(gpa, parsed.value, .{ .verify_with = signer }) catch return;

    // Republish to the user's feed pool so the note propagates. Our composer
    // produces tagless kind:1 notes, so an empty tag set matches the signed id.
    const owned = gpa.dupe(u8, parsed.value.content) catch return;
    var out = parsed.value;
    out.content = owned;
    out.tags = &.{};
    const thread = std.Thread.spawn(.{}, publishEvent, .{ gpa, out }) catch return;
    thread.detach();
}

/// Lowercase-hex-encodes a 32-byte key into `out`.
fn hexLower(out: *[64]u8, bytes: [32]u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
}

// -------------------------------------------------------------------- app run

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    g_environ = init.environ_map;

    // A returning user has a persisted session: restore it (load the local key,
    // or silently reconnect the bunker) and skip onboarding. A newcomer starts
    // at the welcome screen, and the feed comes up when they sign in (see
    // `update`). Best-effort: on failure the app still runs, showing onboarding.
    const restored = restoreSession(init.io, init.environ_map);

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
    if (restored) {
        // Returning user: open the store and start the background ingest before
        // the window appears. A newcomer's feed starts on sign-in.
        app_state.model.stage = .ready;
        startFeed(init.io, init.environ_map);
    }

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
fn startFeed(io: std.Io, environ: *const std.process.Environ.Map) void {
    if (g_store != null) return; // already running
    const gpa = std.heap.page_allocator;
    const store = gpa.create(nostr.store.Store) catch return;
    store.* = openFeedStore(io, environ) catch |err| {
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
// `$HOME/.plaza/identity.key` (the raw 32-byte secret, mode 0600). It is created
// on the user's onboarding action, not silently: a first run with no key file
// opens the welcome screen, and "Create your identity" generates and persists
// it. This is the zero-config local signer; connecting an external signer
// (Signet, over NIP-46) so the key never touches the client is the next
// onboarding option, and swaps in at `signNote`.

/// Opens (creating if needed) `$HOME/.plaza`, returning the directory handle.
fn plazaDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Loads the identity from `identity.key` if present, adopting it and returning
/// true. Never generates a key, that is the onboarding action's job.
fn loadIdentityIfPresent(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var dir = plazaDir(io, environ) catch return false;
    defer dir.close(io);

    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "identity.key", gpa, std.Io.Limit.limited(64)) catch return false;
    defer gpa.free(raw);
    if (raw.len != 32) return false;

    var signer = nostr.keys.Signer.init();
    var secret: [32]u8 = undefined;
    @memcpy(&secret, raw[0..32]);
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        return false;
    };
    g_signer_kind = .local;
    setIdentity(signer, kp);
    return true;
}

/// Generates a fresh identity, persists it (mode 0600), and adopts it. Backs the
/// onboarding "create identity" action, using the io and environment stashed in
/// `main`. Returns true on success.
fn createLocalIdentity() bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;

    var signer = nostr.keys.Signer.init();
    const kp = signer.generateKeyPair(io) catch {
        signer.deinit();
        return false;
    };

    persistIdentityKey(io, environ, kp.secret_key);
    g_signer_kind = .local;
    setIdentity(signer, kp);
    return true;
}

/// Imports an existing key from a bech32 `nsec`, persists it (mode 0600), and
/// adopts it as the local identity. Backs the onboarding "paste your nsec" path.
/// On a malformed key sets the login error and returns false.
fn importNsec(nsec: []const u8) bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;
    const gpa = std.heap.page_allocator;

    const secret = nostr.nip19.decodeNsec(gpa, nsec) catch {
        g_login_error.store(@intFromEnum(LoginError.bad_key), .release);
        return false;
    };
    var signer = nostr.keys.Signer.init();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        g_login_error.store(@intFromEnum(LoginError.bad_key), .release);
        return false;
    };

    persistIdentityKey(io, environ, secret);
    g_signer_kind = .local;
    setIdentity(signer, kp);
    return true;
}

/// Writes the raw 32-byte secret to `$HOME/.plaza/identity.key` at mode 0600,
/// replacing any existing file. A failure to persist is non-fatal: the session
/// still runs with the in-memory key (it just will not survive a relaunch).
fn persistIdentityKey(io: std.Io, environ: *const std.process.Environ.Map, secret: [32]u8) void {
    var dir = plazaDir(io, environ) catch |err| {
        std.debug.print("plaza: could not open key dir: {s}\n", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    // Replace any prior key (a logout deletes it, so normally there is none).
    dir.deleteFile(io, "identity.key") catch {};
    dir.writeFile(io, .{
        .sub_path = "identity.key",
        .data = &secret,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    }) catch |err| std.debug.print("plaza: could not persist identity: {s}\n", .{@errorName(err)});
}

/// Sets the identity globals: the signer, the keypair, and the abbreviated npub
/// the composer shows. The signer's secp256k1 context is used only on the UI
/// thread.
fn setIdentity(signer: nostr.keys.Signer, kp: nostr.keys.KeyPair) void {
    g_identity_signer = signer;
    g_identity_kp = kp;
    const npub = abbreviateNpub(&g_identity_npub_buf, kp.public_key);
    g_identity_npub_len = npub.len;
}

// ------------------------------------------------------------------- session
//
// The active identity is persisted as a small session file at
// `$HOME/.plaza/session` (mode 0600), a line-based `key=value` record, so a
// returning user is signed straight back in without re-entering anything. A
// local session points at `identity.key` (the raw secret already on disk); a
// remote session carries everything needed to silently reconnect the NIP-46
// bunker (the signer's pubkey, its relay, our ephemeral transport secret, and
// the connect secret), never the user's own key, which lives only in the signer.

/// Writes the session file for the current identity kind. Best-effort: a failure
/// to persist just means this identity will not auto-restore next launch.
fn persistSession() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);

    var buf: [1024]u8 = undefined;
    const data = switch (g_signer_kind) {
        .local => std.fmt.bufPrint(&buf, "kind=local\n", .{}) catch return,
        .remote => blk: {
            const kp = g_remote_client_kp orelse return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, g_remote_pubkey);
            var cs_hex: [64]u8 = undefined;
            hexLower(&cs_hex, kp.secret_key);
            break :blk std.fmt.bufPrint(&buf, "kind=remote\nremote_pubkey={s}\nrelay={s}\nclient_secret={s}\nsecret={s}\n", .{
                &pk_hex,
                g_remote_relay_buf[0..g_remote_relay_len],
                &cs_hex,
                g_remote_secret_buf[0..g_remote_secret_len],
            }) catch return;
        },
    };
    dir.writeFile(io, .{
        .sub_path = "session",
        .data = data,
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
    }) catch |err| std.debug.print("plaza: could not persist session: {s}\n", .{@errorName(err)});
}

/// Restores the persisted identity at boot. Returns whether a session was
/// restored (so the feed should start). Reads `$HOME/.plaza/session`; falls back
/// to migrating a legacy `identity.key` (pre-session installs) into a local
/// session. Any missing or malformed data returns false, landing on onboarding.
fn restoreSession(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var dir = plazaDir(io, environ) catch return false;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;

    const raw = dir.readFileAlloc(io, "session", gpa, std.Io.Limit.limited(2048)) catch {
        // No session file: adopt a legacy local key if one is on disk.
        if (loadIdentityIfPresent(io, environ)) {
            persistSession();
            return true;
        }
        return false;
    };
    defer gpa.free(raw);

    var kind: []const u8 = "";
    var f_pubkey: []const u8 = "";
    var f_relay: []const u8 = "";
    var f_client_secret: []const u8 = "";
    var f_secret: []const u8 = "";
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "kind")) kind = val;
        if (std.mem.eql(u8, key, "remote_pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "relay")) f_relay = val;
        if (std.mem.eql(u8, key, "client_secret")) f_client_secret = val;
        if (std.mem.eql(u8, key, "secret")) f_secret = val;
    }

    if (std.mem.eql(u8, kind, "local")) return loadIdentityIfPresent(io, environ);
    if (std.mem.eql(u8, kind, "remote")) return restoreRemoteSigner(gpa, f_pubkey, f_relay, f_client_secret, f_secret);
    return false;
}

/// Rebuilds the remote-signer connection from a persisted session and reconnects
/// silently: adopts the bunker pubkey as the identity, reconstructs the ephemeral
/// transport key, starts the response listener, and re-sends `connect`.
fn restoreRemoteSigner(gpa: std.mem.Allocator, pubkey_hex: []const u8, relay: []const u8, client_secret_hex: []const u8, secret: []const u8) bool {
    if (pubkey_hex.len != 64 or client_secret_hex.len != 64) return false;
    if (relay.len == 0 or relay.len > g_remote_relay_buf.len) return false;
    if (secret.len > g_remote_secret_buf.len) return false;

    var pubkey: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pubkey, pubkey_hex) catch return false;
    var client_secret: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&client_secret, client_secret_hex) catch return false;

    var signer = nostr.keys.Signer.init();
    const client_kp = signer.keyPairFromSecretKey(client_secret) catch {
        signer.deinit();
        return false;
    };
    signer.deinit();

    g_remote_pubkey = pubkey;
    @memcpy(g_remote_relay_buf[0..relay.len], relay);
    g_remote_relay_len = relay.len;
    @memcpy(g_remote_secret_buf[0..secret.len], secret);
    g_remote_secret_len = secret.len;
    g_remote_client_kp = client_kp;

    const npub = abbreviateNpub(&g_identity_npub_buf, pubkey);
    g_identity_npub_len = npub.len;
    g_signer_kind = .remote;
    g_remote_status.store(1, .release);

    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{gpa}) catch return false;
    thread.detach();
    sendConnect(gpa);
    return true;
}

/// Logs out: deletes the session (and, for a local key, the key file itself),
/// resets the identity globals, and returns to onboarding. The feed store and
/// its ingest threads keep running (they serve the starter pack regardless of
/// who is signed in); a subsequent sign-in reuses them. The user is never locked
/// in, a local key can always be copied from Settings first, and a remote
/// signer keeps the user's key throughout.
fn performLogout(model: *Model) void {
    if (g_io) |io| if (g_environ) |environ| {
        if (plazaDir(io, environ)) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            dir.deleteFile(io, "session") catch {};
            if (g_signer_kind == .local) dir.deleteFile(io, "identity.key") catch {};
        } else |_| {}
    };

    // Reset identity state. The detached NIP-46 listener (if any) keeps looping
    // against the old bunker but is orphaned: nothing reads its results once the
    // identity is cleared. A clean per-session teardown is future work.
    if (g_identity_signer) |*s| s.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_identity_npub_len = 0;
    g_signer_kind = .local;
    g_remote_client_kp = null;
    g_remote_relay_len = 0;
    g_remote_secret_len = 0;
    g_remote_status.store(0, .release);
    g_login_error.store(@intFromEnum(LoginError.none), .release);
    g_last_count = std.math.maxInt(usize);

    model.login_buffer.clear();
    model.draft_buffer.clear();
    model.logout_pending = false;
    model.reveal_nsec = false;
    model.notes_len = 0;
    model.stage = .onboarding;
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

    // Follow-scoped: only the starter pack's recent notes, so the pool streams
    // the user's feed rather than the whole firehose.
    const kinds = [_]u16{1};
    const filters = [_]nostr.filter.Filter{.{ .authors = &starter_pack, .kinds = &kinds, .limit = feed_capacity }};
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

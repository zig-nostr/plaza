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
//! The static screens live in `onboarding.native` and `settings.native`; the
//! feed is a Zig view (inline images need a runtime image reference the markup
//! grammar does not carry). This file is the logic.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const plaza_icons = @import("plaza_icons.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
// A desktop window sized for the redesign's centered reading column: the feed
// content is a fixed 620px column, so the window opens wide enough to seat it
// with margin, and extra width past that becomes margin, never a longer line.
const window_width: f32 = 680;
const window_height: f32 = 820;
const feed_column_width: f32 = 620;

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

// How many notes the feed can hold, and how many it asks the store for at
// first. The list is windowed, so holding more costs memory, not frames; the
// query grows a page at a time as the reader reaches the end.
const feed_capacity = 300;
const feed_page = 60;
// The composer's fixed text capacity. Comfortably longer than a typical note;
// the display buffer (`Note.content_buf`) truncates for rendering, but the
// published event carries the full draft.
const compose_capacity = 512;
const refresh_timer_key: u64 = 1;
const refresh_interval_ms: u64 = 1_000;
// Wanted-profile fetching runs on its own cadence, decoupled from the view
// refresh: an author's name and avatar do not need per-second freshness, and a
// separate engine timer is the seam a future data-plane extraction cuts along.
const profile_timer_key: u64 = 3;
const profile_interval_ms: u64 = 2_000;
// The app version shown in Settings. Keep in step with app.zon's `.version`.
const plaza_version = "0.1.0";
// Owner-only permissions for the files holding secrets. POSIX gets 0600;
// Windows has no mode bits (its permissions are file ATTRIBUTES), so it takes
// the default there and inherits the profile directory's access control.
const secret_file_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    std.Io.File.Permissions.fromMode(0o600);
// Effect keys for the two Settings clipboard copies (npub, nsec). Clipboard
// effects share the effect key space, so these stay distinct from the timer key.
const copy_npub_key: u64 = 100;
const copy_nsec_key: u64 = 101;
// Image fetches use effect keys `<base> + slot`, kept clear of the timer and
// clipboard keys above.
const avatar_fetch_key_base: u64 = 1000;
const media_fetch_key_base: u64 = 2000;
const open_url_key: u64 = 102;

// The profile cache holds display names and avatars keyed by pubkey. It is
// larger than the feed's author set so a mention can resolve to a name too.
const profile_cap = 32;
// The canvas image registry has 16 slots for the whole app, so avatars and feed
// media split it. The avatar share covers every author the follow feed can show
// (the starter pack plus the user), so nobody in the feed is stuck on initials;
// feed images take the rest through a small LRU. A mention-only cache entry,
// past the avatar budget, renders initials.
const max_avatar_images = 10;
const max_media_images = 6;
const media_image_id_base: u64 = max_avatar_images + 1;
// What each image is requested at. Avatars draw at 40pt, so asking for more
// than a couple of hundred pixels is pure waste. Feed images are bounded as a
// BOX, not just a width: the registry's budget is 1 MiB of decoded pixels, so a
// 512-wide image that happens to be tall (512x717 is a real example) still
// blows it. 480x480 leaves honest headroom under the cap.
const avatar_target_px: u32 = 128;
const media_target_px: u32 = 480;
// The largest body we accept from a fetch. The effect caps at 256 KiB anyway;
// stopping a little short keeps the decode budget for images that will fit.
const max_image_bytes = 240 * 1024;
// The registry's own ceiling on one decoded image.
const max_registered_image_bytes = 1024 * 1024;
// Animated GIFs decode every frame up front, so they are bounded twice over: by
// frame count and by total decoded bytes. An animated GIF is asked for at this
// smaller size, since it has to arrive whole inside the fetch cap.
const gif_target_px: u32 = 240;
const max_gif_frames = 64;
const max_gif_total_bytes = 24 * 1024 * 1024;
// How many play at once, and how often the shared animation timer ticks.
const max_playing_gifs = 2;
const animation_interval_ms: u32 = 80;
const animation_timer_key: u64 = 2;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view, native_sdk.security.permission_clipboard, native_sdk.security.permission_network };
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
const SignerKind = enum { local, remote, helper };
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

// ------------------------------------------------- the isolated signer helper
//
// plaza-signer holds the key in a separate PROCESS, reached over loopback HTTP.
// Plaza spawns it at launch, writes it a 0600 bearer token, and (for now)
// health-checks it; routing the actual signing through it comes next. The port
// is Plaza-specific (not signet's 8787), so a standalone Signet and the
// built-in one never collide.
const helper_port: u16 = 8790;
const helper_spawn_key: u64 = 40;
const helper_poll_key: u64 = 41;
// The daemon binary (a sibling of Plaza's own executable) and the shared token,
// resolved once in main and read by boot/tick.
var g_helper_bin_buf: [1024]u8 = undefined;
var g_helper_bin_len: usize = 0;
var g_helper_token_buf: [64]u8 = undefined;
var g_helper_token_len: usize = 0;
var g_helper_state_dir_buf: [512]u8 = undefined;
var g_helper_state_dir_len: usize = 0;
var g_helper_token_path_buf: [512]u8 = undefined;
var g_helper_token_path_len: usize = 0;
// 0 starting, 1 uninitialized (reachable, no key yet), 2 ready (holds a key),
// 3 unreachable. Reachable at all (1 or 2) is what proves the loopback IPC.
var g_helper_state = std.atomic.Value(u8).init(0);

fn helperBin() []const u8 {
    return g_helper_bin_buf[0..g_helper_bin_len];
}
fn helperToken() []const u8 {
    return g_helper_token_buf[0..g_helper_token_len];
}

/// Resolves the daemon path (a sibling of argv[0], so it works both from the
/// dev tree and a packaged bundle), mints a fresh bearer token, and writes it
/// 0600 under ~/.plaza. Best-effort: on any failure the helper simply never
/// comes up and signing keeps to its current in-process path.
fn resolveHelper(init: std.process.Init) void {
    // The daemon lives beside Plaza's own executable.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const argv0 = args.next() orelse return;
    const dir = std.fs.path.dirname(argv0) orelse ".";
    const bin = std.fmt.bufPrint(&g_helper_bin_buf, "{s}/plaza-signer", .{dir}) catch return;
    g_helper_bin_len = bin.len;

    const home = init.environ_map.get("HOME") orelse ".";
    const state_dir = std.fmt.bufPrint(&g_helper_state_dir_buf, "{s}/.plaza", .{home}) catch return;
    g_helper_state_dir_len = state_dir.len;
    const token_path = std.fmt.bufPrint(&g_helper_token_path_buf, "{s}/.plaza/signer.token", .{home}) catch return;
    g_helper_token_path_len = token_path.len;

    // A fresh 32-byte token, hex-encoded, so a stray process on the machine
    // cannot drive the signer even if it guesses the port.
    var raw: [32]u8 = undefined;
    init.io.randomSecure(&raw) catch return;
    var hexbuf: [64]u8 = undefined;
    _ = hexLower(&hexbuf, raw);
    @memcpy(g_helper_token_buf[0..64], &hexbuf);
    g_helper_token_len = 64;

    var d = plazaDir(init.io, init.environ_map) catch return;
    defer d.close(init.io);
    d.writeFile(init.io, .{
        .sub_path = "signer.token",
        .data = &hexbuf,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch return;
}

/// Spawns the keyholder daemon: keyless, it idles serving /pubkey and /setup.
/// The parent-pid is Plaza's, so the daemon exits when Plaza does.
fn spawnHelper(fx: *Effects) void {
    if (g_helper_bin_len == 0 or g_helper_token_len == 0) return;
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{helper_port}) catch return;
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return;
    fx.spawn(.{
        .key = helper_spawn_key,
        .argv = &.{
            helperBin(),    "--serve",
            "--port",       port_str,
            "--state-dir",  g_helper_state_dir_buf[0..g_helper_state_dir_len],
            "--token-file", g_helper_token_path_buf[0..g_helper_token_path_len],
            "--parent-pid", pid_str,
        },
        .on_exit = Effects.exitMsg(.helper_exited),
        .output = .collect,
    });
}

/// Health-checks the daemon: GET /pubkey with the bearer token. A 200 (in any
/// state) proves the loopback IPC works; a connection error keeps it at
/// unreachable and the tick tries again.
fn pollHelper(fx: *Effects) void {
    if (g_helper_token_len == 0) return;
    // Poll while signed out: this both proves the IPC at startup and detects a
    // key appearing later (a terminal or window import), so Plaza adopts it
    // live. Once signed in there is nothing to watch for.
    if (activePubkey() != null) return;
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/pubkey", .{helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = helper_poll_key,
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .on_response = Effects.responseMsg(.helper_pubkey),
    });
}

/// Records the health-check result. A reachable daemon (200) tells us the IPC
/// works; the body says whether it already holds a key.
fn handleHelperPubkey(model: *Model, response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status != 200) {
        g_helper_state.store(3, .release); // unreachable, keep retrying
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    const ready = std.mem.eql(u8, parsed.value.state, nostr.signer_ipc.state_ready);
    g_helper_state.store(if (ready) 2 else 1, .release);
    if (!ready) return;

    // The daemon holds a key and Plaza is a guest: adopt it. This is how a
    // terminal or window import (which Plaza did not initiate) signs the user
    // in live. A Plaza-initiated setup is left to handleHelperSetup, which owns
    // the name beat and the remembered intent.
    if (activePubkey() != null) return;
    if (g_helper_setup != .none or g_helper_pending_in_flight != .none) return;
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    enterFeed(model);
    replayPending(model);
}

// The signed-in helper identity: its pubkey lives here (the SECRET lives only in
// the daemon). `.helper` is the built-in local key now; `g_identity_kp` stays
// null for it, so the key is never in this process.
var g_helper_identity_pk: [32]u8 = undefined;
var g_helper_has_identity = false;

// Helper setup is async and can race the daemon coming up, so an intent is
// queued and fired by the tick once the daemon is reachable. `create` mints a
// fresh key (then the name beat); `import_user` adopts a pasted nsec; `migrate`
// moves a legacy in-process key into the daemon and deletes it, silently.
const HelperSetup = enum { none, create, import_user, migrate };
var g_helper_setup: HelperSetup = .none;
var g_helper_setup_secret: [32]u8 = undefined;
const helper_setup_key: u64 = 42;
const helper_sign_key: u64 = 43;

fn helperReachable() bool {
    return g_helper_state.load(.acquire) >= 1;
}

/// Queues a helper setup and fires it now if the daemon is already up (else the
/// tick fires it the moment the health-check confirms reachability).
fn queueHelperSetup(fx: *Effects, kind: HelperSetup, secret: ?[32]u8) void {
    g_helper_setup = kind;
    if (secret) |sk| g_helper_setup_secret = sk;
    driveHelperSetup(fx);
}

/// Fires a queued setup once the daemon is reachable. Called on the tick and
/// right after queueing.
fn driveHelperSetup(fx: *Effects) void {
    if (g_helper_setup == .none or !helperReachable()) return;
    const gpa = std.heap.page_allocator;
    switch (g_helper_setup) {
        .none => {},
        .create => helperFetch(fx, helper_setup_key, "/setup", "{\"method\":\"create\"}", Effects.responseMsg(.helper_setup)),
        .import_user, .migrate => {
            const nsec = nostr.nip19.encodeNsec(gpa, g_helper_setup_secret) catch return;
            defer gpa.free(nsec);
            std.crypto.secureZero(u8, &g_helper_setup_secret);
            var body_buf: [128]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"method\":\"import\",\"secret\":\"{s}\"}}", .{nsec}) catch return;
            defer std.crypto.secureZero(u8, &body_buf);
            helperFetch(fx, helper_setup_key, "/setup", body, Effects.responseMsg(.helper_setup));
        },
    }
    // In flight now; the response either completes it or, on failure, requeues.
    g_helper_pending_in_flight = g_helper_setup;
    g_helper_setup = .none;
}
var g_helper_pending_in_flight: HelperSetup = .none;

/// A POST to the daemon with the bearer token. The body is copied by the effect,
/// so a stack buffer is fine.
fn helperFetch(fx: *Effects, key: u64, comptime path: []const u8, body: []const u8, on_response: @TypeOf(Effects.responseMsg(.helper_setup))) void {
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}" ++ path, .{helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = key,
        .url = url,
        .method = .POST,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .body = body,
        .on_response = on_response,
    });
}

/// Sends one event to the daemon to be signed. Builds the unsigned event against
/// the helper's own pubkey (so the returned id matches), wraps it, and POSTs
/// /sign; the response is the signed event, ingested and published like any
/// other. Frees `content_owned` once the request is built (the signed event
/// carries the content back).
fn requestHelperSign(fx: *Effects, gpa: std.mem.Allocator, content_owned: []const u8, kind: u16) void {
    defer gpa.free(content_owned);
    const pk = activePubkey() orelse return;
    const created = nowSeconds();
    const id = nostr.event.computeId(gpa, pk, created, kind, &.{}, content_owned) catch return;
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = pk,
        .created_at = created,
        .kind = kind,
        .tags = &.{},
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch return;
    defer gpa.free(unsigned_json);
    const body = (nostr.signer_ipc.SignEvent{ .event = unsigned_json }).toJson(gpa) catch return;
    defer gpa.free(body);
    helperFetch(fx, helper_sign_key, "/sign", body, Effects.responseMsg(.helper_signed));
}

/// Adopts a helper-held identity: only the pubkey lives here, never the secret
/// (that stays in the daemon). Clears any in-UI local key.
fn adoptHelperIdentity(pk: [32]u8) void {
    if (g_identity_signer) |*sig| sig.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_helper_identity_pk = pk;
    g_helper_has_identity = true;
    g_signer_kind = .helper;
    const npub = abbreviateNpub(&g_identity_npub_buf, pk);
    g_identity_npub_len = npub.len;
    g_last_count = std.math.maxInt(usize);
}

/// Restores a helper identity from a persisted session pubkey. Synchronous: the
/// daemon independently loads its own key, so Plaza only needs to know who it is.
fn restoreHelperIdentity(pubkey_hex: []const u8) bool {
    if (pubkey_hex.len != 64) return false;
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pubkey_hex) catch return false;
    adoptHelperIdentity(pk);
    return true;
}

/// Completes an async helper setup. On a fresh create it adopts the minted
/// identity and opens the name beat; a transient failure requeues for the tick.
fn handleHelperSetup(model: *Model, response: native_sdk.EffectResponse) void {
    const purpose = g_helper_pending_in_flight;
    g_helper_pending_in_flight = .none;
    if (response.outcome != .ok) {
        g_helper_setup = purpose; // the daemon was not up; the tick retries
        return;
    }
    if (response.status != 200) {
        // A migration is a silent background upgrade: on failure the in-process
        // key keeps working, so say nothing. Foreground setups report.
        if (purpose != .migrate) setToast(model, "Could not set up your key");
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    switch (purpose) {
        .create => {
            enterFeed(model);
            model.naming = true; // the name beat; replay follows it
        },
        .import_user => {
            enterFeed(model);
            replayPending(model);
        },
        // A completed migration: the daemon now holds the key, so delete the
        // in-process file. The user was already signed in; nothing else changes.
        .migrate => deleteIdentityKeyFile(),
        .none => {},
    }
}

/// Deletes the legacy in-process key file, once its secret is safe in the daemon.
fn deleteIdentityKeyFile() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    dir.deleteFile(io, "identity.key") catch {};
}

/// Ingests and publishes a signed event returned by the daemon. Trusted: it
/// came from our own daemon over authenticated loopback. A kind:0 seeds the
/// profile cache so the name shows at once.
fn handleHelperSigned(response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status != 200) return;
    const gpa = std.heap.page_allocator;
    var wrapped = nostr.signer_ipc.parse(nostr.signer_ipc.SignEvent, gpa, response.body) catch return;
    defer wrapped.deinit();
    var parsed = nostr.event.fromJson(gpa, wrapped.value.event) catch return;
    defer parsed.deinit();
    const owned = gpa.dupe(u8, parsed.value.content) catch return;
    var out = parsed.value;
    out.content = owned;
    out.tags = &.{};
    if (out.kind == 0) {
        if (upsertProfile(out.pubkey)) |prof| parseMetadataInto(prof, owned);
    }
    ingestAndPublish(gpa, out, null);
}
// The listener runs for one connection generation. A logout or a reconnect
// bumps this; the detached listener and the in-flight workers see the change
// and stop, so an old bunker's listener never processes into a new session (or
// a dead one). Correlating this into every pending request is the teardown fix.
var g_remote_generation = std.atomic.Value(u64).init(0);
// A remote sign that never came back, surfaced once in the composer identity
// line so a restored draft is explained rather than silently reappearing.
// Set by the timeout scan, cleared on the next edit or a later success.
var g_remote_sign_notice = std.atomic.Value(bool).init(false);

// Pending NIP-46 requests, keyed by id, so a response is correlated to the
// request that asked for it (not guessed from whether `result` parses as an
// event), and a request that never returns times out instead of losing the
// draft. A tiny spinlock guards the table: every critical section is a handful
// of field writes or an 8-slot scan and never touches IO, so a lock this cheap
// is the right tool (std.Io.Mutex would drag a per-thread `io` through every
// access, across threads that deliberately never share one).
const remote_sign_timeout_s: i64 = 30;
const max_pending_remote = 8;
const RemoteMethod = enum { connect, sign_event };
const PendingRemote = struct {
    active: bool = false,
    id_buf: [24]u8 = undefined,
    id_len: usize = 0,
    method: RemoteMethod = .connect,
    deadline_s: i64 = 0,
    generation: u64 = 0,
    // The listener flags a failed response here; the UI tick, which owns the
    // composer, is what actually restores the draft (see `scanPendingRemote`).
    failed: bool = false,
    // sign_event only: the draft text, restored to the composer on failure or
    // timeout. Owned by the slot; freed when the request resolves or is swept.
    content: ?[]const u8 = null,

    fn id(self: *const PendingRemote) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};
var g_pending_lock = std.atomic.Value(bool).init(false);
var g_pending: [max_pending_remote]PendingRemote = [_]PendingRemote{.{}} ** max_pending_remote;

fn pendingLock() void {
    while (g_pending_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn pendingUnlock() void {
    g_pending_lock.store(false, .release);
}

/// Records a request as awaiting its response, taking ownership of `content`
/// (the draft, for `sign_event`, so a timeout can restore it). Returns false
/// when the table is full or the id does not fit, in which case the caller
/// still owns `content`.
fn registerPending(req_id: []const u8, method: RemoteMethod, content: ?[]const u8) bool {
    if (req_id.len > 24) return false;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active) continue;
        slot.* = .{
            .active = true,
            .method = method,
            .id_len = req_id.len,
            .deadline_s = nowSeconds() + remote_sign_timeout_s,
            .generation = g_remote_generation.load(.acquire),
            .content = content,
        };
        @memcpy(slot.id_buf[0..req_id.len], req_id);
        return true;
    }
    return false;
}

/// Takes the pending request matching `req_id` out of the table, or null when
/// none matches (an unknown id, or one already resolved: dropping it keeps a
/// duplicated response from publishing twice). The caller owns the returned
/// slot's `content`.
fn takePending(req_id: []const u8) ?PendingRemote {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and std.mem.eql(u8, slot.id(), req_id)) {
            const taken = slot.*;
            slot.* = .{};
            return taken;
        }
    }
    return null;
}

/// Marks the pending request matching `req_id` failed, leaving it in the table
/// for the UI tick to restore the draft and free the content. Returns whether a
/// slot matched.
fn failPending(req_id: []const u8) bool {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and std.mem.eql(u8, slot.id(), req_id)) {
            slot.failed = true;
            return true;
        }
    }
    return false;
}

// Test seams for the NIP-46 pending-request table (the correlation and teardown
// logic), exercised without threads or a live bunker.
pub const RemoteMethodForTest = RemoteMethod;
pub fn registerPendingForTest(req_id: []const u8, method: RemoteMethod, content: ?[]const u8) bool {
    return registerPending(req_id, method, content);
}
pub fn takePendingContentForTest(req_id: []const u8) ?struct { method: RemoteMethod, content: ?[]const u8 } {
    const taken = takePending(req_id) orelse return null;
    return .{ .method = taken.method, .content = taken.content };
}
pub fn failPendingForTest(req_id: []const u8) bool {
    return failPending(req_id);
}
pub fn clearPendingForTest() void {
    clearPending();
}
pub fn bumpRemoteGenerationForTest() void {
    _ = g_remote_generation.fetchAdd(1, .monotonic);
}
pub fn scanPendingRemoteForTest(model: *Model) void {
    scanPendingRemote(model);
}
pub fn remoteSignNoticeForTest() bool {
    return g_remote_sign_notice.load(.acquire);
}

/// Empties the pending table, freeing every held draft. For logout, so a new
/// session never inherits the old one's in-flight requests.
fn clearPending() void {
    const gpa = std.heap.page_allocator;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        if (slot.content) |c| gpa.free(c);
        slot.* = .{};
    }
}

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

// --------------------------------------------------------------- media proxy
//
// The image registry decodes at most a 512x512 image and the fetch effect caps
// bodies at 256 KiB, so a full-size photo can neither be downloaded nor decoded
// as-is. Images are therefore requested at the size they will actually be drawn:
// through a host's own resizer when it has one, otherwise through a
// weserv-compatible proxy (the free public wsrv.nl by default, and any instance
// the user prefers, including their own). Clearing the setting loads originals
// straight from their host, which still works for anything small enough.

const default_media_proxy = "https://wsrv.nl/";
var g_media_proxy_buf: [200]u8 = undefined;
var g_media_proxy_len: usize = 0;

/// The configured proxy base URL, empty when images load directly.
pub fn mediaProxy() []const u8 {
    return g_media_proxy_buf[0..g_media_proxy_len];
}

/// Sets the proxy base URL (trimmed; empty disables proxying).
pub fn setMediaProxy(url: []const u8) void {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const n = @min(trimmed.len, g_media_proxy_buf.len);
    @memcpy(g_media_proxy_buf[0..n], trimmed[0..n]);
    g_media_proxy_len = n;
}

/// Whether the host serves its own resized variants via `?w=`, letting us skip
/// the proxy hop entirely. nostr.build's Blossom hosts do; most others ignore it.
fn hostSupportsWidthParam(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "://blossom.nostr.build/") != null or
        std.mem.indexOf(u8, src, "://blossom.band/") != null or
        std.mem.indexOf(u8, src, ".blossom.band/") != null;
}

/// How an image is fitted when resized.
pub const MediaFit = enum {
    /// Square, cropped to fill: avatars.
    square,
    /// Scaled down to fit inside a square box, aspect preserved: feed images.
    /// Bounding both edges is what keeps a tall image inside the pixel budget.
    inside,
    /// Like `inside`, but every frame is kept and the result stays a GIF, so it
    /// can still animate. Asked for smaller, since the whole animation has to
    /// arrive inside the fetch cap.
    animation,
};

/// Whether `src` points at a GIF, which is fetched keeping its frames.
pub fn isGifUrl(src: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, src, '?') orelse src.len;
    return std.ascii.endsWithIgnoreCase(src[0..path_end], ".gif");
}

/// Builds the URL to fetch `src` at roughly `width` pixels, writing into `out`
/// and returning the slice to request. Falls back to `src` itself whenever no
/// resizing route applies or the URL would not fit.
pub fn mediaUrl(out: []u8, src: []const u8, width: u32, fit: MediaFit) []const u8 {
    // A host that resizes for us: cheapest path, no third party involved.
    if (hostSupportsWidthParam(src) and std.mem.indexOfScalar(u8, src, '?') == null) {
        return std.fmt.bufPrint(out, "{s}?w={d}", .{ src, width }) catch src;
    }
    const proxy = mediaProxy();
    if (proxy.len == 0) return src;

    var encoded_buf: [768]u8 = undefined;
    const encoded = percentEncode(&encoded_buf, src) orelse return src;
    const sep: []const u8 = if (std.mem.endsWith(u8, proxy, "/")) "" else "/";
    return switch (fit) {
        .square => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=cover&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        .inside => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        // `n=-1` keeps every frame; the output stays a GIF because that is the
        // animated format the vendored decoder can read frame by frame.
        .animation => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&n=-1&output=gif", .{ proxy, sep, encoded, width, width }) catch src,
    };
}

/// Percent-encodes `src` into `out` (everything outside the unreserved set), so
/// a source URL survives as one query parameter. Null if it would not fit.
fn percentEncode(out: []u8, src: []const u8) ?[]const u8 {
    const hexdigits = "0123456789ABCDEF";
    var n: usize = 0;
    for (src) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            if (n + 1 > out.len) return null;
            out[n] = c;
            n += 1;
        } else {
            if (n + 3 > out.len) return null;
            out[n] = '%';
            out[n + 1] = hexdigits[c >> 4];
            out[n + 2] = hexdigits[c & 0x0f];
            n += 3;
        }
    }
    return out[0..n];
}

// ------------------------------------------------------------------ profiles
//
// Kind:0 metadata gives each author a display name and an avatar. The pool
// ingests kind:0 for the feed's authors alongside their notes (the store keeps
// only the newest per author, kind:0 being replaceable); the UI thread parses
// them into this cache during the feed rebuild, keyed by pubkey. The feed reads
// names and avatar image ids from the cache at render time, so a name or a
// just-loaded avatar shows on the next frame without a re-query. Avatars are
// fetched (bounded, cap-aware) and registered as canvas images; the cache is
// UI-thread-only, so no synchronisation is needed.

// Pubkeys a note mentioned that we have no name for. The pool only subscribes
// to the follow set's metadata, so a mention of anyone else would render as a
// bare npub forever; these are fetched separately, once each, and then resolve
// like any other name.
const wanted_profiles_cap = 24;
const WantedProfile = struct {
    used: bool = false,
    requested: bool = false,
    /// How many times this one has been asked for. Some pubkeys simply have no
    /// metadata published anywhere, so the asking is bounded.
    attempts: u8 = 0,
    pubkey: [32]u8 = [_]u8{0} ** 32,
};
/// How many rounds to ask for a mentioned profile before letting it be.
const max_profile_attempts = 3;
var g_wanted = [_]WantedProfile{.{}} ** wanted_profiles_cap;

/// Notes that `pubkey` was mentioned but has no known name yet.
fn wantProfile(pubkey: [32]u8) void {
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) return;
    }
    for (&g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return;
    }
    for (&g_wanted) |*w| {
        if (!w.used) {
            w.* = .{ .used = true, .pubkey = pubkey };
            return;
        }
    }
}

/// Profile-timer rounds between re-asking for metadata that has not arrived
/// (about 20s at the profile interval).
const profile_rearm_rounds: u64 = 10;
var g_profile_round: u64 = 0;

/// Lets the still-unnamed be asked for again on the next pass.
fn rearmWantedProfiles() void {
    for (&g_wanted) |*w| {
        if (w.used and w.attempts < max_profile_attempts) w.requested = false;
    }
}

/// Asks the relays for the metadata of everyone mentioned but still unnamed, in
/// one batch on a throwaway connection.
fn requestWantedProfiles() void {
    var batch: [wanted_profiles_cap][32]u8 = undefined;
    var n: usize = 0;
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        // Resolved: free the slot so later mentions can use it. Without this the
        // table fills with names we already have and new mentions are dropped.
        if (lookupProfile(w.pubkey)) |p| {
            if (p.name_len > 0) {
                w.* = .{};
                continue;
            }
        }
        if (w.attempts >= max_profile_attempts) continue;
        if (w.requested) continue;
        batch[n] = w.pubkey;
        n += 1;
        w.requested = true;
        w.attempts += 1;
        if (n == batch.len) break;
    }
    if (n == 0) return;
    const thread = std.Thread.spawn(.{}, fetchProfilesOnce, .{ std.heap.page_allocator, batch, n }) catch return;
    thread.detach();
}

/// Fetches kind:0 for `batch` and ingests it, then closes. Its own io backend
/// and signer, like every other background worker.
fn fetchProfilesOnce(gpa: std.mem.Allocator, batch: [wanted_profiles_cap][32]u8, len: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{.{ .authors = batch[0..len], .kinds = &kinds, .limit = @intCast(len) }};
    for (relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        relay.subscribe("plaza-mentions", &filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const store = g_store orelse continue;
                    _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
                },
                // Everything stored has been sent; no need to hold the socket.
                .eose => break,
                else => {},
            }
        }
        // Keep going: no single relay holds everyone's metadata, and the store
        // keeps only the newest copy of each anyway.
    }
}

/// A cached author profile.
const Profile = struct {
    used: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    picture_buf: [200]u8 = [_]u8{0} ** 200,
    picture_len: u8 = 0,
    /// The resolved avatar URL, which is also its cache key.
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,
    /// The id of the kind:0 event these fields came from, so an unchanged
    /// event is never parsed twice (the store keeps only the newest per
    /// author, but the feed reconciles every second).
    meta_id: [32]u8 = [_]u8{0} ** 32,
    // The avatar's lifecycle: not yet fetched, in flight, registered, or given
    // up on (initials fallback).
    avatar_state: enum { idle, fetching, loaded, failed } = .idle,
    // The registered canvas-image id for this profile's avatar (0 = none). Fixed
    // per cache slot, so a re-fetch replaces the same id.
    image_id: u64 = 0,

    fn name(self: *const Profile) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn picture(self: *const Profile) []const u8 {
        return self.picture_buf[0..self.picture_len];
    }
    fn url(self: *const Profile) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

var g_profiles = [_]Profile{.{}} ** profile_cap;

// Bumped whenever a profile gains or changes a display name. Mention labels are
// baked into note text at parse time, so the feed re-parses (rather than
// reuses) its notes when this moves; author lines resolve live and never need it.
var g_names_generation: u64 = 0;

/// Clears the profile cache. For tests, which share the process globals.
pub fn resetProfilesForTest() void {
    g_profiles = [_]Profile{.{}} ** profile_cap;
    g_names_generation = 0;
    g_notes_names_generation = 0;
}

/// Finds the cached profile for `pubkey`, or null.
fn lookupProfile(pubkey: [32]u8) ?*Profile {
    for (&g_profiles) |*p| {
        if (p.used and std.mem.eql(u8, &p.pubkey, &pubkey)) return p;
    }
    return null;
}

/// The cache slot for `pubkey`, allocating a free one on first sight. Null only
/// when the cache is full (then that author renders from its npub and initials).
pub fn upsertProfile(pubkey: [32]u8) ?*Profile {
    if (lookupProfile(pubkey)) |p| return p;
    for (&g_profiles, 0..) |*p, i| {
        if (!p.used) {
            p.* = .{ .used = true, .pubkey = pubkey };
            // The first slots own an avatar image id; beyond the registry's
            // budget, an entry is name-only (initials avatar).
            if (i < max_avatar_images) p.image_id = @intCast(i + 1);
            return p;
        }
    }
    return null;
}

/// Parses a kind:0 metadata JSON content into `profile`'s name and picture.
/// Tolerant: unknown fields are ignored and a malformed blob leaves the profile
/// unchanged (it just keeps rendering from its npub). Prefers `display_name`
/// (or the legacy `displayName`) over `name`.
pub fn parseMetadataInto(profile: *Profile, content: []const u8) void {
    const Metadata = struct {
        name: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        displayName: ?[]const u8 = null,
        picture: ?[]const u8 = null,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const md = std.json.parseFromSliceLeaky(Metadata, arena_state.allocator(), content, .{ .ignore_unknown_fields = true }) catch return;

    // The first name that is actually SET wins. Checking presence alone is not
    // enough: plenty of real profiles carry `"display_name": ""` alongside a
    // real `name` (jb55's does), and an empty winner drops the author back to a
    // bare npub.
    for ([_]?[]const u8{ md.displayName, md.display_name, md.name }) |candidate| {
        const raw = candidate orelse continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const n = utf8SafeLen(trimmed, profile.name_buf.len);
        @memcpy(profile.name_buf[0..n], trimmed[0..n]);
        profile.name_len = @intCast(n);
        break;
    }
    if (md.picture) |pic| {
        const trimmed = std.mem.trim(u8, pic, " \t\r\n");
        if (trimmed.len <= profile.picture_buf.len and (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://"))) {
            // A changed picture URL means the old avatar is stale: refetch it
            // into the same image slot.
            if (!std.mem.eql(u8, trimmed, profile.picture())) {
                @memcpy(profile.picture_buf[0..trimmed.len], trimmed);
                profile.picture_len = @intCast(trimmed.len);
                if (profile.avatar_state != .fetching) profile.avatar_state = .idle;
            }
        }
    }
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
        .helper => if (g_helper_has_identity) g_helper_identity_pk else null,
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
    // The author's full pubkey, so the view can resolve a display name and an
    // avatar from the profile cache at render time (picking up a name or a
    // just-loaded avatar without rebuilding the note).
    pubkey: [32]u8 = [_]u8{0} ** 32,
    initials_buf: [2]u8 = [_]u8{0} ** 2,
    author_buf: [24]u8 = [_]u8{0} ** 24,
    author_len: u8 = 0,
    time_buf: [12]u8 = [_]u8{0} ** 12,
    time_len: u8 = 0,
    content_buf: [220]u8 = [_]u8{0} ** 220,
    content_len: u16 = 0,
    // The first image URL in the note, lifted out of the text and rendered as a
    // picture instead (see `renderContent`'s `omit`).
    image_url_buf: [300]u8 = [_]u8{0} ** 300,
    image_url_len: u16 = 0,
    // Height divided by width, taken from the note's own NIP-92 `imeta dim`
    // when it carries one. Knowing the shape BEFORE the picture downloads is
    // what lets the card reserve exactly the right space, so nothing shifts
    // when the image arrives (or is evicted and comes back).
    image_aspect: f32 = 0,

    pub fn initials(self: *const Note) []const u8 {
        return &self.initials_buf;
    }
    /// Whether this note carries an image to render.
    pub fn hasImage(self: *const Note) bool {
        return self.image_url_len > 0;
    }
    /// The note's image URL (empty when it has none).
    pub fn imageUrl(self: *const Note) []const u8 {
        return self.image_url_buf[0..self.image_url_len];
    }
    /// The registered image id for this note's picture, or 0 while it is
    /// loading, unavailable, or absent.
    pub fn media_id(self: *const Note) u64 {
        if (mediaSlotFor(self.id)) |m| {
            if (m.state == .loaded) return m.image_id;
        }
        return 0;
    }
    /// The author's display name from their kind:0 profile, or the abbreviated
    /// npub until (or unless) a profile is known.
    pub fn author(self: *const Note) []const u8 {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.name_len > 0) return p.name();
        }
        return self.author_buf[0..self.author_len];
    }
    /// The registered avatar image id for this author, or 0 to draw initials.
    pub fn avatar_id(self: *const Note) u64 {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.avatar_state == .loaded) return p.image_id;
        }
        return 0;
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
    // The media-proxy field in Settings (see `g_media_proxy_buf`).
    proxy_buffer: canvas.TextBuffer(200) = .{},
    proxy_saved: bool = false,
    // Which note's picture is expanded to fill the window, if any.
    expanded_note: ?i64 = null,
    // Whether the compose sheet is open. Compose is on demand from the "New
    // note" button in the titlebar, not a permanent bar, so the feed fills the
    // window.
    composing: bool = false,
    // Whether the guest dismissed the join strip this session. Dismissal only
    // hides the strip; the join surface stays reachable through every gated
    // verb and the status bar's Guest chip.
    guest_strip_dismissed: bool = false,
    // Whether the first-intent join sheet is up (the ladder: create, bring a
    // key, use a signer). Rises when a guest presses a gated verb, or from the
    // strip and the Guest chip.
    joining: bool = false,
    // The remembered intent: the guest reached for the composer, so composing
    // opens by itself the moment an identity exists. The sheet says so.
    pending_compose: bool = false,
    // The name beat: after creating an identity, one optional, skippable ask
    // so the account is not blank. Never for imported keys or signers.
    naming: bool = false,
    name_buffer: canvas.TextBuffer(64) = .{},
    // A small confirming toast ("Posted", "Name set"), cleared by the tick.
    toast_buf: [48]u8 = undefined,
    toast_len: usize = 0,
    toast_until: i64 = 0,
    // The backup nudge after the first local-key post this session: calm,
    // dismissible, stakes stated plainly.
    backup_nudge: bool = false,
    backup_nudge_dismissed: bool = false,
    // Where the feed is scrolled, so images load around the viewport instead of
    // only at the top. The windowed list replaces this estimate with the
    // runtime's exact visible range in the next milestone.
    feed_scroll: canvas.ScrollState = .{},
    // How many notes the feed currently asks the store for; grows a page at a
    // time as the reader reaches the end.
    feed_limit: usize = feed_page,

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, the stage through
    // `show_onboarding`/`show_feed`/`show_settings`, the login field through
    // `login_draft`, so the raw fields are never bound by name.
    // Everything the FEED reads is listed here too: that screen is a Zig view
    // now, so markup never binds its state (the welcome and Settings fragments
    // still bind theirs, and are still checked).
    pub const view_unbound = .{
        "notes",                 "notes_len",     "live_relays",            "offline_relays", "draft_buffer",
        "stage",                 "login_buffer",  "logout_pending",         "reveal_nsec",    "proxy_buffer",
        "proxy_saved",           "feed_scroll",   "feed_limit",             "draft",          "draft_empty",
        "identity",              "has_notes",     "empty",                  "status",         "empty_text",
        "footer",                "note_list",     "expanded_note",          "composing",      "caught_up",
        "relay_health",          "relays_online", "scope_voices",           "is_guest",       "show_guest_strip",
        "guest_strip_dismissed", "joining",       "pending_compose",        "naming",         "name_buffer",
        "name_draft",            "name_empty",    "toast_buf",              "toast_len",      "toast_until",
        "toast_text",            "backup_nudge",  "backup_nudge_dismissed",
    };

    /// The name beat's current text.
    pub fn name_draft(self: *const Model) []const u8 {
        return self.name_buffer.text();
    }
    /// Whether the name field is blank, which disables Save.
    pub fn name_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.name_buffer.text(), " \t\r\n").len == 0;
    }
    /// The live toast text, empty when none is showing.
    pub fn toast_text(self: *const Model) []const u8 {
        if (self.toast_until == 0) return "";
        return self.toast_buf[0..self.toast_len];
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
        // A remote sign that never came back: the draft has been restored to the
        // composer, so say why rather than let it silently reappear.
        if (g_signer_kind == .remote and g_remote_sign_notice.load(.acquire))
            return "Your signer didn't respond. Draft restored, try again.";
        if (g_identity_npub_len == 0) return "Preparing your key…";
        // Show the user's own display name once their kind:0 is known, else npub.
        var who: []const u8 = g_identity_npub_buf[0..g_identity_npub_len];
        if (activePubkey()) |pk| {
            if (lookupProfile(pk)) |p| {
                if (p.name_len > 0) who = p.name();
            }
        }
        if (g_signer_kind == .remote) {
            // The connection's honest state, not just its happy path: reaching,
            // signing as (which key), or unreachable.
            return switch (g_remote_status.load(.acquire)) {
                1 => std.fmt.allocPrint(arena, "Reaching your signer · {s}", .{who}) catch who,
                2 => std.fmt.allocPrint(arena, "Signing via your signer · {s}", .{who}) catch who,
                3 => "Your signer is unreachable. Posts will not sign.",
                else => std.fmt.allocPrint(arena, "Your signer · {s}", .{who}) catch who,
            };
        }
        return std.fmt.allocPrint(arena, "Posting as {s}", .{who}) catch who;
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
            .helper => "Signet",
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
            .helper => "Your key will be removed from Signet on this device. Back it up first if you want to keep this identity.",
        };
    }
    /// The media-proxy field's text (what `text="{proxy_draft}"` binds).
    pub fn proxy_draft(self: *const Model) []const u8 {
        return self.proxy_buffer.text();
    }
    /// Confirmation under the media-proxy field.
    pub fn proxy_status(self: *const Model) []const u8 {
        if (!self.proxy_saved) return "";
        return if (g_media_proxy_len == 0) "Saved. Loading originals directly." else "Saved.";
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

    /// The status bar's left text, which doubles as the caught-up footer: there
    /// is no separate spinner, the feed renders from disk before the window
    /// finishes opening.
    pub fn caught_up(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notes_len == 0) return "Starter pack";
        return std.fmt.allocPrint(arena, "Caught up · starter pack · {d} notes", .{self.notes_len}) catch "Starter pack";
    }

    /// The status bar's relay health, drawn after the online dot.
    pub fn relay_health(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}/{d} relays", .{ self.live_relays, relays.len }) catch "relays";
    }

    /// Whether at least one relay is connected (drives the status dot color).
    pub fn relays_online(self: *const Model) bool {
        return self.live_relays > 0;
    }

    /// Whether the reader is browsing without an identity. Reading never
    /// needs one; the gated verbs ask at first intent.
    pub fn is_guest(self: *const Model) bool {
        _ = self;
        return activePubkey() == null;
    }

    /// Whether the guest join strip is showing (guest, and not dismissed).
    pub fn show_guest_strip(self: *const Model) bool {
        return self.is_guest() and !self.guest_strip_dismissed;
    }

    /// The feed's scope line: how many hand-picked voices it is scoped to.
    pub fn scope_voices(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "{d} voices · hand-picked", .{starter_pack.len}) catch "hand-picked";
    }

    /// The note with this id, if it is still in the feed.
    pub fn noteById(self: *const Model, note_id: i64) ?*const Note {
        for (self.notes[0..self.notes_len]) |*note| {
            if (note.id == note_id) return note;
        }
        return null;
    }

    /// The span of notes at or near the viewport, which is what gets pictures.
    /// Card heights vary, so this estimates from the average (total content over
    /// note count) and pads generously; being a row or two wide only costs a
    /// prefetch. Before the first scroll event it reports the top of the feed.
    pub fn visibleRange(self: *const Model) struct { first: usize, last: usize } {
        if (self.notes_len == 0) return .{ .first = 0, .last = 0 };
        // The windowed list reports the exact rows it put on screen, so this is
        // no longer an estimate. Before the first build it reports the top.
        const last_row = self.notes_len - 1;
        if (g_visible_last == 0 and g_visible_first == 0) {
            return .{ .first = 0, .last = @min(last_row, max_media_images - 1) };
        }
        return .{ .first = @min(g_visible_first, last_row), .last = @min(g_visible_last, last_row) };
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
            // Profiles first, so a note's mentions resolve to names as it builds.
            refreshProfiles(store);
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
        // Only as much as the reader has paged into, so the rebuild cost stays
        // flat until they actually ask for more.
        const limit = @min(self.feed_limit, feed_capacity);
        var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = @intCast(limit) }) catch return;
        defer result.deinit();

        // The store's count moves on every kind of ingest (profiles included),
        // and the pool streams all day, so this runs about once a second. The
        // notes themselves rarely change: reuse the already-parsed card whenever
        // the event is one we hold, and parse only what is genuinely new.
        // Mention labels are baked into content at parse time, so a new display
        // name (the generation) forces one full parse pass to refresh them.
        const reuse_ok = g_names_generation == g_notes_names_generation;
        g_notes_names_generation = g_names_generation;

        // Nothing new at all: the usual tick, when the count moved for some
        // other kind of event. Keep every card exactly as it is.
        if (reuse_ok and result.events.len == self.notes_len) {
            var same = true;
            for (result.events, 0..) |ev, i| {
                if (noteIdOf(ev) != self.notes[i].id) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }

        // The old cards, so new positions can take them over by id.
        const old = &g_notes_scratch;
        const old_len = self.notes_len;
        @memcpy(old[0..old_len], self.notes[0..old_len]);

        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= limit) break;
            const id = noteIdOf(ev);
            self.notes[n] = blk: {
                if (reuse_ok) {
                    for (old[0..old_len]) |*prev| {
                        if (prev.id == id) break :blk prev.*;
                    }
                }
                break :blk noteFrom(ev, now_s);
            };
            n += 1;
        }
        self.notes_len = n;
    }
};

/// Adopts `secret` as the active local identity. For tests: the feed scopes
/// its queries to the follow set plus the signed-in user, so a test that
/// stores its own events needs to BE somebody.
pub fn setIdentityForTest(secret: [32]u8) void {
    var signer = nostr.keys.Signer.init();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        return;
    };
    g_signer_kind = .local;
    setIdentity(signer, kp);
}

/// Clears the active identity again. For tests.
pub fn clearIdentityForTest() void {
    if (g_identity_signer) |*sgn| sgn.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_identity_npub_len = 0;
    g_signer_kind = .local;
}

/// Reconciles profiles and notes against `store` directly, bypassing the
/// count guard. For tests, which drive the store themselves.
pub fn reconcileForTest(model: *Model, store: *nostr.store.Store, now_s: i64) void {
    refreshProfiles(store);
    model.rebuildNotes(store, now_s);
}

/// The feed key derived from an event id: the first eight bytes, sign bit
/// masked so the markup engine's i64 key round-trip never overflows.
pub fn noteIdOf(ev: nostr.event.Event) i64 {
    return @intCast(std.mem.readInt(u64, ev.id[0..8], .big) & std.math.maxInt(i64));
}

// The previous feed, kept across one rebuild so unchanged notes carry over
// without being re-parsed. Static rather than stack: three hundred cards of
// fixed buffers are far too big for a frame's stack.
var g_notes_scratch: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity;
// The names generation the current cards were parsed under (see
// `g_names_generation`).
var g_notes_names_generation: u64 = 0;

/// Reads kind:0 metadata for the feed's authors from the store and parses each
/// into the profile cache. The store keeps only the newest kind:0 per author, so
/// this always reflects the current metadata.
fn refreshProfiles(store: *nostr.store.Store) void {
    const kinds = [_]u16{0};
    var authors: [starter_pack.len + 1 + wanted_profiles_cap][32]u8 = undefined;
    var authors_len: usize = 0;
    for (starter_pack) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    if (activePubkey()) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    // Anyone a note mentioned, so their name resolves once it arrives.
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        authors[authors_len] = w.pubkey;
        authors_len += 1;
    }
    var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = profile_cap + wanted_profiles_cap }) catch return;
    defer result.deinit();
    for (result.events) |ev| {
        const p = upsertProfile(ev.pubkey) orelse continue;
        // The same event parses to the same fields; skip the JSON work.
        if (std.mem.eql(u8, &p.meta_id, &ev.id)) continue;
        const named_before = p.name_len > 0;
        const name_before = p.name_buf;
        parseMetadataInto(p, ev.content);
        p.meta_id = ev.id;
        if ((p.name_len > 0) != named_before or !std.mem.eql(u8, &p.name_buf, &name_before)) {
            g_names_generation +%= 1;
        }
    }
}

/// Fires avatar fetches for cached profiles that have a picture and an image
/// slot but no avatar yet, a few per tick to stay well inside the effect budget.
/// The response lands on `avatar_fetched`.
fn scanAvatarFetches(fx: *Effects) void {
    const per_tick = 8;
    var fired: usize = 0;
    for (&g_profiles, 0..) |*p, i| {
        if (!p.used or p.avatar_state != .idle or p.picture_len == 0 or p.image_id == 0) continue;

        var url_buf: [1024]u8 = undefined;
        const url = mediaUrl(&url_buf, p.picture(), avatar_target_px, .square);
        const n = @min(url.len, p.url_buf.len);
        @memcpy(p.url_buf[0..n], url[0..n]);
        p.url_len = @intCast(n);

        // Local-first: a cached avatar is registered before the first paint, so
        // faces arrive with the feed rather than seconds after it.
        if (loadCachedImage(fx, p.image_id, p.url(), avatar_target_px)) |_| {
            p.avatar_state = .loaded;
            continue;
        }
        if (fired >= per_tick) continue;
        p.avatar_state = .fetching;
        fx.fetch(.{
            .key = avatar_fetch_key_base + @as(u64, @intCast(i)),
            .url = p.url(),
            .on_response = Effects.responseMsg(.avatar_fetched),
        });
        fired += 1;
    }
}

/// Handles an avatar fetch response: registers the decoded image on success, or
/// retries a slot-starved rejection and gives up (initials) on anything else.
fn handleAvatarFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < avatar_fetch_key_base) return;
    const slot = response.key - avatar_fetch_key_base;
    if (slot >= g_profiles.len) return;
    const p = &g_profiles[@intCast(slot)];
    if (!p.used) return;

    // A rejection means every effect slot was busy: try again next tick.
    if (response.outcome == .rejected) {
        p.avatar_state = .idle;
        return;
    }
    // Anything but a clean, whole, OK image body falls back to initials.
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        p.avatar_state = .failed;
        return;
    }
    // Decode into this profile's fixed image id, downscaling if the platform
    // decoder will not take it as-is. Only a genuinely undecodable body falls
    // back to initials now.
    if (decodeAndRegister(fx, p.image_id, response.body, avatar_target_px)) |_| {
        p.avatar_state = .loaded;
        storeCachedImage(p.url(), response.body);
    } else {
        p.avatar_state = .failed;
    }
}

// --------------------------------------------------------------- image decode
//
// The canvas image registry decodes through the platform codec and refuses
// anything over 512x512, with no downscaler of its own. Most real avatars and
// nearly every feed photo are larger than that, so Plaza decodes and resizes
// them itself: the platform decoder is tried first (it knows every format the
// OS does, WebP and HEIC included), and stb takes over when it refuses.

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_load_gif_from_memory(buffer: [*]const u8, len: c_int, delays: *?[*]c_int, x: *c_int, y: *c_int, z: *c_int, comp: ?*c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbir_resize_uint8_linear(input_pixels: [*]const u8, input_w: c_int, input_h: c_int, input_stride_in_bytes: c_int, output_pixels: [*]u8, output_w: c_int, output_h: c_int, output_stride_in_bytes: c_int, pixel_layout: c_int) ?[*]u8;

/// `STBIR_RGBA`: four channels, alpha not premultiplied, which is what both stb
/// hands back and the registry wants.
const stbir_rgba: c_int = 4;

// The image cache: every image Plaza fetches is written to `$HOME/.plaza/media`
// under a hash of the URL it was fetched from (which encodes the requested
// size), and read back before the network is touched. This is what makes
// avatars and pictures local-first like the notes themselves: on every launch
// after the first they are on screen with the feed, not seconds later.

/// The cache file name for `url`: its SHA-256, hex encoded.
fn cacheName(out: *[64]u8, url: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hexdigits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0x0f];
    }
    return out[0..];
}

/// Opens (creating if needed) `$HOME/.plaza/media`.
fn mediaCacheDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza/media", .{home});
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Registers `url`'s image from the on-disk cache, if it is there. Reading a
/// handful of small files is fast enough to do inline, and it is what lets the
/// first painted frame already carry avatars.
fn loadCachedImage(fx: *Effects, id: u64, url: []const u8, max_dim: u32) ?DecodedSize {
    const io = g_io orelse return null;
    const environ = g_environ orelse return null;
    var dir = mediaCacheDir(io, environ) catch return null;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_bytes)) catch return null;
    defer gpa.free(bytes);
    return decodeAndRegister(fx, id, bytes, max_dim);
}

/// Writes a freshly fetched image into the cache. Best-effort: a failure here
/// only costs a re-download next launch.
fn storeCachedImage(url: []const u8, bytes: []const u8) void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = mediaCacheDir(io, environ) catch return;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    dir.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// The pixel size an image ended up registered at, so the view can lay it out
/// at its real aspect instead of stretching it into whatever box it is given.
const DecodedSize = struct { width: usize, height: usize };

/// Decodes `bytes` and registers the pixels under `id`, downscaling so the long
/// edge is at most `max_dim`. Returns the registered size, or null on failure.
fn decodeAndRegister(fx: *Effects, id: u64, bytes: []const u8, max_dim: u32) ?DecodedSize {
    // Fast path: let the platform decode and register directly. This succeeds
    // whenever the image already fits the registry's budget.
    if (fx.registerImageBytes(id, bytes)) |registered| {
        return .{ .width = registered.width, .height = registered.height };
    } else |_| {}

    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return null;
    defer stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    const src_w: usize = @intCast(w);
    const src_h: usize = @intCast(h);
    const longest = @max(src_w, src_h);
    if (longest <= max_dim) {
        // The platform refused it for some other reason; the decoded pixels
        // still fit, so register them as they are.
        fx.registerImage(id, src_w, src_h, pixels[0 .. src_w * src_h * 4]) catch return null;
        return .{ .width = src_w, .height = src_h };
    }

    const scale = @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(longest));
    const dst_w: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_w)) * scale)));
    const dst_h: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_h)) * scale)));

    const gpa = std.heap.page_allocator;
    const out = gpa.alloc(u8, dst_w * dst_h * 4) catch return null;
    defer gpa.free(out);
    if (stbir_resize_uint8_linear(pixels, w, h, 0, out.ptr, @intCast(dst_w), @intCast(dst_h), 0, stbir_rgba) == null) return null;
    fx.registerImage(id, dst_w, dst_h, out) catch return null;
    return .{ .width = dst_w, .height = dst_h };
}

// ---------------------------------------------------------------- feed media
//
// Feed images take the image ids the avatars do not, through a small LRU keyed
// by note. Only the top of the feed loads for now: that is what the budget
// holds and what is on screen at rest. Windowed visibility (load exactly what
// is in view, evict what leaves) arrives with the virtual list.

const MediaSlot = struct {
    used: bool = false,
    note_id: i64 = 0,
    image_id: u64 = 0,
    state: enum { idle, fetching, loaded, failed } = .idle,
    /// Tick counter at the last time this note was still wanted, for eviction.
    last_used: u64 = 0,
    /// The registered pixel size, so the card can lay the picture out at its
    /// own aspect rather than stretching it.
    width: usize = 0,
    height: usize = 0,
    /// The resolved URL this image is fetched from, which is also its cache key.
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,
    /// Every frame of an animated GIF, decoded once and owned by stb (freed on
    /// eviction). Null for a still picture.
    frames: ?[*]u8 = null,
    frame_count: u16 = 0,
    frame_index: u16 = 0,
    /// Milliseconds this GIF holds each frame, and how much of that has elapsed.
    frame_delay_ms: u32 = 100,
    elapsed_ms: u32 = 0,

    fn url(self: *const MediaSlot) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    fn animated(self: *const MediaSlot) bool {
        return self.frames != null and self.frame_count > 1;
    }
    /// Releases the decoded frames, if any. Called before a slot is reused.
    fn releaseFrames(self: *MediaSlot) void {
        if (self.frames) |px| stbi_image_free(px);
        self.frames = null;
        self.frame_count = 0;
        self.frame_index = 0;
    }
};

var g_media = [_]MediaSlot{.{}} ** max_media_images;
var g_media_clock: u64 = 0;

// The rows the windowed list last put on screen. Written by the view (which is
// where the runtime resolves the window) and read by the fetch pass in
// `update`, so the image budget follows the reader exactly.
var g_visible_first: usize = 0;
var g_visible_last: usize = 0;

// What shape each note's picture turned out to be, remembered per note id and
// OUTLIVING both the media slot and the note itself. A slot is evicted as soon
// as the note scrolls out of the window; without this the card would forget how
// tall its picture was, shrink, and shift the feed under the reader, then shift
// it back on the way up. Notes whose `imeta` declared a size never need it.
const aspect_memory_cap = 128;
const AspectEntry = struct { note_id: i64 = 0, aspect: f32 = 0 };
var g_aspects = [_]AspectEntry{.{}} ** aspect_memory_cap;
var g_aspect_next: usize = 0;

/// Records the shape of `note_id`'s picture.
fn rememberAspect(note_id: i64, width: usize, height: usize) void {
    if (width == 0 or height == 0) return;
    const aspect = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width));
    for (&g_aspects) |*entry| {
        if (entry.note_id == note_id) {
            entry.aspect = aspect;
            return;
        }
    }
    g_aspects[g_aspect_next] = .{ .note_id = note_id, .aspect = aspect };
    g_aspect_next = (g_aspect_next + 1) % aspect_memory_cap;
}

/// The remembered shape of `note_id`'s picture, if it has been seen.
fn recalledAspect(note_id: i64) ?f32 {
    for (&g_aspects) |entry| {
        if (entry.note_id == note_id and entry.aspect > 0) return entry.aspect;
    }
    return null;
}

/// Clears the media cache. For tests, which share the process globals.
pub fn resetMediaForTest() void {
    g_media = [_]MediaSlot{.{}} ** max_media_images;
    g_media_clock = 0;
}

/// The slot holding `note_id`'s image, if any.
fn mediaSlotFor(note_id: i64) ?*MediaSlot {
    for (&g_media) |*m| {
        if (m.used and m.note_id == note_id) return m;
    }
    return null;
}

/// The slot for `note_id`, claiming a free one or evicting the least recently
/// wanted. Never evicts a slot whose note is still on screen (touched this
/// pass), and never one with a fetch in flight: when more pictures are visible
/// than there are slots, the extras hold their reserved space rather than
/// stealing each other's slot back and forth, which decoded images on the UI
/// thread every pass and made a tall window feel heavy.
pub fn claimMediaSlotForTest(fx: *Effects, note_id: i64) ?*MediaSlot {
    return claimMediaSlot(fx, note_id);
}

pub fn touchMediaClockForTest() u64 {
    g_media_clock += 1;
    return g_media_clock;
}

fn claimMediaSlot(fx: *Effects, note_id: i64) ?*MediaSlot {
    if (mediaSlotFor(note_id)) |m| return m;
    for (&g_media, 0..) |*m, i| {
        if (!m.used) {
            m.* = .{ .used = true, .note_id = note_id, .image_id = media_image_id_base + i };
            return m;
        }
    }
    var victim: ?*MediaSlot = null;
    for (&g_media) |*m| {
        if (m.state == .fetching) continue;
        if (m.last_used == g_media_clock) continue; // still wanted on screen
        if (victim == null or m.last_used < victim.?.last_used) victim = m;
    }
    const v = victim orelse return null;
    const id = v.image_id;
    // Free the registry slot and any decoded frames before reusing the id.
    _ = fx.unregisterImage(id);
    v.releaseFrames();
    v.* = .{ .used = true, .note_id = note_id, .image_id = id };
    return v;
}

/// Decodes every frame of an animated GIF into `slot` and registers the first,
/// so the shared animation timer can cycle it. Returns false for a still image
/// (including a single-frame GIF), leaving the normal still path to handle it.
fn loadAnimatedGif(fx: *Effects, slot: *MediaSlot, bytes: []const u8) bool {
    if (bytes.len < 3 or !std.mem.eql(u8, bytes[0..3], "GIF")) return false;

    var delays: ?[*]c_int = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var count: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_gif_from_memory(bytes.ptr, @intCast(bytes.len), &delays, &w, &h, &count, &comp, 4) orelse return false;
    if (count <= 1 or w <= 0 or h <= 0) {
        stbi_image_free(pixels);
        return false;
    }

    const frame_w: usize = @intCast(w);
    const frame_h: usize = @intCast(h);
    const frame_bytes = frame_w * frame_h * 4;
    const frames: usize = @intCast(count);
    // stb decodes every frame up front, so a long or large GIF is the real
    // memory hazard rather than the per-frame cost. Refuse the extremes and let
    // the caller fall back to a still first frame.
    if (frame_bytes > max_registered_image_bytes or frames > max_gif_frames or frame_bytes * frames > max_gif_total_bytes) {
        stbi_image_free(pixels);
        return false;
    }

    fx.registerImage(slot.image_id, frame_w, frame_h, pixels[0..frame_bytes]) catch {
        stbi_image_free(pixels);
        return false;
    };

    slot.releaseFrames();
    slot.frames = pixels;
    slot.frame_count = @intCast(frames);
    slot.frame_index = 0;
    slot.elapsed_ms = 0;
    // GIF delays are centiseconds x10; anything implausibly fast gets the
    // browsers' customary floor.
    slot.frame_delay_ms = if (delays) |d| (if (d[0] >= 20) @intCast(d[0]) else 100) else 100;
    slot.width = frame_w;
    slot.height = frame_h;
    slot.state = .loaded;
    rememberAspect(slot.note_id, frame_w, frame_h);
    return true;
}

/// Registers a feed picture from the on-disk cache, animating it if it is a GIF.
/// Returns whether the slot is now loaded.
fn loadCachedMedia(fx: *Effects, slot: *MediaSlot, gif: bool) bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;
    var dir = mediaCacheDir(io, environ) catch return false;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_bytes)) catch return false;
    defer gpa.free(bytes);

    if (gif and loadAnimatedGif(fx, slot, bytes)) return true;
    if (decodeAndRegister(fx, slot.image_id, bytes, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        return true;
    }
    return false;
}

/// Advances the animated pictures currently in view, one shared timer for all of
/// them (a timer each would exhaust the 16-slot timer table). Only a couple play
/// at once: the rest hold their first frame until they scroll into that budget.
fn advanceAnimations(fx: *Effects, model: *const Model) void {
    const window = model.visibleRange();
    var playing: usize = 0;
    for (&g_media) |*slot| {
        if (!slot.used or !slot.animated() or slot.state != .loaded) continue;
        // In view? The note has to still be one of the ones on screen.
        var visible = false;
        var index = window.first;
        while (index <= window.last and index < model.notes_len) : (index += 1) {
            if (model.notes[index].id == slot.note_id) {
                visible = true;
                break;
            }
        }
        if (!visible) continue;
        if (playing >= max_playing_gifs) break;
        playing += 1;

        slot.elapsed_ms += animation_interval_ms;
        if (slot.elapsed_ms < slot.frame_delay_ms) continue;
        slot.elapsed_ms = 0;
        slot.frame_index = (slot.frame_index + 1) % slot.frame_count;

        const frames = slot.frames orelse continue;
        const frame_bytes = slot.width * slot.height * 4;
        const offset = @as(usize, slot.frame_index) * frame_bytes;
        // Re-registering the same id swaps the pixels everywhere it is drawn.
        fx.registerImage(slot.image_id, slot.width, slot.height, frames[offset..][0..frame_bytes]) catch {};
    }
}

/// Loads the pictures for the notes around the viewport: the cached ones
/// straight from disk, the rest over the network a few per tick. Notes outside
/// the window keep their slot only until something on screen needs it.
fn scanMediaFetches(fx: *Effects, model: *const Model) void {
    const per_tick = 6;
    var fired: usize = 0;
    g_media_clock += 1;

    const window = model.visibleRange();

    // First mark every slot whose note is on screen as wanted, so the claim
    // pass below can only ever evict pictures that have scrolled away. Without
    // this, a viewport showing more pictures than there are slots would evict
    // a slot needed later in this very pass, endlessly.
    var touch = window.first;
    while (touch <= window.last and touch < model.notes_len) : (touch += 1) {
        if (mediaSlotFor(model.notes[touch].id)) |m| m.last_used = g_media_clock;
    }

    var index = window.first;
    while (index <= window.last and index < model.notes_len) : (index += 1) {
        const note = &model.notes[index];
        if (!note.hasImage()) continue;
        const slot = claimMediaSlot(fx, note.id) orelse continue;
        slot.last_used = g_media_clock;
        if (slot.state != .idle) continue;

        var url_buf: [1024]u8 = undefined;
        const gif = isGifUrl(note.imageUrl());
        const url = if (gif)
            mediaUrl(&url_buf, note.imageUrl(), gif_target_px, .animation)
        else
            mediaUrl(&url_buf, note.imageUrl(), media_target_px, .inside);
        const n = @min(url.len, slot.url_buf.len);
        @memcpy(slot.url_buf[0..n], url[0..n]);
        slot.url_len = @intCast(n);

        // Local-first: a picture we already have appears with the note, with no
        // network round-trip at all.
        if (loadCachedMedia(fx, slot, gif)) continue;
        if (fired >= per_tick) continue;
        slot.state = .fetching;
        fx.fetch(.{
            .key = media_fetch_key_base + (slot.image_id - media_image_id_base),
            .url = slot.url(),
            .on_response = Effects.responseMsg(.media_fetched),
        });
        fired += 1;
    }
}

/// Handles a feed-image fetch response, mirroring the avatar path.
fn handleMediaFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < media_fetch_key_base) return;
    const index = response.key - media_fetch_key_base;
    if (index >= g_media.len) return;
    const slot = &g_media[@intCast(index)];
    if (!slot.used) return;

    if (response.outcome == .rejected) {
        slot.state = .idle;
        return;
    }
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        slot.state = .failed;
        return;
    }
    // An animated GIF keeps all its frames; anything else (including a GIF with
    // only one frame) takes the still path.
    if (loadAnimatedGif(fx, slot, response.body)) {
        storeCachedImage(slot.url(), response.body);
        return;
    }
    if (decodeAndRegister(fx, slot.image_id, response.body, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        // Keep it for next launch: the feed should come back with its pictures.
        storeCachedImage(slot.url(), response.body);
    } else {
        slot.state = .failed;
    }
}

// A pressed link is handed to the OS opener. The URL comes from note content,
// which is untrusted, so it is validated before it ever becomes an argument: it
// must be a plain http(s) URL with no whitespace or control bytes. There is no
// shell involved (argv is passed as a vector), and a leading scheme means the
// opener can never read it as a flag or a local path.
var g_open_url_buf: [1024]u8 = undefined;

/// Whether `url` is safe to hand to the system opener.
pub fn isSafeExternalUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    if (url.len > g_open_url_buf.len) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Opens `url` in the user's browser, if it passes validation.
fn openExternally(fx: *Effects, url: []const u8) void {
    if (!isSafeExternalUrl(url)) return;
    // The link slice lives in the view arena, so copy it before the effect runs.
    @memcpy(g_open_url_buf[0..url.len], url);
    const owned = g_open_url_buf[0..url.len];
    fx.spawn(.{ .key = open_url_key, .argv = &.{ "/usr/bin/open", owned }, .output = .collect });
}

/// Lets everything that failed to load try again, after the media proxy changed.
fn retryFailedImages() void {
    for (&g_profiles) |*p| {
        if (p.used and p.avatar_state == .failed) p.avatar_state = .idle;
    }
    for (&g_media) |*m| {
        if (m.used and m.state == .failed) m.state = .idle;
    }
}

/// Builds a `Note` view-model from a stored event.
pub fn noteFrom(ev: nostr.event.Event, now_s: i64) Note {
    var note = Note{
        .created_at = ev.created_at,
        .pubkey = ev.pubkey,
        .id = noteIdOf(ev),
    };

    // Avatar initials fallback: the first pubkey byte as two hex digits, stable
    // and distinct per author, shown until an avatar image loads.
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[ev.pubkey[0] >> 4], hexdigits[ev.pubkey[0] & 0x0f] };

    setAuthor(&note, ev.pubkey);

    // An image link becomes a picture, so lift it out of the text and omit it
    // from the rendered content rather than showing a bare URL beside it.
    var image_url: []const u8 = "";
    if (firstImageUrl(ev.content)) |url| {
        if (url.len <= note.image_url_buf.len) {
            @memcpy(note.image_url_buf[0..url.len], url);
            note.image_url_len = @intCast(url.len);
            image_url = note.imageUrl();
            note.image_aspect = imetaAspect(ev.tags, url);
        }
    }

    // Content: `nostr:` mentions rewritten to @name (or a short @npub), copied
    // whole-codepoint so a split multi-byte sequence never reaches the shaper.
    note.content_len = @intCast(renderContent(&note.content_buf, ev.content, image_url));

    note.setTime(now_s);
    return note;
}

/// The aspect (height over width) the note's own NIP-92 `imeta` tag declares for
/// `url`, or 0 when it says nothing. An `imeta` tag reads
/// `["imeta", "url https://…", "dim 882x302", …]`; dimensions are sometimes
/// written as floats, so both forms parse.
pub fn imetaAspect(tags: []const nostr.event.Tag, url: []const u8) f32 {
    for (tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "imeta")) continue;
        var matches_url = false;
        var aspect: f32 = 0;
        for (tag[1..]) |field| {
            if (std.mem.startsWith(u8, field, "url ")) {
                matches_url = std.mem.eql(u8, std.mem.trim(u8, field[4..], " "), url);
            } else if (std.mem.startsWith(u8, field, "dim ")) {
                const dim = std.mem.trim(u8, field[4..], " ");
                const x = std.mem.indexOfScalar(u8, dim, 'x') orelse continue;
                const w = std.fmt.parseFloat(f32, dim[0..x]) catch continue;
                const h = std.fmt.parseFloat(f32, dim[x + 1 ..]) catch continue;
                if (w > 0 and h > 0) aspect = h / w;
            }
        }
        if (matches_url and aspect > 0) return aspect;
    }
    return 0;
}

/// The first image URL in `content`, or null. Recognised by extension, which is
/// what Nostr media hosts serve; a link without one stays ordinary text.
pub fn firstImageUrl(content: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] != 'h') continue;
        if (!std.mem.startsWith(u8, content[i..], "http://") and !std.mem.startsWith(u8, content[i..], "https://")) continue;
        // The URL runs to the first whitespace.
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        const url = content[i..j];
        // Ignore a trailing bare query string when matching the extension.
        const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..path_end];
        for (exts) |ext| {
            if (std.ascii.endsWithIgnoreCase(path, ext)) return url;
        }
        i = j;
    }
    return null;
}

/// Copies note content into `dst`, rewriting NIP-27 `nostr:npub…`/`nostr:nprofile…`
/// mentions into a readable `@name` (from the profile cache) or a short `@npub`,
/// and dropping `omit` (the URL rendered as a picture) wherever it appears.
/// Plain text is copied one whole codepoint at a time and stops at `dst`'s
/// capacity, so the buffer never ends mid-sequence. Returns the byte length.
pub fn renderContent(dst: []u8, src: []const u8, omit: []const u8) usize {
    // Mention decoding needs an allocator for bech32 scratch; a stack buffer
    // covers it without touching the heap for every note parsed. A pathological
    // mention that will not fit simply stays as its raw token.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const arena = fba.allocator();

    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (omit.len > 0 and std.mem.startsWith(u8, src[i..], omit)) {
            i += omit.len;
            continue;
        }
        if (parseMentionAt(arena, src, i)) |m| {
            var label_buf: [80]u8 = undefined;
            const label = mentionLabel(m.pubkey, &label_buf);
            if (out + label.len > dst.len) break;
            @memcpy(dst[out..][0..label.len], label);
            out += label.len;
            i = m.end;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        const take = @min(seq_len, src.len - i);
        if (out + take > dst.len) break;
        @memcpy(dst[out..][0..take], src[i..][0..take]);
        out += take;
        i += take;
    }
    // Lifting a URL out can leave whitespace stranded at either edge.
    const trimmed = std.mem.trim(u8, dst[0..out], " \t\r\n");
    if (trimmed.len != out) {
        std.mem.copyForwards(u8, dst[0..trimmed.len], trimmed);
        return trimmed.len;
    }
    return out;
}

/// A parsed `nostr:` mention at `src[i]`: the byte just past its token, and the
/// referenced pubkey. Null when `src[i]` is not the start of one.
fn parseMentionAt(arena: std.mem.Allocator, src: []const u8, i: usize) ?struct { end: usize, pubkey: [32]u8 } {
    const prefix = "nostr:";
    var body_start = i;
    if (std.mem.startsWith(u8, src[i..], prefix)) {
        body_start = i + prefix.len;
    } else {
        // A bare npub/nprofile counts too (plenty of clients write them without
        // the scheme), but only at a word boundary, so one inside a URL or a
        // longer token is left alone.
        const bare = std.mem.startsWith(u8, src[i..], "npub1") or std.mem.startsWith(u8, src[i..], "nprofile1");
        if (!bare) return null;
        if (i > 0 and (isBech32Char(src[i - 1]) or src[i - 1] == '/' or src[i - 1] == ':')) return null;
    }
    const rest = src[body_start..];
    var j: usize = 0;
    while (j < rest.len and isBech32Char(rest[j])) j += 1;
    if (j == 0) return null;
    const token = rest[0..j];
    const end = body_start + j;

    if (std.mem.startsWith(u8, token, "npub1")) {
        const pk = nostr.nip19.decodeNpub(arena, token) catch return null;
        return .{ .end = end, .pubkey = pk };
    }
    if (std.mem.startsWith(u8, token, "nprofile1")) {
        const pp = nostr.nip19.decodeNprofile(arena, token) catch return null;
        return .{ .end = end, .pubkey = pp.pubkey };
    }
    return null;
}

/// Writes `@` + the cached display name (or a short npub) for `pubkey` into
/// `buf`, returning the written slice. `buf` should be at least 80 bytes.
fn mentionLabel(pubkey: [32]u8, buf: []u8) []const u8 {
    buf[0] = '@';
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) {
            const n = @min(p.name_len, buf.len - 1);
            @memcpy(buf[1..][0..n], p.name_buf[0..n]);
            return buf[0 .. 1 + n];
        }
    }
    // No name for this one: ask for it, so the next rebuild can show it.
    wantProfile(pubkey);
    const npub = abbreviateNpub(buf[1..], pubkey);
    return buf[0 .. 1 + npub.len];
}

/// Whether `c` is a bech32 data character (lowercase letter or digit), the run
/// that follows a `nostr:` prefix.
fn isBech32Char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
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
    /// Open the compose sheet (a guest is routed to the join screen instead).
    open_compose,
    /// Dismiss the compose sheet.
    close_compose,
    /// Open the first-intent join sheet (create / bring a key / use a signer).
    open_join,
    /// Dismiss the join sheet; a remembered intent is forgotten with it.
    close_join,
    /// The sheet's primary: mint a local identity and replay the intent.
    join_create,
    /// The sheet's other paths: the join screen's field takes an nsec or a
    /// bunker link. The remembered intent survives the trip.
    join_bring_key,
    /// Leave the join screen back to the feed; reading never needs an identity.
    keep_browsing,
    /// Hide the guest strip for this session.
    dismiss_guest_strip,
    /// A text edit in the name beat's field.
    name_edit: canvas.TextInputEvent,
    /// Publish the chosen name as the account's kind:0 and move on.
    name_save,
    /// Skip the name beat; the account stays nameless for now.
    name_skip,
    /// From the backup nudge: open Settings at the backup card.
    backup_now,
    /// Dismiss the backup nudge for this session.
    backup_later,
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
    /// The signer daemon exited (logged; the watchdog and respawn are later).
    helper_exited: native_sdk.EffectExit,
    /// The signer daemon's /pubkey health-check answered.
    helper_pubkey: native_sdk.EffectResponse,
    /// A /setup (create) answered: adopt the new helper identity.
    helper_setup: native_sdk.EffectResponse,
    /// A /sign answered: ingest and publish the signed event.
    helper_signed: native_sdk.EffectResponse,
    /// An avatar fetch finished: register the image or fall back to initials.
    avatar_fetched: native_sdk.EffectResponse,
    /// A media fetch finished: decode, downscale if needed, and register it.
    media_fetched: native_sdk.EffectResponse,
    /// A text edit in the Settings media-proxy field.
    proxy_edit: canvas.TextInputEvent,
    /// Save the media-proxy setting.
    proxy_save,
    /// The feed scrolled: remember where, so images load around the viewport.
    feed_scrolled: canvas.ScrollState,
    /// A link in a note was pressed: open it in the browser.
    open_url: []const u8,
    /// The animation timer fired: advance any playing GIFs.
    animate: native_sdk.EffectTimer,
    /// The profile-fetch timer: re-ask for wanted metadata, decoupled from the
    /// view refresh (see `profile_timer_key`).
    profiles: native_sdk.EffectTimer,
    /// Expand a note's picture to fill the window.
    expand_image: i64,
    /// Dismiss the expanded picture.
    close_image,
    /// The reader reached the end of the feed: ask the store for another page.
    load_older,

    // Dispatched from Zig rather than markup: the effect results, and every
    // action on the feed screen (a Zig view now, not a markup file).
    pub const view_unbound = .{ "tick", "animate", "profiles", "avatar_fetched", "media_fetched", "draft_edit", "post", "open_compose", "close_compose", "open_join", "close_join", "join_create", "join_bring_key", "dismiss_guest_strip", "name_edit", "name_save", "name_skip", "backup_now", "backup_later", "helper_exited", "helper_pubkey", "helper_setup", "helper_signed", "open_settings", "feed_scrolled", "open_url", "expand_image", "close_image", "load_older" };
};

// ---------------------------------------------------------------- app + view

pub const AppUi = canvas.Ui(Msg);

// The two static screens stay declarative markup, compiled into the view at
// build time (so their bindings are still checked, now by the compiler). The
// feed is hand-written below: an inline image needs a runtime `ImageId`
// reference, which the markup grammar deliberately does not carry, so a media
// feed has to be a Zig view.
const OnboardingView = canvas.CompiledMarkupView(Model, Msg, @embedFile("onboarding.native"));
const SettingsView = canvas.CompiledMarkupView(Model, Msg, @embedFile("settings.native"));

/// The root view: one screen at a time, chosen by the stage, with an expanded
/// picture layered over it when one is open.
pub fn appView(ui: *AppUi, model: *const Model) AppUi.Node {
    const base = switch (model.stage) {
        .onboarding => OnboardingView.build(ui, model),
        .settings => SettingsView.build(ui, model),
        .ready => feedView(ui, model),
    };
    if (model.expanded_note) |note_id| {
        if (model.noteById(note_id)) |note| {
            // Layered OVER the feed rather than replacing it, so the scroll
            // region stays mounted and holds its offset. Swapping the tree out
            // unmounts it, and closing would drop the reader back at the top.
            return ui.stack(.{ .grow = 1 }, .{ base, imageViewer(ui, note) });
        }
    }
    if (model.stage == .ready and model.joining) {
        return ui.stack(.{ .grow = 1 }, .{ base, joinSheet(ui, model) });
    }
    if (model.stage == .ready and model.naming) {
        return ui.stack(.{ .grow = 1 }, .{ base, nameSheet(ui, model) });
    }
    if (model.stage == .ready and model.composing) {
        return ui.stack(.{ .grow = 1 }, .{ base, composeSheet(ui, model) });
    }
    if (model.stage == .ready and model.toast_until != 0) {
        return ui.stack(.{ .grow = 1 }, .{ base, toastOverlay(ui, model) });
    }
    return base;
}

/// The name beat: one optional ask after creating an identity, so the account
/// is not blank. Fully skippable; the remembered intent replays either way.
fn nameSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .name_skip,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "Name" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            ui.column(.{ .width = 372, .gap = 12, .padding = 20, .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 } }, .{
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = "Want a name on it?", .weight = .bold, .scale = 1.3 }},
                ),
                ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Shown with your notes. Change it any time."),
                ui.el(.textarea, .{
                    .text = model.name_draft(),
                    .placeholder = "A name people will see",
                    .on_input = AppUi.inputMsg(.name_edit),
                    .on_submit = .name_save,
                    .height = 44,
                }, .{}),
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .name_skip }, "Skip"),
                    ui.spacer(1),
                    ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.name_empty(), .on_press = .name_save }, "Save"),
                }),
            }),
        }),
    });
}

/// A small confirming toast, bottom center, retired by the tick.
fn toastOverlay(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .padding = 24 }, .{
        ui.row(.{ .padding = 10, .style = .{ .background = p.surface_toast, .border = p.border_modal, .radius = 10, .stroke_width = 1 } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_body } }, model.toast_text()),
        }),
    });
}

/// The first-intent sheet: the join ladder over the dimmed feed. Three ways in,
/// most confident first, and always the way back to reading. When the guest
/// reached for the composer, the sheet says the note is waiting.
fn joinSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_join,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "Join" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            ui.column(.{ .width = 372, .gap = 12, .padding = 20, .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 } }, .{
                if (model.pending_compose)
                    ui.text(.{ .size = .sm, .style = .{ .foreground = p.status_warning } }, "Your note is waiting.")
                else
                    ui.spacer(0),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = "How do you want to join?", .weight = .bold, .scale = 1.3 }},
                ),
                ui.text(
                    .{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } },
                    "Everything here is signed with a key of your own, not an account someone holds for you.",
                ),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = "NEW HERE", .monospace = true, .scale = 0.85 }},
                ),
                ui.button(.{ .variant = .primary, .on_press = .join_create }, "Create your identity"),
                ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Ready in seconds. Nothing to write down."),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = "ALREADY ON NOSTR", .monospace = true, .scale = 0.85 }},
                ),
                ui.button(.{ .on_press = .join_bring_key }, "Bring your key"),
                ui.button(.{ .on_press = .join_bring_key }, "Use your own signer"),
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_join }, "Keep browsing"),
                    ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_faint_alt } }, "Reading never needs an identity."),
                }),
            }),
        }),
    });
}

/// The compose sheet: a modal over the feed with the note field and the actions.
/// On demand from the titlebar's "New note", so the feed is not sharing the
/// window with a permanent composer. Escape or a click outside closes it.
fn composeSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_compose,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "New note" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            ui.column(.{ .width = 520, .gap = 10, .padding = 16, .style = .{ .background = theme.palette.surface_modal, .border = theme.palette.border_modal, .radius = 14, .stroke_width = 1 } }, .{
                ui.el(.textarea, .{
                    .text = model.draft(),
                    .placeholder = "Share something with the network…",
                    .on_input = AppUi.inputMsg(.draft_edit),
                    .on_submit = .post,
                    .height = 140,
                }, .{}),
                ui.row(.{ .cross = .center, .gap = 8 }, .{
                    ui.text(.{ .size = .sm, .style = .{ .foreground = theme.palette.text_muted } }, model.identity(ui.arena)),
                    ui.spacer(1),
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_compose }, "Cancel"),
                    ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.draft_empty(), .on_press = .post }, "Post"),
                }),
            }),
        }),
    });
}

/// The expanded picture, filling the window over the feed. The registry decodes
/// at most 512 pixels on a side, so rather than upscale a small copy into a
/// blur, this shows it as large as it honestly goes and offers the
/// full-resolution original in the browser. Pressing the backdrop closes it,
/// which also stops presses reaching the feed underneath.
fn imageViewer(ui: *AppUi, note: *const Note) AppUi.Node {
    const image_id = note.media_id();
    // A dialog, not a bare column: modal surfaces paint their own opaque
    // surface and always claim their own input, so the feed underneath neither
    // shows through nor scrolls, and Escape or a click outside closes it.
    // Stacking kinds layer their children, so the contents go in a column.
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_image,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Expanded image" },
    }, .{
        ui.column(.{ .grow = 1, .gap = 12, .cross = .stretch }, .{
            // The picture needs a definite box: an image is a leaf with no
            // intrinsic size, so it draws nothing unless a stretching parent
            // hands it one (a centred column collapses its width to zero).
            ui.row(.{ .grow = 1, .cross = .stretch }, .{
                if (image_id != 0) blk: {
                    var node = ui.image(.{
                        .image = image_id,
                        .grow = 1,
                        .semantics = .{ .label = "Expanded image" },
                    });
                    node.widget.image_fit = .contain;
                    break :blk node;
                } else ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Still loading…"),
            }),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_image }, "Close"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg{ .open_url = note.imageUrl() } }, "Open original"),
            }),
        }),
    });
}

/// The one options value both `virtualWindow` and `virtualList` read. The MODEL
/// owns the notes; the runtime only ever sees how many there are, an estimate
/// per row, and the window it asked for.
fn feedOptions(model: *const Model) AppUi.VirtualListOptions {
    return .{
        .id = "feed",
        .item_count = model.notes_len,
        // Variable-extent mode: cards are as tall as their wrapped text and
        // their picture. The estimate prices unbuilt rows; the engine patches in
        // measured heights as rows mount, and anchors the viewport so those
        // corrections never move what the reader is looking at.
        .item_extent = 0,
        .extent_estimate = noteExtentEstimate,
        .extent_context = model,
        .gap = 8,
        .padding = 12,
        .overscan = 3,
        .grow = 1,
        // Only bare builds (tests, previews) read this: under the app the
        // runtime supplies the real viewport. Without it a test resolves an
        // empty window and renders no rows at all.
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Feed" },
        .on_reach_end = .load_older,
    };
}

/// A cheap height estimate for the note at `index`, from model facts only
/// (never layout): the card's chrome, its wrapped lines, and its picture.
fn noteExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    // Re-derived for the redesign row (B1): 14px top and bottom padding, the
    // identity line, the body gaps, the engagement row, and the hairline, with
    // the body wrapping in the ~540px text column beside the 40px avatar.
    const chrome: f32 = 74;
    const line_height: f32 = 22;
    const chars_per_line: f32 = 70;

    const model: *const Model = @ptrCast(@alignCast(context orelse return chrome + line_height));
    const i: usize = @intCast(index);
    if (i >= model.notes_len) return chrome + line_height;
    const note = &model.notes[i];

    const chars: f32 = @floatFromInt(note.content_len);
    const lines = @max(1, @ceil(chars / chars_per_line));
    var extent = chrome + lines * line_height;
    if (note.hasImage()) extent += pictureHeight(note) + 4;
    return extent;
}

/// The feed screen: header, the note list, the composer, and a status bar.
fn feedView(ui: *AppUi, model: *const Model) AppUi.Node {
    // The data-window seam: the runtime resolves scroll offset and viewport
    // into a visible index range, and only those rows are built. A feed of any
    // length then costs what the handful on screen costs.
    const options = feedOptions(model);
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(AppUi.Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (rows, 0..) |*row, offset| row.* = noteCard(ui, &model.notes[window.start_index + offset]);

    // Exactly which rows are on screen, which is what decides where the image
    // budget goes. Recorded here because the runtime resolves it during the
    // build, while the fetch pass runs later, in `update`.
    g_visible_first = window.first_visible_index;
    g_visible_last = window.last_visible_index;

    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        titleBar(ui),
        if (model.show_guest_strip()) guestStrip(ui) else ui.spacer(0),
        scopeHeader(ui, model),
        if (model.notes_len == 0)
            ui.column(.{ .gap = 12, .main = .center, .cross = .center, .grow = 1, .padding = 24 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.empty_text()),
            })
        else
            // The list owns its scroll state, keyed by the id in `feedOptions`,
            // so the offset survives every rebuild (and the image viewer
            // opening over it) without the model mirroring it.
            ui.virtualList(options, window, .{rows}),
        if (model.backup_nudge) backupNudge(ui) else ui.spacer(0),
        statusBar(ui, model),
    });
}

/// The backup nudge: calm, dismissible, the stakes stated plainly. Rises once,
/// after the first local-key post of a session.
fn backupNudge(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .style = .{ .background = p.surface_subbar } }, .{
        ui.column(.{ .height = 1, .style = .{ .background = p.divider_chrome } }, .{}),
        ui.row(.{ .cross = .center, .gap = 10, .padding = 10 }, .{
            ui.text(
                .{ .size = .sm, .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.",
            ),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .backup_now }, "Back up"),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .backup_later }, "Not now"),
        }),
    });
}

/// The chromeless titlebar: the mark and wordmark on the left, then the compose
/// and settings actions. One bar, so the feed fills the rest of the window.
fn titleBar(ui: *AppUi) AppUi.Node {
    return ui.column(.{}, .{
        ui.row(.{ .height = 48, .cross = .center, .gap = 10, .padding = 14 }, .{
            ui.appIcon(.{ .width = 20, .height = 20, .style_tokens = .{ .foreground = .text } }, "mark"),
            ui.paragraph(
                .{ .style = .{ .foreground = theme.palette.text_primary } },
                &.{.{ .text = "Plaza", .weight = .bold }},
            ),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .open_compose }, "New note"),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .open_settings }, "Settings"),
        }),
        ui.column(.{ .height = 1, .style = .{ .background = theme.palette.divider_chrome } }, .{}),
    });
}

/// The guest join strip: one quiet, dismissible line under the titlebar. It
/// invites, never blocks; reading is free forever and every path in stays
/// reachable after dismissal (the gated verbs, the status bar's Guest chip).
fn guestStrip(ui: *AppUi) AppUi.Node {
    return ui.column(.{ .style = .{ .background = theme.palette.surface_subbar } }, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 10 }, .{
            ui.text(
                .{ .size = .sm, .wrap = true, .grow = 1, .style = .{ .foreground = theme.palette.text_muted_alt } },
                "Browsing as a guest. Reading is yours forever. Join in when something moves you.",
            ),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .open_join }, "Create identity"),
            ui.button(.{ .size = .sm, .on_press = .open_join }, "Sign in"),
            // An icon press, not a text button: the built-in x glyph (the
            // U+2715 codepoint is outside Geist's coverage, rendered tofu).
            ui.el(.list_item, .{
                .on_press = .dismiss_guest_strip,
                .padding = 6,
                .style = .{ .quiet_hover = true },
                .semantics = .{ .label = "Dismiss" },
            }, .{
                ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = theme.palette.text_faint_alt } }, "x"),
            }),
        }),
        ui.column(.{ .height = 1, .style = .{ .background = theme.palette.divider_chrome } }, .{}),
    });
}

/// The feed's scope line: which feed this is (the starter pack) and how wide it
/// reaches. A property of the feed, not a destination to choose between.
fn scopeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 8, .padding = 12 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = theme.palette.text_primary } },
                &.{.{ .text = "Starter pack", .weight = .bold }},
            ),
            ui.spacer(1),
            // Geist Mono: the metadata voice, via a monospace span.
            ui.paragraph(
                .{ .style = .{ .foreground = theme.palette.text_faint_alt } },
                &.{.{ .text = model.scope_voices(ui.arena), .monospace = true }},
            ),
        }),
        ui.column(.{ .height = 1, .style = .{ .background = theme.palette.divider_feedrow } }, .{}),
    });
}

/// The status bar: the caught-up line on the left (there is no spinner, the feed
/// renders from disk), relay health on the right after an online dot.
fn statusBar(ui: *AppUi, model: *const Model) AppUi.Node {
    const dot_color = if (model.relays_online()) theme.palette.status_success else theme.palette.text_faint_alt;
    return ui.column(.{}, .{
        ui.column(.{ .height = 1, .style = .{ .background = theme.palette.divider_chrome } }, .{}),
        ui.row(.{ .height = 30, .cross = .center, .gap = 6, .padding = 10 }, .{
            ui.text(.{ .style = .{ .foreground = theme.palette.text_muted } }, model.caught_up(ui.arena)),
            ui.spacer(1),
            ui.column(.{ .width = 6, .height = 6, .style = .{ .background = dot_color, .radius = 3 } }, .{}),
            ui.text(.{ .style = .{ .foreground = theme.palette.text_muted } }, model.relay_health(ui.arena)),
            if (model.is_guest())
                ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .open_join }, "Guest")
            else
                ui.spacer(0),
        }),
    });
}

/// One note: avatar, author line, content, and any inline image. Keyed by the
/// note id so the list diff holds scroll position across reconciles. This is
/// the per-row builder the windowed list will call in the milestone ahead.
/// The warm avatar tint for an author, chosen deterministically from the
/// pubkey so a face keeps the same color across sessions. Neutral graphite is
/// the last entry and the natural fallback for an all-zero key.
fn avatarTint(pubkey: [32]u8) theme.palette.Tint {
    const key = @as(usize, pubkey[0]) +% pubkey[15] +% pubkey[31];
    return theme.palette.avatar_tints[key % theme.palette.avatar_tints.len];
}

/// The 40px feed avatar: the fetched picture clipped to the circle when it has
/// loaded, else the author's initials on their warm tint.
fn noteAvatar(ui: *AppUi, note: *const Note) AppUi.Node {
    const tint = avatarTint(note.pubkey);
    return ui.avatar(.{
        .image = note.avatar_id(),
        .width = 40,
        .height = 40,
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
    }, note.initials());
}

/// The engagement row: reply, repost, like, zap, in that fixed order, as muted
/// action glyphs. The counts are backend data the feed does not carry yet (the
/// app ingests only kinds 0 and 1), so the row ships with actionable icons and
/// no numbers, and the numbers arrive when the aggregation pipeline lands.
fn engagementRow(ui: *AppUi) AppUi.Node {
    const glyph = AppUi.ElementOptions{ .width = 15, .height = 15, .style_tokens = .{ .foreground = .text_muted } };
    return ui.row(.{ .gap = 30, .cross = .center, .opacity = 0.75 }, .{
        ui.appIcon(glyph, "reply"),
        ui.icon(glyph, "repeat"),
        ui.appIcon(glyph, "like"),
        ui.appIcon(glyph, "zap"),
    });
}

/// One feed note: a bare row on the window, no card. Avatar column, then an
/// identity line (name, and the time hung to the right), the body, any image,
/// and the engagement row. The content is a fixed reading column centered in
/// the window, with a hairline under each row as the only separation. Keyed by
/// the note id so the list diff holds scroll position across reconciles.
fn noteCard(ui: *AppUi, note: *const Note) AppUi.Node {
    var node = ui.row(.{ .main = .center }, .{
        ui.column(.{ .width = feed_column_width }, .{
            ui.row(.{ .gap = 12, .cross = .start, .padding = 14 }, .{
                noteAvatar(ui, note),
                ui.column(.{ .gap = 5, .grow = 1 }, .{
                    ui.row(.{ .gap = 6, .cross = .center }, .{
                        ui.paragraph(
                            .{ .grow = 1, .style = .{ .foreground = theme.palette.text_primary } },
                            &.{.{ .text = note.author(), .weight = .bold }},
                        ),
                        ui.text(.{ .style = .{ .foreground = theme.palette.text_faint_alt } }, note.time()),
                    }),
                    ui.paragraph(
                        .{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = theme.palette.text_body } },
                        contentSpans(ui, note.content()),
                    ),
                    // The picture. The space is reserved at the picture's own
                    // shape whether or not it has loaded, so the feed never
                    // shifts as images arrive.
                    if (note.hasImage()) notePicture(ui, note) else ui.spacer(0),
                    engagementRow(ui),
                }),
            }),
            // The only separation between rows: a hairline, so a real border
            // can later mean something (a quote, a reply).
            ui.column(.{ .height = 1, .style = .{ .background = theme.palette.divider_feedrow } }, .{}),
        }),
    });
    // The note id is masked non-negative at build time, so this cast is safe.
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// Splits rendered note text into styled runs so a note reads like a note: web
/// links are accented, underlined, and pressable, and `@mentions` are accented.
/// Every span's text is a subslice of the note's own content, so nothing is
/// copied. A paragraph holds at most 32 runs, so a link-heavy note keeps its
/// tail as one plain run rather than losing it.
pub fn contentSpans(ui: *AppUi, text: []const u8) []const canvas.TextSpan {
    const max_spans = 32;
    if (text.len == 0) return &.{};
    const spans = ui.arena.alloc(canvas.TextSpan, max_spans) catch return &.{};

    var n: usize = 0;
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < text.len) {
        const is_url = std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://");
        const is_mention = text[i] == '@' and i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1]);
        if (!is_url and !is_mention) {
            i += 1;
            continue;
        }
        // Two slots for this run plus the trailing plain run.
        if (n + 3 > max_spans) break;
        if (i > plain_start) {
            spans[n] = .{ .text = text[plain_start..i] };
            n += 1;
        }
        var j = i;
        while (j < text.len and !std.ascii.isWhitespace(text[j])) j += 1;
        const run = text[i..j];
        spans[n] = if (is_url)
            .{ .text = run, .color = .accent, .underline = true, .link = run }
        else
            .{ .text = run, .color = .accent };
        n += 1;
        i = j;
        plain_start = j;
    }
    if (plain_start < text.len and n < max_spans) {
        spans[n] = .{ .text = text[plain_start..] };
        n += 1;
    }
    return spans[0..n];
}

/// The height a note's picture occupies, whether or not it has loaded. Taken
/// from the note's declared `imeta` shape, else the shape it turned out to be
/// last time it was decoded, else a gentle default. Clamped so one very tall
/// image cannot take over the feed.
pub fn pictureHeight(note: *const Note) f32 {
    const nominal_width: f32 = 300;
    const default_aspect: f32 = 0.66;
    const aspect = if (note.image_aspect > 0)
        note.image_aspect
    else
        recalledAspect(note.id) orelse default_aspect;
    return std.math.clamp(nominal_width * aspect, 80, 320);
}

/// A note's picture: the image once registered, or a placeholder holding the
/// exact same space while it loads. Drawn with `contain` at its own aspect, so
/// it is never stretched and stays undistorted as the window resizes. Pressing
/// it opens the viewer.
fn notePicture(ui: *AppUi, note: *const Note) AppUi.Node {
    const height = pictureHeight(note);
    const image_id = note.media_id();
    if (image_id == 0) {
        // Reserved space, not an empty frame: same height the picture will take.
        return ui.el(.skeleton, .{ .height = height, .semantics = .{ .label = "Loading image" } }, .{});
    }
    var picture = ui.image(.{ .image = image_id, .grow = 1 });
    // `ui.image` leaves the fit at `stretch`, which distorts the picture into
    // whatever box it is given (and worse as the window resizes).
    picture.widget.image_fit = .contain;
    // The picture sits in a pressable row rather than carrying the press
    // itself: an image is a leaf, and the hit target belongs on a container.
    // `quiet_hover` keeps it from washing over on hover like a list row, and the
    // box is sized to the drawn picture so only the picture itself is pressable,
    // not the empty width beside a narrow one.
    //
    // The link role is what puts the pointing hand over it: the engine follows
    // the native convention, where the hand marks a link and ordinary controls
    // keep the arrow, so this is the one role that advertises "clickable".
    return ui.el(.list_item, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .expand_image = note.id },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{picture});
}

/// How wide the drawn picture is: its own shape at the reserved height, never
/// wider than the card. `contain` centres a narrow picture in its box, so
/// matching the box to the picture is what keeps the press on the picture.
pub fn pictureWidth(note: *const Note) f32 {
    const nominal_width: f32 = 300;
    const height = pictureHeight(note);
    const aspect = if (note.image_aspect > 0)
        note.image_aspect
    else
        recalledAspect(note.id) orelse 0.66;
    if (aspect <= 0) return nominal_width;
    return @min(nominal_width, height / aspect);
}

const PlazaApp = native_sdk.UiApp(Model, Msg);
const Effects = PlazaApp.Effects;
/// The effects type, exported so tests can exercise the fx-free slot paths.
pub const EffectsForTest = Effects;

/// Boot: seed the feed once, register whatever images are already cached, then
/// arm the repeating timers.
pub fn boot(model: *Model, fx: *Effects) void {
    model.refresh(nowSeconds());
    // Local-first, all the way to the first frame: cached avatars and pictures
    // are registered here, so a returning user gets faces WITH the notes rather
    // than a tick later. Only what is on disk resolves now; the rest is fetched
    // from the first tick onward.
    scanAvatarFetches(fx);
    scanMediaFetches(fx, model);
    fx.startTimer(.{
        .key = refresh_timer_key,
        .interval_ms = refresh_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // One timer drives every playing GIF; a timer each would exhaust the table.
    fx.startTimer(.{
        .key = animation_timer_key,
        .interval_ms = animation_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.animate),
    });
    // Bring up the isolated signer; the tick health-checks it until it answers.
    spawnHelper(fx);
    // Background metadata fetching on its own cadence, off the view refresh.
    fx.startTimer(.{
        .key = profile_timer_key,
        .interval_ms = profile_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.profiles),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) {
                model.refresh(nowSeconds());
                // Start any pending image fetches (needs effects, so here, not
                // in refresh). The feed reads loaded images at render time.
                scanAvatarFetches(fx);
                scanMediaFetches(fx, model);
                // Retire timed-out or refused signer requests, restoring a lost
                // draft to the composer (this thread owns it).
                if (g_signer_kind == .remote) scanPendingRemote(model);
                // Health-check the signer daemon until the loopback IPC answers,
                // then fire any queued key setup.
                pollHelper(fx);
                driveHelperSetup(fx);
                // A toast lives a few seconds, then the tick retires it.
                if (model.toast_until != 0 and nowSeconds() >= model.toast_until) {
                    model.toast_until = 0;
                    model.toast_len = 0;
                }
            }
        },
        .animate => |t| {
            if (t.outcome == .fired) advanceAnimations(fx, model);
        },
        .profiles => |t| {
            if (t.outcome == .fired) {
                // Re-arm the still-unnamed every so often: a relay that had
                // nothing a moment ago may have it now.
                g_profile_round +%= 1;
                if (g_profile_round % profile_rearm_rounds == 0) rearmWantedProfiles();
                requestWantedProfiles();
            }
        },
        .helper_exited => |e| {
            if (e.reason != .exited) std.debug.print("plaza: [helper] exited\n", .{});
        },
        .helper_pubkey => |response| {
            handleHelperPubkey(model, response);
            // A queued setup fires the moment the daemon is reachable.
            driveHelperSetup(fx);
        },
        .helper_setup => |response| handleHelperSetup(model, response),
        .helper_signed => |response| handleHelperSigned(response),
        .avatar_fetched => |response| handleAvatarFetched(fx, response),
        .draft_edit => |edit| {
            model.draft_buffer.apply(edit);
            // The user is composing again: retire a stale "signer didn't respond".
            g_remote_sign_notice.store(false, .release);
        },
        .post => {
            submitPost(model, fx);
            // Posting closes the sheet; the note is already local and will
            // appear on the next tick.
            model.composing = false;
            setToast(model, if (g_signer_kind == .remote) "Sent to your signer" else "Posted");
            // The first local post is the calm moment to suggest a backup.
            if (g_signer_kind == .local and !model.backup_nudge_dismissed)
                model.backup_nudge = true;
        },
        .open_compose => {
            // The gate is on press, not on sight: a guest reaching for the
            // composer is exactly first intent, so the sheet rises and
            // remembers what was reached for.
            if (model.is_guest()) {
                model.joining = true;
                model.pending_compose = true;
            } else model.composing = true;
        },
        .close_compose => model.composing = false,
        .open_join => model.joining = true,
        .close_join => {
            model.joining = false;
            model.pending_compose = false;
        },
        .join_create => {
            // Async: the daemon mints the key (the key never enters Plaza), the
            // response adopts the identity and opens the name beat.
            model.joining = false;
            queueHelperSetup(fx, .create, null);
        },
        .join_bring_key => {
            // The join screen's field handles both an nsec and a bunker link;
            // the remembered intent survives the trip and replays on entry.
            model.joining = false;
            model.stage = .onboarding;
        },
        .keep_browsing => {
            model.stage = .ready;
            model.pending_compose = false;
        },
        .dismiss_guest_strip => model.guest_strip_dismissed = true,
        .name_edit => |edit| model.name_buffer.apply(edit),
        .name_save => {
            publishName(model, fx);
            model.naming = false;
            setToast(model, "Name set");
            replayPending(model);
        },
        .name_skip => {
            model.naming = false;
            replayPending(model);
        },
        .backup_now => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
            model.stage = .settings;
        },
        .backup_later => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
        },
        .create_identity => queueHelperSetup(fx, .create, null),
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
                    replayPending(model);
                },
                // Pair with the external signer from the bunker URL; on success
                // the feed comes up and posts route through it. A bad URL keeps
                // us on onboarding with an error (see `login_status`).
                .bunker => {
                    if (!connectRemoteSigner(raw)) return;
                    persistSession();
                    enterFeed(model);
                    replayPending(model);
                },
                .invalid => g_login_error.store(@intFromEnum(LoginError.format), .release),
            }
        },
        .open_settings => {
            // Seed the proxy field from the live setting so it edits in place.
            model.proxy_buffer.set(mediaProxy());
            model.proxy_saved = false;
            model.stage = .settings;
        },
        .proxy_edit => |edit| {
            model.proxy_buffer.apply(edit);
            model.proxy_saved = false;
        },
        .proxy_save => {
            setMediaProxy(model.proxy_buffer.text());
            saveSettings();
            model.proxy_saved = true;
            // Retry anything that failed to load under the previous setting.
            retryFailedImages();
        },
        .media_fetched => |response| handleMediaFetched(fx, response),
        .open_url => |url| openExternally(fx, url),
        .expand_image => |note_id| model.expanded_note = note_id,
        .close_image => model.expanded_note = null,
        .feed_scrolled => |scroll| {
            model.feed_scroll = scroll;
            // Load what just came into view without waiting for the next tick.
            scanMediaFetches(fx, model);
        },
        .load_older => {
            // One more page from the store, up to what the feed can hold.
            if (model.feed_limit >= feed_capacity) return;
            model.feed_limit = @min(model.feed_limit + feed_page, feed_capacity);
            g_last_count = std.math.maxInt(usize);
            model.refresh(nowSeconds());
        },
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
/// Shows a small confirming toast for a few seconds (the tick retires it).
fn setToast(model: *Model, text: []const u8) void {
    const n = @min(text.len, model.toast_buf.len);
    @memcpy(model.toast_buf[0..n], text[0..n]);
    model.toast_len = n;
    model.toast_until = nowSeconds() + 3;
}

/// Publishes the name beat's text as the account's kind:0 metadata, and seeds
/// the local profile cache so the app shows the name at once. Local keys only
/// (the beat never runs for imports or signers). Quotes and backslashes are
/// dropped rather than escaped: a display name is prose, not JSON.
fn publishName(model: *Model, fx: *Effects) void {
    const raw = std.mem.trim(u8, model.name_buffer.text(), " \t\r\n");
    if (raw.len == 0) return;
    const signer = g_identity_signer orelse return;
    const kp = g_identity_kp orelse return;
    const gpa = std.heap.page_allocator;

    var clean_buf: [64]u8 = undefined;
    var clean_len: usize = 0;
    for (raw) |c| {
        if (c == '"' or c == '\\') continue;
        clean_buf[clean_len] = c;
        clean_len += 1;
    }
    const clean = clean_buf[0..clean_len];
    if (clean.len == 0) return;

    const json = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{clean}) catch return;
    if (g_signer_kind == .helper) {
        // The daemon signs the kind:0; the response seeds the cache.
        requestHelperSign(fx, gpa, json, 0);
        model.name_buffer.clear();
        return;
    }
    const ev = nostr.event.create(gpa, signer, kp, nowSeconds(), 0, &.{}, json, null) catch {
        gpa.free(json);
        return;
    };
    ingestAndPublish(gpa, ev, null);
    // Seed the cache: the composer line and the feed show the name at once.
    if (upsertProfile(kp.public_key)) |prof| parseMetadataInto(prof, json);
    model.name_buffer.clear();
}

/// Completes the remembered first intent once an identity exists: the guest
/// reached for the composer, so it opens by itself. The welcome-in moment.
fn replayPending(model: *Model) void {
    if (model.pending_compose) {
        model.pending_compose = false;
        model.composing = true;
    }
}

/// The replay seam, exercised without disk or relays. For tests.
pub fn replayPendingForTest(model: *Model) void {
    replayPending(model);
}

/// Restores a helper identity from a session pubkey hex. For tests.
pub fn restoreHelperForTest(pubkey_hex: []const u8) bool {
    return restoreHelperIdentity(pubkey_hex);
}

/// Drives the remote-signer connection state (0 idle, 1 reaching, 2 connected,
/// 3 unreachable) plus a remote identity, so the presentation is testable
/// without a live bunker. For tests.
pub fn setRemoteStateForTest(status: u8, npub_len: usize) void {
    g_signer_kind = if (status == 0) .local else .remote;
    g_remote_status.store(status, .release);
    g_remote_sign_notice.store(false, .release);
    if (npub_len > 0) {
        const stub = "npub1testsigner";
        const n = @min(stub.len, g_identity_npub_buf.len);
        @memcpy(g_identity_npub_buf[0..n], stub[0..n]);
        g_identity_npub_len = n;
    } else g_identity_npub_len = 0;
}

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
fn submitPost(model: *Model, fx: *Effects) void {
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
        .helper => requestHelperSign(fx, gpa, owned, 1),
    }
    model.draft_buffer.clear();
}

/// The engine write seam: a note this process now holds, whether locally signed
/// or returned signed from the remote signer, enters the local store and is
/// published to the pool. The store is the single-writer data plane, only ever
/// written from this process. `verify` re-checks a signature we did not produce
/// ourselves and gates such a note out of both the store and the pool on
/// failure; a note we just signed skips the check and publishes even if the
/// store rejects the write (a duplicate). `ev.content` must be a
/// process-lifetime allocation, since the detached publisher reads it after
/// this returns.
fn ingestAndPublish(gpa: std.mem.Allocator, ev: nostr.event.Event, verify: ?nostr.keys.Signer) void {
    const store = g_store orelse return;
    if (verify) |signer| {
        // A note we did not produce: verification is the gate into the store
        // AND the pool, so a bad signature is dropped rather than propagated.
        _ = store.ingest(gpa, ev, .{ .verify_with = signer }) catch return;
    } else {
        // A note we just signed: a store failure (e.g. a duplicate id) must not
        // stop it reaching the pool.
        _ = store.ingest(gpa, ev, .{}) catch {};
    }
    const thread = std.Thread.spawn(.{}, publishEvent, .{ gpa, ev }) catch return;
    thread.detach();
}

/// Local path: sign with the local key, then hand the note to the write seam so
/// it lands in the store (shown on the next tick) and reaches the pool.
fn postLocally(gpa: std.mem.Allocator, owned: []const u8) void {
    const ev = signNote(gpa, owned) orelse {
        gpa.free(owned);
        return;
    };
    ingestAndPublish(gpa, ev, null);
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
    g_remote_sign_notice.store(false, .release);

    // A fresh generation: any prior listener (a reconnect to a second bunker)
    // stops processing, and every request registered from here carries it.
    const generation = g_remote_generation.fetchAdd(1, .monotonic) + 1;

    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch {
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
    if (!registerPending(req_id, .connect, null)) return;
    const params = [_][]const u8{ &hexbuf, g_remote_secret_buf[0..g_remote_secret_len] };
    sendRequest(gpa, .{ .id = req_id, .method = "connect", .params = &params });
}

/// Remote path: build the unsigned kind:1 event and send a `sign_event` request.
/// The signed event returns to the listener, which stores and publishes it.
fn requestRemoteSign(gpa: std.mem.Allocator, content_owned: []const u8) void {
    // `content_owned` is handed to the pending slot (so a timeout can restore
    // it to the composer); it is freed here only on an early return.
    const created_at = nowSeconds();
    // A canonical unsigned event (the bunker fills in the signature). The id is
    // computed against the user's pubkey so the bunker's result matches it.
    const id = nostr.event.computeId(gpa, g_remote_pubkey, created_at, 1, &.{}, content_owned) catch {
        gpa.free(content_owned);
        return;
    };
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = g_remote_pubkey,
        .created_at = created_at,
        .kind = 1,
        .tags = &.{},
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch {
        gpa.free(content_owned);
        return;
    };
    defer gpa.free(unsigned_json);

    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "req-{d}", .{g_req_counter.fetchAdd(1, .monotonic)}) catch {
        gpa.free(content_owned);
        return;
    };
    // Track before sending: the response can arrive on the listener thread the
    // instant the send lands, and it must find the pending slot already there.
    if (!registerPending(req_id, .sign_event, content_owned)) {
        gpa.free(content_owned);
        return;
    }
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
/// reconnecting until its `generation` is superseded (a logout or a reconnect
/// bumps `g_remote_generation`). Its own io backend and signer, never the UI
/// thread's.
fn nip46ReceiveLoop(gpa: std.mem.Allocator, generation: u64) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const client_kp = g_remote_client_kp orelse return;

    while (generation == g_remote_generation.load(.acquire)) {
        nip46ReceiveOnce(gpa, io, signer, client_kp, generation) catch |err| {
            std.debug.print("plaza: [signer] {s}\n", .{@errorName(err)});
        };
        if (generation != g_remote_generation.load(.acquire)) break;
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials the bunker relay, subscribes for responses addressed to our client key
/// (`#p` = the ephemeral pubkey, which only our bunker knows), and handles each
/// until the connection drops or this listener's `generation` is superseded.
fn nip46ReceiveOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, generation: u64) !void {
    var relay = try nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]);
    defer relay.deinit();

    var client_hex: [64]u8 = undefined;
    hexLower(&client_hex, client_kp.public_key);
    const pvals = [_][]const u8{&client_hex};
    const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &pvals }};
    const kinds = [_]u16{nostr.nip46.kind};
    const filters = [_]nostr.filter.Filter{.{ .kinds = &kinds, .tags = &tag_filters }};
    try relay.subscribe("plaza-nip46", &filters);

    while (generation == g_remote_generation.load(.acquire)) {
        var msg = (try relay.receive()) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| handleNip46Response(gpa, signer, client_kp, e.event, generation),
            else => {},
        }
    }
}

/// Decrypts, parses, and correlates a NIP-46 response to the request that asked
/// for it. An error response flags its request so the UI restores the draft; a
/// `sign_event` result is verified, stored, and published to the feed pool (the
/// remote equivalent of the local post path); a `connect` ack marks connected.
/// An unknown or already-handled id is dropped, so a duplicate never publishes
/// twice and a stale session's response never lands.
fn handleNip46Response(gpa: std.mem.Allocator, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, ev: nostr.event.Event, generation: u64) void {
    if (generation != g_remote_generation.load(.acquire)) return;
    const plaintext = nostr.nip46.open(gpa, signer, client_kp.secret_key, ev) catch return;
    defer gpa.free(plaintext);
    var resp = nostr.nip46.parseResponse(gpa, plaintext) catch return;
    defer resp.deinit();

    if (resp.value.err.len != 0) {
        std.debug.print("plaza: [signer] {s}\n", .{resp.value.err});
        // Leave the slot in the table, flagged: the UI tick owns the composer,
        // so it restores the draft (sign) or fails the status (connect).
        _ = failPending(resp.value.id);
        return;
    }

    // Correlate to the request that asked. A missing slot means an unknown id
    // or one already handled: drop it (no double publish, no stray "connected").
    const pending = takePending(resp.value.id) orelse return;
    defer if (pending.content) |c| gpa.free(c);

    g_remote_status.store(2, .release);
    g_remote_sign_notice.store(false, .release);

    switch (pending.method) {
        // The connect ack is a plain "ack" string; the status above is the point.
        .connect => {},
        .sign_event => {
            var parsed = nostr.event.fromJson(gpa, resp.value.result) catch return;
            defer parsed.deinit();
            // A process-lifetime copy of the content: `parsed` is freed on
            // return, but the detached publisher reads it afterwards. Our
            // composer produces tagless kind:1 notes, so an empty tag set still
            // matches the signed id, and the write seam verifies that before
            // trusting it into the feed.
            const owned = gpa.dupe(u8, parsed.value.content) catch return;
            var out = parsed.value;
            out.content = owned;
            out.tags = &.{};
            ingestAndPublish(gpa, out, signer);
        },
    }
}

/// UI-thread sweep of the pending table (called each tick): a request that
/// failed or ran past its deadline is retired here, where the composer can be
/// touched. A timed-out or refused `sign_event` restores its draft (only into
/// an empty composer, so a newer draft is never clobbered) and shows a notice;
/// a `connect` that never returned fails the connection status. A slot from a
/// superseded generation (logout/reconnect) is dropped silently.
fn scanPendingRemote(model: *Model) void {
    const now = nowSeconds();
    const gpa = std.heap.page_allocator;
    const generation = g_remote_generation.load(.acquire);
    var restore: ?[]const u8 = null;
    var sign_failed = false;
    var connect_failed = false;

    pendingLock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        const stale = slot.generation != generation;
        const due = slot.failed or now >= slot.deadline_s;
        if (!stale and !due) continue;
        const method = slot.method;
        const content = slot.content;
        slot.* = .{};
        if (stale) {
            if (content) |c| gpa.free(c);
            continue;
        }
        switch (method) {
            .sign_event => {
                // The composer holds one draft: keep the first, free the rest.
                if (content) |c| {
                    if (restore == null) restore = c else gpa.free(c);
                }
                sign_failed = true;
            },
            .connect => {
                if (content) |c| gpa.free(c);
                connect_failed = true;
            },
        }
    }
    pendingUnlock();

    if (restore) |c| {
        if (model.draft_empty()) model.draft_buffer.set(c);
        gpa.free(c);
    }
    if (sign_failed) g_remote_sign_notice.store(true, .release);
    if (connect_failed and g_remote_status.load(.acquire) == 1) g_remote_status.store(3, .release);
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

    // The action glyphs the feed draws (reply/like/zap) that the built-in set
    // does not carry. Registered before the first view build.
    canvas.icons.registerAppIcons(&plaza_icons.app_icons);

    // A returning user has a persisted session: restore it (load the local key,
    // or silently reconnect the bunker) so they are signed straight back in.
    // Best-effort: on failure the app still runs, as a guest.
    loadSettings(init.io, init.environ_map);
    _ = restoreSession(init.io, init.environ_map);
    // Resolve the keyholder daemon (its path and a fresh bearer token); boot
    // spawns it. Best-effort, and non-fatal: signing still works in-process.
    resolveHelper(init);

    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = appView,
        // The app renders in its own type on every platform: Geist for prose,
        // Geist Mono for metadata, registered on the installing frame.
        .fonts = &.{
            .{ .id = theme.geist_font_id, .name = "Geist-Regular.ttf", .ttf = theme.geist_ttf },
            .{ .id = theme.geist_mono_font_id, .name = "GeistMono-Regular.ttf", .ttf = theme.geist_mono_ttf },
        },
        // The dark, cool-grey, white-accent look (see theme.zig).
        .tokens_fn = theme.tokens(Model),
    });
    defer app_state.destroy();
    app_state.model = initialModel();
    // Guest-first: the app opens INTO the feed, never a welcome wall. A
    // restored session is signed straight back in; a newcomer browses as a
    // guest (the feed reads fine without an identity) and is asked for one at
    // first intent, not at launch. Either way the store and the pool start
    // before the window appears, so the first frame renders from disk.
    app_state.model.stage = .ready;
    startFeed(init.io, init.environ_map);

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
    // Queue a silent, background upgrade: move this in-process key into the
    // isolated daemon. The tick fires it once the daemon is reachable; on
    // success the identity becomes helper-held and identity.key is deleted. If
    // it never lands, the key keeps working in-process, no loss.
    g_helper_setup_secret = secret;
    g_helper_setup = .migrate;
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
        .flags = .{ .permissions = secret_file_permissions },
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
        .helper => blk: {
            if (!g_helper_has_identity) return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, g_helper_identity_pk);
            break :blk std.fmt.bufPrint(&buf, "kind=helper\npubkey={s}\n", .{&pk_hex}) catch return;
        },
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
        .flags = .{ .permissions = secret_file_permissions },
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
        if (std.mem.eql(u8, key, "pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "relay")) f_relay = val;
        if (std.mem.eql(u8, key, "client_secret")) f_client_secret = val;
        if (std.mem.eql(u8, key, "secret")) f_secret = val;
    }

    if (std.mem.eql(u8, kind, "helper")) return restoreHelperIdentity(f_pubkey);
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
    g_remote_sign_notice.store(false, .release);

    // A fresh generation for this reconnected session (see `connectRemoteSigner`).
    const generation = g_remote_generation.fetchAdd(1, .monotonic) + 1;
    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch return false;
    thread.detach();
    sendConnect(gpa);
    return true;
}

/// Loads app-wide settings (the media proxy) from `$HOME/.plaza/settings`,
/// starting from the default so a fresh install proxies out of the box.
fn loadSettings(io: std.Io, environ: *const std.process.Environ.Map) void {
    setMediaProxy(default_media_proxy);
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "settings", gpa, std.Io.Limit.limited(1024)) catch return;
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        // An empty value is meaningful: the user chose to load originals.
        if (std.mem.eql(u8, line[0..eq], "media_proxy")) setMediaProxy(line[eq + 1 ..]);
    }
}

/// Persists app-wide settings. Best-effort, like the session file.
fn saveSettings() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var buf: [512]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "media_proxy={s}\n", .{mediaProxy()}) catch return;
    dir.writeFile(io, .{
        .sub_path = "settings",
        .data = data,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch |err| std.debug.print("plaza: could not persist settings: {s}\n", .{@errorName(err)});
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
            // The helper's key lives in the daemon's file; remove it too, so a
            // logout leaves no key on disk. (The running daemon keeps its copy
            // in memory until it exits with Plaza; recreating an identity in the
            // same session needs a restart.)
            if (g_signer_kind == .helper) dir.deleteFile(io, "signer.key") catch {};
        } else |_| {}
    };

    // Tear down the NIP-46 session: bumping the generation stops the detached
    // listener from processing into the next session, and the pending table is
    // emptied so no in-flight request survives the logout.
    _ = g_remote_generation.fetchAdd(1, .monotonic);
    clearPending();
    g_remote_sign_notice.store(false, .release);

    if (g_identity_signer) |*s| s.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_identity_npub_len = 0;
    g_helper_has_identity = false;
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
    // Never a locked door: signing out lands on the guest feed, reading
    // uninterrupted (the pool and store keep running), not a welcome wall.
    model.stage = .ready;
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

    // Follow-scoped: the starter pack's recent notes for the feed, plus their
    // kind:0 metadata (and the user's own) so the feed can show real names and
    // avatars. Two filters share one subscription.
    var authors: [starter_pack.len + 1][32]u8 = starter_pack ++ [_][32]u8{undefined};
    var authors_len: usize = starter_pack.len;
    if (activePubkey()) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    const feed_kinds = [_]u16{1};
    const profile_kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{
        .{ .authors = &starter_pack, .kinds = &feed_kinds, .limit = feed_capacity },
        .{ .authors = authors[0..authors_len], .kinds = &profile_kinds, .limit = profile_cap },
    };
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

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
    pubkey: [32]u8 = [_]u8{0} ** 32,
};
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

/// Asks the relays for the metadata of everyone mentioned but still unnamed, in
/// one batch on a throwaway connection.
fn requestWantedProfiles() void {
    var batch: [wanted_profiles_cap][32]u8 = undefined;
    var n: usize = 0;
    for (&g_wanted) |*w| {
        if (!w.used or w.requested) continue;
        if (lookupProfile(w.pubkey)) |p| {
            if (p.name_len > 0) {
                w.requested = true;
                continue;
            }
        }
        batch[n] = w.pubkey;
        n += 1;
        w.requested = true;
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
        // One relay that answered is enough for metadata.
        return;
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

/// Clears the profile cache. For tests, which share the process globals.
pub fn resetProfilesForTest() void {
    g_profiles = [_]Profile{.{}} ** profile_cap;
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
    // Where the feed is scrolled, so images load around the viewport instead of
    // only at the top. The windowed list replaces this estimate with the
    // runtime's exact visible range in the next milestone.
    feed_scroll: canvas.ScrollState = .{},

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, the stage through
    // `show_onboarding`/`show_feed`/`show_settings`, the login field through
    // `login_draft`, so the raw fields are never bound by name.
    // Everything the FEED reads is listed here too: that screen is a Zig view
    // now, so markup never binds its state (the welcome and Settings fragments
    // still bind theirs, and are still checked).
    pub const view_unbound = .{
        "notes",       "notes_len",     "live_relays",    "offline_relays", "draft_buffer",
        "stage",       "login_buffer",  "logout_pending", "reveal_nsec",    "proxy_buffer",
        "proxy_saved", "feed_scroll",   "draft",          "draft_empty",    "identity",
        "has_notes",   "empty",         "status",         "empty_text",     "footer",
        "note_list",   "expanded_note",
    };

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
        // Show the user's own display name once their kind:0 is known, else npub.
        var who: []const u8 = g_identity_npub_buf[0..g_identity_npub_len];
        if (activePubkey()) |pk| {
            if (lookupProfile(pk)) |p| {
                if (p.name_len > 0) who = p.name();
            }
        }
        const prefix = if (g_signer_kind == .remote) "Signing via your signer · " else "Posting as ";
        return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, who }) catch who;
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
        const overscan = 2;
        if (self.notes_len == 0) return .{ .first = 0, .last = 0 };
        const content = self.feed_scroll.content_extent;
        const viewport = self.feed_scroll.viewport_extent;
        if (content <= 0 or viewport <= 0) {
            return .{ .first = 0, .last = @min(self.notes_len - 1, max_media_images - 1) };
        }
        const average = content / @as(f32, @floatFromInt(self.notes_len));
        if (average <= 0) return .{ .first = 0, .last = self.notes_len - 1 };

        const first_f = @max(0, self.feed_scroll.offset / average - overscan);
        const last_f = (self.feed_scroll.offset + viewport) / average + overscan;
        const first: usize = @intFromFloat(first_f);
        const last: usize = @intFromFloat(@max(0, last_f));
        return .{ .first = @min(first, self.notes_len - 1), .last = @min(last, self.notes_len - 1) };
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
        parseMetadataInto(p, ev.content);
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
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
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
/// wanted (never one with a fetch in flight). Null when every slot is busy.
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
    var index = window.first;
    while (index <= window.last and index < model.notes_len) : (index += 1) {
        const note = &model.notes[index];
        if (!note.hasImage()) continue;
        const slot = claimMediaSlot(fx, note.id) orelse continue;
        // Touch it every pass so an on-screen picture is never the eviction
        // victim for one further down.
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
        .id = @intCast(std.mem.readInt(u64, ev.id[0..8], .big) & std.math.maxInt(i64)),
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
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    /// Expand a note's picture to fill the window.
    expand_image: i64,
    /// Dismiss the expanded picture.
    close_image,

    // Dispatched from Zig rather than markup: the effect results, and every
    // action on the feed screen (a Zig view now, not a markup file).
    pub const view_unbound = .{ "tick", "animate", "avatar_fetched", "media_fetched", "draft_edit", "post", "open_settings", "feed_scrolled", "open_url", "expand_image", "close_image" };
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

/// The root view: one screen at a time, chosen by the stage. An expanded
/// picture takes over the window until it is dismissed.
pub fn appView(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.expanded_note) |note_id| {
        if (model.noteById(note_id)) |note| return imageViewer(ui, note);
    }
    return switch (model.stage) {
        .onboarding => OnboardingView.build(ui, model),
        .settings => SettingsView.build(ui, model),
        .ready => feedView(ui, model),
    };
}

/// The expanded picture, filling the window. The registry decodes at most 512
/// pixels on a side, so rather than upscale a small copy into a blur, this shows
/// it at its own size and offers the full-resolution original in the browser.
fn imageViewer(ui: *AppUi, note: *const Note) AppUi.Node {
    const image_id = note.media_id();
    return ui.column(.{
        .grow = 1,
        .gap = 12,
        .padding = 16,
        .main = .center,
        .cross = .center,
        .style_tokens = .{ .background = .background },
    }, .{
        if (image_id != 0) blk: {
            var node = ui.image(.{
                .image = image_id,
                .grow = 1,
                .semantics = .{ .label = "Expanded image" },
            });
            node.widget.image_fit = .contain;
            break :blk node;
        } else ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Still loading…"),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_image }, "Close"),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .on_press = Msg{ .open_url = note.imageUrl() } }, "Open original"),
        }),
    });
}

/// The feed screen: header, the note list, the composer, and a status bar.
fn feedView(ui: *AppUi, model: *const Model) AppUi.Node {
    const notes = model.notes[0..model.notes_len];
    const cards = ui.arena.alloc(AppUi.Node, notes.len) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (cards, notes) |*card, *note| card.* = noteCard(ui, note);

    return ui.column(.{ .grow = 1 }, .{
        ui.row(.{ .gap = 8, .cross = .center, .padding = 16 }, .{
            ui.column(.{ .gap = 4, .grow = 1 }, .{
                ui.text(.{ .size = .heading }, "Plaza"),
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.status(ui.arena)),
            }),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .open_settings }, "Settings"),
        }),
        ui.separator(.{}),
        if (notes.len == 0)
            ui.column(.{ .gap = 12, .main = .center, .cross = .center, .grow = 1, .padding = 24 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.empty_text()),
            })
        else
            ui.scroll(.{ .grow = 1, .on_scroll = AppUi.scrollMsg(.feed_scrolled) }, .{
                ui.column(.{ .gap = 8, .padding = 12 }, .{cards}),
            }),
        ui.separator(.{}),
        ui.column(.{ .gap = 8, .padding = 12 }, .{
            ui.inputGroup(
                .{},
                ui.el(.textarea, .{
                    .text = model.draft(),
                    .placeholder = "Share something with the network…",
                    .on_input = AppUi.inputMsg(.draft_edit),
                    .on_submit = .post,
                }, .{}),
                ui.inputGroupActions(.{}, .{
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.identity(ui.arena)),
                    ui.spacer(1),
                    ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.draft_empty(), .on_press = .post }, "Post"),
                }),
            ),
        }),
        ui.statusBar(.{}, model.footer(ui.arena)),
    });
}

/// One note: avatar, author line, content, and any inline image. Keyed by the
/// note id so the list diff holds scroll position across reconciles. This is
/// the per-row builder the windowed list will call in the milestone ahead.
fn noteCard(ui: *AppUi, note: *const Note) AppUi.Node {
    var node = ui.el(.card, .{ .padding = 12 }, .{
        ui.row(.{ .gap = 10, .cross = .start }, .{
            ui.avatar(.{ .image = note.avatar_id() }, note.initials()),
            ui.column(.{ .gap = 4, .grow = 1 }, .{
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    ui.text(.{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, note.author()),
                    ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, note.time()),
                }),
                ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url) }, contentSpans(ui, note.content())),
                // The picture. The space is reserved at the picture's own shape
                // whether or not it has loaded, so the feed never shifts as
                // images arrive, or as they are evicted and fetched again while
                // scrolling back and forth.
                if (note.hasImage()) notePicture(ui, note) else ui.spacer(0),
            }),
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
    // `quiet_hover` keeps it from washing over on hover like a list row.
    return ui.el(.list_item, .{
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .expand_image = note.id },
        .semantics = .{ .role = .button, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{picture});
}

const PlazaApp = native_sdk.UiApp(Model, Msg);
const Effects = PlazaApp.Effects;

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
                requestWantedProfiles();
            }
        },
        .animate => |t| {
            if (t.outcome == .fired) advanceAnimations(fx, model);
        },
        .avatar_fetched => |response| handleAvatarFetched(fx, response),
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
        .expand_image => |note_id| {
            std.debug.print("plaza: [viewer] expand note={d} found={}\n", .{ note_id, model.noteById(note_id) != null });
            model.expanded_note = note_id;
        },
        .close_image => model.expanded_note = null,
        .feed_scrolled => |scroll| {
            model.feed_scroll = scroll;
            // Load what just came into view without waiting for the next tick.
            scanMediaFetches(fx, model);
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
    loadSettings(init.io, init.environ_map);
    const restored = restoreSession(init.io, init.environ_map);

    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = appView,
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
        .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o600) },
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

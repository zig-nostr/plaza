//! NIP-46: the remote signer connection, its pending requests, and their answers.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");
const login = @import("login.zig");
const private_lists = @import("private_lists.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const PendingUndo = main.PendingUndo;
const slotIdForTest = main.slotIdForTest;
const Effects = main.Effects;
const LoginError = main.LoginError;
const Model = main.Model;
const PlaceRoute = main.PlaceRoute;
const WarnCarry = main.WarnCarry;
const abbreviateNpub = main.abbreviateNpub;
const applyUndo = main.applyUndo;
const authDeliverSigned = main.authDeliverSigned;
const authFailSigning = main.authFailSigning;
const bunker_watch_slot = main.bunker_watch_slot;
const compose_capacity = main.compose_capacity;
const dupeTags = main.dupeTags;
const enterFeed = main.enterFeed;
const finishPrivateBookmark = main.finishPrivateBookmark;
const halfAwaiting = main.halfAwaiting;
const ingestAndPublish = main.ingestAndPublish;
const invalidateFeed = main.invalidateFeed;
const loadBookmarksFromStore = main.loadBookmarksFromStore;
const loadMutesFromStore = main.loadMutesFromStore;
const networkAllowed = main.networkAllowed;
const nowSeconds = main.nowSeconds;
const offerLiveRelay = main.offerLiveRelay;
const one_shot_budget_ms = main.one_shot_budget_ms;
const parkUploadSign = main.parkUploadSign;
const persistSession = main.persistSession;
const privateHalfId = main.privateHalfId;
const private_half_retry_s = main.private_half_retry_s;
const rearmPrivateHalves = main.rearmPrivateHalves;
const releaseOneShot = main.releaseOneShot;
const releaseUndo = main.releaseUndo;
const replayPending = main.replayPending;
const setPlain = main.setPlain;
const setToast = main.setToast;
const uploadSignFailed = main.uploadSignFailed;
const watchOneShot = main.watchOneShot;

// Remote-signer (NIP-46) connection state, set at connect time and read by the
// background threads. The ephemeral client keypair is Plaza's transport identity
// with the bunker (never the user's key); the user's identity is the bunker's
// own pubkey. Each worker thread makes its own secp256k1 signer, only these
// bytes are shared.
pub var g_remote_client_kp: ?nostr.keys.KeyPair = null;
pub var g_remote_pubkey: [32]u8 = undefined;
pub var g_remote_relay_buf: [256]u8 = undefined;
pub var g_remote_relay_len: usize = 0;
pub var g_remote_secret_buf: [128]u8 = undefined;
pub var g_remote_secret_len: usize = 0;
// 0 idle, 1 connecting, 2 connected, 3 failed. Drives the onboarding status line.
pub var g_remote_status = std.atomic.Value(u8).init(0);
// Set from the moment a pasted bunker link starts connecting until its first
// answer arrives. While it is set the connection exists but nobody is signed in
// by it: a link that points at a relay nobody is listening on, or a signer that
// is not running, must not turn into an account that looks fine and then cannot
// sign. See `driveBunkerConnect`.
pub var g_remote_confirming = std.atomic.Value(bool).init(false);
// The listener runs for one connection generation. A logout or a reconnect
// bumps this; the detached listener and the in-flight workers see the change
// and stop, so an old bunker's listener never processes into a new session (or
// a dead one). Correlating this into every pending request is the teardown fix.
pub var g_remote_generation = std.atomic.Value(u64).init(0);

/// A connect or a reconnect starts a new generation, and with it a new chance
/// for a signer that said no. A half the previous session's bunker declined or
/// never answered is put back to idle, so the next tick asks the signer that is
/// connected now. Logout bumps the generation directly: it forgets the halves
/// outright and has nothing to re-ask.
pub fn newRemoteGeneration() u64 {
    rearmPrivateHalves(0, true);
    return g_remote_generation.fetchAdd(1, .monotonic) + 1;
}
// A remote sign that never came back, surfaced once in the composer identity
// line so a restored draft is explained rather than silently reappearing.
// Set by the timeout scan, cleared on the next edit or a later success.
pub var g_remote_sign_notice = std.atomic.Value(bool).init(false);

// Pending NIP-46 requests, keyed by id, so a response is correlated to the
// request that asked for it (not guessed from whether `result` parses as an
// event), and a request that never returns times out instead of losing the
// draft. A tiny spinlock guards the table: every critical section is a handful
// of field writes or an 8-slot scan and never touches IO, so a lock this cheap
// is the right tool (std.Io.Mutex would drag a per-thread `io` through every
// access, across threads that deliberately never share one).
const remote_sign_timeout_s: i64 = 30;
const max_pending_remote = 8;
pub const no_half_id = [_]u8{0} ** 32;
pub const RemoteMethod = enum { connect, sign_event, nip44_decrypt, nip04_decrypt, nip44_encrypt, sign_auth, sign_upload_auth };
const PendingRemote = struct {
    active: bool = false,
    id_buf: [24]u8 = undefined,
    id_len: usize = 0,
    method: RemoteMethod = .connect,
    /// A decrypt only: which `g_private_halves` slot this answers. The
    /// response arrives with nothing but a request id on it, so the slot has to
    /// be remembered here or the plaintext has no home.
    half_index: u8 = 0,
    /// A decrypt only: `privateHalfId` of the ciphertext that was asked. The slot
    /// index alone says where an answer would go, not whose it is: a sign-out
    /// frees the slots while this ask is still out, and the next account can be
    /// holding that slot by the time the answer lands.
    half_id: [32]u8 = [_]u8{0} ** 32,
    deadline_s: i64 = 0,
    generation: u64 = 0,
    // The listener flags a failed response here; the UI tick, which owns the
    // composer, is what actually restores the draft (see `scanPendingRemote`).
    failed: bool = false,
    // sign_event only: the draft text, restored to the composer on failure or
    // timeout. Owned by the slot; freed when the request resolves or is swept.
    content: ?[]const u8 = null,
    // Whether `content` is a composer draft worth restoring on failure. A
    // reaction (kind:7 "+") is not, so its failure is silent, not a stray "+".
    restorable: bool = false,
    // Where the write was submitted from. A bunker asks a person, so this comes
    // back on a human timescale, by which time the reader may be standing in a
    // different room entirely.
    route: PlaceRoute = .none,
    // sign_event only: the content warning the draft was signed with, kept with
    // THIS request so the draft that comes back gets its own warning when several
    // signs are out at once.
    warn: WarnCarry = .{},
    // sign_event only: what this press changed, put back if this request fails
    // and released when it is signed. Owned by the slot, like `content`.
    undo: PendingUndo = .none,

    pub fn id(self: *const PendingRemote) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};
/// A decrypt answer on its way from the listener thread to the UI tick.
///
/// The bunker's replies land on the listener thread, and `g_private_halves` is
/// read by the view every frame and written by `scanPrivateHalves` on the UI
/// thread. Rather than add a second writer to that state from another thread,
/// the listener parks the plaintext here under the pending lock it already
/// takes, and `scanPendingRemote` applies it where every other private-half
/// write happens.
const HalfInbox = struct {
    used: bool = false,
    index: u8 = 0,
    /// The ciphertext the ask was about, carried from `PendingRemote.half_id`.
    half_id: [32]u8 = [_]u8{0} ** 32,
    ok: bool = false,
    plain_buf: [4096]u8 = undefined,
    plain_len: u16 = 0,
};
pub var g_half_inbox: [max_pending_remote]HalfInbox = [_]HalfInbox{.{}} ** max_pending_remote;

/// The same crossing for a seal, of which only one is ever in flight.
const SealInbox = struct {
    used: bool = false,
    ok: bool = false,
    buf: [4096]u8 = undefined,
    len: u16 = 0,
};
var g_seal_inbox: SealInbox = .{};

var g_pending_lock = std.atomic.Value(bool).init(false);
pub var g_pending: [max_pending_remote]PendingRemote = [_]PendingRemote{.{}} ** max_pending_remote;

pub fn pendingLock() void {
    while (g_pending_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn pendingUnlock() void {
    g_pending_lock.store(false, .release);
}

/// Records a request as awaiting its response, taking ownership of `content`
/// (the draft, for `sign_event`, so a timeout can restore it when `restorable`).
/// Returns false when the table is full or the id does not fit, in which case
/// the caller still owns `content`.
pub fn registerPending(req_id: []const u8, method: RemoteMethod, content: ?[]const u8, restorable: bool, route: PlaceRoute, half_index: u8, half_id: [32]u8, warn: WarnCarry) bool {
    return registerPendingWith(req_id, method, content, restorable, route, half_index, half_id, warn, .none);
}

/// `registerPending` for a sign that carries an undo. The slot takes ownership
/// of `undo` only when this returns true.
fn registerPendingWith(req_id: []const u8, method: RemoteMethod, content: ?[]const u8, restorable: bool, route: PlaceRoute, half_index: u8, half_id: [32]u8, warn: WarnCarry, undo: PendingUndo) bool {
    if (req_id.len > 24) return false;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active) continue;
        slot.* = .{
            .active = true,
            .method = method,
            .half_index = half_index,
            .half_id = half_id,
            .id_len = req_id.len,
            .deadline_s = nowSeconds() + remote_sign_timeout_s,
            .generation = g_remote_generation.load(.acquire),
            .content = content,
            .restorable = restorable,
            .route = route,
            .warn = if (restorable) warn else .{},
            .undo = undo,
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
pub fn takePending(req_id: []const u8) ?PendingRemote {
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

/// `takePending` for an answer from the signer, which also marks the connection
/// up. Both happen under the table's lock: the tick decides a pasted link's
/// `connect` never went out when it finds no slot and the status still at
/// "connecting", and with the two done apart an answer that arrived between them
/// read as exactly that, and a signer that said yes was reported as silent.
pub fn takeAnswered(req_id: []const u8) ?PendingRemote {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and std.mem.eql(u8, slot.id(), req_id)) {
            const taken = slot.*;
            slot.* = .{};
            g_remote_status.store(2, .release);
            return taken;
        }
    }
    return null;
}

/// Marks the pending request matching `req_id` failed, leaving it in the table
/// for the UI tick to restore the draft and free the content. Returns whether a
/// slot matched.
pub fn failPending(req_id: []const u8) bool {
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
/// Empties the pending table, freeing every held draft. For logout, so a new
/// session never inherits the old one's in-flight requests.
pub fn clearPending() void {
    const gpa = std.heap.page_allocator;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        if (slot.content) |c| gpa.free(c);
        releaseUndo(slot.undo);
        slot.* = .{};
    }
}
// ------------------------------------------------------- remote signer (NIP-46)
//
// Signing can be routed to an external signer (Notary) over NIP-46 so the user's
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
/// request. Returns false (and marks the status failed) on a bad URL. Returning
/// true means the request is out, not that anyone is signed in: that happens
/// when the signer answers it (see `driveBunkerConnect`).
pub fn connectRemoteSigner(url_raw: []const u8) bool {
    const url = std.mem.trim(u8, url_raw, " \t\r\n");
    const io = main.g_io orelse return false;
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
    const npub = abbreviateNpub(&keyholder.g_identity_npub_buf, g_remote_pubkey);
    keyholder.g_identity_npub_len = npub.len;
    keyholder.g_signer_kind = .remote;
    g_remote_status.store(1, .release);
    g_remote_sign_notice.store(false, .release);
    // Nobody is signed in by this until the signer answers (see
    // `driveBunkerConnect`).
    g_remote_confirming.store(true, .release);

    // A fresh generation: any prior listener (a reconnect to a second bunker)
    // stops processing, and every request registered from here carries it.
    const generation = newRemoteGeneration();

    // The listener is a network thread, so a test build does not start one
    // (see `networkAllowed`).
    if (networkAllowed()) {
        const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch {
            abandonRemoteSigner(.signer_silent);
            return false;
        };
        thread.detach();
    }

    sendConnect(gpa);
    return true;
}

/// Request ids a unit test hands out, which has no io to draw them from.
var g_test_request_seq: u32 = 0;

/// Whether this generation's `connect` is neither waiting for its answer nor
/// answered: it never went out, so there is nothing left to wait for.
pub fn connectWentQuiet() bool {
    const generation = g_remote_generation.load(.acquire);
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and slot.method == .connect and slot.generation == generation and !slot.failed) return false;
    }
    // Read under the same lock the listener takes an answer under (see
    // `takeAnswered`), so a slot that is gone because it was ANSWERED is never
    // mistaken for one that never went out.
    return g_remote_status.load(.acquire) == 1;
}

/// Takes down a bunker connection that is not going to be anybody's sign-in:
/// the listener stops, every request in flight is dropped, and the pairing
/// secret and the client key are wiped rather than left in memory. Who is
/// signed in is not touched here (see `abandonRemoteSigner`).
fn dropRemoteConnection() void {
    // Bumped first, so the detached listener stops processing before the state
    // it reads is taken away.
    _ = g_remote_generation.fetchAdd(1, .monotonic);
    clearPending();
    g_remote_confirming.store(false, .release);
    g_remote_sign_notice.store(false, .release);
    std.crypto.secureZero(u8, &g_remote_secret_buf);
    g_remote_secret_len = 0;
    if (g_remote_client_kp) |*kp| std.crypto.secureZero(u8, &kp.secret_key);
    g_remote_client_kp = null;
    g_remote_relay_len = 0;
    g_remote_status.store(0, .release);
}

/// Takes back a bunker connection that never became a sign-in: the connection
/// is dropped, and the reader is a guest again with the reason on the sheet
/// they are still looking at.
pub fn abandonRemoteSigner(why: LoginError) void {
    dropRemoteConnection();
    keyholder.g_identity_npub_len = 0;
    keyholder.g_signer_kind = .helper;
    login.g_login_error.store(@intFromEnum(why), .release);
}

/// Whether a pasted bunker link is still waiting on its signer.
pub fn bunkerConnecting() bool {
    return g_remote_confirming.load(.acquire);
}

/// The tick's half of connecting a pasted bunker link: signs the reader in once
/// the signer has answered, and gives the sheet an error when it has not.
///
/// The link used to sign the reader in the moment it parsed. A link to a relay
/// that was down then produced an account, a green dot, and a repost that sat
/// on "Reposted" for thirty seconds before failing, with the reason only in a
/// log. The answer to `connect` is the proof that the signer exists, is
/// reachable and took this client, so it is what the sign-in waits for.
pub fn driveBunkerConnect(model: *Model) void {
    if (!g_remote_confirming.load(.acquire)) return;
    // Something else took the seat (a keyholder key adopted while waiting).
    // The pairing is not theirs, so it goes: left up, its listener would hold
    // the bunker relay for the rest of the run with the link's secret in
    // memory, and a late answer would mark a signer nobody uses "connected".
    if (keyholder.g_signer_kind != .remote) {
        dropRemoteConnection();
        return;
    }
    switch (g_remote_status.load(.acquire)) {
        2 => {
            g_remote_confirming.store(false, .release);
            login.g_login_error.store(@intFromEnum(LoginError.none), .release);
            persistSession();
            model.joining = false;
            model.bunker_mode = false;
            model.login_buffer.clear();
            enterFeed(model);
            replayPending(model);
        },
        // The request failed or ran out its thirty seconds.
        3 => abandonRemoteSigner(.signer_silent),
        // Connecting. If nothing is in flight any more there is nothing to wait
        // for: the request never went out.
        else => if (connectWentQuiet()) abandonRemoteSigner(.signer_silent),
    }
}

/// A request id nobody watching the relay can guess.
///
/// These were `req-0`, `req-1`, and so on, from a counter that starts at zero
/// on every launch. Our client pubkey is not a secret: it is the `p` tag on
/// every request we publish. Anyone reading the bunker's relay could therefore
/// address an answer to us and guess which request was in flight. They still
/// cannot read the request, and after the sender check above they cannot be
/// heard at all, but a request id should not be a countdown either.
///
/// Sixteen hex characters from the system CSPRNG, the same source the ephemeral
/// client key comes from.
pub fn newRequestId(out: *[24]u8) ?[]const u8 {
    const io = main.g_io orelse {
        // No io in a unit test, so ids come from a counter there. Never in the app.
        if (!builtin.is_test) return null;
        g_test_request_seq +%= 1;
        return std.fmt.bufPrint(out, "test{x}", .{g_test_request_seq}) catch null;
    };
    var raw: [8]u8 = undefined;
    io.randomSecure(&raw) catch return null;
    return std.fmt.bufPrint(out, "{x}", .{raw}) catch null;
}

/// Sends the NIP-46 `connect` request (remote pubkey + optional secret).
pub fn sendConnect(gpa: std.mem.Allocator) void {
    var hexbuf: [64]u8 = undefined;
    hexLower(&hexbuf, g_remote_pubkey);
    var idbuf: [24]u8 = undefined;
    const req_id = newRequestId(&idbuf) orelse return;
    if (!registerPending(req_id, .connect, null, false, .none, 0, no_half_id, .{})) return;
    const params = [_][]const u8{ &hexbuf, g_remote_secret_buf[0..g_remote_secret_len] };
    sendRequest(gpa, .{ .id = req_id, .method = "connect", .params = &params });
}

/// Remote path: build the unsigned event of `kind` (with `tags`, stamped
/// `created_at`) and send a `sign_event` request. The signed event returns to
/// the listener, which stores and publishes it. `restorable` is true only for a
/// composer draft, so a failed reaction never lands "+"-text in the composer.
pub fn requestRemoteSign(gpa: std.mem.Allocator, created_at: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8, restorable: bool, route: PlaceRoute, undo: PendingUndo) void {
    requestRemoteSignAs(.sign_event, gpa, created_at, kind, tags, content_owned, restorable, route, undo);
}

/// The same request, tracked as `method`: an upload token is signed the same way
/// and answered to a different place.
pub fn requestRemoteSignAs(method: RemoteMethod, gpa: std.mem.Allocator, created_at: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8, restorable: bool, route: PlaceRoute, undo: PendingUndo) void {
    // `content_owned` and `undo` are handed to the pending slot (so a timeout
    // can restore them); they are freed here only on an early return.
    var handed = false;
    defer if (!handed) releaseUndo(undo);
    // A canonical unsigned event (the bunker fills in the signature). The id is
    // computed against the user's pubkey so the bunker's result matches it.
    const id = nostr.event.computeId(gpa, g_remote_pubkey, created_at, kind, tags, content_owned) catch {
        gpa.free(content_owned);
        return;
    };
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = g_remote_pubkey,
        .created_at = created_at,
        .kind = kind,
        .tags = tags,
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch {
        gpa.free(content_owned);
        return;
    };
    defer gpa.free(unsigned_json);

    var idbuf: [24]u8 = undefined;
    const req_id = newRequestId(&idbuf) orelse {
        gpa.free(content_owned);
        return;
    };
    // Track before sending: the response can arrive on the listener thread the
    // instant the send lands, and it must find the pending slot already there.
    if (!registerPendingWith(req_id, method, content_owned, restorable, route, 0, no_half_id, WarnCarry.fromTags(tags), undo)) {
        gpa.free(content_owned);
        return;
    }
    handed = true;
    const params = [_][]const u8{unsigned_json};
    sendRequest(gpa, .{ .id = req_id, .method = "sign_event", .params = &params });
}

/// Which NIP-46 method opens this private half.
///
/// NIP-51 lets the private half be NIP-04 or NIP-44, and the two are told apart
/// by shape: a NIP-04 payload is `base64?iv=base64` and a NIP-44 one is bare
/// base64, which can never contain a `?`. Jumble and Amethyst both choose on
/// that marker. A legacy list sent to `nip44_decrypt` comes back as an error,
/// which reads as a refusal and leaves the reader with a list they can never
/// write.
pub fn isNip04Payload(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "?iv=") != null;
}

pub fn remoteDecryptMethod(payload: []const u8) RemoteMethod {
    return if (isNip04Payload(payload)) .nip04_decrypt else .nip44_decrypt;
}
/// Remote path for a private half: ask the bunker to open it.
///
/// Without this a reader signed in through an external signer could never read
/// their own encrypted list. `scanPrivateHalves` only knew how to ask the LOCAL
/// keyholder over HTTP, so on a bunker the ask went to a daemon that either is
/// not running or does not hold the key, came back not-ok, and the half was
/// marked refused forever. `writeMute` then refused every mute write, because
/// a private half that is present and unreadable is exactly the case it will
/// not publish over. So the safety guard was firing correctly on a question
/// that was never actually asked of the right signer.
///
/// The peer is the reader's own pubkey: NIP-51 encrypts a private half to
/// yourself, so both sides of the conversation key are this account's.
pub fn requestRemoteDecrypt(gpa: std.mem.Allocator, half_index: usize, ciphertext: []const u8) bool {
    var hexbuf: [64]u8 = undefined;
    hexLower(&hexbuf, g_remote_pubkey);
    var idbuf: [24]u8 = undefined;
    const req_id = newRequestId(&idbuf) orelse return false;
    const method = remoteDecryptMethod(ciphertext);
    if (!registerPending(req_id, method, null, false, .none, @intCast(half_index), privateHalfId(ciphertext), .{})) return false;
    const params = [_][]const u8{ &hexbuf, ciphertext };
    sendRequest(gpa, .{ .id = req_id, .method = @tagName(method), .params = &params });
    return true;
}

/// Remote path for a seal: ask the bunker to encrypt a private half to this
/// reader's own key. The answer completes the bookmark write.
pub fn requestRemoteEncrypt(gpa: std.mem.Allocator, plaintext: []const u8) bool {
    var hexbuf: [64]u8 = undefined;
    hexLower(&hexbuf, g_remote_pubkey);
    var idbuf: [24]u8 = undefined;
    const req_id = newRequestId(&idbuf) orelse return false;
    if (!registerPending(req_id, .nip44_encrypt, null, false, .none, 0, no_half_id, .{})) return false;
    const params = [_][]const u8{ &hexbuf, plaintext };
    sendRequest(gpa, .{ .id = req_id, .method = "nip44_encrypt", .params = &params });
    return true;
}

/// Serializes `request` and spawns a one-shot thread to seal and publish it.
pub fn sendRequest(gpa: std.mem.Allocator, request: nostr.nip46.Request) void {
    // `networkAllowed` and not `relayFetchAllowed`: the two say different
    // things. This one asks only "may I touch the network", which is the whole
    // of the concern here. Signing does not read the store and must not start
    // depending on one existing.
    if (!networkAllowed()) return;
    const req_json = request.toJson(gpa) catch return;
    var id_buf: [24]u8 = undefined;
    const id_len = @min(request.id.len, id_buf.len);
    @memcpy(id_buf[0..id_len], request.id[0..id_len]);
    const thread = std.Thread.spawn(.{}, nip46Send, .{ gpa, req_json, id_buf, id_len }) catch {
        gpa.free(req_json);
        return;
    };
    thread.detach();
}

/// Seals `req_json` to the remote signer and publishes it on a throwaway
/// connection to the bunker relay. Owns `req_json`. Its own io and signer.
fn nip46Send(gpa: std.mem.Allocator, req_json: []const u8, req_id: [24]u8, req_id_len: usize) void {
    defer gpa.free(req_json);
    const client_kp = g_remote_client_kp orelse return;
    sendNip46(gpa, req_json, client_kp) catch {
        // A request that could not even be put on the wire has no answer
        // coming, so its slot is flagged failed now rather than left to run out
        // its thirty seconds. The tick retires it the same way it retires a
        // refusal.
        _ = failPending(req_id[0..req_id_len]);
    };
}

fn sendNip46(gpa: std.mem.Allocator, req_json: []const u8, client_kp: nostr.keys.KeyPair) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const created_at = std.Io.Timestamp.now(io, .real).toSeconds();
    var sealed = try nostr.nip46.seal(gpa, io, signer, client_kp, g_remote_pubkey, req_json, created_at);
    defer sealed.deinit();

    var relay = try nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]);
    defer relay.deinit();
    // The read below waits for the relay's OK. Without a deadline a bunker
    // relay that accepts the publish and says nothing holds this thread, and
    // this is the signing path: one wedged request would be one thread gone for
    // the life of the process, every time the reader signed anything.
    const watched = watchOneShot(io, relay, one_shot_budget_ms);
    defer releaseOneShot(watched);
    try relay.publish(sealed.event);
    // Read the relay's OK so the frame flushes before we close; best-effort.
    var msg = (relay.receive() catch return) orelse return;
    msg.deinit();
}

/// The response listener: holds the bunker relay and processes responses,
/// reconnecting until its `generation` is superseded (a logout or a reconnect
/// bumps `g_remote_generation`). Its own io backend and signer, never the UI
/// thread's.
pub fn nip46ReceiveLoop(gpa: std.mem.Allocator, generation: u64) void {
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
    // Withdrawn before the connection is freed: declared after `deinit`, so it
    // runs before it.
    defer relay.deinit();
    offerLiveRelay(bunker_watch_slot, relay);
    defer offerLiveRelay(bunker_watch_slot, null);

    var client_hex: [64]u8 = undefined;
    hexLower(&client_hex, client_kp.public_key);
    const pvals = [_][]const u8{&client_hex};
    const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &pvals }};
    const kinds = [_]u16{nostr.nip46.kind};
    // FROM THE SIGNER, addressed to us. The `p` tag alone is not a restriction:
    // our client pubkey is on every request we publish, so anyone reading the
    // relay can address an event to it. Naming the author is what makes this
    // subscription about a conversation with one party.
    //
    // `limit = 0` asks for nothing stored. Kind 24133 is ephemeral and a relay
    // should not be keeping it, but one that does would otherwise replay a
    // previous session's answers into this one.
    const authors = [_][32]u8{g_remote_pubkey};
    const filters = [_]nostr.filter.Filter{.{
        .authors = &authors,
        .kinds = &kinds,
        .tags = &tag_filters,
        .limit = 0,
    }};
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
pub fn handleNip46Response(gpa: std.mem.Allocator, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, ev: nostr.event.Event, generation: u64) void {
    if (generation != g_remote_generation.load(.acquire)) return;
    // Only the signer this session connected to.
    //
    // A relay filter is a request, not a guarantee, and this one has to hold on
    // its own because of how NIP-44 works: the conversation key is derived from
    // the SENDER's key, so an event from anybody decrypts successfully as long
    // as they encrypted it to our client key. That key is public. Without this
    // line, a stranger who guesses the id of a request in flight can answer it,
    // and the answer is either an event we then publish from the reader's
    // machine to the reader's relays, or a failure that discards their note.
    if (!std.mem.eql(u8, &ev.pubkey, &g_remote_pubkey)) return;
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
    // Taking it also marks the connection up (see `takeAnswered`).
    const pending = takeAnswered(resp.value.id) orelse return;
    defer if (pending.content) |c| gpa.free(c);

    g_remote_sign_notice.store(false, .release);

    switch (pending.method) {
        // The connect ack is a plain "ack" string; the status above is the point.
        .connect => {},
        // The plaintext of a private half. Parked for the UI tick rather than
        // written straight into `g_private_halves`, which the view reads every
        // frame and `scanPrivateHalves` writes on the other thread.
        .nip44_encrypt => {
            pendingLock();
            defer pendingUnlock();
            const n = @min(resp.value.result.len, g_seal_inbox.buf.len);
            @memcpy(g_seal_inbox.buf[0..n], resp.value.result[0..n]);
            g_seal_inbox.len = @intCast(n);
            g_seal_inbox.used = true;
            g_seal_inbox.ok = n > 0;
        },
        .nip44_decrypt, .nip04_decrypt => {
            pendingLock();
            defer pendingUnlock();
            for (&g_half_inbox) |*box| {
                if (box.used) continue;
                const n = @min(resp.value.result.len, box.plain_buf.len);
                box.* = .{ .used = true, .index = pending.half_index, .half_id = pending.half_id, .ok = true, .plain_len = @intCast(n) };
                @memcpy(box.plain_buf[0..n], resp.value.result[0..n]);
                break;
            }
        },
        // A relay's NIP-42 challenge, signed. Never published and never stored:
        // it goes to the one relay that asked, by way of the slot that is
        // waiting for it, and `authDeliverSigned` checks it before it can.
        .sign_auth => {
            var parsed = nostr.event.fromJson(gpa, resp.value.result) catch {
                authFailSigning(pending.half_index);
                return;
            };
            defer parsed.deinit();
            authDeliverSigned(gpa, signer, pending.half_index, parsed.value);
        },
        // An upload token: checked here, parked for the tick, never stored.
        .sign_upload_auth => {
            var parsed = nostr.event.fromJson(gpa, resp.value.result) catch {
                parkUploadSign(null);
                return;
            };
            defer parsed.deinit();
            const sound = std.mem.eql(u8, &parsed.value.pubkey, &g_remote_pubkey) and
                (nostr.event.verify(gpa, signer, parsed.value) catch false);
            if (!sound) {
                parkUploadSign(null);
                return;
            }
            const json = nostr.event.toJson(gpa, parsed.value) catch {
                parkUploadSign(null);
                return;
            };
            defer gpa.free(json);
            parkUploadSign(json);
        },
        .sign_event => {
            var parsed = nostr.event.fromJson(gpa, resp.value.result) catch return releaseUndo(pending.undo);
            defer parsed.deinit();
            // Signed as the account we asked it to sign as. The verify further
            // down the write path checks that an event's signature matches its
            // OWN pubkey, which a stranger's event also satisfies, so this is
            // the check that says the note is this reader's.
            if (!std.mem.eql(u8, &parsed.value.pubkey, &g_remote_pubkey)) return releaseUndo(pending.undo);
            // A process-lifetime copy of the content: `parsed` is freed on
            // return, but the detached publisher reads it afterwards. Our
            // composer produces tagless kind:1 notes, so an empty tag set still
            // matches the signed id, and the write seam verifies that before
            // trusting it into the feed.
            const owned = gpa.dupe(u8, parsed.value.content) catch return releaseUndo(pending.undo);
            var out = parsed.value;
            out.content = owned;
            // Preserve the signed tags (a reaction carries e/p/k); forcing them
            // empty would make the id not match, and the verify below would drop
            // it. Deep-copied because `parsed` is freed on return.
            // Whole, or not published: the id is computed over these tags, so
            // a partial copy is an event the verify below would drop anyway.
            out.tags = dupeTags(gpa, parsed.value.tags) orelse return releaseUndo(pending.undo);
            // Signed, so there is nothing to take back. Same reasoning as the
            // built-in signer's: released on the signature, not on the ingest.
            // This request's own record, never another one still out.
            releaseUndo(pending.undo);
            ingestAndPublish(gpa, out, signer, pending.route);
        },
    }
}

/// UI-thread sweep of the pending table (called each tick): a request that
/// failed or ran past its deadline is retired here, where the composer can be
/// touched. A timed-out or refused `sign_event` restores its draft (only into
/// an empty composer, so a newer draft is never clobbered) and shows a notice;
/// a `connect` that never returned fails the connection status. A slot from a
/// superseded generation (logout/reconnect) is dropped silently.
pub fn scanPendingRemote(model: *Model, fx_for_seal: *Effects) void {
    const now = nowSeconds();
    const gpa = std.heap.page_allocator;
    const generation = g_remote_generation.load(.acquire);
    var restore: ?[]const u8 = null;
    var restore_warn: WarnCarry = .{};
    var sign_failed = false;
    // Each failed sign's own record, put back after the lock is released.
    var undos: [max_pending_remote]PendingUndo = undefined;
    var undos_len: usize = 0;
    var connect_failed = false;
    var seal_failed = false;
    var upload_sign_failed = false;

    pendingLock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        const stale = slot.generation != generation;
        const due = slot.failed or now >= slot.deadline_s;
        if (!stale and !due) continue;
        const method = slot.method;
        const content = slot.content;
        const slot_half = slot.half_index;
        const slot_half_id = slot.half_id;
        const slot_explicit = slot.failed;
        const slot_restorable = slot.restorable;
        const slot_warn = slot.warn;
        const slot_undo = slot.undo;
        slot.* = .{};
        if (stale) {
            if (content) |c| gpa.free(c);
            // The session it belonged to is gone, and the state it would put
            // back went with it.
            releaseUndo(slot_undo);
            // An ask that died with its session leaves the half "asking"
            // forever, and nothing would ask again: the reader's list would
            // stay read-only until a restart. Back to idle, so the next tick
            // asks. Only the half that ask was about: the slot may belong to
            // another list by now.
            if (method == .nip44_decrypt or method == .nip04_decrypt) {
                if (halfAwaiting(slot_half, slot_half_id)) |h| h.state = .idle;
            }
            continue;
        }
        switch (method) {
            .sign_event => {
                // The composer holds one draft: keep the first restorable one,
                // free the rest. A reaction's content is not restorable, so it
                // is freed and its failure stays silent.
                if (content) |c| {
                    if (slot_restorable and restore == null) {
                        restore = c;
                        restore_warn = slot_warn;
                    } else gpa.free(c);
                }
                if (slot_restorable) sign_failed = true;
                // Any failed signature, restorable or not, may have been a
                // follow press whose list already moved: this one's own.
                undos[undos_len] = slot_undo;
                undos_len += 1;
            },
            .connect => {
                if (content) |c| gpa.free(c);
                connect_failed = true;
            },
            // A token the bunker refused or never answered. The upload card says
            // so; there is no draft to give back.
            .sign_upload_auth => {
                if (content) |c| gpa.free(c);
                upload_sign_failed = true;
            },
            // Refused or never answered. NOT "the half is empty": that
            // distinction is the whole reason this cache exists, and collapsing
            // the two is what publishes an empty content over somebody's
            // private list.
            //
            // An error from the bunker is a "no" and waits for a press. A
            // deadline that passed is a silence: the prompt may be sitting
            // unseen on a phone, or the answer lost on the way, so the half
            // is asked again once `private_half_retry_s` has passed.
            .nip44_decrypt, .nip04_decrypt => {
                if (content) |c| gpa.free(c);
                if (halfAwaiting(slot_half, slot_half_id)) |h| {
                    h.state = .refused;
                    h.retry_at_s = if (slot_explicit) 0 else now + private_half_retry_s;
                }
            },
            // A seal the bunker refused or never answered. The list is left
            // exactly as it was, which is the only safe outcome: the reader
            // still has every private bookmark they had.
            .nip44_encrypt => {
                if (content) |c| gpa.free(c);
                seal_failed = true;
            },
            // The relay's challenge goes unanswered and the row says so.
            .sign_auth => {
                if (content) |c| gpa.free(c);
                authFailSigning(slot_half);
            },
        }
    }
    // Answers that came back while the listener held them. Applied here so
    // every write to `g_private_halves` happens on this thread.
    var opened = false;
    for (&g_half_inbox) |*box| {
        if (!box.used) continue;
        // Only into the half that was asked: a slot freed by a sign-out and
        // taken by another list is not this answer's home.
        if (halfAwaiting(box.index, box.half_id)) |h| {
            if (box.ok and box.plain_len > 0) {
                const n = @min(box.plain_len, h.plain_buf.len);
                @memcpy(h.plain_buf[0..n], box.plain_buf[0..n]);
                h.plain_len = @intCast(n);
                h.state = .open;
                opened = true;
            } else {
                h.state = .refused;
            }
        }
        std.crypto.secureZero(u8, &box.plain_buf);
        box.* = .{};
    }
    // The bunker's ciphertext, if one arrived. Applied here so the splice and
    // the publish happen on this thread, like every other write.
    var sealed: ?[]const u8 = null;
    var sealed_buf: [4096]u8 = undefined;
    if (g_seal_inbox.used) {
        if (g_seal_inbox.ok and g_seal_inbox.len > 0) {
            @memcpy(sealed_buf[0..g_seal_inbox.len], g_seal_inbox.buf[0..g_seal_inbox.len]);
            sealed = sealed_buf[0..g_seal_inbox.len];
        } else seal_failed = true;
        g_seal_inbox = .{};
    }
    pendingUnlock();
    if (sealed) |ciphertext| finishPrivateBookmark(model, fx_for_seal, ciphertext);
    if (seal_failed) {
        private_lists.g_private_seal = .{};
        setToast(model, "Your signer did not seal that. Nothing was sent.");
    }
    if (opened) {
        // The set was read with this half closed, so it is short by whatever
        // was in it. Read it again now that it can be.
        loadMutesFromStore();
        loadBookmarksFromStore();
        invalidateFeed();
    }

    if (restore) |c| {
        if (model.draft_empty()) {
            setPlain(compose_capacity, &model.draft_buffer, c);
            restore_warn.restoreInto(model);
        }
        gpa.free(c);
    }
    if (sign_failed) g_remote_sign_notice.store(true, .release);
    for (undos[0..undos_len]) |u| applyUndo(model, u);
    if (upload_sign_failed) uploadSignFailed();
    if (connect_failed and g_remote_status.load(.acquire) == 1) g_remote_status.store(3, .release);
}

/// Lowercase-hex-encodes a 32-byte key into `out`.
pub fn hexLower(out: *[64]u8, bytes: [32]u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
}

/// Pretends the key is held by Notary, by a remote signer, or by Plaza itself.
/// Pretends this session connected to `pubkey`'s bunker.
pub fn setRemotePubkeyForTest(pubkey: [32]u8) void {
    g_remote_pubkey = pubkey;
}

/// Hands one NIP-46 response event to the listener's handler, as a relay would.
/// The generation is the live one, so only the checks under test can reject it.
pub fn deliverNip46ResponseForTest(
    signer: nostr.keys.Signer,
    client_kp: nostr.keys.KeyPair,
    ev: nostr.event.Event,
) void {
    handleNip46Response(
        std.heap.page_allocator,
        signer,
        client_kp,
        ev,
        g_remote_generation.load(.acquire),
    );
}

// Test seams for the NIP-46 pending-request table (the correlation and teardown
// logic), exercised without threads or a live bunker.
pub const RemoteMethodForTest = RemoteMethod;
pub fn registerPendingForTest(req_id: []const u8, method: RemoteMethod, content: ?[]const u8) bool {
    return registerPending(req_id, method, content, content != null, .none, 0, no_half_id, .{});
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
/// Marks the pending sign whose draft is `content` failed, as a refusal or a
/// timeout would, so a test can pick WHICH of several signs comes back.
pub fn failPendingByContentForTest(content: []const u8) bool {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (!slot.active or slot.method != .sign_event) continue;
        const c = slot.content orelse continue;
        if (!std.mem.eql(u8, c, content)) continue;
        slot.failed = true;
        return true;
    }
    return false;
}
pub fn bumpRemoteGenerationForTest() void {
    _ = newRemoteGeneration();
}
pub fn scanPendingRemoteForTest(model: *Model, fx: *Effects) void {
    scanPendingRemote(model, fx);
}
pub fn remoteSignNoticeForTest() bool {
    return g_remote_sign_notice.load(.acquire);
}
/// Whether any parked bunker answer is still waiting for the tick, or still
/// holds plaintext.
pub fn halfInboxHoldsForTest() bool {
    pendingLock();
    defer pendingUnlock();
    for (&g_half_inbox) |*box| {
        if (box.used or box.plain_len != 0) return true;
    }
    return false;
}

/// A decrypt request registered for the half in `index`, with no outcome yet,
/// as `requestRemoteDecrypt` does.
pub fn registerRemoteHalfAskForTest(index: u8, method: RemoteMethod) bool {
    return registerPending("halfask", method, null, false, .none, index, slotIdForTest(index), .{});
}
/// Starts connecting to a bunker the way `connectRemoteSigner` does, without a
/// socket or a thread: the connection state is set, nobody is signed in, and a
/// `connect` request is waiting for its answer. Returns that request's id. For
/// tests.
pub fn beginBunkerConnectForTest(pubkey: [32]u8, id_out: *[24]u8) []const u8 {
    g_remote_pubkey = pubkey;
    keyholder.g_signer_kind = .remote;
    g_remote_status.store(1, .release);
    g_remote_sign_notice.store(false, .release);
    g_remote_confirming.store(true, .release);
    login.g_login_error.store(@intFromEnum(LoginError.none), .release);
    _ = g_remote_generation.fetchAdd(1, .monotonic);
    const id = "connect-for-test";
    @memcpy(id_out[0..id.len], id);
    _ = registerPending(id, .connect, null, false, .none, 0, no_half_id, .{});
    return id_out[0..id.len];
}
/// The id of the `connect` request a pasted link left waiting, if any. For
/// tests.
pub fn pendingConnectIdForTest(out: *[24]u8) ?[]const u8 {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and slot.method == .connect) {
            @memcpy(out[0..slot.id_len], slot.id());
            return out[0..slot.id_len];
        }
    }
    return null;
}

/// What the listener does with a `connect` answer from the signer. For tests.
pub fn answerBunkerConnectForTest(id: []const u8) void {
    _ = takeAnswered(id);
}

/// Whether the pairing secret `needle` is still anywhere in the buffer that
/// held it, or a client key is still held. For tests.
pub fn remoteSecretHeldForTest(needle: []const u8) bool {
    if (g_remote_client_kp != null) return true;
    return std.mem.indexOf(u8, &g_remote_secret_buf, needle) != null;
}

/// Which listener generation is current, so a test can see one was stopped.
/// For tests.
pub fn remoteGenerationForTest() u64 {
    return g_remote_generation.load(.acquire);
}

pub fn connectWentQuietForTest() bool {
    return connectWentQuiet();
}

pub fn driveBunkerConnectForTest(model: *Model) void {
    driveBunkerConnect(model);
}

/// Puts every piece of bunker state back to a guest's. For tests.
pub fn resetBunkerConnectForTest() void {
    abandonRemoteSigner(.none);
    g_remote_confirming.store(false, .release);
}
pub fn remoteDecryptMethodNameForTest(payload: []const u8) []const u8 {
    return @tagName(remoteDecryptMethod(payload));
}

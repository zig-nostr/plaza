//! The bundled keyholder: starting it, the first-run ceremony, and signing through it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const follows = @import("follows.zig");
const own_lists = @import("own_lists.zig");
const blossom = @import("blossom.zig");
const remote_signer = @import("remote_signer.zig");
const feed_state = @import("feed_state.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const giveDraftBack = main.giveDraftBack;
const PendingUndo = main.PendingUndo;
const copyBounded = main.copyBounded;
const Effects = main.Effects;
const Model = main.Model;
const PlaceRoute = main.PlaceRoute;
const WarnCarry = main.WarnCarry;
const abbreviateNpub = main.abbreviateNpub;
const acceptUploadAuth = main.acceptUploadAuth;
const activePubkey = main.activePubkey;
const applyUndo = main.applyUndo;
const compose_capacity = main.compose_capacity;
const draftWarningOf = main.draftWarningOf;
const dupeTags = main.dupeTags;
const enterFeed = main.enterFeed;
const ingestAndPublish = main.ingestAndPublish;
const invalidateFeed = main.invalidateFeed;
const nowSeconds = main.nowSeconds;
const parseMetadataInto = main.parseMetadataInto;
const pendingHasRoom = main.pendingHasRoom;
const pendingLock = main.pendingLock;
const pendingUnlock = main.pendingUnlock;
const persistSession = main.persistSession;
const plazaDir = main.plazaDir;
const releaseUndo = main.releaseUndo;
const replayPending = main.replayPending;
const saveDraft = main.saveDraft;
const setPlain = main.setPlain;
const setToast = main.setToast;
const uploadSignFailed = main.uploadSignFailed;
const upsertProfile = main.upsertProfile;

// Plaza's local identity: the keypair that signs composed notes. Loaded in
// `main` (returning user) or created by the onboarding action, both on the UI
// thread, and read only there, so no synchronisation is needed. The signer holds
// a secp256k1 context (not shared across threads); the publish path never signs,
// it forwards an already-signed event, so it needs neither. This is the
// zero-config local signer; connecting an external signer (Notary, over NIP-46,
// so the key never touches the client) is the next onboarding option, and swaps
// in at `signAndPublish` below.
pub var g_identity_npub_buf: [24]u8 = undefined;
pub var g_identity_npub_len: usize = 0;

// How composed notes are signed: with the local key, or remotely over NIP-46 by
// an external signer (Notary) so the secret key never enters Plaza. `submitPost`
// branches on this; it is set once during onboarding.
/// Where the signature comes from. There is no third answer any more.
///
/// `local` used to mean a secret key in THIS process. Plaza does not hold one:
/// file permissions separate users, not apps, so a key this app wrote down was
/// readable by every app on the machine, and the one thing a nostr identity
/// cannot survive is being copied.
///
/// The default is `helper` with no identity adopted, which is what a guest is.
const SignerKind = enum { remote, helper };
pub var g_signer_kind: SignerKind = .helper;
// ------------------------------------------------- the isolated signer helper
//
// Notary's daemon holds the key in a separate PROCESS, reached over loopback.
// Plaza spawns it at launch, writes it a 0600 bearer token, and (for now)
// health-checks it; routing the actual signing through it comes next. The port
// is Plaza-specific (not notary's 8787), so a standalone Notary and the
// built-in one never collide.
/// The port Plaza's own daemon landed on, learned from its stdout.
///
/// Zero until it says so. It used to be a constant, chosen to avoid colliding
/// with a standalone Notary on 8787, and a constant is exactly what something
/// else can sit on first.
pub var g_helper_port: u16 = 0;

/// The one line of the daemon's stdout Plaza reads. Must match
/// `approval_http.port_line_prefix` in Notary.
pub const helper_port_prefix = "notary-approval-port";
const helper_spawn_key: u64 = 40;
pub const helper_poll_key: u64 = 41;
// The daemon binary (a sibling of Plaza's own executable) and the shared token,
// resolved once in main and read by boot/tick.
var g_helper_bin_buf: [1024]u8 = undefined;
var g_helper_bin_len: usize = 0;
pub var g_helper_secret_buf: [64]u8 = undefined;
pub var g_helper_secret_len: usize = 0;
/// What the keyholder last said about itself.
///
/// Four values, and the fourth is the one that was missing: LOCKED, meaning it
/// holds a key it cannot use yet. Plaza tested only for "ready" and read
/// everything else as "reachable, no key here", so a locked Notary read as an
/// empty one. The library's own contract names that as the mistake worth
/// designing against: a client that believes a keyholder is empty offers to
/// make a key over the top of an identity somebody already has, and a nostr key
/// cannot be replaced.
///
/// Nothing was destroyed, because Notary refuses a second setup. But the reader
/// pressed "Create your identity", got a toast, and was never offered the one
/// thing that would have worked, which is to unlock.
pub const HelperState = enum(u8) {
    starting = 0,
    /// Reachable, holds no key. Ready to be set up.
    empty = 1,
    /// Reachable, holds a key, signing.
    ready = 2,
    /// Not answering.
    unreachable_ = 3,
    /// Reachable, holds a key it cannot use until somebody unlocks it.
    locked = 4,
};
pub var g_helper_state = std.atomic.Value(u8).init(0);

pub fn helperState() HelperState {
    return @enumFromInt(g_helper_state.load(.acquire));
}
/// When the signed-in health check last ran, and how often it may run. The
/// signed-out poll is every tick (it is waiting for a key to appear); this is the
/// quieter beat that keeps the status bar honest afterwards.
var g_helper_polled_at: i64 = 0;
const helper_health_interval_s: i64 = 5;
fn helperBin() []const u8 {
    return g_helper_bin_buf[0..g_helper_bin_len];
}
/// The secret, without the newline the pipe carries, for the auth header.
pub fn helperToken() []const u8 {
    if (g_helper_secret_len == 0) return "";
    return g_helper_secret_buf[0 .. g_helper_secret_len - 1];
}

/// Whether the launch probe found the keyholder daemon beside Plaza.
///
/// `.unprobed` is not a third answer, it is "nobody has looked yet", and it
/// reads as present on purpose: the probe runs in `main` before the first view,
/// so the only build that sees this value is the test binary, and a suite that
/// never launches an app should not render every join screen as a broken
/// install.
const KeyholderProbe = enum { unprobed, found, missing };
pub var g_keyholder: KeyholderProbe = .unprobed;

/// True when the daemon that would hold the key is not installed beside Plaza.
///
/// Worth a separate word from the daemon being unreachable, which is what
/// `g_helper_state` tracks. Unreachable is a moment: the daemon takes a beat to
/// come up, and `g_helper_setup` exists to hold an intent until it answers.
/// Missing is permanent and known at launch, so anything that queues and waits
/// on it is a button that does nothing, forever, with no way for the reader to
/// find out why.
pub fn keyholderMissing() bool {
    return g_keyholder == .missing;
}

/// Records that there is no keyholder.
///
/// Only the flag. It is tempting to settle `g_helper_state` here as well, since
/// with no daemon the health check never runs and that state is pinned at its
/// initial 0 forever. But every reader of it already treats 0 and "unreachable"
/// alike, so the store would change nothing that any test could tell apart, and
/// a second mechanism nothing can distinguish from its absence is not a
/// safeguard. The one reader that DID read 0 wrongly is `signerStatus`, and it
/// asks this question directly now.
fn markKeyholderMissing() void {
    g_keyholder = .missing;
}
/// The directory holding Plaza's own executable, which is where both helper
/// binaries ship.
///
/// NOT `dirname(argv[0])`. argv[0] is whatever the launcher felt like passing:
/// a PATH lookup hands over a bare name with no directory in it at all, and a
/// symlink hands over the link's directory rather than the bundle's. Both send
/// the probe below looking somewhere the helpers were never installed, and the
/// answer it comes back with is "this install has no keyholder" about an install
/// that is perfectly fine. `executableDirPath` asks the OS where this process
/// actually came from, and follows symlinks to get there.
pub fn exeDir(io: std.Io, buf: []u8) ?[]const u8 {
    const n = std.process.executableDirPath(io, buf) catch return null;
    return buf[0..n];
}

/// Writes `dir/name` into `out` if that file is there, and returns its length;
/// 0 when it is not.
///
/// The access check is the whole point. Formatting a path is not finding a
/// binary, and a spawn of a file that is not there is reported on stderr and
/// nowhere else, so the app carries on believing it has a helper it does not
/// have. That is precisely how a bundle shipped with no keyholder in it.
pub fn resolveSibling(io: std.Io, out: []u8, dir: []const u8, name: []const u8) usize {
    const path = std.fmt.bufPrint(out, "{s}/{s}", .{ dir, name }) catch return 0;
    std.Io.Dir.cwd().access(io, path, .{}) catch return 0;
    return path.len;
}
/// Resolves the daemon (a sibling of Plaza's own executable, so it works both
/// from the dev tree and a packaged bundle) and mints the secret it is handed
/// writes it 0600 under ~/.plaza.
///
/// When the daemon is not there, this returns having set NOTHING: no path, no
/// token, no state dir. Every caller downstream is already guarded on one of
/// those being empty, so a missing keyholder becomes a quiet no-op at the effect
/// layer and a said-out-loud one in the join ladder, rather than a spawn of a
/// path that does not exist.
pub fn resolveHelper(init: std.process.Init) void {
    // The daemon lives beside Plaza's own executable. It is Notary's, not a
    // second signer of Plaza's own: one keyholder, built and audited once.
    var dir_buf: [1024]u8 = undefined;
    const dir = exeDir(init.io, &dir_buf) orelse return markKeyholderMissing();
    g_helper_bin_len = resolveSibling(init.io, &g_helper_bin_buf, dir, "signer");
    if (g_helper_bin_len == 0) {
        // Dev tree: Notary's checkout beside this one. Plaza's build does not
        // produce a keyholder any more, so without this a developer run has no
        // signer at all and every sign silently dead-ends.
        g_helper_bin_len = resolveSibling(init.io, &g_helper_bin_buf, dir, "../../../notary/daemon/zig-out/bin/signer");
    }
    if (g_helper_bin_len == 0) return markKeyholderMissing();
    g_keyholder = .found;

    // The secret Plaza hands its daemon, minted here and written NOWHERE.
    //
    // It used to be a token in a 0600 file, which is the shape every local
    // signing agent uses and the shape none of them defends. File permissions
    // separate USERS, not apps: every app you run could read that file and
    // sign as you. Measured on this machine, along with the two other places a
    // secret leaks: a process's argv (`ps` prints it) and its environment
    // (`ps -Eww` prints it).
    //
    // A pipe to a child has none of those properties. It has no name and no
    // path, so there is nothing for another program to open, and holding it is
    // the whole of the proof. That is why Plaza starts its own daemon rather
    // than looking for a shared one: a keyholder anything can reach has to
    // decide who may reach it, and nobody has solved that on the desktop.
    var raw: [24]u8 = undefined;
    init.io.randomSecure(&raw) catch return;
    const written = std.fmt.bufPrint(&g_helper_secret_buf, "{x}\n", .{raw}) catch return;
    g_helper_secret_len = written.len;
}

// The Notary ceremony window binary. In a packaged app it sits beside Plaza in
// Contents/MacOS; in the dev tree it is the sub-project's own build output.
pub var g_notary_win_buf: [1024]u8 = undefined;
pub var g_notary_win_len: usize = 0;
const notary_spawn_key: u64 = 44;
// Set on logout, so the health-check does not hand the key straight back.
// Cleared when the reader explicitly signs in again.
pub var g_logged_out: bool = false;

/// WHICH key signed out.
///
/// The bare latch above was not enough on its own: `beginCreate` clears it, and
/// one second later the poll re-adopted the account the reader had just left,
/// their create failed as already-initialized with nothing on screen saying so,
/// and the next note went out under the old identity.
///
/// It matters more now, not less. Signing out of Plaza leaves the key in
/// Notary, so `/pubkey` reports that key on every poll for as long as it is
/// there. "Signed out" is a fact this app has to remember for itself rather
/// than something the keyholder will ever confirm, and a pubkey is the precise
/// version of it: re-importing the SAME key deliberately still signs in.
pub var g_logged_out_pk: ?[32]u8 = null;

pub fn resolveNotaryWindow(init: std.process.Init) void {
    var dir_buf: [1024]u8 = undefined;
    const dir = exeDir(init.io, &dir_buf) orelse return;
    // Notary's OWN window, not a second one of Plaza's. Bringing a key is the
    // one thing Plaza deliberately cannot do: the key never touches this
    // process, so the screen that receives it belongs to the app that holds it.
    //
    // Packaged: a sibling. Dev: Notary's checkout beside this one, because it
    // is built by a separate build.zig and never lands in Plaza's bin
    // directory. Sibling first, that being the shipped layout.
    g_notary_win_len = resolveSibling(init.io, &g_notary_win_buf, dir, "notary");
    if (g_notary_win_len != 0) return;
    g_notary_win_len = resolveSibling(init.io, &g_notary_win_buf, dir, "../../../notary/gui/zig-out/bin/notary");
}

/// Whether there is a Notary holding this account's key AND a window to show it
/// in. Both halves matter: a remote signer is somebody else's process on
/// somebody else's machine and Notary has nothing to say about it, and an
/// install that arrived without the window would offer a press that opens
/// nothing.
pub fn openNotaryAvailable() bool {
    return g_signer_kind == .helper and g_notary_win_len > 0;
}

/// Whether the ceremony window is the right place to take a pasted key. Not
/// when there is no window, and not when there is no daemon behind it either:
/// handing the paste to the keyholder is the window's entire job, so with no
/// keyholder it is a window that can only fail, over a key the reader typed
/// correctly. The in-Plaza field is the honest destination then.
pub fn ceremonyCanTakeKey() bool {
    return g_notary_win_len > 0 and !keyholderMissing();
}
/// What the Notary window is being opened for. `status` is not a ceremony at
/// all: it makes no key, takes none and resets none, it only asks the daemon
/// what it is holding. It shares the spawn key with the two that are ceremonies,
/// so there is never more than one Notary window on screen.
const Ceremony = enum { import_key, create_key, status };

/// Opens the Notary ceremony window: a separate process, so key material never
/// enters Plaza on either path. The window reads the token itself and talks to
/// the daemon; Plaza adopts the identity when the key appears (see
/// handleHelperPubkey).
///
/// The window OWNS its ceremony, including the create. It would be less code for
/// Plaza to mint the key and let the window merely announce it, but only the side
/// that made the request can tell a key it just minted from a key that was
/// already sitting in the daemon: a window watching /pubkey sees "ready" either
/// way, and would introduce somebody's leftover key as the reader's new identity.
/// Where this app's keyholder is listening, written down for the whole process
/// so it can be handed to the window as an argv value.
var g_notary_addr_buf: [32]u8 = undefined;
var g_notary_addr_len: usize = 0;

/// Opens the key window ON THIS APP'S KEYHOLDER, or does not open it at all.
///
/// Returns false when the keyholder has not reported its port yet, and the
/// caller says so. Opening anyway is what produced the bug this exists for: the
/// window went looking for a keyholder of its own and, in a packaged app where
/// `signer` sits beside it, started a SECOND one. The reader then unlocked a
/// keyholder this app was not using, and sat in guest mode with their key right
/// there. Restarting did it again, because it does the same thing every time.
pub fn spawnNotaryWindow(fx: *Effects, ceremony: Ceremony) bool {
    if (g_notary_win_len == 0) return false;
    const bin = g_notary_win_buf[0..g_notary_win_len];
    // No port, no window. There is no safe fallback: the fallback IS the bug.
    if (g_helper_port == 0 or g_helper_secret_len == 0) return false;
    const addr = std.fmt.bufPrint(&g_notary_addr_buf, "127.0.0.1:{d}", .{g_helper_port}) catch return false;
    g_notary_addr_len = addr.len;
    const address = g_notary_addr_buf[0..g_notary_addr_len];
    // The secret goes down the pipe, never into argv: `ps` prints argv to every
    // program running as this user, and this is the one credential that lets
    // anything reach the keyholder.
    const secret = g_helper_secret_buf[0..g_helper_secret_len];
    // Two calls rather than one with a computed argv: `&.{...}` over runtime
    // values is a pointer to a temporary, and handing the effect layer one that
    // outlives its scope is the kind of bug that shows up as a garbled argv on
    // somebody else's machine.
    // `on_exit` is not optional here. The SDK REJECTS a spawn whose key already
    // has a live process, and a rejection is reported through this callback and
    // nowhere else: without it, pressing "Create your identity" while a Notary
    // window is already open did nothing at all, silently, and left the reader on
    // the guest feed having pressed the app's primary call to action.
    switch (ceremony) {
        .import_key => fx.spawn(.{
            .key = notary_spawn_key,
            .argv = &.{ bin, "--approval-http", address },
            .stdin = secret,
            .output = .collect,
            .on_exit = Effects.exitMsg(.notary_exited),
        }),
        .create_key => fx.spawn(.{
            .key = notary_spawn_key,
            .argv = &.{ bin, "--approval-http", address, "--create" },
            .stdin = secret,
            .output = .collect,
            .on_exit = Effects.exitMsg(.notary_exited),
        }),
        .status => fx.spawn(.{
            .key = notary_spawn_key,
            .argv = &.{ bin, "--approval-http", address, "--status" },
            .stdin = secret,
            .output = .collect,
            .on_exit = Effects.exitMsg(.notary_exited),
        }),
    }
    return true;
}

/// What the ceremony window did, learned when it goes.
///
/// Every route out of the window lands here: a mint, an import, a cancel, a
/// failure, a crash, and a spawn that never started because one was already
/// running. Only the first arms the name beat.
pub fn handleNotaryExited(model: *Model, e: native_sdk.EffectExit) void {
    const was_running = g_ceremony;
    g_ceremony = .none;
    // The window is gone, so a keyholder that is locked AGAIN later may ask for
    // its passphrase again. Without this the prompt is a once-per-launch offer,
    // and a reader who signs out would never be asked a second time.
    g_unlock_prompt_open = false;

    if (e.reason == .rejected) {
        // A window is already open. Say so, whatever was being opened: a
        // rejection only ever follows a press, and an unanswered press is the
        // thing this whole list of fixes is about. It used to be said only while
        // a CEREMONY was running, so pressing "Open Notary" twice was silent.
        if (was_running == .running) g_ceremony_adopted = false;
        setToast(model, "A Notary window is already open");
        return;
    }

    const created = e.reason == .exited and e.code == ceremony_created_code;
    if (!created) {
        g_ceremony_adopted = false;
        return;
    }

    // Minted. The flag that lets a contact list be written without reading one
    // back first is set HERE, on the confirmation, and never on the press: a key
    // that was never made cannot have provably no history.
    own_lists.g_identity_minted_here = true;
    // Their own list is about to be one name long. The pack is what they have
    // been reading, so it stays what they read until they choose otherwise.
    follows.g_home_scope = .starter_pack;
    if (g_ceremony_adopted) {
        // The poll already signed the reader in, so the beat is owed now.
        g_ceremony_adopted = false;
        persistSession();
        model.naming = true;
        return;
    }
    g_ceremony = .created;
}

/// What the create ceremony has told us, which is the only thing that decides
/// whether an appearing key is one the reader just made.
///
/// This was a 90-second timer, and a timer is not an answer. It said "a key that
/// turns up soon after the Create press", which is a DIFFERENT statement from "the
/// key the ceremony made", and the gap between them was reachable: press Create,
/// have it fail (the daemon is not up yet, so the window says so and exits), then
/// press "Bring your key" and import a real account. The imported key arrived
/// inside the window, so Plaza treated it as freshly minted, offered "Want a name
/// on it?" over an account that already had one, and publishing that name rewrote
/// the account's kind:0 from an empty local profile. That is the exact shape of
/// the rule this app is built around: never write a replaceable record over data
/// you have not read back.
///
/// So the ceremony reports its own result instead. The window exits with
/// `ceremony_created_code` if and only if it minted a key, and that exit is what
/// arms the beat. A failed create, an import, a cancel and a crash all exit some
/// other way and arm nothing.
const CeremonyState = enum {
    /// No create ceremony has been asked for.
    none,
    /// The window was spawned and has not reported yet.
    running,
    /// The window minted a key and Plaza has not yet adopted it.
    created,
};
pub var g_ceremony: CeremonyState = .none;
/// A key was adopted while the ceremony was still running, so the beat is owed
/// once the window confirms what it did. The poll usually wins this race: the
/// window holds its result until the reader dismisses it and Plaza polls every
/// second, so in practice the poll always wins. The other branch is still real
/// and still tested: a reader who presses Continue inside the first second gets
/// their name beat from the exit instead.
pub var g_ceremony_adopted = false;

/// The window's exit code when, and only when, it minted a key.
const ceremony_created_code: i32 = 9;

/// Starts Plaza's own keyholder: keyless at first, idling on /pubkey and
/// /setup until somebody brings a key.
///
/// Port ZERO. There is no shared address, so there is nothing for anything else
/// to be sitting on and nothing for Plaza to be tricked into talking to; the
/// daemon says on stdout where it landed. The secret goes down the pipe, which
/// is the only channel another program running as this user cannot read.
///
/// The daemon is Plaza's CHILD and dies with it. That is not a limitation: a
/// keyholder that outlives its app is a keyholder something else can find.
/// Whether the keyholder is holding a key nobody has unlocked, and the reader
/// has not been asked about it yet this episode.
///
/// Set from the health poll, spent on the tick where an `Effects` is in hand.
/// Latched so the window opens ONCE: the poll runs every tick, and opening on
/// each one would stack windows the reader never asked for.
var g_want_unlock_prompt: bool = false;
var g_unlock_prompt_open: bool = false;

/// Opens the key window on a locked keyholder so the passphrase can be given.
///
/// Not while another ceremony is up: a reader who pressed "Bring your key" is
/// already looking at the window this would open a second copy of.
pub fn driveUnlockPrompt(fx: *Effects) void {
    if (!g_want_unlock_prompt or g_unlock_prompt_open) return;
    if (g_ceremony != .none) return;
    if (helperState() != .locked) {
        g_want_unlock_prompt = false;
        return;
    }
    // A refusal means the keyholder has not reported its port yet. Leave the
    // want set so the next poll tries again rather than losing the prompt.
    if (!spawnNotaryWindow(fx, .status)) return;
    g_unlock_prompt_open = true;
    g_want_unlock_prompt = false;
}

/// How many times this app will start its keyholder again after it goes.
///
/// A keyholder that ends is not always a failure: signing out from the key
/// window ends the process on purpose, because relay threads were handed the
/// key by value and only ending them takes it back. Before this, that left this
/// app with a dead keyholder and no way back until it was restarted, so the
/// window's own sign-out button had to be disabled to avoid causing it.
///
/// Bounded, because a keyholder that cannot start at all would otherwise be
/// started forever. Reset whenever one stays up long enough to answer.
pub const helper_restart_limit: u8 = 3;
pub var g_helper_restarts: u8 = 0;

pub fn spawnHelper(fx: *Effects) void {
    if (g_helper_bin_len == 0 or g_helper_secret_len == 0) return;
    fx.spawn(.{
        .key = helper_spawn_key,
        .argv = &.{ helperBin(), "--approval-http", "127.0.0.1:0" },
        .stdin = g_helper_secret_buf[0..g_helper_secret_len],
        .on_line = Effects.lineMsg(.helper_line),
        .on_exit = Effects.exitMsg(.helper_exited),
    });
}

/// Health-checks the daemon: GET /pubkey with the bearer token. A 200 (in any
/// state) proves the loopback IPC works; a connection error keeps it at
/// unreachable and the tick tries again.
pub fn pollHelper(fx: *Effects) void {
    if (g_helper_secret_len == 0) return;
    // Signed OUT, this proves the IPC at startup and catches a key appearing
    // later (a terminal or window import), so Plaza adopts it live: poll every
    // tick. Signed IN, the status bar now reports whether Notary can actually
    // sign, and a stale flag there would be a chip that lies, so keep polling,
    // slowly. Only for a Notary identity: a local key or a bunker has nothing on
    // the other end of this socket.
    if (activePubkey() != null) {
        if (g_signer_kind != .helper) return;
        const now = nowSeconds();
        if (now - g_helper_polled_at < helper_health_interval_s) return;
        g_helper_polled_at = now;
    }
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/pubkey", .{g_helper_port}) catch return;
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
pub fn handleHelperPubkey(model: *Model, response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status != 200) {
        g_helper_state.store(3, .release); // unreachable, keep retrying
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    const ipc = nostr.signer_ipc;
    // Three states, told apart. Anything this app does not recognise counts as
    // "cannot sign", never as "no key yet", which is the rule the contract
    // states beside the constants.
    const state: HelperState = if (std.mem.eql(u8, parsed.value.state, ipc.state_ready))
        .ready
    else if (std.mem.eql(u8, parsed.value.state, ipc.state_locked))
        .locked
    else if (std.mem.eql(u8, parsed.value.state, ipc.state_uninitialized))
        .empty
    else
        .locked;
    g_helper_state.store(@intFromEnum(state), .release);

    if (state == .locked) {
        // A locked keyholder is proof there IS a key on this Mac: it was set up
        // once and needs its passphrase again. Saying "Notary is locked" and
        // stopping there left the reader with a key they could not reach and
        // nothing to press, which reads as being signed out with extra steps.
        g_want_unlock_prompt = true;
        // It HOLDS a key. Saying nothing here is what made a locked keyholder
        // look like an empty one: the latch below is cleared only by evidence
        // that the key is really gone, and this is not that evidence.
        return;
    }
    if (state != .ready) {
        // The daemon says it holds nothing, which is the only real evidence the
        // logout's reset landed. Whatever key appears next is a new one.
        g_logged_out_pk = null;
        return;
    }

    // The daemon holds a key and Plaza is a guest: adopt it. This is how a
    // terminal or window import (which Plaza did not initiate) signs the user
    // in live. A Plaza-initiated setup is left to handleHelperSetup, which owns
    // the name beat and the remembered intent.
    if (g_logged_out) return; // a just-logged-out session must stay out
    // And the key that just left stays gone even after an explicit sign-in drops
    // that latch, until the daemon has said it no longer holds it. Pressing
    // "Create your identity" used to be enough to walk straight back into the
    // account the reader had just signed out of.
    if (g_logged_out_pk) |left| {
        var still: [32]u8 = undefined;
        if (std.fmt.hexToBytes(&still, parsed.value.pubkey)) |_| {
            if (std.mem.eql(u8, &still, &left)) {
                // Still the key this reader signed out of, and it will BE that
                // key until they remove it in Notary. Signing out of a client
                // does not take an identity off the machine, so this is the
                // expected answer rather than a reset that failed to land, and
                // the latch simply holds.
                return;
            }
        } else |_| {}
    }
    if (activePubkey() != null) return;
    if (g_helper_setup != .none or g_helper_pending_in_flight != .none) return;
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    enterFeed(model);
    switch (g_ceremony) {
        // The window has confirmed a mint, so this key is that key: nothing else
        // can be in a daemon that just accepted a create.
        .created => {
            g_ceremony = .none;
            model.naming = true; // the name beat; replay follows it
            return;
        },
        // A ceremony is open but has not said what it did yet. Sign in, and owe
        // the beat until the window reports. NOT "assume it was a create": that
        // assumption is the bug this replaced.
        .running => g_ceremony_adopted = true,
        .none => {},
    }
    replayPending(model);
}

// The signed-in identity: its PUBKEY lives here and the secret lives only in
// the keyholder. There is no field in this program that can hold a secret key.
pub var g_helper_identity_pk: [32]u8 = undefined;
pub var g_helper_has_identity = false;

// Helper setup is async and can race the daemon coming up, so an intent is
// queued and fired by the tick once the daemon is reachable. `create` mints a
// fresh key (then the name beat); `import_user` adopts a pasted nsec; `migrate`
// moves a legacy in-process key into the daemon and deletes it, silently.
const HelperSetup = enum { none, create, import_user, migrate };
pub var g_helper_setup: HelperSetup = .none;
var g_helper_setup_secret: [32]u8 = undefined;
const helper_setup_key: u64 = 42;
pub const helper_sign_key: u64 = 43;

pub fn helperReachable() bool {
    return g_helper_port != 0 and g_helper_state.load(.acquire) >= 1;
}

/// Queues a helper setup and fires it now if the daemon is already up (else the
/// tick fires it the moment the health-check confirms reachability).
fn queueHelperSetup(fx: *Effects, kind: HelperSetup, secret: ?[32]u8) void {
    g_logged_out = false; // an explicit sign-in re-enables adopt-on-appear
    g_helper_setup = kind;
    if (secret) |sk| g_helper_setup_secret = sk;
    driveHelperSetup(fx);
}

/// Fires a queued setup once the daemon is reachable. Called on the tick and
/// right after queueing.
/// Whether a queued setup may go out.
///
/// A LOCKED keyholder already holds a key, so firing a setup at it offers to
/// make one over the top of an identity somebody already has, and a nostr key
/// cannot be replaced. Notary refuses, so nothing is destroyed, but the reader
/// gets a toast where they should be getting a passphrase box.
///
/// A predicate rather than a line inside the sender, because the sender needs
/// an effects channel and a test has none.
pub fn helperSetupMayFire(queued: bool, state: HelperState) bool {
    if (!queued) return false;
    return state == .empty;
}
pub fn driveHelperSetup(fx: *Effects) void {
    if (!helperReachable()) return;
    if (!helperSetupMayFire(g_helper_setup != .none, helperState())) return;
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
pub var g_helper_pending_in_flight: HelperSetup = .none;

/// A POST to the daemon with the bearer token. The body is copied by the effect,
/// so a stack buffer is fine.
pub fn helperFetch(fx: *Effects, key: u64, comptime path: []const u8, body: []const u8, on_response: @TypeOf(Effects.responseMsg(.helper_setup))) void {
    helperFetchTimeout(fx, key, path, body, on_response, helper_sign_timeout_ms);
}

/// The same, with the wire deadline stated rather than inherited.
fn helperFetchTimeout(fx: *Effects, key: u64, comptime path: []const u8, body: []const u8, on_response: @TypeOf(Effects.responseMsg(.helper_setup)), timeout_ms: u32) void {
    // Nowhere to send it yet. The daemon takes a kernel-chosen port and says
    // which one on stdout, so between the spawn and that line there is no
    // address: sending to port zero would be a request nobody could answer and
    // a failure the caller would read as a signer that is not working.
    if (g_helper_port == 0) return;
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}" ++ path, .{g_helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = key,
        .url = url,
        .method = .POST,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .body = body,
        .timeout_ms = timeout_ms,
        .on_response = on_response,
    });
}

// A helper sign that has gone out and not come back.
//
// The remote signer has had a pending table, a deadline and a restore since the
// day it shipped. The helper had none of it, and `signAndPublish` dropped the
// `restorable` flag on the way to it, so a Notary sign that failed for any
// reason destroyed the note in silence: `submitPost` clears the composer, the
// press deletes ~/.plaza/draft, the toast says "Posted", and the response
// handler returned on its first line without a Model to restore anything into.
// Nothing was stored and nothing was queued, because the outbox is fed from
// `ingestAndPublish`, which the helper path only reaches AFTER a good signature.
//
// The daemon answers non-200 while perfectly alive: 401 with a stale token, 409
// with no key yet, 400 on a malformed event, 500 on a signing failure. It also
// dies without being respawned, and a dead port answers `connect_failed`.
//
// One slot, because the SDK refuses a second fetch on an occupied key and every
// helper sign uses the same one.
const HelperSign = struct {
    active: bool = false,
    restorable: bool = false,
    /// Where the write was submitted from, carried across the round trip: the
    /// keyholder can ask a person, and the reader can walk into another room
    /// while it waits.
    route: PlaceRoute = .none,
    failed: bool = false,
    deadline_s: i64 = 0,
    content: ?[]u8 = null,
    /// The content warning this note was signed with, so the note that comes back
    /// is handed back with ITS warning and not whichever one was set last.
    warn: WarnCarry = .{},
    /// What is out for signing is an upload token, not something to publish:
    /// its failure belongs to the upload card, not to the composer.
    upload_auth: bool = false,
    /// What this press changed, put back if the signature never comes. Owned
    /// by the slot.
    undo: PendingUndo = .none,
    /// The kind of the event out for signing.
    kind: u16 = 0,
};
pub var g_helper_sign: HelperSign = .{};

/// The tag set of the most recent event handed to a signer. Read only by tests,
/// which have no other view of the event that actually goes out.
pub var g_last_published_tags: []const nostr.event.Tag = &.{};

/// How long a sign may be out before the note is handed back.
///
/// Ten seconds was safe while the keyholder answered in about a millisecond and
/// could not do anything else. Notary can refuse and ask a person, and the
/// answer to that arrives on a human timescale. The app-side backstop and the
/// wire timeout must agree, and they did not: the fetch carried no timeout at
/// all, so the SDK's default of thirty seconds applied while this fired at ten.
///
/// What that gap does is worse than a slow note. At ten seconds Plaza restores
/// the draft and says the sign failed, while the request is still live; an
/// answer at twenty then publishes an event the reader was told had failed. For
/// those twenty seconds `signerReady` reports true because this slot is clear,
/// while the effect key is still held, so the NEXT sign is rejected by the SDK
/// and silently does nothing.
///
/// So the two are one number now, stated in both places from here.
pub const helper_sign_timeout_s: i64 = 30;
pub const helper_sign_timeout_ms: u32 = @intCast(helper_sign_timeout_s * 1000);
/// Remembers a note handed to the daemon, so a failure has something to give
/// back. Called BEFORE the request is built, because building it can fail too
/// and those paths used to lose the note just as quietly.
fn rememberHelperSign(gpa: std.mem.Allocator, content: []const u8, restorable: bool, route: PlaceRoute, warn: WarnCarry, undo: PendingUndo) void {
    releaseHelperSign();
    g_helper_sign = .{
        .active = true,
        .restorable = restorable,
        .route = route,
        .failed = false,
        .deadline_s = nowSeconds() + helper_sign_timeout_s,
        .content = if (restorable) gpa.dupe(u8, content) catch null else null,
        .warn = if (restorable) warn else .{},
        .undo = undo,
    };
}

/// Drops the slot without restoring: the signature came back.
pub fn releaseHelperSign() void {
    if (g_helper_sign.content) |c| std.heap.page_allocator.free(c);
    releaseUndo(g_helper_sign.undo);
    g_helper_sign = .{};
}

/// Marks the sign as failed. The restore itself happens on the tick, where a
/// Model is reachable, exactly as the remote path does it.
fn failHelperSign() void {
    if (!g_helper_sign.active) return;
    g_helper_sign.failed = true;
}

/// Hands a failed sign's note back to the composer and says why. The mirror of
/// `scanPendingRemote`, and called from the same tick.
pub fn scanHelperSign(model: *Model) void {
    if (!g_helper_sign.active) return;
    if (!g_helper_sign.failed and nowSeconds() < g_helper_sign.deadline_s) return;
    const restorable = g_helper_sign.restorable;
    const content = g_helper_sign.content;
    const warn = g_helper_sign.warn;
    const upload_auth = g_helper_sign.upload_auth;
    const undo = g_helper_sign.undo;
    g_helper_sign = .{};
    const gpa = std.heap.page_allocator;
    if (upload_auth) uploadSignFailed();
    if (content) |c| {
        // A reader who has started typing again keeps what they are typing,
        // first; see `giveDraftBack`.
        if (restorable) {
            switch (giveDraftBack(model, c, warn)) {
                // Said out loud, because the notice this used to rely on cannot
                // be read: its string lives in `Model.identity()`, which is
                // listed in `view_unbound` and rendered by nothing. A toast is
                // the surface every other failed write now uses.
                .restored => setToast(model, "Not signed. Your draft is back."),
                .below => setToast(model, "Not signed. It is back, under what you typed."),
                // The toast comes with the copy, on the next tick.
                .clipboard => {},
            }
            saveDraft(model.draft(), draftWarningOf(model));
        }
        gpa.free(c);
    }
    if (restorable) g_helper_sign_notice.store(true, .release);
    // Fires whether or not the note was restorable. A follow write carries no
    // draft to give back, which is exactly why its failure used to be silent.
    applyUndo(model, undo);
}

/// A helper sign that failed, surfaced once in the composer so a restored draft
/// is explained rather than silently reappearing. Cleared on the next edit or a
/// later success, the same as the remote signer's.
pub var g_helper_sign_notice = std.atomic.Value(bool).init(false);
/// The last event this app actually published, so a test can check the
/// SIGNATURE rather than only the tags.
pub var g_last_published: ?nostr.event.Event = null;
/// Whether the signer can be asked for a signature RIGHT NOW.
///
/// Every helper sign goes out on one effect key, and the SDK refuses a second
/// fetch while that key is held. The refusal is delivered as a `.rejected`
/// outcome, which used to be dropped on the first line of the response handler,
/// so the second sign of a pair simply never happened.
///
/// It is not only a race. The tick issues `flushRelayList` and
/// `drivePendingIntent` in the SAME update call, with no drain possible between
/// them, so when both are due the second is rejected every time. The callers
/// had already moved their state by then: the follow set had the new name in it
/// and the UI said "Following" for a list that was never signed.
///
/// So the callers ask first, and a "not now" leaves everything where it was.
/// Every one of them is retried by something: the relay list keeps its pending
/// edit, a press can be pressed again, and the composer keeps its draft.
pub fn signerReady() bool {
    return switch (g_signer_kind) {
        // One key, one sign. The bunker's table has eight slots keyed by request
        // id, so it does not collide, and a local key signs inline.
        .helper => !g_helper_sign.active,
        // Until all eight are taken. A sign with no slot to wait in has nowhere
        // to keep its undo, so the press is refused before it moves anything.
        .remote => pendingHasRoom(),
    };
}
/// Whether a note is with a signer right now, waiting for a signature. True for
/// both the bunker's pending table and the built-in signer's slot.
pub fn signInFlight() bool {
    if (g_helper_sign.active and g_helper_sign.restorable) return true;
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_pending) |slot| {
        if (slot.active and slot.restorable) return true;
    }
    return false;
}

/// Puts the built-in signer in the state it is in while a signature is out, so
/// a test can drive the press that lands during one.
/// Stops the test keyholder from answering, so a test can look at a note while
/// it is still out being signed.
///
/// The stand-in daemon answers instantly, which is right for the tests that
/// only want to be somebody and publish something. The ones about what happens
/// while a signature is in flight, or when it never comes back, need the answer
/// held.
pub var g_test_signer_silent: bool = false;
/// Sends one event of `kind` (with `tags`, stamped `created`) to the daemon to
/// be signed. Builds the unsigned event against the helper's own pubkey so the
/// returned id matches, wraps it, and POSTs /sign; the response is the signed
/// event, ingested and published like any other. `content_owned` and `tags` are
/// process-lifetime (the local and remote paths reference them too), so this
/// does not free them.
pub fn requestHelperSign(fx: *Effects, gpa: std.mem.Allocator, created: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8, restorable: bool, route: PlaceRoute, undo: PendingUndo) void {
    const pk = activePubkey() orelse return releaseUndo(undo);
    // Recorded first. Every `catch return` below is a path that used to end with
    // the note gone and the app saying "Posted".
    rememberHelperSign(gpa, content_owned, restorable, route, WarnCarry.fromTags(tags), undo);
    g_helper_sign.upload_auth = kind == blossom.auth_kind;
    g_helper_sign.kind = kind;
    const id = nostr.event.computeId(gpa, pk, created, kind, tags, content_owned) catch {
        failHelperSign();
        return;
    };
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = pk,
        .created_at = created,
        .kind = kind,
        .tags = tags,
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch {
        failHelperSign();
        return;
    };
    defer gpa.free(unsigned_json);
    const body = (nostr.signer_ipc.SignEvent{ .event = unsigned_json }).toJson(gpa) catch {
        failHelperSign();
        return;
    };
    defer gpa.free(body);
    // A test cannot drive the loopback: an `Effects` is not constructible
    // outside a running app, so the fetch below would fault on undefined
    // memory. It stands in for the daemon instead, and answers the way the
    // daemon does, so the response handler is exercised rather than skipped.
    // Comptime, so the shipped binary has no branch.
    if (builtin.is_test) {
        if (!g_test_signer_silent) answerHelperSignForTest(gpa, unsigned_json);
        return;
    }
    helperFetch(fx, helper_sign_key, "/sign", body, Effects.responseMsg(.helper_signed));
}

/// Adopts a helper-held identity: only the pubkey lives here, never the secret
/// (that stays in the daemon). Clears any in-UI local key.
pub fn adoptHelperIdentity(pk: [32]u8) void {
    g_helper_identity_pk = pk;
    g_helper_has_identity = true;
    g_signer_kind = .helper;
    const npub = abbreviateNpub(&g_identity_npub_buf, pk);
    g_identity_npub_len = npub.len;
    invalidateFeed();
}

/// Restores a helper identity from a persisted session pubkey. Synchronous: the
/// daemon independently loads its own key, so Plaza only needs to know who it is.
pub fn restoreHelperIdentity(pubkey_hex: []const u8) bool {
    if (pubkey_hex.len != 64) return false;
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pubkey_hex) catch return false;
    adoptHelperIdentity(pk);
    return true;
}

/// Completes an async helper setup. On a fresh create it adopts the minted
/// identity and opens the name beat; a transient failure requeues for the tick.
/// What a failed `/setup` puts on screen. The daemon's own words when it sent
/// any, because the one failure a reader can act on is a Keychain that would
/// not hold the key, and "Could not set up your key" reads like a hiccup worth
/// retrying rather than "you do not have an identity". The generic line is for
/// a daemon that answered with nothing parseable.
fn reportHelperSetupFailure(model: *Model, body: []const u8) void {
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Failure, gpa, body) catch {
        setToast(model, "Could not set up your key");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.@"error".len == 0) {
        setToast(model, "Could not set up your key");
        return;
    }
    setToast(model, parsed.value.@"error");
}

pub fn handleHelperSetup(model: *Model, response: native_sdk.EffectResponse) void {
    const purpose = g_helper_pending_in_flight;
    g_helper_pending_in_flight = .none;
    if (response.outcome != .ok) {
        g_helper_setup = purpose; // the daemon was not up; the tick retries
        return;
    }
    if (response.status != 200) {
        // A migration is a silent background upgrade: on failure the in-process
        // key keeps working, so say nothing. Foreground setups report.
        if (purpose != .migrate) reportHelperSetupFailure(model, response.body);
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    switch (purpose) {
        .create => {
            // Confirmed here, for the same reason the ceremony window's mint is
            // confirmed on its exit: the daemon has answered, so a key exists and
            // it is this one.
            own_lists.g_identity_minted_here = true;
            follows.g_home_scope = .starter_pack;
            // Persisted AGAIN, because the write above happened before the flag
            // was set and therefore recorded `minted=0`. A restart then read
            // this key back as an imported one, which is a weaker claim about a
            // key that provably has no history, and it is the difference between
            // the sign-out warning saying the key can be signed in with again
            // and saying it cannot be recovered.
            persistSession();
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

/// Starts making a key, in the Notary window.
///
/// The window is the only place a key can be made. The daemon will not mint one
/// without a passphrase, and the passphrase is typed into the window: Plaza
/// never sees it and never asks for it. There used to be a fallback that asked
/// the daemon directly when the window binary was absent, and with a passphrase
/// now mandatory the daemon answered it with a bare "passphrase required" that
/// showed for three seconds over a sheet that had already closed.
pub fn beginCreate(model: *Model, fx: *Effects) void {
    // Nothing can mint a key without the daemon that would hold it: Plaza has
    // not held one itself since the key moved out of this process. The ladder
    // says so in place of the card, but the guard belongs HERE, because this is
    // the one function every create path goes through, and what it prevents is
    // an intent queued against a binary that will never appear. A missing
    // keyholder never becomes reachable, so without this the reader's press is
    // swallowed whole and the sheet closes over nothing.
    if (keyholderMissing()) return setToast(model, "Notary is missing from this install.");
    // And the same for the window: with no window there is nowhere to type the
    // passphrase, so nothing is queued and the press says why it did nothing.
    // The toast holds 48 bytes, which this fills exactly.
    if (g_notary_win_len == 0) return setToast(model, "Notary's key window is missing from this install");
    // The ceremony is the other process's now, so what a queued setup would
    // have done has to be done here: re-enable adopt-on-appear, which a logout
    // latches off.
    g_logged_out = false;
    g_ceremony = .running;
    g_ceremony_adopted = false;
    if (!spawnNotaryWindow(fx, .create_key)) {
        g_ceremony = .none;
        setToast(model, "Your keyholder is still starting. Try again.");
    }
}

/// Deletes the legacy in-process key file, once its secret is safe in the daemon.
fn deleteIdentityKeyFile() void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    dir.deleteFile(io, "identity.key") catch {};
}
pub fn handleHelperSigned(response: native_sdk.EffectResponse) void {
    // A refusal, a timeout, a rejected effect, or a daemon that is not there.
    // The tick hands the note back; this line used to be where it was dropped.
    if (response.outcome != .ok or response.status != 200) {
        failHelperSign();
        return;
    }
    const gpa = std.heap.page_allocator;
    // Every failure below is the daemon answering with something this app cannot
    // use, which is a failed sign like any other.
    var wrapped = nostr.signer_ipc.parse(nostr.signer_ipc.SignEvent, gpa, response.body) catch {
        failHelperSign();
        return;
    };
    defer wrapped.deinit();
    var parsed = nostr.event.fromJson(gpa, wrapped.value.event) catch {
        failHelperSign();
        return;
    };
    defer parsed.deinit();
    const owned = gpa.dupe(u8, parsed.value.content) catch {
        failHelperSign();
        return;
    };
    // Handed to the publish on success, and freed on every other way out: each
    // refusal below used to leave this copy and the tags behind.
    var handed = false;
    defer if (!handed) gpa.free(owned);
    var out = parsed.value;
    out.content = owned;
    // Preserve the signed event's tags (a reaction carries e/p/k): forcing them
    // empty would leave the published id not matching its content, so relays
    // would reject it. Deep-copied because `parsed` is freed on return.
    // Whole, or the note is handed back rather than published. Without the
    // signed tags the id no longer matches the event, so a relay rejects it and
    // the reader is told nothing; failing here keeps the note recoverable.
    out.tags = dupeTags(gpa, parsed.value.tags) orelse {
        failHelperSign();
        return;
    };
    defer if (!handed) {
        for (out.tags) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        gpa.free(out.tags);
    };
    // Checked, not trusted, and that is a change of mind rather than an
    // oversight. The old reasoning was written down here: "it came from our own
    // daemon over authenticated loopback". It was true when the daemon was a
    // binary Plaza built and shipped. It is not now: the keyholder is a
    // separate product whose key can be changed, removed or replaced between
    // the moment Plaza asked whose key it was and the moment an answer arrives.
    //
    // Two things, and the second is the one that matters. A signature proves
    // the event was signed by the key it names. It says nothing about WHOSE key
    // that is, so publishing without the second check would put a note on
    // relays under an account the reader is not signed in to, over their name,
    // with nothing on screen to say so.
    var verifier = nostr.keys.Signer.init();
    defer verifier.deinit();
    const mine = activePubkey() orelse {
        failHelperSign();
        return;
    };
    if (!std.mem.eql(u8, &out.pubkey, &mine)) {
        failHelperSign();
        return;
    }
    if (nostr.event.verify(gpa, verifier, out)) |ok| {
        if (!ok) {
            failHelperSign();
            return;
        }
    } else |_| {
        failHelperSign();
        return;
    }

    // An upload token is asked for, and answered, as one. A note that comes back
    // where a token was asked for would otherwise be published below, and a
    // token that comes back for a note would take the note's slot with it and
    // never hand the draft back.
    if ((out.kind == blossom.auth_kind) != g_helper_sign.upload_auth) {
        failHelperSign();
        return;
    }
    // An upload token goes to the upload and nowhere else.
    if (out.kind == blossom.auth_kind) {
        releaseHelperSign();
        acceptUploadAuth(gpa, out);
        return;
    }
    if (out.kind == 0) {
        if (upsertProfile(out.pubkey)) |prof| parseMetadataInto(prof, owned);
    }
    // The room is read BEFORE the slot is released, because releasing it resets
    // the slot and with it the route. Read after, every note Notary signed went
    // to the reader's public relays, the exclusive place it was written in
    // included or not, and the outbox retried it there too.
    const route = g_helper_sign.route;
    // Signed. The note is the store's and the outbox's problem now, so the copy
    // held for a restore is dropped and any earlier failure notice retired.
    releaseHelperSign();
    g_helper_sign_notice.store(false, .release);
    // There is nothing left to take back: this press is signed. Its undo went
    // with the slot above, rather than when the event is ingested, because an
    // ingest that fails would otherwise leave the record armed.
    // The room this write was submitted FROM, not the one on screen now: the
    // keyholder can ask a person, and the reader can walk out while it waits.
    handed = true;
    ingestAndPublish(gpa, out, null, route);
}

/// Delivers one /pubkey answer the way the runtime would.
pub fn deliverHelperPubkeyForTest(model: *Model, body: []const u8) void {
    handleHelperPubkey(model, .{ .key = helper_poll_key, .outcome = .ok, .status = 200, .body = body });
}

pub fn helperSetupPendingForTest() bool {
    return g_helper_setup != .none;
}

pub fn helperStateForTest() HelperState {
    return helperState();
}

pub fn helperTokenForTest() []const u8 {
    return helperToken();
}

/// Puts the daemon into the "answering and holding a key" state, so a test can
/// ask what the OTHER conditions do.
pub fn setHelperReadyForTest() void {
    g_helper_state.store(2, .release);
}

pub fn helperReachableForTest() bool {
    return helperReachable();
}

pub fn helperPortForTest() u16 {
    return g_helper_port;
}

pub fn setHelperPortForTest(port: u16) void {
    g_helper_port = port;
}

pub fn helperSecretForTest() []const u8 {
    return g_helper_secret_buf[0..g_helper_secret_len];
}

pub fn mintHelperSecretForTest(io: std.Io) void {
    var raw: [24]u8 = undefined;
    io.randomSecure(&raw) catch return;
    const written = std.fmt.bufPrint(&g_helper_secret_buf, "{x}\n", .{raw}) catch return;
    g_helper_secret_len = written.len;
}

/// `false` restores the unprobed state rather than claiming a keyholder was
/// found, because in a test nothing has looked for one.
pub fn setKeyholderMissingForTest(missing: bool) void {
    g_keyholder = if (missing) .missing else .unprobed;
}

pub fn resolveSiblingForTest(io: std.Io, out: []u8, dir: []const u8, name: []const u8) usize {
    return resolveSibling(io, out, dir, name);
}

pub fn exeDirForTest(io: std.Io, buf: []u8) ?[]const u8 {
    return exeDir(io, buf);
}

/// Adopts the Notary signer kind for the active test identity, so the status
/// line can be asked what it says about a daemon that is not there.
/// Says that this test drives the keyholder's answers itself.
///
/// A test that reaches for this one is asking about what happens WHILE a
/// signature is out, or when the answer is a 401, or when none comes at all.
/// The stand-in keyholder that answers every other test instantly would give
/// it a success before it could look, so switching kind here silences it.
pub fn setSignerKindHelperForTest() void {
    g_signer_kind = .helper;
    g_test_signer_silent = true;
}

/// Hands the keyholder back to the stand-in, for a test that took it.
pub fn setSignerKindLocalForTest() void {
    g_signer_kind = .helper;
    g_test_signer_silent = false;
}

/// Which kind of signer this app is using, by name.
pub fn signerKindNameForTest() []const u8 {
    return @tagName(g_signer_kind);
}
pub fn ceremonyCanTakeKeyForTest() bool {
    return ceremonyCanTakeKey();
}
pub fn setSignerKindForTest(kind: []const u8) void {
    g_signer_kind = if (std.mem.eql(u8, kind, "remote")) .remote else .helper;
}

/// Pretends the ceremony window was (or was not) found beside Plaza.
pub fn setNotaryWindowFoundForTest(found: bool) void {
    g_notary_win_len = if (found) "/nonexistent/notary".len else 0;
    if (found) @memcpy(g_notary_win_buf[0.."/nonexistent/notary".len], "/nonexistent/notary");
}

/// Whether a helper setup is sitting queued, waiting for the daemon to answer.
pub fn helperSetupQueuedForTest() bool {
    return g_helper_setup != .none;
}

pub fn helperSetupMayFireForTest(queued: bool, state: HelperState) bool {
    return helperSetupMayFire(queued, state);
}

pub fn helperSignTimeoutSecondsForTest() i64 {
    return helper_sign_timeout_s;
}

pub fn helperSignTimeoutMillisForTest() u32 {
    return helper_sign_timeout_ms;
}
/// The tag set of the last event handed to a signer, for tests.
pub fn lastPublishedTagsForTest() []const nostr.event.Tag {
    return g_last_published_tags;
}

pub fn lastPublishedForTest() ?nostr.event.Event {
    return g_last_published;
}

pub fn forgetLastPublishedForTest() void {
    g_last_published = null;
}

pub fn clearLastPublishedTagsForTest() void {
    g_last_published_tags = &.{};
}

pub fn helperSignRestorableForTest() bool {
    return g_helper_sign.active and g_helper_sign.restorable;
}

pub fn requestHelperSignForTest(fx: *Effects, created: i64, kind: u16, content: []const u8, restorable: bool) void {
    requestHelperSign(fx, std.heap.page_allocator, created, kind, &.{}, content, restorable, .none, .none);
}

/// The same, submitted from a place that writes to `relay` and, when
/// `exclusive`, nowhere else.
pub fn requestHelperSignRoutedForTest(fx: *Effects, created: i64, content: []const u8, relay: []const u8, exclusive: bool) void {
    var route: PlaceRoute = .{ .exclusive = exclusive };
    route.lens[0] = @intCast(copyBounded(&route.urls[0], relay));
    route.len = 1;
    requestHelperSign(fx, std.heap.page_allocator, created, 1, &.{}, content, true, route, .none);
}

/// The route the last published event was handed to the publish with. Only
/// recorded in a test binary.
pub var g_last_published_route: PlaceRoute = .none;

pub fn lastPublishedRouteRelaysForTest(out: [][]const u8) usize {
    var n: usize = 0;
    while (n < g_last_published_route.len and n < out.len) : (n += 1) out[n] = g_last_published_route.url(n);
    return n;
}

pub fn lastPublishedRouteExclusiveForTest() bool {
    return g_last_published_route.exclusive;
}

pub fn handleHelperSignedForTest(response: native_sdk.EffectResponse) void {
    handleHelperSigned(response);
}

pub fn releaseHelperSignForTest() void {
    releaseHelperSign();
}

/// Puts the pending sign past its deadline, for the case where no terminal ever
/// arrives: a daemon that accepts the socket and then says nothing.
pub fn expireHelperSignForTest() void {
    g_helper_sign.deadline_s = 0;
}

pub fn scanHelperSignForTest(model: *Model) void {
    scanHelperSign(model);
}

pub fn helperSignNoticeForTest() bool {
    return g_helper_sign_notice.load(.acquire);
}

pub fn signerReadyForTest() bool {
    return signerReady();
}

pub fn silenceTestSignerForTest(silent: bool) void {
    g_test_signer_silent = silent;
}

pub fn holdHelperSignForTest() void {
    g_signer_kind = .helper;
    g_helper_sign.active = true;
}

pub fn helperSignPendingForTest() bool {
    return g_helper_sign.active;
}

/// Ingests and publishes a signed event returned by the daemon. Trusted: it
/// came from our own daemon over authenticated loopback. A kind:0 seeds the
/// profile cache so the name shows at once.
/// The keyholder a test has: signs what was asked for and answers exactly as
/// the daemon would, so `handleHelperSigned` runs for real.
///
/// Only compiled into a test binary. It exists so that the four hundred tests
/// that "are somebody" drive the path that ships rather than one that does not,
/// which is worth more than the shortcut it replaces.
pub fn answerHelperSignForTest(gpa: std.mem.Allocator, unsigned_json: []const u8) void {
    const secret = feed_state.g_test_secret orelse return;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    var parsed = nostr.event.fromJson(gpa, unsigned_json) catch return;
    defer parsed.deinit();
    const ev = parsed.value;
    const signed = nostr.event.create(gpa, signer, kp, ev.created_at, ev.kind, ev.tags, ev.content, null) catch return;
    const signed_json = nostr.event.toJson(gpa, signed) catch return;
    defer gpa.free(signed_json);
    const body = (nostr.signer_ipc.SignEvent{ .event = signed_json }).toJson(gpa) catch return;
    defer gpa.free(body);
    handleHelperSigned(.{ .key = helper_sign_key, .outcome = .ok, .status = 200, .body = body });
}

/// Delivers one signed-event answer the way the runtime would, so a test can
/// hand the app an event it did NOT ask for.
pub fn deliverHelperSignedForTest(body: []const u8) void {
    handleHelperSigned(.{ .key = helper_sign_key, .outcome = .ok, .status = 200, .body = body });
}
/// Clears the active identity again. For tests.
pub fn clearIdentityForTest() void {
    follows.g_home_scope = .following;
    g_identity_npub_len = 0;
    g_signer_kind = .helper;
    feed_state.g_test_secret = null;
    g_helper_has_identity = false;
}
/// What pressing "Create your identity" does to the sign-out latch: drops it
/// before any new key exists. The pubkey latch is what has to hold after this.
pub fn loggedOutForTest() bool {
    return g_logged_out;
}

pub fn clearLoggedOutLatchForTest() void {
    g_logged_out = false;
}
/// Restores a helper identity from a session pubkey hex. For tests.
pub fn restoreHelperForTest(pubkey_hex: []const u8) bool {
    return restoreHelperIdentity(pubkey_hex);
}

/// Sets what the create ceremony has reported, which is the only thing that
/// tells an appearing key apart from any other. For tests.
pub fn setCeremonyForTest(state: enum { none, running, created }) void {
    g_ceremony = switch (state) {
        .none => .none,
        .running => .running,
        .created => .created,
    };
    g_ceremony_adopted = false;
}

/// Parks the daemon health flag at "unreachable", so a queued setup stays queued
/// instead of reaching for an effects layer a unit test does not have. For tests.
pub fn setHelperUnreachableForTest() void {
    g_helper_state.store(0, .release);
    g_helper_setup = .none;
    g_helper_pending_in_flight = .none;
}

pub fn ceremonyOwesNameForTest() bool {
    return g_ceremony_adopted;
}
/// Delivers the ceremony window's exit, which is how Plaza learns what it did.
/// For tests.
pub fn handleNotaryExitedForTest(model: *Model, e: native_sdk.EffectExit) void {
    handleNotaryExited(model, e);
}

/// Delivers a daemon /pubkey answer, which is how a key made or imported in the
/// other process reaches Plaza. For tests.
pub fn handleHelperPubkeyForTest(model: *Model, response: native_sdk.EffectResponse) void {
    handleHelperPubkey(model, response);
}
/// Drives the remote-signer connection state (0 idle, 1 reaching, 2 connected,
/// 3 unreachable) plus a remote identity, so the presentation is testable
/// without a live bunker. For tests.
pub fn setRemoteStateForTest(status: u8, npub_len: usize) void {
    g_signer_kind = if (status == 0) .helper else .remote;
    remote_signer.g_remote_status.store(status, .release);
    remote_signer.g_remote_sign_notice.store(false, .release);
    if (npub_len > 0) {
        const stub = "npub1testsigner";
        const n = @min(stub.len, g_identity_npub_buf.len);
        @memcpy(g_identity_npub_buf[0..n], stub[0..n]);
        g_identity_npub_len = n;
    } else g_identity_npub_len = 0;
}
pub fn clearLastPublishedForTest() void {
    g_last_published = null;
    g_last_published_tags = &.{};
}
pub fn loggedOutPubkeyForTest() ?[32]u8 {
    return g_logged_out_pk;
}

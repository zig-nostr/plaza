//! The session: where it is kept, restoring it, the legacy key, and signing out.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const follows = @import("follows.zig");
const keyholder = @import("keyholder.zig");
const login = @import("login.zig");
const own_lists = @import("own_lists.zig");
const remote_signer = @import("remote_signer.zig");
const compose = @import("compose.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const LoginError = main.LoginError;
const Model = main.Model;
const abbreviateNpub = main.abbreviateNpub;
const activePubkey = main.activePubkey;
const clearPending = main.clearPending;
const dropUpload = main.dropUpload;
const forgetBlossom = main.forgetBlossom;
const forgetBookmarks = main.forgetBookmarks;
const forgetFollows = main.forgetFollows;
const forgetMutes = main.forgetMutes;
const forgetOwnRecordAnswers = main.forgetOwnRecordAnswers;
const forgetPlaces = main.forgetPlaces;
const forgetPrivateHalves = main.forgetPrivateHalves;
const forgetReplyDrafts = main.forgetReplyDrafts;
const hexLower = main.hexLower;
const invalidateFeed = main.invalidateFeed;
const newRemoteGeneration = main.newRemoteGeneration;
const nip46ReceiveLoop = main.nip46ReceiveLoop;
const releaseHelperSign = main.releaseHelperSign;
const resetInbox = main.resetInbox;
const resetRelaysToBootstrap = main.resetRelaysToBootstrap;
const restoreHelperIdentity = main.restoreHelperIdentity;
const saveDraft = main.saveDraft;
const secret_file_permissions = main.secret_file_permissions;
const sendConnect = main.sendConnect;

/// Opens (creating if needed) `$HOME/.plaza`, returning the directory handle.
pub fn plazaDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Whether a key from an older Plaza is still sitting on this disk.
///
/// Plaza used to keep the raw secret at `$HOME/.plaza/identity.key`, mode 0600.
/// It does not read it any more, and it does not move it either: importing it
/// would mean this process holding a secret key, which is the whole thing that
/// stopped.
///
/// So the file is LEFT ALONE and the reader is told it is there. Deleting
/// somebody's only copy of an identity because an app was rewritten is not a
/// migration, and silently orphaning it is worse: they would land on the
/// welcome screen as a guest with their account still on the disk and nothing
/// on screen connecting the two.
var g_legacy_key_found = false;

pub fn legacyKeyOnDisk() bool {
    return g_legacy_key_found;
}

fn noticeLegacyKey(io: std.Io, environ: *const std.process.Environ.Map) void {
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    const st = dir.statFile(io, "identity.key", .{}) catch return;
    g_legacy_key_found = st.size == 32;
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
pub fn persistSession() void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);

    var buf: [1024]u8 = undefined;
    const data = switch (keyholder.g_signer_kind) {
        .helper => blk: {
            if (!keyholder.g_helper_has_identity) return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, keyholder.g_helper_identity_pk);
            break :blk std.fmt.bufPrint(&buf, "kind=helper\npubkey={s}\nminted={d}\n", .{ &pk_hex, @intFromBool(own_lists.g_identity_minted_here) }) catch return;
        },
        .remote => blk: {
            const kp = remote_signer.g_remote_client_kp orelse return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, remote_signer.g_remote_pubkey);
            var cs_hex: [64]u8 = undefined;
            hexLower(&cs_hex, kp.secret_key);
            break :blk std.fmt.bufPrint(&buf, "kind=remote\nremote_pubkey={s}\nrelay={s}\nclient_secret={s}\nsecret={s}\n", .{
                &pk_hex,
                remote_signer.g_remote_relay_buf[0..remote_signer.g_remote_relay_len],
                &cs_hex,
                remote_signer.g_remote_secret_buf[0..remote_signer.g_remote_secret_len],
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
pub fn restoreSession(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var dir = plazaDir(io, environ) catch return false;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;

    const raw = dir.readFileAlloc(io, "session", gpa, std.Io.Limit.limited(2048)) catch {
        // No session file. An older Plaza kept its key here; it is not read
        // and not moved, only noticed, so the reader can be told where it is.
        noticeLegacyKey(io, environ);
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
        // Whether this key was minted here. Absent means an older session file,
        // and absent has to read as "imported": assuming a key is ours when we
        // do not know is exactly the assumption that loses a contact list.
        if (std.mem.eql(u8, key, "minted")) own_lists.g_identity_minted_here = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "remote_pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "relay")) f_relay = val;
        if (std.mem.eql(u8, key, "client_secret")) f_client_secret = val;
        if (std.mem.eql(u8, key, "secret")) f_secret = val;
    }

    if (std.mem.eql(u8, kind, "helper")) return restoreHelperIdentity(f_pubkey);
    // A session written by a Plaza that held its own key. There is no such
    // identity any more, so this lands on the welcome screen; the notice says
    // where the key it was pointing at still is.
    if (std.mem.eql(u8, kind, "local")) {
        noticeLegacyKey(io, environ);
        return false;
    }
    if (std.mem.eql(u8, kind, "remote")) return restoreRemoteSigner(gpa, f_pubkey, f_relay, f_client_secret, f_secret);
    return false;
}

/// Rebuilds the remote-signer connection from a persisted session and reconnects
/// silently: adopts the bunker pubkey as the identity, reconstructs the ephemeral
/// transport key, starts the response listener, and re-sends `connect`.
fn restoreRemoteSigner(gpa: std.mem.Allocator, pubkey_hex: []const u8, relay: []const u8, client_secret_hex: []const u8, secret: []const u8) bool {
    if (pubkey_hex.len != 64 or client_secret_hex.len != 64) return false;
    if (relay.len == 0 or relay.len > remote_signer.g_remote_relay_buf.len) return false;
    if (secret.len > remote_signer.g_remote_secret_buf.len) return false;

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

    remote_signer.g_remote_pubkey = pubkey;
    @memcpy(remote_signer.g_remote_relay_buf[0..relay.len], relay);
    remote_signer.g_remote_relay_len = relay.len;
    @memcpy(remote_signer.g_remote_secret_buf[0..secret.len], secret);
    remote_signer.g_remote_secret_len = secret.len;
    remote_signer.g_remote_client_kp = client_kp;

    const npub = abbreviateNpub(&keyholder.g_identity_npub_buf, pubkey);
    keyholder.g_identity_npub_len = npub.len;
    keyholder.g_signer_kind = .remote;
    remote_signer.g_remote_status.store(1, .release);
    remote_signer.g_remote_sign_notice.store(false, .release);

    // A fresh generation for this reconnected session (see `connectRemoteSigner`).
    const generation = newRemoteGeneration();
    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch return false;
    thread.detach();
    sendConnect(gpa);
    return true;
}
pub fn performLogout(model: *Model, fx: *Effects) void {
    // Notary is NOT touched. Signing out of a client is not the same act as
    // taking your key off the machine, and conflating them means one press in
    // one app destroys an identity every other app was using. The key stays
    // where it lives; this app stops using it.
    //
    // Which makes the latch below the whole mechanism rather than a backstop.
    // The keyholder still holds the key and will keep saying so on every
    // health check, so "signed out" is a fact Plaza has to remember for itself.
    _ = fx;
    keyholder.g_logged_out = true;
    // WHICH key left, so the health-check can refuse to hand it back even after
    // an explicit sign-in drops the latch above.
    keyholder.g_logged_out_pk = activePubkey();
    if (main.g_io) |io| if (main.g_environ) |environ| {
        if (plazaDir(io, environ)) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            // The session, and nothing else. No key file is removed, by
            // either name: `identity.key` belongs to a Plaza that held its own
            // key and is left where its owner can find it, and the keyholder's
            // file is the keyholder's.
            dir.deleteFile(io, "session") catch {};
        } else |_| {}
    };

    // Tear down the NIP-46 session: bumping the generation stops the detached
    // listener from processing into the next session, and the pending table is
    // emptied so no in-flight request survives the logout.
    _ = remote_signer.g_remote_generation.fetchAdd(1, .monotonic);
    clearPending();
    remote_signer.g_remote_sign_notice.store(false, .release);
    // And the built-in signer's slot, for the same reason: it holds the leaving
    // account's writing, and the confirmation said what that costs.
    releaseHelperSign();
    keyholder.g_helper_sign_notice.store(false, .release);

    keyholder.g_identity_npub_len = 0;
    keyholder.g_helper_has_identity = false;
    keyholder.g_signer_kind = .helper;
    remote_signer.g_remote_client_kp = null;
    remote_signer.g_remote_relay_len = 0;
    remote_signer.g_remote_secret_len = 0;
    remote_signer.g_remote_status.store(0, .release);
    login.g_login_error.store(@intFromEnum(LoginError.none), .release);
    invalidateFeed();

    // The relay list belongs to the ACCOUNT, not the machine: it came from their
    // kind:10002 and it names where they read and write. Carrying it into the
    // next account would route a stranger's notes through the previous reader's
    // relays, and hand the new account a list they never chose. Back to the
    // relays the app was born with, ready to adopt the next account's own.
    resetRelaysToBootstrap();
    // And what was concluded about the leaving account's own records. Carrying
    // any of it would let the next account be judged without being asked, and a
    // write would then go out over a list nobody has read.
    forgetOwnRecordAnswers();
    // And who the leaving account followed, so the next reader is not shown a
    // feed built from a stranger's list.
    forgetFollows();
    forgetMutes();
    forgetBookmarks();
    forgetPrivateHalves();
    dropUpload();
    forgetBlossom();
    resetInbox();
    forgetPlaces();
    // And a note this account was about to sign. It is held on the near side of
    // the signature precisely so it can still be taken back, and a session
    // ending is the clearest possible instance of taking it back.
    compose.g_post_due_s = 0;
    compose.g_reply_due_s = 0;
    model.notifications_open = false;
    model.editing_profile = false;
    model.profile_seeded = false;
    model.profile_confirm_new = false;
    model.fresh_ask = null;

    // And this key was not made here, whoever comes next. The flag is the ONE
    // piece of evidence that authorizes building a contact list, a relay list or
    // a profile from nothing, and it is persisted to the session file, so left
    // set it outlived the account it was true about: mint here, log out, and an
    // identity imported afterwards inherited permission to publish nine
    // starter-pack names over a real eight-hundred-follow list.
    own_lists.g_identity_minted_here = false;
    // And Home reads follows again. The pack is where a key MADE here starts,
    // which is a fact about that account and not about this app: left set, the
    // next reader signed in with eight hundred follows and got nine strangers.
    follows.g_home_scope = .following;

    model.login_buffer.clear();
    model.draft_buffer.clear();
    model.draft_dropped = 0;
    model.warn_on = false;
    model.warn_buffer.clear();
    // Every other thing the previous reader typed, for the same reason the draft
    // is cleared: it is their private thinking, and it is one press from being
    // published under the NEXT account's key.
    //
    // The reply box survived because logout performs no navigation, so the next
    // account landed inside the previous reader's open thread with their unsent
    // sentence still in the composer. The name field survived Skip as well as
    // logout, so a freshly minted key could be given a permanent kind:0 carrying
    // the previous person's typed name.
    model.reply_buffer.clear();
    forgetReplyDrafts();
    model.name_buffer.clear();
    model.viewing_thread = 0;
    model.thread_stack_len = 0;
    model.notifications_return = false;
    model.viewing_profile = null;
    model.topic_len = 0;
    model.viewing_bookmarks = false;
    // And off the disk. An unfinished note is the previous account's private
    // thinking; leaving it would hand it to whoever signs in next, in their
    // composer, one keystroke from being published under THEIR key.
    saveDraft("", null);
    // The OUTBOX is deliberately left alone, and that is not an oversight.
    //
    // A queued note is one the reader wrote and the app has not managed to
    // deliver yet. Emptying the queue here would destroy it, and `sweepOutbox`
    // already refuses to do that for exactly this reason. So it stays, and
    // `syncOutboxOwner` is what makes staying safe: on the next tick the slots
    // are handed to whoever is signed in, and these entries are parked in this
    // account's own record. Sign back in as its author and it is read back and
    // goes out. For a LOCAL key that is only possible if the reader kept a copy,
    // because this function deletes the key file; the note is still theirs, and
    // still here, which is the most an app can honestly promise at that point.
    //
    // Getting this wrong is how the previous account's unsent note would ride
    // out over the next account's relays, counted in their status bar as
    // something the app owed THEM.
    model.logout_pending = false;
    model.notes_len = 0;
    // Never a locked door: signing out lands on the guest feed, reading
    // uninterrupted (the pool and store keep running), not a welcome wall.
    model.stage = .ready;
}

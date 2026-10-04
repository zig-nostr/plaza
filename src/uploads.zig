//! Picture uploads: picking a file, preparing it, and sending it to a media server.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const drafts = @import("drafts.zig");
const keyholder = @import("keyholder.zig");
const remote_signer = @import("remote_signer.zig");
const blossom = @import("blossom.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const Model = main.Model;
const activePubkey = main.activePubkey;
const compose_capacity = main.compose_capacity;
const nowSeconds = main.nowSeconds;
const pendingLock = main.pendingLock;
const pendingUnlock = main.pendingUnlock;
const requestHelperSign = main.requestHelperSign;
const requestRemoteSignAs = main.requestRemoteSignAs;
const setToast = main.setToast;
const signerReady = main.signerReady;
const uploadServers = main.uploadServers;

// ------------------------------------------------------------ picture upload
//
// Putting a picture into a note, an avatar or a banner.
//
// The protocol is Blossom and `blossom.zig` holds it. What lives here is what
// only the app can know: who is signed in, which signer will sign, which draft or
// profile field the address belongs in, and what is on screen while it happens.
//
// The shape of one upload, because it spans three threads and a signer:
//
//   1. The reader presses a button, a file dialog opens, and a file is chosen.
//      Nothing has left the machine.
//   2. A worker reads it, checks what it is, removes location and camera
//      metadata and works out the hash, size and blurhash. The card now says what
//      will be sent and to which servers, and waits for a press on Upload.
//   3. The press asks the signer for a kind:24242 token naming that hash. It goes
//      through exactly the signer every other event goes through, so a Notary or
//      a NIP-46 bunker prompts as it would for a note. The token is never stored
//      and never published: it is a bearer credential for one file.
//   4. A second worker sends the picture, server by server, until one takes it.
//   5. The tick puts the returned address where the picture was asked for.
//
// A job is shared between the UI thread and at most one worker at a time, and it
// is reference counted so that cancelling while a worker is mid-write cannot free
// what the worker is reading. The UI holds one reference; each worker holds one
// while it runs.

/// BUD-03's list of a person's media servers.
pub const blossom_list_kind: u16 = 10063;

pub const UploadTarget = enum(u8) { note, avatar, banner };

const UploadPhase = enum(u8) {
    /// A worker is reading the file.
    preparing,
    /// Checked and waiting for the reader to say go.
    ready,
    /// The token is with the signer.
    signing,
    /// The token is back; the tick starts the send.
    signed,
    sending,
    /// A server took it; the tick applies the address.
    sent,
    failed,
};

pub const UploadJob = struct {
    refs: std.atomic.Value(u32) = .init(1),
    phase_raw: std.atomic.Value(u8) = .init(@intFromEnum(UploadPhase.preparing)),
    target: UploadTarget,
    path_buf: [1024]u8 = undefined,
    path_len: u16 = 0,
    prepared: ?blossom.Prepared = null,
    /// Why it failed, or empty. Written before the phase moves to `.failed`.
    message_buf: [200]u8 = undefined,
    message_len: u8 = 0,
    /// The servers this upload will try, fixed when the file is chosen so what
    /// the card named is what is used.
    servers: [blossom.max_servers][blossom.max_server_len]u8 = undefined,
    server_lens: [blossom.max_servers]u8 = [_]u8{0} ** blossom.max_servers,
    server_count: u8 = 0,
    /// Whether those are the reader's own list rather than the defaults.
    from_list: bool = false,
    alt_buf: [200]u8 = undefined,
    alt_len: u8 = 0,
    signing_since_s: i64 = 0,
    /// The `Authorization` header, once the signer has answered.
    authorization: ?[]u8 = null,
    progress: blossom.Progress = .{},
    /// What the send found. Written before the phase moves to `.sent` or
    /// `.failed`.
    outcome: ?blossom.Outcome = null,
    /// Post was pressed while this picture was still on its way into the note,
    /// and was refused. The card says so, since the composer shows no toast.
    post_waits: bool = false,

    pub fn phase(self: *const UploadJob) UploadPhase {
        return @enumFromInt(self.phase_raw.load(.acquire));
    }

    fn setPhase(self: *UploadJob, next: UploadPhase) void {
        self.phase_raw.store(@intFromEnum(next), .release);
    }

    fn path(self: *const UploadJob) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// The file's name, without the folders it was found in.
    pub fn fileName(self: *const UploadJob) []const u8 {
        const p = self.path();
        const slash = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return p;
        return p[slash + 1 ..];
    }

    pub fn message(self: *const UploadJob) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    pub fn server(self: *const UploadJob, i: usize) []const u8 {
        return self.servers[i][0..self.server_lens[i]];
    }

    fn alt(self: *const UploadJob) []const u8 {
        return self.alt_buf[0..self.alt_len];
    }

    /// Ends the job in a failure the reader can read. Safe from a worker.
    fn fail(self: *UploadJob, text: []const u8) void {
        const n = @min(text.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], text[0..n]);
        self.message_len = @intCast(n);
        self.setPhase(.failed);
    }
};

/// The job on screen, if any. UI thread only.
pub var g_upload: ?*UploadJob = null;

/// A profile picture or banner has been filled in by an upload and not saved.
/// The sheet says so, because the field alone does not tell anyone that the
/// picture is not published yet.
pub var g_profile_upload_unsaved: bool = false;

pub fn setProfileUploadUnsavedForTest(on: bool) void {
    g_profile_upload_unsaved = on;
}

/// Stands in for the file dialog: tests, and the harness that drives the real
/// app without a person to click through a native panel. Null in a build nobody
/// has set it in, which is every shipped one.
pub var g_pick_path_override: ?[]const u8 = null;

/// How long a token may be out with the signer before the upload gives up on it.
/// Longer than either signer's own timeout, so this only ever fires for a
/// request that was never sent at all.
const upload_sign_wait_s: i64 = 90;

fn releaseUploadJob(job: *UploadJob) void {
    if (job.refs.fetchSub(1, .acq_rel) != 1) return;
    const gpa = std.heap.page_allocator;
    if (job.prepared) |*prepared| prepared.deinit(gpa);
    if (job.authorization) |header| gpa.free(header);
    gpa.destroy(job);
}

/// Lets go of the job on screen. A worker still running keeps it alive until it
/// is done, and is told to stop.
pub fn dropUpload() void {
    const job = g_upload orelse return;
    g_upload = null;
    // What was in the way of another pick is gone with it.
    g_pick_refused = null;
    job.progress.cancel.store(true, .release);
    releaseUploadJob(job);
}

/// The job on screen when it is for `target`.
pub fn uploadJobFor(target: UploadTarget) ?*UploadJob {
    const job = g_upload orelse return null;
    return if (job.target == target) job else null;
}

/// A pick that was refused because the one job slot is taken, said beside the
/// control that was pressed. A toast cannot say it: the composer and the Edit
/// profile sheet both draw over the toast.
const PickRefused = struct { target: UploadTarget, why: []const u8 };

var g_pick_refused: ?PickRefused = null;

pub fn pickRefusedFor(target: UploadTarget) ?[]const u8 {
    const r = g_pick_refused orelse return null;
    return if (r.target == target) r.why else null;
}

pub fn pickRefusedForTest(target: u8) ?[]const u8 {
    return pickRefusedFor(std.enums.fromInt(UploadTarget, target) orelse return null);
}

/// Whether the composer has a picture on its way into the note: chosen and not
/// yet uploaded, or uploading. Posting now would send the note without it, and
/// the address would then land in the emptied composer as a draft of its own.
pub fn composerPictureUnfinished() bool {
    const job = uploadJobFor(.note) orelse return false;
    return job.phase() != .failed;
}

/// Refuses a post that would leave the composer's picture behind, and marks the
/// card, which is where the reader is looking.
pub fn postWaitsForPicture() bool {
    if (!composerPictureUnfinished()) return false;
    uploadJobFor(.note).?.post_waits = true;
    return true;
}

pub fn postWaitsForTest() bool {
    const job = uploadJobFor(.note) orelse return false;
    return job.post_waits;
}

fn uploadBusy(job: *const UploadJob) bool {
    return switch (job.phase()) {
        .preparing, .signing, .signed, .sending, .sent => true,
        .ready, .failed => false,
    };
}

/// Asks for a file and starts reading it. The dialog is the SDK's own, so the
/// reader sees the native one, and nothing is read or sent until they choose.
pub fn uploadPick(model: *Model, fx: *Effects, target: UploadTarget) void {
    if (model.is_guest()) return;
    if (g_upload) |job| {
        if (uploadBusy(job)) {
            g_pick_refused = .{ .target = target, .why = "Another picture is still uploading. Try again once it is in." };
            return;
        }
        // A picture chosen for another field and not sent yet is the reader's
        // choice, with a description typed for it perhaps, and the slot holds
        // one job. Dropping it to make room was silent.
        if (job.phase() == .ready and job.target != target) {
            g_pick_refused = .{ .target = target, .why = switch (job.target) {
                .note => "A picture for your note is waiting in the composer. Upload or cancel it there first.",
                .avatar => "A picture for your avatar is waiting. Upload or cancel it first.",
                .banner => "A picture for your banner is waiting. Upload or cancel it first.",
            } };
            return;
        }
        dropUpload();
    }
    g_pick_refused = null;
    var buf: [1024]u8 = undefined;
    const path = pickPicturePath(fx, &buf) orelse return;
    startPrepare(model, target, path);
}

fn pickPicturePath(fx: *Effects, buf: []u8) ?[]const u8 {
    if (g_pick_path_override) |path| {
        const n = @min(path.len, buf.len);
        @memcpy(buf[0..n], path[0..n]);
        return buf[0..n];
    }
    if (builtin.is_test) return null;
    const services = fx.services orelse return null;
    const exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" };
    const filters = [_]native_sdk.FileFilter{.{ .name = "Pictures", .extensions = &exts }};
    var out: [4096 * 4]u8 = undefined;
    const result = services.showOpenDialog(.{ .title = "Choose a picture", .filters = &filters }, &out) catch return null;
    if (result.count == 0) return null;
    // One path per line; one was asked for.
    const first = std.mem.sliceTo(result.paths, '\n');
    const n = @min(first.len, buf.len);
    @memcpy(buf[0..n], first[0..n]);
    return buf[0..n];
}

fn startPrepare(model: *Model, target: UploadTarget, path: []const u8) void {
    const gpa = std.heap.page_allocator;
    if (path.len == 0 or path.len > 1024) return;
    const job = gpa.create(UploadJob) catch return;
    job.* = .{ .target = target };
    @memcpy(job.path_buf[0..path.len], path);
    job.path_len = @intCast(path.len);
    model.upload_alt_buffer.clear();
    // The servers are named now, before anything is read from disk, so the card
    // that asks for a press has the same answer a later look would.
    const servers = uploadServers();
    job.server_count = @intCast(servers.count);
    job.from_list = servers.own;
    for (0..servers.count) |i| {
        job.server_lens[i] = servers.lens[i];
        @memcpy(job.servers[i][0..servers.lens[i]], servers.at(i));
    }
    g_upload = job;
    job.refs.store(2, .release);
    const thread = std.Thread.spawn(.{}, prepareWorker, .{job}) catch {
        job.refs.store(1, .release);
        job.fail("Plaza could not start reading the file.");
        return;
    };
    thread.detach();
}

fn prepareWorker(job: *UploadJob) void {
    defer releaseUploadJob(job);
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Read here, with the process's own access, and not through the SDK's file
    // effect: that one caps a read at 1 MiB, and since 0.9.1 it also refuses any
    // path outside the app's own folders unless the manifest asks for
    // `filesystem`. A picture is neither small nor in those folders, and the
    // reader just chose it.
    const file = std.Io.Dir.cwd().readFileAlloc(io, job.path(), gpa, .limited(blossom.max_picture_bytes + 1)) catch |err| {
        job.fail(switch (err) {
            error.StreamTooLong => "That file is larger than the 32 MB Plaza will upload.",
            error.FileNotFound => "That file is no longer there.",
            error.AccessDenied, error.PermissionDenied => "Plaza is not allowed to read that file.",
            else => "Plaza could not read that file.",
        });
        return;
    };
    const prepared = blossom.prepare(gpa, file) catch |err| {
        job.fail(switch (err) {
            error.TooLarge => "That file is larger than the 32 MB Plaza will upload.",
            error.NotAPicture => "That is not a picture Plaza can upload. It takes PNG, JPEG, GIF and WebP.",
            error.Damaged => "That picture's file looks damaged, so Plaza did not upload it.",
            error.OutOfMemory => "Plaza ran out of memory reading that file.",
        });
        return;
    };
    job.prepared = prepared;
    job.setPhase(.ready);
}

/// The Upload press: asks the signer for a token, which is the first thing that
/// leaves this process, and the first thing a bunker will ask its owner about.
pub fn uploadGo(model: *Model, fx: *Effects) void {
    const job = g_upload orelse return;
    if (job.phase() != .ready) return;
    if (activePubkey() == null) return;
    const prepared = job.prepared orelse return;
    // Said on the card, which stays up, and not as a toast: the composer draws
    // none, so a toast raised from there would turn up on the feed afterwards.
    job.message_len = 0;
    if (!signerReady() or uploadTokenOutstanding()) {
        const busy = "Your signer is busy with something else. Press Upload again in a moment.";
        @memcpy(job.message_buf[0..busy.len], busy);
        job.message_len = busy.len;
        return;
    }
    if (job.target == .note) {
        const alt = std.mem.trim(u8, model.upload_alt(), " \t\r\n");
        const n = @min(alt.len, job.alt_buf.len);
        @memcpy(job.alt_buf[0..n], alt[0..n]);
        job.alt_len = @intCast(n);
    }
    const gpa = std.heap.page_allocator;
    const created = nowSeconds();
    const tags = blossom.authTags(gpa, &prepared.sha256, prepared.bytes.len, created + blossom.auth_lifetime_s) catch {
        job.fail("Plaza ran out of memory.");
        return;
    };
    const content = gpa.dupe(u8, blossom.auth_content) catch {
        job.fail("Plaza ran out of memory.");
        return;
    };
    job.signing_since_s = created;
    job.setPhase(.signing);
    switch (keyholder.g_signer_kind) {
        .remote => requestRemoteSignAs(.sign_upload_auth, gpa, created, blossom.auth_kind, tags, content, false, .none, .none),
        .helper => requestHelperSign(fx, gpa, created, blossom.auth_kind, tags, content, false, .none, .none),
    }
}

/// Whether a token asked for earlier, for a picture since put away, is still out
/// with the signer. Its answer, or its failure, lands on whichever upload is
/// signing when it arrives, and is not that upload's, so a new request waits
/// until it has come back. A bunker takes several requests at once, so being
/// ready is not enough to say so.
fn uploadTokenOutstanding() bool {
    if (keyholder.g_helper_sign.active and keyholder.g_helper_sign.upload_auth) return true;
    pendingLock();
    defer pendingUnlock();
    if (g_upload_sign_inbox.used) return true;
    for (&remote_signer.g_pending) |*slot| {
        if (slot.active and slot.method == .sign_upload_auth) return true;
    }
    return false;
}

/// Sends the same picture again after a failure, with the same token when there
/// is one, so a signer is not asked twice for the same file. A token near the end
/// of its hour is asked for again rather than sent to be refused.
pub fn uploadRetry(model: *Model, fx: *Effects) void {
    const job = g_upload orelse return;
    if (job.phase() != .failed or job.prepared == null) return;
    job.message_len = 0;
    job.outcome = null;
    job.progress.sent.store(0, .release);
    job.progress.cancel.store(false, .release);
    if (job.authorization) |header| {
        if (nowSeconds() < job.signing_since_s + blossom.auth_lifetime_s - 120) {
            job.setPhase(.signed);
            return;
        }
        std.heap.page_allocator.free(header);
        job.authorization = null;
    }
    job.setPhase(.ready);
    uploadGo(model, fx);
}

pub fn uploadCancel(model: *Model) void {
    _ = model;
    dropUpload();
}

/// Whether a token is the one that was asked for: an upload token for this file
/// and nothing else, that runs out within the hour. A signer that returns
/// anything wider has not signed what the reader saw: a second `x` would let a
/// server store a different file under this key, a `t delete` would let it
/// delete one, and a token with no expiry is good for as long as anyone keeps it.
pub fn tokenNamesFile(tags: []const nostr.event.Tag, sha256_hex: []const u8, now: i64) bool {
    var upload = false;
    var named = false;
    var expires = false;
    for (tags) |tag| {
        if (tag.len < 2) continue;
        if (std.mem.eql(u8, tag[0], "t")) {
            if (!std.mem.eql(u8, tag[1], "upload")) return false;
            upload = true;
        } else if (std.mem.eql(u8, tag[0], "x")) {
            if (!std.mem.eql(u8, tag[1], sha256_hex)) return false;
            named = true;
        } else if (std.mem.eql(u8, tag[0], "expiration")) {
            const at = std.fmt.parseInt(i64, tag[1], 10) catch return false;
            // Plaza asked for an hour from the moment it asked. A minute of
            // slack, and no more.
            if (at <= now or at > now + blossom.auth_lifetime_s + 60) return false;
            expires = true;
        }
    }
    return upload and named and expires;
}

/// A signed token arriving from the signer. UI thread. It becomes the header the
/// send carries, and goes nowhere else.
pub fn acceptUploadAuth(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    const job = g_upload orelse return;
    if (job.phase() != .signing) return;
    const prepared = job.prepared orelse return;
    const me = activePubkey() orelse return;
    if (ev.kind != blossom.auth_kind or !std.mem.eql(u8, &ev.pubkey, &me) or !tokenNamesFile(ev.tags, &prepared.sha256, nowSeconds())) {
        job.fail("Your signer returned something other than the upload request, so nothing was uploaded.");
        return;
    }
    const json = nostr.event.toJson(gpa, ev) catch {
        job.fail("Plaza ran out of memory.");
        return;
    };
    defer gpa.free(json);
    job.authorization = blossom.authorizationHeader(gpa, json) catch {
        job.fail("Plaza ran out of memory.");
        return;
    };
    job.setPhase(.signed);
}

/// The signer would not, or could not.
pub fn uploadSignFailed() void {
    const job = g_upload orelse return;
    if (job.phase() != .signing) return;
    job.fail("Your signer did not approve the upload, so nothing was uploaded.");
}

/// A token the bunker's listener thread has read, parked for the tick. The same
/// crossing a sealed private half takes, for the same reason: the listener must
/// not touch what the view is reading.
const UploadSignInbox = struct {
    used: bool = false,
    ok: bool = false,
    buf: [4096]u8 = undefined,
    len: u16 = 0,
};
var g_upload_sign_inbox: UploadSignInbox = .{};

/// Listener thread. `event_json` is the signed token, or null when the answer
/// was unusable.
pub fn parkUploadSign(event_json: ?[]const u8) void {
    pendingLock();
    defer pendingUnlock();
    g_upload_sign_inbox.used = true;
    g_upload_sign_inbox.ok = false;
    if (event_json) |json| {
        if (json.len <= g_upload_sign_inbox.buf.len) {
            @memcpy(g_upload_sign_inbox.buf[0..json.len], json);
            g_upload_sign_inbox.len = @intCast(json.len);
            g_upload_sign_inbox.ok = true;
        }
    }
}

/// UI thread: hands a parked token to the job it was for.
fn drainUploadSignInbox() void {
    var local: [4096]u8 = undefined;
    var len: usize = 0;
    var ok = false;
    {
        pendingLock();
        defer pendingUnlock();
        if (!g_upload_sign_inbox.used) return;
        ok = g_upload_sign_inbox.ok;
        len = g_upload_sign_inbox.len;
        if (ok) @memcpy(local[0..len], g_upload_sign_inbox.buf[0..len]);
        g_upload_sign_inbox = .{};
    }
    if (!ok) {
        uploadSignFailed();
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.event.fromJson(gpa, local[0..len]) catch {
        uploadSignFailed();
        return;
    };
    defer parsed.deinit();
    acceptUploadAuth(gpa, parsed.value);
}

/// Called from the tick.
pub fn driveUpload(model: *Model) void {
    drainUploadSignInbox();
    const job = g_upload orelse return;
    switch (job.phase()) {
        .signed => startSend(job),
        .sent => finishUpload(model, job),
        .signing => if (nowSeconds() - job.signing_since_s > upload_sign_wait_s) {
            job.fail("Your signer did not answer, so nothing was uploaded.");
        },
        else => {},
    }
}

fn startSend(job: *UploadJob) void {
    const prepared = job.prepared orelse return;
    job.progress.total = prepared.bytes.len;
    job.setPhase(.sending);
    _ = job.refs.fetchAdd(1, .monotonic);
    const thread = std.Thread.spawn(.{}, sendWorker, .{job}) catch {
        _ = job.refs.fetchSub(1, .monotonic);
        job.fail("Plaza could not start the upload.");
        return;
    };
    thread.detach();
}

fn sendWorker(job: *UploadJob) void {
    defer releaseUploadJob(job);
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const prepared = job.prepared orelse return;
    const header = job.authorization orelse return;
    var servers: [blossom.max_servers][]const u8 = undefined;
    for (0..job.server_count) |i| servers[i] = job.server(i);
    const out = blossom.upload(io, .{
        .servers = servers[0..job.server_count],
        .bytes = prepared.bytes,
        .mime = prepared.format.mime(),
        .ext = prepared.format.ext(),
        .sha256_hex = &prepared.sha256,
        .authorization = header,
    }, &job.progress);
    job.outcome = out;
    switch (out) {
        .ok => job.setPhase(.sent),
        .failed => |why| job.fail(why.text()),
        // The reader has already let go of it.
        .cancelled => {},
    }
}

/// A server took the picture. Puts its address where it was asked for.
fn finishUpload(model: *Model, job: *UploadJob) void {
    const outcome = job.outcome orelse return;
    const ok = switch (outcome) {
        .ok => |o| o,
        else => return,
    };
    const url = ok.descriptor.url();
    switch (job.target) {
        .note => {
            if (!appendPictureToDraft(model, url)) {
                job.fail("It uploaded, but your note has no room left for its address.");
                return;
            }
            rememberUploaded(job, ok.descriptor);
        },
        .avatar, .banner => {
            const buffer = if (job.target == .avatar) &model.profile_picture_buffer else &model.profile_banner_buffer;
            if (url.len > buffer.storage.len) {
                job.fail("It uploaded, but its address is too long for a profile field.");
                return;
            }
            buffer.set(url);
            // The reader has now chosen this value, so the field no longer
            // stands for one that did not fit.
            if (job.target == .avatar) model.profile_picture_long = false else model.profile_banner_long = false;
            g_profile_upload_unsaved = true;
        },
    }
    dropUpload();
}

/// Appends `url` to the draft on a line of its own. False when it will not fit.
pub fn appendPictureToDraft(model: *Model, url: []const u8) bool {
    const text = model.draft();
    var buf: [compose_capacity]u8 = undefined;
    const lead: []const u8 = if (text.len == 0 or text[text.len - 1] == '\n') "" else "\n";
    const written = std.fmt.bufPrint(&buf, "{s}{s}{s}\n", .{ text, lead, url }) catch return false;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(written);
    drafts.g_draft_dirty = true;
    return true;
}
// What the uploader knew about a picture it sent, kept so the note that carries
// its address can say so. Only an uploader has the hash, the dimensions and the
// blurhash before anyone has fetched the file.
pub const UploadedPicture = struct {
    used: bool = false,
    url_buf: [512]u8 = undefined,
    url_len: u16 = 0,
    mime: []const u8 = "",
    sha_buf: [64]u8 = undefined,
    size: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    blur_buf: [blossom.max_blurhash_len]u8 = undefined,
    blur_len: u8 = 0,
    alt_buf: [200]u8 = undefined,
    alt_len: u8 = 0,

    fn url(self: *const UploadedPicture) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};
pub var g_uploaded: [8]UploadedPicture = [_]UploadedPicture{.{}} ** 8;
pub var g_uploaded_next: usize = 0;

fn rememberUploaded(job: *const UploadJob, d: blossom.Descriptor) void {
    const prepared = job.prepared orelse return;
    var entry: UploadedPicture = .{ .used = true, .mime = prepared.format.mime() };
    @memcpy(entry.url_buf[0..d.url().len], d.url());
    entry.url_len = @intCast(d.url().len);
    // What the server says it stored, when it says. If that is not the file that
    // was sent, the size, dimensions and blurhash describe a different file and
    // are left out; the hash is the server's, because that is what the address
    // serves.
    const same = if (d.sha256()) |theirs| std.mem.eql(u8, theirs, &prepared.sha256) else true;
    @memcpy(&entry.sha_buf, d.sha256() orelse &prepared.sha256);
    if (same) {
        entry.size = prepared.bytes.len;
        entry.width = prepared.width;
        entry.height = prepared.height;
        const blur = prepared.blurhashText();
        @memcpy(entry.blur_buf[0..blur.len], blur);
        entry.blur_len = @intCast(blur.len);
    }
    @memcpy(entry.alt_buf[0..job.alt_len], job.alt());
    entry.alt_len = job.alt_len;
    g_uploaded[g_uploaded_next % g_uploaded.len] = entry;
    g_uploaded_next +%= 1;
}

pub fn uploadedPictureFor(url: []const u8) ?*const UploadedPicture {
    for (&g_uploaded) |*entry| {
        if (entry.used and std.mem.eql(u8, entry.url(), url)) return entry;
    }
    return null;
}

/// The full `imeta` tag for a picture this app uploaded, or null for any other.
pub fn uploadedImeta(gpa: std.mem.Allocator, url: []const u8) ?[]const []const u8 {
    const entry = uploadedPictureFor(url) orelse return null;
    return blossom.imetaTag(gpa, url, entry.mime, &entry.sha_buf, entry.size, entry.width, entry.height, entry.blur_buf[0..entry.blur_len], entry.alt_buf[0..entry.alt_len]) catch null;
}

pub fn appendPictureToDraftForTest(model: *Model, url: []const u8) bool {
    return appendPictureToDraft(model, url);
}

/// Records a picture as if it had just been uploaded. For tests.
pub fn rememberUploadedForTest(url: []const u8, mime: []const u8, sha_hex: []const u8, size: usize, width: u32, height: u32, hash: []const u8, alt: []const u8) void {
    var entry: UploadedPicture = .{ .used = true, .mime = mime, .size = size, .width = width, .height = height };
    @memcpy(entry.url_buf[0..url.len], url);
    entry.url_len = @intCast(url.len);
    @memcpy(entry.sha_buf[0..sha_hex.len], sha_hex);
    @memcpy(entry.blur_buf[0..hash.len], hash);
    entry.blur_len = @intCast(hash.len);
    @memcpy(entry.alt_buf[0..alt.len], alt);
    entry.alt_len = @intCast(alt.len);
    g_uploaded[g_uploaded_next % g_uploaded.len] = entry;
    g_uploaded_next +%= 1;
}

pub fn forgetUploadedForTest() void {
    g_uploaded = [_]UploadedPicture{.{}} ** 8;
    g_uploaded_next = 0;
}

// Test seams for the upload: the file dialog stood in for, the phases read, and
// the stages that happen on a thread or in a signer driven by hand.

pub fn setPickPathForTest(path: ?[]const u8) void {
    g_pick_path_override = path;
}

pub fn uploadPickForTest(model: *Model, fx: *Effects, target: u8) void {
    uploadPick(model, fx, std.enums.fromInt(UploadTarget, target) orelse return);
}

pub fn uploadGoForTest(model: *Model, fx: *Effects) void {
    uploadGo(model, fx);
}

pub fn uploadRetryForTest(model: *Model, fx: *Effects) void {
    uploadRetry(model, fx);
}

pub fn uploadCancelForTest(model: *Model) void {
    uploadCancel(model);
}

pub fn driveUploadForTest(model: *Model) void {
    driveUpload(model);
}

pub fn dropUploadForTest() void {
    dropUpload();
}

/// The phase of the job on screen, or "none".
pub fn uploadStateForTest() []const u8 {
    const job = g_upload orelse return "none";
    return @tagName(job.phase());
}

/// Why the job failed, or empty.
pub fn uploadMessageForTest() []const u8 {
    const job = g_upload orelse return "";
    return job.message();
}

/// Moves the job's token back in time, as if it had been signed `seconds` ago.
pub fn ageUploadTokenForTest(seconds: i64) void {
    const job = g_upload orelse return;
    job.signing_since_s -= seconds;
}

pub fn uploadSentBytesForTest() usize {
    const job = g_upload orelse return 0;
    return job.progress.sent.load(.acquire);
}

/// A token as the bunker's listener thread would park it.
pub fn parkUploadSignForTest(event_json: ?[]const u8) void {
    parkUploadSign(event_json);
}

pub fn tokenNamesFileForTest(tags: []const nostr.event.Tag, sha256_hex: []const u8, now: i64) bool {
    return tokenNamesFile(tags, sha256_hex, now);
}

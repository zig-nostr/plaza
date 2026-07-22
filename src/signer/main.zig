//! plaza-signer: Plaza's isolated keyholder.
//!
//! A small headless daemon that holds the user's secret key and answers signing
//! and NIP-44 requests over loopback HTTP. It is a separate PROCESS from Plaza's
//! UI, and that separation is the point: Plaza's UI runs image decoders and a
//! relay JSON parser on bytes off the wire, so the key must not live there. The
//! key enters this process (typed into the ceremony window, which POSTs it to
//! /setup) and never leaves it: no endpoint returns the secret.
//!
//! Built from the nostr library alone, never the SDK. The wire types are the
//! library's `signer_ipc`, so every product speaks the identical protocol.
//!
//! At rest the key is a raw 32-byte secret in a 0600 file. There is no
//! passphrase encryption yet: a passphrase keystore does not exist, and NIP-49
//! with no passphrase would be theater. The security delivered today is process
//! isolation; at-rest encryption arrives with a real passphrase keystore.
//!
//! Spawned by Plaza with `--serve --port N --state-dir DIR --token-file FILE
//! --parent-pid PID`. It binds loopback only, authenticates every request with
//! the bearer token in the token file, and exits when its parent (Plaza) does,
//! so a keyholder is never orphaned.

const std = @import("std");
const nostr = @import("nostr");
const ipc = nostr.signer_ipc;
const keystore = nostr.keystore;

const key_file_name = "signer.key"; // raw 32-byte secret, hex, 0600

// ------------------------------------------------------------------- state

/// The keyholder's live state, shared read-only across connection threads after
/// setup. `/setup` is the only mutator, guarded by the lock; a request that
/// signs copies the secret out under the lock and builds its own secp context,
/// so no context is shared across threads.
const State = struct {
    // A tiny spinlock (std.Thread.Mutex is gone in 0.16, Io.Mutex would thread
    // an io through every access). Critical sections are a 32-byte copy or a
    // one-time setup write; contention is effectively nil.
    lock_flag: std.atomic.Value(bool) = .init(false),
    secret: ?[32]u8 = null,
    pubkey: ?[32]u8 = null,
    key_dir: std.Io.Dir,
    key_path: []const u8,

    fn lock(self: *State) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *State) void {
        self.lock_flag.store(false, .release);
    }

    fn ready(self: *State) bool {
        self.lock();
        defer self.unlock();
        return self.secret != null;
    }

    /// Copies the secret out for one operation (null if uninitialized).
    fn take(self: *State) ?[32]u8 {
        self.lock();
        defer self.unlock();
        return self.secret;
    }

    fn pubkeyHex(self: *State, out: *[64]u8) ?[]const u8 {
        self.lock();
        defer self.unlock();
        const pk = self.pubkey orelse return null;
        return hexLower(out, pk);
    }

    /// Adopts a raw secret: derives the pubkey, holds both, and persists the
    /// secret 0600. Refuses if a key is already held (one-shot setup).
    fn adopt(self: *State, io: std.Io, secret: [32]u8) !void {
        self.lock();
        defer self.unlock();
        if (self.secret != null) return error.AlreadyInitialized;

        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        const kp = signer.keyPairFromSecretKey(secret) catch return error.BadKey;

        var hexbuf: [64]u8 = undefined;
        _ = hexLower(&hexbuf, secret);
        keystore.writeNewKeyFile(io, self.key_dir, self.key_path, &hexbuf) catch |e| {
            std.crypto.secureZero(u8, &hexbuf);
            return e;
        };
        std.crypto.secureZero(u8, &hexbuf);

        self.secret = secret;
        self.pubkey = kp.public_key;
    }

    /// Loads a persisted secret at startup, if any.
    fn load(self: *State, gpa: std.mem.Allocator, io: std.Io) void {
        // A plain read of the raw-hex key file: keystore.readKeyFile is for
        // ncryptsec content only, which this is deliberately not.
        const hex = self.key_dir.readFileAlloc(io, self.key_path, gpa, std.Io.Limit.limited(128)) catch return;
        defer {
            std.crypto.secureZero(u8, hex);
            gpa.free(hex);
        }
        const trimmed = std.mem.trim(u8, hex, " \t\r\n");
        if (trimmed.len < 64) return;
        var secret: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&secret, trimmed[0..64]) catch return;
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        const kp = signer.keyPairFromSecretKey(secret) catch return;
        self.lock();
        defer self.unlock();
        self.secret = secret;
        self.pubkey = kp.public_key;
    }
};

// ----------------------------------------------------------------- helpers

// The existence probe: kill(pid, 0) signals nothing, only reports whether the
// process is still alive. Declared with an int signal to sidestep std's SIG
// enum (the null signal is not one of its members).
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

fn hexLower(out: *[64]u8, bytes: [32]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out[0..64];
}

/// Constant-time token comparison, so a wrong bearer token leaks no timing.
fn tokenOk(expected: []const u8, got: []const u8) bool {
    if (expected.len == 0 or expected.len != got.len) return false;
    var diff: u8 = 0;
    for (expected, got) |a, b| diff |= a ^ b;
    return diff == 0;
}

// -------------------------------------------------------------------- main

var g_state: State = undefined;
var g_token: []const u8 = "";

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;

    var port: u16 = 0;
    var state_dir: []const u8 = ".";
    var token_file: []const u8 = "";
    var parent_pid: ?i32 = null;
    var serve = false;

    {
        var probe = std.process.Args.Iterator.init(init.minimal.args);
        _ = probe.skip();
        if (probe.next()) |sub| {
            if (std.mem.eql(u8, sub, "import")) return runImport(init);
        }
    }

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--serve")) {
            serve = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            port = std.fmt.parseInt(u16, args.next() orelse fail("--port needs a value"), 10) catch fail("bad --port");
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            state_dir = args.next() orelse fail("--state-dir needs a value");
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            token_file = args.next() orelse fail("--token-file needs a value");
        } else if (std.mem.eql(u8, arg, "--parent-pid")) {
            parent_pid = std.fmt.parseInt(i32, args.next() orelse fail("--parent-pid needs a value"), 10) catch fail("bad --parent-pid");
        }
    }
    if (!serve or port == 0 or token_file.len == 0) {
        fail("usage: plaza-signer --serve --port N --token-file FILE [--state-dir DIR] [--parent-pid PID]");
    }

    // The state dir holds the key file; open it (creating if needed).
    var dir = std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{}) catch std.Io.Dir.cwd();
    g_state = .{ .key_dir = dir, .key_path = key_file_name };
    g_state.load(gpa, io);

    // The bearer token: read the file Plaza wrote (0600). Every request carries
    // it, so a stray process on the machine cannot drive the signer.
    g_token = readTokenFile(gpa, io, token_file) orelse fail("cannot read the token file");

    // Never outlive Plaza: if the parent dies, so does the keyholder.
    if (parent_pid) |pid| {
        const t = std.Thread.spawn(.{}, watchParent, .{pid}) catch fail("cannot start the watchdog");
        t.detach();
    }

    serveLoop(gpa, io, port);
    _ = &dir;
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("plaza-signer: {s}\n", .{msg});
    std.process.exit(1);
}

fn readTokenFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var r = f.reader(io, &buf);
    const n = r.interface.readSliceShort(&buf) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Polls the parent process; exits when it is gone. `kill(pid, 0)` is the probe:
/// it signals nothing, only reports whether the process exists.
fn watchParent(pid: i32) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    while (true) {
        io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
        if (kill(pid, 0) != 0) std.process.exit(0);
    }
}

// ---------------------------------------------------------------- import CLI
//
// `plaza-signer import`: the strongest import path. The nsec is read from the
// terminal with echo off (or from stdin when piped), so it never touches
// Plaza, the clipboard, or the screen. If Plaza's daemon is running it is
// POSTed to /setup over loopback (so Plaza picks it up live); otherwise the key
// is written to the keystore directly and the next launch adopts it. A key is
// never accepted as an argument (it would leak into shell history and ps).

fn runImport(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;
    const home = init.environ_map.get("HOME") orelse ".";
    const port: u16 = 8790;

    var input_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &input_buf);
    const input = readSecret(io, "Paste your nsec (input hidden): ", &input_buf) orelse fail("no key read");
    if (input.len == 0) fail("nothing pasted");
    if (!std.mem.startsWith(u8, input, "nsec1") and !std.mem.startsWith(u8, input, "ncryptsec1")) {
        fail("paste an nsec or an ncryptsec");
    }

    var pass_buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass_buf);
    var passphrase: []const u8 = "";
    if (std.mem.startsWith(u8, input, "ncryptsec1")) {
        passphrase = readSecret(io, "Passphrase for the key: ", &pass_buf) orelse fail("no passphrase");
    }

    // Decode to derive the npub (a confirmation the user can check) and to have
    // the raw secret for the offline write.
    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    if (std.mem.startsWith(u8, input, "ncryptsec1")) {
        secret = keystore.decryptKey(gpa, input, passphrase) catch fail("could not decrypt that key (wrong passphrase?)");
    } else {
        secret = nostr.nip19.decodeNsec(gpa, input) catch fail("not a valid nsec");
    }
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch fail("bad key");
    const npub = nostr.nip19.encodeNpub(gpa, kp.public_key) catch fail("out of memory");
    defer gpa.free(npub);

    var token_path_buf: [512]u8 = undefined;
    const token_path = std.fmt.bufPrint(&token_path_buf, "{s}/.plaza/signer.token", .{home}) catch fail("path too long");

    if (postSetup(io, port, token_path, input, passphrase)) |ok| {
        if (!ok) fail("a key is already set up (the signer holds one already)");
        std.debug.print("Imported {s}\nYou're all set; Plaza picks it up automatically.\n", .{npub});
        return;
    }
    // The daemon is not running: write the key for the next launch to adopt.
    var state_buf: [512]u8 = undefined;
    const state_dir = std.fmt.bufPrint(&state_buf, "{s}/.plaza", .{home}) catch fail("path too long");
    var dir = std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{}) catch fail("cannot open the state dir");
    defer dir.close(io);
    var g = State{ .key_dir = dir, .key_path = key_file_name };
    g.adopt(io, secret) catch |e| switch (e) {
        error.AlreadyInitialized => fail("a key is already set up"),
        else => fail("could not store the key"),
    };
    std.debug.print("Imported {s}\nStart Plaza to use it.\n", .{npub});
}

/// Reads one secret line. On a terminal, echo is disabled so nothing is shown;
/// when stdin is a pipe, it just reads the line. The returned slice points into
/// `buf` (which the caller zeroes).
fn readSecret(io: std.Io, prompt: []const u8, buf: []u8) ?[]const u8 {
    _ = io;
    const stdin_fd: std.posix.fd_t = 0;
    // tcgetattr succeeds only on a terminal; a pipe returns an error, which is
    // how this tells interactive from piped without a separate isatty.
    const restore: ?std.posix.termios = std.posix.tcgetattr(stdin_fd) catch null;
    if (restore) |base| {
        std.debug.print("{s}", .{prompt});
        var quiet = base;
        quiet.lflag.ECHO = false;
        std.posix.tcsetattr(stdin_fd, .NOW, quiet) catch {};
    }
    defer if (restore) |base| {
        std.posix.tcsetattr(stdin_fd, .NOW, base) catch {};
        std.debug.print("\n", .{});
    };
    const n = std.posix.read(stdin_fd, buf) catch return null;
    if (n == 0) return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

/// POSTs an import to a running daemon over loopback. Returns null when nothing
/// is listening (so the caller writes the key directly), true on 200, false on
/// a rejection (e.g. a key already set up).
fn postSetup(io: std.Io, port: u16, token_path: []const u8, secret_input: []const u8, passphrase: []const u8) ?bool {
    const gpa = std.heap.page_allocator;
    const token = readTokenFile(gpa, io, token_path) orelse return null;
    defer gpa.free(token);
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
    var stream = addr.connect(io, .{ .mode = .stream }) catch return null;
    defer stream.close(io);

    var body_buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &body_buf);
    const body = std.fmt.bufPrint(&body_buf, "{{\"method\":\"import\",\"secret\":\"{s}\",\"passphrase\":\"{s}\"}}", .{ secret_input, passphrase }) catch return null;

    var req_buf: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &req_buf);
    const req = std.fmt.bufPrint(&req_buf, "POST /setup HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ token, body.len, body }) catch return null;

    var wbuf: [128]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    sw.interface.writeAll(req) catch return null;
    sw.interface.flush() catch return null;

    var rbuf: [512]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const n = sr.interface.readSliceShort(&rbuf) catch return null;
    return std.mem.indexOf(u8, rbuf[0..n], " 200 ") != null;
}

// -------------------------------------------------------------- http server

const net = std.Io.net;

fn serveLoop(gpa: std.mem.Allocator, io: std.Io, port: u16) void {
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch fail("bad loopback address");
    var server = addr.listen(io, .{ .reuse_address = true }) catch fail("cannot bind loopback");
    while (true) {
        const stream = server.accept(io) catch continue;
        const t = std.Thread.spawn(.{}, handle, .{ gpa, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn handle(gpa: std.mem.Allocator, stream: net.Stream) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer stream.close(io);
    handleConn(gpa, io, stream) catch {};
}

fn handleConn(gpa: std.mem.Allocator, io: std.Io, stream: net.Stream) !void {
    var read_storage: [4096]u8 = undefined;
    var write_storage: [4096]u8 = undefined;
    var sr = stream.reader(io, &read_storage);
    var sw = stream.writer(io, &write_storage);
    const w = &sw.interface;

    // Read the head plus whatever body bytes arrive with it. Secrets ride the
    // /setup body, so wipe the buffer before the frame unwinds.
    var buf: [65536]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var len: usize = 0;
    const head_end = while (true) {
        if (len >= buf.len) return respond(w, 431, "headers too large");
        var data: [1][]u8 = .{buf[len..]};
        const n = sr.interface.readVec(&data) catch return;
        if (n == 0) return;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |i| break i;
    };

    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
    const request_line = lines.next() orelse return respond(w, 400, "bad request");
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return respond(w, 400, "bad request");
    const path = parts.next() orelse return respond(w, 400, "bad request");

    var auth: []const u8 = "";
    var content_length: usize = 0;
    while (lines.next()) |line| {
        if (asciiStartsWithIgnoreCase(line, "authorization:")) {
            const v = std.mem.trim(u8, line["authorization:".len..], " ");
            auth = if (asciiStartsWithIgnoreCase(v, "bearer ")) v["bearer ".len..] else v;
        } else if (asciiStartsWithIgnoreCase(line, "content-length:")) {
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10) catch 0;
        }
    }

    // Every endpoint is authenticated. No token, no service.
    if (!tokenOk(g_token, auth)) return respond(w, 401, "unauthorized");

    // Gather the body (some may already be in `buf` after the head).
    const body_start = head_end + 4;
    var body: []const u8 = buf[body_start..len];
    if (content_length > body.len) {
        if (body_start + content_length > buf.len) return respond(w, 413, "body too large");
        const need = content_length - body.len;
        var got: usize = 0;
        while (got < need) {
            var data: [1][]u8 = .{buf[len .. len + (need - got)]};
            const n = sr.interface.readVec(&data) catch break;
            if (n == 0) break;
            len += n;
            got += n;
        }
        body = buf[body_start .. body_start + content_length];
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, ipc.path_pubkey)) {
        return handlePubkey(gpa, w);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, ipc.path_setup)) {
        return handleSetup(gpa, io, w, body);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, ipc.path_sign)) {
        return handleSign(gpa, io, w, body);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, ipc.path_nip44_encrypt)) {
        return handleCipher(gpa, io, w, body, .encrypt);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, ipc.path_nip44_decrypt)) {
        return handleCipher(gpa, io, w, body, .decrypt);
    }
    return respond(w, 404, "no such endpoint");
}

fn handlePubkey(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    var hexbuf: [64]u8 = undefined;
    const pk = g_state.pubkeyHex(&hexbuf);
    const body = ipc.Pubkey{
        .state = if (pk != null) ipc.state_ready else ipc.state_uninitialized,
        .pubkey = pk orelse "",
    };
    const json = body.toJson(gpa) catch return respond(w, 500, "out of memory");
    defer gpa.free(json);
    return respondJson(w, 200, json);
}

fn handleSetup(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, body: []const u8) !void {
    var parsed = ipc.parse(ipc.Setup, gpa, body) catch return respondErr(gpa, w, 400, "malformed setup");
    defer parsed.deinit();
    const req = parsed.value;

    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);

    if (std.mem.eql(u8, req.method, ipc.Setup.method_create)) {
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        const kp = signer.generateKeyPair(io) catch return respondErr(gpa, w, 500, "key generation failed");
        secret = kp.secret_key;
    } else if (std.mem.eql(u8, req.method, ipc.Setup.method_import)) {
        if (std.mem.startsWith(u8, req.secret, "ncryptsec1")) {
            secret = keystore.decryptKey(gpa, req.secret, req.passphrase) catch return respondErr(gpa, w, 400, "could not decrypt that key");
        } else if (std.mem.startsWith(u8, req.secret, "nsec1")) {
            secret = nostr.nip19.decodeNsec(gpa, req.secret) catch return respondErr(gpa, w, 400, "not a valid nsec");
        } else {
            return respondErr(gpa, w, 400, "paste an nsec or an ncryptsec");
        }
    } else {
        return respondErr(gpa, w, 400, "unknown setup method");
    }

    g_state.adopt(io, secret) catch |e| return switch (e) {
        error.AlreadyInitialized => respondErr(gpa, w, 409, "a key is already set up"),
        else => respondErr(gpa, w, 500, "could not store the key"),
    };
    return handlePubkey(gpa, w);
}

fn handleSign(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, body: []const u8) !void {
    var parsed = ipc.parse(ipc.SignEvent, gpa, body) catch return respondErr(gpa, w, 400, "malformed sign request");
    defer parsed.deinit();

    var unsigned = nostr.event.fromJson(gpa, parsed.value.event) catch return respondErr(gpa, w, 400, "not a valid event");
    defer unsigned.deinit();
    const ev = unsigned.value;

    // Rumors stay unsigned: kind 14 and 15 are the inner NIP-59 payloads that
    // must never carry a signature. Refuse, always.
    if (ev.kind == 14 or ev.kind == 15) return respondErr(gpa, w, 422, "kind 14 and 15 are never signed");

    var secret = g_state.take() orelse return respondErr(gpa, w, 409, "no key yet");
    defer std.crypto.secureZero(u8, &secret);
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return respondErr(gpa, w, 500, "bad key");

    const signed = nostr.event.create(gpa, signer, kp, ev.created_at, ev.kind, ev.tags, ev.content, null) catch return respondErr(gpa, w, 500, "signing failed");
    const json = nostr.event.toJson(gpa, signed) catch return respondErr(gpa, w, 500, "out of memory");
    defer gpa.free(json);
    const out = ipc.SignEvent{ .event = json };
    const out_json = out.toJson(gpa) catch return respondErr(gpa, w, 500, "out of memory");
    defer gpa.free(out_json);
    _ = io;
    return respondJson(w, 200, out_json);
}

fn handleCipher(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, body: []const u8, comptime dir: enum { encrypt, decrypt }) !void {
    var parsed = ipc.parse(ipc.Cipher, gpa, body) catch return respondErr(gpa, w, 400, "malformed cipher request");
    defer parsed.deinit();
    const req = parsed.value;

    var peer: [32]u8 = undefined;
    if (req.peer.len != 64 or (std.fmt.hexToBytes(&peer, req.peer) catch null) == null) {
        return respondErr(gpa, w, 400, "peer must be 32-byte hex");
    }

    var secret = g_state.take() orelse return respondErr(gpa, w, 409, "no key yet");
    defer std.crypto.secureZero(u8, &secret);
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Batched: N items in, N out, in order. Any item that fails aborts the
    // batch (the client asked for all of them).
    var out = std.ArrayList([]const u8).empty;
    defer {
        for (out.items) |item| gpa.free(item);
        out.deinit(gpa);
    }
    for (req.items) |item| {
        const result = switch (dir) {
            .encrypt => nostr.nip44.encrypt(gpa, io, signer, secret, peer, item),
            .decrypt => nostr.nip44.decrypt(gpa, signer, secret, peer, item),
        } catch return respondErr(gpa, w, 422, "a cipher item failed");
        out.append(gpa, result) catch return respondErr(gpa, w, 500, "out of memory");
    }
    const res = ipc.CipherResult{ .items = out.items };
    const json = res.toJson(gpa) catch return respondErr(gpa, w, 500, "out of memory");
    defer gpa.free(json);
    return respondJson(w, 200, json);
}

// ---------------------------------------------------------------- responses

fn respond(w: *std.Io.Writer, status: u16, message: []const u8) !void {
    const body = std.fmt.allocPrint(std.heap.page_allocator, "{{\"error\":\"{s}\"}}", .{message}) catch "{}";
    defer if (body.len > 2) std.heap.page_allocator.free(body);
    return respondJson(w, status, body);
}

fn respondErr(gpa: std.mem.Allocator, w: *std.Io.Writer, status: u16, message: []const u8) !void {
    const fail_body = ipc.Failure{ .@"error" = message };
    const json = fail_body.toJson(gpa) catch return respondJson(w, status, "{\"error\":\"error\"}");
    defer gpa.free(json);
    return respondJson(w, status, json);
}

fn respondJson(w: *std.Io.Writer, status: u16, json: []const u8) !void {
    try w.print("HTTP/1.1 {d} x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, json.len, json });
    try w.flush();
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (haystack[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

test {
    std.testing.refAllDecls(@This());
}

test "token comparison is length-checked and constant-time-ish" {
    try std.testing.expect(tokenOk("secrettoken", "secrettoken"));
    try std.testing.expect(!tokenOk("secrettoken", "secrettokeX"));
    try std.testing.expect(!tokenOk("secrettoken", "short"));
    try std.testing.expect(!tokenOk("", ""));
}

test "hex encoding is lowercase and full width" {
    var out: [64]u8 = undefined;
    const bytes = [_]u8{0xab} ** 32;
    try std.testing.expectEqualStrings("ab" ** 32, hexLower(&out, bytes));
}

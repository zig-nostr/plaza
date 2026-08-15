//! The bunker: `plaza-signer` answering NIP-46 for OTHER apps.
//!
//! Plaza already holds a key in a process separate from the one that renders
//! strangers' notes. This lets that same process be the signer for a web client
//! in a browser, so somebody can use Coracle or Jumble without an extension
//! holding their key.
//!
//! WHY THIS PROCESS AND NOT PLAZA'S UI: the whole reason `plaza-signer` exists
//! is that the UI runs image decoders and a relay JSON parser on bytes off the
//! wire, so the key must not live there. Serving NIP-46 from the UI would put a
//! relay-reachable signing loop inside exactly the process that separation was
//! built to protect. It goes here, beside the key, where the only other thing
//! running is a loopback HTTP server.
//!
//! OFF BY DEFAULT, and that is not timidity. Turning it on dials relays and
//! publishes a pubkey that anybody may then send requests to. An app nobody
//! asked to be a signer should not open that surface because it happens to hold
//! a key.
//!
//! WHAT GUARDS IT, in order:
//!
//!   1. The bunker URL carries a secret. Without it `connect` is refused, so
//!      reading the pubkey off a relay buys nothing.
//!   2. A client presenting the secret still has to be APPROVED by the reader,
//!      once, before it is authorized. The URL is a credential and credentials
//!      get shared by accident; a human confirming "this app may sign as you"
//!      is what stands between a leaked URL and a silent signer.
//!   3. Authorized clients are listed and revocable. A bunker you cannot audit
//!      is one you have to trust, which is the thing extensions are criticised
//!      for.
//!
//! Requests from a client that has not connected never reach approval at all:
//! the library refuses them before the policy is consulted.
//!
//! What is NOT here yet, said plainly because the difference matters: once a
//! client is approved it signs without a further prompt. Amber prompts per
//! method with a remembered duration (`RememberType` in its SettingsScreen),
//! which is the right shape and is the next slice. Until it lands, approving a
//! client is approving everything it will ever ask for, and the settings copy
//! says so.

const std = @import("std");
const nostr = @import("nostr");
const nip46 = nostr.nip46;
const keys = nostr.keys;

/// What the bunker serves on when the reader has not chosen.
///
/// Three, and they are Amber's (`defaultAppRelays`), for the reason a signer on
/// one relay is a signer that stops signing when that relay does, silently, with
/// the client left waiting on a request nothing will ever answer.
pub const default_relays = [_][]const u8{
    "wss://nostr.oxtr.dev",
    "wss://theforest.nostr1.com",
    "wss://relay.primal.net",
};

pub const max_clients = 16;
pub const max_pending = 8;

/// How long a connect request waits for the reader before it is refused.
///
/// Fails CLOSED. A prompt nobody answered is not consent, and a signer that
/// silently waits forever is worse than one that says no: the client sits on a
/// request that will never be answered and shows nothing.
pub const connect_decision_timeout_ms: u64 = 120_000;

pub const Decision = enum(u8) { pending, allow, deny };

/// A client waiting on the reader, as the UI and the tests see it.
pub const Waiting = struct { id: u64, client: [32]u8 };

/// A client asking to connect, waiting on the reader.
pub const Pending = struct {
    used: bool = false,
    id: u64 = 0,
    client: [32]u8 = [_]u8{0} ** 32,
    /// What the client called itself in its `nostrconnect://` token, or empty
    /// when it connected with a bunker URL and never said. Never trusted, only
    /// shown: it is a string a stranger chose, and the pubkey is the identity.
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    decision: std.atomic.Value(Decision) = .init(.pending),

    pub fn name(self: *const Pending) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// One client the reader has approved.
pub const Client = struct {
    used: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    approved_at: i64 = 0,

    pub fn name(self: *const Client) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The bunker's own state, shared by every relay thread and the HTTP server.
pub const Bunker = struct {
    lock_flag: std.atomic.Value(bool) = .init(false),
    /// Whether the reader has turned it on. Every relay thread checks this and
    /// parks when it goes false, so switching off actually stops serving rather
    /// than leaving threads dialling.
    enabled: std.atomic.Value(bool) = .init(false),
    /// Bumps whenever the queue or the client list changes, so the UI can poll
    /// with a cursor instead of re-reading everything every tick.
    version: std.atomic.Value(u64) = .init(0),

    secret_buf: [32]u8 = [_]u8{0} ** 32,
    secret_len: u8 = 0,

    pending: [max_pending]Pending = [_]Pending{.{}} ** max_pending,
    next_id: u64 = 1,
    clients: [max_clients]Client = [_]Client{.{}} ** max_clients,

    /// The connect state the library keeps, shared across every relay thread so
    /// a client that connected over one relay is recognised on another.
    authorized: nip46.AuthorizedClients = .{},
    seen: nostr.signer.SeenRequests = .{},

    fn acquire(self: *Bunker) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *Bunker) void {
        self.lock_flag.store(false, .release);
    }

    pub fn isEnabled(self: *Bunker) bool {
        return self.enabled.load(.acquire);
    }

    pub fn secret(self: *Bunker) []const u8 {
        return self.secret_buf[0..self.secret_len];
    }

    /// Turns the bunker on, minting a connect secret if there is not one.
    ///
    /// The secret is 32 hex characters from the OS CSPRNG. It is the only thing
    /// between a public pubkey and a connect attempt, so it is not derived from
    /// anything and not reused across accounts.
    pub fn enable(self: *Bunker, io: std.Io) void {
        self.acquire();
        if (self.secret_len == 0) {
            var raw: [16]u8 = undefined;
            // The OS CSPRNG through `io`, which is where this codebase gets
            // entropy (`keys.generate` uses the same call). A secret from
            // anything weaker is a secret worth guessing.
            io.randomSecure(&raw) catch {
                self.release();
                return;
            };
            const hex = "0123456789abcdef";
            for (raw, 0..) |b, i| {
                self.secret_buf[i * 2] = hex[b >> 4];
                self.secret_buf[i * 2 + 1] = hex[b & 0x0f];
            }
            self.secret_len = 32;
        }
        self.release();
        self.enabled.store(true, .release);
        _ = self.version.fetchAdd(1, .monotonic);
    }

    /// Turns it off and ends every session with it.
    ///
    /// Revoking on the way down is the point rather than tidiness: a client
    /// still holding an authorization would be recognised the moment the reader
    /// switched it back on, which is not what "off" means to anybody.
    pub fn disable(self: *Bunker) void {
        self.enabled.store(false, .release);
        self.authorized.clear();
        self.acquire();
        self.clients = [_]Client{.{}} ** max_clients;
        for (&self.pending) |*p| {
            if (p.used) p.decision.store(.deny, .release);
        }
        self.release();
        _ = self.version.fetchAdd(1, .monotonic);
    }

    /// Files a connect request and blocks this relay thread until the reader
    /// decides or the timeout refuses it.
    ///
    /// Blocking is what the library's policy hook gives us, and it is bounded:
    /// only an already-connected client can reach a signing policy, and this one
    /// is reached only by a `connect` carrying the right secret. A relay thread
    /// parked here is answering the one question a human has to answer.
    pub fn askToConnect(self: *Bunker, io: std.Io, client: [32]u8, client_name: []const u8) Decision {
        // Already approved: a reconnect after a dropped socket must not ask
        // again, or every flaky connection becomes a prompt.
        if (self.isKnown(client)) return .allow;

        const idx = self.file(client, client_name) orelse return .deny;
        const step_ms = 50;
        var waited: u64 = 0;
        var decision = self.pending[idx].decision.load(.acquire);
        while (decision == .pending and waited < connect_decision_timeout_ms) {
            io.sleep(std.Io.Duration.fromMilliseconds(step_ms), .awake) catch {};
            waited += step_ms;
            decision = self.pending[idx].decision.load(.acquire);
        }
        if (decision == .allow) self.remember(client, client_name);

        self.acquire();
        self.pending[idx] = .{};
        self.release();
        _ = self.version.fetchAdd(1, .monotonic);
        return if (decision == .allow) .allow else .deny;
    }

    fn file(self: *Bunker, client: [32]u8, client_name: []const u8) ?usize {
        self.acquire();
        defer self.release();
        for (&self.pending, 0..) |*p, i| {
            if (p.used) continue;
            p.* = .{ .used = true, .id = self.next_id, .client = client };
            const n = @min(client_name.len, p.name_buf.len);
            @memcpy(p.name_buf[0..n], client_name[0..n]);
            p.name_len = @intCast(n);
            self.next_id += 1;
            _ = self.version.fetchAdd(1, .monotonic);
            return i;
        }
        return null;
    }

    /// The first client waiting on the reader. The UI polls this; a test uses
    /// it to prove a client was ASKED rather than let in.
    pub fn firstPending(self: *Bunker) ?Waiting {
        self.acquire();
        defer self.release();
        for (self.pending) |p| {
            if (p.used and p.decision.load(.monotonic) == .pending) return .{ .id = p.id, .client = p.client };
        }
        return null;
    }

    pub fn isKnown(self: *Bunker, client: [32]u8) bool {
        self.acquire();
        defer self.release();
        for (self.clients) |c| {
            if (c.used and std.mem.eql(u8, &c.pubkey, &client)) return true;
        }
        return false;
    }

    fn remember(self: *Bunker, client: [32]u8, client_name: []const u8) void {
        self.acquire();
        defer self.release();
        for (&self.clients) |*c| {
            if (c.used) continue;
            c.* = .{ .used = true, .pubkey = client, .approved_at = 0 };
            const n = @min(client_name.len, c.name_buf.len);
            @memcpy(c.name_buf[0..n], client_name[0..n]);
            c.name_len = @intCast(n);
            return;
        }
    }

    /// The reader's answer to a waiting connect request.
    pub fn decide(self: *Bunker, id: u64, allow: bool) bool {
        self.acquire();
        defer self.release();
        for (&self.pending) |*p| {
            if (!p.used or p.id != id) continue;
            if (p.decision.load(.monotonic) != .pending) return false;
            p.decision.store(if (allow) .allow else .deny, .release);
            _ = self.version.fetchAdd(1, .monotonic);
            return true;
        }
        return false;
    }

    /// Ends one client's session. The library's set is cleared too, so the next
    /// request from it is refused rather than merely unlisted.
    pub fn revoke(self: *Bunker, client: [32]u8) bool {
        var found = false;
        self.acquire();
        for (&self.clients) |*c| {
            if (c.used and std.mem.eql(u8, &c.pubkey, &client)) {
                c.* = .{};
                found = true;
            }
        }
        self.release();
        if (!found) return false;
        // No per-client removal in the library's set, so every session is ended
        // and the survivors reconnect. Revoking is rare and correctness beats
        // convenience: leaving a revoked client authorized would be the one
        // failure this button exists to prevent.
        self.authorized.clear();
        self.acquire();
        var kept: [max_clients]Client = [_]Client{.{}} ** max_clients;
        var n: usize = 0;
        for (self.clients) |c| {
            if (!c.used) continue;
            kept[n] = c;
            n += 1;
        }
        self.clients = kept;
        self.release();
        _ = self.version.fetchAdd(1, .monotonic);
        return true;
    }
};

/// Builds the `bunker://` URL the reader hands to another app.
///
/// Every relay it serves on is named, because a client publishes its request to
/// all of them and one that only knew a single relay would fail the moment that
/// relay did.
pub fn uri(out: []u8, pubkey_hex: []const u8, relays: []const []const u8, secret: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(out);
    try w.writeAll("bunker://");
    try w.writeAll(pubkey_hex);
    var first = true;
    for (relays) |r| {
        try w.writeAll(if (first) "?" else "&");
        first = false;
        try w.writeAll("relay=");
        try writePercentEncoded(&w, r);
    }
    if (secret.len > 0) {
        try w.writeAll(if (first) "?" else "&");
        try w.writeAll("secret=");
        try writePercentEncoded(&w, secret);
    }
    return w.buffered();
}

fn writePercentEncoded(w: *std.Io.Writer, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0x0f]);
        }
    }
}

test "the bunker url names every relay and carries the secret" {
    var buf: [512]u8 = undefined;
    const relays = [_][]const u8{ "wss://a.example", "wss://b.example" };
    const url = try uri(&buf, "ab" ** 32, &relays, "s3cret");

    try std.testing.expect(std.mem.startsWith(u8, url, "bunker://" ++ "ab" ** 32));
    // Both, because a client publishes to all of them and one that knew only
    // the first would stop working the moment that relay did.
    try std.testing.expect(std.mem.indexOf(u8, url, "relay=wss%3A%2F%2Fa.example") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "relay=wss%3A%2F%2Fb.example") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "secret=s3cret") != null);
    // One `?`, then `&`. A second `?` is a URL a client will not parse.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, url, "?"));
}

test "turning the bunker off ends every session it had" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());
    try std.testing.expect(b.isEnabled());
    try std.testing.expect(b.secret().len == 32);

    const client = [_]u8{0x31} ** 32;
    b.remember(client, "Coracle");
    b.authorized.authorize(client);
    try std.testing.expect(b.isKnown(client));
    try std.testing.expect(b.authorized.isAuthorized(client));

    b.disable();
    // Both halves. Leaving the library's set populated would mean the client is
    // recognised again the instant the bunker is switched back on, which is not
    // what "off" means.
    try std.testing.expect(!b.isEnabled());
    try std.testing.expect(!b.isKnown(client));
    try std.testing.expect(!b.authorized.isAuthorized(client));
}

test "the secret survives a disable, so the url a reader handed out still works" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());
    var first: [32]u8 = undefined;
    @memcpy(&first, b.secret());

    b.disable();
    b.enable(threaded.io());
    // Re-minting it would silently invalidate a URL already pasted into another
    // app, and the reader would have no way to know why it stopped connecting.
    try std.testing.expectEqualStrings(&first, b.secret());
}

test "revoking one client keeps the others listed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());
    const a = [_]u8{0x41} ** 32;
    const c = [_]u8{0x42} ** 32;
    b.remember(a, "Coracle");
    b.remember(c, "Jumble");

    try std.testing.expect(b.revoke(a));
    try std.testing.expect(!b.isKnown(a));
    try std.testing.expect(b.isKnown(c));
    // Revoking something never approved is not an error, it is a no-op.
    try std.testing.expect(!b.revoke([_]u8{0x43} ** 32));
}

test "an approved client reconnecting is not asked again" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());
    const client = [_]u8{0x51} ** 32;
    b.remember(client, "Coracle");

    // A known client returns before anything blocks, so this cannot hang on the
    // 120s timeout. A dropped socket is an ordinary event, and prompting on
    // every reconnect would train the reader to approve without reading.
    try std.testing.expectEqual(Decision.allow, b.askToConnect(threaded.io(), client, "Coracle"));
}

/// Runs one `askToConnect` on its own thread so the test can answer it. Its own
/// `io` too, the way every thread in this codebase has one.
const AskCtx = struct {
    b: *Bunker,
    gpa: std.mem.Allocator,
    client: [32]u8,
    result: Decision = .pending,
};

fn askOnThread(ctx: *AskCtx) void {
    var threaded = std.Io.Threaded.init(ctx.gpa, .{});
    defer threaded.deinit();
    ctx.result = ctx.b.askToConnect(threaded.io(), ctx.client, "Coracle");
}

/// Waits for the queue to show a waiting client, without a wall clock.
fn waitForPending(b: *Bunker, io: std.Io) ?Waiting {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (b.firstPending()) |p| return p;
        io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    return null;
}

test "a client the reader has never seen is asked, not let in" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());

    // The whole security story rests on this. A client presenting the right
    // secret still has to be approved: the URL is a credential, credentials get
    // shared by accident, and without this a leaked URL is a silent signer.
    const stranger = [_]u8{0x61} ** 32;
    var ctx = AskCtx{ .b = &b, .gpa = std.testing.allocator, .client = stranger };
    const t = try std.Thread.spawn(.{}, askOnThread, .{&ctx});

    // It must be WAITING, not decided. If it had been let in there would be
    // nothing queued and the thread would already have returned allow.
    const asked = waitForPending(&b, threaded.io()) orelse return error.ClientWasNeverAsked;
    try std.testing.expectEqualSlices(u8, &stranger, &asked.client);
    try std.testing.expect(!b.isKnown(stranger));

    // Denying keeps it out, and out means out of the library's set too.
    try std.testing.expect(b.decide(asked.id, false));
    t.join();
    try std.testing.expectEqual(Decision.deny, ctx.result);
    try std.testing.expect(!b.isKnown(stranger));
    try std.testing.expect(!b.authorized.isAuthorized(stranger));
}

test "approving a waiting client remembers it, so it is listed and revocable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());

    const client = [_]u8{0x62} ** 32;
    var ctx = AskCtx{ .b = &b, .gpa = std.testing.allocator, .client = client };
    const t = try std.Thread.spawn(.{}, askOnThread, .{&ctx});

    const asked = waitForPending(&b, threaded.io()) orelse return error.ClientWasNeverAsked;
    try std.testing.expect(b.decide(asked.id, true));
    t.join();

    try std.testing.expectEqual(Decision.allow, ctx.result);
    // Listed, because a bunker whose clients you cannot see is one you have to
    // trust, and revocable for the same reason.
    try std.testing.expect(b.isKnown(client));
    try std.testing.expect(b.revoke(client));
    try std.testing.expect(!b.isKnown(client));
}

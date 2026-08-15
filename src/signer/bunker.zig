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
//! Connecting is not the same as being allowed to do things. A connected client
//! is asked again the first time it wants to sign, and separately per METHOD and
//! per event KIND, because signing a note and signing a contact list are
//! different risks: a bad kind:3 write empties somebody's follow list.
//!
//! Each answer carries how long it lasts, following Amber's `RememberType`:
//! once, an hour, a day, or always. A denial is remembered on the same terms,
//! because "no, and stop asking for an hour" is a real answer. An answer that
//! lapses leaves the question OPEN rather than becoming a denial, and a prompt
//! that times out is not written down at all: silence from a reader who walked
//! away is not a decision.
//!
//! `ping` and `get_public_key` are never asked about. They leak nothing a relay
//! does not already carry, and prompting for them is what teaches people to
//! approve without reading.

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
pub const max_permissions = 64;

/// What a client is asking to do. Only the three that need a decision: `ping`
/// and `get_public_key` leak nothing a relay does not already carry, and
/// `connect` is the client itself being let in.
pub const Ask = enum {
    sign_event,
    nip44_encrypt,
    nip44_decrypt,

    pub fn fromMethod(method: []const u8) ?Ask {
        if (std.mem.eql(u8, method, "sign_event")) return .sign_event;
        if (std.mem.eql(u8, method, "nip44_encrypt")) return .nip44_encrypt;
        if (std.mem.eql(u8, method, "nip44_decrypt")) return .nip44_decrypt;
        return null;
    }

    pub fn label(self: Ask) []const u8 {
        return switch (self) {
            .sign_event => "sign a note",
            .nip44_encrypt => "encrypt a message",
            .nip44_decrypt => "read an encrypted message",
        };
    }
};

/// How long an answer lasts.
///
/// Amber's `RememberType`, trimmed to four. Its eight steps are the right idea
/// at a granularity nobody uses; what matters is that "not now", "for a while"
/// and "stop asking" are all reachable in one press.
pub const Remember = enum(u8) {
    once,
    hour,
    day,
    always,

    pub fn millis(self: Remember) i64 {
        return switch (self) {
            // `once` is never stored, so it has no duration to ask for. This
            // was a 0 that made an already-expired record, which meant TWO
            // mechanisms held the same property and neither could be tested:
            // removing either left the other quietly covering for it. One
            // mechanism, and a caller that gets here is a bug that says so.
            .once => unreachable,
            .hour => 60 * 60 * 1000,
            .day => 24 * 60 * 60 * 1000,
            // Never lapses, so there is no moment to compute.
            .always => 0,
        };
    }
};

/// One remembered answer, keyed the way Amber keys it: the app, the method, and
/// for a signature the event KIND.
///
/// Per kind because signing a note and signing a contact list are different
/// risks. This app's own history is the argument: a bad kind:3 write empties
/// somebody's follow list, and "you allowed signing once" should not have
/// covered that.
///
/// Allow and deny each carry their own expiry, again following Amber. "No, and
/// stop asking for an hour" is a real answer, and folding it into one field
/// would make a denial either permanent or worthless.
pub const Permission = struct {
    used: bool = false,
    client: [32]u8 = [_]u8{0} ** 32,
    ask: Ask = .sign_event,
    /// The event kind for `sign_event`, or -1 for the methods that have none.
    kind: i32 = -1,
    allow: bool = false,
    /// When it lapses. Zero means never, which is what `always` stores.
    until_ms: i64 = 0,

    fn matches(self: *const Permission, client: [32]u8, ask: Ask, kind: i32) bool {
        return self.used and self.ask == ask and self.kind == kind and
            std.mem.eql(u8, &self.client, &client);
    }

    fn live(self: *const Permission, now_ms: i64) bool {
        return self.until_ms == 0 or now_ms < self.until_ms;
    }
};

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
    /// What is being asked. Null for a `connect`, which is the client itself
    /// asking to be let in rather than asking to do something.
    ask: ?Ask = null,
    kind: i32 = -1,
    /// How long the reader's answer should last, written by the UI beside the
    /// decision itself.
    remember: std.atomic.Value(Remember) = .init(.once),

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
    permissions: [max_permissions]Permission = [_]Permission{.{}} ** max_permissions,

    /// How long a prompt waits, as a field rather than the constant, so a test
    /// can drive the timeout without waiting two minutes for it.
    decision_timeout_ms: u64 = connect_decision_timeout_ms,

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
        while (decision == .pending and waited < self.decision_timeout_ms) {
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

    /// The first waiting request in full: who, and what they want.
    pub fn firstPendingFull(self: *Bunker) ?struct { id: u64, client: [32]u8, ask: ?Ask, kind: i32 } {
        self.acquire();
        defer self.release();
        for (self.pending) |p| {
            if (p.used and p.decision.load(.monotonic) == .pending) {
                return .{ .id = p.id, .client = p.client, .ask = p.ask, .kind = p.kind };
            }
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

    /// Whether this client may do this, without asking anybody.
    ///
    /// Null when nothing has been remembered and the reader has to be asked. A
    /// LAPSED permission is null too rather than a denial: "allow for an hour"
    /// expiring means the question is open again, not that the answer became no.
    pub fn remembered(self: *Bunker, client: [32]u8, ask: Ask, kind: i32, now_ms: i64) ?bool {
        self.acquire();
        defer self.release();
        for (&self.permissions) |*perm| {
            if (!perm.matches(client, ask, kind)) continue;
            if (!perm.live(now_ms)) {
                perm.* = .{};
                continue;
            }
            return perm.allow;
        }
        return null;
    }

    /// Writes the reader's answer down for as long as they asked.
    ///
    /// `once` stores nothing: the answer covered this request and the next one
    /// is a fresh question, which is the whole meaning of once.
    pub fn rememberAnswer(self: *Bunker, client: [32]u8, ask: Ask, kind: i32, allow: bool, how_long: Remember, now_ms: i64) void {
        if (how_long == .once) return;
        const until: i64 = if (how_long == .always) 0 else now_ms + how_long.millis();
        self.acquire();
        defer self.release();
        // An existing answer for the same question is replaced, not added
        // beside: two records for one question is a coin toss over which is
        // read, and the reader's latest word is the one that counts.
        for (&self.permissions) |*perm| {
            if (!perm.matches(client, ask, kind)) continue;
            perm.allow = allow;
            perm.until_ms = until;
            _ = self.version.fetchAdd(1, .monotonic);
            return;
        }
        for (&self.permissions) |*perm| {
            if (perm.used) continue;
            perm.* = .{ .used = true, .client = client, .ask = ask, .kind = kind, .allow = allow, .until_ms = until };
            _ = self.version.fetchAdd(1, .monotonic);
            return;
        }
    }

    /// Asks the reader whether this client may do this, and remembers the answer
    /// for as long as they said.
    pub fn askTo(self: *Bunker, io: std.Io, client: [32]u8, ask: Ask, kind: i32) Decision {
        const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (self.remembered(client, ask, kind, now_ms)) |allowed| {
            return if (allowed) .allow else .deny;
        }

        const idx = self.fileAsk(client, ask, kind) orelse return .deny;
        const step_ms = 50;
        var waited: u64 = 0;
        var decision = self.pending[idx].decision.load(.acquire);
        while (decision == .pending and waited < self.decision_timeout_ms) {
            io.sleep(std.Io.Duration.fromMilliseconds(step_ms), .awake) catch {};
            waited += step_ms;
            decision = self.pending[idx].decision.load(.acquire);
        }
        const how_long = self.pending[idx].remember.load(.acquire);
        // Only a real answer is written down. A timeout refuses this request and
        // leaves the question open, because nobody said no: remembering silence
        // as a denial would lock a client out for an hour over a reader who was
        // away from the machine.
        if (decision != .pending) {
            self.rememberAnswer(client, ask, kind, decision == .allow, how_long, now_ms);
        }

        self.acquire();
        self.pending[idx] = .{};
        self.release();
        _ = self.version.fetchAdd(1, .monotonic);
        return if (decision == .allow) .allow else .deny;
    }

    fn fileAsk(self: *Bunker, client: [32]u8, ask: Ask, kind: i32) ?usize {
        self.acquire();
        defer self.release();
        for (&self.pending, 0..) |*p, i| {
            if (p.used) continue;
            p.* = .{ .used = true, .id = self.next_id, .client = client, .ask = ask, .kind = kind };
            self.next_id += 1;
            _ = self.version.fetchAdd(1, .monotonic);
            return i;
        }
        return null;
    }

    /// The reader's answer to a waiting connect request.
    pub fn decide(self: *Bunker, id: u64, allow: bool) bool {
        return self.decideFor(id, allow, .once);
    }

    /// The same, with how long it should last.
    pub fn decideFor(self: *Bunker, id: u64, allow: bool, how_long: Remember) bool {
        self.acquire();
        defer self.release();
        for (&self.pending) |*p| {
            if (!p.used or p.id != id) continue;
            if (p.decision.load(.monotonic) != .pending) return false;
            // The duration first, so the waiting thread cannot wake on the
            // decision and read a remember value that has not been written yet.
            p.remember.store(how_long, .release);
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

/// Starts one relay thread per default relay.
///
/// Called once, when the reader turns the bunker on. The threads outlive a
/// switch-off: they see `enabled` go false, finish whatever they were doing and
/// return, which is what makes turning it off actually stop serving rather than
/// leaving sockets open. Turning it on again starts fresh ones.
pub fn start(gpa: std.mem.Allocator, b: *Bunker, secret_key: [32]u8) void {
    for (default_relays) |url| {
        const t = std.Thread.spawn(.{}, serveRelay, .{ gpa, b, url, secret_key }) catch |err| {
            // Said out loud rather than swallowed: a bunker that is on and
            // serving two relays instead of three is a thing the reader would
            // want to know, and it looks like nothing from the outside.
            std.debug.print("plaza-signer: bunker relay {s} did not start ({s})\n", .{ url, @errorName(err) });
            continue;
        };
        t.detach();
    }
}

/// The policy the library consults on a `connect`.
///
/// It holds the bunker, so `decide` can file the request and park this relay
/// thread until the reader answers. Blocking here is what the library's hook
/// gives us and it is bounded two ways: only `connect` reaches it (every other
/// method is refused first for a client that has not connected), and the wait
/// fails closed after two minutes.
pub const ConnectPolicy = struct {
    b: *Bunker,
    io: std.Io,

    pub fn asPolicy(self: *const ConnectPolicy) nip46.Policy {
        return .{ .ctx = @constCast(self), .decideFn = decide };
    }

    fn decide(ctx: ?*anyopaque, request: *const nip46.Request, client: [32]u8) nip46.Decision {
        const self: *ConnectPolicy = @ptrCast(@alignCast(ctx.?));
        // A signer that has been switched off answers nothing, including to a
        // client it approved earlier. The relay threads are winding down, and
        // one that is mid-request must not sign on the way out.
        if (!self.b.isEnabled()) return .reject;
        // `ping` is how a client checks the socket is alive. Asking a human
        // about it is what trains people to stop reading prompts.
        if (std.mem.eql(u8, request.method, "ping")) return .approve;
        if (!std.mem.eql(u8, request.method, "connect")) {
            // Reaching here means the library already established this client
            // connected. What it may DO is a separate question, asked per method
            // and, for a signature, per event kind.
            const ask = Ask.fromMethod(request.method) orelse return .approve;
            const kind: i32 = if (ask == .sign_event) templateKind(request) else -1;
            return switch (self.b.askTo(self.io, client, ask, kind)) {
                .allow => .approve,
                else => .reject,
            };
        }
        return switch (self.b.askToConnect(self.io, client, "")) {
            .allow => .approve,
            else => .reject,
        };
    }
};

/// The `kind` out of a `sign_event` request's template.
///
/// Read rather than trusted for anything but the prompt and the permission key:
/// it is a number in JSON a client wrote, and the event it actually signs is
/// built from that same template by the library. Unreadable means -1, which
/// buckets with "no kind" and asks separately rather than silently reusing the
/// permission granted for some other kind.
fn templateKind(request: *const nip46.Request) i32 {
    if (request.params.len < 1) return -1;
    const Template = struct { kind: i32 = -1 };
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSlice(Template, fba.allocator(), request.params[0], .{
        .ignore_unknown_fields = true,
    }) catch return -1;
    defer parsed.deinit();
    return parsed.value.kind;
}

/// Serves one relay until the connection drops or the bunker is switched off.
///
/// One thread per relay, each with its own `io` and its own secp256k1 context,
/// which is why the connect state and the answered-request record are the
/// caller's and shared: a client that connected over one relay has to be
/// recognised on another, and one intent arriving on three relays must be
/// answered once.
pub fn serveRelay(
    gpa: std.mem.Allocator,
    b: *Bunker,
    url: []const u8,
    secret_key: [32]u8,
) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret_key) catch return;

    var policy = ConnectPolicy{ .b = b, .io = io };
    var nip46_bunker = nip46.Bunker.initSingleKey(signer, kp, policy.asPolicy(), &b.authorized);
    nip46_bunker.secret = b.secret();

    while (b.isEnabled()) {
        serveOnce(gpa, io, b, url, &nip46_bunker, kp) catch {};
        if (!b.isEnabled()) break;
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

fn serveOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *Bunker,
    url: []const u8,
    nip46_bunker: *nip46.Bunker,
    remote: keys.KeyPair,
) !void {
    var relay = try nostr.relay.dial(gpa, io, url);
    defer relay.deinit();
    try nostr.signer.serve(gpa, io, relay, nip46_bunker, remote, url, &b.seen);
}

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

test "a switched-off bunker signs nothing, even for a client it approved" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());

    const client = [_]u8{0x71} ** 32;
    b.remember(client, "Coracle");
    // Standing permission, so this test is about the switch and not about the
    // prompt: without one, signing asks, which is what the per-method change
    // made it do.
    b.rememberAnswer(client, .sign_event, 1, true, .always, 0);
    var policy = ConnectPolicy{ .b = &b, .io = threaded.io() };
    const p = policy.asPolicy();

    const sign = nip46.Request{ .id = "1", .method = "sign_event", .params = &.{"{\"kind\":1}"} };
    try std.testing.expectEqual(nip46.Decision.approve, p.decide(&sign, client));

    // Off means off. The relay threads are winding down and one mid-request
    // must not sign on the way out, which is the window a reader who just
    // pressed the switch is most likely to care about.
    b.disable();
    try std.testing.expectEqual(nip46.Decision.reject, p.decide(&sign, client));
}

test "ping never asks a human" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());

    var policy = ConnectPolicy{ .b = &b, .io = threaded.io() };
    const p = policy.asPolicy();
    const ping = nip46.Request{ .id = "1", .method = "ping", .params = &.{} };

    // A stranger's ping is answered without a prompt and without approving
    // them. Clients ping to check the socket; a prompt for each one is what
    // teaches people to approve without reading.
    const stranger = [_]u8{0x72} ** 32;
    try std.testing.expectEqual(nip46.Decision.approve, p.decide(&ping, stranger));
    try std.testing.expect(!b.isKnown(stranger));
    try std.testing.expect(b.firstPending() == null);
}

test "a remembered answer covers only the question it answered" {
    var b = Bunker{};
    const client = [_]u8{0x81} ** 32;
    const now: i64 = 1_000_000;

    // Nothing remembered yet: every question is open.
    try std.testing.expect(b.remembered(client, .sign_event, 1, now) == null);

    b.rememberAnswer(client, .sign_event, 1, true, .always, now);
    try std.testing.expectEqual(true, b.remembered(client, .sign_event, 1, now).?);

    // A DIFFERENT KIND is a different question. Signing a note and signing a
    // contact list are different risks, and this app's own history is the
    // argument: a bad kind:3 write empties somebody's follow list.
    try std.testing.expect(b.remembered(client, .sign_event, 3, now) == null);
    // A different method is too.
    try std.testing.expect(b.remembered(client, .nip44_decrypt, -1, now) == null);
    // And a different client, which is the one that would be a real breach.
    try std.testing.expect(b.remembered([_]u8{0x82} ** 32, .sign_event, 1, now) == null);
}

test "a denial is remembered, and both kinds of answer lapse" {
    var b = Bunker{};
    const client = [_]u8{0x83} ** 32;
    const now: i64 = 1_000_000;

    // "No, and stop asking for an hour" is a real answer. Folding it into the
    // same field as an allow would make a denial either permanent or worthless.
    b.rememberAnswer(client, .nip44_decrypt, -1, false, .hour, now);
    try std.testing.expectEqual(false, b.remembered(client, .nip44_decrypt, -1, now).?);
    try std.testing.expectEqual(false, b.remembered(client, .nip44_decrypt, -1, now + 59 * 60 * 1000).?);

    // Lapsed answers are NULL, not denials: an hour running out means the
    // question is open again, not that the answer became no.
    try std.testing.expect(b.remembered(client, .nip44_decrypt, -1, now + 61 * 60 * 1000) == null);

    b.rememberAnswer(client, .sign_event, 1, true, .day, now);
    try std.testing.expectEqual(true, b.remembered(client, .sign_event, 1, now + 23 * 60 * 60 * 1000).?);
    try std.testing.expect(b.remembered(client, .sign_event, 1, now + 25 * 60 * 60 * 1000) == null);
}

test "once is not written down" {
    var b = Bunker{};
    const client = [_]u8{0x84} ** 32;
    const now: i64 = 1_000_000;

    // The answer covered this request and the next one is a fresh question,
    // which is the whole meaning of once.
    b.rememberAnswer(client, .sign_event, 1, true, .once, now);
    try std.testing.expect(b.remembered(client, .sign_event, 1, now) == null);
}

test "the reader's latest word replaces the earlier one" {
    var b = Bunker{};
    const client = [_]u8{0x85} ** 32;
    const now: i64 = 1_000_000;

    b.rememberAnswer(client, .sign_event, 1, true, .always, now);
    b.rememberAnswer(client, .sign_event, 1, false, .always, now);
    // One record per question. Two would be a coin toss over which is read.
    try std.testing.expectEqual(false, b.remembered(client, .sign_event, 1, now).?);
    var records: usize = 0;
    for (b.permissions) |perm| {
        if (perm.used) records += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), records);
}

test "an unreadable template asks separately rather than reusing a permission" {
    var b = Bunker{};
    const client = [_]u8{0x86} ** 32;
    const now: i64 = 1_000_000;

    // A client's template is JSON it wrote. If the kind cannot be read it
    // buckets as -1, and must NOT quietly ride on the permission granted for
    // some other kind.
    b.rememberAnswer(client, .sign_event, 1, true, .always, now);
    try std.testing.expect(b.remembered(client, .sign_event, -1, now) == null);

    const bad = nip46.Request{ .id = "1", .method = "sign_event", .params = &.{"not json"} };
    try std.testing.expectEqual(@as(i32, -1), templateKind(&bad));
    const none = nip46.Request{ .id = "1", .method = "sign_event", .params = &.{} };
    try std.testing.expectEqual(@as(i32, -1), templateKind(&none));
    const ok = nip46.Request{ .id = "1", .method = "sign_event", .params = &.{"{\"kind\":30023,\"content\":\"x\"}"} };
    try std.testing.expectEqual(@as(i32, 30023), templateKind(&ok));
}

const TimeoutCtx = struct {
    b: *Bunker,
    gpa: std.mem.Allocator,
    client: [32]u8,
    result: Decision = .pending,
};

fn askAndTimeOut(ctx: *TimeoutCtx) void {
    var threaded = std.Io.Threaded.init(ctx.gpa, .{});
    defer threaded.deinit();
    ctx.result = ctx.b.askTo(threaded.io(), ctx.client, .sign_event, 1);
}

test "a prompt nobody answered is refused, and not written down" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var b = Bunker{};
    b.enable(threaded.io());
    b.decision_timeout_ms = 150;

    const client = [_]u8{0x87} ** 32;
    var ctx = TimeoutCtx{ .b = &b, .gpa = std.testing.allocator, .client = client };
    const t = try std.Thread.spawn(.{}, askAndTimeOut, .{&ctx});
    t.join();

    // Refused, because a prompt nobody answered is not consent.
    try std.testing.expectEqual(Decision.deny, ctx.result);

    // But NOT remembered as a denial. A reader who walked away from the machine
    // said nothing, and turning silence into "no for an hour" would lock an app
    // out over an absence. The question stays open.
    const now = std.Io.Timestamp.now(threaded.io(), .real).toMilliseconds();
    try std.testing.expect(b.remembered(client, .sign_event, 1, now) == null);
}

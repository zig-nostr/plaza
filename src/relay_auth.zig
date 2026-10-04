//! Relay AUTH (NIP-42): the reader's choice per relay, challenges, signing, and resending what was refused.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const activePubkey = main.activePubkey;
const answerHelperAuthForTest = main.answerHelperAuthForTest;
const helperFetch = main.helperFetch;
const hexLower = main.hexLower;
const isFeedSub = main.isFeedSub;
const isRelayUrl = main.isRelayUrl;
const max_relays = main.max_relays;
const newRequestId = main.newRequestId;
const no_half_id = main.no_half_id;
const nowSeconds = main.nowSeconds;
const plazaDir = main.plazaDir;
const registerPending = main.registerPending;
const relayAt = main.relayAt;
const relaySnapshot = main.relaySnapshot;
const relayUrlEql = main.relayUrlEql;
const secret_file_permissions = main.secret_file_permissions;
const sendRequest = main.sendRequest;

/// The longest challenge Plaza will sign. NIP-42 leaves it an arbitrary string;
/// real relays send a few dozen bytes. One past this is not a challenge worth
/// putting inside a signed event.
const auth_challenge_cap = 256;
/// The signed event as JSON: id, pubkey and sig (256 hex), the relay address
/// (96), the challenge (256, doubled if every byte needs escaping), and the keys.
const auth_event_cap = 1536;
/// How long a signature may be out before it is given up on.
const auth_sign_timeout_s: i64 = 30;
/// A relay that refused a subscription for want of AUTH and then never sent a
/// challenge is not going to. Past this the connection is dropped and re-dialed,
/// which is what a refused feed did before AUTH was understood at all.
pub const auth_gate_wait_ms: i64 = 20_000;

/// What the reader has said about identifying themselves to one relay.
pub const AuthChoice = enum(u8) { ask, allow, deny };

const max_auth_choices = 128;
/// `$HOME/.plaza/relay-auth`: one `allow <pubkey> <url>` or `deny <pubkey> <url>`
/// per line, the pubkey in hex naming the account the answer was given for.
/// Beside the relay list and the other local settings, and nowhere near a key.
const auth_choices_file = "relay-auth";
/// Written here first and renamed over the real one, so a crash mid-write
/// leaves the old file whole rather than a last line cut short. A cut line
/// could still be a relay address, just a different relay's.
const auth_choices_tmp = "relay-auth.tmp";
/// A line is the word, 64 hex, the address (96 at most) and three separators.
const auth_choices_file_cap = max_auth_choices * 176 + 64;

const AuthChoiceEntry = struct {
    used: bool = false,
    allow: bool = false,
    /// Whose answer it is. Saying yes as one account says nothing about
    /// another: the relay learns a different person.
    account: [32]u8 = [_]u8{0} ** 32,
    url_len: u8 = 0,
    url_buf: [96]u8 = [_]u8{0} ** 96,

    fn url(self: *const AuthChoiceEntry) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

/// Where one relay's challenge has got to.
const AuthPhase = enum(u8) {
    /// Nothing has been asked of us on this connection. A challenge may be held
    /// in the slot, but no relay has refused anything for want of it yet.
    idle,
    /// Waiting for the reader to say yes or no.
    asking,
    /// Allowed. The UI tick has to get it signed.
    want_sign,
    /// A signer has the request.
    signing,
    /// `event` holds the signed reply, for the reader thread to send.
    signed,
    /// On the wire, waiting for the relay's OK.
    sent,
    /// The reader said no, now or earlier.
    declined,
    /// There is no key to identify with: a guest.
    no_key,
    /// The signer failed, or the relay refused the reply.
    failed,
    /// The relay accepted it.
    done,
};

const AuthSlot = struct {
    phase: AuthPhase = .idle,
    /// The relay has refused something for want of AUTH. This is what turns a
    /// held challenge into a question for the reader: a relay that merely greets
    /// with a challenge is never asked about and never answered.
    gated: bool = false,
    deadline_s: i64 = 0,
    /// The account the signer was asked to sign as.
    signing_as: [32]u8 = [_]u8{0} ** 32,
    challenge_len: u16 = 0,
    challenge: [auth_challenge_cap]u8 = [_]u8{0} ** auth_challenge_cap,
    event_len: u16 = 0,
    event: [auth_event_cap]u8 = [_]u8{0} ** auth_event_cap,
};

var g_auth_lock = std.atomic.Value(bool).init(false);
pub var g_auth_choices: [max_auth_choices]AuthChoiceEntry = @splat(.{});
pub var g_auth_slots: [max_relays]AuthSlot = @splat(.{});

pub fn authLock() void {
    while (g_auth_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn authUnlock() void {
    g_auth_lock.store(false, .release);
}

fn authChoiceLocked(account: [32]u8, url: []const u8) AuthChoice {
    for (&g_auth_choices) |*e| {
        if (!e.used or !std.mem.eql(u8, &e.account, &account)) continue;
        if (relayUrlEql(e.url(), url)) return if (e.allow) .allow else .deny;
    }
    return .ask;
}

/// What `account` has said about `url`, or `.ask` when it has not.
pub fn authChoiceOf(account: [32]u8, url: []const u8) AuthChoice {
    authLock();
    defer authUnlock();
    return authChoiceLocked(account, url);
}

/// What the signed-in reader has said about `url`. `.ask` for a guest, who has
/// nothing to say yes with.
pub fn authChoiceFor(url: []const u8) AuthChoice {
    const me = activePubkey() orelse return .ask;
    return authChoiceOf(me, url);
}

/// Records `account`'s choice for `url`. `.ask` forgets it. False when there is
/// no room, in which case nothing was recorded and the next challenge asks
/// again, which is the safe way to fail.
pub fn setAuthChoice(account: [32]u8, url: []const u8, choice: AuthChoice) bool {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    if (trimmed.len == 0 or trimmed.len > 96) return false;
    authLock();
    defer authUnlock();
    for (&g_auth_choices) |*e| {
        if (!e.used or !std.mem.eql(u8, &e.account, &account)) continue;
        if (!relayUrlEql(e.url(), trimmed)) continue;
        if (choice == .ask) e.* = .{} else e.allow = choice == .allow;
        return true;
    }
    if (choice == .ask) return true;
    for (&g_auth_choices) |*e| {
        if (e.used) continue;
        e.* = .{ .used = true, .allow = choice == .allow, .account = account, .url_len = @intCast(trimmed.len) };
        @memcpy(e.url_buf[0..trimmed.len], trimmed);
        return true;
    }
    return false;
}

/// Reads the file's TEXT into the table. Split from the io so the format has a
/// test, the same as the relay list's.
pub fn applyAuthChoicesFile(raw: []const u8) void {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const word = parts.next() orelse continue;
        // A line with no account on it (`allow <url>`, the shape before answers
        // were per account) says nothing about whom it was said for, so it is
        // skipped and that relay is asked about again.
        const hex = parts.next() orelse continue;
        const url = parts.next() orelse continue;
        if (parts.next() != null) continue;
        if (hex.len != 64) continue;
        var account: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&account, hex) catch continue;
        // Only an address this app would dial. A hand-edited line naming
        // anything else is not a decision about a relay.
        if (!isRelayUrl(url)) continue;
        if (std.mem.eql(u8, word, "allow")) {
            _ = setAuthChoice(account, url, .allow);
        } else if (std.mem.eql(u8, word, "deny")) {
            _ = setAuthChoice(account, url, .deny);
        }
    }
}

pub fn formatAuthChoicesFile(buf: []u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    authLock();
    defer authUnlock();
    for (&g_auth_choices) |*e| {
        if (!e.used) continue;
        var hex: [64]u8 = undefined;
        hexLower(&hex, e.account);
        w.print("{s} {s} {s}\n", .{ if (e.allow) "allow" else "deny", hex[0..], e.url() }) catch return null;
    }
    return w.buffered();
}

pub fn loadAuthChoices(io: std.Io, environ: *const std.process.Environ.Map) void {
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var buf: [auth_choices_file_cap]u8 = undefined;
    const raw = dir.readFile(io, auth_choices_file, &buf) catch return;
    applyAuthChoicesFile(raw);
}

fn saveAuthChoices() void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var buf: [auth_choices_file_cap]u8 = undefined;
    const text = formatAuthChoicesFile(&buf) orelse return;
    dir.writeFile(io, .{
        .sub_path = auth_choices_tmp,
        .data = text,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch return;
    dir.rename(auth_choices_tmp, dir, auth_choices_file, io) catch {};
}

/// What to do about a challenge, given who the reader is and what they said.
/// Called with the lock held; `account` is read before it is taken.
fn authDecideLocked(account: ?[32]u8, url: []const u8) AuthPhase {
    const me = account orelse return .no_key;
    return switch (authChoiceLocked(me, url)) {
        .allow => .want_sign,
        .deny => .declined,
        .ask => .asking,
    };
}

/// A fresh connection on `index`, or one that has just ended: nothing from the
/// last one applies to the next.
pub fn authSlotReset(index: usize) void {
    if (index >= max_relays) return;
    authLock();
    defer authUnlock();
    g_auth_slots[index] = .{};
}

/// The relay on `index` sent a challenge. It is kept as the latest one and
/// nothing else happens, unless the relay has already refused something for want
/// of it, in which case this is the challenge that was being waited for.
/// Returns where that leaves the slot.
fn authSlotChallenge(index: usize, url: []const u8, challenge: []const u8) AuthPhase {
    if (index >= max_relays) return .idle;
    const me = activePubkey();
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    s.event_len = 0;
    if (challenge.len == 0 or challenge.len > auth_challenge_cap) {
        s.challenge_len = 0;
        if (s.gated) s.phase = .failed;
        return s.phase;
    }
    @memcpy(s.challenge[0..challenge.len], challenge);
    s.challenge_len = @intCast(challenge.len);
    s.phase = if (s.gated) authDecideLocked(me, url) else .idle;
    return s.phase;
}

/// Looks again at a challenge that is waiting on something the reader can
/// change: signing in, switching account, or answering from the relay's row.
///
/// `pressed` is true when the reader has just answered. Only then does a failed
/// exchange get another go: a signer that timed out while a person was away
/// otherwise left the relay refusing for the life of the socket. Never on the
/// reader thread's own wake, or a signer that keeps refusing would be asked
/// again every thirty seconds.
fn authSlotReevaluate(index: usize, url: []const u8, pressed: bool) void {
    if (index >= max_relays) return;
    const me = activePubkey();
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    if (s.challenge_len == 0) return;
    switch (s.phase) {
        // `want_sign` is in the list so that changing the badge from identify to
        // anonymous before the tick has asked for a signature takes effect. Once
        // a signer has the request it is too late to recall, and the send checks
        // the choice again.
        .asking, .declined, .no_key, .want_sign => s.phase = authDecideLocked(me, url),
        .failed => if (pressed) {
            s.phase = authDecideLocked(me, url);
        },
        else => {},
    }
}

/// A composed reply that may not go out after all: the reader said no while it
/// was on its way, or is now a different account than the one it names. The
/// slot is decided again for whoever is signed in now, so a yes from the new
/// account gets its own signature and a no sends nothing.
fn authSlotDiscardSigned(index: usize, url: []const u8) void {
    if (index >= max_relays) return;
    const me = activePubkey();
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    s.event_len = 0;
    s.phase = authDecideLocked(me, url);
}

/// The relay on `index` refused something for want of AUTH. This is the moment
/// the reader's choice is consulted, with the challenge the relay last sent. With
/// none held yet the slot waits for one.
fn authSlotGate(index: usize, url: []const u8) void {
    if (index >= max_relays) return;
    const me = activePubkey();
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    s.gated = true;
    if (s.challenge_len != 0 and s.phase == .idle) s.phase = authDecideLocked(me, url);
}

pub fn authSlotPhase(index: usize) AuthPhase {
    if (index >= max_relays) return .idle;
    authLock();
    defer authUnlock();
    return g_auth_slots[index].phase;
}

fn authSlotGated(index: usize) bool {
    if (index >= max_relays) return false;
    authLock();
    defer authUnlock();
    return g_auth_slots[index].gated;
}

const AuthAsking = struct {
    /// The first relay waiting on the reader's answer, the one the notice names.
    first: usize,
    /// How many are waiting, that one included.
    count: usize,
};

/// Who is waiting on the reader, in ONE pass under the lock. The notice needs
/// both halves, and taking them in two passes let a reader thread clear the
/// slot in between: a first relay and a count of zero, and `count - 1` below
/// zero.
pub fn authAskingSummary() ?AuthAsking {
    authLock();
    defer authUnlock();
    var out: ?AuthAsking = null;
    for (&g_auth_slots, 0..) |*s, i| {
        // A relay that has left the list cannot be asked about, and must not
        // stand in front of one that still can.
        if (s.phase != .asking or relayAt(i) == null) continue;
        if (out) |*o| o.count += 1 else out = .{ .first = i, .count = 1 };
    }
    return out;
}

/// The first relay waiting on the reader's answer, for the notice.
pub fn authAsking() ?usize {
    const a = authAskingSummary() orelse return null;
    return a.first;
}

/// How many relays are waiting on the reader, so the notice can say there are
/// more behind the one it names.
pub fn authAskingCount() usize {
    const a = authAskingSummary() orelse return 0;
    return a.count;
}

/// Claims an allowed challenge for signing. Returns its length, with the bytes
/// in `out`, or null when this slot has nothing to sign.
///
/// Decided again here, for the account signed in at this moment. `want_sign`
/// was decided for whoever was signed in when the challenge came or when the
/// reader thread last woke, and a switch of account in between must not turn
/// one account's yes into a signature from another.
fn authBeginSigning(index: usize, url: []const u8, out: *[auth_challenge_cap]u8) ?usize {
    if (index >= max_relays) return null;
    const me = activePubkey();
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    if (s.phase != .want_sign) return null;
    s.phase = authDecideLocked(me, url);
    if (s.phase != .want_sign) return null;
    const n: usize = s.challenge_len;
    @memcpy(out[0..n], s.challenge[0..n]);
    s.signing_as = me.?;
    s.phase = .signing;
    s.deadline_s = nowSeconds() + auth_sign_timeout_s;
    return n;
}

/// A signature that did not come: the signer refused, timed out, or answered
/// with something unusable. Only moves a slot that is actually waiting on one.
pub fn authFailSigning(index: usize) void {
    if (index >= max_relays) return;
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    if (s.phase == .signing) s.phase = .failed;
}

/// Retires signatures that have been out too long.
pub fn authSweep(now_s: i64) void {
    authLock();
    defer authUnlock();
    for (&g_auth_slots) |*s| {
        if (s.phase == .signing and now_s >= s.deadline_s) s.phase = .failed;
    }
}

/// A signed event has come back for `index`. It is checked against the slot
/// before it can be sent: it must be a kind:22242 signed by the account that is
/// signed in, naming this relay by the address it was dialed at and echoing the
/// challenge it is currently holding. A signer is a separate program, and what
/// it returns is data.
pub fn authDeliverSigned(gpa: std.mem.Allocator, signer: nostr.keys.Signer, index: usize, ev: nostr.event.Event) void {
    if (index >= max_relays) return;
    var url_buf: [96]u8 = undefined;
    const entry = relaySnapshot(index, &url_buf) orelse {
        authFailSigning(index);
        return;
    };
    const mine = activePubkey();
    var relay_tag: ?[]const u8 = null;
    var challenge_tag: ?[]const u8 = null;
    for (ev.tags) |tag| {
        if (tag.len < 2) continue;
        if (relay_tag == null and std.mem.eql(u8, tag[0], "relay")) relay_tag = tag[1];
        if (challenge_tag == null and std.mem.eql(u8, tag[0], "challenge")) challenge_tag = tag[1];
    }
    var sound = ev.kind == nostr.nip42.kind and ev.content.len == 0;
    sound = sound and mine != null and std.mem.eql(u8, &ev.pubkey, &mine.?);
    sound = sound and relay_tag != null and std.mem.eql(u8, relay_tag.?, entry.url) and challenge_tag != null;
    if (sound) sound = nostr.event.verify(gpa, signer, ev) catch false;
    const json: ?[]u8 = if (sound) (nostr.event.toJson(gpa, ev) catch null) else null;
    defer if (json) |j| gpa.free(j);

    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    // Superseded: the connection ended or the slot moved on while this was out.
    if (s.phase != .signing) return;
    // The reader signed out, or in as someone else, while this was out. It
    // answers for an account that is not here, so it is dropped, and the
    // challenge is decided again for whoever is: their own yes is signed by
    // them, and with no yes the notice asks. Failing it instead left the relay
    // refusing the new account for the life of the socket.
    const still_same = mine != null and std.mem.eql(u8, &mine.?, &s.signing_as);
    if (!still_same) {
        s.phase = authDecideLocked(mine, entry.url);
        return;
    }
    const j = json orelse {
        s.phase = .failed;
        return;
    };
    if (j.len > auth_event_cap) {
        s.phase = .failed;
        return;
    }
    // The relay sent a newer challenge while the signer worked. This signature
    // answers the old one, so it is thrown away and the new one is signed.
    if (!std.mem.eql(u8, challenge_tag.?, s.challenge[0..s.challenge_len])) {
        s.phase = .want_sign;
        return;
    }
    @memcpy(s.event[0..j.len], j);
    s.event_len = @intCast(j.len);
    s.phase = .signed;
}

/// Takes the signed reply, for the reader thread to send.
fn authTakeSigned(index: usize, out: *[auth_event_cap]u8) ?usize {
    if (index >= max_relays) return null;
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    if (s.phase != .signed) return null;
    const n: usize = s.event_len;
    @memcpy(out[0..n], s.event[0..n]);
    s.phase = .sent;
    return n;
}

/// The relay's OK for our reply.
fn authOutcome(index: usize, accepted: bool) void {
    if (index >= max_relays) return;
    authLock();
    defer authUnlock();
    const s = &g_auth_slots[index];
    if (s.phase == .sent) s.phase = if (accepted) .done else .failed;
}

/// Which subscriptions a relay refused for want of AUTH, so they can be asked
/// again once it has been given.
const OwedSubs = struct {
    feed: bool = false,
    inbox: bool = false,
    engagement: bool = false,

    fn mark(self: *OwedSubs, sub_id: []const u8) void {
        // The feed under any generation of its id: it is re-issued as
        // `plaza-feed-<n>` whenever its question changes, sign-in included.
        if (isFeedSub(sub_id)) {
            self.feed = true;
        } else if (std.mem.eql(u8, sub_id, "plaza-inbox")) {
            self.inbox = true;
        } else if (std.mem.eql(u8, sub_id, "plaza-engagement")) {
            self.engagement = true;
        }
    }

    pub fn any(self: OwedSubs) bool {
        return self.feed or self.inbox or self.engagement;
    }
};

/// One connection's side of the exchange. Lives on the reader thread's stack.
pub const AuthSession = struct {
    index: usize,
    owed: OwedSubs = .{},
    /// The id of the reply we sent and are waiting on an OK for.
    sent_id: ?[32]u8 = null,
    /// A challenge arrived on this connection.
    challenged: bool = false,
    /// The relay accepted our reply. After this an `auth-required:` is final:
    /// identifying again would not change the answer, and asking would loop.
    authed: bool = false,
    /// When the first auth-required CLOSED arrived, in the awake clock.
    gated_at_ms: i64 = 0,
    /// Whose connection it was when the reply went out. See `AuthPoll.redial`.
    sent_gen: u32 = 0,
};

pub const AuthReaction = struct {
    /// The message was about authentication and the caller is done with it.
    handled: bool = false,
    /// Subscriptions to ask again, because the relay has accepted us.
    resend: OwedSubs = .{},
};

fn isAuthRequired(reason: []const u8) bool {
    // NIP-01's machine-readable prefix, matched the way both reference clients
    // match it: by the start of the reason, nothing after the colon.
    return std.mem.startsWith(u8, reason, "auth-required");
}

/// What a relay's message means for authentication. Everything else comes back
/// unhandled and goes on to the loop's own switch.
pub fn authReact(sess: *AuthSession, url: []const u8, msg: nostr.message.RelayMessage, now_ms: i64) AuthReaction {
    switch (msg) {
        .auth => |a| {
            // A new challenge starts the exchange over. Nothing sent for an
            // earlier one counts for this one.
            sess.sent_id = null;
            sess.authed = false;
            sess.challenged = true;
            sess.gated_at_ms = 0;
            const phase = authSlotChallenge(sess.index, url, a.challenge);
            if (phase == .failed) std.debug.print("plaza: [{s}] sent a challenge that cannot be answered\n", .{url});
            return .{ .handled = true };
        },
        .closed => |c| {
            if (!isAuthRequired(c.message)) return .{};
            if (sess.authed) return .{};
            authGated(sess, url, now_ms);
            sess.owed.mark(c.subscription_id);
            return .{ .handled = true };
        },
        .ok => |o| {
            const sent = sess.sent_id orelse return authRefusedEvent(sess, url, o, now_ms);
            if (!std.mem.eql(u8, &o.event_id, &sent)) return authRefusedEvent(sess, url, o, now_ms);
            sess.sent_id = null;
            authOutcome(sess.index, o.accepted);
            if (!o.accepted) {
                std.debug.print("plaza: [{s}] refused our NIP-42 reply: {s}\n", .{ url, o.message });
                return .{ .handled = true };
            }
            sess.authed = true;
            const owed = sess.owed;
            sess.owed = .{};
            return .{ .handled = true, .resend = owed };
        },
        else => return .{},
    }
}

/// The relay has refused something for want of AUTH: this is what makes it a
/// question for the reader.
fn authGated(sess: *AuthSession, url: []const u8, now_ms: i64) void {
    authSlotGate(sess.index, url);
    if (sess.gated_at_ms == 0) sess.gated_at_ms = now_ms;
}

/// An OK that said no to an event with an `auth-required:` reason. The same
/// refusal as a CLOSED for a REQ. Nothing is owed back to the relay for it: the
/// reader thread sends no events of its own, so there is nothing to re-send, but
/// the relay has still said it wants to know who the reader is.
fn authRefusedEvent(sess: *AuthSession, url: []const u8, o: anytype, now_ms: i64) AuthReaction {
    if (o.accepted or !isAuthRequired(o.message) or sess.authed) return .{};
    authGated(sess, url, now_ms);
    return .{ .handled = true };
}

const AuthPoll = enum {
    quiet,
    /// Drop this connection and dial again. Either the relay refused a
    /// subscription for want of a challenge it never sent, or the reader is no
    /// longer the person this socket was identified as.
    redial,
};

/// The reader's half of the exchange that is not a reaction to a message: send
/// a signature that has arrived, and notice that the reader changed their mind
/// or signed in. Called once a wake, so a quiet relay is served as well.
pub fn authPoll(sess: *AuthSession, url: []const u8, relay: anytype, now_ms: i64, identity_gen: u32) AuthPoll {
    // A relay remembers who a socket was identified as for as long as the socket
    // lives. Signing out, or in as someone else, does not change that, so the
    // only way to stop being known to the relay as the previous account is to
    // leave the connection.
    if (sess.authed and identity_gen != sess.sent_gen) return .redial;
    authSlotReevaluate(sess.index, url, false);
    var buf: [auth_event_cap]u8 = undefined;
    if (authTakeSigned(sess.index, &buf)) |n| {
        const gpa = std.heap.page_allocator;
        if (nostr.event.fromJson(gpa, buf[0..n])) |parsed_const| {
            var parsed = parsed_const;
            defer parsed.deinit();
            // Checked again here, at the last moment before it leaves: the
            // reader can press "anonymous" while a bunker is still waiting for a
            // person, or switch account, and a reply signed as the previous one
            // would identify this socket as somebody who is no longer here.
            // Only a yes from the account the reply names lets it go.
            const me = activePubkey();
            const still_mine = me != null and std.mem.eql(u8, &me.?, &parsed.value.pubkey);
            if (!still_mine or authChoiceOf(parsed.value.pubkey, url) != .allow) {
                authSlotDiscardSigned(sess.index, url);
                return .quiet;
            }
            if (relay.authenticate(parsed.value)) |_| {
                sess.sent_id = parsed.value.id;
                sess.sent_gen = identity_gen;
            } else |_| {
                authOutcome(sess.index, false);
            }
        } else |_| {
            authOutcome(sess.index, false);
        }
    }
    if (sess.gated_at_ms != 0 and !sess.challenged and now_ms - sess.gated_at_ms > auth_gate_wait_ms) return .redial;
    return .quiet;
}

// The UI half. Everything below runs on the UI thread, which is the only one
// that may reach a signer.

/// One signature at a time through Notary's door, as with a note. A bunker has
/// a table of its own.
pub var g_helper_auth_active = false;
pub var g_helper_auth_index: usize = 0;
pub const helper_auth_key: u64 = 45;

fn authSignerReady() bool {
    return switch (keyholder.g_signer_kind) {
        .helper => !g_helper_auth_active and (keyholder.g_helper_port != 0 or builtin.is_test),
        .remote => true,
    };
}

/// Builds the unsigned kind:22242 for `url` and `challenge` and asks the active
/// signer for a signature. False when nothing could be asked.
fn requestAuthSign(fx: *Effects, index: usize, url: []const u8, challenge: []const u8) bool {
    const pk = activePubkey() orelse return false;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const created = nowSeconds();
    const relay_tag = a.dupe([]const u8, &.{ "relay", url }) catch return false;
    const challenge_tag = a.dupe([]const u8, &.{ "challenge", challenge }) catch return false;
    const tags = a.dupe(nostr.event.Tag, &.{ relay_tag, challenge_tag }) catch return false;
    const id = nostr.event.computeId(a, pk, created, nostr.nip42.kind, tags, "") catch return false;
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = pk,
        .created_at = created,
        .kind = nostr.nip42.kind,
        .tags = tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(a, unsigned) catch return false;
    switch (keyholder.g_signer_kind) {
        .helper => {
            const body = (nostr.signer_ipc.SignEvent{ .event = unsigned_json }).toJson(a) catch return false;
            g_helper_auth_active = true;
            g_helper_auth_index = index;
            // A test cannot drive the loopback, so a stand-in keyholder answers
            // the way the real one does and the response handler runs for real.
            if (builtin.is_test) {
                if (!keyholder.g_test_signer_silent) answerHelperAuthForTest(a, unsigned_json);
                return true;
            }
            helperFetch(fx, helper_auth_key, "/sign", body, Effects.responseMsg(.helper_auth_signed));
            return true;
        },
        .remote => {
            var idbuf: [24]u8 = undefined;
            const req_id = newRequestId(&idbuf) orelse return false;
            // Tracked before it is sent: the answer can land on the listener
            // thread the instant the send does.
            if (!registerPending(req_id, .sign_auth, null, false, .none, @intCast(index), no_half_id, .{})) return false;
            const params = [_][]const u8{unsigned_json};
            sendRequest(std.heap.page_allocator, .{ .id = req_id, .method = "sign_event", .params = &params });
            return true;
        },
    }
}
pub fn handleHelperAuthSigned(response: native_sdk.EffectResponse) void {
    const index = g_helper_auth_index;
    g_helper_auth_active = false;
    if (response.outcome != .ok or response.status != 200) {
        authFailSigning(index);
        return;
    }
    const gpa = std.heap.page_allocator;
    var wrapped = nostr.signer_ipc.parse(nostr.signer_ipc.SignEvent, gpa, response.body) catch {
        authFailSigning(index);
        return;
    };
    defer wrapped.deinit();
    var parsed = nostr.event.fromJson(gpa, wrapped.value.event) catch {
        authFailSigning(index);
        return;
    };
    defer parsed.deinit();
    var verifier = nostr.keys.Signer.init();
    defer verifier.deinit();
    authDeliverSigned(gpa, verifier, index, parsed.value);
}

/// The tick's share: retire stale signatures, and get the allowed challenges
/// signed.
pub fn driveRelayAuth(fx: *Effects) void {
    authSweep(nowSeconds());
    for (0..max_relays) |i| {
        if (authSlotPhase(i) != .want_sign) continue;
        if (!authSignerReady()) return;
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(i, &url_buf) orelse {
            authSlotReset(i);
            continue;
        };
        var challenge: [auth_challenge_cap]u8 = undefined;
        const n = authBeginSigning(i, entry.url, &challenge) orelse continue;
        if (!requestAuthSign(fx, i, entry.url, challenge[0..n])) {
            if (keyholder.g_signer_kind == .helper) g_helper_auth_active = false;
            authFailSigning(i);
        }
    }
}

/// The reader's answer to the notice.
pub fn authAnswer(index: usize, allow: bool) void {
    const me = activePubkey() orelse return;
    var url_buf: [96]u8 = undefined;
    const entry = relaySnapshot(index, &url_buf) orelse return;
    _ = setAuthChoice(me, entry.url, if (allow) .allow else .deny);
    saveAuthChoices();
    authSlotReevaluate(index, entry.url, true);
}

/// The relay row's badge: ask first, then identify, then anonymous.
pub fn authCycle(index: usize) void {
    const me = activePubkey() orelse return;
    var url_buf: [96]u8 = undefined;
    const entry = relaySnapshot(index, &url_buf) orelse return;
    const next: AuthChoice = switch (authChoiceOf(me, entry.url)) {
        .ask => .allow,
        .allow => .deny,
        .deny => .ask,
    };
    _ = setAuthChoice(me, entry.url, next);
    saveAuthChoices();
    authSlotReevaluate(index, entry.url, true);
}

/// What the badge on a relay row says, or null when there is nothing to say
/// yet: no choice made and no refusal for want of AUTH. Null for a guest too, who has no
/// identity to give and so nothing for the badge to change.
pub fn authBadgeText(index: usize, url: []const u8) ?[]const u8 {
    if (activePubkey() == null) return null;
    const choice = authChoiceFor(url);
    if (choice == .ask and authSlotPhase(index) == .idle) return null;
    return switch (choice) {
        .ask => "ask first",
        .allow => "identify",
        .deny => "anonymous",
    };
}

/// Why a relay is not giving this reader what they asked for, in the row, when
/// the reason is authentication. Null for a relay that has not refused.
pub fn authRowNote(index: usize) ?[]const u8 {
    if (!authSlotGated(index)) return null;
    return switch (authSlotPhase(index)) {
        .asking => "Wants to know who you are. Waiting for your answer.",
        .want_sign, .signing, .signed, .sent => "Identifying you to it.",
        .declined => "Wants to know who you are. You chose not to tell it.",
        .no_key => "Wants to know who you are. Sign in to answer it.",
        .failed => "Wants to know who you are, and would not accept the answer.",
        .idle, .done => null,
    };
}

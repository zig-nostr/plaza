//! The encrypted halves of mute and bookmark lists.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");
const remote_signer = @import("remote_signer.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
const answerPrivateHalfForTest = main.answerPrivateHalfForTest;
const helperFetch = main.helperFetch;
const invalidateFeed = main.invalidateFeed;
const isNip04Payload = main.isNip04Payload;
const loadBookmarksFromStore = main.loadBookmarksFromStore;
const loadMutesFromStore = main.loadMutesFromStore;
const nowSeconds = main.nowSeconds;
const pendingLock = main.pendingLock;
const pendingUnlock = main.pendingUnlock;
const registerPending = main.registerPending;
const requestRemoteDecrypt = main.requestRemoteDecrypt;
const signerIsHealthy = main.signerIsHealthy;

/// The decrypted private half of a NIP-51 list, once Notary has opened it.
///
/// NIP-51 puts the private half of a list in `content`, encrypted to yourself.
/// Plaza used to open it inline, against a secret key in this process. There is
/// no secret key in this process any more, and asking the keyholder is a round
/// trip, while every caller here answers a question that has to be answered NOW:
/// is this account muted, and may this list be written back.
///
/// So the round trip happens once and the answer is kept. A caller reads this
/// cache and gets a synchronous answer or nothing; nothing queues the ask and
/// stays "cannot read", which is the same fail-safe as before and the one that
/// matters: content that is present and unreadable means the list is NOT
/// written back. Publishing a list whose private half you could not read
/// deletes every private entry in it, which is a real bug in a real client and
/// is why the guard exists.
const PrivateHalf = struct {
    used: bool = false,
    state: enum { idle, asking, open, refused, unreadable } = .idle,
    /// The ciphertext this entry is about, by hash: the ciphertext itself runs
    /// to kilobytes and this only has to tell two of them apart.
    id: [32]u8 = [_]u8{0} ** 32,
    /// `refused` only: when a refusal that was really a silence may be asked
    /// again without a press, in seconds. Zero means only a press (or a new
    /// connection) re-asks, which is what an explicit "no" gets.
    retry_at_s: i64 = 0,
    /// The ask in flight over Notary's door, if that is who was asked. The
    /// answer comes back with nothing but a key, so the key carries this.
    ask_seq: u32 = 0,
    plain_buf: [4096]u8 = undefined,
    plain_len: u16 = 0,

    fn plain(self: *const PrivateHalf) []const u8 {
        return self.plain_buf[0..self.plain_len];
    }
};

/// One per list a reader can have a private half in: mutes, bookmarks, and room
/// for two more before anything has to be evicted.
pub var g_private_halves: [4]PrivateHalf = [_]PrivateHalf{.{}} ** 4;

/// The ciphertext each slot is about, held because the ask happens on a later
/// tick than the read that noticed it was needed.
const PrivateCiphertext = struct {
    buf: [4096]u8 = undefined,
    len: u16 = 0,
    fn slice(self: *const PrivateCiphertext) []const u8 {
        return self.buf[0..self.len];
    }
};
pub var g_private_ciphertext: [4]PrivateCiphertext = [_]PrivateCiphertext{.{}} ** 4;

/// Effect keys for the decrypts, one per slot.
const private_half_key_base: u64 = 48;

/// How long a silence from the bunker is left alone before the half is asked
/// again, after the ask itself has already waited out `remote_sign_timeout_s`.
pub const private_half_retry_s: i64 = 60;

/// Each ask over Notary's door gets the next number, and the key carries it
/// above the slot, so an answer can be told from one for an earlier ask of the
/// same slot. The slot alone cannot say: a sign-out frees it while the answer
/// is on the wire, and the next account can have taken it by then. Never
/// reused, never reset by a sign-out, for the same reason.
var g_half_ask_seq: u32 = 0;

pub fn privateHalfKey(i: usize, seq: u32) u64 {
    return (@as(u64, seq) << 16) | (private_half_key_base + @as(u64, @intCast(i)));
}

/// Marks slot `i` as asked over Notary's door and returns the key to ask under.
pub fn beginHelperAsk(i: usize) u64 {
    g_half_ask_seq +%= 1;
    if (g_half_ask_seq == 0) g_half_ask_seq = 1;
    const h = &g_private_halves[i];
    h.state = .asking;
    h.ask_seq = g_half_ask_seq;
    return privateHalfKey(i, g_half_ask_seq);
}

/// The half an answer is for, if it is still waiting for one: the slot is in
/// use, holds the same ciphertext that was asked, and is in the asking state.
/// Anything else is an answer to a question nobody is asking any more (the
/// reader signed out, the slot was given to another list, or the ask was
/// already retired), and applying it would hand one account's plaintext, or its
/// refusal, to another's list.
pub fn halfAwaiting(index: usize, id: [32]u8) ?*PrivateHalf {
    if (index >= g_private_halves.len) return null;
    const h = &g_private_halves[index];
    if (!h.used or h.state != .asking) return null;
    if (!std.mem.eql(u8, &h.id, &id)) return null;
    return h;
}

/// Puts refused halves back to idle so the next tick asks again: those whose
/// retry stamp has passed, or all of them with `all`, which is what a new
/// connection to the signer means. Never touches `unreadable`, which no second
/// ask can change.
pub fn rearmPrivateHalves(now: i64, all: bool) void {
    for (&g_private_halves) |*h| {
        if (!h.used or h.state != .refused) continue;
        if (!all and (h.retry_at_s == 0 or now < h.retry_at_s)) continue;
        h.state = .idle;
        h.retry_at_s = 0;
    }
}
/// And one for the encrypt, of which there is only ever one in flight: it is
/// driven by a press, and `signerReady` already refuses a second press while a
/// signature is out.
pub const private_seal_key: u64 = 64;

/// A private bookmark write, waiting for its ciphertext.
///
/// Writing into an encrypted half cannot be done in one pass. The plaintext has
/// to be sealed by whoever holds the key, which is Notary over HTTP or a bunker
/// over a relay, and neither answers in the same call. So the press builds the
/// new private tag array, asks for it to be sealed, and parks here; the answer
/// completes the splice.
///
/// The splice re-reads the record when the ciphertext lands rather than holding
/// the one it read at press time. A round trip to a bunker goes through a human
/// pressing approve, so the list can genuinely have moved in between, and
/// writing a splice built against a record that is no longer current is exactly
/// the class of bug the read-before-write rule exists to stop.
const PrivateSeal = struct {
    active: bool = false,
    event_id: [32]u8 = [_]u8{0} ** 32,
    adding: bool = false,
    /// Set while a bunker is sealing it, so a refusal can be told from silence.
    awaiting_remote: bool = false,
    /// The id of the list the new private half was built from, or null when
    /// there was none. The finish publishes only over that same record.
    base: ?[32]u8 = null,
};
pub var g_private_seal: PrivateSeal = .{};

/// Whether `now` is the record whose id was `then` (both absent counts).
pub fn sameRecord(now: ?OwnProfile, then: ?[32]u8) bool {
    if (now) |rec| {
        const id = then orelse return false;
        return std.mem.eql(u8, &rec.id, &id);
    }
    return then == null;
}

pub fn privateHalfId(content: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &out, .{});
    return out;
}

fn privateHalfFor(content: []const u8) ?*PrivateHalf {
    const id = privateHalfId(content);
    for (&g_private_halves) |*h| {
        if (h.used and std.mem.eql(u8, &h.id, &id)) return h;
    }
    return null;
}

/// The plaintext, or null with the ask queued.
pub fn privateHalfOpened(content: []const u8) ?[]const u8 {
    if (content.len == 0) return null;
    if (privateHalfFor(content)) |h| {
        return if (h.state == .open) h.plain() else null;
    }
    // Never seen. Claim a slot so the tick asks Notary for it. The oldest
    // unopened one goes first; an opened one is worth more than a pending ask.
    const id = privateHalfId(content);
    for (&g_private_halves, 0..) |*h, i| {
        if (!h.used) return claimPrivateHalf(i, id, content);
    }
    for (&g_private_halves, 0..) |*h, i| {
        if (h.state != .open) return claimPrivateHalf(i, id, content);
    }
    return null;
}

/// Takes slot `i` for this ciphertext and keeps a copy of it, because the ask
/// goes out on a later tick than the read that noticed it was needed.
fn claimPrivateHalf(i: usize, id: [32]u8, content: []const u8) ?[]const u8 {
    if (content.len > g_private_ciphertext[i].buf.len) return null;
    // Notary's own door opens NIP-44 and nothing else, so a NIP-04 half is not
    // something it can be asked for. No slot: the half reads as unreadable, which
    // is the truth, rather than as a refusal that a press would keep re-asking.
    if (keyholder.g_signer_kind == .helper and isNip04Payload(content)) return null;
    g_private_halves[i] = .{ .used = true, .state = .idle, .id = id };
    @memcpy(g_private_ciphertext[i].buf[0..content.len], content);
    g_private_ciphertext[i].len = @intCast(content.len);
    // A test has no tick to fire the ask on, so its stand-in keyholder answers
    // here. In the app this returns null and the answer arrives a tick later,
    // which is the whole reason this is a cache and not a call. A bunker never
    // answers inline, in a test or out of one: its answer is parked by the
    // listener and applied by the sweep.
    if (builtin.is_test and keyholder.g_signer_kind == .helper) {
        answerPrivateHalfForTest(std.heap.page_allocator, i, content);
        if (g_private_halves[i].state == .open) return g_private_halves[i].plain();
    }
    return null;
}
pub fn parkHalfAnswer(index: u8, id: [32]u8, plain: []const u8) void {
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_half_inbox) |*box| {
        if (box.used) continue;
        const n = @min(plain.len, box.plain_buf.len);
        box.* = .{ .used = true, .index = index, .half_id = id, .ok = true, .plain_len = @intCast(n) };
        @memcpy(box.plain_buf[0..n], plain[0..n]);
        return;
    }
}

pub const HalfAskEnd = enum {
    /// The bunker answered with an error.
    failed,
    /// The deadline passed with no answer.
    timed_out,
};
pub fn endHalfAsk(index: u8, id: [32]u8, end: HalfAskEnd) bool {
    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "half{d}", .{index}) catch return false;
    if (!registerPending(req_id, .nip44_decrypt, null, false, .none, index, id, .{})) return false;
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_pending) |*slot| {
        if (!slot.active or !std.mem.eql(u8, slot.id(), req_id)) continue;
        switch (end) {
            .failed => slot.failed = true,
            .timed_out => slot.deadline_s = -1,
        }
    }
    return true;
}
/// Asks Notary to open one private half, if any is waiting and the keyholder
/// can answer. One at a time: these are rare, and a batch would need the
/// ciphertexts held somewhere while the answer travels.
pub fn scanPrivateHalves(fx: *Effects) void {
    if (!signerIsHealthy()) return;
    const me = activePubkey() orelse return;
    // A silence from the bunker is not an answer: once its wait is over the
    // half is asked again, by the same state machine that asked it the first
    // time, so it is never asked twice at once.
    rearmPrivateHalves(nowSeconds(), false);
    for (&g_private_halves, 0..) |*h, i| {
        if (!h.used or h.state != .idle) continue;
        const content = g_private_ciphertext[i].slice();
        if (content.len == 0) {
            h.state = .unreadable;
            continue;
        }
        const gpa = std.heap.page_allocator;
        // A bunker answers over NIP-46, not over the keyholder's HTTP door.
        // This used to fall through to `helperFetch` regardless, so a reader on
        // an external signer asked a daemon that does not hold their key.
        if (keyholder.g_signer_kind == .remote) {
            h.state = .asking;
            if (!requestRemoteDecrypt(gpa, i, content)) {
                // Nothing was sent (no room to track it, no id): a delay and
                // not an answer, so it is asked again shortly.
                h.state = .refused;
                h.retry_at_s = nowSeconds() + private_half_retry_s;
            }
            return;
        }
        var peer_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&peer_hex, "{x}", .{me}) catch return;
        // To yourself: both sides of the conversation key are this account's,
        // which is what NIP-51 means by a half encrypted to yourself.
        const body = (nostr.signer_ipc.Cipher{ .peer = &peer_hex, .items = &.{content} }).toJson(gpa) catch return;
        defer gpa.free(body);
        if (builtin.is_test) {
            answerPrivateHalfForTest(gpa, i, content);
            return;
        }
        helperFetch(fx, beginHelperAsk(i), "/nip44/decrypt", body, Effects.responseMsg(.private_half));
        return;
    }
}

/// Notary's answer: the plaintext, or a refusal this reader has to live with.
///
/// Two kinds of "no". A 403, a 409, a dead daemon: the keyholder did not open
/// it, and might if asked again, so the half is `refused` and a press asks
/// again. A 422, or a 200 that does not parse: the keyholder looked at this
/// ciphertext and cannot read it, and asking again gets the same answer, so the
/// half is `unreadable` and nothing re-asks it.
pub fn handlePrivateHalf(response: native_sdk.EffectResponse) void {
    const low = response.key & 0xffff;
    if (low < private_half_key_base) return;
    const i = low - private_half_key_base;
    if (i >= g_private_halves.len) return;
    const seq: u32 = @truncate(response.key >> 16);
    const h = &g_private_halves[@intCast(i)];
    // Only the ask this slot is waiting on. A sign-out frees the slot while an
    // answer is still on its way, and the next account can be asking from the
    // same slot by the time it lands: the answer is then for a ciphertext that
    // is no longer here and must not be applied to the one that is.
    if (!h.used or h.state != .asking or seq == 0 or h.ask_seq != seq) return;
    if (response.outcome == .ok and response.status == 422) {
        h.state = .unreadable;
        return;
    }
    if (response.outcome != .ok or response.status != 200) {
        // Refused, or the keyholder is not there. NOT "the half is empty": the
        // whole point of this cache is that unreadable and empty are different
        // answers, and treating them alike is what deletes somebody's list.
        h.state = .refused;
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.CipherResult, gpa, response.body) catch {
        h.state = .unreadable;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.items.len == 0) {
        h.state = .refused;
        return;
    }
    const plain = parsed.value.items[0];
    const n = @min(plain.len, h.plain_buf.len);
    @memcpy(h.plain_buf[0..n], plain[0..n]);
    h.plain_len = @intCast(n);
    h.state = .open;
    // The mute set was read with this half closed, so it is short by whatever
    // was in it. Read it again now that it can be.
    loadMutesFromStore();
    loadBookmarksFromStore();
    invalidateFeed();
}
/// What was concluded about the leaving account's encrypted lists, and what they
/// said. Keyed by the ciphertext, so a stranger's list would never be read as
/// the previous reader's, but the plaintext of their private mutes has no
/// business sitting in memory after they sign out, and an ask that was still in
/// flight must not be left to be mistaken for an answer.
pub fn forgetPrivateHalves() void {
    for (&g_private_halves) |*h| {
        std.crypto.secureZero(u8, &h.plain_buf);
        h.* = .{};
    }
    for (&g_private_ciphertext) |*c| c.len = 0;
    // A bunker's answer the listener parked and the tick has not applied yet
    // holds the plaintext too, and would otherwise be applied by the next
    // sweep to whatever list holds that slot by then.
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_half_inbox) |*box| {
        std.crypto.secureZero(u8, &box.plain_buf);
        box.* = .{};
    }
}

/// Whether an encrypted content opens at all.
///
/// `privateMutes` returns zero for two completely different situations: a half
/// that decrypted fine and simply names nobody, and a half that could not be
/// decrypted. Carrying the first one forward is ordinary; carrying the second is
/// the only thing this write must never do. This is what tells them apart, and
/// the name says "readable" rather than "empty" on purpose: a reader glancing at
/// `!privateHalfIsEmpty(...)` at the call site would take it to mean the
/// opposite of what the guard is for.
pub fn privateHalfIsReadable(gpa: std.mem.Allocator, content: []const u8) bool {
    const plain = privateHalfOpened(content) orelse return false;
    const parsed = std.json.parseFromSlice([]const []const []const u8, gpa, plain, .{}) catch return false;
    defer parsed.deinit();
    // It decrypted and parsed. Whatever is in it, this app understood the half it
    // is about to carry forward, which is the whole question.
    return true;
}

/// Why a write may not go ahead over a private half, in the three ways it can
/// fail. They all refuse, and none of them publishes; what differs is what the
/// reader is told and whether a press asks again.
const HalfGate = enum {
    /// Opened and understood. Carry it forward.
    readable,
    /// The signer has been asked, or is about to be, and has not answered. A
    /// bunker answers on a human timescale, so this is the common first press.
    waiting,
    /// The signer refused, or never answered. Not "empty": a refusal that read
    /// as an empty half is the one way to publish a list with every private
    /// entry stripped out of it.
    declined,
    /// There is no way to open it from here: too large to hold, a NIP-04 half
    /// behind Notary's NIP-44 door, or a plaintext that is not a tag list.
    unreadable,
};

/// The gate every write over a NIP-51 list goes through before it carries a
/// private half forward.
///
/// A press on a declined half asks again. Amethyst's decrypt cache keeps a
/// refusal or a timeout as "can try again" rather than as an answer, and without
/// that a reader who dismissed one prompt on their bunker would have a
/// read-only list until they restarted. A signer that stayed silent is also
/// asked again once a while has passed (`rearmPrivateHalves`), and every new
/// connection to the signer starts over. Each path moves the half back to idle
/// and the one ask goes out from there, so at most one prompt is ever out: a
/// second press while the first is open lands on `.waiting`. What the signer
/// said it cannot read at all is `.unreadable` and is never asked again.
pub fn privateHalfGate(gpa: std.mem.Allocator, content: []const u8) HalfGate {
    if (privateHalfIsReadable(gpa, content)) return .readable;
    const h = privateHalfFor(content) orelse return .unreadable;
    switch (h.state) {
        .idle, .asking => return .waiting,
        .refused => {
            h.state = .idle;
            h.retry_at_s = 0;
            return .declined;
        },
        .open, .unreadable => return .unreadable,
    }
}

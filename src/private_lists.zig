//! The encrypted halves of mute and bookmark lists.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");
const remote_signer = @import("remote_signer.zig");
const feed_state = @import("feed_state.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const max_private_cipher_len = main.max_private_cipher_len;
const max_private_plain_len = main.max_private_plain_len;
const handlePrivateSeal = main.handlePrivateSeal;
const Model = main.Model;
const no_half_id = main.no_half_id;
const Effects = main.Effects;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
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
    /// When it was last read or filled, on `g_half_clock`, so the open slot
    /// given up for a new half is the one used longest ago.
    touched: u64 = 0,
    /// As long as NIP-44 can seal, so any list a signer can write can be read
    /// back. It was 4096 bytes, which a few dozen entries outgrow, and an
    /// unreadable half refuses every write to its list.
    plain_buf: [max_private_plain_len]u8 = undefined,
    plain_len: u16 = 0,

    fn plain(self: *const PrivateHalf) []const u8 {
        return self.plain_buf[0..self.plain_len];
    }
};

/// One per list a reader can have a private half in: mutes, bookmarks, and room
/// for two more before anything has to be given up.
///
/// Every private bookmark write mints a new ciphertext, and each one read back
/// used to take a slot for good: an open slot was never given up. After about
/// three writes in a session every slot held the half of a list long since
/// replaced, the current one found none, and every write to that list read as
/// unreadable until a restart. So a new half takes the open slot used longest
/// ago, never one a list holds now (`g_current_half`) and never one an ask is
/// out for, and a seal fills the slot for the half it publishes itself.
var g_private_halves: [4]PrivateHalf = [_]PrivateHalf{.{}} ** 4;

/// The lists a reader can have a private half in.
pub const HalfList = enum { mutes, bookmarks };

/// The half each list was last read with, by hash, or null for a list read with
/// no private half. Set by the read itself, so no caller can forget to: every
/// read of a half names the list it is reading for.
var g_current_half: [std.meta.fields(HalfList).len]?[32]u8 = [_]?[32]u8{null} ** std.meta.fields(HalfList).len;

/// The half the private bookmark write in flight was built on. Its finish reads
/// that half again, so the slot stays until the seal is over.
var g_seal_base_half: ?[32]u8 = null;

var g_half_clock: u64 = 0;

/// Guards everything above, and `g_private_ciphertext`. A relay's reader
/// thread reads halves through an arriving list (`ingestMuteList`, and
/// `ingestBookmarkList` by way of the store), while the UI thread asks, answers
/// and writes, so every touch of a slot happens under it. It tracks no owner:
/// nothing called while it is held takes it again or takes `pendingLock`, which
/// is always taken first where both are held. A read hands back a copy rather
/// than a slice into a slot, because the slot can be given up the moment the
/// lock is let go.
var g_half_lock = std.atomic.Value(bool).init(false);

fn lockHalves() void {
    while (g_half_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockHalves() void {
    g_half_lock.store(false, .release);
}

/// The ciphertext each slot is about, held because the ask happens on a later
/// tick than the read that noticed it was needed.
const PrivateCiphertext = struct {
    buf: [max_private_cipher_len]u8 = undefined,
    len: u32 = 0,
    fn slice(self: *const PrivateCiphertext) []const u8 {
        return self.buf[0..self.len];
    }
};
var g_private_ciphertext: [4]PrivateCiphertext = [_]PrivateCiphertext{.{}} ** 4;

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
    lockHalves();
    defer unlockHalves();
    return beginHelperAskUnlocked(i);
}

fn beginHelperAskUnlocked(i: usize) u64 {
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
fn halfAwaitingUnlocked(index: usize, id: [32]u8) ?*PrivateHalf {
    if (index >= g_private_halves.len) return null;
    const h = &g_private_halves[index];
    if (!h.used or h.state != .asking) return null;
    if (!std.mem.eql(u8, &h.id, &id)) return null;
    return h;
}

/// An ask that died with its session: back to idle, so the next tick asks
/// again. Only if the slot is still waiting on that very ask.
pub fn rearmHalfAsk(index: usize, id: [32]u8) void {
    lockHalves();
    defer unlockHalves();
    if (halfAwaitingUnlocked(index, id)) |h| h.state = .idle;
}

/// A decrypt the bunker refused (`retry_at_s` zero) or never answered.
pub fn refuseHalfAsk(index: usize, id: [32]u8, retry_at_s: i64) void {
    lockHalves();
    defer unlockHalves();
    if (halfAwaitingUnlocked(index, id)) |h| {
        h.state = .refused;
        h.retry_at_s = retry_at_s;
    }
}

/// A bunker's answer to a decrypt, applied to the half that asked. Returns
/// whether it opened one. Called with `pendingLock` held, which is the order
/// the two are always taken in.
pub fn applyHalfAnswer(index: usize, id: [32]u8, ok: bool, too_large: bool, plain: []const u8) bool {
    lockHalves();
    defer unlockHalves();
    const h = halfAwaitingUnlocked(index, id) orelse return false;
    if (ok and plain.len > 0 and plain.len <= h.plain_buf.len) {
        @memcpy(h.plain_buf[0..plain.len], plain);
        h.plain_len = @intCast(plain.len);
        h.state = .open;
        return true;
    }
    // Asking again gets the same answer.
    h.state = if (too_large or plain.len > h.plain_buf.len) .unreadable else .refused;
    return false;
}

/// Puts refused halves back to idle so the next tick asks again: those whose
/// retry stamp has passed, or all of them with `all`, which is what a new
/// connection to the signer means. Never touches `unreadable`, which no second
/// ask can change.
pub fn rearmPrivateHalves(now: i64, all: bool) void {
    lockHalves();
    defer unlockHalves();
    rearmPrivateHalvesUnlocked(now, all);
}

fn rearmPrivateHalvesUnlocked(now: i64, all: bool) void {
    for (&g_private_halves) |*h| {
        if (!h.used or h.state != .refused) continue;
        if (!all and (h.retry_at_s == 0 or now < h.retry_at_s)) continue;
        h.state = .idle;
        h.retry_at_s = 0;
    }
}
/// And one for the encrypt, of which there is only ever one in flight: it is
/// driven by a press, and `g_private_seal.active` refuses a second press while
/// one is out. The key carries the ask's number above it, the same way a
/// decrypt's does, so a late answer to a seal that a sign-out abandoned cannot
/// complete the next one.
pub const private_seal_key: u64 = 64;

pub var g_seal_ask_seq: u32 = 0;

pub fn privateSealKey(seq: u32) u64 {
    return (@as(u64, seq) << 16) | private_seal_key;
}

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
    /// The account that pressed. A seal is a list encrypted to one key, and
    /// finishing it under another account would publish that account a list
    /// it cannot read.
    account: [32]u8 = [_]u8{0} ** 32,
    /// Which ask over Notary's door this is, carried in the effect key.
    ask_seq: u32 = 0,
    /// How long the plaintext was. NIP-44 pads to an exact length, so this says
    /// exactly how long the ciphertext that comes back must be.
    plain_len: usize = 0,
};
pub var g_private_seal: PrivateSeal = .{};

/// Abandons a seal in flight, and any answer the listener parked for it. On
/// every path that ends the session it was asked in: a sign-out, a dropped
/// bunker, and a bunker ask that died with its generation. Left set, it refused
/// every private bookmark for the rest of the run, and an answer still on its
/// way could complete it under whoever signed in next.
pub fn forgetPrivateSeal() void {
    clearPrivateSeal();
    pendingLock();
    defer pendingUnlock();
    remote_signer.g_seal_inbox = .{};
}

/// What the private bookmark write in flight asked to have sealed, so the half
/// it publishes is open from the moment it is published. Without it the reader
/// asked the signer to open the list it had just written, which on a bunker is
/// one more prompt, and every write took one more slot. UI thread only: the
/// press, the finish and every path that ends a seal run there.
var g_seal_plain: [max_private_plain_len]u8 = undefined;
var g_seal_plain_len: usize = 0;
/// The seal it belongs to, so a plaintext from an ask that was abandoned can
/// never be taken for the next one's.
var g_seal_plain_seq: u32 = 0;

/// Keeps the plaintext a seal was asked for, and the half it was built on.
pub fn holdSealPlaintext(seq: u32, base_content: []const u8, plain: []const u8) void {
    dropSealPlaintext();
    if (plain.len > g_seal_plain.len) return;
    @memcpy(g_seal_plain[0..plain.len], plain);
    g_seal_plain_len = plain.len;
    g_seal_plain_seq = seq;
    lockHalves();
    defer unlockHalves();
    g_seal_base_half = if (base_content.len > 0) privateHalfId(base_content) else null;
}

/// Wipes the held plaintext and lets the base half go.
pub fn dropSealPlaintext() void {
    std.crypto.secureZero(u8, g_seal_plain[0..g_seal_plain_len]);
    g_seal_plain_len = 0;
    g_seal_plain_seq = 0;
    lockHalves();
    defer unlockHalves();
    g_seal_base_half = null;
}

/// Ends the seal in flight, on every path that gives up on it.
pub fn clearPrivateSeal() void {
    g_private_seal = .{};
    dropSealPlaintext();
}

/// The seal numbered `seq` came back as `ciphertext` and is being published as
/// `list`'s private half: that half is opened with the plaintext it was sealed
/// from, and is the list's half now. Nothing is asked of the signer.
pub fn seedSealedHalf(list: HalfList, seq: u32, ciphertext: []const u8) void {
    defer dropSealPlaintext();
    if (seq == 0 or seq != g_seal_plain_seq or g_seal_plain_len == 0) return;
    if (ciphertext.len == 0 or ciphertext.len > g_private_ciphertext[0].buf.len) return;
    const id = privateHalfId(ciphertext);
    lockHalves();
    defer unlockHalves();
    // The list's half moves first, so the one it replaces is free to go.
    g_current_half[@intFromEnum(list)] = id;
    g_seal_base_half = null;
    const i = slotOfUnlocked(id) orelse slotToGiveUpUnlocked() orelse return;
    // An ask out for this very ciphertext keeps its slot, and its answer is the
    // same plaintext.
    if (g_private_halves[i].used and g_private_halves[i].state == .asking) return;
    fillOpenUnlocked(i, id, g_seal_plain[0..g_seal_plain_len]);
    @memcpy(g_private_ciphertext[i].buf[0..ciphertext.len], ciphertext);
    g_private_ciphertext[i].len = @intCast(ciphertext.len);
}

pub fn privateSealActiveForTest() bool {
    return g_private_seal.active;
}

pub fn forgetPrivateSealForTest() void {
    forgetPrivateSeal();
}

/// The effect key the seal in flight was asked under.
pub fn privateSealKeyForTest() u64 {
    return privateSealKey(g_private_seal.ask_seq);
}

/// Notary's answer to a seal, delivered under `key` the way the runtime would.
pub fn deliverPrivateSealForTest(model: *Model, fx: *Effects, key: u64, ciphertext: []const u8) void {
    const gpa = std.heap.page_allocator;
    const body = (nostr.signer_ipc.CipherResult{ .items = &.{ciphertext} }).toJson(gpa) catch return;
    defer gpa.free(body);
    handlePrivateSeal(model, fx, .{ .key = key, .outcome = .ok, .status = 200, .body = body });
}

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

fn touchUnlocked(h: *PrivateHalf) void {
    g_half_clock += 1;
    h.touched = g_half_clock;
}

fn slotOfUnlocked(id: [32]u8) ?usize {
    for (&g_private_halves, 0..) |*h, i| {
        if (h.used and std.mem.eql(u8, &h.id, &id)) return i;
    }
    return null;
}

/// Whether a slot has to stay: a list holds its half now, an ask is out for it
/// and its answer would land on whatever took the slot, or the seal in flight
/// was built on it.
fn pinnedUnlocked(h: *const PrivateHalf) bool {
    if (h.state == .asking) return true;
    for (g_current_half) |current| {
        if (current) |id| {
            if (std.mem.eql(u8, &h.id, &id)) return true;
        }
    }
    if (g_seal_base_half) |id| {
        if (std.mem.eql(u8, &h.id, &id)) return true;
    }
    return false;
}

/// The slot a half not held yet may take: a free one, else one no list holds
/// and nothing waits on. A verdict that is not open goes before an opened half,
/// which is worth more than a pending ask, and among those the one used longest
/// ago goes first. Null when every slot has to stay.
fn slotToGiveUpUnlocked() ?usize {
    for (&g_private_halves, 0..) |*h, i| {
        if (!h.used) return i;
    }
    var best: ?usize = null;
    for (&g_private_halves, 0..) |*h, i| {
        if (pinnedUnlocked(h)) continue;
        if (best) |b| {
            const other = &g_private_halves[b];
            const h_open = h.state == .open;
            const other_open = other.state == .open;
            if (h_open != other_open) {
                if (!h_open) best = i;
                continue;
            }
            if (h.touched < other.touched) best = i;
        } else best = i;
    }
    return best;
}

/// Empties slot `i` for another half. What it held is the reader's private
/// list, so it is wiped, not just forgotten.
fn releaseSlotUnlocked(i: usize) void {
    std.crypto.secureZero(u8, &g_private_halves[i].plain_buf);
    g_private_halves[i] = .{};
    g_private_ciphertext[i].len = 0;
}

fn fillOpenUnlocked(i: usize, id: [32]u8, plain: []const u8) void {
    releaseSlotUnlocked(i);
    const h = &g_private_halves[i];
    h.* = .{ .used = true, .state = .open, .id = id };
    @memcpy(h.plain_buf[0..plain.len], plain);
    h.plain_len = @intCast(plain.len);
    touchUnlocked(h);
}

/// The plaintext of `content`, which `list` is being read with now, as a copy
/// the caller frees with `freePrivatePlain`; or null, with the ask queued.
pub fn privateHalfOpened(gpa: std.mem.Allocator, list: HalfList, content: []const u8) ?[]u8 {
    const claimed: usize = claim: {
        lockHalves();
        defer unlockHalves();
        g_current_half[@intFromEnum(list)] = if (content.len == 0) null else privateHalfId(content);
        if (content.len == 0) return null;
        const id = privateHalfId(content);
        if (slotOfUnlocked(id)) |i| {
            const h = &g_private_halves[i];
            touchUnlocked(h);
            if (h.state != .open) return null;
            return gpa.dupe(u8, h.plain()) catch null;
        }
        // Never seen. Claim a slot so the tick asks Notary for it.
        const i = slotToGiveUpUnlocked() orelse return null;
        if (!claimPrivateHalfUnlocked(i, id, content)) return null;
        break :claim i;
    };
    // A test has no tick to fire the ask on, so its stand-in keyholder answers
    // here. In the app this returns null and the answer arrives a tick later,
    // which is the whole reason this is a cache and not a call. A bunker never
    // answers inline, in a test or out of one: its answer is parked by the
    // listener and applied by the sweep.
    if (builtin.is_test and keyholder.g_signer_kind == .helper) {
        answerPrivateHalfForTest(std.heap.page_allocator, claimed, content);
        lockHalves();
        defer unlockHalves();
        const i = slotOfUnlocked(privateHalfId(content)) orelse return null;
        if (g_private_halves[i].state != .open) return null;
        return gpa.dupe(u8, g_private_halves[i].plain()) catch null;
    }
    return null;
}

/// Frees what `privateHalfOpened` handed back, wiped first: it is the reader's
/// private list.
pub fn freePrivatePlain(gpa: std.mem.Allocator, plain: []u8) void {
    std.crypto.secureZero(u8, plain);
    gpa.free(plain);
}

/// Takes slot `i` for this ciphertext and keeps a copy of it, because the ask
/// goes out on a later tick than the read that noticed it was needed.
fn claimPrivateHalfUnlocked(i: usize, id: [32]u8, content: []const u8) bool {
    if (content.len > g_private_ciphertext[i].buf.len) return false;
    // Notary's own door opens NIP-44 and nothing else, so a NIP-04 half is not
    // something it can be asked for. No slot: the half reads as unreadable, which
    // is the truth, rather than as a refusal that a press would keep re-asking.
    if (keyholder.g_signer_kind == .helper and isNip04Payload(content)) return false;
    releaseSlotUnlocked(i);
    g_private_halves[i] = .{ .used = true, .state = .idle, .id = id };
    touchUnlocked(&g_private_halves[i]);
    @memcpy(g_private_ciphertext[i].buf[0..content.len], content);
    g_private_ciphertext[i].len = @intCast(content.len);
    return true;
}
/// Parks a decrypt answer for the tick. One too long to hold is parked as
/// unreadable, never cut: a cut plaintext is a list missing its tail, and a
/// write over it would publish the list without those entries.
pub fn parkHalfAnswer(index: u8, id: [32]u8, plain: []const u8) void {
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_half_inbox) |*box| {
        if (box.used) continue;
        if (plain.len > box.plain_buf.len) {
            box.* = .{ .used = true, .index = index, .half_id = id, .ok = false, .too_large = true };
            return;
        }
        box.* = .{ .used = true, .index = index, .half_id = id, .ok = true, .plain_len = @intCast(plain.len) };
        @memcpy(box.plain_buf[0..plain.len], plain);
        return;
    }
}

/// Parks a bunker's seal for the tick, whole or not at all.
pub fn parkSealAnswer(result: []const u8) void {
    pendingLock();
    defer pendingUnlock();
    remote_signer.g_seal_inbox.used = true;
    remote_signer.g_seal_inbox.ok = result.len > 0 and result.len <= remote_signer.g_seal_inbox.buf.len;
    remote_signer.g_seal_inbox.len = 0;
    if (!remote_signer.g_seal_inbox.ok) return;
    @memcpy(remote_signer.g_seal_inbox.buf[0..result.len], result);
    remote_signer.g_seal_inbox.len = @intCast(result.len);
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
    const gpa = std.heap.page_allocator;
    const remote = keyholder.g_signer_kind == .remote;
    // The ask is settled under the lock and sent after it: sending takes
    // `pendingLock`, which is never taken inside this one.
    var index: usize = 0;
    var key: u64 = 0;
    const content: []u8 = pick: {
        lockHalves();
        defer unlockHalves();
        // A silence from the bunker is not an answer: once its wait is over the
        // half is asked again, by the same state machine that asked it the
        // first time, so it is never asked twice at once.
        rearmPrivateHalvesUnlocked(nowSeconds(), false);
        for (&g_private_halves, 0..) |*h, i| {
            if (!h.used or h.state != .idle) continue;
            const cipher = g_private_ciphertext[i].slice();
            if (cipher.len == 0) {
                h.state = .unreadable;
                continue;
            }
            const copy = gpa.dupe(u8, cipher) catch return;
            index = i;
            // A bunker answers over NIP-46, not over the keyholder's HTTP door.
            // This used to fall through to `helperFetch` regardless, so a reader
            // on an external signer asked a daemon that does not hold their key.
            if (remote) {
                h.state = .asking;
            } else if (!builtin.is_test) {
                key = beginHelperAskUnlocked(i);
            }
            break :pick copy;
        }
        return;
    };
    defer gpa.free(content);
    if (remote) {
        if (!requestRemoteDecrypt(gpa, index, content)) {
            // Nothing was sent (no room to track it, no id): a delay and not an
            // answer, so it is asked again shortly.
            refuseHalfAsk(index, privateHalfId(content), nowSeconds() + private_half_retry_s);
        }
        return;
    }
    if (builtin.is_test) {
        answerPrivateHalfForTest(gpa, index, content);
        return;
    }
    // Nothing went out if the body cannot be built, so the half goes back to
    // waiting for the next tick, as it did before it was marked asked.
    var peer_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&peer_hex, "{x}", .{me}) catch {
        rearmHalfAsk(index, privateHalfId(content));
        return;
    };
    // To yourself: both sides of the conversation key are this account's,
    // which is what NIP-51 means by a half encrypted to yourself.
    const body = (nostr.signer_ipc.Cipher{ .peer = &peer_hex, .items = &.{content} }).toJson(gpa) catch {
        rearmHalfAsk(index, privateHalfId(content));
        return;
    };
    defer gpa.free(body);
    helperFetch(fx, key, "/nip44/decrypt", body, Effects.responseMsg(.private_half));
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
    const gpa = std.heap.page_allocator;
    // Read before the lock is taken; applied only if the slot still waits on it.
    var parsed: ?nostr.signer_ipc.Parsed(nostr.signer_ipc.CipherResult) = null;
    defer if (parsed) |*p| p.deinit();
    const answered = response.outcome == .ok and response.status == 200;
    if (answered) parsed = nostr.signer_ipc.parse(nostr.signer_ipc.CipherResult, gpa, response.body) catch null;

    const opened = apply: {
        lockHalves();
        defer unlockHalves();
        const h = &g_private_halves[@intCast(i)];
        // Only the ask this slot is waiting on. A sign-out frees the slot while
        // an answer is still on its way, and the next account can be asking
        // from the same slot by the time it lands: the answer is then for a
        // ciphertext that is no longer here and must not be applied to the one
        // that is.
        if (!h.used or h.state != .asking or seq == 0 or h.ask_seq != seq) return;
        if (response.outcome == .ok and response.status == 422) {
            h.state = .unreadable;
            return;
        }
        if (!answered) {
            // Refused, or the keyholder is not there. NOT "the half is empty":
            // the whole point of this cache is that unreadable and empty are
            // different answers, and treating them alike is what deletes
            // somebody's list.
            h.state = .refused;
            return;
        }
        const result = parsed orelse {
            h.state = .unreadable;
            return;
        };
        if (result.value.items.len == 0) {
            h.state = .refused;
            return;
        }
        const plain = result.value.items[0];
        // Too long to hold is unreadable, never cut: a cut plaintext is a list
        // missing its tail.
        if (plain.len > h.plain_buf.len) {
            h.state = .unreadable;
            return;
        }
        @memcpy(h.plain_buf[0..plain.len], plain);
        h.plain_len = @intCast(plain.len);
        h.state = .open;
        break :apply true;
    };
    if (!opened) return;
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
    {
        lockHalves();
        defer unlockHalves();
        for (0..g_private_halves.len) |i| releaseSlotUnlocked(i);
        g_current_half = [_]?[32]u8{null} ** g_current_half.len;
        g_seal_base_half = null;
    }
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
pub fn privateHalfIsReadable(gpa: std.mem.Allocator, list: HalfList, content: []const u8) bool {
    const plain = privateHalfOpened(gpa, list, content) orelse return false;
    defer freePrivatePlain(gpa, plain);
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
pub fn privateHalfGate(gpa: std.mem.Allocator, list: HalfList, content: []const u8) HalfGate {
    if (privateHalfIsReadable(gpa, list, content)) return .readable;
    lockHalves();
    defer unlockHalves();
    const h = &g_private_halves[slotOfUnlocked(privateHalfId(content)) orelse return .unreadable];
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

/// Claims a private-half slot the way a reader hitting an encrypted list does,
/// and returns its index, WITHOUT the test keyholder answering it. That is what
/// a bunker reader's state actually looks like: the half is claimed and waiting
/// on a signer that answers over the relay rather than over HTTP.
pub fn claimPrivateHalfPendingForTest(content: []const u8) ?u8 {
    const id = privateHalfId(content);
    lockHalves();
    defer unlockHalves();
    for (&g_private_halves, 0..) |*h, i| {
        if (h.used) continue;
        if (content.len > g_private_ciphertext[i].buf.len) return null;
        h.* = .{ .used = true, .state = .asking, .id = id };
        touchUnlocked(h);
        @memcpy(g_private_ciphertext[i].buf[0..content.len], content);
        g_private_ciphertext[i].len = @intCast(content.len);
        return @intCast(i);
    }
    return null;
}

/// What the listener thread does when the bunker answers a `nip44_decrypt`.
pub fn parkRemoteHalfAnswerForTest(index: u8, plain: []const u8) void {
    parkHalfAnswer(index, slotIdForTest(index), plain);
}

/// The same for an ask that was made about `ciphertext`, whoever holds the slot
/// by the time the answer lands.
pub fn parkRemoteHalfAnswerForCiphertextForTest(index: u8, ciphertext: []const u8, plain: []const u8) void {
    parkHalfAnswer(index, privateHalfId(ciphertext), plain);
}

pub fn slotIdForTest(index: u8) [32]u8 {
    if (index >= g_private_halves.len) return no_half_id;
    lockHalves();
    defer unlockHalves();
    return g_private_halves[index].id;
}

/// A decrypt the bunker refused or never answered, for the ask made about
/// `ciphertext`.
pub fn endRemoteHalfAskForTest(index: u8, ciphertext: []const u8, end: HalfAskEnd) bool {
    return endHalfAsk(index, privateHalfId(ciphertext), end);
}

/// A `nip44_decrypt` the bunker refused: an explicit error.
pub fn failRemoteHalfForTest(index: u8) bool {
    return endHalfAsk(index, slotIdForTest(index), .failed);
}

/// A `nip44_decrypt` the bunker never answered before the deadline.
pub fn timeoutRemoteHalfForTest(index: u8) bool {
    return endHalfAsk(index, slotIdForTest(index), .timed_out);
}
/// What the tick does for every idle half when a bunker is the signer: the ask
/// goes out and the half waits for it. The test has no relay to send to.
pub fn markIdleHalvesAskedForTest() void {
    lockHalves();
    defer unlockHalves();
    for (&g_private_halves) |*h| {
        if (h.used and h.state == .idle) h.state = .asking;
    }
}
pub fn privateHalfRetryAtForTest(index: u8) i64 {
    if (index >= g_private_halves.len) return -1;
    lockHalves();
    defer unlockHalves();
    return g_private_halves[index].retry_at_s;
}

/// How long an opened private half can be before it cannot be held.
pub fn privateHalfPlainCapForTest() usize {
    return g_private_halves[0].plain_buf.len;
}

pub fn privateHalfRetryDelayForTest() i64 {
    return private_half_retry_s;
}

/// The sweep `scanPrivateHalves` runs each tick, with the clock stated.
pub fn rearmPrivateHalvesForTest(now: i64) void {
    rearmPrivateHalves(now, false);
}

pub fn privateHalfStateForTest(index: u8) []const u8 {
    if (index >= g_private_halves.len) return "none";
    lockHalves();
    defer unlockHalves();
    return stateNameUnlocked(index);
}

fn stateNameUnlocked(index: usize) []const u8 {
    if (!g_private_halves[index].used) return "none";
    return switch (g_private_halves[index].state) {
        .idle => "idle",
        .asking => "asking",
        .open => "open",
        .refused => "refused",
        .unreadable => "unreadable",
    };
}

/// What the slot holding `content` says, without reading it for any list or
/// claiming a slot for it: "none" when no slot holds it.
pub fn privateHalfStateOfForTest(content: []const u8) []const u8 {
    lockHalves();
    defer unlockHalves();
    const i = slotOfUnlocked(privateHalfId(content)) orelse return "none";
    return stateNameUnlocked(i);
}

/// Opens `content` as `plain` in the slot it has, or the one a new half would
/// take, without reading it for any list.
pub fn openPrivateHalfForTest(content: []const u8, plain: []const u8) void {
    const id = privateHalfId(content);
    lockHalves();
    defer unlockHalves();
    const i = slotOfUnlocked(id) orelse slotToGiveUpUnlocked() orelse return;
    fillOpenUnlocked(i, id, plain[0..@min(plain.len, g_private_halves[i].plain_buf.len)]);
}

/// Reads `content` as `list`'s private half, the way the list's own reader does.
pub fn readPrivateHalfForTest(list: HalfList, content: []const u8) bool {
    const gpa = std.heap.page_allocator;
    const plain = privateHalfOpened(gpa, list, content) orelse return false;
    freePrivatePlain(gpa, plain);
    return true;
}

/// How many decrypts have been asked over Notary's door.
pub fn halfAskSeqForTest() u32 {
    lockHalves();
    defer unlockHalves();
    return g_half_ask_seq;
}

/// The keyholder a test has, for the decrypt path. Only in a test binary.
pub fn answerPrivateHalfForTest(gpa: std.mem.Allocator, i: usize, content: []const u8) void {
    const secret = feed_state.g_test_secret orelse return;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    const key = beginHelperAsk(i);
    const plain = nostr.nip44.decrypt(gpa, signer, kp.secret_key, kp.public_key, content) catch {
        // Notary would answer 422: it looked, and the ciphertext does not open.
        handlePrivateHalf(.{ .key = key, .outcome = .ok, .status = 422, .body = "{\"error\":\"unreadable\"}" });
        return;
    };
    defer gpa.free(plain);
    const body = (nostr.signer_ipc.CipherResult{ .items = &.{plain} }).toJson(gpa) catch return;
    defer gpa.free(body);
    handlePrivateHalf(.{ .key = key, .outcome = .ok, .status = 200, .body = body });
}
/// The same under a stated key, so an answer can be delivered after the ask it
/// belongs to is long gone.
pub fn deliverPrivateHalfKeyedForTest(key: u64, status: u16, body: []const u8) void {
    handlePrivateHalf(.{ .key = key, .outcome = if (status == 0) .connect_failed else .ok, .status = status, .body = body });
}

/// The key the ask now in flight on slot `index` went out under.
pub fn privateHalfAskKeyForTest(index: u8) u64 {
    lockHalves();
    defer unlockHalves();
    return privateHalfKey(index, g_private_halves[index].ask_seq);
}

/// Puts slot zero in the "asked, waiting" state for a given ciphertext.
pub fn askPrivateHalfForTest(content: []const u8) void {
    lockHalves();
    defer unlockHalves();
    releaseSlotUnlocked(0);
    g_private_halves[0] = .{ .used = true, .state = .idle, .id = privateHalfId(content) };
    _ = beginHelperAskUnlocked(0);
    const n = @min(content.len, g_private_ciphertext[0].buf.len);
    @memcpy(g_private_ciphertext[0].buf[0..n], content[0..n]);
    g_private_ciphertext[0].len = @intCast(n);
}

pub fn privateHalfIsReadableForTest(content: []const u8) bool {
    return privateHalfIsReadable(std.heap.page_allocator, .mutes, content);
}

pub fn forgetPrivateHalvesForTest() void {
    forgetPrivateHalves();
}

pub fn privateHalfGateNameForTest(content: []const u8) []const u8 {
    return @tagName(privateHalfGate(std.heap.page_allocator, .mutes, content));
}

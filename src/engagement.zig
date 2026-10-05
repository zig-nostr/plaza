//! Counts under a note, the reader's own likes, and zap amounts.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const activePubkey = main.activePubkey;

// The notes this session has liked, so the heart renders filled and an un-like
// knows which reaction (kind:7) to delete. In-memory: this is the optimistic
// layer, not the source of truth.
//
// Every entry records WHOSE like it is, and that is not decoration. The key was
// the note id alone, which is identical under every account, and nothing ever
// cleared the table. So a note liked as one account showed a filled red heart
// to the next account signed in on the same machine, who had never touched it,
// and their first press took the UN-like branch: Plaza signed a kind:5 under
// THEIR key naming a reaction the other account authored. That is a public,
// permanent, on-relay link between two identities the reader was keeping apart,
// it destroys the app's only record of the first account's reaction, and their
// intended like never publishes at all.
//
// An owner makes that impossible by construction rather than by remembering to
// clear the table on every door out of an account, which is the version of this
// fix that goes stale the first time somebody adds another door.
pub const my_likes_cap = 512;
pub const MyLike = struct {
    used: bool = false,
    owner: [32]u8 = [_]u8{0} ** 32,
    note_id: i64 = 0,
    // The id of our own kind:7 reaction, e-tagged by the kind:5 that un-likes it.
    reaction_id: [32]u8 = [_]u8{0} ** 32,
};
pub var g_my_likes = [_]MyLike{.{}} ** my_likes_cap;

/// Whether the signed-in account has liked `note_id`.
pub fn isLiked(note_id: i64) bool {
    return likeEntry(note_id) != null;
}

/// The signed-in account's like record for `note_id`, or null. A guest has no
/// likes, and neither does anyone else's entry.
pub fn likeEntry(note_id: i64) ?*MyLike {
    const me = activePubkey() orelse return null;
    for (&g_my_likes) |*e| {
        if (e.used and e.note_id == note_id and std.mem.eql(u8, &e.owner, &me)) return e;
    }
    return null;
}

/// Records a like on `note_id` with our reaction's id, so the heart fills and an
/// un-like can find the reaction. Silently drops when the table is full (the
/// like still publishes; only the optimistic bookkeeping is skipped).
pub fn rememberLike(note_id: i64, reaction_id: [32]u8) void {
    const me = activePubkey() orelse return;
    if (likeEntry(note_id)) |e| {
        e.reaction_id = reaction_id;
        return;
    }
    for (&g_my_likes) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .owner = me, .note_id = note_id, .reaction_id = reaction_id };
            return;
        }
    }
}

/// Drops the like on `note_id`, returning its reaction id (to e-tag the un-like).
pub fn forgetLike(note_id: i64) ?[32]u8 {
    if (likeEntry(note_id)) |e| {
        const id = e.reaction_id;
        e.* = .{};
        return id;
    }
    return null;
}
// ------------------------------------------------------------ engagement counts
//
// Reply / repost / like / zap tallies per feed note, aggregated client-side (no
// NIP-45 COUNT, whose relay support is spotty). Each ingest thread opens a second
// subscription, `{kinds:[1,6,7,9735], "#e":[the notes it loaded]}`, and folds the
// arriving events into this in-memory table, deduped across relays by event id.
// The view reads it at render time. Counts are per session: a relaunch refetches
// them, so nothing here is persisted.

// Above the displayed feed so the union of the relays' watched sets fits with
// room to spare; a full table then only degrades gracefully (see ensureEngagement).
pub const engagement_cap = 512;
pub const Counts = struct {
    replies: u32 = 0,
    reposts: u32 = 0,
    likes: u32 = 0,
    zap_msat: u64 = 0,
    /// Whether one of those reposts is ours.
    ///
    /// Read out of the crowd rather than kept in a table of our own, which is
    /// what a like needs: an un-like has to name the exact reaction it deletes,
    /// so that id is remembered locally. A repost has no undo (see `repost`), so
    /// the only question is whether ours is in there, and the subscription that
    /// counts them already carries the answer. It also means the filled icon
    /// survives a relaunch, and is true for a repost sent from another client.
    reposted_by_me: bool = false,
};
pub const Engagement = struct {
    used: bool = false,
    note_id: i64 = 0,
    counts: Counts = .{},
    /// Which relays in the pool have delivered this note, one bit each. The
    /// thread's focal line reports the count, so the claim "seen on 4 relays" is
    /// a measurement rather than a guess. A pool wider than the mask simply stops
    /// counting past bit 63, which no configuration reaches today.
    relays_seen: u64 = 0,
};
pub var g_engagement = [_]Engagement{.{}} ** engagement_cap;

// Cross-relay dedup: a bounded open-addressing set of event-id prefixes (the
// first 8 bytes as a u64; 0 marks an empty slot, so the ~1-in-2^64 all-zero
// prefix is simply never deduped). When it fills, new ids stop being recorded
// and a reaction seen on two relays can double-count; sized far above a starter
// pack feed's traffic so that is only a theoretical tail.
pub const seen_engagement_cap = 1 << 15;
pub var g_seen = [_]u64{0} ** seen_engagement_cap;
pub var g_seen_len: usize = 0;
var g_engagement_lock = std.atomic.Value(bool).init(false);
pub fn engagementLock() void {
    while (g_engagement_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn engagementUnlock() void {
    g_engagement_lock.store(false, .release);
}

/// The u64 dedup key for an event id (its first 8 bytes, big-endian).
pub fn idPrefix(id: [32]u8) u64 {
    return std.mem.readInt(u64, id[0..8], .big);
}
/// Whether `prefix` is already in the seen set. Caller holds the lock. The probe
/// count is bounded by the table size so a full table cannot spin.
fn seenContains(prefix: u64) bool {
    if (prefix == 0) return false;
    var i = prefix % seen_engagement_cap;
    var probes: usize = 0;
    while (g_seen[i] != 0 and probes < seen_engagement_cap) : ({
        i = (i + 1) % seen_engagement_cap;
        probes += 1;
    }) {
        if (g_seen[i] == prefix) return true;
    }
    return false;
}

/// Records `prefix` as seen and returns true if it was new (not a cross-relay
/// duplicate). Caller holds the lock. A full set (or the ~1-in-2^64 zero prefix)
/// reports NOT-new, so counting stops rather than double-counting: reporting new
/// there would fold an event into the crowd total that `seenContains` can never
/// confirm, breaking the own-like reconciliation. Sized far above a feed's
/// traffic so this "stop counting" tail is only theoretical.
fn markSeen(prefix: u64) bool {
    if (prefix == 0 or g_seen_len >= seen_engagement_cap) return false;
    var i = prefix % seen_engagement_cap;
    while (g_seen[i] != 0) : (i = (i + 1) % seen_engagement_cap) {
        if (g_seen[i] == prefix) return false;
    }
    g_seen[i] = prefix;
    g_seen_len += 1;
    return true;
}

/// The counts row for `note_id`, creating it if there is room. Caller holds the
/// lock. Null only when the table is full of other notes.
pub fn ensureEngagement(note_id: i64) ?*Engagement {
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return e;
    }
    for (&g_engagement) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .note_id = note_id };
            return e;
        }
    }
    return null;
}

/// The crowd counts for `note_id` (zeroes if none). Read at render time.
pub fn engagementFor(note_id: i64) Counts {
    engagementLock();
    defer engagementUnlock();
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return e.counts;
    }
    return .{};
}

/// The like count to display for a note: the crowd's likes plus this session's
/// own optimistic +1, dropped once our reaction (`my_reaction`) has come back
/// through the subscription and is folded into the crowd total. Both reads
/// happen under one lock hold, so the two never disagree across a concurrent
/// count (which would flicker the number for a frame).
pub fn likeCountFor(note_id: i64, my_reaction: ?[32]u8) u64 {
    engagementLock();
    defer engagementUnlock();
    var crowd: u32 = 0;
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) {
            crowd = e.counts.likes;
            break;
        }
    }
    const mine: u64 = if (my_reaction) |rid| (if (seenContains(idPrefix(rid))) 0 else 1) else 0;
    return @as(u64, crowd) + mine;
}

/// Whether a kind:7 reaction's content counts as a like: NIP-25 treats "+" and
/// empty as a like, and "-" (a downvote) and emoji/shortcode as something else.
fn isLikeReaction(content: []const u8) bool {
    return content.len == 0 or std.mem.eql(u8, content, "+");
}

/// The millisats a bolt11 invoice encodes, or 0 when it carries no amount. The
/// human-readable part is everything before the bech32 separator (the only '1',
/// since the data charset excludes it); the amount is its digits times the
/// optional multiplier, scaled to msat (1 BTC = 1e11 msat).
pub fn bolt11Msat(invoice: []const u8) u64 {
    if (!std.mem.startsWith(u8, invoice, "ln")) return 0;
    const sep = std.mem.lastIndexOfScalar(u8, invoice, '1') orelse return 0;
    const hrp = invoice[0..sep];
    var i: usize = 2; // past "ln"
    while (i < hrp.len and !std.ascii.isDigit(hrp[i])) i += 1; // past the currency
    const start = i;
    while (i < hrp.len and std.ascii.isDigit(hrp[i])) i += 1;
    if (i == start) return 0; // an amountless "any amount" invoice
    const num = std.fmt.parseInt(u64, hrp[start..i], 10) catch return 0;
    const mult: u8 = if (i < hrp.len) hrp[i] else 0;
    return switch (mult) {
        'm' => num *| 100_000_000,
        'u' => num *| 100_000,
        'n' => num *| 100,
        'p' => num / 10,
        0 => num *| 100_000_000_000,
        else => 0,
    };
}

/// The sats a kind:9735 zap receipt is worth, from its bolt11 tag.
/// The most a single receipt may add to a note's total.
///
/// Not a judgement about generosity: it is a bound on how wrong one forged
/// receipt can make the number. A hundred thousand sats is already an unusual
/// zap, and a card claiming millions is the whole payoff for forging one.
pub const zap_msat_ceiling: u64 = 100_000_000; // 100k sats
/// What a zap receipt is worth to a note's total, after checking it is real.
///
/// The counting path used to read the receipt's own `bolt11` tag and add it,
/// with nothing checked. A kind:9735 is an ordinary public event that anybody
/// can publish, so a note could be given any total at all by writing a receipt
/// with a large invoice string in it and no payment behind it. `zapClaim`
/// already did this properly for the inbox and this path never called it.
///
/// What is checked here, without a network round trip:
///
///   - the `description` holds a real kind:9734 zap request whose signature
///     verifies, so the receipt carries something the payer actually signed;
///   - that request asks about THIS event, so a genuine receipt for a different
///     note cannot be replayed onto this one;
///   - the amount is the smaller of what the request asked for and what the
///     invoice says, so neither number alone can inflate the total;
///   - the result is clamped.
///
/// Not checked: that the receipt is signed by the recipient's LNURL server
/// (`nostrPubkey`), which the reference clients do verify. That needs the
/// recipient's LNURL, which is a fetch this path cannot make. Its absence means
/// a receipt can still be minted by someone willing to sign a zap request for
/// the reader's note, which is a far higher bar than editing a string.
fn zapMsat(ev: nostr.event.Event) u64 {
    const target = engagementTarget(ev) orelse return 0;

    var invoice_msat: u64 = 0;
    var description: ?[]const u8 = null;
    for (ev.tags) |tag| {
        if (tag.len < 2) continue;
        if (std.mem.eql(u8, tag[0], "bolt11")) invoice_msat = bolt11Msat(tag[1]);
        if (std.mem.eql(u8, tag[0], "description")) description = tag[1];
    }
    const desc = description orelse return 0;

    const gpa = std.heap.page_allocator;
    var parsed = nostr.event.fromJson(gpa, desc) catch return 0;
    defer parsed.deinit();
    const req = parsed.value;
    if (req.kind != 9734) return 0;

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    if (!(nostr.event.verify(gpa, signer, req) catch false)) return 0;

    // The request has to be about the note being credited. Without this a real
    // receipt for a popular note could be re-published against any other note.
    var about_this_note = false;
    var requested_msat: u64 = 0;
    for (req.tags) |t| {
        if (t.len < 2) continue;
        if (t[0].len == 1 and t[0][0] == 'e' and std.ascii.eqlIgnoreCase(t[1], target))
            about_this_note = true;
        if (std.mem.eql(u8, t[0], "amount"))
            requested_msat = std.fmt.parseInt(u64, t[1], 10) catch 0;
    }
    if (!about_this_note) return 0;

    // Both numbers, when both are present: the smaller one. An invoice for a
    // fortune attached to a request for a sat is not worth a fortune, and the
    // reverse is equally untrue.
    const msat = if (requested_msat > 0 and invoice_msat > 0)
        @min(requested_msat, invoice_msat)
    else if (invoice_msat > 0) invoice_msat else requested_msat;

    return @min(msat, zap_msat_ceiling);
}

/// The single note an engagement event is about: its `reply`-marked e tag if it
/// has one (NIP-10), else its last e tag (NIP-25 says a reaction's target is the
/// last e tag; the same positional convention names a reply's direct parent).
/// Counting only this one, rather than every e tag, keeps a threaded reply from
/// crediting the whole ancestor chain and dedupes an id repeated across tags.
pub fn engagementTarget(ev: nostr.event.Event) ?[]const u8 {
    var last_e: ?[]const u8 = null;
    var reply_e: ?[]const u8 = null;
    for (ev.tags) |tag| {
        if (tag.len < 2 or tag[0].len != 1 or tag[0][0] != 'e') continue;
        last_e = tag[1];
        if (tag.len >= 4 and std.mem.eql(u8, tag[3], "reply")) reply_e = tag[1];
    }
    return reply_e orelse last_e;
}

/// Folds one engagement event into the count of the single note it targets, when
/// that note is in this relay thread's loaded set. The cross-relay dedup
/// (`markSeen`) happens only AFTER the target is confirmed present here and a row
/// is in hand, so an event a thread cannot place does not consume the dedup slot
/// (which would let its true owner drop it) and a full table cannot mark an event
/// seen-but-uncounted (which would break the own-like reconciliation).
pub fn countEngagement(ev: nostr.event.Event, feed_ids: []const i64) void {
    // A reaction that is not a like ("+") adds nothing.
    if (ev.kind == 7 and !isLikeReaction(ev.content)) return;
    const target_hex = engagementTarget(ev) orelse return;
    const target = noteIdFromHex(target_hex) orelse return;

    engagementLock();
    defer engagementUnlock();
    var in_feed = false;
    for (feed_ids) |fid| {
        if (fid == target) {
            in_feed = true;
            break;
        }
    }
    if (!in_feed) return;
    const row = ensureEngagement(target) orelse return;
    if (!markSeen(idPrefix(ev.id))) return;
    switch (ev.kind) {
        1 => row.counts.replies += 1,
        6, 16 => {
            row.counts.reposts += 1;
            if (activePubkey()) |me| {
                if (std.mem.eql(u8, &ev.pubkey, &me)) row.counts.reposted_by_me = true;
            }
        },
        7 => row.counts.likes += 1,
        9735 => row.counts.zap_msat +|= zapMsat(ev),
        else => {},
    }
}

/// Parses a 64-char hex event id's first 8 bytes into the same non-negative i64
/// key `noteIdOf` derives, so an `e` tag maps onto a loaded note. Null when the
/// value is not at least 16 hex digits.
fn noteIdFromHex(hex: []const u8) ?i64 {
    if (hex.len < 16) return null;
    var bytes: [8]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex[0..16]) catch return null;
    return @intCast(std.mem.readInt(u64, &bytes, .big) & std.math.maxInt(i64));
}

/// Clears the like table. For tests, which share the process globals.
pub fn rememberLikeForTest(note_id: i64, reaction_id: [32]u8) void {
    rememberLike(note_id, reaction_id);
}

pub fn likeReactionIdForTest(note_id: i64) ?[32]u8 {
    const e = likeEntry(note_id) orelse return null;
    return e.reaction_id;
}

pub fn resetLikesForTest() void {
    g_my_likes = [_]MyLike{.{}} ** my_likes_cap;
}

/// Whether this session has liked the note (for tests and the view).
pub fn isLikedForTest(note_id: i64) bool {
    return isLiked(note_id);
}
pub const zap_msat_ceiling_for_test = zap_msat_ceiling;

/// Clears the engagement table and dedup set. For tests.
/// Sets a note's zap total directly, for tests about what the RENDER does with
/// a large number. Ingestion cannot produce one in a single step any more, and
/// the two properties are worth testing apart: what is admitted, and what is
/// survivable once admitted.
pub fn setZapMsatForTest(id: i64, msat: u64) void {
    engagementLock();
    defer engagementUnlock();
    if (ensureEngagement(id)) |row| row.counts.zap_msat = msat;
}

pub fn resetEngagementForTest() void {
    g_engagement = [_]Engagement{.{}} ** engagement_cap;
    g_seen = [_]u64{0} ** seen_engagement_cap;
    g_seen_len = 0;
}

/// Folds an event into the counts, for tests (the ingest path without threads).
pub fn countEngagementForTest(ev: nostr.event.Event, feed_ids: []const i64) void {
    countEngagement(ev, feed_ids);
}
pub fn repostedByMeForTest(note_id: i64) bool {
    return engagementFor(note_id).reposted_by_me;
}

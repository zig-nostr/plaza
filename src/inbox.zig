//! Notifications: what arrives, what is unread, and what is saved between runs.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const profile_cache = @import("profile_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const MentionList = main.MentionList;
const activePubkey = main.activePubkey;
const clipToChars = main.clipToChars;
const comment_kind = main.comment_kind;
const contentNames = main.contentNames;
const contentWarningOf = main.contentWarningOf;
const engagementTarget = main.engagementTarget;
const feedKeyOf = main.feedKeyOf;
const hexLower = main.hexLower;
const inbox_page = main.inbox_page;
const isBech32Char = main.isBech32Char;
const isEventRefStart = main.isEventRefStart;
const isInReadGraph = main.isInReadGraph;
const isMuted = main.isMuted;
const like = main.like;
const note_content_cap = main.note_content_cap;
const nowSeconds = main.nowSeconds;
const renderContentInto = main.renderContentInto;
const replyParent = main.replyParent;
const repost = main.repost;
const wantProfile = main.wantProfile;
const wantQuote = main.wantQuote;
const warning_reason_bytes = main.warning_reason_bytes;

/// Notes that this relay has now delivered. Called from each relay's ingest
/// thread as the event lands, so the count is of relays that ACTUALLY sent it.
// ------------------------------------------------------------------- the inbox
//
// What other people did that was aimed at this reader: replies, mentions, likes,
// reposts and zaps. It is the first surface in this app where a stranger can put
// something in front of the reader, so what does NOT get in matters as much as
// what does.
//
// One function decides three things at once: whether an event becomes an item,
// which verb it is, and whether it counts toward the bell. Every client that
// split those decisions ended up with a badge that disagreed with its own list.

/// The kinds a relay is asked for on the reader's behalf.
pub const inbox_kinds = [_]u16{ 1, comment_kind, 6, 7, 9735 };

/// How many items are kept. The KV holds one rewritten blob, so this is what
/// bounds it, and the oldest fall off the end.
pub const inbox_cap = 200;

/// How many people may be p-tagged before an event is treated as a broadcast
/// rather than a message. A note naming twenty people is a hellthread, and
/// being one of the twenty is not a notification.
const inbox_hellthread_max = 10;

/// How many items any ONE author may hold at once.
///
/// The hellthread rule refuses a single event naming a crowd. This refuses the
/// mirror image, which is cheaper to send and worse: many events each naming
/// only the reader. Signing two hundred of those costs seconds and nothing else,
/// and without a per-author bound they evict every notification the reader
/// actually wanted, permanently, because `inboxSince` then resumes past them.
pub const inbox_per_author_max = 20;

/// The most a zap may claim before the amount is treated as noise.
///
/// `bolt11` is a string the sender writes, so the number in it is a claim, not a
/// fact. Bitcoin's whole supply is 21e14 sats; anything above that is a parser
/// artefact or a lie, and either way the honest thing to draw is no amount at
/// all rather than eighteen quintillion.
const inbox_max_claimable_msat: u64 = 21_000_000 * 100_000_000 * 1000;

// `created_at` is written by whoever signed the event, so it is not a fact. One
// event dated 2100 would push the read mark past everything that will ever
// arrive and the bell would never light again. Nostur ships that bug with the
// TODO still in the file.
//
// Clamped to NOW, with no skew allowance. An allowance sounds generous and is
// not: marking read would then move the mark that far into the future, and
// everything arriving inside the window would be born already read. A genuine
// event from a slightly fast clock simply sorts as "now", which costs nothing.

pub const InboxVerb = enum { reply, mention, like, repost, zap };

pub const InboxItem = struct {
    used: bool = false,
    id: [32]u8 = [_]u8{0} ** 32,
    author: [32]u8 = [_]u8{0} ** 32,
    /// The note this is about, when it is about one. The WHOLE id, not the feed's
    /// truncated handle: the note a notification points at is usually an old one
    /// of the reader's own, which the follow-scoped feed window does not hold, so
    /// the row has to be able to ask the store for it by name.
    target_id: [32]u8 = [_]u8{0} ** 32,
    created_at: i64 = 0,
    verb: InboxVerb = .mention,
    /// Millisats, for a zap.
    msat: u64 = 0,
    /// The words this row shows, copied in when the item is admitted.
    ///
    /// Never read from the store while drawing. The feed already paid for that
    /// lesson: asking the database who you follow once per card cost 24423us to
    /// rebuild, three whole frames to draw one, and two hundred notification
    /// rows querying per frame would be the same bug wearing a different hat.
    ///
    /// WHICH note this holds depends on the verb, and that is the whole design.
    /// For a reply or a mention it is THEIR note, because the question is what
    /// did they say. For a reaction, a repost or a zap it is YOUR note, because
    /// the question is which of mine did this happen to.
    body_buf: [180]u8 = [_]u8{0} ** 180,
    body_len: u8 = 0,
    /// A reaction's own content: `+`, `-`, an emoji, or a `:shortcode:`. The
    /// gutter draws this instead of a generic heart, which is the difference
    /// between "somebody reacted" and seeing what they actually sent.
    glyph_buf: [16]u8 = [_]u8{0} ** 16,
    glyph_len: u8 = 0,
    /// The note whose words `body_buf` holds asked to be covered (NIP-36). The
    /// row draws the cover chip in the body's place, and `body_key` is the id
    /// pressing it uncovers, the same one the note carries in the feed.
    warned: bool = false,
    warning_buf: [warning_reason_bytes]u8 = [_]u8{0} ** warning_reason_bytes,
    warning_len: u8 = 0,
    body_key: i64 = 0,
    /// Whether the baked words name somebody, so they are worth baking again
    /// when a name lands. A mention label is written into the text at bake time,
    /// the same as a note's is, and the same thing keeps it honest: the names
    /// generation it was baked under.
    names_pending: bool = false,
    names_generation: u64 = 0,
    /// Admitted and not yet looked at on the UI thread. `inboxAdd` runs on the
    /// relay readers, and the profile and quote caches that baking the words and
    /// asking for the author's name touch are the UI thread's alone, so those
    /// wait for `resolveInboxBodies`.
    fresh: bool = false,
    /// Where each person's name sits in the words, so the row styles the whole
    /// name the way the feed does, `@Ada Lovelace` and not just `@Ada`.
    mentions: MentionList = .{},

    pub fn hasTarget(self: InboxItem) bool {
        return !std.mem.allEqual(u8, &self.target_id, 0);
    }

    pub fn body(self: *const InboxItem) []const u8 {
        return self.body_buf[0..self.body_len];
    }

    pub fn reactionGlyph(self: *const InboxItem) []const u8 {
        return self.glyph_buf[0..self.glyph_len];
    }
};

/// Copies `src` into `dst`, clipped to whole codepoints, and returns the length.
fn fillClipped(dst: []u8, src: []const u8) u8 {
    // Whitespace runs collapse to one space, newlines included. A preview is one
    // block: kept as-is, a note with a blank line between paragraphs drew as two
    // separated blocks inside a row, so four notifications filled the screen and
    // the list read as a stack of documents rather than a list of events.
    var flat_buf: [512]u8 = undefined;
    var flat_len: usize = 0;
    var in_space = false;
    for (src) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            in_space = true;
            continue;
        }
        if (in_space and flat_len > 0 and flat_len < flat_buf.len) {
            flat_buf[flat_len] = ' ';
            flat_len += 1;
        }
        in_space = false;
        if (flat_len == flat_buf.len) break;
        flat_buf[flat_len] = c;
        flat_len += 1;
    }
    const trimmed = flat_buf[0..flat_len];
    const ellipsis = "\u{2026}";
    // Room kept for the ellipsis before clipping, not after: appending it to a
    // full buffer would either overflow or cut a codepoint in half.
    const room = if (trimmed.len > dst.len) dst.len - ellipsis.len else dst.len;
    const take = clipToChars(trimmed, room, room);
    @memcpy(dst[0..take.len], take);
    if (take.len == trimmed.len) return @intCast(take.len);
    // Cut. Say so, or a sentence that stops mid-word reads as the whole note.
    @memcpy(dst[take.len..][0..ellipsis.len], ellipsis);
    return @intCast(take.len + ellipsis.len);
}

pub var g_inbox = [_]InboxItem{.{}} ** inbox_cap;
pub var g_inbox_len: usize = 0;
/// Whose inbox this is. One reader's notifications are never another's.
pub var g_inbox_owner: ?[32]u8 = null;
/// Everything at or below this stamp has been seen. A single number, because the
/// KV has no cursor and no delete, so a per-item read set could neither be
/// enumerated nor pruned.
pub var g_inbox_read_through: i64 = 0;
var g_inbox_lock = std.atomic.Value(bool).init(false);
var g_inbox_dirty = false;

pub fn lockInbox() void {
    while (g_inbox_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockInbox() void {
    g_inbox_lock.store(false, .release);
}

/// A timestamp this app is willing to act on.
fn believableStamp(created_at: i64, now_s: i64) i64 {
    return @min(created_at, now_s);
}

/// Whether `ev` is something the reader should be told about, and what it is.
///
/// The one gate. The bell, the sheet and the badge all read the result of this,
/// so they cannot drift apart.
pub fn inboxVerbFor(ev: nostr.event.Event, me: [32]u8) ?InboxVerb {
    // Your own actions are not news, except a zap receipt, which is authored by
    // a payment server rather than by the person who paid.
    if (ev.kind != 9735 and std.mem.eql(u8, &ev.pubkey, &me)) return null;

    // The relay is asked for events p-tagging the reader, but a relay may send
    // anything down any subscription, so the claim is checked here.
    var p_tags: usize = 0;
    var names_me = false;
    var hex: [64]u8 = undefined;
    hexLower(&hex, me);
    var last_p_is_me = false;
    for (ev.tags) |tag| {
        // Lowercase `p` only, including for a comment, which is what the
        // reference clients do and I checked rather than reasoned.
        //
        // NIP-22 gives a comment two author tags: `P` is the author of the
        // thread's ROOT, `p` the author of the note being answered. Reading
        // `P` here looks generous and is wrong. Amethyst's notification
        // subscription asks `mapOf("p" to listOf(pubkey))` and its classifier
        // is `it[0] == "p"`, both lowercase; Jumble's is `'#p': [pubkey]`.
        // Both carry kind 1111 in their notification kinds, so this is a
        // deliberate narrowing on their part rather than an oversight.
        //
        // Amethyst DOES parse `P`, as `RootAuthorTag`, and uses it for
        // `pubKeyHints()` and `linkedPubKeys()`: relay hints and which
        // profiles to prefetch. Never for the inbox. Taking that as "it
        // admits both" is the misreading this comment exists to prevent.
        //
        // The behaviour it buys: a comment deep in a thread I started, between
        // other people, is not news. A thread can run for a hundred messages
        // and telling the root author about each one is the hellthread problem
        // in NIP-22 clothing.
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "p")) continue;
        p_tags += 1;
        const mine = std.ascii.eqlIgnoreCase(tag[1], &hex);
        if (mine) names_me = true;
        // Tracked separately: for a reaction or a repost the LAST p tag is the
        // one that means "this is about you".
        last_p_is_me = mine;
    }
    if (!names_me) return null;
    // A note addressed to a crowd is a broadcast. Being one of twenty names on
    // it is the most common way an inbox floods.
    if (p_tags > inbox_hellthread_max) return null;

    return switch (ev.kind) {
        // A comment is a reply written in the other vocabulary, so it asks the
        // same question. Adding the kind to `inbox_kinds` without adding it
        // here would let the events arrive and then produce no row: the REQ and
        // this switch are two gates, and a kind in one but not the other is a
        // subscription paying for events nobody draws.
        1, comment_kind => noteVerbFor(ev, me, last_p_is_me),
        // A repost or a reaction copies the p tags of what it is about, and
        // NIP-10 has a reply carry every p tag of its parent plus the parent's
        // author. So the reader's key propagates down every thread they ever
        // touched, and ANY-tag matching then filed somebody reacting to a
        // stranger's reply, three levels below a note of the reader's, as a
        // notification about the reader.
        //
        // NIP-25: "If a client decides to include other `p` tags, which not
        // recommended, the target event `pubkey` should be last the `p` tags."
        // So the last one is the target's author. Jumble enforces exactly this.
        // Where the reacted event is on disk, its author is checked directly,
        // which is better evidence than tag order.
        6, 16 => if (reactionTargetsMe(ev, me, last_p_is_me)) .repost else null,
        // Every reaction except the one that is not good news. The content
        // picks the GLYPH; it does not decide admission. Requiring "+" or empty
        // meant a heart, a fire or any custom shortcode produced no row, no
        // badge and no glyph, so a reader was told nobody had reacted when
        // people had, and the emoji the row is built to show could never reach
        // it. NIP-25 has exactly one negative, and a downvote is still not
        // something to celebrate in a bell.
        7 => if (!isDownvoteReaction(ev.content) and reactionTargetsMe(ev, me, last_p_is_me)) .like else null,
        9735 => .zap,
        else => null,
    };
}

/// NIP-25's one negative reaction: content of exactly "-".
///
/// Everything else, "+" and empty and every emoji and shortcode, is somebody
/// reacting well enough to be told about.
fn isDownvoteReaction(content: []const u8) bool {
    return std.mem.eql(u8, content, "-");
}

/// What a kind:1 naming the reader actually is, or null when it is not about
/// them at all.
///
/// The distinction that matters is whether the note is a REPLY. NIP-10 has a
/// reply carry every `p` tag of its parent plus the parent's author, so once
/// the reader posts a single word into a thread, their key travels down every
/// branch of it forever. Reading any `p` tag as a mention therefore filed every
/// later exchange between two other people, in any conversation the reader once
/// touched, as "X mentioned you in a note". In a busy thread that becomes the
/// commonest row in the inbox: it pushes real notifications out through the
/// item cap and inflates the unread badge on the rail.
///
/// A note that is NOT a reply inherited nothing, so a `p` tag on it is a
/// decision somebody made, and it still counts.
fn noteVerbFor(ev: nostr.event.Event, me: [32]u8, last_p_is_me: bool) ?InboxVerb {
    // Answering a note this app holds and can see is the reader's.
    if (inboxTargetsMyNote(ev, me)) return .reply;
    // Named in the text. A mention is something the writer typed, so a quote of
    // the reader's note counts here too.
    if (contentNames(ev.content, me)) return .mention;
    if (replyParent(ev.kind, ev.tags) != null) {
        // A reply whose parent this app does not hold, which is the normal case
        // for a reader who has been away. NIP-25's ordering rule is the same
        // fallback the reaction path leans on: the last `p` tag is the one the
        // event is about. It is what keeps a genuine reply from being dropped
        // along with the thread noise.
        return if (last_p_is_me) .reply else null;
    }
    return .mention;
}

/// Whether a reaction or repost is about a note of the reader's.
///
/// The store is the authority when it holds the target: an author is a fact,
/// where tag order is a convention the sender may not have followed. Falls back
/// to NIP-25's rule that the target's author is the last `p` tag.
fn reactionTargetsMe(ev: nostr.event.Event, me: [32]u8, last_p_is_me: bool) bool {
    if (engagementTarget(ev)) |t| {
        if (t.len == 64) {
            var id: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&id, t)) |_| {
                if (main.g_store) |store| {
                    if (store.getEvent(std.heap.page_allocator, id) catch null) |found| {
                        var se = found;
                        defer se.deinit();
                        return std.mem.eql(u8, &se.event.pubkey, &me);
                    }
                }
            } else |_| {}
        }
    }
    return last_p_is_me;
}

/// Whether this note replies to something the reader wrote, as opposed to merely
/// naming them. The difference is the difference between a conversation and a
/// stranger putting a link in front of you.
fn inboxTargetsMyNote(ev: nostr.event.Event, me: [32]u8) bool {
    const parent = replyParent(ev.kind, ev.tags) orelse return false;
    const store = main.g_store orelse return false;
    var se = (store.getEvent(std.heap.page_allocator, parent) catch return false) orelse return false;
    defer se.deinit();
    return std.mem.eql(u8, &se.event.pubkey, &me);
}

/// Files an event, if it is one for the reader. Returns whether anything new
/// landed, so a caller can decide whether to save.
pub fn inboxAdd(ev: nostr.event.Event, now_s: i64) bool {
    const me = activePubkey() orelse return false;
    const verb = inboxVerbFor(ev, me) orelse return false;

    lockInbox();
    defer unlockInbox();
    if (g_inbox_owner) |owner| {
        if (!std.mem.eql(u8, &owner, &me)) resetInboxLocked(me);
    } else {
        resetInboxLocked(me);
    }

    // A zap whose payer cannot be established is not filed at all. Falling back
    // to the receipt's own author would put a payment server's key where a
    // person's name goes, and inventing "someone" for it would give a forgery a
    // row to sit in.
    //
    // A zap's IDENTITY is the request's id, not the receipt's. A receipt is a
    // wrapper anyone may write, and the request inside it is public by
    // construction, so one genuine request from somebody the reader follows is
    // all it takes to mint an unlimited number of receipts carrying it. Keying
    // on the receipt let every one of those become its own row, under that
    // person's real name, and the per-author rule then evicted their real
    // notifications to make room. Keyed on the request, a thousand replays are
    // one payment, which is what they are.
    const claim: ?ZapClaim = if (ev.kind == 9735) (zapClaim(ev, me) orelse return false) else null;
    const author = if (claim) |c| c.payer else ev.pubkey;
    const identity = if (claim) |c| c.id else ev.id;
    // Muted, so no row. Checked against the AUTHOR established above rather
    // than the event's own pubkey, which for a zap is a payment server: muting
    // somebody has to stop their zaps too, and their key is only in the request
    // inside the receipt.
    if (isMuted(author)) return false;

    // Deduped on that identity, which is why this runs here rather than on the
    // way in: twenty receipts wrapping one request have twenty ids of their own,
    // and comparing those is exactly what let the replay through.
    for (g_inbox[0..g_inbox_len]) |item| {
        if (std.mem.eql(u8, &item.id, &identity)) return false;
    }

    var target: [32]u8 = [_]u8{0} ** 32;
    if (engagementTarget(ev)) |t| {
        // Into scratch, copied only on success: `hexToBytes` decodes as far as it
        // can before returning an error, so writing straight into `target` left a
        // real prefix and a zero tail on a 64-character tag that was not hex, and
        // `hasTarget` then reported that wreckage as a note to open.
        if (t.len == 64) {
            var scratch: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&scratch, t)) |_| {
                target = scratch;
            } else |_| {}
        }
    }

    var item = InboxItem{
        .used = true,
        .id = identity,
        .author = author,
        .target_id = target,
        // A replay carries the original's time as well, so it cannot pose as
        // something that just happened.
        .created_at = believableStamp(if (claim) |c| c.created_at else ev.created_at, now_s),
        .verb = verb,
        .msat = if (claim) |c| c.msat else 0,
        .fresh = true,
    };
    // A reaction's own glyph, before the item is copied into the inbox. It is
    // the event's content and needs nothing else. The words wait: rendering
    // them looks names up in the profile cache, which belongs to the UI thread,
    // and this runs on whichever relay reader the event came in on. The event
    // is already in the store, so `resolveInboxBodies` reads them from there.
    if (verb == .like) bakeReactionGlyph(&item, ev);

    if (!inboxAdmitLocked(item)) return false;
    g_inbox_dirty = true;
    g_inbox_fresh.store(true, .release);
    g_inbox_unbaked.store(true, .release);
    return true;
}

/// Set when an item is admitted that the UI thread has not welcomed yet.
var g_inbox_fresh = std.atomic.Value(bool).init(false);
/// Set when an item is admitted whose words are not baked yet, so the next
/// resolve runs even when the store did not move (an event the store already
/// held is admitted without adding to its count).
var g_inbox_unbaked = std.atomic.Value(bool).init(false);

/// Welcomes every item admitted since the last call. On the UI thread: the tick
/// calls it, so a name and a target are asked for as notifications arrive and
/// not only once the sheet is open.
pub fn welcomeInboxArrivals() void {
    if (!g_inbox_fresh.swap(false, .acq_rel)) return;
    lockInbox();
    defer unlockInbox();
    for (g_inbox[0..g_inbox_len]) |*item| {
        if (item.used and item.fresh) welcomeInboxItem(item);
    }
}

/// The UI thread's share of admitting an item: its author's name and the note
/// it is about, asked for once.
///
/// WHO it is from, because nothing else ever asked: the profile round fetches
/// kind:0 for the people the reader follows, the people a note mentions, and the
/// reader themself, and somebody who likes or zaps you is in none of those sets.
/// So the notifications page listed raw npubs for exactly the people it is
/// about, which is the one screen where a name is the entire content of the row.
/// And the note it is about, if this is the first we have heard of it: the row
/// is pressable, so the note behind it should be on its way before the reader
/// ever gets there.
fn welcomeInboxItem(item: *InboxItem) void {
    item.fresh = false;
    wantProfile(item.author);
    if (item.hasTarget() and !haveEvent(item.target_id)) wantQuote(item.target_id);
}

/// The reaction as sent. NIP-25 allows `+`, `-`, an empty string and a
/// `:shortcode:`; `+` and empty both mean a like, and the row draws its usual
/// heart for those rather than printing a plus sign.
fn bakeReactionGlyph(item: *InboxItem, ev: nostr.event.Event) void {
    const content = std.mem.trim(u8, ev.content, " \t\r\n");
    if (content.len > 0 and !std.mem.eql(u8, content, "+")) {
        item.glyph_len = fillClipped(&item.glyph_buf, content);
    }
}

/// The reader's own note, for the rows that are about one.
///
/// Usually a miss, and that is expected. What a notification points at is almost
/// always an older note of the reader's own, which the follow-scoped feed window
/// does not hold, so the line after this one asks the relays for it. That is why
/// the resolve below exists: baking once here and never looking again left every
/// reaction, repost and zap row with no note under it for good.
fn bakeTargetBody(item: *InboxItem, target: [32]u8) void {
    if (std.mem.allEqual(u8, &target, 0)) return;
    const store = main.g_store orelse return;
    var se = (store.getEvent(std.heap.page_allocator, target) catch return) orelse return;
    defer se.deinit();
    bakeBody(item, se.event);
}

/// Copies an event's words into the row, and its content warning with them.
pub fn bakeBody(item: *InboxItem, ev: nostr.event.Event) void {
    bakeInboxBody(item, ev.content);
    item.body_key = feedKeyOf(ev.id);
    item.warned = false;
    item.warning_len = 0;
    if (contentWarningOf(ev)) |reason| {
        item.warned = true;
        @memcpy(item.warning_buf[0..reason.len], reason);
        item.warning_len = @intCast(reason.len);
    }
}
/// The shortest bech32 run an event reference can be. A real `nevent1` carries a
/// 32 byte id and is far past this; the floor is only here so a bare word that
/// happens to begin `note1` is not taken for one.
const event_ref_min_len = 20;

/// Writes `src` into `dst` with every event reference replaced by `[Note]`, and
/// returns the length. `dst` must be at least as long as `src`: the label is
/// shorter than any token it replaces, so it never overflows.
///
/// Jumble's notification preview does the same (`[Note]` for an embedded event,
/// ContentPreview/Content.tsx:47-49). The feed draws a quote card for the first
/// one; a two line preview has no room for a card, and sixty characters of
/// bech32 are not something a reader can use.
pub fn collapseEventRefs(dst: []u8, src: []const u8) usize {
    const label = "[Note]";
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (isEventRefStart(src, i)) {
            var j = i;
            if (std.mem.startsWith(u8, src[j..], "nostr:")) j += "nostr:".len;
            const run_start = j;
            while (j < src.len and isBech32Char(src[j])) j += 1;
            if (j - run_start >= event_ref_min_len) {
                @memcpy(dst[out..][0..label.len], label);
                out += label.len;
                i = j;
                continue;
            }
        }
        dst[out] = src[i];
        out += 1;
        i += 1;
    }
    return out;
}
/// Fills a row's words from a note's content, the way a note is drawn rather
/// than the way it was typed.
///
/// A `nostr:npub1…` or `nostr:nprofile1…` in the text becomes the person's name,
/// from the profile cache, exactly as `noteFrom` does it for the feed. The row
/// used to copy the raw content and hand it to `contentSpans`, which only
/// STYLES a token it finds and never rewrites one, so the preview showed the
/// bech32 itself. The old comment on the row claimed otherwise, and nothing
/// tested it.
///
/// The words are rendered BEFORE they are clipped. Clipping first cuts a
/// seventy character token in half, and half a token is not a mention.
fn bakeInboxBody(item: *InboxItem, content: []const u8) void {
    var rendered: [note_content_cap]u8 = undefined;
    var mentions = MentionList{};
    const wrote = renderContentInto(&rendered, content, &.{}, &mentions);
    var collapsed: [note_content_cap]u8 = undefined;
    const kept = collapseEventRefs(&collapsed, rendered[0..wrote]);
    item.body_len = fillClipped(&item.body_buf, collapsed[0..kept]);
    item.names_pending = mentions.len > 0;
    item.names_generation = profile_cache.g_names_generation;
    item.mentions = .{};
    // The offsets recorded while rendering describe the text BEFORE whitespace
    // was folded, event references were shortened and the end was clipped, so
    // they are found again in the words that were kept. Each label is a literal
    // run of the text, and they come in the order they were written. One that
    // was clipped away, or whose spacing was folded, is simply not marked.
    const body = item.body();
    var from: usize = 0;
    for (mentions.all()) |ref| {
        const label = rendered[ref.off..][0..ref.len];
        const at = std.mem.indexOfPos(u8, body, from, label) orelse continue;
        item.mentions.refs[item.mentions.len] = ref;
        item.mentions.refs[item.mentions.len].off = @intCast(at);
        item.mentions.len += 1;
        from = at + label.len;
    }
}

/// The rows the notifications window last put on screen. Written by the view,
/// read by the pass that lends avatar ids on the next tick.
pub var g_inbox_visible: struct { first: usize = 0, last: usize = 0, len: usize = 0 } = .{};

/// The store generation the inbox last tried to fill its missing bodies at.
pub var g_inbox_body_stamp: usize = std.math.maxInt(usize);
/// The names generation the rows were last baked under, so a name arriving
/// reaches a row that already names somebody.
pub var g_inbox_body_names: u64 = std.math.maxInt(u64);

/// Fills in the note behind every row that is still missing one.
///
/// Guarded on the store's event count, so this is one pass per arrival rather
/// than a query per row per frame. The feed already paid for the other version:
/// asking the database once per card cost 24423us to rebuild, three whole frames
/// to draw one.
///
/// A row whose note never arrives keeps an empty body and still says who did
/// what, which is what it did before any of this.
pub fn resolveInboxBodies() void {
    welcomeInboxArrivals();
    const store = main.g_store orelse return;
    const stamp = store.eventCount() catch return;
    const fresh = g_inbox_unbaked.swap(false, .acq_rel);
    if (!fresh and stamp == g_inbox_body_stamp and profile_cache.g_names_generation == g_inbox_body_names) return;
    g_inbox_body_stamp = stamp;
    g_inbox_body_names = profile_cache.g_names_generation;
    lockInbox();
    defer unlockInbox();
    for (g_inbox[0..g_inbox_len]) |*item| {
        if (!item.used) continue;
        // A row that names somebody is baked again when a name has landed since,
        // which is the only thing that can change what it should say. The same
        // rule the quote cache follows, and it keeps the cost to the rows that
        // have a mention in them.
        const stale = item.body_len > 0 and item.names_pending and item.names_generation != profile_cache.g_names_generation;
        if (item.body_len > 0 and !stale) continue;
        // A reply or a mention IS the event, so its own id holds their words.
        // Skipping these was wrong: `inboxAdd` copies the content as the event
        // arrives, but `loadInbox` rebuilds the inbox from the store at launch
        // and never goes near that path, so every reply restored from a previous
        // session drew a name, a time, and nothing in between.
        const from: [32]u8 = if (item.verb == .reply or item.verb == .mention) item.id else item.target_id;
        bakeTargetBody(item, from);
    }
}
/// Asks for the metadata of everyone the inbox names.
///
/// `inboxAdd` already does this for an event as it arrives, and that is not
/// enough: `loadInbox` rebuilds the whole inbox from the store on launch without
/// going near that path, so every notification from a previous session had
/// nobody asking for its author's name. Those rows showed a raw npub and an
/// initial for as long as the app ran, which is exactly the screen where a name
/// IS the content.
///
/// Cheap to repeat. `wantProfile` returns immediately for anyone already named
/// and never queues a duplicate.
pub fn wantInboxProfiles(shown: []const InboxItem) void {
    // Only the rows on screen, and this is the third time the same rule has had
    // to be learned on this page. The wanted table holds 48 and evicts to make
    // room, so asking on behalf of 143 notifications thrashed it: the names that
    // actually arrived were whichever ones happened to survive the churn, which
    // is why opening somebody's profile and coming back was what finally loaded
    // them. Visiting the profile asked for one person instead of a hundred.
    const first = @min(g_inbox_visible.first, shown.len);
    const last = @min(g_inbox_visible.last + 1, shown.len);
    if (last <= first) return;
    for (shown[first..last]) |item| wantProfile(item.author);
}

/// Whether the store already holds this event.
fn haveEvent(id: [32]u8) bool {
    const store = main.g_store orelse return false;
    var se = (store.getEvent(std.heap.page_allocator, id) catch return false) orelse return false;
    se.deinit();
    return true;
}

/// Finds this item a slot, or refuses it. Returns whether it was filed.
///
/// The array is a fixed two hundred, so every arrival past that is a CHOICE about
/// what to delete, and the version this shipped with made that choice before it
/// had looked at the arrival: it shifted every slot down (dropping the oldest),
/// wrote the newcomer at the front, and only then sorted. So a backfilled item
/// from last year displaced an unread reply from this morning, and a stranger who
/// signed two hundred events deleted the reader's whole history of being spoken
/// to. Both are decided here instead, against the item actually arriving.
fn inboxAdmitLocked(item: InboxItem) bool {
    // No one author may own more than their share, however many they send.
    var by_author: usize = 0;
    var oldest_same: ?usize = null;
    for (g_inbox[0..g_inbox_len], 0..) |it, i| {
        if (!std.mem.eql(u8, &it.author, &item.author)) continue;
        by_author += 1;
        if (oldest_same == null or it.created_at < g_inbox[oldest_same.?].created_at) oldest_same = i;
    }
    if (by_author >= inbox_per_author_max) {
        const victim = oldest_same orelse return false;
        // Their own oldest, and only if this one is newer: a flood cannot walk
        // its way through the reader's history one slot at a time either.
        if (g_inbox[victim].created_at >= item.created_at) return false;
        inboxRemoveLocked(victim);
    }

    if (g_inbox_len >= g_inbox.len) {
        const victim = inboxEvictionCandidateLocked() orelse return false;
        const victim_is_stranger = !isInReadGraph(g_inbox[victim].author);
        const mine = isInReadGraph(item.author);
        // Someone the reader follows always outranks someone they do not.
        // Otherwise the newer of the two wins, so nothing already held is ever
        // traded away for something older than it.
        if (!(mine and victim_is_stranger) and g_inbox[victim].created_at >= item.created_at) return false;
        inboxRemoveLocked(victim);
    }

    g_inbox[g_inbox_len] = item;
    g_inbox_len += 1;
    // Newest first, whatever order the relays delivered in.
    sortInboxLocked();
    return true;
}

/// Who is dropped when the inbox is full: the oldest STRANGER, and only when
/// there is no stranger left, the oldest item at all.
///
/// A flood is cheap to send and always arrives from someone the reader has never
/// followed. Spending the reader's last slots on people they chose, rather than
/// on whoever signed most recently, is the difference between an inbox that
/// degrades and one that can be erased on demand.
///
/// Takes the follows lock while the inbox lock is held. That is the same order
/// `inboxItems` already uses, and nothing anywhere takes them the other way
/// round.
fn inboxEvictionCandidateLocked() ?usize {
    var oldest_stranger: ?usize = null;
    var oldest: ?usize = null;
    for (g_inbox[0..g_inbox_len], 0..) |it, i| {
        if (oldest == null or it.created_at < g_inbox[oldest.?].created_at) oldest = i;
        if (isInReadGraph(it.author)) continue;
        if (oldest_stranger == null or it.created_at < g_inbox[oldest_stranger.?].created_at) oldest_stranger = i;
    }
    return oldest_stranger orelse oldest;
}

fn inboxRemoveLocked(index: usize) void {
    if (index >= g_inbox_len) return;
    var i = index;
    while (i + 1 < g_inbox_len) : (i += 1) g_inbox[i] = g_inbox[i + 1];
    g_inbox_len -= 1;
    g_inbox[g_inbox_len] = .{};
}

pub fn resetInboxLocked(owner: [32]u8) void {
    g_inbox_len = 0;
    g_inbox_owner = owner;
    g_inbox_read_through = 0;
}

fn sortInboxLocked() void {
    const Cmp = struct {
        fn lt(_: void, a: InboxItem, b: InboxItem) bool {
            return a.created_at > b.created_at;
        }
    };
    std.mem.sort(InboxItem, g_inbox[0..g_inbox_len], {}, Cmp.lt);
}

/// Who actually sent a zap, established rather than taken on trust.
///
/// The RECEIPT is authored by a payment server, so its pubkey is not the person:
/// the payer is named inside the embedded zap request. That request arrives as a
/// STRING inside a stranger's tag, and parsing a string does not make its claims
/// true. Reading `pubkey` straight out of it, which is the obvious implementation
/// and the one this shipped with, lets anyone in the world publish a receipt whose
/// embedded request names someone the reader follows: the row then draws that
/// person's real cached name and avatar next to an amount the same stranger chose.
/// A trusted face saying "I sent you money" is the most valuable lie this surface
/// can carry, so it is the one that has to be paid for.
///
/// Three checks, all local and all cheap:
///   the embedded event must be a zap REQUEST (kind 9734), not any event at all,
///   its signature must verify, so the named payer really did sign it, and
///   it must name the reader, so a request signed for somebody else cannot be
///   lifted out of their receipt and replayed into this inbox.
///
/// What this still does NOT prove is that money moved: the full NIP-57 check
/// wants the receipt to come from the recipient's own LNURL server, which means
/// fetching and remembering that server's key. Until then an attacker can invent
/// a zap under THEIR OWN name and any amount they like, which is a stranger
/// talking to the reader rather than a friend impersonated, and is the same
/// weight as any other message from a stranger.
/// What a zap receipt can actually be shown to say.
///
/// Everything here comes from the SIGNED request, never from the receipt around
/// it, and that distinction is the whole of it.
const ZapClaim = struct {
    /// The request's own id. This is the item's identity, so the same payment
    /// cannot appear twice however many receipts carry it.
    id: [32]u8,
    payer: [32]u8,
    msat: u64,
    created_at: i64,
};

fn zapClaim(ev: nostr.event.Event, me: [32]u8) ?ZapClaim {
    for (ev.tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "description")) continue;
        const gpa = std.heap.page_allocator;
        var parsed = nostr.event.fromJson(gpa, tag[1]) catch return null;
        defer parsed.deinit();
        const req = parsed.value;
        if (req.kind != 9734) return null;

        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        if (!(nostr.event.verify(gpa, signer, req) catch false)) return null;

        // Signed by the payer, but for whom? A receipt is public, so a request
        // naming somebody else can be copied verbatim into a receipt aimed here.
        var hex: [64]u8 = undefined;
        hexLower(&hex, me);
        var names_me = false;
        for (req.tags) |t| {
            if (t.len < 2 or !std.mem.eql(u8, t[0], "p")) continue;
            if (std.ascii.eqlIgnoreCase(t[1], &hex)) names_me = true;
        }
        if (!names_me) return null;
        // Your own zap of your own note is not news, and the gate above cannot
        // catch it: the request names the reader because the reader is the
        // recipient.
        if (std.mem.eql(u8, &req.pubkey, &me)) return null;

        // NIP-57 puts the amount INSIDE the request, where the payer signed it.
        // The receipt's `bolt11` is written by whoever wrote the receipt, so
        // reading the number from there is how a verified name ends up beside an
        // invented figure.
        var msat: u64 = 0;
        for (req.tags) |t| {
            if (t.len < 2 or !std.mem.eql(u8, t[0], "amount")) continue;
            msat = std.fmt.parseInt(u64, t[1], 10) catch 0;
        }
        if (msat > inbox_max_claimable_msat) msat = 0;

        return .{
            .id = req.id,
            .payer = req.pubkey,
            .msat = msat,
            .created_at = req.created_at,
        };
    }
    return null;
}

/// How many items the reader has not seen.
///
/// Replies and mentions only: somebody writing TO the reader is worth a number
/// on a tile, and a like is worth reading without being summoned to. So the bell
/// deliberately counts FEWER things than the sheet lists, never more. That
/// direction matters: a badge that counts things the sheet then declines to show
/// sends the reader to an empty list and teaches them to distrust it, which is
/// exactly what the follows-only default used to do to every stranger's reply.
pub fn inboxUnread() usize {
    lockInbox();
    defer unlockInbox();
    if (!inboxIsOwnedLocked()) return 0;
    var n: usize = 0;
    for (g_inbox[0..g_inbox_len]) |item| {
        // The bell speaks for the things addressed to them personally. A like
        // is worth reading and is not worth a number on a tile.
        if (item.verb != .reply and item.verb != .mention) continue;
        if (item.created_at > g_inbox_read_through) n += 1;
    }
    return n;
}

fn inboxIsOwnedLocked() bool {
    const me = activePubkey() orelse return false;
    const owner = g_inbox_owner orelse return false;
    return std.mem.eql(u8, &owner, &me);
}

/// Marks everything currently in the inbox as seen.
///
/// The mark is the newest stamp actually HELD, never the wall clock. Marking at
/// now() means anything that arrives later carrying an older stamp, which is
/// every backfill and every slow relay, is born already read and never counted.
pub fn inboxMarkAllRead() void {
    lockInbox();
    defer unlockInbox();
    if (!inboxIsOwnedLocked()) return;
    for (g_inbox[0..g_inbox_len]) |item| {
        if (item.created_at > g_inbox_read_through) g_inbox_read_through = item.created_at;
    }
    g_inbox_dirty = true;
}

/// How many pages the sheet has for this tab. The reader's page index is kept
/// inside it, because the set underneath moves on its own: a fresh contact list
/// narrows the follows tab, and an eviction shortens both.
pub fn inboxPageCount(only_follows: bool) usize {
    var buf: [inbox_cap]InboxItem = undefined;
    const shown = inboxItems(&buf, only_follows);
    if (shown.len == 0) return 1;
    return (shown.len + inbox_page - 1) / inbox_page;
}

/// The items to draw, newest first, filtered to a tab.
pub fn inboxItems(out: []InboxItem, only_follows: bool) []const InboxItem {
    lockInbox();
    defer unlockInbox();
    if (!inboxIsOwnedLocked()) return out[0..0];
    var n: usize = 0;
    for (g_inbox[0..g_inbox_len]) |item| {
        if (n >= out.len) break;
        if (only_follows and !isInReadGraph(item.author)) continue;
        out[n] = item;
        n += 1;
    }
    return out[0..n];
}

pub fn inboxReadThrough() i64 {
    lockInbox();
    defer unlockInbox();
    return g_inbox_read_through;
}

/// The newest stamp held, which is where a backfill resumes from.
pub fn inboxNewest() i64 {
    lockInbox();
    defer unlockInbox();
    if (!inboxIsOwnedLocked() or g_inbox_len == 0) return 0;
    return g_inbox[0].created_at;
}

/// Asks this relay for what other people aimed at the reader, or stops asking.
///
/// Called at dial AND whenever the identity changes, because a connection lives
/// as long as the relay keeps it alive: on a healthy socket there is no reconnect
/// to heal a subscription that was never opened.
pub fn subscribeInbox(relay: anytype) void {
    const me = activePubkey() orelse {
        // Signed out. The filter names a person who is no longer here, so it is
        // withdrawn rather than left running: a relay should stop being told
        // which pubkey this connection cares about the moment it stops being
        // true.
        relay.unsubscribe("plaza-inbox") catch {};
        return;
    };
    const hex = inboxMeHex(me);
    const inbox_tags = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &.{&hex} }};
    const since = inboxSince();
    const inbox_filters = [_]nostr.filter.Filter{.{
        .kinds = &inbox_kinds,
        .tags = &inbox_tags,
        .limit = inbox_backfill_cap,
        .since = if (since > 0) since else null,
    }};
    relay.subscribe("plaza-inbox", &inbox_filters) catch {};
}

/// The reader's own pubkey as hex, for a filter that names them.
fn inboxMeHex(me: [32]u8) [64]u8 {
    var hex: [64]u8 = undefined;
    hexLower(&hex, me);
    return hex;
}

/// How far back a fresh subscription asks.
///
/// The newest item held, minus an overlap: asking for exactly the newest stamp
/// re-fetches that one event and, worse, a relay whose clock differs by a second
/// silently drops everything in the gap. With nothing held, no `since` at all
/// and the limit does the bounding, which is what relays are good at.
const inbox_backfill_cap: u32 = 200;
const inbox_since_overlap_s: i64 = 60 * 60;

fn inboxSince() i64 {
    const newest = inboxNewest();
    if (newest == 0) return 0;
    return @max(0, newest - inbox_since_overlap_s);
}

/// Marks the index changed, so the tick writes it once rather than every relay
/// writing it on every event.
pub fn markInboxDirty() void {
    lockInbox();
    defer unlockInbox();
    g_inbox_dirty = true;
}

pub fn inboxNeedsSave() bool {
    lockInbox();
    defer unlockInbox();
    return g_inbox_dirty;
}

/// Where the inbox index and the read mark live. Per account, because one
/// reader's notifications are not another's and a shared key is how account
/// switching corrupts unread state. One rewritten key, because the KV has no
/// cursor, no prefix scan and no delete.
fn inboxKey(buf: *[96]u8, pubkey: [32]u8) []const u8 {
    var hex: [64]u8 = undefined;
    hexLower(&hex, pubkey);
    return std.fmt.bufPrint(buf, "inbox/{s}", .{hex[0..]}) catch buf[0..0];
}

/// Writes the index. The events themselves are already in the store's event
/// tables, so this holds only what cannot be recomputed: which ids matter, what
/// each one was, and how far the reader has read.
pub fn saveInbox() void {
    const store = main.g_store orelse return;
    const me = activePubkey() orelse return;
    var key_buf: [96]u8 = undefined;
    const key = inboxKey(&key_buf, me);
    if (key.len == 0) return;

    const gpa = std.heap.page_allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);

    lockInbox();
    if (!inboxIsOwnedLocked()) {
        unlockInbox();
        return;
    }
    out.print(gpa, "read {d}\n", .{g_inbox_read_through}) catch {
        unlockInbox();
        return;
    };
    // Only the read marker. The items themselves are NOT serialised here any
    // more: the events are already in the store, indexed by their `p` tag, and
    // writing a second parallel copy of them was both duplication and a bug.
    // The blob carried the id, author, stamp, target, verb and msat, and nothing
    // else, so a restored row had no words and no reaction glyph, which is
    // exactly the "some rows have no content" report. Rebuilding from the store
    // replays the real events through the real gate and cannot drift from it.
    g_inbox_dirty = false;
    unlockInbox();
    // Outside the lock: an LMDB write must never be held under a spinlock that
    // ingest threads are waiting on.
    store.put(key, out.items) catch {};
}

/// Reads the index back at sign-in.
pub fn loadInbox() void {
    const store = main.g_store orelse return;
    const me = activePubkey() orelse return;
    const gpa = std.heap.page_allocator;

    lockInbox();
    resetInboxLocked(me);
    unlockInbox();

    // AFTER the reset, which clears it. Reading the marker first and resetting
    // second put the whole inbox back at unread on every launch.
    var key_buf: [96]u8 = undefined;
    const key = inboxKey(&key_buf, me);
    if (key.len > 0) {
        if (store.get(gpa, key) catch null) |raw| {
            defer gpa.free(raw);
            var lines = std.mem.tokenizeScalar(u8, raw, '\n');
            while (lines.next()) |line| {
                var parts = std.mem.tokenizeScalar(u8, line, ' ');
                const first = parts.next() orelse continue;
                if (!std.mem.eql(u8, first, "read")) continue;
                const v = parts.next() orelse continue;
                g_inbox_read_through = std.fmt.parseInt(i64, v, 10) catch 0;
            }
        }
    }

    // The same filter the relay is asked, answered from disk. Jumble does
    // exactly this: it paints the notification list from IndexedDB using the
    // identical filter it is about to send, before opening a socket.
    //
    // Replayed through `inboxAdd`, so restored rows pass the same gate, the same
    // dedup and the same text baking as live ones. The hand-rolled blob this
    // replaces could not: it held six scalar fields and no content, so every row
    // restored from a previous session came back with a name, a time, and
    // nothing in between.
    const hex = inboxMeHex(me);
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &.{&hex} }};
    var result = store.query(gpa, .{
        .kinds = &inbox_kinds,
        .tags = &tags,
        .limit = inbox_backfill_cap,
    }) catch return;
    defer result.deinit();
    const now = nowSeconds();
    for (result.events) |ev| _ = inboxAdd(ev, now);
}
/// Drops the leaving account's notifications. Another reader must never open
/// this app and find somebody else's mail.
pub fn resetInbox() void {
    lockInbox();
    defer unlockInbox();
    g_inbox_len = 0;
    g_inbox_owner = null;
    g_inbox_read_through = 0;
    g_inbox_dirty = false;
}

pub fn bakeBodyForTest(item: *InboxItem, ev: nostr.event.Event) void {
    bakeBody(item, ev);
}
pub fn collapseEventRefsForTest(dst: []u8, src: []const u8) usize {
    return collapseEventRefs(dst, src);
}

pub fn welcomeInboxArrivalsForTest() void {
    welcomeInboxArrivals();
}

pub fn resolveInboxBodiesForTest() void {
    resolveInboxBodies();
}

/// Forgets what the last pass saw, so a test with a store of its own is not
/// skipped because an earlier test left the same event count behind.
pub fn forgetInboxBodyStampForTest() void {
    g_inbox_body_stamp = std.math.maxInt(usize);
    g_inbox_body_names = std.math.maxInt(u64);
}
pub fn saveInboxForTest() void {
    saveInbox();
}

pub fn loadInboxForTest() void {
    loadInbox();
}

pub fn inboxAddForTest(ev: nostr.event.Event, now_s: i64) bool {
    return inboxAdd(ev, now_s);
}

pub fn inboxVerbForTest(ev: nostr.event.Event, me: [32]u8) ?InboxVerb {
    return inboxVerbFor(ev, me);
}
/// Files `count` unread notifications, so a view test can ask what the rail's
/// badge does with a number without standing up relays.
pub fn seedInboxUnreadForTest(count: usize) void {
    const me = activePubkey() orelse return;
    lockInbox();
    defer unlockInbox();
    resetInboxLocked(me);
    var i: usize = 0;
    while (i < count and g_inbox_len < g_inbox.len) : (i += 1) {
        var id: [32]u8 = [_]u8{0} ** 32;
        id[0] = @intCast(i % 251 + 1);
        g_inbox[g_inbox_len] = .{
            .used = true,
            .id = id,
            .author = id,
            .target_id = [_]u8{0} ** 32,
            .created_at = 1_800_000_000,
            .verb = .reply,
            .msat = 0,
        };
        g_inbox_len += 1;
    }
}
pub fn resetInboxForTest() void {
    lockInbox();
    defer unlockInbox();
    g_inbox_len = 0;
    g_inbox_owner = null;
    g_inbox_read_through = 0;
}

pub fn inboxLenForTest() usize {
    lockInbox();
    defer unlockInbox();
    return g_inbox_len;
}

//! Writing: compose and reply, post timing, tags, content warnings, reactions, reposts and deletes.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const keyholder = @import("keyholder.zig");
const own_lists = @import("own_lists.zig");
const prefs = @import("prefs.zig");
const session = @import("session.zig");
const blossom = @import("blossom.zig");
const outbox = @import("outbox.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const noteOwnWriteUnstored = main.noteOwnWriteUnstored;
const noteOwnWriteUnstoredOffThread = main.noteOwnWriteUnstoredOffThread;
const notePrivateBookmarkPublished = main.notePrivateBookmarkPublished;
const postWaitsForPicture = main.postWaitsForPicture;
const AppUi = main.AppUi;
const Effects = main.Effects;
const HintList = main.HintList;
const Model = main.Model;
const Note = main.Note;
const PendingUndo = main.PendingUndo;
const PlaceRoute = main.PlaceRoute;
const UrlList = main.UrlList;
const activePubkey = main.activePubkey;
const armUndo = main.armUndo;
const askFreshFirst = main.askFreshFirst;
const canWriteFollows = main.canWriteFollows;
const client_tag_name = main.client_tag_name;
const closeThread = main.closeThread;
const engagementFor = main.engagementFor;
const engagementLock = main.engagementLock;
const engagementUnlock = main.engagementUnlock;
const enqueueOutbox = main.enqueueOutbox;
const ensureEngagement = main.ensureEngagement;
const forgetLike = main.forgetLike;
const hintOrEmpty = main.hintOrEmpty;
const hintsFor = main.hintsFor;
const isBech32Char = main.isBech32Char;
const isHashtagChar = main.isHashtagChar;
const isLiked = main.isLiked;
const isReaderNote = main.isReaderNote;
const looksLikeImageUrl = main.looksLikeImageUrl;
const noListToast = main.noListToast;
const nowSeconds = main.nowSeconds;
const openEvent = main.openEvent;
const outboxEntryFor = main.outboxEntryFor;
const outboxHasRoom = main.outboxHasRoom;
const outboxLock = main.outboxLock;
const outboxUnlock = main.outboxUnlock;
const pTagFor = main.pTagFor;
const parseMentionAt = main.parseMentionAt;
const plazaIngest = main.plazaIngest;
const publishEvent = main.publishEvent;
const refPrecededByBoundary = main.refPrecededByBoundary;
const rememberLike = main.rememberLike;
const requestHelperSign = main.requestHelperSign;
const requestRemoteSign = main.requestRemoteSign;
const routeForOpenPlace = main.routeForOpenPlace;
const saveDraft = main.saveDraft;
const sayFollowWrite = main.sayFollowWrite;
const setToast = main.setToast;
const signerReady = main.signerReady;
const uploadedImeta = main.uploadedImeta;
const uploadedPictureFor = main.uploadedPictureFor;
const writeFollow = main.writeFollow;

// -------------------------------------------------------------- compose & post
//
// Posting is local-first: a composed note is signed, written to the local store
// straight away (so it shows in the feed on the next tick), and published to the
// pool on a detached thread. The feed dedupes by event id, so when a relay later
// echoes our own note back through the ingest subscriptions it collapses onto
// the local copy.

/// Posts the current draft: sign a kind:1 note, store it locally at once, and
/// publish it to the pool in the background. A blank draft or a not-yet-ready
/// identity is a no-op.
/// Signs and publishes what is in the composer, and everything that follows a
/// note actually leaving.
///
/// Its own function because there are two ways in now: the press, when the
/// pause is off, and the clock, when it is on. Leaving this inline under the
/// press meant a held note that finally went would clear no draft, close no
/// sheet and say nothing.
/// The room a held note was written in, captured when the reader pressed Post
/// rather than when the pause runs out. That gap is the whole feature: the
/// reader is free to walk somewhere else while it counts, and the note still
/// belongs where it was written.
pub var g_held_route: PlaceRoute = .none;

/// What a press is told when the signer cannot take it now. Any signer: Notary
/// with a sign out, or a bunker with every request slot taken.
pub const signer_busy_toast = "Your signer is busy for a moment. Try again.";
comptime {
    std.debug.assert(signer_busy_toast.len <= 48);
}

pub fn firePost(model: *Model, fx: *Effects, route: ?PlaceRoute) bool {
    g_post_due_s = 0;
    // A picture chosen during the pause is on its way into this note. The
    // note stays in the composer and the card says why.
    if (postWaitsForPicture()) return false;
    // Nothing below runs unless the note actually went to a signer. It used to
    // run regardless: the composer emptied, the draft file was deleted and the
    // toast said "Posted" for a sign that had been refused before it left the
    // process.
    if (!submitPost(model, fx, route)) {
        setToast(model, if (!outboxHasRoom())
            "Still sending your last notes. This one is kept."
        else
            signer_busy_toast);
        return false;
    }
    // The slot is emptied the moment its contents go to a signer. Leaving it
    // would restore an already-published note into the next launch's composer,
    // one keystroke from being posted twice.
    saveDraft("", null);
    // Posting closes the sheet; the note is already local and will appear on the
    // next tick.
    model.composing = false;
    setToast(model, if (keyholder.g_signer_kind == .remote) "Sent to your signer" else "Posted");
    // The first post is the calm moment to suggest a backup, and the backup
    // lives in Notary now: this app has nothing to back up.
    if (own_lists.g_identity_minted_here and !model.backup_nudge_dismissed)
        model.backup_nudge = true;
    return true;
}

/// How long a note waits in the composer before it is signed, in seconds.
///
/// Zero is off and is not the default. The point of the pause is the one thing
/// nostr cannot give back: once a note is signed and out, a kind:5 is a REQUEST.
/// A relay may ignore it and everyone already holding the event keeps it. So an
/// "undo" that runs after publishing would be a button that cannot do what it
/// says, and this waits on the near side of the signature instead, where taking
/// it back means nothing ever existed.
///
/// The composer stays open and editable while it counts. That is the point
/// rather than a side effect: what this is for is catching the typo you see the
/// instant after you press the button.
///
/// Off by default. Turning it on for everybody would make a note that suddenly
/// does not post read as a fault before it reads as a safeguard, and nobody
/// asked for their existing habit to change. The cost is honest: a pause nobody
/// finds helps nobody, so it sits in Settings where it can be found.
pub var g_post_delay_s: i64 = 0;

/// When the held note is due, or 0 when nothing is held.
pub var g_post_due_s: i64 = 0;

/// And the same for a reply, on its own clock.
///
/// Separate rather than shared because the two surfaces are independent: the
/// composer is a sheet, a reply belongs to a thread, and one held while the
/// other is armed must not cancel or fire it. `postIsDue` and `postSecondsLeft`
/// take the clock as an argument precisely so both can use them.
pub var g_reply_due_s: i64 = 0;
/// Whether a held note is due to be signed now.
///
/// A function of its inputs, so a test can say what it must decide without
/// waiting five seconds for it.
pub fn postIsDue(due_s: i64, now_s: i64) bool {
    if (due_s == 0) return false;
    return now_s >= due_s;
}

/// Seconds still on the clock, for the button. Never negative, and never zero
/// while something is held: a button reading "Undo 0" has already gone.
pub fn postSecondsLeft(due_s: i64, now_s: i64) i64 {
    if (due_s == 0) return 0;
    const left = due_s - now_s;
    return if (left < 1) 1 else left;
}

pub fn submitPost(model: *Model, fx: *Effects, route: ?PlaceRoute) bool {
    const text = std.mem.trim(u8, model.draft_buffer.text(), " \t\r\n");
    if (text.len == 0) return false;
    // The composer is cleared and the draft file deleted right after this
    // returns, so a sign that never went out has to be reported rather than
    // assumed. The one shape that reaches here is a relay-list flush on the same
    // tick, which the SDK would reject and nothing would notice.
    if (!signerReady()) return false;
    // And a queue with room to track it. Refusing here keeps the note in the
    // composer; refusing after the sign, which is where it used to happen,
    // dropped it with no row, no retry and no way back.
    if (!outboxHasRoom()) return false;
    const gpa = std.heap.page_allocator;

    // A process-lifetime copy of the content: `event.create` references its
    // content slice rather than copying it, and the store write and either the
    // publisher or the NIP-46 round-trip read it after the draft is cleared.
    // Canonicalised BEFORE the copy, so the published content and the imeta tag
    // built from it name the same URL. NIP-92 pairs a tag with a URL in the
    // content, and a tag pointing at a string that is not there is one a reader
    // is entitled to ignore.
    const canonical = canonicalMediaUrls(gpa, text);
    const owned = gpa.dupe(u8, canonical) catch return false;
    // Read off `owned`, not off the draft buffer: that is cleared two lines
    // below, and the tags hold slices of whatever they were built from.
    const base_tags = contentTags(gpa, owned, &.{}, model.mentionsOff());
    // The reader's content warning, when they set one. It travels in the tag set,
    // and the signer's pending slot reads it back out of those same tags, so a
    // sign that never comes back hands the words to the composer together with
    // the warning they were signed under. Control characters become spaces: the
    // reason field is a textarea, and a newline in a tag a reader draws on one
    // line would show them a bare warning.
    var reason_buf: [warning_input_capacity]u8 = undefined;
    const warning: ?[]const u8 = if (model.warn_on) singleLine(&reason_buf, model.warn_buffer.text()) else null;
    // Refused, not published without: a note the author asked to have covered
    // must not go out uncovered because an allocation failed.
    const tags = withContentWarning(gpa, base_tags, warning) orelse {
        gpa.free(owned);
        return false;
    };
    // A composer draft: kind:1 carrying whatever its own text implies,
    // restorable to the composer if a remote signer never answers.
    // `.none` on purpose: this is the one write that IS `restorable`, so the
    // draft it came from is what gets handed back.
    signAndPublish(fx, gpa, nowSeconds(), 1, tags, owned, true, .none, route);
    model.draft_buffer.clear();
    model.draft_dropped = 0;
    model.warn_on = false;
    model.warn_buffer.clear();
    return true;
}

/// `text` trimmed, with each control character (a newline from the textarea, a
/// tab) turned into a space, written into `out`. Interior only: the ends are
/// trimmed first.
fn singleLine(out: []u8, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const n = @min(trimmed.len, out.len);
    for (trimmed[0..n], 0..) |c, i| out[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
    return std.mem.trim(u8, out[0..n], " ");
}

/// The content warning a composer post was signed with, kept in the pending sign
/// that carries the post (the bunker's slot or the built-in signer's), so the
/// post that comes back is restored with its own warning. One global for this
/// held whichever post was submitted last: with several signs out, a timed-out
/// one came back with another post's warning, or none.
pub const WarnCarry = struct {
    on: bool = false,
    len: u8 = 0,
    buf: [warning_input_capacity]u8 = [_]u8{0} ** warning_input_capacity,

    /// Reads the warning off the tag set the post is being signed with.
    pub fn fromTags(tags: []const nostr.event.Tag) WarnCarry {
        for (tags) |tag| {
            if (tag.len < 1 or !std.mem.eql(u8, tag[0], "content-warning")) continue;
            var out = WarnCarry{ .on = true };
            const reason = if (tag.len > 1) tag[1] else "";
            const n = @min(reason.len, out.buf.len);
            @memcpy(out.buf[0..n], reason[0..n]);
            out.len = @intCast(n);
            return out;
        }
        return .{};
    }

    /// Puts the warning back in the composer beside the draft it belonged to.
    pub fn restoreInto(self: WarnCarry, model: *Model) void {
        if (!self.on) return;
        model.warn_on = true;
        model.warn_buffer.set(self.buf[0..self.len]);
    }
};

/// Appends NIP-36's `content-warning` tag when the reader set one. The reason is
/// copied: the tags outlive the composer's buffer, like the content they sit with.
/// An empty reason is still a tag, because the tag is what covers the note.
/// Returns null when the tag could not be built: the caller refuses the post.
pub fn withContentWarning(gpa: std.mem.Allocator, tags: []const nostr.event.Tag, reason: ?[]const u8) ?[]const nostr.event.Tag {
    const text = reason orelse return tags;
    const owned = gpa.dupe(u8, text) catch return null;
    const tag = gpa.dupe([]const u8, &.{ "content-warning", owned }) catch {
        gpa.free(owned);
        return null;
    };
    const out = gpa.alloc(nostr.event.Tag, tags.len + 1) catch {
        gpa.free(tag);
        gpa.free(owned);
        return null;
    };
    @memcpy(out[0..tags.len], tags);
    out[tags.len] = tag;
    return out;
}

/// Signs `content_owned` as an event of `kind` with `tags`, stamped `created`,
/// through whichever signer is active, then stores and publishes it. Takes
/// ownership of `content_owned` and `tags` (process-lifetime: the local and
/// remote paths reference them after this returns, and the write seam intends
/// them to outlive the detached publish). `restorable` marks a composer draft,
/// so only a lost post is put back in the composer, never a reaction.
pub fn signAndPublish(fx: *Effects, gpa: std.mem.Allocator, created: i64, kind: u16, tags_in: []const nostr.event.Tag, content_owned: []const u8, restorable: bool, undo: PendingUndo, route_in: ?PlaceRoute) void {
    // What to take back if this signature never arrives, taken as an ARGUMENT
    // rather than armed by the caller beforehand.
    //
    // Every write in this app moved the screen before it signed and none of
    // them put it back, and the reason the whole class existed is that arming
    // was a separate step a caller could simply not do. A parameter cannot be
    // forgotten: a new write does not compile until it has said what its undo
    // is, and `.none` is a decision spelled out loud rather than an omission.
    //
    // It rides the signer's request together with the event it waits on, so a
    // failure puts back this press and no other, and a signature releases this
    // record and no other.
    //
    // Here, rather than at each call site, because this is the ONE door every
    // published event goes through: a switch the reader turned on has to hold for
    // the note they write, the note they repost and the note they quote, and a
    // per-caller version of it is a switch that holds for whichever paths someone
    // remembered.
    const tags = withClientTag(gpa, kind, tags_in);
    // The finished tag set, recorded where a test can read it. A parser that is
    // correct and never called is the regression worth guarding against here,
    // and every other seam in this file stops short of the event itself.
    keyholder.g_last_published_tags = tags;
    // Decided HERE, on the UI thread, at the moment the reader asked, and then
    // carried. Every path past this point runs later and somewhere else: a
    // signer that asks a person, a queue that retries, a detached publish
    // thread. `null` means "whatever room is open right now", which is the
    // answer for every write that is submitted the instant it is pressed; a
    // note held for the undo pause passes the room it was WRITTEN in, because
    // by the time it fires the reader may be standing somewhere else.
    const route = route_in orelse routeForOpenPlace();
    switch (keyholder.g_signer_kind) {
        .remote => requestRemoteSign(gpa, created, kind, tags, content_owned, restorable, route, undo),
        .helper => requestHelperSign(fx, gpa, created, kind, tags, content_owned, restorable, route, undo),
    }
}

/// Appends NIP-89's `client` tag when the reader has asked for it.
///
/// Only to the kinds that ARE the reader's writing. A reaction, a deletion and a
/// contact list are machinery; stamping those would broadcast the same fact more
/// widely for no reader-visible benefit, which is the opposite of what an opt-in
/// privacy switch is for.
pub fn withClientTag(gpa: std.mem.Allocator, kind: u16, tags: []const nostr.event.Tag) []const nostr.event.Tag {
    if (!prefs.g_client_tag) return tags;
    if (kind != 1 and kind != 6) return tags;
    const tag = gpa.dupe([]const u8, &.{ "client", client_tag_name }) catch return tags;
    const out = gpa.alloc(nostr.event.Tag, tags.len + 1) catch return tags;
    @memcpy(out[0..tags.len], tags);
    out[tags.len] = tag;
    return out;
}

/// The time, and what the note was written with when it says so.
///
/// Returned as SPANS of the paragraph the time already occupies, not as a node of
/// its own. A feed row is priced in widget nodes against a per-view ceiling that
/// refuses the whole screen when crossed, and "a quiet second line of metadata"
/// is precisely the sort of thing that costs ten rows' worth of budget without
/// looking like it costs anything.
///
/// The name is drawn in the meta register and prefixed, so it can never be read
/// as the note's own words. It is somebody else's claim about their software.
pub fn timeSpans(ui: *AppUi, note: *const Note, scale: f32) []const canvas.TextSpan {
    const name = note.client();
    if (name.len == 0) {
        const one = ui.arena.alloc(canvas.TextSpan, 1) catch return &.{};
        one[0] = .{ .text = note.time(), .scale = scale };
        return one;
    }
    const two = ui.arena.alloc(canvas.TextSpan, 2) catch return &.{};
    two[0] = .{ .text = note.time(), .scale = scale };
    // Same faint register as the time it follows: inherited from the paragraph,
    // so it cannot drift into looking like the note's own words.
    two[1] = .{ .text = ui.fmt(" via {s}", .{name}), .scale = scale };
    return two;
}

/// " · via X" for a line that is already a single string, empty when the note
/// says nothing. The span form above is for the rows that draw the time on its
/// own; the focal note builds one sentence, so it needs the text form.
pub fn viaSuffix(ui: *AppUi, note: *const Note) []const u8 {
    const name = note.client();
    if (name.len == 0) return "";
    return ui.fmt(" · via {s}", .{name});
}

/// What a note says it was written with, if it says anything.
///
/// Foreign text from a stranger's event, so it is treated as such: a name longer
/// than a label is not a label, and control characters in a meta row are how a
/// row stops looking like a row. An absent or unusable tag draws nothing at all,
/// never "via unknown", because what a note does not say is not a fact about it.
/// In BYTES, which is what the buffer holds, and in CHARACTERS, which is what a
/// reader sees. Both are needed: a byte cap alone is about eight characters of
/// Japanese and twenty-four of English, so it silently refuses a legitimate name
/// in one script and accepts a much wider one in another.
/// 48 so that the CHARACTER cap is the one that binds in every script that
/// matters here: fourteen three-byte characters fit, which is what makes the
/// Japanese case behave like the English one rather than being cut a third
/// shorter for no reason a reader could see.
pub const client_name_bytes = 48;
const client_name_chars = 14;

pub fn clientOf(ev: nostr.event.Event) ?[]const u8 {
    for (ev.tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "client")) continue;
        const name = std.mem.trim(u8, tag[1], " \t\r\n");
        if (name.len == 0) return null;
        for (name) |c| {
            if (c < 0x20 or c == 0x7f) return null;
        }
        // TRUNCATED, not refused. A name too long for the row is still evidence
        // about the note; refusing it outright threw away the whole fact, and
        // did so unevenly by script.
        return clipToChars(name, client_name_chars, client_name_bytes);
    }
    return null;
}

/// How long a content warning's reason may be, in bytes and in characters. One
/// line in a chip, so it is clipped the way a client name is: both caps, because
/// a byte cap alone is a different width in every script.
pub const warning_reason_bytes = 96;
const warning_reason_chars = 48;
///
/// The room the reason gets while it is being typed. What a reader sees is clipped
/// to the caps above, so the field does not need to run far past them.
pub const warning_input_capacity = 120;

/// What an event's NIP-36 `content-warning` tag says, or null when it has none.
///
/// The TAG is the warning, not the sentence in it. `["content-warning"]` and
/// `["content-warning", ""]` are both a request to cover the note and answer an
/// empty reason, and so does a reason holding a control character, which is
/// dropped rather than drawn: refusing to cover a note because its explanation
/// was malformed would invert the author's request. Jumble and Amethyst read the
/// tag the same way (`isNsfwEvent` in `src/lib/event.ts:49`, `TagArray.isSensitive`
/// in `nip36SensitiveContent/TagArrayExt.kt:28`), and Amethyst's
/// `ContentWarningTag.parse` blank-checks the reason (`ContentWarningTag.kt:39`).
pub fn contentWarningOf(ev: nostr.event.Event) ?[]const u8 {
    return contentWarningIn(ev.tags);
}

pub fn contentWarningIn(tags: []const nostr.event.Tag) ?[]const u8 {
    for (tags) |tag| {
        if (tag.len < 1 or !std.mem.eql(u8, tag[0], "content-warning")) continue;
        if (tag.len < 2) return "";
        const reason = std.mem.trim(u8, tag[1], " \t\r\n");
        for (reason) |c| {
            if (c < 0x20 or c == 0x7f) return "";
        }
        return clipToChars(reason, warning_reason_chars, warning_reason_bytes);
    }
    return null;
}

/// The longest prefix of `s` that is at most `max_chars` codepoints and
/// `max_bytes` bytes, cut on a UTF-8 boundary.
///
/// Codepoints rather than bytes because the cap exists to bound WIDTH, and a
/// three-byte character is not three characters wide. Cutting mid-sequence would
/// hand the renderer an invalid string, which is a different bug.
pub fn clipToChars(s: []const u8, max_chars: usize, max_bytes: usize) []const u8 {
    var i: usize = 0;
    var chars: usize = 0;
    while (i < s.len and chars < max_chars) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
        if (i + len > s.len or i + len > max_bytes) break;
        _ = std.unicode.utf8Decode(s[i .. i + len]) catch return s[0..i];
        i += len;
        chars += 1;
    }
    return s[0..i];
}

/// Publishes the reply composer's text as a NIP-10 reply to the open thread's
/// note: a kind:1 e-tagging the root (marked "root") and p-tagging its author,
/// signed and stored local-first so it joins the thread at once. A guest cannot
/// sign, so a reply attempt routes to the join sheet.
/// Sends the held reply, or sends one straight away when the pause is off.
pub fn fireReply(model: *Model, fx: *Effects, route: ?PlaceRoute) void {
    g_reply_due_s = 0;
    publishReply(model, fx, route);
}

fn publishReply(model: *Model, fx: *Effects, route: ?PlaceRoute) void {
    if (model.viewing_thread == 0) return;
    if (model.is_guest()) {
        model.joining = true;
        return;
    }
    const root = model.noteById(model.viewing_thread) orelse return;
    const text = std.mem.trim(u8, model.reply_buffer.text(), " \t\r\n");
    if (text.len == 0) return;
    // Asked first, like every other write. Notary signs one thing at a time, and
    // a reply sent while something else is out took that request's slot and its
    // undo with it. The text stays in the box.
    if (!signerReady()) {
        setToast(model, "Your signer is busy. Try that again in a moment.");
        return;
    }
    const gpa = std.heap.page_allocator;
    const content = gpa.dupe(u8, text) catch return;
    const id_hex = hexAlloc(gpa, root.event_id) orelse return;
    // Where the root can be found, so the next reader of this reply does not have
    // to guess. Empty, not absent, when nothing is known: the marker sits in the
    // slot after it.
    var root_hints: HintList = .{};
    hintsFor(root.event_id, root.pubkey, &root_hints);
    const root_hint = hintOrEmpty(gpa, &root_hints) orelse return;
    const e_tag = gpa.dupe([]const u8, &.{ "e", id_hex, root_hint, "root" }) catch return;
    const p_tag = pTagFor(gpa, root.pubkey) orelse return;

    // Everybody already in the conversation, not only the person being answered.
    // A reply that tags one author is a reply the rest of the thread never hears
    // about, so they answer into a conversation that has moved on without them.
    // Both reference clients do this: Amethyst p-tags every author in the thread
    // plus the parent's own mentions, Jumble the parent author plus the parent's
    // p tags. Plaza does not retain a note's raw tags, so this is the authors,
    // which is the part that carries the conversation.
    var participants: [max_thread_participant_tags][32]u8 = undefined;
    var participants_len: usize = 0;
    const me = activePubkey();
    for (model.thread_notes[0..model.thread_notes_len]) |n| {
        if (participants_len == participants.len) break;
        // Not the root author, who already has a tag, and never yourself.
        if (std.mem.eql(u8, &n.pubkey, &root.pubkey)) continue;
        if (me) |mine| {
            if (std.mem.eql(u8, &mine, &n.pubkey)) continue;
        }
        if (mentionExcluded(model.mentionsOff(), n.pubkey)) continue;
        var dup = false;
        for (participants[0..participants_len]) |seen| {
            if (std.mem.eql(u8, &seen, &n.pubkey)) dup = true;
        }
        if (dup) continue;
        participants[participants_len] = n.pubkey;
        participants_len += 1;
    }

    const thread = gpa.alloc(nostr.event.Tag, 2 + participants_len) catch return;
    thread[0] = e_tag;
    thread[1] = p_tag;
    var filled: usize = 2;
    for (participants[0..participants_len]) |pubkey| {
        thread[filled] = pTagFor(gpa, pubkey) orelse break;
        filled += 1;
    }
    // The threading tags first, then whatever the reply's own text implies. A
    // reply can carry a hashtag, a mention or a picture exactly like a note can,
    // and it used to carry none of them.
    const tags = contentTags(gpa, content, thread[0..filled], model.mentionsOff());
    // Its own copy, because `content` belongs to the write seam from here and a
    // reply is not `restorable`: the composer's restore path holds one draft and
    // hands it to the composer, which is the wrong box for this text.
    const kept: PendingUndo = if (std.heap.page_allocator.dupe(u8, text)) |c| .{ .reply = .{ .text = c, .root = root.event_id } } else |_| .none;
    signAndPublish(fx, gpa, nowSeconds(), 1, tags, content, false, kept, route);
    model.reply_buffer.clear();
}
// ------------------------------------------------------------------------ likes
//
// A like is a NIP-25 kind:7 reaction with content "+", e/p/k-tagging the note.
// It rides the same three sign paths as a post and is local-first and optimistic:
// the heart fills the instant it is pressed (read from `g_my_likes` at render),
// and the reaction publishes in the background. Un-like is a NIP-09 kind:5
// deletion e-tagging our own reaction, since NIP-25 has no un-react. A guest
// press cannot sign, so it is remembered and completed after sign-in.

/// Lowercase-hex-encodes a 32-byte value into a fresh process-lifetime slice.
pub fn hexAlloc(gpa: std.mem.Allocator, bytes: [32]u8) ?[]const u8 {
    const out = gpa.alloc(u8, 64) catch return null;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

// How many of each derived tag one note may carry. Caps rather than limits: a
// pasted C header emits a topic per `#include`, a pasted thread emits a mention
// per npub, and neither should be allowed to turn one note into a hundred-tag
// event that relays reject wholesale.
const max_topic_tags = 10;
pub const max_mention_tags = 8;
const max_quote_tags = 4;
const max_imeta_tags = 4;
// A long thread should not turn one reply into a mass notification, and some
// relays cap tag counts outright.
const max_thread_participant_tags = 12;
pub const max_topic_bytes = 64;

/// Rewrites `github.com/<owner>/<repo>/raw/<rest>` to
/// `raw.githubusercontent.com/<owner>/<repo>/<rest>`, returning `text` unchanged
/// when there is nothing to rewrite (and on OOM).
///
/// The first form is a 302 whose own response is `content-type: text/html`, so a
/// client that checks the type before inlining refuses to draw the picture and
/// the note arrives as a wall of text with a link in it. The second form is the
/// same bytes with `image/jpeg` on the first response.
///
/// Narrow on purpose: one host, one path shape, both ends serving the identical
/// file. This is the only place Plaza edits what somebody typed, and widening it
/// into a general URL cleaner would make that a habit instead of a fix.
fn canonicalMediaUrls(gpa: std.mem.Allocator, text: []const u8) []const u8 {
    const marker = "https://github.com/";
    if (std.mem.indexOf(u8, text, marker) == null) return text;

    var out = std.ArrayList(u8).initCapacity(gpa, text.len) catch return text;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.mem.startsWith(u8, text[i..], marker)) {
            out.append(gpa, text[i]) catch return text;
            i += 1;
            continue;
        }
        var end = i;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
        const url = text[i..end];
        const tail = url[marker.len..];
        // owner/repo/raw/<rest>, and nothing shorter.
        var parts = std.mem.splitScalar(u8, tail, '/');
        const owner = parts.next() orelse "";
        const repo = parts.next() orelse "";
        const raw = parts.next() orelse "";
        const rest = parts.rest();
        if (owner.len > 0 and repo.len > 0 and std.mem.eql(u8, raw, "raw") and rest.len > 0) {
            out.print(gpa, "https://raw.githubusercontent.com/{s}/{s}/{s}", .{ owner, repo, rest }) catch return text;
        } else {
            out.appendSlice(gpa, url) catch return text;
        }
        i = end;
    }
    return out.toOwnedSlice(gpa) catch text;
}

/// The MIME type an image URL's extension implies, or "" when it implies none.
fn imageMimeForUrl(url: []const u8) []const u8 {
    const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path = url[0..path_end];
    const table = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".avif", .mime = "image/avif" },
        .{ .ext = ".bmp", .mime = "image/bmp" },
    };
    for (table) |row| {
        if (std.ascii.endsWithIgnoreCase(path, row.ext)) return row.mime;
    }
    return "";
}

/// The tags a note's own text implies: `t` per hashtag, `p` per mention, `q` per
/// quoted event, and `imeta` per image URL.
///
/// Everything here is derived from the text being published, at the moment it is
/// published, never from a list assembled while typing. Deleting a mention has
/// to delete its tag, and a side list built when the mention was picked goes
/// stale the moment the text is edited around it.
///
/// Not folded into `signAndPublish` alongside `withClientTag`, though that is the
/// one door every event passes through. A kind:0's content is a JSON blob whose
/// display name may contain a `#`, and a kind:3's content is machinery; scanning
/// those would put garbage on the network. The single-door pattern is right for a
/// tag that describes the client and wrong for tags derived from prose.
///
/// Process-lifetime, like the other builders here: the local write and the
/// detached publish both read these after this returns. Degrades to fewer tags on
/// OOM rather than refusing to post.
/// Everyone `content` would notify: each mention it names, and the author of
/// each event it quotes. Self-filtered and deduped, in the order they appear.
///
/// The composer's chips and the publish path both call this. Two functions that
/// each derived the set would be two functions that could disagree, and the one
/// promise the chips make is that they name exactly who gets tagged.
pub fn notifiedBy(content: []const u8, out: *[max_mention_tags][32]u8) usize {
    var n: usize = 0;
    const me = activePubkey();
    var scratch: [16 * 1024]u8 = undefined;
    var i: usize = 0;
    while (i < content.len and n < out.len) {
        // URLs whole, so a token inside one is never read as a reference.
        if (std.mem.startsWith(u8, content[i..], "http://") or std.mem.startsWith(u8, content[i..], "https://")) {
            while (i < content.len and !std.ascii.isWhitespace(content[i])) i += 1;
            continue;
        }
        var found: ?[32]u8 = null;
        var next = i + 1;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const arena = fba.allocator();
        if (parseMentionAt(arena, content, i)) |m| {
            found = m.pubkey;
            next = m.end;
        } else if (refPrecededByBoundary(content, i)) {
            var body_start = i;
            if (std.mem.startsWith(u8, content[i..], "nostr:")) body_start = i + "nostr:".len;
            const rest = content[body_start..];
            if (std.mem.startsWith(u8, rest, "nevent1")) {
                var j: usize = 0;
                while (j < rest.len and isBech32Char(rest[j])) j += 1;
                if (nostr.nip19.decodeNevent(arena, rest[0..j])) |ptr| {
                    // Only an author the pointer itself carries. A note1 has
                    // none, and this list must not name somebody on a guess.
                    if (ptr.author) |author| found = author;
                    next = body_start + j;
                } else |_| {}
            }
        }
        if (found) |pubkey| {
            const is_me = if (me) |mine| std.mem.eql(u8, &mine, &pubkey) else false;
            var dup = false;
            for (out[0..n]) |seen| {
                if (std.mem.eql(u8, &seen, &pubkey)) dup = true;
            }
            if (!is_me and !dup) {
                out[n] = pubkey;
                n += 1;
            }
            i = @max(next, i + 1);
            continue;
        }
        i += 1;
    }
    return n;
}

/// Whether `content` names `who`: as a NIP-27 mention, or as the author of an
/// event it quotes.
///
/// The reading half of what `notifiedBy` does for writing. Same scan, same
/// tokens, one difference: this one is asked about a specific person and so
/// cannot filter the reader out, which is the only thing it is ever asked
/// about.
pub fn contentNames(content: []const u8, who: [32]u8) bool {
    var scratch: [16 * 1024]u8 = undefined;
    var i: usize = 0;
    while (i < content.len) {
        // URLs whole, so a token inside one is never read as a reference.
        if (std.mem.startsWith(u8, content[i..], "http://") or std.mem.startsWith(u8, content[i..], "https://")) {
            while (i < content.len and !std.ascii.isWhitespace(content[i])) i += 1;
            continue;
        }
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const arena = fba.allocator();
        if (parseMentionAt(arena, content, i)) |m| {
            if (std.mem.eql(u8, &m.pubkey, &who)) return true;
            i = @max(m.end, i + 1);
            continue;
        }
        if (refPrecededByBoundary(content, i)) {
            var body_start = i;
            if (std.mem.startsWith(u8, content[i..], "nostr:")) body_start = i + "nostr:".len;
            const rest = content[body_start..];
            if (std.mem.startsWith(u8, rest, "nevent1")) {
                var j: usize = 0;
                while (j < rest.len and isBech32Char(rest[j])) j += 1;
                if (nostr.nip19.decodeNevent(arena, rest[0..j])) |ptr| {
                    // Quoting somebody's note is telling them about it, so the
                    // author the pointer carries counts. A `note1` carries none,
                    // and nobody is named on a guess.
                    if (ptr.author) |author| {
                        if (std.mem.eql(u8, &author, &who)) return true;
                    }
                    i = @max(body_start + j, i + 1);
                    continue;
                } else |_| {}
            }
        }
        i += 1;
    }
    return false;
}
/// Whether `pubkey` is in `excluded`, the set the reader has switched off for
/// this draft.
pub fn mentionExcluded(excluded: []const [32]u8, pubkey: [32]u8) bool {
    for (excluded) |e| {
        if (std.mem.eql(u8, &e, &pubkey)) return true;
    }
    return false;
}

pub fn contentTags(gpa: std.mem.Allocator, content: []const u8, base: []const nostr.event.Tag, excluded: []const [32]u8) []const nostr.event.Tag {
    var topics: [max_topic_tags][]const u8 = undefined;
    var topics_len: usize = 0;
    var mentions: [max_mention_tags][32]u8 = undefined;
    var mentions_len: usize = 0;
    var quotes: [max_quote_tags]struct { id: [32]u8, author: ?[32]u8, relay: UrlList(1) } = undefined;
    var quotes_len: usize = 0;
    var images: [max_imeta_tags][]const u8 = undefined;
    var images_len: usize = 0;

    const me = activePubkey();
    var scratch: [16 * 1024]u8 = undefined;

    var i: usize = 0;
    scan: while (i < content.len) {
        // A URL is consumed WHOLE, before anything else looks at this byte. That
        // single ordering is what keeps `https://example.com/page#section` from
        // publishing a topic called "section", and it is the guard the reference
        // clients are missing.
        if (std.mem.startsWith(u8, content[i..], "http://") or std.mem.startsWith(u8, content[i..], "https://")) {
            var j = i;
            while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
            const url = content[i..j];
            // A picture this app uploaded is one whatever its address ends in:
            // it knows what it sent.
            if (images_len < images.len and (looksLikeImageUrl(url) or uploadedPictureFor(url) != null)) {
                var dup = false;
                for (images[0..images_len]) |seen| {
                    if (std.mem.eql(u8, seen, url)) dup = true;
                }
                // One tag per distinct URL: NIP-92 pairs a tag with a URL in the
                // content, and the same picture twice is still one picture.
                if (!dup) {
                    images[images_len] = url;
                    images_len += 1;
                }
            }
            i = j;
            continue :scan;
        }

        // A mention, by the same parser the renderer uses, so what is tagged is
        // exactly what is drawn as a name.
        {
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            if (parseMentionAt(fba.allocator(), content, i)) |m| {
                const is_me = if (me) |mine| std.mem.eql(u8, &mine, &m.pubkey) else false;
                var dup = false;
                for (mentions[0..mentions_len]) |seen| {
                    if (std.mem.eql(u8, &seen, &m.pubkey)) dup = true;
                }
                // Never tag yourself: your own inbox lighting up for your own
                // note is a bug the reader would report as one.
                const off = mentionExcluded(excluded, m.pubkey);
                if (!is_me and !dup and !off and mentions_len < mentions.len) {
                    mentions[mentions_len] = m.pubkey;
                    mentions_len += 1;
                }
                i = m.end;
                continue :scan;
            }
        }

        // A quoted event.
        if (quotes_len < quotes.len) {
            var body_start = i;
            var is_ref = false;
            if (std.mem.startsWith(u8, content[i..], "nostr:")) {
                if (refPrecededByBoundary(content, i)) {
                    body_start = i + "nostr:".len;
                    is_ref = true;
                }
            } else if (std.mem.startsWith(u8, content[i..], "nevent1") or std.mem.startsWith(u8, content[i..], "note1")) {
                is_ref = refPrecededByBoundary(content, i);
            }
            if (is_ref) {
                const rest = content[body_start..];
                if (std.mem.startsWith(u8, rest, "nevent1") or std.mem.startsWith(u8, rest, "note1")) {
                    var j: usize = 0;
                    while (j < rest.len and isBech32Char(rest[j])) j += 1;
                    const token = rest[0..j];
                    var fba = std.heap.FixedBufferAllocator.init(&scratch);
                    const arena = fba.allocator();
                    var id: ?[32]u8 = null;
                    var author: ?[32]u8 = null;
                    // The relay the pointer itself names, first, because whoever
                    // wrote it chose it. Copied here: the decode's arena is the
                    // scratch buffer, reused on the next token.
                    var named: UrlList(1) = .{};
                    if (std.mem.startsWith(u8, token, "nevent1")) {
                        if (nostr.nip19.decodeNevent(arena, token)) |ptr| {
                            id = ptr.id;
                            author = ptr.author;
                            for (ptr.relays) |r| {
                                if (named.add(r)) break;
                            }
                        } else |_| {}
                    } else if (nostr.nip19.decodeNote(arena, token)) |note_id| {
                        id = note_id;
                    } else |_| {}
                    if (id) |event_id| {
                        var dup = false;
                        for (quotes[0..quotes_len]) |seen| {
                            if (std.mem.eql(u8, &seen.id, &event_id)) dup = true;
                        }
                        if (!dup) {
                            // Only the author the pointer itself carries. A
                            // `note1` carries none, and slot 4 is a notification
                            // target, so a guess there tells the wrong person
                            // they were quoted. Absent beats wrong.
                            quotes[quotes_len] = .{ .id = event_id, .author = author, .relay = named };
                            quotes_len += 1;
                        }
                        i = body_start + j;
                        continue :scan;
                    }
                }
            }
        }

        // A hashtag, last, because everything above can begin with a character
        // this would otherwise swallow.
        if (content[i] == '#' and i + 1 < content.len and isHashtagChar(content[i + 1]) and
            (i == 0 or !isHashtagChar(content[i - 1])))
        {
            var j = i + 1;
            while (j < content.len and isHashtagChar(content[j])) j += 1;
            const raw = content[i + 1 .. j];
            if (raw.len <= max_topic_bytes and std.unicode.utf8ValidateSlice(raw) and topics_len < topics.len) {
                // NIP-24 is a MUST on the value being lowercase. ASCII folding
                // only: a full Unicode fold would need a casing table, and the
                // tags this misses are ones no relay filter is asking for.
                const folded = gpa.alloc(u8, raw.len) catch {
                    i = j;
                    continue :scan;
                };
                _ = std.ascii.lowerString(folded, raw);
                var dup = false;
                for (topics[0..topics_len]) |seen| {
                    if (std.mem.eql(u8, seen, folded)) dup = true;
                }
                // Folded first, THEN deduped, so `#Nostr #nostr` is one topic.
                if (dup) {
                    gpa.free(folded);
                } else {
                    topics[topics_len] = folded;
                    topics_len += 1;
                }
            }
            i = j;
            continue :scan;
        }

        i += 1;
    }

    // Every quoted author is also a mention: NIP-10 asks for it, and without it
    // the person you quoted never learns you did.
    for (quotes[0..quotes_len]) |q| {
        const author = q.author orelse continue;
        if (mentions_len >= mentions.len) break;
        const is_me = if (me) |mine| std.mem.eql(u8, &mine, &author) else false;
        if (is_me or mentionExcluded(excluded, author)) continue;
        var dup = false;
        for (mentions[0..mentions_len]) |seen| {
            if (std.mem.eql(u8, &seen, &author)) dup = true;
        }
        if (dup) continue;
        mentions[mentions_len] = author;
        mentions_len += 1;
    }

    const derived = topics_len + mentions_len + quotes_len + images_len;
    if (derived == 0) return base;

    var out = std.ArrayList(nostr.event.Tag).initCapacity(gpa, base.len + derived) catch return base;
    out.appendSliceAssumeCapacity(base);

    for (topics[0..topics_len]) |topic| {
        const tag = gpa.dupe([]const u8, &.{ "t", topic }) catch break;
        out.appendAssumeCapacity(tag);
    }
    for (mentions[0..mentions_len]) |pubkey| {
        const tag = pTagFor(gpa, pubkey) orelse break;
        out.appendAssumeCapacity(tag);
    }
    for (quotes[0..quotes_len]) |q| {
        const id_hex = hexAlloc(gpa, q.id) orelse break;
        // The pointer's own relay, else the best Plaza knows (`hintsFor`), as
        // Jumble's `extractQuoteTags` does with `data.relays?.[0] ?? getEventHint`.
        // Empty when neither exists, because the author sits after it.
        const relay: []const u8 = if (q.relay.count > 0)
            gpa.dupe(u8, q.relay.at(0)) catch break
        else blk: {
            var hints: HintList = .{};
            hintsFor(q.id, q.author, &hints);
            break :blk hintOrEmpty(gpa, &hints) orelse break;
        };
        // Positional, so an author can only be read out of slot 4. With no
        // author the tag stops at the relay, or at the id when there is none,
        // rather than shipping empty slots.
        const tag = if (q.author) |author| blk: {
            const author_hex = hexAlloc(gpa, author) orelse break :blk gpa.dupe([]const u8, &.{ "q", id_hex }) catch break;
            break :blk gpa.dupe([]const u8, &.{ "q", id_hex, relay, author_hex }) catch break;
        } else if (relay.len > 0)
            gpa.dupe([]const u8, &.{ "q", id_hex, relay }) catch break
        else
            gpa.dupe([]const u8, &.{ "q", id_hex }) catch break;
        out.appendAssumeCapacity(tag);
    }
    for (images[0..images_len]) |url| {
        // One this app uploaded: it carries everything the uploader knew, which
        // is more than a reader fetching it would learn.
        if (uploadedImeta(gpa, url)) |full| {
            out.appendAssumeCapacity(full);
            continue;
        }
        // NIP-92's fields are one space-joined "key value" string each, and a
        // value may itself contain spaces, so a reader splits on the FIRST space
        // only. Plaza's own reader already does; this writes what that reads.
        const url_field = std.fmt.allocPrint(gpa, "url {s}", .{url}) catch break;
        const mime = imageMimeForUrl(url);
        const tag = if (mime.len == 0)
            gpa.dupe([]const u8, &.{ "imeta", url_field }) catch break
        else blk: {
            const mime_field = std.fmt.allocPrint(gpa, "m {s}", .{mime}) catch break;
            break :blk gpa.dupe([]const u8, &.{ "imeta", url_field, mime_field }) catch break;
        };
        out.appendAssumeCapacity(tag);
    }

    return out.toOwnedSlice(gpa) catch base;
}

/// The NIP-25 like tags for a note: `["e", id, relay]`, `["p", author, relay]`,
/// `["k", "1"]`. Each relay is left off, not blanked, when nothing is known:
/// NIP-25 puts the hint last in both tags, so there is nothing to hold a place
/// for. Process-lifetime (the sign paths reference them); null on OOM.
fn buildLikeTags(gpa: std.mem.Allocator, note: *const Note) ?[]const nostr.event.Tag {
    const id_hex = hexAlloc(gpa, note.event_id) orelse return null;
    var hints: HintList = .{};
    hintsFor(note.event_id, note.pubkey, &hints);
    const e = if (hints.count == 0)
        gpa.dupe([]const u8, &.{ "e", id_hex }) catch return null
    else
        gpa.dupe([]const u8, &.{ "e", id_hex, hintOrEmpty(gpa, &hints) orelse return null }) catch return null;
    const p = pTagFor(gpa, note.pubkey) orelse return null;
    const k = gpa.dupe([]const u8, &.{ "k", "1" }) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, 3) catch return null;
    tags[0] = e;
    tags[1] = p;
    tags[2] = k;
    return tags;
}

/// The NIP-18 tags on a repost: `["e", id, "", author]` and `["p", author]`.
///
/// Read off Jumble (`src/lib/draft-event.ts:126` `createRepostDraftEvent`, whose
/// `buildETag(event.id, event.pubkey)` puts the author in the e-tag's fourth
/// field) and NDK (`core/src/events/repost.ts`, which tags the event and then
/// adds `k` only for a kind other than 1). Both send the e-tag and the p-tag and
/// no `k` for a kind:1, which is every note Plaza's feed holds, so there is no
/// `k` here and no kind:16.
///
/// The third field is the relay hint, where the reposted note can be found
/// (`hintsFor`). It is empty rather than absent when nothing is known because
/// the author sits in the fourth, and dropping the hint would move the pubkey
/// into the hint's place and tell every reader to dial it as a relay. Jumble's
/// `buildETag` fills the same slot from `getEventHint`, and Amethyst's
/// `RepostEvent.build` from the hint bundle's relay.
fn buildRepostTags(gpa: std.mem.Allocator, note: *const Note) ?[]const nostr.event.Tag {
    const id_hex = hexAlloc(gpa, note.event_id) orelse return null;
    const author_hex = hexAlloc(gpa, note.pubkey) orelse return null;
    var hints: HintList = .{};
    hintsFor(note.event_id, note.pubkey, &hints);
    const hint = hintOrEmpty(gpa, &hints) orelse return null;
    const e = gpa.dupe([]const u8, &.{ "e", id_hex, hint, author_hex }) catch return null;
    const p = pTagFor(gpa, note.pubkey) orelse return null;
    const tags = gpa.alloc(nostr.event.Tag, 2) catch return null;
    tags[0] = e;
    tags[1] = p;
    return tags;
}

/// The reposted note itself, as JSON, which is what NIP-18 says the content
/// should carry and what both clients above put there. A reader that has never
/// seen the note can render it from this without going and asking for it.
///
/// Empty when the note is not in the store, which is legal and is what those
/// clients fall back to as well. Plaza reads its own feed out of the store, so
/// it is normally there; a note that has been evicted still reposts, it just
/// costs the reader a fetch.
pub fn repostContent(gpa: std.mem.Allocator, note: *const Note) []const u8 {
    const store = main.g_store orelse return gpa.dupe(u8, "") catch "";
    var se = (store.getEvent(gpa, note.event_id) catch null) orelse return gpa.dupe(u8, "") catch "";
    defer se.deinit();
    return nostr.event.toJson(gpa, se.event) catch gpa.dupe(u8, "") catch "";
}

/// The NIP-09 deletion tags to un-like: `["e", reaction_id]`, `["k", "7"]`.
/// The tags of a NIP-09 deletion: the event it asks relays to drop, and the
/// kind that event was. This was `buildUnlikeTags` with the 7 written in, which
/// is the same builder with one number decided in advance.
///
/// The `k` tag is what lets a relay refuse a request to delete something of a
/// kind the sender should not be deleting, without fetching the target first.
fn buildDeleteTags(gpa: std.mem.Allocator, target_id: [32]u8, target_kind: u16) ?[]const nostr.event.Tag {
    const id_hex = hexAlloc(gpa, target_id) orelse return null;
    var kind_buf: [8]u8 = undefined;
    const kind_text = std.fmt.bufPrint(&kind_buf, "{d}", .{target_kind}) catch return null;
    const kind_owned = gpa.dupe(u8, kind_text) catch return null;
    const e = gpa.dupe([]const u8, &.{ "e", id_hex }) catch return null;
    const k = gpa.dupe([]const u8, &.{ "k", kind_owned }) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, 2) catch return null;
    tags[0] = e;
    tags[1] = k;
    return tags;
}

/// Toggles a like on `note_id`. A guest cannot sign, so the like is remembered
/// and the join sheet opens; it completes after sign-in (`drivePendingIntent`).
pub fn toggleLike(model: *Model, fx: *Effects, note_id: i64) void {
    if (model.is_guest()) {
        model.pending = .{ .like = note_id };
        model.joining = true;
        return;
    }
    // A like and an un-like both move `g_my_likes` before they sign, and an
    // un-like's kind:5 is a deletion. A rejected sign there would leave the heart
    // empty and the reaction still standing on every relay.
    if (!signerReady()) return setToast(model, "Your signer is busy. Try that again in a moment.");
    if (isLiked(note_id)) unlike(fx, note_id) else like(model, fx, note_id);
}

/// Publishes a kind:7 like and fills the heart at once. The reaction id is
/// deterministic in the unsigned fields, so it is computed here (with the same
/// created/tags/content the sign path will use) and remembered, so an un-like
/// can delete exactly this reaction.
pub fn like(model: *const Model, fx: *Effects, note_id: i64) void {
    const note = model.noteById(note_id) orelse return;
    const gpa = std.heap.page_allocator;
    const pk = activePubkey() orelse return;
    const created = nowSeconds();
    const tags = buildLikeTags(gpa, note) orelse return;
    const content = gpa.dupe(u8, "+") catch return;
    const id = nostr.event.computeId(gpa, pk, created, 7, tags, content) catch return;
    rememberLike(note_id, id);
    signAndPublish(fx, gpa, created, 7, tags, content, false, .{ .like = note_id }, null);
}

/// Publishes a kind:6 repost, and fills the icon at once.
///
/// One way, on purpose. Jumble disables its button once you have reposted
/// (`RepostButton.tsx`, `canRepost = !hasReposted && …`) and NDK offers no undo
/// at all; a like has one here only because an un-like has a reaction id to
/// name in a kind:5, and every reader treats a deleted repost differently
/// anyway. Pressing again is a no-op rather than a second repost.
pub fn repost(model: *Model, fx: *Effects, note_id: i64) void {
    if (model.is_guest()) {
        model.pending = .{ .repost = note_id };
        model.joining = true;
        return;
    }
    if (!signerReady()) return setToast(model, "Your signer is busy. Try that again in a moment.");
    if (engagementFor(note_id).reposted_by_me) return;
    const note = model.noteById(note_id) orelse return;
    const gpa = std.heap.page_allocator;
    const tags = buildRepostTags(gpa, note) orelse return;
    const content = repostContent(gpa, note);
    // Filled before the signature comes back, the same way a like is. Our own
    // kind:6 arrives through the engagement subscription a moment later and sets
    // the same flag from the crowd, so this only covers the gap.
    markRepostedByMe(note_id);
    signAndPublish(fx, gpa, nowSeconds(), 6, tags, content, false, .{ .repost = note_id }, null);
}

/// Sets the "ours" flag on a note's row before the crowd confirms it.
///
/// The FLAG only. Not the count, which is the part a like has to work at: a like
/// shows an optimistic +1 and then has to retire it, which is why it remembers
/// its reaction id and why `likeCountFor` subtracts. Adding one here would be
/// added again a moment later, because our own kind:6 arrives through the same
/// engagement subscription as everybody else's and `markSeen` is keyed by event
/// id, so that fold is the first time that id has been seen and it counts.
///
/// So the icon fills at once and the number moves when the repost is really out.
/// That is the honest pair: the icon is about what you did, the number is about
/// what has been seen.
pub fn markRepostedByMe(note_id: i64) void {
    engagementLock();
    defer engagementUnlock();
    const row = ensureEngagement(note_id) orelse return;
    row.counts.reposted_by_me = true;
}

/// Clears it again, for a repost whose signature never came back.
///
/// The flag used to be written `true` and nothing else, so a refused repost
/// left the button dead for the rest of the process (`repost` returns early on
/// it), and, because it is not cleared on logout either, dead for the next
/// account to sign in as well.
pub fn clearRepostedByMe(note_id: i64) void {
    engagementLock();
    defer engagementUnlock();
    const row = ensureEngagement(note_id) orelse return;
    row.counts.reposted_by_me = false;
}

/// Publishes a kind:5 deletion of our own reaction and empties the heart at once.
fn unlike(fx: *Effects, note_id: i64) void {
    const gpa = std.heap.page_allocator;
    const reaction_id = forgetLike(note_id) orelse return;
    const tags = buildDeleteTags(gpa, reaction_id, 7) orelse return;
    const content = gpa.dupe(u8, "") catch return;
    // The id is already gone from the table by here, so the undo carries it:
    // without it a refused un-like empties the heart, leaves the kind:7 on
    // every relay, and the next press publishes a second reaction.
    signAndPublish(fx, gpa, nowSeconds(), 5, tags, content, false, .{ .unlike = .{ .note_id = note_id, .reaction_id = reaction_id } }, null);
}

/// Asks the relays to drop a note this reader wrote.
///
/// The local half needs no code: the store tombstones and removes on ingest of
/// a kind:5, scoped to the same author, the signed event reaches it through the
/// one door every write goes through, and a kind:5 landing already invalidates
/// the feed. So the note leaves the feed on the next rebuild with nothing added
/// here.
///
/// Kind 1 only, and that is a rule rather than a simplification. A replaceable
/// event is superseded, never deleted: `capturePrevious` and `keepReplaced`
/// exist so a list can be walked back, and a kind:5 aimed at one would ask
/// relays to drop the reader's follow list or their relay list with no way
/// back. Amethyst does delete lists this way. This will not.
pub fn deleteNote(model: *Model, fx: *Effects, note_id: i64) void {
    const target = deletableTarget(model, note_id) orelse return;
    // Said, rather than the confirm closing on nothing.
    if (!signerReady()) return setToast(model, signer_busy_toast);
    const gpa = std.heap.page_allocator;
    const tags = buildDeleteTags(gpa, target.event_id, target.kind) orelse return;
    const content = gpa.dupe(u8, "") catch return;
    // A thread level is a snapshot, so reading the note you just deleted would
    // leave a level showing an event the store no longer holds.
    if (model.viewing_thread == note_id) closeThread(model);
    signAndPublish(fx, gpa, nowSeconds(), 5, tags, content, false, .none, null);
}

/// What a deletion may target, or null when the answer is no.
///
/// Separated from the publish because these gates are the whole safety of the
/// feature and a test has to be able to ask them without signing anything.
pub fn deletableTarget(model: *Model, note_id: i64) ?struct { event_id: [32]u8, kind: u16 } {
    const note = model.noteById(note_id) orelse return null;
    const me = activePubkey() orelse return null;
    if (!std.mem.eql(u8, &note.pubkey, &me)) return null;
    // The kind comes from the STORE, not from the card. A `Note` carries no
    // kind: the feed builds one from whatever it drew, and an event of a kind
    // this app cannot render is still drawn as a note today (#268). Reading the
    // stored event is the only way to know what is actually being asked for,
    // and it is worth a disk read on the one action with no undo.
    const store = main.g_store orelse return null;
    var stored = (store.getEvent(std.heap.page_allocator, note.event_id) catch return null) orelse return null;
    defer stored.deinit();
    // Kind 1 only, and that is a rule rather than a simplification. A
    // replaceable event is superseded, never deleted: `capturePrevious` and
    // `keepReplaced` exist so a list can be walked back, and a kind:5 aimed at
    // one would ask relays to drop this reader's follow list or their relay
    // list with no way back. Amethyst deletes lists this way. This will not.
    if (stored.event.kind != 1) return null;
    // The card said it was theirs; the stored event has to agree. A card is
    // built by the feed and a signature is not.
    if (!std.mem.eql(u8, &stored.event.pubkey, &me)) return null;
    return .{ .event_id = note.event_id, .kind = stored.event.kind };
}
/// After sign-in, completes a like a guest reached for: the welcome-in moment.
/// Driven from the tick, where `fx` is in hand and the feed has just rebuilt.
pub fn drivePendingIntent(model: *Model, fx: *Effects) void {
    if (!model.pending.waiting() or model.is_guest()) return;
    const intent = model.pending;
    // Cleared FIRST, whatever happens next. A verb that cannot be completed (the
    // note scrolled away, the follow list has not loaded) must not be retried on
    // every tick for the rest of the session.
    model.pending = .none;
    switch (intent) {
        .none => {},
        .post => model.composing = true,
        .reply => |id| {
            // Back to the conversation they were in, with what they wrote still
            // in the box: `reply_buffer` survived the sheet.
            if (model.viewing_thread != id) openEvent(model, noteEventId(model, id) orelse return);
        },
        .like => |id| {
            if (isLiked(id)) return;
            like(model, fx, id);
            setToast(model, "Liked");
        },
        .repost => |id| {
            if (engagementFor(id).reposted_by_me) return;
            repost(model, fx, id);
            setToast(model, "Reposted");
        },
        .follow => |pk| {
            // The follow-safety gate still applies: this publishes a replaceable
            // list, and nothing may be written over a contact list that has not
            // been read back. When it is not yet safe the intent is dropped rather
            // than queued, because a write that lands minutes later, silently, is
            // exactly the shape this app refuses everywhere else.
            if (!canWriteFollows()) {
                // Every relay finished with no list: the guest's first follow is
                // asked about like any other, now that they have an account.
                if (askFreshFirst(model, .{ .action = .follow, .who = pk })) return;
                setToast(model, noListToast("follow list"));
                return;
            }
            sayFollowWrite(model, writeFollow(fx, pk, true), true);
        },
    }
}
/// The full event id of a loaded note, for reopening what a guest was reading.
fn noteEventId(model: *const Model, note_id: i64) ?[32]u8 {
    if (model.noteById(note_id)) |note| return note.event_id;
    return null;
}

/// Deep-copies `tags` into process-lifetime memory so the detached publisher can
/// read them after the parse arena is freed. Returns an empty set on OOM (posts
/// are tagless, so nothing is lost there; a reaction that OOMs simply drops).
/// Copies a record's tags, or reports that it could not.
///
/// Null, never an empty slice. This is the splice base for every replaceable
/// write (kind 0, 3 and 10002), and those writes decide how much to keep by
/// counting what is in here. An empty slice says "this record had no tags",
/// which is a true statement about a record with no tags and a catastrophic one
/// about a copy that ran out of memory: the follow list's own shrink guard
/// compares against this same slice, so 0 to 1 reads as growth and passes.
///
/// A base that could not be copied whole must read as "not read". Every caller
/// already handles that safely, because it is the same path as a store miss.
pub fn dupeTags(gpa: std.mem.Allocator, tags: []const nostr.event.Tag) ?[]const nostr.event.Tag {
    if (tags.len == 0) return &.{};
    const out = gpa.alloc(nostr.event.Tag, tags.len) catch return null;
    for (tags, 0..) |tag, i| {
        const fields = gpa.alloc([]const u8, tag.len) catch return null;
        for (tag, 0..) |field, j| {
            fields[j] = gpa.dupe(u8, field) catch return null;
        }
        out[i] = fields;
    }
    return out;
}

/// The engine write seam: a note this process now holds, whether locally signed
/// or returned signed from the remote signer, enters the local store and is
/// published to the pool. The store is the single-writer data plane, only ever
/// written from this process. `verify` re-checks a signature we did not produce
/// ourselves and gates such a note out of both the store and the pool on
/// failure; a note we just signed skips the check and publishes even if the
/// store rejects the write (a duplicate). `ev.content` must be a
/// process-lifetime allocation, since the detached publisher reads it after
/// this returns.
pub fn ingestAndPublish(gpa: std.mem.Allocator, ev: nostr.event.Event, verify: ?nostr.keys.Signer, route: PlaceRoute) void {
    // A media server's upload token is a bearer credential for one file, not a
    // record. It is never stored and never published, whatever signed it.
    if (ev.kind == blossom.auth_kind) return;
    if (builtin.is_test) {
        keyholder.g_last_published = ev;
        keyholder.g_last_published_route = route;
    }
    if (main.g_store == null) return;
    if (verify) |signer| {
        // A note a bunker signed: verification is the gate into the store AND
        // the pool, so a bad signature is dropped rather than propagated.
        const stored = if (plazaIngest(gpa, ev, .{ .verify_with = signer })) |result| switch (result) {
            .added, .replaced, .duplicate, .stale => true,
            else => false,
        } else |_| false;
        if (!stored) {
            // The store refused it or failed before it checked anything, so
            // the signature is checked here. A bad one is not published, and
            // `.invalid` lands here too. A good one goes out anyway, the way a
            // Notary write the store refused does: returning dropped a mute or
            // a follow the press had already shown, whose undo the listener
            // releases on the signature, with nothing stored, nothing sent
            // and nothing said. And it is held, so the next write of its kind
            // builds on it. The hold is the UI thread's and this runs on the
            // bunker listener, so it goes by the inbox the hold reads first.
            if (!(nostr.event.verify(gpa, signer, ev) catch false)) return;
            noteOwnWriteUnstoredOffThread(ev);
        }
    } else {
        // A note we just signed: a store failure (e.g. a duplicate id) must not
        // stop it reaching the pool. But the store is now behind what went
        // out, and a write that splices onto it must wait for this record.
        const stored = if (plazaIngest(gpa, ev, .{})) |result| switch (result) {
            .added, .replaced, .duplicate, .stale => true,
            else => false,
        } else |_| false;
        if (!stored) noteOwnWriteUnstored(ev);
    }
    // Queued BEFORE the walk, so a note that never reaches a relay is still a
    // note the app knows it owes the reader. A queue with no room says so:
    // publishing anyway would be a note nobody is tracking while the banner
    // promises that anything written is kept.
    if (isReaderNote(ev.kind)) {
        if (!enqueueOutbox(ev.id, ev.pubkey, nowSeconds(), route)) {
            outbox.g_outbox_overflow.store(true, .monotonic);
            return;
        }
    } else if (verify == null) {
        // Everything else this reader signs: a follow, a mute, a like, a relay
        // list. Tracked so that a write which acks NO relay is retried and
        // counted like a note, instead of being published once and forgotten.
        //
        // Best effort, deliberately. The refusal above is right for a note,
        // whose text the reader would otherwise lose with nothing tracking it.
        // A follow is not that: refusing to publish it because the queue is
        // full would turn a full queue into silently dropped writes, which is
        // worse than an untracked publish and is a failure this app did not
        // have before.
        _ = enqueueOutbox(ev.id, ev.pubkey, nowSeconds(), route);
    }
    notePrivateBookmarkPublished(ev);
    // A test drives the write path, not the network. Its pool names hosts that
    // do not resolve, and a detached dial thread for one of those outlives the
    // test that started it and can take the process down on the way out, which
    // reads as a failing suite with no failing assertion. Comptime, so the
    // shipped binary has no branch here at all.
    if (builtin.is_test) return;
    const thread = std.Thread.spawn(.{}, publishWorker, .{ gpa, ev, route }) catch {
        // No thread: the note stays queued and the next drain will carry it.
        return;
    };
    thread.detach();
}

/// One publish walk for `ev`, with the queue updated around it.
pub fn publishWorker(gpa: std.mem.Allocator, ev: nostr.event.Event, route: PlaceRoute) void {
    markOutboxSending(ev.id, true);
    publishEvent(gpa, ev, route);
    markOutboxSending(ev.id, false);
}

pub fn markOutboxSending(id: [32]u8, sending: bool) void {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return;
    e.sending = sending;
    if (!sending) e.rounds +|= 1;
    _ = outbox.g_outbox_rev.fetchAdd(1, .monotonic);
}

/// One failed publish round, the way `markOutboxSending(false)` records it.
pub fn markOutboxRoundForTest(id: [32]u8) void {
    markOutboxSending(id, true);
    markOutboxSending(id, false);
}
/// Drives one helper sign the way `signAndPublish` does, without needing a live
/// daemon behind it. The fetch itself goes nowhere in a test; what is under test
/// is what happens to the note when it does not come back.
/// Drives the whole post, from the composer down through the signer dispatch.
/// The dispatch is the part that mattered: it forwarded `restorable` to the
/// bunker and dropped it on the way to the built-in signer, so the flag arriving
/// intact is not something a test of `requestHelperSign` alone can see.
pub fn submitPostForTest(model: *Model, fx: *Effects) bool {
    return submitPost(model, fx, null);
}
pub fn dupeTagsForTest(gpa: std.mem.Allocator, tags: []const nostr.event.Tag) ?[]const nostr.event.Tag {
    return dupeTags(gpa, tags);
}

pub fn contentTagsForTest(gpa: std.mem.Allocator, content: []const u8) []const nostr.event.Tag {
    return contentTags(gpa, content, &.{}, &.{});
}
pub fn markRepostedByMeForTest(note_id: i64) void {
    markRepostedByMe(note_id);
}
/// Publishes one event the way any press does, so a test can ask what actually
/// went out rather than what a helper built.
pub fn signAndPublishForTest(fx: *Effects, created: i64, kind: u16, tags: []const nostr.event.Tag, content: []const u8) void {
    const gpa = std.heap.page_allocator;
    const owned = gpa.dupe(u8, content) catch return;
    signAndPublish(fx, gpa, created, kind, tags, owned, false, .none, null);
}

/// The same, carrying what the press changed, as every real write does.
pub fn signAndPublishWithUndoForTest(fx: *Effects, created: i64, kind: u16, content: []const u8, undo: PendingUndo) void {
    const gpa = std.heap.page_allocator;
    const owned = gpa.dupe(u8, content) catch return;
    signAndPublish(fx, gpa, created, kind, &.{}, owned, false, undo, null);
}
pub fn replyHeldForTest() bool {
    return g_reply_due_s != 0;
}

pub fn holdReplyForTest(now_s: i64) void {
    g_reply_due_s = now_s + (if (g_post_delay_s == 0) @as(i64, 5) else g_post_delay_s);
}

pub fn postDelayForTest() i64 {
    return g_post_delay_s;
}
pub fn setPostDelayForTest(seconds: i64) void {
    g_post_delay_s = seconds;
}

pub fn postHeldForTest() bool {
    return g_post_due_s != 0;
}

pub fn holdPostForTest(now_s: i64) void {
    g_post_due_s = now_s + g_post_delay_s;
}
pub fn ingestAndPublishForTest(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    ingestAndPublish(gpa, ev, null, .none);
}
/// The bunker's door: an event signed elsewhere, checked on the way in.
pub fn ingestAndPublishVerifiedForTest(gpa: std.mem.Allocator, ev: nostr.event.Event, signer: nostr.keys.Signer) void {
    ingestAndPublish(gpa, ev, signer, .none);
}
pub fn notifiedByForTest(content: []const u8, out: *[max_mention_tags][32]u8) usize {
    return notifiedBy(content, out);
}

pub fn deletableTargetKindForTest(model: *Model, note_id: i64) ?u16 {
    const t = deletableTarget(model, note_id) orelse return null;
    return t.kind;
}

pub fn drivePendingIntentForTest(model: *Model, fx: *Effects) void {
    drivePendingIntent(model, fx);
}
pub fn countOutboxRoundForTest(id: [32]u8) void {
    markOutboxSending(id, true);
    markOutboxSending(id, false);
}
/// What the route a held note is carrying names, for the test: the relay list a
/// publish walk would actually dial, taken from the value and not from whatever
/// room happens to be open when it is read.
pub fn heldRouteRelaysForTest(out: [][]const u8) usize {
    var n: usize = 0;
    while (n < g_held_route.len and n < out.len) : (n += 1) out[n] = g_held_route.url(n);
    return n;
}

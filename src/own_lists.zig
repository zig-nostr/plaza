//! Whether the reader's own lists can be written: what their relays have answered, and the consent to start one from nothing.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const blossom = @import("blossom.zig");
const follows = @import("follows.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const activePubkey = main.activePubkey;
const blossom_list_kind = main.blossom_list_kind;
const bookmark_list_kind = main.bookmark_list_kind;
const bookmarksAreOwned = main.bookmarksAreOwned;
const canWriteFollows = main.canWriteFollows;
const contact_list_kind = main.contact_list_kind;
const copyBounded = main.copyBounded;
const isRelayUrl = main.isRelayUrl;
const lockOwnProfile = main.lockOwnProfile;
const max_relays = main.max_relays;
const mute_list_kind = main.mute_list_kind;
const mutesAreOwned = main.mutesAreOwned;
const nowSeconds = main.nowSeconds;
const ownRecordExists = main.ownRecordExists;
const relayAt = main.relayAt;
const relaySlots = main.relaySlots;
const relayUrlEql = main.relayUrlEql;
const unlockOwnProfile = main.unlockOwnProfile;

/// Why the follow control is unavailable, in the reader's terms. An unexplained
/// dead button is the failure mode of every client that got the safety right and
/// the honesty wrong.
pub fn followBlockedReason() ?[]const u8 {
    if (activePubkey() == null) return null;
    if (canWriteFollows()) return null;
    return switch (ownListsRead()) {
        .reading => "Looking for your follow list…",
        .incomplete => "Could not read your follow list. Try again",
        // Every relay finished and none has one: the press asks first, so the
        // control is live. See `needsFreshConsent`.
        .none_found => null,
    };
}

/// Why muting is unavailable right now, in the words the button shows under it.
///
/// The same rule as following, and for a worse consequence: a mute list is
/// replaceable, so writing one this app has not read back would replace whatever
/// the reader really has with a list of one name. A key minted here is the one
/// case where having none is a fact rather than a read that has not landed.
pub fn muteBlockedReason() ?[]const u8 {
    if (activePubkey() == null) return null;
    if (noHistoryKnown(.mutes)) return null;
    // Free, and the right question. `mutesAreOwned` is true exactly when this
    // account's own kind:10000 has been read, which is what the gate in
    // `writeMute` decides on. No store query per frame: the button asks this,
    // and `writeMute` asks the read itself, which is the lesson the follow path
    // paid for (deciding a write from a SECOND query let a transient failure
    // answer "they have no list").
    if (mutesAreOwned()) return null;
    return switch (ownListsRead()) {
        .reading => "Looking for your mute list…",
        .incomplete => "Could not read your mute list. Try again",
        .none_found => null,
    };
}

/// Why the bookmark rows are unavailable, in the words the row shows, or null
/// when the list is read (or provably empty). Same rule as the mute list.
pub fn bookmarkBlockedReason() ?[]const u8 {
    if (activePubkey() == null) return null;
    if (noHistoryKnown(.bookmarks)) return null;
    if (bookmarksAreOwned()) return null;
    return switch (ownListsRead()) {
        .reading => "Still fetching your bookmarks",
        .incomplete => "Could not read your bookmarks. Try again",
        .none_found => null,
    };
}

/// Whether this account's own kind:3 is in the local store, REMEMBERED.
///
/// This is asked from view code. `followBlockedReason` calls it, `noteContextItems`
/// calls that for the follow line in every post's menu, and the feed builds a card
/// for every note on screen, every frame. The honest answer used to be
/// `ownRecordJson`, which runs an LMDB query and then duplicates the whole record:
/// every tag, every field, each one its own `page_allocator` call, which is its own
/// `mmap`. Freeing it is an `munmap` apiece.
///
/// With three hundred follows that is roughly six hundred syscalls per card per
/// frame. A stack sample of a scroll put 1437 of 1462 app-side samples inside
/// `noteContextItems`, almost all of them here, and the frame rebuild measured 22.7
/// ms against an 8.3 ms frame: the feed scrolled at about nine frames a second, and
/// it got worse the more people you followed, which is exactly backwards.
///
/// The answer changes only when a kind:3 for this account reaches the store, and
/// `plazaIngest` is the one door for that, so it is recorded there instead of
/// re-derived sixty times a frame. Keyed by pubkey, so an identity change misses
/// rather than inherits.
const OwnListMemo = enum { unknown, absent, present };
var g_own_contact_list_memo: OwnListMemo = .unknown;
var g_own_contact_list_memo_for: ?[32]u8 = null;

pub fn haveOwnContactList() bool {
    const pk = activePubkey() orelse return false;
    if (g_own_contact_list_memo_for) |who| {
        if (std.mem.eql(u8, &who, &pk) and g_own_contact_list_memo != .unknown) {
            return g_own_contact_list_memo == .present;
        }
    }
    // The miss path asks whether a record EXISTS, which reads one row and copies
    // nothing. It is `ownRecordJson` that was expensive, not the query.
    const present = ownRecordExists(contact_list_kind);
    g_own_contact_list_memo_for = pk;
    g_own_contact_list_memo = if (present) .present else .absent;
    return present;
}

/// Records that this account's contact list is now in the store. Called from the
/// ingest door, which is the only way one gets there.
pub fn noteOwnContactListStored(pk: [32]u8) void {
    g_own_contact_list_memo_for = pk;
    g_own_contact_list_memo = .present;
}

/// Forgets what was remembered about this account's own lists. An identity change
/// misses on the pubkey anyway; this is for the paths that want it gone now.
pub fn forgetOwnListMemo() void {
    g_own_contact_list_memo = .unknown;
    g_own_contact_list_memo_for = null;
}
/// Whether EVERY relay this reader can read from has answered about this
/// account's contact list, and none of them had one.
///
/// This no longer authorizes anything. It drives the "still looking" line only,
/// because relay silence is not evidence about an account this app did not
/// create: see `canWriteFollows`.
pub fn contactsConfirmedAbsent() bool {
    const pk = activePubkey() orelse return false;
    const counts = relayAnswers(pk);
    if (counts.readable == 0 or counts.answered == 0) return false;
    return counts.answered >= counts.readable;
}

/// Whether every relay that could hold this account's own lists has finished
/// answering without sending one: every relay Plaza reads from, AND every relay
/// the reader's own kind:10002 says they write to.
///
/// The second half is the one that matters. NIP-65 puts a reader's lists on
/// their WRITE relays, and the pool Plaza reads from can be anything: the
/// bootstrap relays on a cold import, a list of eight cut from a longer one, a
/// relay the reader marked write-only so it is never asked. Silence from those
/// is silence from the wrong place. Jumble asks the same relays for the same
/// reason (`client.service.ts:1436`, the author's write relays first). An
/// unknown relay list means it is not known where the lists live, which is
/// never "finished".
pub fn ownRelaysAllFinished() bool {
    const pk = activePubkey() orelse return false;
    const counts = relayAnswers(pk);
    if (counts.readable == 0 or counts.answered < counts.readable) return false;
    return counts.outbox == .read;
}
/// How many of the relays this reader reads from have finished answering about
/// their own records, how many there are, and whether the reader's own write
/// relays are among them.
const RelayAnswers = struct { answered: usize, readable: usize, outbox: OutboxRead = .unknown };

/// Where the reader's own write relays stand against the pool.
const OutboxRead = enum {
    /// No kind:10002 for this account has been seen, or it names no relay they
    /// write to: nobody can say where their lists are kept.
    unknown,
    /// At least one relay they write to is not one Plaza reads from (not in the
    /// pool, write-only here, or past what the pool can hold).
    not_read,
    /// Every relay they write to is one Plaza reads from.
    read,
};

fn relayAnswers(pk: [32]u8) RelayAnswers {
    lockOwnProfile();
    defer unlockOwnProfile();
    const mine = if (main.g_own_contacts_asked_for) |asked| std.mem.eql(u8, &asked, &pk) else false;
    var out = RelayAnswers{ .answered = 0, .readable = 0 };
    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse continue;
        if (!e.read) continue;
        out.readable += 1;
        if (mine and answeredFromSeat(i, e.url())) out.answered += 1;
    }
    out.outbox = outboxRead(pk);
    return out;
}

/// The relays this reader's own newest kind:10002 says they write to, recorded
/// as it arrives and keyed by the account it came from. Guarded by the
/// own-profile lock: an ingest thread writes it, the UI thread reads it.
const OwnOutbox = struct {
    of: ?[32]u8 = null,
    created_at: i64 = 0,
    urls: [max_relays][96]u8 = undefined,
    lens: [max_relays]u8 = [_]u8{0} ** max_relays,
    len: usize = 0,
    /// A write relay Plaza cannot ask: more of them than the pool has seats, or
    /// an address it cannot dial. The read can never be called finished.
    unaskable: bool = false,
};
pub var g_own_outbox: OwnOutbox = .{};

/// Records the write relays of the reader's own kind:10002. Newer replaces older;
/// a list about another account, or one not newer than what is held, is ignored.
pub fn noteOwnOutbox(ev: nostr.event.Event) void {
    var next: OwnOutbox = .{ .of = ev.pubkey, .created_at = ev.created_at };
    for (ev.tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "r")) continue;
        // Same reading as `applyOwnRelayList`: only `read` narrows a relay away
        // from writing, and an unknown marker narrows nothing.
        if (tag.len >= 3 and std.mem.eql(u8, tag[2], "read")) continue;
        const url = std.mem.trim(u8, tag[1], " \t\r\n");
        if (!isRelayUrl(url) or url.len > 96) {
            next.unaskable = true;
            continue;
        }
        var dup = false;
        for (0..next.len) |j| {
            if (relayUrlEql(next.urls[j][0..next.lens[j]], url)) dup = true;
        }
        if (dup) continue;
        if (next.len >= max_relays) {
            next.unaskable = true;
            continue;
        }
        @memcpy(next.urls[next.len][0..url.len], url);
        next.lens[next.len] = @intCast(url.len);
        next.len += 1;
    }
    lockOwnProfile();
    defer unlockOwnProfile();
    if (g_own_outbox.of) |held| {
        if (std.mem.eql(u8, &held, &ev.pubkey) and ev.created_at <= g_own_outbox.created_at) return;
    }
    g_own_outbox = next;
}

/// Called with the own-profile lock held.
fn outboxRead(pk: [32]u8) OutboxRead {
    const of = g_own_outbox.of orelse return .unknown;
    if (!std.mem.eql(u8, &of, &pk)) return .unknown;
    if (g_own_outbox.len == 0 and !g_own_outbox.unaskable) return .unknown;
    if (g_own_outbox.unaskable) return .not_read;
    for (0..g_own_outbox.len) |j| {
        const want = g_own_outbox.urls[j][0..g_own_outbox.lens[j]];
        var found = false;
        for (0..relaySlots()) |i| {
            const e = relayAt(i) orelse continue;
            if (e.read and relayUrlEql(e.url(), want)) found = true;
        }
        if (!found) return .not_read;
    }
    return .read;
}

/// How long Plaza keeps saying it is reading the reader's own lists before it
/// says it could not. A relay can accept the subscription and then never finish
/// it, and "reading" with no end is a state the reader cannot do anything about.
const own_lists_wait_s: i64 = 15;

/// Where the read of this account's own follow, mute and bookmark lists stands
/// when the list is not in the local store. One REQ asks every relay for all of
/// them, so one answer from a relay covers all three.
pub const OwnListsRead = enum {
    /// Relays are still answering and the wait has not run out.
    reading,
    /// The wait ran out and some relay has not finished. Not hearing back is not
    /// the same as being told there is nothing, so nothing is written.
    incomplete,
    /// Every relay this reader reads from has finished and none sent the list.
    none_found,
};

pub var g_own_lists_since: i64 = 0;
pub var g_own_lists_since_for: ?[32]u8 = null;

/// Read from view code. The clock starts the first time this account asks, so
/// there is no sign-in path that has to remember to start it.
pub fn ownListsRead() OwnListsRead {
    const pk = activePubkey() orelse return .reading;
    if (ownRelaysAllFinished()) return .none_found;
    const now = nowSeconds();
    if (g_own_lists_since_for) |who| {
        if (!std.mem.eql(u8, &who, &pk)) g_own_lists_since_for = null;
    }
    if (g_own_lists_since_for == null) {
        g_own_lists_since = now;
        g_own_lists_since_for = pk;
    }
    return if (now - g_own_lists_since >= own_lists_wait_s) .incomplete else .reading;
}

/// Asks every relay again what it holds for this reader. The answers already
/// counted are dropped first: they were about the question as it stood, and a
/// retry that kept them would report "done" without having heard anything new.
pub fn retryOwnListsRead() void {
    const pk = activePubkey() orelse return;
    {
        lockOwnProfile();
        defer unlockOwnProfile();
        main.g_own_contacts_asked_for = pk;
        g_contacts_answered_by = [_]bool{false} ** max_relays;
    }
    g_own_lists_since = nowSeconds();
    g_own_lists_since_for = pk;
    // The open subscriptions re-ask on this counter, which is what makes every
    // relay send its stored answer (and its end-of-stored-events) again.
    _ = follows.g_follow_gen.fetchAdd(1, .monotonic);
}

/// The lists a write can replace.
pub const ListKind = enum { follows, mutes, bookmarks, profile, media_servers };

/// Which lists the reader has said, with every relay finished, are new for this
/// account. Keyed by the pubkey it was said about, like every conclusion about
/// the reader's own records, and dropped on any identity change.
var g_fresh_for: ?[32]u8 = null;
var g_fresh: [@typeInfo(ListKind).@"enum".fields.len]bool = @splat(false);

pub fn forgetFresh() void {
    g_fresh_for = null;
    g_fresh = @splat(false);
}

pub fn startedFresh(kind: ListKind) bool {
    const pk = activePubkey() orelse return false;
    const who = g_fresh_for orelse return false;
    if (!std.mem.eql(u8, &who, &pk) or !g_fresh[@intFromEnum(kind)]) return false;
    // The yes was about the relays as they stood. A retry, a relay added or the
    // reader's own relay list arriving since has reopened the question.
    return ownRelaysAllFinished();
}

/// Spends the reader's yes on the write that starts the list. One yes starts one
/// list: once it exists, every later write splices onto it, and a later read
/// that comes back empty (a store error, a record not yet back from a bunker) is
/// refused rather than read as "start again from nothing".
pub fn takeFresh(kind: ListKind) bool {
    if (!startedFresh(kind)) return false;
    g_fresh[@intFromEnum(kind)] = false;
    return true;
}

/// Whether having no `kind` list is a fact about this account rather than a read
/// that did not land: the key was made here, or the reader said so after every
/// relay finished without one.
pub fn noHistoryKnown(kind: ListKind) bool {
    return g_identity_minted_here or startedFresh(kind);
}

/// Records the reader's answer to "start a new list?". Refused unless every relay
/// has still finished without sending one, so a question left open on screen
/// while the relays changed (a retry, a relay added) cannot be answered with a
/// yes that no longer describes anything.
///
/// Set here, on the confirmation, and never on the press that asked for it.
pub fn confirmStartFresh(kind: ListKind) bool {
    const pk = activePubkey() orelse return false;
    if (!ownRelaysAllFinished()) return false;
    if (g_fresh_for) |who| {
        if (!std.mem.eql(u8, &who, &pk)) g_fresh = @splat(false);
    }
    g_fresh_for = pk;
    g_fresh[@intFromEnum(kind)] = true;
    return true;
}

/// Whether a write of `kind` has to be asked about first: no copy of the list is
/// held, nothing says the account is new, and every relay has finished without
/// one. While relays are still answering (or stopped answering) there is nothing
/// to ask about, because the answer would be a guess; the control says so instead.
pub fn needsFreshConsent(kind: ListKind) bool {
    if (activePubkey() == null) return false;
    if (noHistoryKnown(kind)) return false;
    if (listHeld(kind)) return false;
    return ownListsRead() == .none_found;
}

/// Whether a copy of `kind` is held here, so a write splices onto it.
pub fn listHeld(kind: ListKind) bool {
    return switch (kind) {
        .follows => follows.g_pending_follow_tags != null or haveOwnContactList(),
        .mutes => ownRecordExists(mute_list_kind),
        .bookmarks => ownRecordExists(bookmark_list_kind),
        .profile => ownRecordExists(0),
        .media_servers => ownRecordExists(blossom_list_kind),
    };
}
/// Says how far the read got, in the reader's terms: how many of the relays
/// they read from have finished or, once they all have, which relays Plaza is
/// still missing. For the line under a control that is waiting.
pub fn ownListsProgress(ui: *AppUi) []const u8 {
    const pk = activePubkey() orelse return "";
    const counts = relayAnswers(pk);
    if (counts.readable == 0) return "No relay is set to read from.";
    if (counts.answered < counts.readable) {
        return ui.fmt("{d} of {d} {s} finished answering.", .{ counts.answered, counts.readable, if (counts.readable == 1) "relay" else "relays" });
    }
    return switch (counts.outbox) {
        .unknown => "Plaza has not found your relay list, so it cannot tell which relays keep your lists.",
        .not_read => "Plaza does not read from every relay you write to, which is where your lists are kept.",
        .read => "",
    };
}

/// What the reader can do about a read that did not finish, beyond asking again.
pub fn ownListsAdvice() []const u8 {
    const pk = activePubkey() orelse return "";
    const counts = relayAnswers(pk);
    if (counts.answered < counts.readable) return " A relay that is down can be removed in Settings.";
    return switch (counts.outbox) {
        .not_read => " Those relays can be added, or set to read, in Settings.",
        .unknown, .read => "",
    };
}

/// Which relays have answered about this account's contact list.
pub var g_contacts_answered_by = [_]bool{false} ** max_relays;
/// And the address each one had when it answered. A slot is a seat, not a
/// relay: adopting the reader's own relay list, or removing a relay and adding
/// another, seats a different relay at the same index, and an answer from the
/// one that sat there before says nothing about the one sitting there now. The
/// reader's own relays land in exactly the seats the bootstrap relays answered
/// from, so without this they counted as finished before they were asked.
var g_contacts_answered_url: [max_relays][96]u8 = undefined;
var g_contacts_answered_url_len = [_]u8{0} ** max_relays;

/// Whether the signed-in key was MINTED by this app, as opposed to imported.
///
/// This is the fact that decides whether creating a contact list from nothing is
/// safe, and it is the one piece of evidence that is not a guess. A key this app
/// made moments ago provably has no history anywhere. A key the reader pasted in
/// has a past this app knows nothing about, and no amount of relay silence turns
/// that into knowledge: on a cold import the relays being asked are the app's
/// own bootstrap five, which may hold none of the reader's real relays, so five
/// clean answers can coexist with eight hundred follows sitting somewhere else.
pub var g_identity_minted_here = false;
/// Records that relay `index`, dialed at `url`, reached the end of what it holds
/// for this account without producing a contact list.
pub fn noteContactsAnsweredBy(index: usize, url: []const u8, pk: [32]u8) void {
    if (index >= max_relays) return;
    if (url.len == 0 or url.len > g_contacts_answered_url[index].len) return;
    lockOwnProfile();
    defer unlockOwnProfile();
    if (main.g_own_contacts_asked_for) |asked| {
        if (!std.mem.eql(u8, &asked, &pk)) {
            g_contacts_answered_by = [_]bool{false} ** max_relays;
        }
    }
    main.g_own_contacts_asked_for = pk;
    g_contacts_answered_by[index] = true;
    @memcpy(g_contacts_answered_url[index][0..url.len], url);
    g_contacts_answered_url_len[index] = @intCast(url.len);
}

/// Whether the answer recorded for seat `i` came from the relay sitting there
/// now. Called with the own-profile lock held.
fn answeredFromSeat(i: usize, now_url: []const u8) bool {
    if (!g_contacts_answered_by[i]) return false;
    return relayUrlEql(g_contacts_answered_url[i][0..g_contacts_answered_url_len[i]], now_url);
}
/// Holds a write that would start a list from nothing and puts the question to
/// the reader. Returns whether it did, so the caller stops there.
pub fn askFreshFirst(model: *Model, ask: FreshAsk) bool {
    const me = activePubkey() orelse return false;
    if (!needsFreshConsent(ask.kind())) return false;
    var held = ask;
    held.of = me;
    model.fresh_ask = held;
    return true;
}

/// What a refused list write says, by how far the read of that list got. The
/// refusal is the same every time (nothing was changed); what the reader can do
/// about it is not.
pub fn noListToast(comptime what: []const u8) []const u8 {
    return noListToastIn(what, ownListsRead());
}

pub fn noListToastIn(comptime what: []const u8, read: OwnListsRead) []const u8 {
    return switch (read) {
        .reading => "Still reading your " ++ what ++ ". Try again soon.",
        .incomplete => "Can't read your " ++ what ++ ". Nothing changed.",
        .none_found => "No " ++ what ++ " on your relays. Nothing changed.",
    };
}
/// What the Edit profile sheet knows about the profile it is editing.
///
/// The distinction that matters is `fetching` versus `absent`. "The store has no
/// kind:0 for me" means either that this account has never had a profile or that
/// nobody has answered yet, and those two look identical from here. Publishing
/// under the second reading REPLACES a real profile with whatever three fields
/// this app models, which is how somebody's lightning address disappears. So the
/// sheet asks every read relay first, and only calls it `absent` once they have
/// all answered.
/// What is waiting on the reader's answer to "start a new list?".
pub const FreshAsk = struct {
    action: Action,
    /// The account the question was put about. A yes is never spent on another.
    of: [32]u8 = [_]u8{0} ** 32,
    /// The person to follow or mute.
    who: [32]u8 = [_]u8{0} ** 32,
    /// The note to bookmark.
    note_id: i64 = 0,
    /// The media server to add, normalized.
    server_buf: [blossom.max_server_len]u8 = undefined,
    server_len: u8 = 0,

    pub const Action = enum { follow, mute, bookmark, bookmark_privately, add_media_server };

    pub fn kind(self: FreshAsk) ListKind {
        return switch (self.action) {
            .follow => .follows,
            .mute => .mutes,
            .bookmark, .bookmark_privately => .bookmarks,
            .add_media_server => .media_servers,
        };
    }

    pub fn mediaServer(url: []const u8) FreshAsk {
        var ask = FreshAsk{ .action = .add_media_server };
        ask.server_len = @intCast(copyBounded(&ask.server_buf, url));
        return ask;
    }

    pub fn server(self: *const FreshAsk) []const u8 {
        return self.server_buf[0..self.server_len];
    }
};

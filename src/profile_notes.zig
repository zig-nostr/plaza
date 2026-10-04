//! A person's notes, page by page: which relays to ask, and when the end is reached.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const navigation = @import("navigation.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Model = main.Model;
const comment_kind = main.comment_kind;
const contact_list_kind = main.contact_list_kind;
const countEngagement = main.countEngagement;
const engagementFilter = main.engagementFilter;
const engagement_watch_cap = main.engagement_watch_cap;
const feedEndLatches = main.feedEndLatches;
const hexLower = main.hexLower;
const max_relays = main.max_relays;
const noteIdOf = main.noteIdOf;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const outbox_relays_per_author = main.outbox_relays_per_author;
const plazaIngestFrom = main.plazaIngestFrom;
const profile_autofill_max = main.profile_autofill_max;
const profile_fetch_messages = main.profile_fetch_messages;
const profile_fill_rows = main.profile_fill_rows;
const profile_notes_max = main.profile_notes_max;
const profile_page = main.profile_page;
const profile_relay_page = main.profile_relay_page;
const relayFetchAllowed = main.relayFetchAllowed;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const relayUrlEql = main.relayUrlEql;
const relay_list_kind = main.relay_list_kind;
const releaseOneShot = main.releaseOneShot;
const selectWriteRelays = main.selectWriteRelays;
const watchOneShot = main.watchOneShot;
const writeTagUrls = main.writeTagUrls;

/// What one pass over the relays learned, for deciding whether history ended.
const ProfileRound = struct {
    /// Relays that took the subscription.
    asked: usize = 0,
    /// Relays that answered it to the end.
    answered: usize = 0,
    /// Notes that were new to the store.
    added: usize = 0,
    /// Notes the relays returned that are strictly older than the cursor asked
    /// from. This, not `added`, is what says whether there was anything to find:
    /// a note can be a duplicate because another fetch stored it a moment
    /// earlier, which says nothing about whether history has ended.
    older: usize = 0,
    /// How far back this round brought their notes without leaving a hole (see
    /// `roundReach`). Null when it brought none.
    reach: ?i64 = null,
};

/// One note a round brought: when it was written, and which one it is.
pub const ProfileSeen = struct { at: i64, key: i64 };

/// Where a round's notes stop being complete. Each relay sent its newest page
/// below the cursor, and below the oldest note of the shortest page another
/// relay may hold notes that nobody has sent yet. So the cut is the
/// `profile_relay_page`-th newest distinct note across them all, and every note
/// above it is in hand from every relay asked. When there were fewer than a page,
/// every relay sent all it had, and the oldest is the cut.
///
/// Jumble cuts its merged page the same way: it sorts what the relays sent and
/// keeps `limit` of it before taking the oldest as the next cursor
/// (services/client.service.ts:749-755).
pub fn roundReach(seen: []ProfileSeen) ?i64 {
    if (seen.len == 0) return null;
    std.mem.sort(ProfileSeen, seen, {}, struct {
        fn newer(_: void, a: ProfileSeen, b: ProfileSeen) bool {
            if (a.at != b.at) return a.at > b.at;
            return a.key < b.key;
        }
    }.newer);
    var distinct: usize = 0;
    var cut = seen[0].at;
    for (seen, 0..) |note, i| {
        if (i > 0 and note.key == seen[i - 1].key and note.at == seen[i - 1].at) continue;
        distinct += 1;
        cut = note.at;
        if (distinct == profile_relay_page) break;
    }
    return cut;
}
/// The most connections one older-notes round makes: the author's own write
/// relays, then the reader's read relays.
pub const profile_round_targets = outbox_relays_per_author + max_relays;

/// The write relays a relay list names, as owned strings, in the order the list
/// gives them. The same selection the feed's routing makes, from the same
/// function, so the two cannot disagree about where somebody publishes.
pub fn writeRelaysOf(ev: nostr.event.Event, out: *[outbox_relays_per_author][96]u8, lens: *[outbox_relays_per_author]u8) usize {
    var raw: [32][]const u8 = undefined;
    var selected: [outbox_relays_per_author][]const u8 = undefined;
    const chosen = selectWriteRelays(raw[0..writeTagUrls(ev, &raw)], &selected);
    for (selected[0..chosen], 0..) |url, i| {
        @memcpy(out[i][0..url.len], url);
        lens[i] = @intCast(url.len);
    }
    return chosen;
}
/// Where to ask for somebody's older notes: the relays they publish to, which
/// is where the outbox model says their notes are, then the reader's own read
/// relays. Jumble does the same, `relayList.write` followed by its defaults
/// (Profile/ProfileFeed.tsx:140).
///
/// The author's list is read from the store, so it is whatever the routing has
/// already fetched, and a person whose list has not arrived is asked of the
/// reader's relays alone, which is also what the first page does.
pub fn profileTargets(pubkey: [32]u8, out: *[profile_round_targets][96]u8, lens: *[profile_round_targets]u8) usize {
    var n: usize = 0;
    if (main.g_store) |store| {
        const kinds = [_]u16{relay_list_kind};
        const authors = [_][32]u8{pubkey};
        if (store.query(std.heap.page_allocator, .{ .authors = &authors, .kinds = &kinds, .limit = 1 })) |res| {
            var result = res;
            defer result.deinit();
            if (result.events.len > 0) {
                var own: [outbox_relays_per_author][96]u8 = undefined;
                var own_lens: [outbox_relays_per_author]u8 = undefined;
                const got = writeRelaysOf(result.events[0], &own, &own_lens);
                for (0..got) |i| {
                    @memcpy(out[n][0..own_lens[i]], own[i][0..own_lens[i]]);
                    lens[n] = own_lens[i];
                    n += 1;
                }
            }
        } else |_| {}
    }
    for (0..relaySlots()) |ri| {
        if (n >= out.len) break;
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        if (!entry.read) continue;
        var seen = false;
        for (0..n) |i| {
            if (relayUrlEql(out[i][0..lens[i]], entry.url)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        @memcpy(out[n][0..entry.url.len], entry.url);
        lens[n] = @intCast(entry.url.len);
        n += 1;
    }
    return n;
}
/// The filter that asks for a person's notes older than `until`. `until` is
/// inclusive in NIP-01, so the note it was taken from comes back once and the
/// store drops it as a duplicate; asking for `until - 1` instead would lose
/// every other note written in that same second.
pub fn buildProfileOlderFilter(authors: []const [32]u8, until: i64) nostr.filter.Filter {
    return .{
        .authors = authors,
        .kinds = &profile_note_kinds,
        .until = until,
        .limit = profile_relay_page,
    };
}

const profile_note_kinds = [_]u16{ 1, comment_kind };

/// The filter for a person's newest notes, the page their profile opens with.
/// Comments as well as notes, the same kinds an older page asks for: the next
/// page starts where this one reached, so a kind left out here is a kind
/// nothing ever asks for in the newest stretch of somebody's history.
pub fn buildProfileNewestFilter(authors: []const [32]u8) nostr.filter.Filter {
    return .{ .authors = authors, .kinds = &profile_note_kinds, .limit = profile_relay_page };
}

/// One pass over the relays for a person's notes. With no `until` it is the
/// page a profile opens with: the newest notes, their profile and contact list,
/// from the reader's read relays. With one it is the next page back, from the
/// relays the person publishes to as well.
///
/// Either way a second subscription then collects the reactions on what came
/// back, into the table every row reads its counts from.
pub fn profileRound(pubkey: [32]u8, until: ?i64) ProfileRound {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var round = ProfileRound{};
    const authors = [_][32]u8{pubkey};
    // Their profile too: the screen needs an about, a banner and a lud16, none
    // of which the name-and-face cache models.
    const meta_kinds = [_]u16{ 0, contact_list_kind };
    const first_filters = [_]nostr.filter.Filter{
        buildProfileNewestFilter(&authors),
        .{ .authors = &authors, .kinds = &meta_kinds, .limit = 2 },
    };
    // Every note the round brought, for where it reached. A relay that sends more
    // than it was asked for has the rest left out, which only makes the cut newer.
    var brought: [profile_round_targets * profile_relay_page]ProfileSeen = undefined;
    var brought_len: usize = 0;
    const older_filters = [_]nostr.filter.Filter{buildProfileOlderFilter(&authors, until orelse 0)};
    const filters: []const nostr.filter.Filter = if (until != null) &older_filters else &first_filters;

    var targets: [profile_round_targets][96]u8 = undefined;
    var target_lens: [profile_round_targets]u8 = undefined;
    var target_count: usize = 0;
    if (until != null) {
        target_count = profileTargets(pubkey, &targets, &target_lens);
    } else {
        for (0..relaySlots()) |ri| {
            var url_buf: [96]u8 = undefined;
            const entry = relaySnapshot(ri, &url_buf) orelse continue;
            if (!entry.read or target_count >= targets.len) continue;
            @memcpy(targets[target_count][0..entry.url.len], entry.url);
            target_lens[target_count] = @intCast(entry.url.len);
            target_count += 1;
        }
    }

    for (0..target_count) |ti| {
        const target_url = targets[ti][0..target_lens[ti]];
        var relay = nostr.relay.dial(gpa, io, target_url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse continue;
        defer releaseOneShot(watched);
        relay.subscribe(if (until != null) "plaza-person-older" else "plaza-person", filters) catch continue;
        round.asked += 1;
        var relay_older: usize = 0;

        var ids: [engagement_watch_cap][64]u8 = undefined;
        var watch: [engagement_watch_cap]i64 = undefined;
        var watch_len: usize = 0;
        var id_count: usize = 0;
        var engagement_open = false;
        var seen: usize = 0;
        // Bounded, because `relay.receive()` has no deadline and a relay that
        // accepts a subscription and then goes quiet would hold this thread for
        // the life of the process.
        while (seen < profile_fetch_messages) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    // Phase 2's answers are REACTIONS, and a reaction that is
                    // only stored changes no count on any row: the table the
                    // rows read is filled by `countEngagement`, which is the
                    // whole reason phase 2 exists.
                    if (engagement_open) {
                        if (nostr.event.verify(gpa, signer, e.event) catch false)
                            countEngagement(e.event, watch[0..watch_len]);
                        continue;
                    }
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, target_url) catch continue;
                    if (result == .invalid) continue;
                    // Theirs, and a note: a relay can send anything down any
                    // subscription, and somebody else's note says nothing about
                    // how far back this person's history goes.
                    const theirs = std.mem.eql(u8, &e.event.pubkey, &pubkey);
                    if (theirs and (e.event.kind == 1 or e.event.kind == comment_kind)) {
                        if (result == .added) round.added += 1;
                        // `until` is inclusive, so the note the cursor came from
                        // comes back. It is not news, and counting it would let
                        // a page that found nothing older read as progress.
                        const below = if (until) |cursor| e.event.created_at < cursor else true;
                        if (below) {
                            if (until != null) {
                                round.older += 1;
                                relay_older += 1;
                            }
                            if (brought_len < brought.len) {
                                brought[brought_len] = .{ .at = e.event.created_at, .key = noteIdOf(e.event) };
                                brought_len += 1;
                            }
                        }
                    }
                    if (e.event.kind == 1 and id_count < ids.len) {
                        hexLower(&ids[id_count], e.event.id);
                        watch[watch_len] = noteIdOf(e.event);
                        watch_len += 1;
                        id_count += 1;
                    }
                },
                .eose => {
                    // "I have looked and that is all of it", which is the only
                    // message that lets an empty page mean the end.
                    if (!engagement_open) round.answered += 1;
                    if (engagement_open or id_count == 0) break;
                    engagement_open = true;
                    var evals: [engagement_watch_cap][]const u8 = undefined;
                    for (0..id_count) |i| evals[i] = &ids[i];
                    const eng_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = evals[0..id_count] }};
                    const eng_filters = [_]nostr.filter.Filter{engagementFilter(&eng_tags)};
                    relay.subscribe("plaza-person-engagement", &eng_filters) catch break;
                },
                .closed => break,
                else => continue,
            }
        }
        // A full page from one relay is the page, whether or not the store had
        // those notes already. The rest of the list is for the next time the
        // reader reaches the end. Counting only what was new to the store made a
        // page of notes the store already held dial every relay in the list.
        if (until != null and relay_older >= profile_relay_page) break;
    }
    round.reach = roundReach(brought[0..brought_len]);
    if (round.reach) |at| noteProfileReach(pubkey, at);
    return round;
}

// ---------------------------------------------------- a person's older notes
//
// The same shape as the feed's paging above, and for the same reasons: the
// store first, the relays only once the store has nothing older, one round at a
// time, and an end of history that only a relay answering "nothing older" can
// declare.

/// Whether an older-notes round is out, so a reader who keeps scrolling does not
/// stack one dial per relay per frame.
pub var g_profile_older_busy = std.atomic.Value(bool).init(false);
/// Whose history a round found the end of. A key rather than a flag, because a
/// round for one person can land after the reader has walked to another, and
/// "that is all of it" is only true of the person it was asked about.
pub var g_profile_end = std.atomic.Value(u64).init(0);
/// The last older-notes ask, recorded before the network is consulted so a test
/// (which never opens a socket) can see what would have been sent.
pub var g_profile_older_ask: ?ProfileOlderAsk = null;

pub const ProfileOlderAsk = struct { pubkey: [32]u8, until: i64 };

pub fn profileEndKey(pubkey: [32]u8) u64 {
    return std.mem.readInt(u64, pubkey[0..8], .big) | 1;
}

pub fn profileEndReached(pubkey: [32]u8) bool {
    return g_profile_end.load(.monotonic) == profileEndKey(pubkey);
}

pub fn resetProfileEnd() void {
    g_profile_end.store(0, .monotonic);
}
/// How far back the relays have brought the open person's notes on this visit:
/// the oldest cut any round has made (`roundReach`), the first page included.
///
/// The next page is asked from here, never from the oldest note in hand. The
/// store holds whatever any surface ever fetched, so beyond the run the relays
/// paged through it can hold one old note of theirs from a thread or a quote,
/// with a year of their history missing in between. Paging from that note
/// skipped the year, and since it was still the oldest note in hand on the next
/// visit, skipped it every time. Jumble pages from the refs its relays sent and
/// not from its cache (NoteList/index.tsx:519-523).
///
/// Written by the round's thread, read by the tick, so it is guarded. Only the
/// person the page is open on is recorded: a round for somebody the reader has
/// walked away from lands here as a no-op.
var g_profile_reach: struct { key: u64 = 0, at: i64 = no_profile_reach } = .{};
var g_profile_reach_lock = std.atomic.Value(bool).init(false);
const no_profile_reach = std.math.maxInt(i64);

fn lockProfileReach() void {
    while (g_profile_reach_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}

fn unlockProfileReach() void {
    g_profile_reach_lock.store(false, .release);
}

/// Starts recording for `pubkey`. A fresh visit forgets how far an earlier one
/// got, because the person may have written since; Back to the same person keeps
/// it, along with the depth the list was paged to.
pub fn armProfileReach(pubkey: [32]u8, fresh: bool) void {
    const key = profileEndKey(pubkey);
    lockProfileReach();
    defer unlockProfileReach();
    if (!fresh and g_profile_reach.key == key) return;
    g_profile_reach = .{ .key = key };
}

pub fn noteProfileReach(pubkey: [32]u8, at: i64) void {
    const key = profileEndKey(pubkey);
    lockProfileReach();
    defer unlockProfileReach();
    if (g_profile_reach.key != key) return;
    g_profile_reach.at = @min(g_profile_reach.at, at);
}

pub fn profileReach(pubkey: [32]u8) ?i64 {
    const key = profileEndKey(pubkey);
    lockProfileReach();
    defer unlockProfileReach();
    if (g_profile_reach.key != key or g_profile_reach.at == no_profile_reach) return null;
    return g_profile_reach.at;
}
/// Where the next relay page for the open person starts. Before any round has
/// brought a note there is no run to continue, so the page asks for their
/// newest, from the moment the page opened: the first page only asked the
/// reader's own relays, and the next one also asks theirs.
fn profileOlderCursor(model: *const Model, pubkey: [32]u8) i64 {
    return profileReach(pubkey) orelse model.thread_open_at;
}

fn fetchOlderProfile(pubkey: [32]u8, until: i64) void {
    g_profile_older_ask = .{ .pubkey = pubkey, .until = until };
    if (!relayFetchAllowed()) return;
    if (g_profile_older_busy.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, fetchProfileOlderWorker, .{ pubkey, until }) catch {
        g_profile_older_busy.store(false, .release);
        return;
    };
    thread.detach();
}

fn fetchProfileOlderWorker(pubkey: [32]u8, until: i64) void {
    defer g_profile_older_busy.store(false, .release);
    const round = profileRound(pubkey, until);
    if (profileRoundEnded(round)) g_profile_end.store(profileEndKey(pubkey), .monotonic);
}

/// Nothing anywhere had anything older, AND somebody was there to say so. The
/// same two-part rule as the feed: a round that reached nobody says nothing, and
/// the next scroll asks again.
pub fn profileRoundEnded(round: ProfileRound) bool {
    return feedEndLatches(round.asked, round.answered, round.older);
}
/// The reader reached the end of a person's list: one more page of their notes.
///
/// Store first. A read that came back full may have more behind it, so the limit
/// goes up a page and the list is read again; that is a disk read and the screen
/// grows at once. Only when the store had nothing more to give are the relays
/// asked, for what comes before where they have reached (`g_profile_reach`).
/// Jumble's order:
/// `_loadMoreTimeline` serves from its cached refs and only then queries with
/// `{ ...filter, until, limit }` (services/client.service.ts:731-751).
pub fn loadOlderProfile(model: *Model) void {
    const pk = model.viewing_profile orelse return;
    const held = model.thread_notes_len;
    if (held >= model.profile_limit and model.profile_limit < profile_notes_max) {
        model.profile_limit = @min(model.profile_limit + profile_page, profile_notes_max);
        model.refreshProfileNotes(nowSeconds());
        if (model.thread_notes_len > held) return;
    }
    if (held == 0 or held >= profile_notes_max) return;
    if (profileEndReached(pk)) return;
    // The page's own first fetch is still out. A short list reaches its end the
    // moment it opens, and paging from the one note the store had then would ask
    // for history the first fetch is already bringing, and find the end of it
    // by being second.
    if (navigation.g_thread_done_seq.load(.acquire) < model.thread_seq) return;
    const cursor = profileOlderCursor(model, pk);
    model.profile_asked_until = cursor;
    fetchOlderProfile(pk, cursor);
}
/// How many rows the open person's current tab holds.
fn profileTabCount(model: *const Model, pubkey: [32]u8) usize {
    var n: usize = 0;
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (!std.mem.eql(u8, &note.pubkey, &pubkey)) continue;
        if ((model.profile_tab == .replies) != note.has_reply_parent) continue;
        n += 1;
    }
    return n;
}

/// Whether the last row of the open person's list is built, which is to say on
/// screen or within the overscan beside it. Written by the view, read by the
/// tick, one frame stale like the other visible sets.
pub var g_profile_bottom_in_view: bool = false;

/// The list's bottom edge, watched rather than waited for.
///
/// `on_reach_end` fires once per approach and re-arms only after the reader has
/// scrolled well away, which is right for a long list and wrong for two cases.
/// A tab too short to scroll has no end to reach, and a list that has just
/// grown by less than a screen is still at its end with the trigger spent. Both
/// leave the reader at the bottom with nothing coming and no way to ask. This is
/// Jumble's bottom sentinel (an IntersectionObserver on the element
/// under the list, hooks/useInfiniteScroll.tsx:113-118 and NoteList/index.tsx:582):
/// while the bottom is in view and there may be more, ask.
///
/// Stops where asking again would be asking the same question. A round that
/// brought nothing older leaves the cursor where it was, and the next manual
/// reach-end is the reader's way of trying again.
pub fn loadAtProfileBottom(model: *Model) void {
    const pk = model.viewing_profile orelse return;
    if (!g_profile_bottom_in_view) return;
    if (model.thread_notes_len == 0) return;
    // The page's own first fetch is still out. Asking for older notes before the
    // newest have landed would page from a cursor that is about to move.
    if (navigation.g_thread_done_seq.load(.acquire) < model.thread_seq) return;
    if (g_profile_older_busy.load(.monotonic) or profileEndReached(pk)) return;
    // The store has nothing more and the relays were already asked from here.
    if (model.thread_notes_len < model.profile_limit and profileOlderCursor(model, pk) == model.profile_asked_until) return;
    // A short tab is the case a reader cannot scroll out of, so it is bounded:
    // an account with no replies at all would otherwise walk its whole history
    // for a tab that stays empty.
    if (profileTabCount(model, pk) < profile_fill_rows) {
        if (model.profile_autofill >= profile_autofill_max) return;
        model.profile_autofill += 1;
    }
    loadOlderProfile(model);
}

pub fn roundReachForTest(seen: []ProfileSeen) ?i64 {
    return roundReach(seen);
}

pub fn writeRelaysOfForTest(ev: nostr.event.Event, out: *[outbox_relays_per_author][96]u8, lens: *[outbox_relays_per_author]u8) usize {
    return writeRelaysOf(ev, out, lens);
}

pub fn profileTargetsForTest(pubkey: [32]u8, out: *[profile_round_targets][96]u8, lens: *[profile_round_targets]u8) usize {
    return profileTargets(pubkey, out, lens);
}

pub fn profileEndReachedForTest(pubkey: [32]u8) bool {
    return profileEndReached(pubkey);
}

pub fn setProfileEndForTest(pubkey: [32]u8) void {
    g_profile_end.store(profileEndKey(pubkey), .monotonic);
}

pub fn resetProfileEndForTest() void {
    resetProfileEnd();
    g_profile_older_busy.store(false, .monotonic);
    g_profile_older_ask = null;
}

pub fn profileOlderAskForTest() ?ProfileOlderAsk {
    return g_profile_older_ask;
}

/// Records that a round for `pubkey` reached back to `at`, the way a relay
/// answer does, for a test that has no relay.
pub fn noteProfileReachForTest(pubkey: [32]u8, at: i64) void {
    noteProfileReach(pubkey, at);
}

pub fn profileReachForTest(pubkey: [32]u8) ?i64 {
    return profileReach(pubkey);
}

pub fn profileRoundEndedForTest(asked: usize, answered: usize, added: usize, older: usize) bool {
    return profileRoundEnded(.{ .asked = asked, .answered = answered, .added = added, .older = older });
}

pub fn loadOlderProfileForTest(model: *Model) void {
    loadOlderProfile(model);
}

pub fn loadAtProfileBottomForTest(model: *Model, bottom_in_view: bool) void {
    g_profile_bottom_in_view = bottom_in_view;
    loadAtProfileBottom(model);
}

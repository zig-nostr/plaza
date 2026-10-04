//! Moving between screens, and the fetches each screen starts.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const people_search = @import("people_search.zig");
const places = @import("places.zig");
const profile_notes = @import("profile_notes.zig");
const uploads = @import("uploads.zig");
const article = @import("article.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Address = main.Address;
const Effects = main.Effects;
const Model = main.Model;
const Note = main.Note;
const RelayHints = main.RelayHints;
const Screen = main.Screen;
const Stage = main.Stage;
const activePubkey = main.activePubkey;
const addressFor = main.addressFor;
const armProfileReach = main.armProfileReach;
const askPlace = main.askPlace;
const comment_kind = main.comment_kind;
const copyBounded = main.copyBounded;
const countEngagement = main.countEngagement;
const dropUpload = main.dropUpload;
const engagementKinds = main.engagementKinds;
const engagement_request_limit = main.engagement_request_limit;
const feed_filter_kinds = main.feed_filter_kinds;
const feed_page = main.feed_page;
const followSet = main.followSet;
const follow_chunk = main.follow_chunk;
const goToOwnPlaza = main.goToOwnPlaza;
const hexLower = main.hexLower;
const leaveNotifications = main.leaveNotifications;
const leaveSettings = main.leaveSettings;
const max_feed_filters = main.max_feed_filters;
const max_follows = main.max_follows;
const max_topic_bytes = main.max_topic_bytes;
const mediaProxy = main.mediaProxy;
const noteFrom = main.noteFrom;
const noteIdOf = main.noteIdOf;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const openAddressedArticle = main.openAddressedArticle;
const parkReplyDraft = main.parkReplyDraft;
const parseAddress = main.parseAddress;
const place_looking_toast = main.place_looking_toast;
const plazaIngestFrom = main.plazaIngestFrom;
const profileRound = main.profileRound;
const profile_page = main.profile_page;
const refreshPlaceFetch = main.refreshPlaceFetch;
const relayFetchAllowed = main.relayFetchAllowed;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const releaseOneShot = main.releaseOneShot;
const resetProfileEnd = main.resetProfileEnd;
const samePlace = main.samePlace;
const searchReset = main.searchReset;
const setToast = main.setToast;
const startBlossomProbe = main.startBlossomProbe;
const takeReplyDraft = main.takeReplyDraft;
const threadQueryIds = main.threadQueryIds;
const thread_reply_cap = main.thread_reply_cap;
const wantProfile = main.wantProfile;
const wantProfileHinted = main.wantProfileHinted;
const wantQuote = main.wantQuote;
const wantQuoteHinted = main.wantQuoteHinted;
const watchOneShot = main.watchOneShot;

/// Open somebody's profile, remembering whether the notifications sheet was what
/// we came from so closing it returns there rather than to the feed.
pub fn openPerson(model: *Model, pubkey: [32]u8) void {
    leaveNotifications(model);
    enterProfile(model, pubkey);
}
/// The one door into Settings. Every field on the screen that edits a live
/// setting is seeded here, because an arm that sets `stage = .settings` on its
/// own leaves those fields EMPTY, and an empty field over a Save button is an
/// invitation to erase the setting it was supposed to show. The backup nudge did
/// exactly that to the media proxy.
pub fn enterSettings(model: *Model) void {
    // Already here. Cmd+, reaches past every sheet, and running the rest again
    // closes the Edit profile sheet over what was typed in it, drops a picture
    // on its way into it, and puts back a media proxy half edited.
    if (model.stage == .settings) return;
    model.menu = .none;
    // One sheet at a time: Settings is a sheet now, and the notifications sheet
    // is checked FIRST in the view, so leaving it open would open Settings into
    // a window that never shows it.
    model.notifications_open = false;
    model.proxy_buffer.set(mediaProxy());
    model.proxy_saved = false;
    model.proxy_invalid = false;
    model.settings_scroll_y = 0;
    model.editing_profile = false;
    // The Edit profile sheet closes here too, and a picture on its way to the
    // avatar or banner has nowhere to land once it has: it would finish
    // uploading into a field the next open clears.
    if (uploads.g_upload) |job| {
        if (job.target != .note) dropUpload();
    }
    uploads.g_profile_upload_unsaved = false;
    model.blossom_error = .none;
    // Whether this account has a media server list is asked of the relays now,
    // so by the time an edit is made the answer is in.
    startBlossomProbe();
    model.stage = .settings;
}
// ------------------------------------------------------------------------ threads
//
// A thread is the focused note plus the kind:1 replies that e-tag it. It is
// layered OVER the feed, which stays mounted so its scroll offset survives.
// Opening one snapshots the root, reads any replies already in the store, and
// fires a one-shot fetch of the rest (with their engagement) into the store; the
// replies are cached in the model so they are pressable (open as a sub-thread)
// and get their pictures fetched, the same local-first path the feed uses.

/// Opens `note_id` as a thread. The target may live in the feed or the current
/// thread; it is snapshotted as the new root so it survives store rebuilds. When
/// a thread is already open, the current root is pushed so Back returns to it.
pub fn openThread(model: *Model, note_id: i64) void {
    const target = model.noteById(note_id) orelse return;
    // A note pressed on the feed itself has no sheet to go back to, whatever an
    // earlier visit to Notifications left behind.
    if (!model.levelOpen()) model.notifications_return = false;
    enterThread(model, target.*);
}

/// Focuses `root` as the open thread: pushes the current thread (if any) onto
/// the back-stack, snapshots the new root, and fires its reply fetch. Shared by
/// open-a-feed-note, open-a-reply, and open-a-quoted-note.
pub fn enterThread(model: *Model, root: Note) void {
    parkReplyDraft(model);
    pushCurrentScreen(model);
    // Here and not in `setThreadRoot`: a newer copy of the article being read
    // swaps the root in place, and the reply being typed under it stays put.
    takeReplyDraft(model, root.event_id);
    setThreadRoot(model, root);
}

/// Makes `root` the open thread without touching the back-stack. `enterThread`
/// is a push and this; a newer copy of an article the reader is already reading
/// is this alone, so Back still goes where it went before.
fn setThreadRoot(model: *Model, root: Note) void {
    // A topic or the bookmark list outranks a thread when the view is built,
    // so left set, either one hid the thread: pressing a note on those pages
    // opened nothing. The level being left is already on the stack.
    model.topic_len = 0;
    model.viewing_bookmarks = false;
    model.viewing_profile = null;
    model.viewing_thread = root.id;
    model.thread_root = root;
    model.thread_notes_len = 0;
    // The level being opened starts at its first page with its held section
    // closed. Only this level: the ones underneath keep what the reader left
    // them holding. The arrival table needs no reset either, since it is keyed
    // by the level's root and discards itself when it finds another thread.
    model.thread_page[model.currentLevel()] = 1;
    model.thread_outside_open[model.currentLevel()] = false;
    wantProfile(root.pubkey);
    // The fetch is claimed BEFORE the first build, because that build asks
    // whether this level's fetch has settled: against the previous level's
    // sequence it would answer yes, mark the table settled before a single
    // reply had landed, and put the whole opening read back into relay-answer
    // order, which is the thing arrival batching exists to prevent.
    const now = nowSeconds();
    const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
    model.thread_seq = seq;
    model.thread_open_at = now;
    model.refreshThreadNotes(now);
    model.thread_loading = model.thread_notes_len == 0;
    fetchThreadReplies(root.event_id, seq);
}
/// Replaces the open level's root in place, keeping the back-stack.
pub fn swapThreadRoot(model: *Model, root: Note) void {
    setThreadRoot(model, root);
}
/// Pushes whatever level is open, so Back returns to it. A no-op at the feed,
/// and a no-op at the depth cap, which is the same rule threads always had.
fn pushCurrentScreen(model: *Model) void {
    if (model.thread_stack_len >= model.thread_stack.len) return;
    if (model.viewing_bookmarks) {
        model.thread_stack[model.thread_stack_len] = .{ .bookmarks = true };
        model.thread_stack_len += 1;
        return;
    }
    if (model.viewingTopic()) |topic| {
        var level = Screen{ .topic_len = @intCast(topic.len) };
        @memcpy(level.topic_buf[0..topic.len], topic);
        model.thread_stack[model.thread_stack_len] = level;
        model.thread_stack_len += 1;
        return;
    }
    if (model.viewing_profile) |pk| {
        model.thread_stack[model.thread_stack_len] = .{ .profile = pk, .profile_limit = model.profile_limit };
        model.thread_stack_len += 1;
        return;
    }
    if (model.viewing_thread != 0) {
        model.thread_stack[model.thread_stack_len] = .{ .note = model.thread_root };
        model.thread_stack_len += 1;
    }
}

/// The filters that ask for notes older than `until`.
///
/// Chunked exactly like the live subscription, and for the same reason: a relay
/// refuses a filter whose field items exceed its size cap. Separate from
/// `buildFeedFilters` because this asks for notes and nothing else: profiles
/// and relay lists are replaceable, so there is no older copy to page back to.
pub fn buildOlderFilters(
    authors: []const [32]u8,
    until: i64,
    out: []nostr.filter.Filter,
) []nostr.filter.Filter {
    var len: usize = 0;
    var start: usize = 0;
    while (start < authors.len and len < out.len) : (start += follow_chunk) {
        const chunk = authors[start..@min(start + follow_chunk, authors.len)];
        out[len] = .{
            .authors = chunk,
            .kinds = &feed_filter_kinds,
            .until = until,
            .limit = feed_page,
        };
        len += 1;
    }
    return out[0..len];
}

/// Whether an older-notes fetch is already in flight, so a reader who keeps
/// scrolling does not stack one request per frame.
pub var g_older_busy = std.atomic.Value(bool).init(false);
/// Set when a network round for older notes came back with nothing new, which
/// is the only honest way to know the feed has an end.
pub var g_feed_end_reached = std.atomic.Value(bool).init(false);

pub fn feedEndReached() bool {
    return g_feed_end_reached.load(.monotonic);
}

/// The end of history is an answer about a QUESTION: is there anything older
/// than this, from these authors, on these relays. Change the question and the
/// answer stops being about anything.
///
/// This existed only as a test helper with no callers anywhere, so the latch
/// was write-once for the life of the process: sign in as somebody else, follow
/// three hundred new people, add a relay that holds a decade of history, and
/// the feed still refused to ask.
pub fn resetFeedEnd() void {
    g_feed_end_reached.store(false, .monotonic);
}

/// The latch's condition, lifted out so it can be asserted without standing up
/// a relay. The worker calls this with what its round actually saw.
pub fn feedEndLatches(asked: usize, answered: usize, added: usize) bool {
    return asked > 0 and answered > 0 and added == 0;
}
/// Asks the relays for notes older than `until`.
///
/// Reaching the end of the loaded feed used to raise the store's query limit
/// and nothing else. The store answers with what it has, so once the initial
/// backfill was exhausted the list simply stopped growing: no older history, no
/// end-of-feed state, and no way to reach anything from before the app was
/// opened. A reader coming back after a week saw the last few hundred notes and
/// could not scroll past them. Grepping this file for `.until` returned nothing
/// at all, which is the whole bug: no filter Plaza ever sent carried one.
///
/// Store first, network second, which is Jumble's ordering: `_loadMoreTimeline`
/// serves from its cached list and only then asks with `{ ...filter, until }`.
pub fn fetchOlderNotes(until: i64) void {
    if (!relayFetchAllowed()) return;
    // One at a time. Sitting at the bottom of the list fires this on every
    // frame, and each round is a dial per relay.
    if (g_older_busy.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, fetchOlderWorker, .{until}) catch {
        g_older_busy.store(false, .release);
        return;
    };
    thread.detach();
}

fn fetchOlderWorker(until: i64) void {
    const gpa = std.heap.page_allocator;
    defer g_older_busy.store(false, .release);
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var authors: [max_follows + 1][32]u8 = undefined;
    var authors_len: usize = 0;
    if (activePubkey()) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    for (followSet()) |pk| {
        if (authors_len == authors.len) break;
        authors[authors_len] = pk;
        authors_len += 1;
    }
    if (authors_len == 0) return;

    var filters: [max_feed_filters]nostr.filter.Filter = undefined;
    const built = buildOlderFilters(authors[0..authors_len], until, &filters);
    const flen = built.len;

    var added: usize = 0;
    // How many relays took the subscription and answered it. Both, because an
    // end of history is a thing relays TELL you and the two ways of not being
    // told look identical from `added` alone.
    var asked: usize = 0;
    var answered: usize = 0;
    for (0..relaySlots()) |ri| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        if (!entry.read) continue;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse continue;
        defer releaseOneShot(watched);
        relay.subscribe("plaza-older", filters[0..flen]) catch continue;
        asked += 1;
        var seen: usize = 0;
        // Bounded: `receive` has no deadline, and a relay that takes the
        // subscription and then goes quiet would hold this thread forever.
        while (seen < profile_fetch_messages) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, entry.url) catch continue;
                    if (result == .added) added += 1;
                },
                .eose => {
                    // "I have looked and that is all of it." The only message
                    // that licenses the latch below.
                    answered += 1;
                    break;
                },
                .closed => break,
                else => {},
            }
        }
        relay.unsubscribe("plaza-older") catch {};
    }

    // Nothing anywhere had anything older, AND somebody was actually there to
    // say so. Both halves matter, and only the first was checked.
    //
    // `added` counts events that were new to the store, and every failure in
    // the loop above is a `catch continue`: a dial that could not connect, a
    // subscribe that was refused. So an offline round and a round where every
    // relay answered "nothing older" produced the same zero, and this latched
    // on the first paging attempt made on a train. It is write-once for the
    // life of the process, so the feed then dead-ended until the app restarted.
    //
    // A round that reached nobody now says nothing at all, and the next attempt
    // asks again.
    if (feedEndLatches(asked, answered, added)) g_feed_end_reached.store(true, .monotonic);
}

/// Opens a person as a level of their own.
/// Opens a topic as a level of its own: what this reader already holds carrying
/// that `t` tag, on the back stack, with the feed left where it was.
///
/// Local store first and rendered immediately, then a bounded ask to the read
/// relays behind it. A topic has no author, so the outbox model has nothing to
/// say about where to ask: the reader's own read relays are the honest answer,
/// rather than a search relay nobody chose.
pub fn openTopic(model: *Model, topic_in: []const u8) void {
    if (topic_in.len == 0 or topic_in.len > max_topic_bytes) return;
    // NIP-24: `t` values are lowercase, and a relay matches them exactly, so
    // `#Nostr` asked for as written finds nothing that `contentTags` published.
    var folded: [max_topic_bytes]u8 = undefined;
    for (topic_in, 0..) |c, i| folded[i] = std.ascii.toLower(c);
    const topic = folded[0..topic_in.len];
    // Already here: pressing `#zig` inside the `#zig` topic would otherwise push
    // a second copy of it and cost a Back to undo.
    if (model.viewingTopic()) |current| {
        if (std.mem.eql(u8, current, topic)) return;
    }
    leaveNotifications(model);
    pushCurrentScreen(model);
    model.viewing_bookmarks = false;
    model.viewing_profile = null;
    model.viewing_thread = 0;
    model.thread_notes_len = 0;
    parkReplyDraft(model);
    @memcpy(model.topic_buf[0..topic.len], topic);
    model.topic_len = @intCast(topic.len);
    const now = nowSeconds();
    const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
    model.thread_seq = seq;
    model.thread_open_at = now;
    model.refreshTopicNotes(now);
    model.thread_loading = model.thread_notes_len == 0;
    fetchTopicNotes(topic, seq);
}
/// Opens the bookmark list as a level of its own.
///
/// The answer to "a bookmark I cannot find again is a button, not a feature".
pub fn openBookmarks(model: *Model) void {
    if (model.viewing_bookmarks) return;
    leaveNotifications(model);
    pushCurrentScreen(model);
    model.viewing_profile = null;
    model.viewing_thread = 0;
    model.topic_len = 0;
    model.thread_notes_len = 0;
    parkReplyDraft(model);
    model.viewing_bookmarks = true;
    model.thread_seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
    model.thread_open_at = nowSeconds();
    // Read from this machine and nothing else. Every bookmarked note was in the
    // feed when it was saved, so it is already here; there is no relay round
    // trip to wait on and no skeleton to show.
    model.refreshBookmarkNotes(nowSeconds());
    model.thread_loading = false;
}
pub fn enterProfile(model: *Model, pubkey: [32]u8) void {
    // Already here. Pressing a face on somebody's own page would otherwise push
    // a second copy of the same person and cost a Back to undo.
    if (model.viewing_profile) |current| {
        if (std.mem.eql(u8, &current, &pubkey)) return;
    }
    pushCurrentScreen(model);
    model.topic_len = 0;
    model.viewing_bookmarks = false;
    model.viewing_profile = pubkey;
    model.viewing_thread = 0;
    model.thread_notes_len = 0;
    parkReplyDraft(model);
    wantProfile(pubkey);
    model.profile_tab = .notes;
    model.profile_limit = profile_page;
    model.profile_autofill = 0;
    model.profile_asked_until = 0;
    profile_notes.g_profile_bottom_in_view = false;
    armProfileReach(pubkey, true);
    const now = nowSeconds();
    const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
    model.thread_seq = seq;
    model.thread_open_at = now;
    model.refreshProfileNotes(now);
    model.thread_loading = model.thread_notes_len == 0;
    fetchProfileNotes(pubkey, seq);
}
/// Opens an event (by its full id) as a thread, reading it straight from the
/// store. `openThread` cannot: it resolves the render key through the feed and
/// the open thread, and a quoted note or an ANCESTOR is in neither. Both press
/// this instead, and both only ever fire for an event already ingested (an
/// unresolved quote card is not pressable, and an ancestor row exists because
/// the walk found the event).
/// Puts the address field away and forgets what was in it.
pub fn closeAddress(model: *Model) void {
    model.address_open = false;
    model.address_buffer.clear();
    model.address_error = .none;
    people_search.g_nip05_ask = null;
    searchReset();
}

/// Reads what is in the address field and goes where it points.
///
/// The field closes BEFORE the navigation, never after it. Every destination
/// here has an early return in front of it, and closing on arrival leaves the
/// sheet up in exactly the cases where the reader has least idea why nothing
/// moved. This is the same rule `.open_event` already follows for the
/// notifications sheet.
///
/// A refusal does the opposite and leaves the field open with what was typed
/// still in it, because the reader is about to fix a character.
pub fn openAddress(model: *Model, fx: *Effects) void {
    // A NIP-19 entity is a few hundred bytes at the outside, and the decode
    // allocates the relay list and a place's identifier out of this too.
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = parseAddress(fba.allocator(), model.address_buffer.text());
    const hit = switch (parsed) {
        .unreadable => {
            model.address_error = .unreadable;
            return;
        },
        .wrong_kind => {
            model.address_error = .wrong_kind;
            return;
        },
        .ok => |ok| ok,
    };

    closeAddress(model);
    // The address can be opened over Settings, and the destination is drawn
    // under it. Leave Settings first, or the reader presses Open and sees
    // nothing happen.
    if (model.stage == .settings) leaveSettings(model);
    // And the notifications sheet, for every target and not only a person:
    // a thread, an article or a room opened under the sheet is a press that
    // seems to do nothing. Once, here, because a second call would read the
    // sheet as already closed and forget that it was the way back.
    leaveNotifications(model);
    switch (hit.target) {
        // The hints go in FIRST, so that if the note is not held the fetch
        // `openEvent` starts already knows where to look. `wantQuote` inside
        // `openEvent` then finds this entry and leaves it alone.
        .event => |id| {
            wantQuoteHinted(id, hit.hints);
            openEvent(model, id);
        },
        .person => |pk| {
            wantProfileHinted(pk, hit.hints);
            enterProfile(model, pk);
        },
        .place => |pl| {
            var want: @TypeOf(places.g_place_want.?) = .{ .pubkey = pl.pubkey, .ident_buf = @splat(0), .ident_len = 0 };
            want.ident_len = @intCast(copyBounded(&want.ident_buf, pl.identifier));
            places.g_place_want = want;
            askPlace(fx, hit.hints);
            // A copy already in the store opens the room now. Otherwise say
            // that the address was heard: the fetch ends with a toast of its
            // own, and the seconds between are not silence.
            // Not when the address is the room already on screen: there is
            // nothing to look for, and the window only watches for a newer copy.
            refreshPlaceFetch(model);
            if (places.g_place_want) |w| {
                if (!w.applied and !samePlace(w)) setToast(model, place_looking_toast);
            }
            // A room is not a level, so there is no Back that could return to
            // the sheet through it.
            if (!model.levelOpen()) model.notifications_return = false;
        },
        .article => |art| {
            // Cannot fail: `parseAddress` only returns this for an address that
            // `Address.make` accepted.
            const addr = Address.make(art.kind, art.pubkey, art.identifier) orelse return;
            openAddressedArticle(model, addr, hit.hints);
        },
    }
}

/// Goes to a stored event the reader asked for by id. A note opens as a thread
/// and a published article opens as the article, which `feedView` draws as a
/// reader instead of a thread because its root is a kind:30023.
///
/// A draft (kind:30024) opens nothing. It is the author's unfinished copy, it is
/// not addressed to a reader, and putting it on screen with the same title and
/// body as the published one is how a draft gets read as the real thing.
pub fn enterEvent(model: *Model, ev: nostr.event.Event) void {
    if (ev.kind == article.draft_kind) {
        setToast(model, "That is an unpublished draft.");
        return;
    }
    enterThread(model, noteFrom(ev, nowSeconds()));
}
pub fn openEvent(model: *Model, id: [32]u8) void {
    // A quote card or pill for an `naddr` carries the address's stand-in key
    // where an id would be, and opens the newest copy of the coordinate.
    if (addressFor(id)) |slot| {
        const addr = slot.addr;
        var hints: [RelayHints.cap][]const u8 = undefined;
        for (0..slot.hints.count) |i| hints[i] = slot.hints.at(@intCast(i));
        const n = slot.hints.count;
        openAddressedArticle(model, addr, hints[0..n]);
        return;
    }
    if (main.g_store) |store| {
        if (store.getEvent(std.heap.page_allocator, id) catch null) |found| {
            var se = found;
            defer se.deinit();
            enterEvent(model, se.event);
            return;
        }
    }
    // Not held. This is reachable from a notification, whose target is whatever
    // note the thing was about, and that note is often one nobody asked any relay
    // for: a stranger's parent in a thread the reader was named in, or the
    // reader's own note from before this install. Silence here is the worst
    // answer, because the row looks alive and is not. So ask for it, and say so.
    wantQuote(id);
    // And WAIT for it. Asking was all this did, and the fetch works: the id goes
    // into the quote cache, the relays the address named get dialled, and the
    // note lands in the store seconds later. Nothing recorded that the reader
    // was trying to GO somewhere, so there was nobody waiting on it when it
    // landed. The toast expired, the feed stayed the feed, and pasting the same
    // address a second time opened the thread instantly off the local copy.
    g_event_want = .{ .id = id, .from = standingNow(model) };
    setToast(model, "Fetching that note");
}

/// Where the reader is standing, in just enough detail to tell "still here"
/// from "gone somewhere else".
///
/// One snapshot compared on the tick, rather than a cancel written into each
/// door out of the feed. A cancel in `enterThread` would cover `enterThread`
/// and nothing else, and a note can arrive while the reader has opened a
/// profile, walked into a room, or gone into Settings just as easily.
pub const Standing = struct {
    stage: Stage = .ready,
    /// The open thread, zero at the feed.
    thread: i64 = 0,
    profile: ?[32]u8 = null,
    /// The other two kinds of level. Left out, a note fetch started at the
    /// feed or from Notifications opened its thread over a hashtag page or the
    /// bookmark list the reader had gone to meanwhile.
    bookmarks: bool = false,
    topic_buf: [max_topic_bytes]u8 = @splat(0),
    topic_len: u8 = 0,
    /// How deep the back stack is. The feed is never pushed, so this alone
    /// cannot tell the feed from the first level over it, which is why the
    /// level kinds above are compared too; it catches the same level reached
    /// again by a different route.
    depth: usize = 0,
    /// The open room: host plus `d`, the pair that is a place's identity, and
    /// null in the reader's own plaza. A title is not an identity, and two
    /// communities may share one.
    place: ?struct { pubkey: [32]u8, ident_buf: [64]u8, ident_len: u8 } = null,

    pub fn eql(a: Standing, b: Standing) bool {
        if (a.stage != b.stage or a.thread != b.thread) return false;
        if (a.bookmarks != b.bookmarks or a.depth != b.depth) return false;
        if (!std.mem.eql(u8, a.topic_buf[0..a.topic_len], b.topic_buf[0..b.topic_len])) return false;
        if ((a.profile == null) != (b.profile == null)) return false;
        if (a.profile) |ap| {
            if (!std.mem.eql(u8, &ap, &b.profile.?)) return false;
        }
        if ((a.place == null) != (b.place == null)) return false;
        if (a.place) |ap| {
            const bp = b.place.?;
            if (!std.mem.eql(u8, &ap.pubkey, &bp.pubkey)) return false;
            if (!std.mem.eql(u8, ap.ident_buf[0..ap.ident_len], bp.ident_buf[0..bp.ident_len])) return false;
        }
        return true;
    }
};

pub fn standingNow(model: *const Model) Standing {
    var s = Standing{
        .stage = model.stage,
        .thread = model.viewing_thread,
        .profile = model.viewing_profile,
        .bookmarks = model.viewing_bookmarks,
        .depth = model.currentLevel(),
    };
    if (model.viewingTopic()) |topic| {
        @memcpy(s.topic_buf[0..topic.len], topic);
        s.topic_len = @intCast(topic.len);
    }
    if (places.g_place) |*p| {
        var here: @TypeOf(s.place.?) = .{ .pubkey = p.author, .ident_buf = @splat(0), .ident_len = 0 };
        here.ident_len = @intCast(copyBounded(&here.ident_buf, p.ident()));
        s.place = here;
    }
    return s;
}

/// The note the reader asked to open, while it is being fetched.
///
/// The same three parts the place fetch has: what was asked for, a tick that
/// applies it when it arrives, and a bounded give-up.
pub var g_event_want: ?struct {
    id: [32]u8,
    /// Ticks the fetch has been outstanding, so it can give up and say so.
    waited: u16 = 0,
    /// Where the reader was standing when they asked.
    from: Standing,
} = null;

/// Looks for the note being waited on, once the store has grown. Called from
/// the tick, beside the place fetch this is modelled on, which is where every
/// other "did it arrive yet" check in this app lives.
pub fn refreshEventFetch(model: *Model) void {
    const want = g_event_want orelse return;
    // Gone somewhere else since asking. The window closes rather than pulling
    // the reader out of whatever they picked up instead, the same rule the
    // place fetch follows when the reader steps sideways out of a linked room.
    if (!want.from.eql(standingNow(model))) {
        g_event_want = null;
        forgetStaleReturn(model);
        return;
    }
    const store = main.g_store orelse return;
    if (store.getEvent(std.heap.page_allocator, want.id) catch null) |found| {
        var se = found;
        defer se.deinit();
        // Closed BEFORE the navigation. `enterThread` moves the reader, so a
        // window still open here would read its own arrival as a walk away on
        // the next tick: right by accident, and only while that stays the last
        // thing this function does.
        g_event_want = null;
        enterEvent(model, se.event);
        return;
    }
    // Give up eventually rather than watching a store read forever, and say so
    // out loud. A reader told "Fetching that note" and then left on the feed
    // with no second word cannot tell a slow relay from a note nobody has.
    g_event_want.?.waited +|= 1;
    if (g_event_want.?.waited > event_fetch_ticks) {
        g_event_want = null;
        forgetStaleReturn(model);
        setToast(model, "That note did not turn up.");
    }
}

/// A fetch asked for from the notifications sheet closed the sheet and noted it
/// as the way back. When the fetch ends without opening a level, nothing is
/// left to go back from, and kept, the note would make some later thread's Back
/// say Notifications and reopen a sheet the reader closed long ago.
pub fn forgetStaleReturn(model: *Model) void {
    if (!model.levelOpen()) model.notifications_return = false;
}

/// How many ticks a note fetch may go unanswered. The same window a place gets,
/// for the same reason: the tick is a second, and a relay that has not answered
/// in fifteen is one that does not have it.
const event_fetch_ticks = 15;
/// Back to the feed from wherever the reader has got to, in one press.
///
/// Not a Back: it drops the whole stack rather than one level, because the mark
/// in the corner of the rail is a destination and not a step. Settings is left,
/// any open person or thread is closed, and the overlays that live above the
/// feed go with them, since landing on the feed behind a panel is not landing
/// on the feed.
///
/// The sheets that ask the reader something (signing in, naming a fresh key)
/// are deliberately NOT touched here. They are questions with an answer owed,
/// and dismissing one as a side effect of navigating is how a remembered intent
/// gets dropped.
pub fn goHome(model: *Model) void {
    model.thread_stack_len = 0;
    model.notifications_return = false;
    model.viewing_profile = null;
    model.viewing_thread = 0;
    // Every kind of level, not the two that were written first. A topic and the
    // bookmark list were left set, so `levelOpen` stayed true and the mark did
    // nothing from either page.
    model.topic_len = 0;
    model.viewing_bookmarks = false;
    model.thread_loading = false;
    model.thread_notes_len = 0;
    parkReplyDraft(model);
    model.menu = .none;
    model.notifications_open = false;
    model.stage = .ready;
    // Home is YOUR feed, so the mark closes the room. Not the same verb as
    // Leave: the place stays in the list with its ids intact, one press away on
    // the rail, which is deliberately left exactly as it was. Hiding it here is
    // what made coming back cost two presses.
    goToOwnPlaza();
}
/// Closes the open thread: pops the back-stack to the thread it was opened from,
/// or returns to the feed (which kept its scroll offset) when the stack is empty.
pub fn closeThread(model: *Model) void {
    // The level being left is the one that resets: the level underneath keeps
    // its pages, its held section and its arrival order, which is what makes the
    // walk back land where the reader left it.
    model.thread_page[model.currentLevel()] = 1;
    model.thread_outside_open[model.currentLevel()] = false;
    parkReplyDraft(model);
    model.thread_notes_len = 0;
    if (model.thread_stack_len > 0) {
        model.thread_stack_len -= 1;
        const prev = model.thread_stack[model.thread_stack_len];
        // Same ordering as `enterThread`, and for the same reason.
        const now = nowSeconds();
        const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
        model.thread_seq = seq;
        model.thread_open_at = now;
        if (prev.bookmarks) {
            model.viewing_profile = null;
            model.viewing_thread = 0;
            model.topic_len = 0;
            model.viewing_bookmarks = true;
            model.refreshBookmarkNotes(now);
            model.thread_loading = false;
        } else if (prev.topic()) |topic| {
            model.viewing_bookmarks = false;
            model.viewing_profile = null;
            model.viewing_thread = 0;
            @memcpy(model.topic_buf[0..topic.len], topic);
            model.topic_len = @intCast(topic.len);
            model.refreshTopicNotes(now);
            model.thread_loading = model.thread_notes_len == 0;
            fetchTopicNotes(topic, seq);
        } else if (prev.profile) |pk| {
            model.viewing_bookmarks = false;
            model.topic_len = 0;
            model.viewing_profile = pk;
            model.viewing_thread = 0;
            model.profile_limit = prev.profile_limit;
            model.profile_autofill = 0;
            model.profile_asked_until = 0;
            profile_notes.g_profile_bottom_in_view = false;
            armProfileReach(pk, false);
            model.refreshProfileNotes(now);
            model.thread_loading = model.thread_notes_len == 0;
            fetchProfileNotes(pk, seq);
        } else {
            model.viewing_bookmarks = false;
            model.topic_len = 0;
            model.viewing_profile = null;
            model.viewing_thread = prev.note.id;
            model.thread_root = prev.note;
            takeReplyDraft(model, prev.note.event_id);
            model.refreshThreadNotes(now);
            model.thread_loading = model.thread_notes_len == 0;
            fetchThreadReplies(prev.note.event_id, seq);
        }
    } else {
        model.viewing_bookmarks = false;
        model.topic_len = 0;
        model.viewing_profile = null;
        model.viewing_thread = 0;
        model.thread_loading = false;
        // Back to where the reader actually came from. The list is rebuilt from
        // the same inbox and the window keeps its offset on the list's own id,
        // so this lands on the row they pressed rather than at the top.
        if (model.notifications_return) {
            model.notifications_return = false;
            model.notifications_open = true;
        }
    }
}

// The open-thread generation, so a reply fetch can report completion for the
// thread it was launched for and not a later one. `g_thread_seq` is bumped on
// each open; the worker copies its seq and, when it has asked every relay,
// raises `g_thread_done_seq` to it. The UI thread clears the loading skeletons
// only when the CURRENT thread's fetch is the one that finished (so a genuinely
// empty thread stops loading, but a stale late worker never clears a new thread).
var g_thread_seq = std.atomic.Value(u64).init(0);
pub var g_thread_done_seq = std.atomic.Value(u64).init(0);

/// Records that the fetch for generation `seq` has asked every relay. Only ever
/// forward: a slow worker for a level the reader has already left finishes
/// after the newer level's, and a plain store put the mark back behind the open
/// level, which then read as still fetching for the rest of the visit.
fn finishLevelFetch(seq: u64) void {
    _ = g_thread_done_seq.fetchMax(seq, .acq_rel);
}

/// The way a worker reports, for a test that plays a late one.
pub fn finishLevelFetchLateForTest(seq: u64) void {
    finishLevelFetch(seq);
}

const topic_kinds = [_]u16{1};

/// The filter for a topic: kind:1 notes carrying a `t` tag with this value,
/// newest `thread_reply_cap`. One definition for the store read and the relay
/// ask, so the two cannot drift into answering different questions.
///
/// Jumble sends `{"#t":[tag]}` to its default relays with the tag lowercased
/// (src/pages/secondary/NoteListPage/index.tsx:49, src/lib/link.ts:29), and
/// Amethyst keys the subscription on the lowercased tag and asks for kind 1
/// among others (HashtagFeedFilterSubAssembler.kt, FilterPostsByHashtags.kt:81-95).
/// NIP-24 says `t` values are lowercase, which `openTopic` guarantees.
pub fn topicFilter(values: *const [1][]const u8, tags: *[1]nostr.filter.TagFilter) nostr.filter.Filter {
    tags.* = .{.{ .letter = 't', .values = values }};
    return .{ .kinds = &topic_kinds, .tags = tags, .limit = thread_reply_cap };
}
/// Asks this reader's read relays for a topic, once. A topic has no author, so
/// there is no outbox question to answer: the relays this reader already reads
/// are the honest set, rather than a search relay nobody chose.
fn fetchTopicNotes(topic: []const u8, seq: u64) void {
    if (!relayFetchAllowed() or topic.len == 0 or topic.len > max_topic_bytes) {
        finishLevelFetch(seq);
        return;
    }
    var owned: [max_topic_bytes]u8 = undefined;
    @memcpy(owned[0..topic.len], topic);
    const thread = std.Thread.spawn(.{}, fetchTopicWorker, .{ owned, @as(u8, @intCast(topic.len)), seq }) catch {
        finishLevelFetch(seq);
        return;
    };
    thread.detach();
}

fn fetchTopicWorker(topic_buf: [max_topic_bytes]u8, topic_len: u8, seq: u64) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    defer finishLevelFetch(seq);

    const topic = topic_buf[0..topic_len];
    const values = [_][]const u8{topic};
    var tags: [1]nostr.filter.TagFilter = undefined;
    const filters = [_]nostr.filter.Filter{topicFilter(&values, &tags)};

    for (0..relaySlots()) |ri| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        if (!entry.read) continue;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have let
        // go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse continue;
        defer releaseOneShot(watched);
        relay.subscribe("plaza-topic", &filters) catch continue;
        var seen: usize = 0;
        // Bounded, for the reason the profile fetch is: `receive` has no
        // deadline, and a relay that accepts a subscription and then goes quiet
        // would hold this thread for the life of the process.
        while (seen < profile_fetch_messages) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    if (e.event.kind != 1) continue;
                    const result = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, entry.url) catch continue;
                    if (result == .invalid) continue;
                },
                .eose => break,
                // A CLOSED ends this relay's part, and no EOSE is coming after it.
                .closed => break,
                else => {},
            }
        }
        relay.unsubscribe("plaza-topic") catch {};
    }
}

/// Fetches a person's recent notes (and their engagement) into the store, on a
/// detached thread. Mirrors the thread's two-phase backfill exactly: one dial per
/// read relay, their kind:1s, then on EOSE a second subscription for what those
/// notes collected, folding into the same engagement table the feed and threads
/// use. Without the second phase every row on a profile shows zero counts.
fn fetchProfileNotes(pubkey: [32]u8, seq: u64) void {
    // Opening a page is asking again, so the end of its history is forgotten:
    // the relays may hold more than they did, and the relay set may be another.
    resetProfileEnd();
    if (!relayFetchAllowed()) {
        finishLevelFetch(seq);
        return;
    }
    const thread = std.Thread.spawn(.{}, fetchProfileWorker, .{ pubkey, seq }) catch {
        finishLevelFetch(seq);
        return;
    };
    thread.detach();
}

fn fetchProfileWorker(pubkey: [32]u8, seq: u64) void {
    defer finishLevelFetch(seq);
    _ = profileRound(pubkey, null);
}
/// How many frames one relay gets to answer a profile's backfill before this
/// thread moves on. See the comment in `fetchProfileWorker`.
pub const profile_fetch_messages = 400;

/// One engagement query over prepared `#e` values.
///
/// Three screens ask this same question, and each used to write it out again.
/// They drifted: the thread and the profile capped the answer, and the feed's,
/// which is the one re-issued on every reconnect, carried no cap at all, so a
/// busy relay decided how much of four kinds across 128 note ids to send back.
/// One function now, so there is nothing left to drift.
pub fn engagementFilter(tags: []const nostr.filter.TagFilter) nostr.filter.Filter {
    return .{ .kinds = engagementKinds(), .tags = tags, .limit = engagement_request_limit };
}
fn fetchThreadReplies(root_id: [32]u8, seq: u64) void {
    if (!relayFetchAllowed()) {
        finishLevelFetch(seq);
        return;
    }
    const thread = std.Thread.spawn(.{}, fetchRepliesWorker, .{ root_id, seq }) catch {
        finishLevelFetch(seq);
        return;
    };
    thread.detach();
}

fn fetchRepliesWorker(root_id: [32]u8, seq: u64) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // The note the reader pressed, and the ROOT of the conversation it sits in.
    //
    // Usually the same note, and when they are not, asking only about the note
    // pressed asks a question almost nothing answers. NIP-10 says a reply
    // carries an `e` tag for the ROOT and one for its immediate parent, so a
    // grandchild of the note in the reader's hand names its own parent and the
    // root, and never the note in between. Opening a reply from the feed
    // therefore fetched that note's direct children and nothing else: no
    // siblings, no parent, no root post, and nothing under those children. The
    // ancestors then trickled in one hop at a time through the quote fetcher,
    // which is why an old conversation took several seconds to assemble.
    //
    // Both ids go into ONE filter. Keeping the pressed note in it is what makes
    // this safe when a root tag is missing, wrong, or points somewhere else:
    // that note's own children still match.
    var thread_ids: [2][32]u8 = undefined;
    var thread_count: usize = 1;
    thread_ids[0] = root_id;
    if (main.g_store) |store| {
        if (store.getEvent(gpa, root_id) catch null) |se| {
            var owned = se;
            defer owned.deinit();
            thread_count = threadQueryIds(root_id, owned.event.kind, owned.event.tags, &thread_ids);
        }
    }
    var thread_hex: [2][64]u8 = undefined;
    var thread_evals: [2][]const u8 = undefined;
    var thread_watch: [2]i64 = undefined;
    for (0..thread_count) |i| {
        hexLower(&thread_hex[i], thread_ids[i]);
        thread_evals[i] = &thread_hex[i];
        thread_watch[i] = @intCast(std.mem.readInt(u64, thread_ids[i][0..8], .big) & std.math.maxInt(i64));
    }

    for (0..relaySlots()) |ri| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        // A read-only or read-write relay. Asking a write-only relay to answer
        // a filter is asking the wrong question of it.
        if (!entry.read) continue;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse continue;
        defer releaseOneShot(watched);

        // Phase 1: the replies themselves (kind:1 e-tagging the root). Collect
        // their ids as they arrive so phase 2 can watch their engagement too.
        var id_hex: [thread_reply_cap][64]u8 = undefined;
        var watch_ids: [thread_reply_cap + 2]i64 = undefined;
        var id_count: usize = 0;
        // The note pressed, and the conversation's root when that is a
        // different note, are both watched from the start so their own counts
        // refresh alongside the replies'.
        var watch_len: usize = 0;
        while (watch_len < thread_count) : (watch_len += 1) watch_ids[watch_len] = thread_watch[watch_len];

        // Comments too, or a thread never FETCHES the half of itself written
        // in the other vocabulary. The walk that assembles a thread admits them
        // now, but it reads the local store, and nothing was putting them
        // there: the conversation stayed exactly as holed as before.
        //
        // The `#e` filter finds them without a second one. NIP-22 has a
        // top-level comment repeat its uppercase scope in the lowercase tags,
        // so a comment on the root carries `e` = the root, and a nested one
        // carries `e` = the comment it answers, which is a thread member by
        // the time it matters.
        const reply_kinds = [_]u16{ 1, comment_kind };
        const reply_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = thread_evals[0..thread_count] }};
        const reply_filters = [_]nostr.filter.Filter{.{ .kinds = &reply_kinds, .tags = &reply_tags, .limit = thread_reply_cap }};
        relay.subscribe("plaza-thread", &reply_filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    _ = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, entry.url) catch {};
                    // Queue the replier's profile so a name and face resolve.
                    wantProfile(e.event.pubkey);
                    if (id_count < thread_reply_cap) {
                        hexLower(&id_hex[id_count], e.event.id);
                        id_count += 1;
                        watch_ids[watch_len] = noteIdOf(e.event);
                        watch_len += 1;
                    }
                },
                .eose => break,
                // A CLOSED ends this relay's part, and no EOSE is coming after it.
                .closed => break,
                else => {},
            }
        }

        // Phase 2: engagement on the root and every reply (replies, reposts,
        // likes, zaps), folded into the shared table so the thread shows real
        // metrics on each row, the same counts the feed shows.
        var evals: [thread_reply_cap + 2][]const u8 = undefined;
        var eval_len: usize = 0;
        while (eval_len < thread_count) : (eval_len += 1) evals[eval_len] = thread_evals[eval_len];
        for (0..id_count) |i| {
            evals[eval_len] = &id_hex[i];
            eval_len += 1;
        }
        const eng_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = evals[0..eval_len] }};
        const eng_filters = [_]nostr.filter.Filter{engagementFilter(&eng_tags)};
        relay.subscribe("plaza-thread-eng", &eng_filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    if (nostr.event.verify(gpa, signer, e.event) catch false)
                        countEngagement(e.event, watch_ids[0..watch_len]);
                },
                .eose => break,
                // A CLOSED ends this relay's part, and no EOSE is coming after it.
                .closed => break,
                else => {},
            }
        }
    }
    // Every relay has been asked: the reply set is as complete as it will get, so
    // the UI can stop showing loading skeletons even if nothing came back.
    finishLevelFetch(seq);
}

/// Marks a thread's reply fetch as finished, the way its worker does.
pub fn markThreadFetchDoneForTest(seq: u64) void {
    g_thread_done_seq.store(seq, .release);
}
/// Marks the fetch for generation `seq` as finished, the way its worker does
/// when every relay has answered, for a test that has no worker.
pub fn finishLevelFetchForTest(seq: u64) void {
    g_thread_done_seq.store(seq, .release);
}
/// The level bookkeeping, for a test that walks a stack up and down. Both take
/// the same paths the app does, so what they assert is what a reader gets.
pub fn enterThreadForTest(model: *Model, root: Note) void {
    enterThread(model, root);
}

pub fn closeThreadForTest(model: *Model) void {
    closeThread(model);
}

pub fn feedEndLatchesForTest(asked: usize, answered: usize, added: usize) bool {
    return feedEndLatches(asked, answered, added);
}
pub fn setFeedEndForTest() void {
    g_feed_end_reached.store(true, .monotonic);
}

pub fn resetFeedEndForTest() void {
    resetFeedEnd();
    g_older_busy.store(false, .monotonic);
}

pub fn openTopicForTest(model: *Model, topic: []const u8) void {
    openTopic(model, topic);
}

pub fn openBookmarksForTest(model: *Model) void {
    openBookmarks(model);
}

pub fn enterProfileForTest(model: *Model, pubkey: [32]u8) void {
    enterProfile(model, pubkey);
}
/// Drives the REAL entry path, so what the test asserts is what a reader gets.
pub fn openEventForTest(model: *Model, id: [32]u8) void {
    openEvent(model, id);
}

/// One tick of the store-side half of that fetch.
pub fn refreshEventFetchForTest(model: *Model) void {
    refreshEventFetch(model);
}

/// Whether the window is still watching. Closed is what both walking away and
/// arriving must produce: an open window keeps reading the store every tick.
pub fn eventFetchArmedForTest() bool {
    return g_event_want != null;
}

pub fn forgetEventFetchForTest() void {
    g_event_want = null;
}

pub fn goHomeForTest(model: *Model) void {
    goHome(model);
}

/// The REQ a topic sends, as the relay receives it.
pub fn topicReqForTest(gpa: std.mem.Allocator, topic: []const u8) ![]u8 {
    const values = [_][]const u8{topic};
    var tags: [1]nostr.filter.TagFilter = undefined;
    const filters = [_]nostr.filter.Filter{topicFilter(&values, &tags)};
    return nostr.message.encodeReq(gpa, "plaza-topic", &filters);
}
/// Puts the page's first fetch back in flight, or lands it, for a test that has
/// no socket to do either.
pub fn setFirstProfileFetchOutForTest(model: *Model, out: bool) void {
    const done = g_thread_done_seq.load(.acquire);
    if (out) {
        model.thread_seq = done + 1;
    } else {
        g_thread_done_seq.store(model.thread_seq, .release);
    }
}

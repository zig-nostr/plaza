//! Finding a person: the local index, the relays asked, and NIP-05 lookups.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const profile_cache = @import("profile_cache.zig");
const search = @import("search.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const Model = main.Model;
const Nip05Address = main.Nip05Address;
const activePubkey = main.activePubkey;
const classifySearch = main.classifySearch;
const closeAddress = main.closeAddress;
const contact_list_kind = main.contact_list_kind;
const hexLower = main.hexLower;
const inFollowGraph = main.inFollowGraph;
const ingest_wake = main.ingest_wake;
const isMuted = main.isMuted;
const leaveSettings = main.leaveSettings;
const networkAllowed = main.networkAllowed;
const nip05Address = main.nip05Address;
const nip05LookupUrl = main.nip05LookupUrl;
const nip05Resolve = main.nip05Resolve;
const nip05_lookup_key_base = main.nip05_lookup_key_base;
const nip05_lookup_keys = main.nip05_lookup_keys;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const openAddress = main.openAddress;
const openPerson = main.openPerson;
const parseMetadataInto = main.parseMetadataInto;
const plazaIngest = main.plazaIngest;
const relayFetchAllowed = main.relayFetchAllowed;
const relaysPaused = main.relaysPaused;
const releaseOneShot = main.releaseOneShot;
const upsertProfile = main.upsertProfile;
const wantProfileHinted = main.wantProfileHinted;
const watchOneShot = main.watchOneShot;

// ------------------------------------------------------- finding a person
//
// The field that opens an address finds people by name as well, because it is
// the one place somebody goes to say who they mean. Two sources answer it, and
// they are not mixed up: every profile already on this machine, instantly and
// with the network off, then NIP-50 search relays, whose results are folded in
// as they land and each marked with the relay that gave it.

/// Most rows the results list holds, and how many of those can be people the
/// store already knew. This is a node budget as much as a taste: the sheet is
/// stacked over the feed, and a row costs about a dozen of the 1024 nodes a view
/// may have.
pub const search_rows_max = 20;
const search_local_max = 12;
/// How many kind:0 events one page of the index build reads, and the most it
/// reads in all. The store keeps one kind:0 per author, so this is a ceiling on
/// people. Newest first, so a store larger than this loses its oldest profiles
/// from the instant half, not its recent ones.
pub const search_scan_page = 1024;
const search_scan_max = 32 * 1024;
/// How many contact lists name the reader, at most, when working out who follows
/// them.
const search_followers_max = 4096;
/// Seconds an index may be old before opening the field builds a new one.
const search_index_ttl_s: i64 = 30;
/// Quiet time after the last keystroke before a name goes to the relays. A name
/// is put to three strangers, so it waits until the reader has stopped typing.
const search_settle_ms: i64 = 600;
/// Shortest term that goes to relays on its own. Enter sends anything.
const search_auto_min = 2;
/// Frames one relay may spend on a search before it is let go.
const search_frames_max = 200;

/// One line of the results.
pub const SearchRow = struct {
    pubkey: [32]u8,
    /// The store already had this person.
    local: bool,
    /// Bit `i` set: search relay `i` returned them.
    relays: u8,
};

pub var g_search_rows: [search_rows_max]SearchRow = undefined;
pub var g_search_len: usize = 0;
/// The term the rows answer, in the form that was searched.
pub var g_search_term: [search.term_max]u8 = undefined;
pub var g_search_term_len: usize = 0;
/// Moves every time the term changes, so an answer to an earlier term that
/// arrives late is recognised and dropped.
pub var g_search_gen = std.atomic.Value(u32).init(0);
/// The generation already put to the relays.
pub var g_search_asked: u32 = 0;
/// When the term last changed, on the awake clock.
pub var g_search_typed_ms: i64 = 0;
/// Where each search relay stands, as a packed `search.Status`.
pub var g_search_status: [search.relays_max]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
/// The generation each search relay has been put, so a relay that was busy when
/// the term settled is asked once it is free.
var g_search_slot_asked: [search.relays_max]u32 = @splat(0);
/// Which generation's thread is out for each search relay, plus one, or 0 when
/// none is. The dial has no deadline of its own, so a relay that never
/// completes the handshake parks its thread before the read budget starts; a
/// fresh thread per settled term on top of that grew without bound while the
/// reader typed.
var g_search_claim: [search.relays_max]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
/// When each claim was taken, on the awake clock. Every claim is made on the UI
/// thread, and only a claim reads it, so it needs no lock.
var g_search_claimed_ms: [search.relays_max]i64 = @splat(0);
/// How many threads are out for each search relay, the one holding the claim
/// and any it took over from that have not ended yet.
var g_search_workers: [search.relays_max]std.atomic.Value(u8) = @splat(std.atomic.Value(u8).init(0));
/// The most threads one search relay may have out. A takeover leaves the old
/// thread parked in its dial, so without a ceiling a relay that takes the TCP
/// connection and never finishes the handshake gained a stuck thread and a
/// socket every `one_shot_budget_ms` for as long as the reader typed.
const search_workers_max = 2;

fn searchClaimToken(gen: u32) u64 {
    return @as(u64, gen) + 1;
}

/// Takes search relay `i` for generation `gen` at `now_ms`: false when it has
/// already been put this term, or when its previous thread is still out, in
/// which case a later tick asks again.
///
/// A thread out longer than `one_shot_budget_ms` for an earlier term is taken
/// over. Its dial has no deadline, so a handshake that never finishes held the
/// relay for the rest of the session, and no later term reached it. A relay
/// that already has `search_workers_max` threads out is not taken over again
/// until one of them ends.
fn claimSearchSlot(i: usize, gen: u32, now_ms: i64) bool {
    if (g_search_slot_asked[i] == gen) return false;
    if (g_search_workers[i].load(.acquire) >= search_workers_max) return false;
    const held = g_search_claim[i].load(.acquire);
    if (held != 0) {
        if (held >= searchClaimToken(gen)) return false;
        if (now_ms - g_search_claimed_ms[i] <= one_shot_budget_ms) return false;
    }
    if (g_search_claim[i].cmpxchgStrong(held, searchClaimToken(gen), .acq_rel, .acquire) != null) return false;
    g_search_claimed_ms[i] = now_ms;
    g_search_slot_asked[i] = gen;
    _ = g_search_workers[i].fetchAdd(1, .acq_rel);
    return true;
}

/// Lets go of relay `i`, but only the claim generation `gen` made. A thread
/// whose claim was taken over ends late, and freeing the slot then would let a
/// second thread in beside the one that holds it now. Either way the thread is
/// no longer out: every successful claim is released exactly once.
fn releaseSearchSlot(i: usize, gen: u32) void {
    _ = g_search_claim[i].cmpxchgStrong(searchClaimToken(gen), 0, .acq_rel, .monotonic);
    _ = g_search_workers[i].fetchSub(1, .acq_rel);
}

/// A person a relay returned, on its way from the thread that read it to the one
/// that draws it.
const SearchArrival = struct { gen: u32, relay: u8, pubkey: [32]u8 };
/// Room for every relay's full answer between two ticks. The tick drains once a
/// second and three relays can each send `relay_limit` people well inside that,
/// so a smaller inbox dropped the later relays' answers: their people never
/// appeared, and people already listed lost the mark naming them.
pub const search_inbox_cap = search.relays_max * search.relay_limit;
var g_search_inbox: [search_inbox_cap]SearchArrival = undefined;
var g_search_inbox_len: usize = 0;
var g_search_inbox_lock = std.atomic.Value(bool).init(false);

fn lockSearchInbox() void {
    while (g_search_inbox_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn unlockSearchInbox() void {
    g_search_inbox_lock.store(false, .release);
}

/// Every profile on this machine with something to match on. Replaced whole by
/// a worker; held under `g_search_index_lock` by anything that reads it.
pub var g_search_index: search.Index = .{};
pub var g_search_index_ready = false;
var g_search_index_built_s: i64 = 0;
var g_search_index_lock = std.atomic.Value(bool).init(false);
var g_search_index_building = std.atomic.Value(bool).init(false);

pub fn lockSearchIndex() void {
    while (g_search_index_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockSearchIndex() void {
    g_search_index_lock.store(false, .release);
}

/// The relays a name is put to, by slot.
pub fn searchRelays() []const []const u8 {
    return &search.default_relays;
}

pub fn awakeMs() i64 {
    const io = main.g_io orelse return 0;
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// The term on screen, cleaned, or null when the field holds no name.
fn searchTermOf(model: *const Model, out: *[search.term_max]u8) ?[]const u8 {
    return switch (classifySearch(model.address_buffer.text())) {
        .blank, .address, .key => null,
        .nip05, .term => search.cleanTerm(out, model.address_buffer.text()),
    };
}

/// Forgets the results and cancels whatever was still on its way.
pub fn searchReset() void {
    _ = g_search_gen.fetchAdd(1, .acq_rel);
    g_search_len = 0;
    g_search_term_len = 0;
    lockSearchInbox();
    g_search_inbox_len = 0;
    unlockSearchInbox();
    for (&g_search_status) |*s| s.store(0, .release);
}

/// The field has opened: nothing to show yet, and a fresh index on its way so
/// the first letters typed are matched against everything held.
pub fn searchOpen() void {
    searchReset();
    searchIndexEnsure();
}

/// The field's text changed. The instant half answers now, synchronously; the
/// relays are asked once typing settles, from the tick.
pub fn searchOnEdit(model: *const Model) void {
    searchReset();
    var buf: [search.term_max]u8 = undefined;
    const term = searchTermOf(model, &buf) orelse return;
    @memcpy(g_search_term[0..term.len], term);
    g_search_term_len = term.len;
    g_search_typed_ms = awakeMs();
    searchRunLocal(term);
}

/// Matches `term` against every profile held and fills the list with the best.
fn searchRunLocal(term: []const u8) void {
    var picked: [search_local_max][32]u8 = undefined;
    var n: usize = 0;
    var hits: [search_local_max * 2]search.Hit = undefined;

    lockSearchIndex();
    const have_index = g_search_index_ready;
    if (have_index) {
        const found = g_search_index.find(term, &hits);
        for (hits[0..found]) |hit| {
            if (n == picked.len) break;
            const pk = g_search_index.entries[hit.entry].pubkey;
            if (isMuted(pk)) continue;
            picked[n] = pk;
            n += 1;
        }
    }
    unlockSearchIndex();

    // Before the index has been built (the first moments after a launch, or no
    // store at all) the profiles the app already holds in memory answer, which
    // is what the mention picker has always done.
    if (!have_index) n = searchCachePick(term, &picked);

    g_search_len = 0;
    for (picked[0..n]) |pk| {
        g_search_rows[g_search_len] = .{ .pubkey = pk, .local = true, .relays = 0 };
        g_search_len += 1;
    }
    hydrateProfiles(picked[0..n]);
}

/// The cache-only answer: the in-memory profiles, ranked the same way.
fn searchCachePick(term: []const u8, out: *[search_local_max][32]u8) usize {
    const gpa = std.heap.page_allocator;
    var builder = search.Builder.init(gpa);
    defer builder.deinit();
    for (&profile_cache.g_profiles) |*pr| {
        if (!pr.used) continue;
        const tier: search.Tier = if (inFollowGraph(pr.pubkey)) .follows else .seen;
        builder.add(pr.pubkey, tier, 0, pr.name(), pr.username(), pr.nip05()) catch return 0;
    }
    var index = builder.finish() catch return 0;
    defer index.deinit(gpa);
    var hits: [search_local_max * 2]search.Hit = undefined;
    const found = index.find(term, &hits);
    var n: usize = 0;
    for (hits[0..found]) |hit| {
        if (n == out.len) break;
        const pk = index.entries[hit.entry].pubkey;
        if (isMuted(pk)) continue;
        out[n] = pk;
        n += 1;
    }
    return n;
}

/// Reads the kind:0 of each person from the store into the profile cache, so a
/// row can draw a name rather than a key. Disk first and exact, as the wanted
/// profiles pass has always done: the store has an author+kind index.
pub fn hydrateProfiles(pubkeys: []const [32]u8) void {
    if (pubkeys.len == 0) return;
    const store = main.g_store orelse return;
    const kinds = [_]u16{0};
    var result = store.query(std.heap.page_allocator, .{ .authors = pubkeys, .kinds = &kinds, .limit = @intCast(pubkeys.len) }) catch return;
    defer result.deinit();
    for (result.events) |ev| {
        const prof = upsertProfile(ev.pubkey) orelse continue;
        if (std.mem.eql(u8, &prof.meta_id, &ev.id)) continue;
        parseMetadataInto(prof, ev.content);
        prof.meta_id = ev.id;
        profile_cache.g_names_generation +%= 1;
    }
}

// --- the index

/// Builds a fresh index on a worker if the one held is missing or old.
fn searchIndexEnsure() void {
    if (comptime builtin.is_test) return;
    if (main.g_store == null) return;
    // Under the lock: the worker writes both of these from its own thread.
    const now = nowSeconds();
    lockSearchIndex();
    const fresh = g_search_index_ready and now - g_search_index_built_s < search_index_ttl_s;
    unlockSearchIndex();
    if (fresh) return;
    if (g_search_index_building.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, searchIndexWorker, .{}) catch {
        g_search_index_building.store(false, .release);
        return;
    };
    thread.detach();
}

fn searchIndexWorker() void {
    defer g_search_index_building.store(false, .release);
    searchIndexRefresh();
}

/// The accounts whose contact lists name the reader. The store can only say who
/// follows the reader among the lists it holds, which is the honest meaning of
/// "people who follow me" here: nothing local can know about a list never read.
fn searchFollowers(gpa: std.mem.Allocator, store: *nostr.store.Store) std.AutoHashMapUnmanaged([32]u8, void) {
    var set: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    const me = activePubkey() orelse return set;
    var hex: [64]u8 = undefined;
    hexLower(&hex, me);
    const kinds = [_]u16{contact_list_kind};
    const values = [_][]const u8{&hex};
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &values }};
    var result = store.query(gpa, .{ .kinds = &kinds, .tags = &tags, .limit = search_followers_max }) catch return set;
    defer result.deinit();
    for (result.events) |ev| set.put(gpa, ev.pubkey, {}) catch break;
    return set;
}

/// Reads every kind:0 in the store into a new index and swaps it in.
pub fn searchIndexRefresh() void {
    const store = main.g_store orelse return;
    const gpa = std.heap.page_allocator;
    var builder = search.Builder.init(gpa);
    defer builder.deinit();
    var followers = searchFollowers(gpa, store);
    defer followers.deinit(gpa);
    var added: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    defer added.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    const Meta = struct {
        name: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        displayName: ?[]const u8 = null,
        nip05: ?[]const u8 = null,
    };

    var until: ?i64 = null;
    var scanned: usize = 0;
    while (scanned < search_scan_max) {
        const kinds = [_]u16{0};
        var page = store.query(gpa, .{ .kinds = &kinds, .until = until, .limit = search_scan_page }) catch break;
        defer page.deinit();
        if (page.events.len == 0) break;
        var fresh: usize = 0;
        for (page.events) |ev| {
            scanned += 1;
            if (added.contains(ev.pubkey)) continue;
            _ = scratch.reset(.retain_capacity);
            const meta = std.json.parseFromSliceLeaky(Meta, scratch.allocator(), ev.content, .{ .ignore_unknown_fields = true }) catch continue;
            // The same choice `parseMetadataInto` makes, so the row that is
            // drawn is named by the string that was matched.
            var shown: []const u8 = "";
            for ([_]?[]const u8{ meta.displayName, meta.display_name, meta.name }) |candidate| {
                const trimmed = std.mem.trim(u8, candidate orelse continue, " \t\r\n");
                if (trimmed.len == 0) continue;
                shown = trimmed;
                break;
            }
            const user = std.mem.trim(u8, meta.name orelse "", " \t\r\n");
            var address = std.mem.trim(u8, meta.nip05 orelse "", " \t\r\n");
            if (std.mem.indexOfScalar(u8, address, '@') == null) address = "";
            const tier: search.Tier = if (inFollowGraph(ev.pubkey)) .follows else if (followers.contains(ev.pubkey)) .follows_me else .seen;
            builder.add(ev.pubkey, tier, ev.created_at, shown, user, address) catch break;
            added.put(gpa, ev.pubkey, {}) catch break;
            fresh += 1;
        }
        if (page.events.len < search_scan_page) break;
        const oldest = page.events[page.events.len - 1].created_at;
        // A whole page inside one second that brought nothing new will bring
        // nothing new again.
        if (until != null and until.? == oldest and fresh == 0) break;
        until = oldest;
    }

    var fresh_index = builder.finish() catch return;
    const built_s = nowSeconds();
    lockSearchIndex();
    std.mem.swap(search.Index, &g_search_index, &fresh_index);
    g_search_index_ready = true;
    g_search_index_built_s = built_s;
    unlockSearchIndex();
    fresh_index.deinit(gpa);
}

// --- the relays

/// What one relay thread is told.
pub const SearchJob = struct {
    gen: u32,
    relay: u8,
    url: []const u8,
    term: [search.term_max]u8,
    term_len: u8,
};

/// Puts the term on screen to the search relays, once per term and relay. Runs
/// every tick while the term stands: a relay whose previous thread was still
/// out is asked here once that thread has gone.
fn searchAskRelays(now_ms: i64) void {
    const gen = g_search_gen.load(.acquire);
    if (g_search_term_len == 0) return;
    g_search_asked = gen;
    if (!relayFetchAllowed()) return;
    const urls = searchRelays();
    for (urls, 0..) |url, i| {
        if (i >= search.relays_max) break;
        if (g_search_slot_asked[i] == gen) continue;
        if (relaysPaused()) {
            g_search_slot_asked[i] = gen;
            g_search_status[i].store((search.Status{ .gen = gen, .state = .paused, .count = 0 }).pack(), .release);
            continue;
        }
        if (!claimSearchSlot(i, gen, now_ms)) continue;
        g_search_status[i].store((search.Status{ .gen = gen, .state = .asking, .count = 0 }).pack(), .release);
        var job = SearchJob{ .gen = gen, .relay = @intCast(i), .url = url, .term = undefined, .term_len = @intCast(g_search_term_len) };
        @memcpy(job.term[0..g_search_term_len], g_search_term[0..g_search_term_len]);
        const thread = std.Thread.spawn(.{}, searchRelayWorker, .{job}) catch {
            releaseSearchSlot(i, gen);
            g_search_status[i].store((search.Status{ .gen = gen, .state = .unreachable_, .count = 0 }).pack(), .release);
            continue;
        };
        thread.detach();
    }
}

/// Sends a search request, unless the term has moved on while the socket
/// opened. The dial can take seconds, and a term the reader has since replaced
/// or cleared is not theirs to send any more. False when nothing was sent.
fn searchSendCurrent(job: SearchJob, sender: anytype, request: []const u8) !bool {
    if (g_search_gen.load(.acquire) != job.gen) return false;
    try sender.send(request);
    return true;
}

/// `searchSendCurrent`'s way onto a live connection.
const SearchRelaySender = struct {
    relay: *nostr.relay.Relay,
    fn send(self: SearchRelaySender, text: []const u8) !void {
        return search.sendText(self.relay, text);
    }
};

/// Publishes a relay's outcome, unless the term has moved on.
fn searchPublish(job: SearchJob, state: search.RelayState, count: u16) void {
    if (g_search_gen.load(.acquire) != job.gen) return;
    g_search_status[job.relay].store((search.Status{ .gen = job.gen, .state = state, .count = count }).pack(), .release);
}

/// Keeps one person a relay returned: verified, stored, and queued for the list.
/// False when the event is not a profile, does not verify, names somebody this
/// relay already named, or comes after the `relay_limit` people it was asked
/// for. `seen` is this relay's own list for this term.
///
/// A relay that ignores `limit` is otherwise a firehose into the shared inbox,
/// which has room for every relay's full answer and no more: one relay sending
/// hundreds crowded the others' people out of it.
pub fn searchAccept(gpa: std.mem.Allocator, signer: nostr.keys.Signer, job: SearchJob, ev: nostr.event.Event, seen: *search.Seen) bool {
    if (ev.kind != 0) return false;
    if (seen.len >= search.relay_limit) return false;
    const result = plazaIngest(gpa, ev, .{ .verify_with = signer }) catch return false;
    if (result == .invalid) return false;
    if (!seen.add(ev.pubkey)) return false;
    searchArrived(job.gen, job.relay, ev.pubkey);
    return true;
}

pub fn searchArrived(gen: u32, relay: u8, pubkey: [32]u8) void {
    lockSearchInbox();
    defer unlockSearchInbox();
    // A full inbox drops the newest: the list is as full as it will get long
    // before this many people have been named.
    if (g_search_inbox_len == g_search_inbox.len) return;
    g_search_inbox[g_search_inbox_len] = .{ .gen = gen, .relay = relay, .pubkey = pubkey };
    g_search_inbox_len += 1;
}

/// Asks one search relay for profiles matching the term, on its own thread.
fn searchRelayWorker(job: SearchJob) void {
    defer releaseSearchSlot(job.relay, job.gen);
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var state: search.RelayState = .unreachable_;
    var found: u16 = 0;
    // Who this relay has named, so two versions of one profile count once.
    var seen: search.Seen = .{};
    defer searchPublish(job, state, found);

    var relay = nostr.relay.dial(gpa, io, job.url) catch return;
    defer relay.deinit();
    // Bounded by the keeper like every other one-shot read: a relay that takes
    // the request and goes quiet must not hold this thread for the life of the
    // process.
    const watched = watchOneShot(io, relay, one_shot_budget_ms);
    defer releaseOneShot(watched);
    const request = search.requestText(gpa, job.term[0..job.term_len]) catch return;
    defer gpa.free(request);
    if (!(searchSendCurrent(job, SearchRelaySender{ .relay = relay }, request) catch return)) return;
    // Asked. From here a relay that never says anything is a quiet one, not one
    // that could not be reached.
    state = .silent;

    // Read in slices of a second rather than parked in `receive`. A thread
    // blocked there cannot see that the term has moved on, and kept a socket
    // and a keeper slot for a search nobody was looking at until the relay next
    // spoke. The deadline is its own as well as the keeper's, so the thread ends
    // even when the keeper's table was full and nothing is watching it.
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + one_shot_budget_ms;
    var frames: usize = 0;
    while (frames < search_frames_max) {
        if (g_search_gen.load(.acquire) != job.gen) return;
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) break;
        var msg = (relay.receiveTimeout(ingest_wake) catch |err| switch (err) {
            error.Timeout => continue,
            else => break,
        }) orelse break;
        defer msg.deinit();
        frames += 1;
        const reply: search.Reply = switch (msg.value) {
            .event => |e| blk: {
                if (searchAccept(gpa, signer, job, e.event, &seen)) found +|= 1;
                break :blk .event;
            },
            .eose => .eose,
            .closed => .closed,
            .notice => .notice,
            .auth => .auth,
            else => .other,
        };
        if (search.settle(reply, found)) |done| {
            state = done;
            return;
        }
    }
    // The connection ended, or the budget did, with people already in hand.
    if (found > 0) state = .answered;
}

/// Moves what the relay threads found into the list, on the UI thread.
fn searchDrain() void {
    var batch: [search_inbox_cap]SearchArrival = undefined;
    lockSearchInbox();
    const n = g_search_inbox_len;
    @memcpy(batch[0..n], g_search_inbox[0..n]);
    g_search_inbox_len = 0;
    unlockSearchInbox();
    if (n == 0) return;

    const gen = g_search_gen.load(.acquire);
    var fresh: [search_inbox_cap][32]u8 = undefined;
    var fresh_len: usize = 0;
    for (batch[0..n]) |arrival| {
        if (arrival.gen != gen) continue;
        const bit: u8 = @as(u8, 1) << @intCast(arrival.relay);
        var known = false;
        for (g_search_rows[0..g_search_len]) |*row| {
            if (!std.mem.eql(u8, &row.pubkey, &arrival.pubkey)) continue;
            row.relays |= bit;
            known = true;
            break;
        }
        if (known or g_search_len == search_rows_max or isMuted(arrival.pubkey)) continue;
        g_search_rows[g_search_len] = .{ .pubkey = arrival.pubkey, .local = false, .relays = bit };
        g_search_len += 1;
        fresh[fresh_len] = arrival.pubkey;
        fresh_len += 1;
    }
    hydrateProfiles(fresh[0..fresh_len]);
}

/// The tick's share: ask the relays once typing has settled, and take in what
/// they have sent. Only while the field is open.
pub fn searchTick(model: *const Model, now_ms: i64) void {
    if (!model.address_open) return;
    // A NIP-05 address is asked of its domain, so only a name is put to relays.
    if (searchTickAsks(model, now_ms)) searchAskRelays(now_ms);
    searchDrain();
}

/// Whether this tick puts the term to the relays: a name long enough to go on
/// its own once typing has settled, or a term already sent, however short. Enter
/// sends a term below `search_auto_min`, and a relay busy at that moment is
/// asked on a later tick like any other, not left out of that term.
fn searchTickAsks(model: *const Model, now_ms: i64) bool {
    // A NIP-05 address is asked of its domain, so only a name is put to relays.
    if (classifySearch(model.address_buffer.text()) != .term) return false;
    if (g_search_term_len == 0) return false;
    if (g_search_asked == g_search_gen.load(.acquire)) return true;
    return g_search_term_len >= search_auto_min and now_ms - g_search_typed_ms >= search_settle_ms;
}

/// How one relay stands for the term on screen. A status left over from an
/// earlier term reads as not asked.
pub fn searchRelayStatus(i: usize) search.Status {
    const s = search.Status.unpack(g_search_status[i].load(.acquire));
    if (s.gen != g_search_gen.load(.acquire)) return .{ .gen = 0, .state = .idle, .count = 0 };
    return s;
}

// --- NIP-05

/// The address being looked up, and whether the answer is awaited.
pub var g_nip05_ask: ?Nip05Address = null;
/// The key that lookup went out under. An answer under any other key is to an
/// earlier lookup, possibly for another domain, and is not this one's answer.
pub var g_nip05_ask_key: u64 = 0;
var g_nip05_seq: u64 = 0;

fn sameNip05(a: *const Nip05Address, b: *const Nip05Address) bool {
    return std.mem.eql(u8, a.name(), b.name()) and std.mem.eql(u8, a.domain(), b.domain());
}

/// Whether the address in the field is the one whose answer is awaited.
pub fn nip05Pending(text: []const u8) bool {
    const ask = g_nip05_ask orelse return false;
    const current = nip05Address(text) orelse return false;
    return sameNip05(&ask, &current);
}

/// Sends the lookup for `name@domain`. The domain is a stranger's, from the
/// reader's own address, which is why this waits for an explicit press instead
/// of running as they type.
fn lookupNip05(model: *Model, fx: *Effects) void {
    const addr = nip05Address(model.address_buffer.text()) orelse return;
    var url_buf: [320]u8 = undefined;
    const url = nip05LookupUrl(&url_buf, &addr) orelse {
        model.address_error = .unreadable;
        return;
    };
    g_nip05_seq +%= 1;
    g_nip05_ask_key = nip05_lookup_key_base + g_nip05_seq % nip05_lookup_keys;
    g_nip05_ask = addr;
    model.address_error = .none;
    if (!networkAllowed()) return;
    fx.fetch(.{
        .key = g_nip05_ask_key,
        .url = url,
        .on_response = Effects.responseMsg(.nip05_found),
    });
}

/// The well-known document came back. Goes to the person it names, if the
/// reader is still looking at the address they asked about.
pub fn handleNip05Found(model: *Model, response: native_sdk.EffectResponse) void {
    // An answer to an earlier lookup. It may be from another domain, and the
    // field may hold that same name at a new one: read as this lookup's answer,
    // the old domain would get to say who the new address is.
    if (response.key != g_nip05_ask_key) return;
    const ask = g_nip05_ask orelse return;
    g_nip05_ask = null;
    // The reader typed on, or left. The answer is to a question nobody is
    // asking any more.
    const current = nip05Address(model.address_buffer.text()) orelse return;
    if (!model.address_open) return;
    if (!sameNip05(&current, &ask)) return;

    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0) {
        model.address_error = .lookup_failed;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const hit = nip05Resolve(arena_state.allocator(), ask.name(), response.body) orelse {
        model.address_error = .not_found;
        return;
    };
    closeAddress(model);
    // The page is drawn under Settings, as an opened address is.
    if (model.stage == .settings) leaveSettings(model);
    wantProfileHinted(hit.pubkey, hit.relays);
    openPerson(model, hit.pubkey);
}

/// Pressing a result.
pub fn searchPick(model: *Model, pubkey: [32]u8) void {
    closeAddress(model);
    if (model.stage == .settings) leaveSettings(model);
    openPerson(model, pubkey);
}

/// What Enter does with what is in the field.
pub fn submitAddress(model: *Model, fx: *Effects) void {
    switch (classifySearch(model.address_buffer.text())) {
        // Nothing is done with a key, on purpose. See `SearchInput.key`.
        .blank, .key => {},
        .address => openAddress(model, fx),
        .nip05 => lookupNip05(model, fx),
        // Straight to the relays: pressing Enter is asking now, not after the
        // pause that typing waits for.
        .term => searchAskRelays(awakeMs()),
    }
}

// --- test seams

/// Back to a fresh start: no index, no rows, no relay state.
pub fn searchResetForTest() void {
    searchReset();
    lockSearchIndex();
    g_search_index.deinit(std.heap.page_allocator);
    g_search_index_ready = false;
    unlockSearchIndex();
    g_search_asked = 0;
    g_search_slot_asked = @splat(0);
    for (&g_search_claim) |*claim| claim.store(0, .release);
    g_search_claimed_ms = @splat(0);
    for (&g_search_workers) |*workers| workers.store(0, .release);
    g_search_typed_ms = 0;
    g_nip05_ask = null;
}

pub fn claimSearchSlotForTest(i: usize, gen: u32, now_ms: i64) bool {
    return claimSearchSlot(i, gen, now_ms);
}

pub fn releaseSearchSlotForTest(i: usize, gen: u32) void {
    releaseSearchSlot(i, gen);
}

/// Whether a tick at `now_ms` would put the term on screen to the relays.
pub fn searchTickAsksForTest(model: *const Model, now_ms: i64) bool {
    return searchTickAsks(model, now_ms);
}

/// Whether a request built for generation `gen` would go out now, through
/// `sender`, a test's stand-in for the connection.
pub fn searchSendCurrentForTest(gen: u32, sender: anytype, request: []const u8) !bool {
    const job = SearchJob{ .gen = gen, .relay = 0, .url = "", .term = undefined, .term_len = 0 };
    return searchSendCurrent(job, sender, request);
}

/// Builds the index now, on this thread, from the store.
pub fn searchIndexRefreshForTest() void {
    searchIndexRefresh();
}

pub fn searchIndexLenForTest() usize {
    lockSearchIndex();
    defer unlockSearchIndex();
    return g_search_index.entries.len;
}

pub fn searchRowCountForTest() usize {
    return g_search_len;
}

pub fn searchRowPubkeyForTest(i: usize) [32]u8 {
    return g_search_rows[i].pubkey;
}

pub fn searchRowLocalForTest(i: usize) bool {
    return g_search_rows[i].local;
}

/// Bit `n` set means search relay `n` returned this row.
pub fn searchRowRelaysForTest(i: usize) u8 {
    return g_search_rows[i].relays;
}

pub fn searchTickForTest(model: *const Model, now_ms: i64) void {
    searchTick(model, now_ms);
}

/// Whether the term on screen has been put to the relays.
pub fn searchAskedForTest() bool {
    return g_search_term_len > 0 and g_search_asked == g_search_gen.load(.acquire);
}

pub fn searchGenForTest() u32 {
    return g_search_gen.load(.acquire);
}

/// A relay thread's hand-off, without the thread.
pub const search_inbox_cap_for_test = search_inbox_cap;

pub fn searchArrivedForTest(gen: u32, relay: u8, pubkey: [32]u8) void {
    searchArrived(gen, relay, pubkey);
}

/// What a relay thread does with one event.
pub fn searchAcceptForTest(gen: u32, relay: u8, signer: nostr.keys.Signer, ev: nostr.event.Event) bool {
    var seen: search.Seen = .{};
    return searchAcceptSeenForTest(gen, relay, signer, ev, &seen);
}

/// The same, with the relay's list of who it has named carried between events.
pub fn searchAcceptSeenForTest(gen: u32, relay: u8, signer: nostr.keys.Signer, ev: nostr.event.Event, seen: *SearchSeenForTest) bool {
    const job = SearchJob{ .gen = gen, .relay = relay, .url = "", .term = undefined, .term_len = 0 };
    return searchAccept(std.heap.page_allocator, signer, job, ev, seen);
}
pub const SearchSeenForTest = search.Seen;
pub const searchRelayLimitForTest = search.relay_limit;

pub fn searchInboxLenForTest() usize {
    lockSearchInbox();
    defer unlockSearchInbox();
    return g_search_inbox_len;
}

pub fn searchSetStatusForTest(relay: usize, state: search.RelayState, count: u16) void {
    g_search_status[relay].store((search.Status{ .gen = g_search_gen.load(.acquire), .state = state, .count = count }).pack(), .release);
}

pub fn searchRelayCountForTest() usize {
    return searchRelays().len;
}

pub fn searchRelayUrlForTest(i: usize) []const u8 {
    return searchRelays()[i];
}

pub fn nip05AskedForTest() bool {
    return g_nip05_ask != null;
}

pub fn handleNip05FoundForTest(model: *Model, response: native_sdk.EffectResponse) void {
    handleNip05Found(model, response);
}

/// The key the lookup now awaited went out under.
pub fn nip05AskKeyForTest() u64 {
    return g_nip05_ask_key;
}
pub const search_scan_page_for_test = search_scan_page;

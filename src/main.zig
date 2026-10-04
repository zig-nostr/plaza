//! Plaza, the flagship native Nostr client.
//!
//! A first run opens a welcome screen with three ways in: create a fresh
//! identity, paste an existing `nsec` to import a key, or paste a `bunker://`
//! link to connect an external signer (Notary) over NIP-46 so the secret key
//! never enters Plaza. The choice is persisted as a session, so a returning user
//! is signed straight back in (a local key from disk, or a silent bunker
//! reconnect). A Settings screen shows who you are signed in as, lets a local
//! user back up their secret key, and logs out without locking anyone in: your
//! key is always yours to copy and take elsewhere.
//!
//! Signed in, you land in a follow-based feed seeded by a curated starter pack
//! (the `starter_pack` authors). Composing signs a kind:1 (locally, or by a
//! `sign_event` round-trip to the bunker), which is stored locally and published
//! to the pool. The feed runs as a pool (each relay on its own thread ingesting
//! into the one shared store, deduped by event id), scoped to the follow set,
//! rendered from disk on a timer, all in one process. Reads and writes route
//! by the reader's own NIP-65 relay list.
//!
//! Onboarding lives in `onboarding.native`; the feed and Settings are Zig views
//! (inline images need a runtime image reference, and a relay row needs its own
//! index in three messages, neither of which the markup grammar carries). This
//! file is the logic.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
pub const search = @import("search.zig");
const plaza_icons = @import("plaza_icons.zig");
const article = @import("article.zig");
const blossom = @import("blossom.zig");
const tuning = @import("tuning.zig");
const hiding = @import("hiding.zig");
const prefs = @import("prefs.zig");
const updates = @import("updates.zig");
const links = @import("links.zig");
const login = @import("login.zig");
const places = @import("places.zig");
const relay_table = @import("relay_table.zig");
const relay_list = @import("relay_list.zig");
const routing = @import("routing.zig");
const relay_conn = @import("relay_conn.zig");
const store_glue = @import("store_glue.zig");
const feed_state = @import("feed_state.zig");
const thread_model = @import("thread_model.zig");
const note_build = @import("note_build.zig");
const profile_cache = @import("profile_cache.zig");
const person_card = @import("person_card.zig");
const quote_cache = @import("quote_cache.zig");
const addresses = @import("addresses.zig");
const link_preview = @import("link_preview.zig");
const relay_hints = @import("relay_hints.zig");
const engagement = @import("engagement.zig");
const inbox = @import("inbox.zig");
const image_cache = @import("image_cache.zig");
const image_pool = @import("image_pool.zig");
const feed_media = @import("feed_media.zig");
const own_lists = @import("own_lists.zig");
const follows = @import("follows.zig");
const mutes = @import("mutes.zig");
const bookmarks = @import("bookmarks.zig");
const private_lists = @import("private_lists.zig");
const keyholder = @import("keyholder.zig");
const remote_signer = @import("remote_signer.zig");
const drafts = @import("drafts.zig");
const session = @import("session.zig");
const own_profile = @import("own_profile.zig");
const uploads = @import("uploads.zig");
const media_servers = @import("media_servers.zig");
const view_upload = @import("view_upload.zig");
const compose = @import("compose.zig");
const outbox = @import("outbox.zig");
const people_search = @import("people_search.zig");
const profile_notes = @import("profile_notes.zig");
const navigation = @import("navigation.zig");
const relay_auth = @import("relay_auth.zig");
const ingest = @import("ingest.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

// The toolkit compiles its macOS host (appkit_host.m) into every binary built
// from this module: the app, the test binary and the model-contract tool. The
// host calls two functions the toolkit exports from Zig, but only its macOS
// platform module references them, and only the app's run path reaches that
// module. A Debug link drops the unused host object, so nothing noticed; an
// optimized one keeps it and fails with the two symbols undefined. Referencing
// them here exports them wherever this module is built.
comptime {
    if (builtin.os.tag == .macos) {
        _ = native_sdk.updater.c_api.native_sdk_update_verify_feed;
        _ = native_sdk.updater.c_api.native_sdk_update_verify_archive;
    }
}

// ------------------------------------------------- bytes that are not ours
//
// `@setRuntimeSafety(true)` appears at the top of every function below that
// walks bytes somebody else chose. It is one rule, stated here once:
//
// Plaza ships ReleaseFast, and ReleaseFast compiles out the bounds check, the
// overflow check and the cast check. That is the right trade for the render
// thread, which walks this app's own data at 120 Hz, and the wrong one for a
// parser, where an index comes off a length a stranger wrote. The `nostr`
// library is already built one notch safer for exactly that reason (see
// `libraryOptimize` in build.zig). The same argument covers the parsing this
// file does for itself, which that setting does not reach.
//
// The question is not "does this touch a string". It is: does an INDEX, a
// LENGTH or a CAST in here come from the input? A note's content, an `imeta`
// tag, a blurhash, a kind:0 body, a fetched page's `<head>`, an image's
// declared dimensions. Anything read start to end is left alone.
//
// It goes at the TOP of the function rather than around the interesting line,
// so a check added inside it later is covered without anybody remembering to.
//
// It does not reach the vendored stb decoders. They are C, they are the largest
// stranger-facing surface in the app, and no Zig setting changes what they do.
// What stands in front of them is the size check in `decodeAndRegister`.

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
// A desktop window sized for the redesign's centered reading column: the feed
// content is a fixed 620px column, so the window opens wide enough to seat it
// with real margin on either side, and extra width past that becomes margin,
// never a longer line. Wider than tall: a reading column wants breathing room,
// not a tower.
//
// From app.zon, like the floor, so the manifest is the one place the number
// lives. These were typed here as well, and two numbers that must agree with
// nothing connecting them is exactly how the floor came to sit seven pixels
// below what the layout needed.
pub const window_width: f32 = @import("window_floor").manifest_width;
// Square. A feed is a column of rows, and the wide-and-short default spent its
// extra width on margin while showing four notes at a time.
pub const window_height: f32 = @import("window_floor").manifest_height;
pub const feed_column_width: f32 = 620;
// The thread's reading column matches the feed's: both are virtualLists now,
// which reserve the same scrollbar gutter, so the two screens share one column
// width and one left edge.
const thread_column_width: f32 = feed_column_width;

// -- Where the people you follow actually write ------------------------------
//
// The suggestions used to be first come, first kept: the first six write relays
// seen in anyone's kind:10002 filled the table and everything after was
// dropped. Which six that is depends on whose relay list happened to arrive
// first, so a relay one person uses could sit above one two hundred people use,
// and the reader was being asked to add relays in arrival order.
//
// What the answer should be is the inversion every outbox implementation
// starts with: turn "person -> relays they write to" into "relay -> people who
// write there", and rank by how many. Jumble does exactly this, and takes each
// author's top few write relays rather than all of them, on the reasoning
// written into their source: most people do not understand relays and a list
// of nine cannot be trusted to mean anything.
//
// Computed from the STORE rather than accumulated on ingest. The store already
// holds one kind:10002 per author, which is the whole input, and counting on
// arrival would need per-relay author sets to avoid counting one person twice
// when their list is re-sent. Reading it back is both simpler and correct by
// construction.

pub fn routeCoverageForTest() RouteCoverage {
    return routing.g_route_coverage;
}
pub const routeCoverageTargetForTest = route_coverage_target;

// -- Relays that will not have us ---------------------------------------------
//
// Coverage says which relays carry the people you follow. It does not say which
// of them will talk to you, and those are not the same set. A paid relay refuses
// the WEBSOCKET HANDSHAKE, before a single Nostr message is exchanged, so there
// is no protocol answer to give it: no NIP-42 challenge arrives, and nothing to
// authenticate with would help, because what it wants is a subscription.
//
// Found on my own account: `wss://nostr.wine` is the single best relay by
// coverage, 50 of 257 follows write there, and it had a routed slot to itself
// dialling and failing on a widening ladder forever. The coverage counter could
// not see it. It reported those 50 people as reached.
//
// So a routed relay that will not have us gives up its slot and the greedy
// spends it on the next relay down, which is a real one. This applies ONLY to
// relays Plaza chose. A relay the reader added themselves keeps its seat and
// keeps retrying however badly it behaves, because dropping somebody's own relay
// quietly is the opposite of what they asked for.

pub fn relayIsRefusedForTest(strikes: u6, at_ms: i64, now_ms: ?i64) bool {
    return relayIsRefused(strikes, at_ms, now_ms);
}
pub const routedRefusalStrikesForTest = routed_refusal_strikes;
pub const routedRefusalMsForTest = routed_refusal_ms;

pub fn refusedRelayCountForTest() usize {
    var urls: [routed_refusal_slots][96]u8 = undefined;
    var lens: [routed_refusal_slots]u8 = @splat(0);
    return refusedRelays(&urls, &lens);
}
pub fn noteRelayRefusalAtForTest(url: []const u8, now: i64) bool {
    return noteRelayRefusalAt(url, now);
}
pub fn clearRelayRefusalForTest(url: []const u8) void {
    clearRelayRefusal(url);
}
pub fn forgetRefusedRelaysForTest() void {
    lockRefused();
    defer unlockRefused();
    for (&routing.g_refused) |*e| {
        e.url_len = 0;
        e.strikes = 0;
        e.at_ms = -1;
    }
}

pub fn worthEvictingForTest(challenger_gain: usize, incumbent_gain: usize) bool {
    return worthEvicting(challenger_gain, incumbent_gain);
}

pub fn sameRouteForTest(url_a: []const u8, authors_a: []const [32]u8, url_b: []const u8, authors_b: []const [32]u8) bool {
    return sameRoute(url_a, authors_a, url_b, authors_b);
}

pub fn routeRecomputeDueForTest(pending_ms: ?i64, since_list_ms: ?i64, since_run_ms: ?i64) bool {
    return routeRecomputeDue(pending_ms, since_list_ms, since_run_ms);
}
pub const routeSettleMsForTest = route_settle_ms;
pub const routeRecomputeMinMsForTest = route_recompute_min_ms;
pub const routeSettleMaxMsForTest = route_settle_max_ms;

pub fn rankRelaySuggestionsForTest(store: *nostr.store.Store) void {
    rankRelaySuggestions(store);
}
pub fn foldWriteRelaysForTest(table: []RelayRank, len_in: usize, urls: []const []const u8) usize {
    return foldWriteRelays(table, len_in, urls);
}
pub const RelayRankForTest = RelayRank;
pub fn relayRankWritersForTest(e: RelayRank) u16 {
    return e.writers;
}
pub fn relayRankUrlForTest(e: *const RelayRank) []const u8 {
    return e.urlSlice();
}
pub const outboxRelaysPerAuthorForTest = outbox_relays_per_author;
pub const maxDiscoveredRelaysForTest = max_discovered_relays;
pub const discoveredAuthorsCapForTest = discovered_authors_cap;
pub const discoveredWatchBaseForTest = discovered_watch_base;
pub const relayWatchSlotsForTest = relay_watch_slots;
pub fn discoveredGenerationForTest(index: usize) u32 {
    if (index >= routing.g_discovered_gen.len) return 0;
    return routing.g_discovered_gen[index].load(.acquire);
}

pub fn relayListDueForTest(now_s: i64) bool {
    return relayListDue(now_s);
}

pub fn relayListEditedForTest(now_s: i64) void {
    relay_list.g_relays_are_mine = true;
    relay_list.g_relay_list_dirty = true;
    relay_list.g_relay_list_touched = now_s;
}

pub fn clearRelayListPublishForTest() void {
    clearRelayListPublish();
}

/// Drives the settle-and-publish the frame tick drives, so a test can assert
/// that a refused publish leaves the edit pending rather than losing it.
pub fn flushRelayListForTest(fx: *Effects, now_s: i64) void {
    flushRelayList(fx, now_s);
}

pub fn relayListPendingForTest() bool {
    return relay_list.g_relay_list_dirty;
}

pub fn noteRelayRemovedForTest(url: []const u8) void {
    noteRelayRemoved(url);
}

pub fn forgetRelayRemovalsForTest() void {
    forgetRelayRemovals();
}

/// Whether publishing the pool would go out right now. The safety property is
/// that it does NOT, until this account's own relay list has been read.
pub fn publishRelayListForTest(fx: *Effects) bool {
    return publishRelayListReporting(fx);
}

// ------------------------------------------------------- your own lists
//
// kind:0, kind:3 and kind:10002 are REPLACEABLE. The store enforces that the way
// relays do: `ingestReplaceable` DELETES the superseded event and its indexes in
// the same transaction. That is right for other people's records, and it means
// that the moment a newer version of one of OUR OWN lists arrives, the version
// it replaces is gone from this machine with no way back.
//
// Usually that is fine, because the newer one is ours too. It is not fine when
// the newer one is wrong: a list published by a client with a bad clock, a list
// this app itself published from a pool it should not have, a relay replaying
// something ancient. Losing a contact list is not a display bug.
//
// So every ingest goes through one door, and that door keeps a copy of what is
// about to be overwritten.

/// Points the app's store at a test's own, so the funnel can be driven for real.
pub fn setStoreForTest(store: ?*nostr.store.Store) void {
    g_store = store;
    if (store) |st| seedFeedNewest(st);
}

pub fn plazaIngestForTest(gpa: std.mem.Allocator, ev: nostr.event.Event) !nostr.store.IngestResult {
    return plazaIngest(gpa, ev, .{});
}

/// The relay-fed funnel: verified, and remembering which relay delivered it.
pub fn plazaIngestFromForTest(gpa: std.mem.Allocator, ev: nostr.event.Event, signer: nostr.keys.Signer, relay_url: []const u8) !nostr.store.IngestResult {
    return plazaIngestFrom(gpa, ev, .{ .verify_with = signer }, relay_url);
}

/// Drives the funnel with verification ON, the way every relay-fed path does.
pub fn plazaIngestVerifiedForTest(gpa: std.mem.Allocator, ev: nostr.event.Event, signer: nostr.keys.Signer) !nostr.store.IngestResult {
    return plazaIngest(gpa, ev, .{ .verify_with = signer });
}

pub fn canWriteRelayListForTest() bool {
    return canWriteRelayList();
}

pub fn forgetOwnRecordAnswersForTest() void {
    forgetOwnRecordAnswers();
}

pub fn ownRecordReadsForTest() usize {
    return store_glue.g_own_record_reads;
}

pub fn resetOwnRecordReadsForTest() void {
    store_glue.g_own_record_reads = 0;
}

/// How many relays the app is born with. Tests derive from this rather than
/// naming a number, so changing the bootstrap list is one edit and not a hunt
/// through the suite for every place that happened to say five.
pub const bootstrap_relay_count_for_test = bootstrap_relays.len;

/// The most relays a reader may have, which is what the ack mask can address.
pub const max_relays_for_test = max_relays;

/// Puts the pool back to the one the app was born with. For tests, which need a
/// known pool: the real one is loaded from disk or from their kind:10002.
pub fn resetRelaysForTest() void {
    relay_table.g_relays = [_]RelayEntry{.{}} ** max_relays;
    relay_table.g_relay_count.store(0, .release);
    relay_list.g_relays_are_mine = false;
    setRelayListStamp(0);
    relay_list.g_relay_list_dirty = false;
    forgetRelayRemovals();
    relay_list.g_staged_ready.store(false, .release);
    relay_table.g_suggested_count.store(0, .release);
    forgetDiscovered();
    forgetRefusedRelaysForTest();
    seedBootstrapRelays();
}

/// The file this pool would be saved as, and reading one back. The stamp line
/// is what carries "how new is what we hold" across a restart.
pub fn formatRelaysFileForTest(buf: []u8) ?[]const u8 {
    return formatRelaysFile(buf);
}

pub fn applyRelaysFileForTest(raw: []const u8) void {
    applyRelaysFile(raw);
}

/// An EMPTY pool, the way a launch starts before the file is read. Distinct from
/// `resetRelaysForTest`, which seeds the bootstrap list: a test that means to
/// reproduce a restart must not have four relays already sitting in the seats
/// the file is about to fill.
pub fn clearRelaysForTest() void {
    relay_table.g_relays = [_]RelayEntry{.{}} ** max_relays;
    relay_table.g_relay_count.store(0, .release);
    relay_list.g_relays_are_mine = false;
    relay_list.g_relay_owner = null;
    setRelayListStamp(0);
    relay_list.g_relay_list_dirty = false;
    forgetRelayRemovals();
    relay_list.g_staged_ready.store(false, .release);
    relay_table.g_suggested_count.store(0, .release);
    forgetDiscovered();
    forgetRefusedRelaysForTest();
}

pub fn relayListStampForTest() i64 {
    return heldRelayListStamp();
}

pub fn setRelayListStampForTest(created_at: i64) void {
    setRelayListStamp(created_at);
}

/// Applies a staged kind:10002 the way the frame loop does.
pub fn adoptRelayListForTest() bool {
    return adoptRelayList();
}

pub fn stageOwnRelayListForTest(ev: nostr.event.Event) void {
    applyOwnRelayList(ev);
}

pub fn ingestRelayListForTest(ev: nostr.event.Event) void {
    ingestRelayList(ev);
}

pub fn cycleRelayForTest(i: usize) void {
    cycleRelay(i);
}

pub fn removeRelayForTest(i: usize) void {
    removeRelay(i);
}

pub fn addRelayForTest(url: []const u8, read: bool, write: bool) ?usize {
    return addRelay(url, read, write);
}

pub fn forgetOutboxAcksForTest() void {
    forgetOutboxAcks();
}

/// One failed publish round, the way `markOutboxSending(false)` records it.
pub fn markOutboxRoundForTest(id: [32]u8) void {
    markOutboxSending(id, true);
    markOutboxSending(id, false);
}

pub fn resetRelaysToBootstrapForTest() void {
    resetRelaysToBootstrap();
}

pub fn relayBadgeTextForTest(i: usize) []const u8 {
    const e = relayAt(i) orelse return "(removed)";
    return relayBadgeText(e);
}

pub fn liveRelayCountForTest() usize {
    return liveRelayCount();
}

pub fn setRelayStatusForTest(i: usize, connected: bool) void {
    setRelayStatus(i, if (connected) .connected else .offline);
}

pub fn relayStatusConnectedForTest(i: usize) bool {
    return connHolds(@enumFromInt(relay_conn.g_relay_status[i].load(.monotonic)));
}

pub fn setRelayQuietForTest(i: usize) void {
    setRelayStatus(i, .quiet);
}
pub fn outboxWokeForTest() bool {
    return relay_conn.g_outbox_woke_ever.load(.monotonic);
}
pub fn resetOutboxWokeForTest() void {
    relay_conn.g_outbox_woke_ever.store(false, .monotonic);
    relay_conn.g_outbox_woke_at.store(0, .monotonic);
}
pub fn relayStatusQuietForTest(i: usize) bool {
    return @as(Conn, @enumFromInt(relay_conn.g_relay_status[i].load(.monotonic))) == .quiet;
}
/// Seats a deadline in the one-shot table without a socket, so what the keeper
/// decides about it can be driven directly.
pub fn seatOneShotForTest(slot: usize, deadline_ms: i64) void {
    relay_conn.g_oneshot_deadline[slot] = deadline_ms;
}
pub fn clearOneShotsForTest() void {
    for (0..one_shot_slots) |i| {
        relay_conn.g_oneshot[i] = null;
        relay_conn.g_oneshot_deadline[i] = 0;
    }
}
pub fn expiredOneShotsForTest(now_ms: i64, out: []usize) usize {
    var buf: [one_shot_slots]usize = undefined;
    const n = expiredOneShots(now_ms, &buf);
    const take = @min(n, out.len);
    @memcpy(out[0..take], buf[0..take]);
    return take;
}
pub fn markOneShotCutForTest(slot: usize) void {
    relay_conn.g_oneshot_deadline[slot] = one_shot_already_cut;
}
pub const oneShotSlotsForTest = one_shot_slots;
pub const oneShotBudgetMsForTest = one_shot_budget_ms;
pub const bunkerWatchSlotForTest = bunker_watch_slot;
pub const maxRelaysForTest = max_relays;

pub fn isReaderNoteForTest(kind: u16) bool {
    return isReaderNote(kind);
}

pub fn poolIsHealthyOfForTest(live: usize, total: usize) bool {
    return poolIsHealthyOf(live, total);
}

pub fn markRelaysMineForTest() void {
    relay_list.g_relays_are_mine = true;
    relay_list.g_relay_owner = activePubkey();
}

pub fn relayListIsOwnedForTest() bool {
    return relayListIsOwned();
}

pub fn relayOwnerForTest() ?[32]u8 {
    return relay_list.g_relay_owner;
}

pub fn relayIsMineForTest() bool {
    return relay_list.g_relays_are_mine;
}

pub fn relayReadWriteForTest(i: usize) ?RelayUse {
    const e = relayAt(i) orelse return null;
    return .{ .read = e.read, .write = e.write };
}

// ------------------------------------------------------------------- places
//
// A place is somebody else's Plaza, published as an event.
//
// fiatjaf's Hallway configures a client at DEPLOY time: fill in a form, get a
// static site on your own domain. That works, and it costs a deploy per variant,
// so you only get variants worth a deploy. His own suggestion for a native app
// was the other shape: one binary, several rooms, each instantiated from a URL
// or an event shared by whoever runs the community. Then a place costs nothing to
// make, and you get the ones nobody would have deployed a site for: one
// conference weekend, a reading group of nine people.
//
// This is the first slice of that. A place carries an app name, a home text, and
// the relays its feeds read from. v1 reads the first two and one feed; the rest
// of Hallway's surface (colours, kinds, publish targets, densities) arrives in
// later versions against the same document.
//
// EVERYTHING HERE COMES FROM A STRANGER. A place is an event by definition
// somebody else signed, so every field is bounded, copied into fixed storage,
// and never trusted for its length. The relay URL is the sharp one: it decides
// where the app connects.

/// So a test builds an address for the kind Plaza actually looks for, rather
/// than repeating the number and agreeing with it by coincidence.
pub const place_kind_for_test = place_kind;

// -------------------------------------------------- things you can take away
//
// A client you can make quiet.
//
// Every element here is one the reader can remove, and the point of the whole
// thing is the second column: a hidden thing should not be FETCHED. Hide
// reaction counts and the subscription stops asking relays for kind:7, so the
// preference is less bandwidth, less parsing and a smaller store rather than a
// number painted over. It is also what makes the claim honest. "The data is
// absent" and "the data is covered up" are different promises, and only one of
// them can be made about a thing that is still being downloaded.
//
// A registry rather than a handful of booleans on the Model, because the ids are
// written to a file and will eventually be a NIP-78 `kind:30078` record, and
// because the same table drives the settings list. That list is not decoration:
// hide something, forget, and there is nothing left to right click. One screen
// naming everything that can be hidden is how this avoids the way hide-based
// customisation usually fails.
//
// Subtractive on purpose. Taking things away cannot make the app ugly or slow;
// rearranging can, and it would mean making the feed's layout data-driven, which
// is an architectural change rather than a preference.

pub fn engagementKindsForTest() []const u16 {
    return engagementKinds();
}
pub const plaza_version_for_test = plaza_version;
pub const settings_column_width_for_test = settings_column_width;
pub const settings_content_width_for_test = settings_content_width;
/// The same number, for a test that has to know where a row's disc lands.
pub const thread_inset_for_test: f32 = thread_inset;
pub const picture_column_width_for_test: f32 = picture_column_width;
pub const compose_editor_width_for_test = compose_editor_width;
pub const reply_editor_height_for_test = reply_editor_height;
pub const link_card_height_for_test: f32 = link_card_height;
pub const link_card_height_bare_for_test: f32 = link_card_height_bare;

/// Files a preview as if a page had answered, for a test that renders the card.
pub fn seedLinkForTest(url: []const u8, title: []const u8, desc: []const u8) void {
    const slot = wantLink(url) orelse return;
    storeLinkMeta(slot, .{ .title = title, .description = desc });
    slot.state = .loaded;
}
/// SUPERSEDED, kept for the argument it lost.
///
/// The banner had a reserved id, on the reasoning that one non-scrolling
/// consumer does not exercise an allocator. That was true, and it stopped being
/// the point: pictures did cross the pools, so the allocator exists now, and a
/// reserved id would be the one slot it could not reach.
///
/// The old note:
///
/// The profile banner's own id, taken out of the avatar pool rather than
/// borrowed from either LRU.
///
/// The block above argues for ONE allocator over all sixteen slots, and that is
/// still the right end state. It is not this change. A banner is one image on a
/// screen that occludes the feed: it never scrolls, never competes with a second
/// banner, and is overwritten in place when the reader walks to another person.
/// A reserved id therefore needs no eviction pass at all, and cannot take a
/// picture the feed is using in ANY navigation order, which is exactly what
/// borrowing from the media LRU could do. Unifying here would still be writing
/// the allocator against imagined callers; a single non-scrolling consumer does
/// not exercise one.
///
/// The cost is one avatar id, and it is not observable: ids are lent only to the
/// visible window, and a window this size holds a handful of rows, so the tenth id
/// only ever lengthened the LRU tail. A reclaimed avatar returns from the disk
/// cache, not the network.
/// Which registry id the banner is holding, or 0 for none. A variable now,
/// because the banner takes its slot from the same pool as everything else.
pub var g_banner_image_id: u64 = 0;
/// The tick the banner was last on screen.
pub var g_banner_seen: u64 = 0;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view, native_sdk.security.permission_clipboard, native_sdk.security.permission_network };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Plaza canvas", .accessibility_label = "Plaza", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
/// The narrowest the window may be made, read from the manifest that enforces
/// it so there is exactly one copy of the number.
///
/// It is a create-time property, which is why it can only be declared in
/// app.zon; it is repeated on the scene because leaving it at the default here
/// would declare "no floor" for any path that re-applies the window's
/// properties. `zig build test` sweeps every screen from this width.
pub const window_min_width: f32 = @import("window_floor").manifest_min_width;

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Plaza",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------- one-process runtime wiring
//
// A native app is a single process and a single instance, so the shared store,
// each relay's connection state, and the wall clock live as process globals,
// the Model stays pure view state (the framework reflects Model/Msg for markup
// checking). Sharing the store across the UI thread and the several ingest
// threads is safe: LMDB serialises its writers (the pool's ingests take the
// write lock one at a time) and hands readers an MVCC snapshot, and every
// `nostr.store` call is a self-contained transaction on its calling thread.

pub var g_store: ?*nostr.store.Store = null;

/// A fresh arrival table, for a test that drives the real stamping.
pub fn arrivalTableForTest() ArrivalTable {
    return .{};
}

pub fn stampArrivalForTest(table: *ArrivalTable, notes: []Note, settled: bool) void {
    stampArrival(table, notes, settled);
}

/// Records one round trip for relay `index`. Stored as milliseconds PLUS ONE, so
/// a sub-millisecond answer (a warm or local relay, truncated to 0) is a reading
/// rather than an empty slot.
pub fn recordRelayRttForTest(index: usize, ms: u64) void {
    recordRelayRtt(index, ms);
}

pub fn clearRelayRttForTest(index: usize) void {
    clearRelayRtt(index);
}

/// The pool's latency: the median across every relay that has answered. The
/// redesign asks for the median WRITE relay, the number that predicts how fast a
/// post lands; until a relay list with read/write markers exists, every relay in// The UI thread's Io, for wall-clock time when rendering relative timestamps
// (set once in `main`, read only on the UI thread).
pub var g_io: ?std.Io = null;
// The process environment, stashed in `main` so the onboarding "create identity"
// action can resolve `$HOME` and open the store off the UI thread event loop.
pub var g_environ: ?*const std.process.Environ.Map = null;
// The event count at the last feed rebuild, a cheap "did the store change?"
// signal so a tick that changed nothing skips the query and note rebuild.
var g_last_count: usize = std.math.maxInt(usize);
/// The same, for whichever level is open. Separate from `g_last_count` because
/// the feed consumes that one, and a level opened after a feed rebuild would
/// otherwise see an unchanged count and never fill.
var g_last_level_count: usize = std.math.maxInt(usize);

// -- What just arrived -------------------------------------------------------
//
// The feed used to answer "has anything changed" by asking the store for the
// whole thing again, once a second, on the render thread: a cursor per followed
// author and a linear pick across all of them per note returned. Measured in the
// library's benchmark at 2049 authors, ReleaseFast, best of fifty: 1.46 ms for a
// screenful and 10.8 ms once the reader has paged twenty pages down, against a
// 16.7 ms frame. The cost is set by how many people the reader follows, not by
// how much actually changed, and almost nothing changes between two ticks.
//
// So the ingest threads say what landed instead. No reference client re-reads
// its store on arrival: Notedeck polls note keys ingested since the last poll
// and merges them, Jumble splices the arriving event into a sorted array, and
// Amethyst hands its filter only the new items. This is that, with the ids
// carried across the thread boundary and the events read back by id, which is a
// direct read each rather than a walk of the follow list.

/// Delivers one /pubkey answer the way the runtime would.
pub fn deliverHelperPubkeyForTest(model: *Model, body: []const u8) void {
    handleHelperPubkey(model, .{ .key = helper_poll_key, .outcome = .ok, .status = 200, .body = body });
}

pub fn helperSetupPendingForTest() bool {
    return keyholder.g_helper_setup != .none;
}

pub fn helperStateForTest() HelperState {
    return helperState();
}

pub fn helperTokenForTest() []const u8 {
    return helperToken();
}

/// Puts the daemon into the "answering and holding a key" state, so a test can
/// ask what the OTHER conditions do.
pub fn setHelperReadyForTest() void {
    keyholder.g_helper_state.store(2, .release);
}

pub fn helperReachableForTest() bool {
    return helperReachable();
}

pub fn helperPortForTest() u16 {
    return keyholder.g_helper_port;
}

pub fn setHelperPortForTest(port: u16) void {
    keyholder.g_helper_port = port;
}

pub fn helperSecretForTest() []const u8 {
    return keyholder.g_helper_secret_buf[0..keyholder.g_helper_secret_len];
}

pub fn mintHelperSecretForTest(io: std.Io) void {
    var raw: [24]u8 = undefined;
    io.randomSecure(&raw) catch return;
    const written = std.fmt.bufPrint(&keyholder.g_helper_secret_buf, "{x}\n", .{raw}) catch return;
    keyholder.g_helper_secret_len = written.len;
}

/// `false` restores the unprobed state rather than claiming a keyholder was
/// found, because in a test nothing has looked for one.
pub fn setKeyholderMissingForTest(missing: bool) void {
    keyholder.g_keyholder = if (missing) .missing else .unprobed;
}

pub fn resolveSiblingForTest(io: std.Io, out: []u8, dir: []const u8, name: []const u8) usize {
    return resolveSibling(io, out, dir, name);
}

pub fn exeDirForTest(io: std.Io, buf: []u8) ?[]const u8 {
    return exeDir(io, buf);
}

/// Adopts the Notary signer kind for the active test identity, so the status
/// line can be asked what it says about a daemon that is not there.
/// Says that this test drives the keyholder's answers itself.
///
/// A test that reaches for this one is asking about what happens WHILE a
/// signature is out, or when the answer is a 401, or when none comes at all.
/// The stand-in keyholder that answers every other test instantly would give
/// it a success before it could look, so switching kind here silences it.
pub fn setSignerKindHelperForTest() void {
    keyholder.g_signer_kind = .helper;
    keyholder.g_test_signer_silent = true;
}

/// Hands the keyholder back to the stand-in, for a test that took it.
pub fn setSignerKindLocalForTest() void {
    keyholder.g_signer_kind = .helper;
    keyholder.g_test_signer_silent = false;
}

/// Which kind of signer this app is using, by name.
pub fn signerKindNameForTest() []const u8 {
    return @tagName(keyholder.g_signer_kind);
}

/// Whether a secret key is sitting in THIS process.
///
/// A constant false, and that is the assertion rather than a stub: there is no
/// longer a variable in this program that can hold one. The test that reads
/// this is what keeps that true, by failing the day somebody adds one back.
pub fn holdsKeyInProcessForTest() bool {
    return false;
}

pub fn signerStatusLabelForTest() []const u8 {
    return signerStatus().label;
}

pub fn ceremonyCanTakeKeyForTest() bool {
    return ceremonyCanTakeKey();
}

/// Pretends the key is held by Notary, by a remote signer, or by Plaza itself.
/// Pretends this session connected to `pubkey`'s bunker.
pub fn setRemotePubkeyForTest(pubkey: [32]u8) void {
    remote_signer.g_remote_pubkey = pubkey;
}

/// Hands one NIP-46 response event to the listener's handler, as a relay would.
/// The generation is the live one, so only the checks under test can reject it.
pub fn deliverNip46ResponseForTest(
    signer: nostr.keys.Signer,
    client_kp: nostr.keys.KeyPair,
    ev: nostr.event.Event,
) void {
    handleNip46Response(
        std.heap.page_allocator,
        signer,
        client_kp,
        ev,
        remote_signer.g_remote_generation.load(.acquire),
    );
}

pub fn setSignerKindForTest(kind: []const u8) void {
    keyholder.g_signer_kind = if (std.mem.eql(u8, kind, "remote")) .remote else .helper;
}

/// Pretends the ceremony window was (or was not) found beside Plaza.
pub fn setNotaryWindowFoundForTest(found: bool) void {
    keyholder.g_notary_win_len = if (found) "/nonexistent/notary".len else 0;
    if (found) @memcpy(keyholder.g_notary_win_buf[0.."/nonexistent/notary".len], "/nonexistent/notary");
}

/// Whether a helper setup is sitting queued, waiting for the daemon to answer.
pub fn helperSetupQueuedForTest() bool {
    return keyholder.g_helper_setup != .none;
}

pub fn helperSetupMayFireForTest(queued: bool, state: HelperState) bool {
    return helperSetupMayFire(queued, state);
}

pub fn helperSignTimeoutSecondsForTest() i64 {
    return helper_sign_timeout_s;
}

pub fn helperSignTimeoutMillisForTest() u32 {
    return helper_sign_timeout_ms;
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

/// The tags a body of text implies, for tests. Deliberately takes the finished
/// string: that is exactly what the publish path passes, which is why a pasted
/// note and a typed one cannot diverge.
pub fn resetWantedProfilesForTest() void {
    profile_cache.g_wanted = [_]WantedProfile{.{}} ** wanted_profiles_cap;
}

pub fn wantProfileForTest(pubkey: [32]u8) void {
    wantProfile(pubkey);
}

pub fn wantProfilesAheadForTest(model: *const Model) void {
    wantProfilesAhead(model);
}

pub fn isProfileWantedForTest(pubkey: [32]u8) bool {
    for (&profile_cache.g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return true;
    }
    return false;
}

pub fn wantedProfileCountForTest() usize {
    var n: usize = 0;
    for (&profile_cache.g_wanted) |*w| {
        if (w.used) n += 1;
    }
    return n;
}

pub fn dupeTagsForTest(gpa: std.mem.Allocator, tags: []const nostr.event.Tag) ?[]const nostr.event.Tag {
    return dupeTags(gpa, tags);
}

pub fn contentTagsForTest(gpa: std.mem.Allocator, content: []const u8) []const nostr.event.Tag {
    return contentTags(gpa, content, &.{}, &.{});
}

/// The tag set of the last event handed to a signer, for tests.
pub fn lastPublishedTagsForTest() []const nostr.event.Tag {
    return keyholder.g_last_published_tags;
}

pub fn lastPublishedForTest() ?nostr.event.Event {
    return keyholder.g_last_published;
}

pub fn forgetLastPublishedForTest() void {
    keyholder.g_last_published = null;
}

pub fn clearLastPublishedTagsForTest() void {
    keyholder.g_last_published_tags = &.{};
}

pub fn helperSignRestorableForTest() bool {
    return keyholder.g_helper_sign.active and keyholder.g_helper_sign.restorable;
}

pub fn requestHelperSignForTest(fx: *Effects, created: i64, kind: u16, content: []const u8, restorable: bool) void {
    requestHelperSign(fx, std.heap.page_allocator, created, kind, &.{}, content, restorable, .none);
}

pub fn handleHelperSignedForTest(response: native_sdk.EffectResponse) void {
    handleHelperSigned(response);
}

pub fn releaseHelperSignForTest() void {
    releaseHelperSign();
}

/// Puts the pending sign past its deadline, for the case where no terminal ever
/// arrives: a daemon that accepts the socket and then says nothing.
pub fn expireHelperSignForTest() void {
    keyholder.g_helper_sign.deadline_s = 0;
}

pub fn scanHelperSignForTest(model: *Model) void {
    scanHelperSign(model);
}

pub fn helperSignNoticeForTest() bool {
    return keyholder.g_helper_sign_notice.load(.acquire);
}

pub fn signerReadyForTest() bool {
    return signerReady();
}

pub fn silenceTestSignerForTest(silent: bool) void {
    keyholder.g_test_signer_silent = silent;
}

pub fn holdHelperSignForTest() void {
    keyholder.g_signer_kind = .helper;
    keyholder.g_helper_sign.active = true;
}

pub fn helperSignPendingForTest() bool {
    return keyholder.g_helper_sign.active;
}

/// Ingests and publishes a signed event returned by the daemon. Trusted: it
/// came from our own daemon over authenticated loopback. A kind:0 seeds the
/// profile cache so the name shows at once.
/// The keyholder a test has: signs what was asked for and answers exactly as
/// the daemon would, so `handleHelperSigned` runs for real.
///
/// Only compiled into a test binary. It exists so that the four hundred tests
/// that "are somebody" drive the path that ships rather than one that does not,
/// which is worth more than the shortcut it replaces.
pub fn answerHelperSignForTest(gpa: std.mem.Allocator, unsigned_json: []const u8) void {
    const secret = feed_state.g_test_secret orelse return;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    var parsed = nostr.event.fromJson(gpa, unsigned_json) catch return;
    defer parsed.deinit();
    const ev = parsed.value;
    const signed = nostr.event.create(gpa, signer, kp, ev.created_at, ev.kind, ev.tags, ev.content, null) catch return;
    const signed_json = nostr.event.toJson(gpa, signed) catch return;
    defer gpa.free(signed_json);
    const body = (nostr.signer_ipc.SignEvent{ .event = signed_json }).toJson(gpa) catch return;
    defer gpa.free(body);
    handleHelperSigned(.{ .key = helper_sign_key, .outcome = .ok, .status = 200, .body = body });
}

/// Delivers one signed-event answer the way the runtime would, so a test can
/// hand the app an event it did NOT ask for.
pub fn deliverHelperSignedForTest(body: []const u8) void {
    handleHelperSigned(.{ .key = helper_sign_key, .outcome = .ok, .status = 200, .body = body });
}

// Test seams for the NIP-46 pending-request table (the correlation and teardown
// logic), exercised without threads or a live bunker.
pub const RemoteMethodForTest = RemoteMethod;
pub fn registerPendingForTest(req_id: []const u8, method: RemoteMethod, content: ?[]const u8) bool {
    return registerPending(req_id, method, content, content != null, .none, 0, no_half_id, .{});
}
pub fn takePendingContentForTest(req_id: []const u8) ?struct { method: RemoteMethod, content: ?[]const u8 } {
    const taken = takePending(req_id) orelse return null;
    return .{ .method = taken.method, .content = taken.content };
}
pub fn failPendingForTest(req_id: []const u8) bool {
    return failPending(req_id);
}
pub fn clearPendingForTest() void {
    clearPending();
}
/// Marks the pending sign whose draft is `content` failed, as a refusal or a
/// timeout would, so a test can pick WHICH of several signs comes back.
pub fn failPendingByContentForTest(content: []const u8) bool {
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_pending) |*slot| {
        if (!slot.active or slot.method != .sign_event) continue;
        const c = slot.content orelse continue;
        if (!std.mem.eql(u8, c, content)) continue;
        slot.failed = true;
        return true;
    }
    return false;
}
pub fn bumpRemoteGenerationForTest() void {
    _ = newRemoteGeneration();
}
pub fn scanPendingRemoteForTest(model: *Model, fx: *Effects) void {
    scanPendingRemote(model, fx);
}
pub fn remoteSignNoticeForTest() bool {
    return remote_signer.g_remote_sign_notice.load(.acquire);
}

/// Why a pasted address did not open anything.
///
/// `unreadable` covers both an unknown prefix and a string that starts right
/// and does not decode: to a reader those are one thing, a bad address, and
/// splitting them would only say which half of the check refused.
///
/// `wrong_kind` is separate because it is not the reader's mistake. A valid
/// `naddr1` can name a kind Plaza has no screen for, and saying "that is not an
/// address" about a perfectly good address is the kind of wrong answer that
/// sends somebody looking for a typo that is not there.
pub const AddressError = enum { none, unreadable, wrong_kind, not_found, lookup_failed };

// --------------------------------------------------------------- media proxy
//
// The image registry decodes at most a 512x512 image and the fetch effect caps
// bodies at 256 KiB, so a full-size photo can neither be downloaded nor decoded
// as-is. Images are therefore requested at the size they will actually be drawn:
// through a host's own resizer when it has one, otherwise through a
// weserv-compatible proxy (the free public wsrv.nl by default, and any instance
// the user prefers, including their own). Clearing the setting loads originals
// straight from their host, which still works for anything small enough.

// -- Asking on a socket that is already open ---------------------------------
//
// A one-shot fetch used to dial its own connection to every relay, serially,
// and read until EOSE. Eight relays meant eight TLS handshakes for one question
// about one profile, a thread parked for the duration, and a connect bounded
// only by the operating system.
//
// The pool already holds those sockets. No client dials for a one-shot:
// NDK, Jumble and welshman all bottom out in a pool lookup, every one of them.
//
// What makes a shared socket safe here is that there is no reply to deliver.
// Every event a relay sends is ingested into the store by the thread that owns
// that socket, whoever asked for it, and the render thread reads the store.
// That is welshman's ingest policy, and it means a subscription id only has to
// name a question, never a caller waiting on an answer.
//
// So this WRITES the REQ from the asking thread. Writes on a connection are
// serialized inside the library (nostr v0.8.0), which is what makes it sound
// while the owning thread is blocked reading the same socket.

pub fn isFeedSubForTest(sub_id: []const u8) bool {
    return isFeedSub(sub_id);
}

pub fn askPoolForTest(sub_id: []const u8, filters: []const nostr.filter.Filter) usize {
    return askPool(sub_id, filters);
}
pub fn askableSlotsForTest(out: []usize) usize {
    return askableSlots(out);
}
pub fn isOneShotSubForTest(sub_id: []const u8) bool {
    return isOneShotSub(sub_id);
}
pub const oneShotSubPrefixForTest = one_shot_sub_prefix;

// ------------------------------------------------------------------ profiles
//
// Kind:0 metadata gives each author a display name and an avatar. The pool
// ingests kind:0 for the feed's authors alongside their notes (the store keeps
// only the newest per author, kind:0 being replaceable); the UI thread parses
// them into this cache during the feed rebuild, keyed by pubkey. The feed reads
// names and avatar image ids from the cache at render time, so a name or a
// just-loaded avatar shows on the next frame without a re-query. Avatars are
// fetched (bounded, cap-aware) and registered as canvas images; the cache is
// UI-thread-only, so no synchronisation is needed.

pub fn buildRoutedFiltersForTest(authors: []const [32]u8, out: []nostr.filter.Filter) []nostr.filter.Filter {
    return buildRoutedFilters(authors, out);
}

/// Stamps the newest note the feed has seen, so a test can put `feedSince` in
/// the state that matters. Without this it returns null for want of any note at
/// all, and a test asserting "no since" passes whether or not the code asks for
/// one.
pub fn setFeedNewestForTest(created_at: i64) void {
    feed_state.g_feed_newest.store(created_at, .monotonic);
}
pub fn feedSinceForTest() ?i64 {
    return feedSince();
}

// ---------------------------------------------------------------- addresses
//
// An `naddr` names a replaceable event by its author, its kind and its `d` tag,
// not by an id, and the event it names changes id every time its author edits
// it. So nothing here is looked up by id: the question is always "the newest
// copy of this coordinate", asked of the store first and of the relays after.
//
// Jumble resolves it the same way: the cache by coordinate first
// (src/services/client.service.ts:891-936), then a filter of author + kind + `d`
// (982-993) sent to the address's own relay hints or, when it has none, to the
// author's first five write relays (1004-1009), keeping the newest answer
// (1027). Plaza asks the hints and the author's write relays both, rather than
// one or the other. Jumble also accepts a newer copy arriving afterwards and
// swaps it in (src/hooks/useFetchEvent.tsx:39-54), which `g_address_want` does.

pub fn newestAddressIdForTest(store: *nostr.store.Store, kind: u16, pubkey: [32]u8, identifier: []const u8) ?[32]u8 {
    const addr = Address.make(kind, pubkey, identifier) orelse return null;
    return newestAddressId(store, &addr);
}

/// Empties the table. For tests, which share the process globals.
pub fn resetAddressesForTest() void {
    addresses.g_addresses = [_]AddressSlot{.{}} ** address_table_cap;
    addresses.g_address_clock = 0;
}

/// The stand-in key an address is filed under, as a card or a pill carries it.
pub fn addressKeyForTest(kind: u16, pubkey: [32]u8, identifier: []const u8) [32]u8 {
    const a = Address.make(kind, pubkey, identifier) orelse return @splat(0);
    return a.key();
}

pub fn addressRegisteredForTest(key: [32]u8) bool {
    return addressFor(key) != null;
}

pub const addressPoolBatchForTest = address_pool_batch;

/// The filters a pool message for these addresses carries, for a test to read.
pub fn addressPoolFiltersForTest(addrs: []const Address, out: *[address_pool_batch + 1]nostr.filter.Filter) usize {
    const held = struct {
        var queries: [address_pool_batch]AddressQuery = undefined;
        var authors: [address_pool_batch][32]u8 = undefined;
    };
    return addressPoolFilters(addrs, &held.queries, &held.authors, out);
}

pub fn addressForTest(kind: u16, pubkey: [32]u8, identifier: []const u8) ?Address {
    return Address.make(kind, pubkey, identifier);
}

pub fn storedWriteRelaysForTest(pubkey: [32]u8, out: *[outbox_relays_per_author][96]u8, lens: *[outbox_relays_per_author]u8) usize {
    return storedWriteRelays(std.heap.page_allocator, pubkey, out, lens);
}

pub fn openAddressedArticleForTest(model: *Model, kind: u16, pubkey: [32]u8, identifier: []const u8) void {
    const a = Address.make(kind, pubkey, identifier) orelse return;
    openAddressedArticle(model, a, &.{});
}

pub fn refreshAddressFetchForTest(model: *Model) void {
    refreshAddressFetch(model);
}

pub fn addressFetchArmedForTest() bool {
    return addresses.g_address_want != null;
}

pub fn forgetAddressFetchForTest() void {
    addresses.g_address_want = null;
}

/// Puts a loaded link preview in the cache, so a view test can render a card
/// without a network round trip. The long-description case is the one that
/// matters: it is what used to run off the side of the window.
/// A feed note carrying `url` as its link, for view tests.
pub fn noteWithLinkForTest(url: []const u8) Note {
    var n = Note{};
    n.id = 1;
    const u = @min(url.len, n.link_url_buf.len);
    @memcpy(n.link_url_buf[0..u], url[0..u]);
    n.link_url_len = @intCast(u);
    return n;
}

pub fn setLinkPreviewForTest(url: []const u8, domain: []const u8, title: []const u8, description: []const u8) void {
    for (&link_preview.g_links) |*l| {
        if (l.used) continue;
        l.* = .{ .used = true, .state = .loaded };
        const u = @min(url.len, l.url_buf.len);
        @memcpy(l.url_buf[0..u], url[0..u]);
        l.url_len = @intCast(u);
        const d = @min(domain.len, l.domain_buf.len);
        @memcpy(l.domain_buf[0..d], domain[0..d]);
        l.domain_len = @intCast(d);
        const t = @min(title.len, l.title_buf.len);
        @memcpy(l.title_buf[0..t], title[0..t]);
        l.title_len = @intCast(t);
        const c = @min(description.len, l.desc_buf.len);
        @memcpy(l.desc_buf[0..c], description[0..c]);
        l.desc_len = @intCast(c);
        return;
    }
}

pub fn clearLinkPreviewsForTest() void {
    for (&link_preview.g_links) |*l| l.* = .{};
}

/// Clears the quote cache. For tests, which share the process globals.
pub fn resetQuotesForTest() void {
    quote_cache.g_quotes = [_]QuoteEntry{.{}} ** quote_cache_cap;
    quote_cache.g_quote_clock = 0;
}

pub const addressDialsPerRoundForTest = address_dials_per_round;

/// Whether an address's relays have been dialled (or claimed for dialling).
pub fn addressDialledForTest(key: [32]u8) bool {
    const slot = addressFor(key) orelse return false;
    return slot.outbox_asked;
}

/// Builds a Note over `content` and runs the quote-reference scan, so a test can
/// assert what `findQuoteRef` captured (id/off/len) without a live event.
pub fn findQuoteRefForTest(content: []const u8) Note {
    var note = Note{};
    const n = @min(content.len, note.content_buf.len);
    @memcpy(note.content_buf[0..n], content[0..n]);
    note.content_len = @intCast(n);
    findQuoteRef(&note);
    return note;
}

/// Clears the profile cache. For tests, which share the process globals.
pub fn resetProfilesForTest() void {
    profile_cache.g_profiles = [_]Profile{.{}} ** profile_cap;
    @memset(&profile_cache.g_profile_index, 0);
    profile_cache.g_names_generation = 0;
    g_notes_names_generation = 0;
    profile_cache.g_image_clock = 0;
}

/// Marks `pubkey`'s profile as having (or not having) a kind:0 picture, so a
/// test can exercise the avatar-id LRU without a real fetch.
pub fn setProfilePictureForTest(pubkey: [32]u8, present: bool) void {
    const p = upsertProfile(pubkey) orelse return;
    p.picture_len = if (present) 8 else 0;
    if (present) @memcpy(p.picture_buf[0..8], "http://x");
}

/// The registry image id currently lent to `pubkey`'s avatar (0 = none). For
/// tests of the id LRU.
/// Puts a profile in the state the avatar pipeline would leave it in, so a view
/// test can ask what the widget does with it without a network round trip.
pub fn setProfileAvatarForTest(pubkey: [32]u8, image_id: u64, state: enum { idle, fetching, loaded, failed }) void {
    const p = upsertProfile(pubkey) orelse return;
    p.image_id = image_id;
    p.avatar_state = switch (state) {
        .idle => .idle,
        .fetching => .fetching,
        .loaded => .loaded,
        .failed => .failed,
    };
}

/// Whether this face is idle, and whether it is now pinned to its own host
/// rather than the proxy. Both are what the host-refusal fallback moves.
pub fn avatarFallbackStateForTest(pubkey: [32]u8) ?struct { idle: bool, direct: bool } {
    const p = lookupProfile(pubkey) orelse return null;
    return .{ .idle = p.avatar_state == .idle, .direct = p.avatar_direct };
}

pub fn avatarImageIdForTest(pubkey: [32]u8) u64 {
    const p = lookupProfile(pubkey) orelse return 0;
    return p.image_id;
}

/// Runs one avatar-id assignment pass, for tests.
pub fn assignAvatarSlotsForTest(fx: *Effects, model: *const Model) void {
    wantProfilesAhead(model);
    beginImagePass();
    assignAvatarSlots(fx, model);
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
    engagement.g_my_likes = [_]MyLike{.{}} ** my_likes_cap;
}

/// Whether this session has liked the note (for tests and the view).
pub fn isLikedForTest(note_id: i64) bool {
    return isLiked(note_id);
}

// ------------------------------------------------------------ engagement counts
//
// Reply / repost / like / zap tallies per feed note, aggregated client-side (no
// NIP-45 COUNT, whose relay support is spotty). Each ingest thread opens a second
// subscription, `{kinds:[1,6,7,9735], "#e":[the notes it loaded]}`, and folds the
// arriving events into this in-memory table, deduped across relays by event id.
// The view reads it at render time. Counts are per session: a relaunch refetches
// them, so nothing here is persisted.

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

pub fn bakeBodyForTest(item: *InboxItem, ev: nostr.event.Event) void {
    bakeBody(item, ev);
}

pub fn notificationRowForTest(ui: *AppUi, item: *const InboxItem) AppUi.Node {
    return notificationRow(ui, item);
}

pub fn collapseEventRefsForTest(dst: []u8, src: []const u8) usize {
    return collapseEventRefs(dst, src);
}

pub fn resolveInboxBodiesForTest() void {
    resolveInboxBodies();
}

/// Forgets what the last pass saw, so a test with a store of its own is not
/// skipped because an earlier test left the same event count behind.
pub fn forgetInboxBodyStampForTest() void {
    inbox.g_inbox_body_stamp = std.math.maxInt(usize);
    inbox.g_inbox_body_names = std.math.maxInt(u64);
}

/// Gives `pubkey` a display name the way a landed kind:0 does, including the
/// names generation moving, which is what tells the surfaces that baked an
/// older label to bake it again.
pub fn setProfileNameForTest(pubkey: [32]u8, name: []const u8) void {
    const p = upsertProfile(pubkey) orelse return;
    var buf: [160]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"name\":\"{s}\"}}", .{name}) catch return;
    parseMetadataInto(p, json);
    profile_cache.g_names_generation +%= 1;
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

/// A NIP-22 comment, for the inbox tests: same shape as the kind:1 builder
/// there, with the kind that makes the other vocabulary apply.
pub fn commentEventForTest(author: u8, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{author} ** 32,
        .pubkey = [_]u8{author} ** 32,
        .created_at = 100,
        .kind = comment_kind,
        .tags = tags,
        .content = "a comment",
        .sig = [_]u8{0} ** 64,
    };
}

/// Files `count` unread notifications, so a view test can ask what the rail's
/// badge does with a number without standing up relays.
pub fn seedInboxUnreadForTest(count: usize) void {
    const me = activePubkey() orelse return;
    lockInbox();
    defer unlockInbox();
    resetInboxLocked(me);
    var i: usize = 0;
    while (i < count and inbox.g_inbox_len < inbox.g_inbox.len) : (i += 1) {
        var id: [32]u8 = [_]u8{0} ** 32;
        id[0] = @intCast(i % 251 + 1);
        inbox.g_inbox[inbox.g_inbox_len] = .{
            .used = true,
            .id = id,
            .author = id,
            .target_id = [_]u8{0} ** 32,
            .created_at = 1_800_000_000,
            .verb = .reply,
            .msat = 0,
        };
        inbox.g_inbox_len += 1;
    }
}

/// Whether a kind:0 has been asked for on this pubkey's behalf.
pub fn profileWantedForTest(pubkey: [32]u8) bool {
    for (&profile_cache.g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return true;
    }
    return false;
}

pub fn forgetWantedProfilesForTest() void {
    for (&profile_cache.g_wanted) |*w| w.* = .{};
}

pub fn resetInboxForTest() void {
    lockInbox();
    defer unlockInbox();
    inbox.g_inbox_len = 0;
    inbox.g_inbox_owner = null;
    inbox.g_inbox_read_through = 0;
}

pub fn inboxLenForTest() usize {
    lockInbox();
    defer unlockInbox();
    return inbox.g_inbox_len;
}

// -------------------------------------------------------- where a note can be found
//
// A relay hint is a claim, written into something other people will read, about
// where a thing can be asked for. Plaza has taken hints since an `nevent1` that
// names relays started getting those relays asked, and wrote none of its own:
// the address it copied, the `e` tag under a reply and the `q` tag under a quote
// all left the slot empty, so every other client was handed the problem Plaza
// itself had been given a way to solve.
//
// Two things are known about where a note lives, and they prove different
// amounts. A relay that DELIVERED the note holds it, because it just sent it. A
// relay the AUTHOR lists as a write relay (their kind:10002) is where they say
// they publish, which is likely and not verified. The order follows that:
//
//   1. a relay that delivered it and is also one of the author's write relays
//   2. a relay that delivered it
//   3. one of the author's write relays
//
// That is Amethyst's `Note.relayHintUrl`: the delivering relay that is in the
// author's outbox set, then the first delivering relay, then the author's own
// first outbox relay. Jumble's `getEventHint` is the second rule alone. The
// third rule is only reached when nothing is known to have delivered the note,
// which is a note read straight off disk after a restart.
//
// When none of the three applies the hint is EMPTY, and that is a considered
// answer rather than a gap: a wrong hint costs every reader a socket to a relay
// that does not have the note, and an empty one costs them nothing they were not
// already paying.
//
// A relay is only offered when a stranger could dial it. `ws://` is cleartext,
// and a private or loopback address in a published tag is useless to everyone
// else and says something about the publisher's network that nobody asked them
// to say. Jumble drops its own local-network relays from every hint for the
// same reason (`getEventHints`, `isLocalNetworkUrl`).

pub fn noteAddressForTest(out: *[note_address_cap]u8, note: *const Note, relays_wanted: usize) ?[]const u8 {
    return noteAddress(out, note, relays_wanted);
}
pub fn profileAddressForTest(out: *[note_address_cap]u8, pubkey: [32]u8) ?[]const u8 {
    return profileAddress(out, pubkey);
}
pub const note_address_cap_for_test = note_address_cap;
pub fn recordSeenOnForTest(id: [32]u8, url: []const u8) void {
    recordSeenOnId(id, url);
}
pub fn resetSeenOnForTest() void {
    seenOnLock();
    defer seenOnUnlock();
    for (&relay_hints.g_seen_on) |*e| e.* = .{};
    relay_hints.g_seen_url_n = 0;
}
pub fn hintsForTest(id: [32]u8, author: ?[32]u8) HintList {
    var out: HintList = .{};
    hintsFor(id, author, &out);
    return out;
}
pub fn isHintableRelayForTest(url: []const u8) bool {
    return isHintableRelay(url);
}
pub fn seenUrlCountForTest() usize {
    return relay_hints.g_seen_url_n;
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
    engagement.g_engagement = [_]Engagement{.{}} ** engagement_cap;
    engagement.g_seen = [_]u64{0} ** seen_engagement_cap;
    engagement.g_seen_len = 0;
}

/// Folds an event into the counts, for tests (the ingest path without threads).
pub fn countEngagementForTest(ev: nostr.event.Event, feed_ids: []const i64) void {
    countEngagement(ev, feed_ids);
}

/// Wall-clock seconds on the UI thread, or 0 before `main` wires the clock.
pub fn nowSeconds() i64 {
    const io = g_io orelse return 0;
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// The pubkey Plaza posts as: the local key, or the remote signer's, or null
/// before an identity is established. The feed includes it so your own notes
/// show alongside the follows you read.
pub fn activePubkey() ?[32]u8 {
    return switch (keyholder.g_signer_kind) {
        .remote => if (remote_signer.g_remote_confirming.load(.acquire)) null else remote_signer.g_remote_pubkey,
        .helper => if (keyholder.g_helper_has_identity) keyholder.g_helper_identity_pk else null,
    };
}

// ------------------------------------------------------------------ model

/// A `nostr:nevent`/`note` quote a note carries: the decoded event id (the
/// fetch, open, and cache key) and the byte span of its raw token within the
/// note's `content_buf`, so the body can be split around it at render time
/// without ever mutating the stored text.
/// Stood in for a picture past the end, so `imageAt` can answer without the
/// caller checking first: a zero-length URL is what every path already reads as
/// "no image".
const empty_note_image = NoteImage{};

/// What a picture's chip says: its dimensions and its weight, as the note claims
/// them, in the shot's own form (`1600x900 · 240 KB`). Either half may be
/// missing, and it is empty when both are. Never taken from the decoded bytes,
/// which are the proxy's box and would be a lie about the file, and never from
/// the response, which carries no headers.
fn imageChipLabelFor(img: *const NoteImage, arena: std.mem.Allocator) []const u8 {
    const has_dims = img.w > 0 and img.h > 0;
    if (has_dims and img.bytes > 0) {
        return std.fmt.allocPrint(arena, "{d}\u{00d7}{d} · {s}", .{ img.w, img.h, byteSize(arena, img.bytes) }) catch "";
    }
    if (has_dims) return std.fmt.allocPrint(arena, "{d}\u{00d7}{d}", .{ img.w, img.h }) catch "";
    if (img.bytes > 0) return byteSize(arena, img.bytes);
    return "";
}

/// How many pictures one note draws.
///
/// Four, which is what the clients that draw galleries settle on, and what a
/// phone's share sheet produces. Past it the extra URLs stay in the body as
/// links, which is the old behaviour for everything after the first and is the
/// right fallback for a note carrying a dozen.
pub const max_note_images = 4;

/// One picture in a note: where it is, and what the note's own `imeta` claims
/// about it before a single byte has been fetched.
pub const NoteImage = struct {
    /// 192 and not the 300 a single image used to get, because there are four of
    /// these in every Note now and the feed copies whole Notes on every rebuild
    /// and every splice. At 300 the rebuild went from 272us to 400us and the
    /// layout from 1303 to 1907, with the node count and the planning stage
    /// unmoved: that is bytes being copied, not work being done.
    ///
    /// It fits what image hosts actually emit. A Blossom URL is its 64-character
    /// hash plus a host and an extension, about 90; nostr.build and primal sit
    /// in the same range. A longer one is left in the body as a link, which is
    /// the same fallback a note past the picture cap gets.
    url_buf: [192]u8 = [_]u8{0} ** 192,
    url_len: u16 = 0,
    /// Height divided by width, from the note's NIP-92 `imeta dim`. Knowing the
    /// shape BEFORE the picture downloads is what lets the card reserve exactly
    /// the right space, so nothing shifts when it arrives (or is evicted and
    /// comes back).
    aspect: f32 = 0,
    /// The author's claim about the file: pixel dimensions and byte size, from
    /// the same `imeta` tag, drawn as chips at rest.
    w: u16 = 0,
    h: u16 = 0,
    bytes: u32 = 0,
    /// Its colour before its bytes. Fixed buffer, because the tag's memory is
    /// the event's.
    blur_buf: [40]u8 = [_]u8{0} ** 40,
    blur_len: u8 = 0,
    /// Whether the note described it. The chip is one word; the description
    /// itself would need a hover expand, which is not expressible.
    has_alt: bool = false,

    pub fn url(self: *const NoteImage) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn blurhash(self: *const NoteImage) []const u8 {
        return self.blur_buf[0..self.blur_len];
    }

    pub fn set(self: *NoteImage, link: []const u8, meta: Imeta) void {
        const n = @min(link.len, self.url_buf.len);
        @memcpy(self.url_buf[0..n], link[0..n]);
        self.url_len = @intCast(n);
        self.aspect = meta.aspect();
        self.w = meta.width;
        self.h = meta.height;
        self.bytes = meta.size;
        const b = @min(meta.blurhash.len, self.blur_buf.len);
        @memcpy(self.blur_buf[0..b], meta.blurhash[0..b]);
        self.blur_len = @intCast(b);
        self.has_alt = meta.alt.len > 0;
    }
};

const QuoteRef = struct {
    kind: enum(u8) { none, event } = .none,
    id: [32]u8 = [_]u8{0} ** 32,
    off: u16 = 0,
    len: u16 = 0,
};

/// How many mentions in one note can be pressed. Past this they still render as
/// `@name`, they just do not open anything, which is the mild end of a note
/// tagging a crowd.
const note_max_mentions = 8;

/// The cap, for a test that has to build a note carrying more than it.
pub const noteMaxMentionsForTest = note_max_mentions;

/// Where a topic span's payload lives.
///
/// A mention's sits in `MentionRef.link_buf`, part of the model-owned `Note`,
/// precisely because `ui.arena` is reset every frame and a press is dispatched
/// after the frame that built it. A topic has no `Note` field to live in, so it
/// gets a table of its own, and a slot in it is only ever written over once no
/// tree a press can still reach refers to it.
///
/// That rule is the whole point. This used to be a ring of sixteen that every
/// hashtag drawn took the next slot of, so a screen with more than sixteen tags
/// on it wrote the later ones over the earlier ones' payloads, and pressing an
/// early tag opened somebody else's.
const topic_slots = 64;
const TopicSlot = struct {
    buf: [topic_link_tag.len + max_topic_bytes]u8 = undefined,
    len: u8 = 0,
    /// The last view build that handed this payload to a span.
    build: u64 = 0,
};
var g_topic_slots: [topic_slots]TopicSlot = [_]TopicSlot{.{}} ** topic_slots;

/// Counts view builds. A press is answered against the tree of the build before
/// the one under way at worst, so a payload drawn in either is still in use.
var g_view_build: u64 = 0;

/// Stores `word` (a hashtag without its `#`) and returns the payload to hang on
/// the span, lowercased so `#Nostr` and `#nostr` are one topic. `contentTags`
/// lowercases on the way out too, so the two halves agree.
///
/// Null when every slot is still in use: the run is then drawn as one that goes
/// nowhere, which is a tag that cannot be pressed this frame rather than a press
/// that opens a different tag.
fn topicLinkFor(word: []const u8) ?[]const u8 {
    if (word.len == 0 or word.len > max_topic_bytes) return null;
    var payload: [topic_link_tag.len + max_topic_bytes]u8 = undefined;
    @memcpy(payload[0..topic_link_tag.len], topic_link_tag);
    for (word, 0..) |c, i| payload[topic_link_tag.len + i] = std.ascii.toLower(c);
    const want = payload[0 .. topic_link_tag.len + word.len];
    // The same tag already held: its bytes are exactly what this span needs.
    for (&g_topic_slots) |*slot| {
        if (slot.len == want.len and std.mem.eql(u8, slot.buf[0..slot.len], want)) {
            slot.build = g_view_build;
            return slot.buf[0..slot.len];
        }
    }
    for (&g_topic_slots) |*slot| {
        if (slot.len != 0 and slot.build + 1 >= g_view_build) continue;
        @memcpy(slot.buf[0..want.len], want);
        slot.len = @intCast(want.len);
        slot.build = g_view_build;
        return slot.buf[0..slot.len];
    }
    return null;
}

/// Starts a view build the way `appView` does, for a test that draws spans
/// without building a whole tree.
pub fn beginViewBuildForTest() void {
    g_view_build +%= 1;
}

/// The topic inside a payload, or null when this link is not one.
fn topicLinkValue(link: []const u8) ?[]const u8 {
    if (link.len <= topic_link_tag.len) return null;
    if (!std.mem.startsWith(u8, link, topic_link_tag)) return null;
    return link[topic_link_tag.len..];
}

pub fn topicLinkValueForTest(link: []const u8) ?[]const u8 {
    return topicLinkValue(link);
}

/// The link payload a mention span carries: `mention_link_tag` followed by the
/// raw 32-byte pubkey.
///
/// Not a URL, and not meant to be read as one. A paragraph has exactly one link
/// handler, so a mention and an ordinary `https://` link arrive at the same
/// place and have to be told apart once they are there. The tag's second byte is
/// zero, which no URL contains, so nothing a stranger can write in a note will
/// be mistaken for a mention.
///
/// Carrying the pubkey rather than spelling it back out as `nostr:npub1…` is
/// what keeps this cheap: the text form is 69 bytes per mention in every note
/// the feed holds, and would then have to be decoded again on the press.
const mention_link_tag = "p\x00";
/// A topic's payload rides the same channel a mention's does: a sentinel whose
/// second byte is zero, which no URL contains, so `open_url` can tell the three
/// apart without a new message or a new field on a span.
const topic_link_tag = "t\x00";
const mention_link_len = mention_link_tag.len + 32;

/// One rendered NIP-27 mention: where its `@name` landed, and who it names.
pub const MentionRef = struct {
    /// Byte range of the label inside the note's `content_buf`.
    off: u16 = 0,
    len: u16 = 0,
    link_buf: [mention_link_len]u8 = [_]u8{0} ** mention_link_len,

    /// The payload for this mention's span. Borrowed from the note, which
    /// outlives the frame that built the span, for the same reason the link
    /// card's URL is: the press message holds the slice, and the opener reads it
    /// after the arena that drew the frame is gone.
    pub fn link(self: *const MentionRef) []const u8 {
        return &self.link_buf;
    }
};

/// The mentions of one note, filled in as its content is rendered.
pub const MentionList = struct {
    refs: [note_max_mentions]MentionRef = [_]MentionRef{.{}} ** note_max_mentions,
    len: u8 = 0,

    pub fn all(self: *const MentionList) []const MentionRef {
        return self.refs[0..self.len];
    }

    pub fn record(self: *MentionList, off: usize, len: usize, pubkey: [32]u8) void {
        if (self.len == self.refs.len) return;
        const ref = &self.refs[self.len];
        ref.off = std.math.cast(u16, off) orelse return;
        ref.len = std.math.cast(u16, len) orelse return;
        @memcpy(ref.link_buf[0..mention_link_tag.len], mention_link_tag);
        @memcpy(ref.link_buf[mention_link_tag.len..], &pubkey);
        self.len += 1;
    }

    /// Moves every offset back by the leading whitespace a trim removed, and
    /// drops anything the trim cut into.
    ///
    /// The trim runs after the whole note is rendered, and it can shift the
    /// buffer left, so offsets recorded during the walk describe the buffer as
    /// it was rather than as it ends up. A note that is nothing but a mention
    /// and some spaces is the ordinary case here, not a contrived one: lifting
    /// an image URL out of the text is exactly what strands that whitespace.
    pub fn rebase(self: *MentionList, lead: usize, len: usize) void {
        var kept: u8 = 0;
        for (self.refs[0..self.len]) |ref| {
            if (ref.off < lead) continue;
            const off = ref.off - lead;
            if (off + ref.len > len) continue;
            self.refs[kept] = ref;
            self.refs[kept].off = @intCast(off);
            kept += 1;
        }
        self.len = kept;
    }
};

/// The pubkey behind a mention's link payload, or null if this is an ordinary
/// link that should go to the browser instead.
pub fn mentionLinkPubkey(link: []const u8) ?[32]u8 {
    if (link.len != mention_link_len) return null;
    if (!std.mem.startsWith(u8, link, mention_link_tag)) return null;
    var pubkey: [32]u8 = undefined;
    @memcpy(&pubkey, link[mention_link_tag.len..]);
    return pubkey;
}

/// The verb a guest reached for, held until they have a key.
pub const Intent = union(enum) {
    none,
    post,
    like: i64,
    repost: i64,
    reply: i64,
    follow: [32]u8,

    pub fn waiting(self: Intent) bool {
        return self != .none;
    }
};

/// One note as the feed renders it: a two-letter avatar, the author's
/// abbreviated npub, a relative timestamp, and the (truncated) content. Strings
/// are copied into fixed buffers so a card never aliases the query arena it was
/// built from.
pub const Note = struct {
    // Non-negative i64: the markup engine holds a `for each` integer key as i64
    // then casts it to u64, so a raw u64 (or negative i64) from the id's high
    // bytes would overflow and panic. Mask off the sign bit.
    id: i64 = 0,
    // The full 32-byte event id, for the reaction's `e` tag and the engagement
    // subscription's `#e` filter. The i64 above is only a render/dedup key.
    event_id: [32]u8 = [_]u8{0} ** 32,
    /// The kind this note was built from.
    ///
    /// Nothing used to branch on kind when it drew, and `noteFrom` built a note
    /// out of any event without ever reading this. The feed and the thread got
    /// away with it because they filter to kind 1 before they get there. The
    /// quote cache and `openEvent` do not, so a long-form article arrived as a
    /// slab of raw markdown painted into a note body, and an event whose content
    /// is empty by design arrived as a card that said nothing at all.
    ///
    /// Two bytes on a fixed struct, which is what lets every surface ask the
    /// same question and get the same answer.
    ///
    /// Who passed this note on, when the card got here as a repost.
    ///
    /// The card itself is the REPOSTED note: its id, its author, its words, its
    /// counts. That is what makes the rest fall out for free. Dedup already
    /// keys on `event_id`, so two follows reposting one note collapse to one
    /// row and a repost of something already in the window does not draw it
    /// twice; and engagement is already counted against the note's own id, so
    /// the numbers under the row belong to what was reposted rather than to the
    /// wrapper. Amethyst gates the wrapper's whole reaction bar off to reach
    /// the same place (`NoteCompose.kt:774`, `isNotRepost`).
    reposter: [32]u8 = [_]u8{0} ** 32,
    has_reposter: bool = false,
    /// Defaults to 1, not 0. `noteFrom` always writes the event's real kind
    /// over this, INCLUDING a real 0, so a kind:0 event still draws as the kind
    /// nothing can render. The default only ever applies to a `Note` built
    /// without an event behind it: a scratch struct, or a fixture. Those have
    /// always been text notes, and 0 would quietly reclassify every one of them
    /// as an event this app refuses to draw.
    kind: u16 = 1,
    created_at: i64 = 0,
    // The author's full pubkey, so the view can resolve a display name and an
    // avatar from the profile cache at render time (picking up a name or a
    // just-loaded avatar without rebuilding the note).
    pubkey: [32]u8 = [_]u8{0} ** 32,
    initials_buf: [2]u8 = [_]u8{0} ** 2,
    author_buf: [24]u8 = [_]u8{0} ** 24,
    author_len: u8 = 0,
    time_buf: [12]u8 = [_]u8{0} ** 12,
    time_len: u8 = 0,
    content_buf: [note_content_cap]u8 = [_]u8{0} ** note_content_cap,
    content_len: u16 = 0,
    /// Every picture the note carries, up to `max_note_images`, lifted out of
    /// the text and drawn as pictures instead (see `renderContent`'s `omit`).
    ///
    /// A note with several images is ordinary, not exotic: a phone's share sheet
    /// posts three at once and every other client draws them as a gallery. This
    /// held exactly one, so the first was drawn and the rest were left in the
    /// body as raw URLs, which is the worst of both.
    images: [max_note_images]NoteImage = [_]NoteImage{.{}} ** max_note_images,
    images_len: u8 = 0,
    /// The first plain link in the note, previewed as a card under the body. One
    /// per note, which is what 11o draws; the URL stays in the text as well.
    link_url_buf: [300]u8 = [_]u8{0} ** 300,
    link_url_len: u16 = 0,
    /// Whether that link is a video file rather than a page.
    ///
    /// ONE BYTE, not a second URL buffer. The URL is already captured here and
    /// already drawn as a card; what was missing is knowing what it points at.
    /// A `Note` is a fixed struct in the feed array, so a second 300-byte buffer
    /// would be paid on every note in the window to say one thing about a few.
    link_is_video: bool = false,
    /// Whether the note described its picture. The chip is the marker the shot
    /// draws, one word: the description itself would need a hover expand, which
    /// is not expressible.
    image_has_alt: bool = false,
    // The first `nostr:nevent`/`note` reference in the content, decoded once at
    // parse time: the quoted event id, and the byte span of its raw token in
    // `content_buf` so the body can split around it and render an embedded quote
    // card. `.none` when the note quotes nothing.
    quote: QuoteRef = .{},
    // Where each `@name` in the rendered content sits, and whom it names, so a
    // press on one can open that profile. The pubkey is gone from the text by
    // the time it is drawn: rewriting `nostr:npub1…` into a readable name is
    // what makes the note legible, and it is also what threw away the only
    // thing a press could have acted on.
    mentions: MentionList = .{},
    // The NIP-10 parent this note answers (the `e` tag marked `reply`, or the
    // thread root for a direct reply), extracted once at parse time so a thread
    // can seat each reply under the note it answers. Zero when it answers
    // nothing; the flag disambiguates a genuine all-zero id.
    reply_parent: [32]u8 = [_]u8{0} ** 32,
    has_reply_parent: bool = false,
    /// This note names a parent that is not in the fetched set. It sits at the
    /// top level for want of anywhere better, and says so rather than passing
    /// itself off as an answer to the thread's opening note.
    parent_missing: bool = false,
    /// What the note says it was written with, from NIP-89's `client` tag.
    /// Copied in rather than read at render time because it is foreign text on a
    /// borrowed event: the buffer is the sanitiser's output, bounded here so a
    /// name can never be longer than the row that draws it.
    client_buf: [client_name_bytes]u8 = [_]u8{0} ** client_name_bytes,
    client_len: u8 = 0,
    /// The author asked for this note to be covered, with NIP-36's
    /// `content-warning` tag. A fact about the note, decided once here from its
    /// tags: whether it is covered RIGHT NOW is a question about the reader (the
    /// switch in Settings, and whether they have pressed this one), and is
    /// answered by `noteCovered`.
    warned: bool = false,
    /// The reason the author gave, clipped. Empty for a bare tag, which still
    /// covers the note: the warning is the tag, not the sentence.
    warning_buf: [warning_reason_bytes]u8 = [_]u8{0} ** warning_reason_bytes,
    warning_len: u8 = 0,
    // Thread placement, stamped by `arrangeThread`: how deep this reply sits
    // under the root (1 = a direct reply). Meaningless outside an arranged
    // thread.
    depth: u8 = 0,
    // Which build of the open thread this reply first appeared in, so a late
    // arrival sorts after what is already on screen instead of jumping into the
    // middle of it. Only meaningful for a thread's replies.
    arrival: u32 = 0,

    pub fn initials(self: *const Note) []const u8 {
        return &self.initials_buf;
    }
    /// The first picture's blurhash, empty when the note carries none.
    pub fn imageBlurhash(self: *const Note) []const u8 {
        return self.imageAt(0).blurhash();
    }
    /// Picture `i`, or an empty one past the end so callers can read it without
    /// checking first. An empty picture has a zero-length URL, which every
    /// caller already treats as "no image".
    pub fn imageAt(self: *const Note, i: usize) *const NoteImage {
        if (i >= self.images_len) return &empty_note_image;
        return &self.images[i];
    }
    /// How many pictures this note draws.
    pub fn imageCount(self: *const Note) usize {
        return self.images_len;
    }
    /// Gives a hand-built note a picture and hands it back so the test can state
    /// its shape. For tests, which used to poke the Note's image fields directly.
    pub fn setImageForTest(self: *Note, i: usize, link: []const u8) *NoteImage {
        const n = @min(link.len, self.images[i].url_buf.len);
        @memcpy(self.images[i].url_buf[0..n], link[0..n]);
        self.images[i].url_len = @intCast(n);
        if (self.images_len <= i) self.images_len = @intCast(i + 1);
        return &self.images[i];
    }
    /// The link this note previews, empty when it has none.
    pub fn linkUrl(self: *const Note) []const u8 {
        return self.link_url_buf[0..self.link_url_len];
    }
    pub fn hasLink(self: *const Note) bool {
        return self.link_url_len > 0;
    }
    /// Whether this note carries an image to render.
    pub fn hasImage(self: *const Note) bool {
        return self.images_len > 0;
    }
    /// What the picture's chip says: its dimensions and its weight, as the note
    /// claims them, in the shot's own form (`1600x900 · 240 KB`). Either half may
    /// be missing, and the chip is empty when both are. Never taken from the
    /// decoded bytes, which are the proxy's 480px box and would be a lie about
    /// the file, and never from the response, which carries no headers.
    pub fn imageChipLabel(self: *const Note, arena: std.mem.Allocator) []const u8 {
        return imageChipLabelFor(self.imageAt(0), arena);
    }
    /// The note's first image URL (empty when it has none).
    pub fn imageUrl(self: *const Note) []const u8 {
        return self.imageAt(0).url();
    }
    /// The registered image id for this note's first picture, or 0 while it is
    /// loading, unavailable, or absent.
    pub fn media_id(self: *const Note) u64 {
        return self.mediaIdAt(0);
    }
    /// The same for picture `i`.
    pub fn mediaIdAt(self: *const Note, i: usize) u64 {
        if (mediaSlotFor(mediaKey(self.id, i))) |m| {
            if (m.state == .loaded) return m.image_id;
        }
        return 0;
    }
    /// The author's display name from their kind:0 profile, or the abbreviated
    /// npub until (or unless) a profile is known.
    pub fn author(self: *const Note) []const u8 {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.name_len > 0) return p.name();
        }
        return self.author_buf[0..self.author_len];
    }
    /// The registered avatar image id for this author, or 0 to draw initials.
    pub fn avatar_id(self: *const Note) u64 {
        return avatarImageId(self.pubkey);
    }
    /// The @handle for the identity line: the author's NIP-05, shown as `@name`
    /// (or `@domain` for the root `_@domain` form). Empty when they have no
    /// NIP-05 (a bare npub is not a handle, so nothing is shown rather than
    /// `@npub…`. Allocated in the caller's arena for the frame.
    /// Who this is, under their name, and whether it is a NIP-05 identity. There is ALWAYS something here once the
    /// profile has arrived, which is the point of the whole ladder below: the
    /// identity block is pinned to the avatar's height, so an empty second line
    /// is not restraint, it is a hole in the row that reads as a rendering bug.
    /// It stayed empty for anyone with no NIP-05 and no username distinct from
    /// their display name, which is a great many people.
    ///
    /// In order:
    ///
    ///  1. the NIP-05, WHOLE (`dergigi@primal.net`), and just the domain for the
    ///     root `_@domain` form. The domain is the half that says who vouched for
    ///     this name, so dropping it threw away the part worth showing. Reads in
    ///     the identity violet.
    ///  2. the kind:0 username, `@user`, muted. Skipped when it would only echo
    ///     the name line above it, because the same string twice reads as a
    ///     rendering bug rather than as a handle.
    ///  3. the website, as its host. Not attested by anybody, so muted too, but
    ///     it is something the person chose to say about themselves.
    ///  4. a short npub. Last, and skipped when the name line is ALREADY the
    ///     npub, which is what it falls back to for a profile nobody has.
    ///
    /// Only the first is violet. Violet has to keep meaning "attested somewhere"
    /// or it means nothing.
    pub fn handleLabel(self: *const Note, arena: std.mem.Allocator) struct { text: []const u8, nip05: bool } {
        if (lookupProfile(self.pubkey)) |p| {
            const shown = nip05Display(p.nip05());
            if (shown.len > 0) return .{ .text = shown, .nip05 = true };
            const user = p.username();
            if (user.len > 0 and !std.mem.eql(u8, user, p.name())) {
                return .{ .text = std.fmt.allocPrint(arena, "@{s}", .{user}) catch "", .nip05 = false };
            }
            const host = p.websiteHost();
            if (host.len > 0 and !std.mem.eql(u8, host, p.name())) {
                return .{ .text = host, .nip05 = false };
            }
        }
        // The npub the note already carries, not a fresh bech32 encode. This is
        // built once per note in `setAuthor`, and this line runs per row per
        // frame for everyone the ladder falls through to, so encoding here would
        // be a bech32 conversion and an allocation on the feed's hot path for a
        // string sitting in the struct.
        //
        // Using the SAME bytes also makes the check below exact by construction:
        // `author()` returns this buffer when there is no kind:0 name, so a
        // stranger's row cannot end up saying one shortening of their key on the
        // name line and another underneath it.
        const short = self.author_buf[0..self.author_len];
        if (short.len > 0 and !std.mem.eql(u8, short, self.author())) {
            return .{ .text = short, .nip05 = false };
        }
        return .{ .text = "", .nip05 = false };
    }

    /// The compact `@local` form, for naming somebody INLINE in a sentence
    /// ("Replying to @dergigi"). Deliberately not `handleLabel`: that is the
    /// identity line under a name, where the domain is the half worth showing,
    /// and a whole `dergigi@primal.net` mid-sentence reads as an email address.
    /// The one caller that put this on an identity LINE now uses the ladder.
    pub fn handle(self: *const Note, arena: std.mem.Allocator) []const u8 {
        const p = lookupProfile(self.pubkey) orelse return "";
        if (p.nip05_len == 0) return "";
        const id = p.nip05();
        const at = std.mem.indexOfScalar(u8, id, '@') orelse return "";
        const local = id[0..at];
        const domain = id[at + 1 ..];
        const shown = if (std.mem.eql(u8, local, "_")) domain else local;
        if (shown.len == 0) return "";
        return std.fmt.allocPrint(arena, "@{s}", .{shown}) catch "";
    }
    /// Whether this author's NIP-05 has been verified (well-known JSON maps the
    /// name back to their pubkey). Only then does the identity line show a check.
    pub fn verified(self: *const Note) bool {
        if (lookupProfile(self.pubkey)) |p| return p.nip05_state == .verified;
        return false;
    }
    pub fn time(self: *const Note) []const u8 {
        return self.time_buf[0..self.time_len];
    }

    /// What this note says it was written with, empty when it says nothing.
    pub fn client(self: *const Note) []const u8 {
        return self.client_buf[0..self.client_len];
    }
    /// The reason the author gave for covering this note, empty when they gave
    /// none or the note carries no warning.
    pub fn warning(self: *const Note) []const u8 {
        return self.warning_buf[0..self.warning_len];
    }
    pub fn content(self: *const Note) []const u8 {
        return self.content_buf[0..self.content_len];
    }

    /// (Re)computes the relative timestamp against `now_s`. Cheap and
    /// allocation-free, so the UI can freshen every tick without a re-query.
    pub fn setTime(self: *Note, now_s: i64) void {
        const written = ageInto(&self.time_buf, self.created_at, now_s) catch return;
        self.time_len = @intCast(written.len);
    }

    /// How long ago, in the app's one spelling of it.
    pub fn ageInto(buf: []u8, created_at: i64, now_s: i64) ![]const u8 {
        const dt = now_s - created_at;
        if (dt < 60) return std.fmt.bufPrint(buf, "now", .{});
        if (dt < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(dt, 60)});
        if (dt < 86_400) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(dt, 3600)});
        if (dt < 604_800) return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(dt, 86_400)});
        return std.fmt.bufPrint(buf, "{d}w", .{@divTrunc(dt, 604_800)});
    }
};

/// Which top-level screen the app shows.
pub const Stage = enum { onboarding, ready, settings };

pub const Model = struct {
    /// The loaded feed. A SLICE into `g_feed_notes`, which grows as the reader
    /// pages down and is never handed back. It was a fixed array of three
    /// hundred, and that array was the only reason the feed had a bottom.
    ///
    /// Re-pointed by `rebuildNotes` after a growth, so nothing holds this across
    /// one.
    notes: []Note = &.{},
    notes_len: usize = 0,
    live_relays: usize = 0,
    /// How many relays the reader has, sampled on the tick beside the live
    /// count: a frame that mixed a fresh numerator with a stale denominator
    /// would read "4/3 relays".
    relay_count: usize = 0,
    /// Which chrome menu is open, if any. One at a time: opening one closes the
    /// rest, and Escape or a press outside closes whatever is open.
    menu: ChromeMenu = .none,
    /// Notes still owed to the relays, sampled on the tick: the queue itself is
    /// written by the publisher's thread, so the view reads this snapshot rather
    /// than the queue, and one frame never disagrees with itself.
    outbox_pending: usize = 0,
    outbox_stuck: usize = 0,
    /// A note the queue had no room for. It was written to this machine and
    /// offered to nobody, which is the one outcome the queue exists to make
    /// impossible, so it is said out loud instead of left to the flag nobody
    /// reads.
    outbox_overflowed: bool = false,
    /// Whether a level is showing its replies from outside the follow graph, and
    /// how many pages of replies it has revealed. PER LEVEL, indexed like the
    /// back-stack: a level stays mounted while the reader walks into a reply and
    /// back, and it has to come back the size it was. One shared pair of flags
    /// collapsed a parent's revealed pages on the way back, under a scroll offset
    /// restored for the taller list.
    thread_outside_open: [thread_depth_max + 1]bool = [_]bool{false} ** (thread_depth_max + 1),
    thread_page: [thread_depth_max + 1]usize = [_]usize{1} ** (thread_depth_max + 1),
    /// Whether the reader has paused the pool. Reading keeps working: the store
    /// is the app, so a pause stops the sockets, not the feed.
    relays_paused: bool = false,
    offline_relays: usize = 0,
    // The composer's edit state (text + caret + selection). The view binds the
    // text through `draft()`, never the buffer itself, and every edit event is
    // mirrored here in `update`.
    draft_buffer: canvas.TextBuffer(compose_capacity) = .{},
    /// Whether the note being written carries a content warning, and why. The
    /// reason may stay empty: the tag is the warning.
    warn_on: bool = false,
    warn_buffer: canvas.TextBuffer(warning_input_capacity) = .{},
    /// Bytes of the last paste that did not fit, so the composer can say so.
    /// Zero once something that fits is typed or pasted over it.
    draft_dropped: usize = 0,
    // Which screen shows. A returning user (session on disk) starts at `.ready`;
    // a newcomer starts at `.onboarding` and moves to `.ready` when they sign in.
    // `.settings` is reached from the feed and returns to it.
    stage: Stage = .onboarding,
    // The onboarding sign-in field: an existing `nsec` to import a key, or a
    // `bunker://` URL to pair with an external NIP-46 signer (Notary).
    login_buffer: canvas.TextBuffer(220) = .{},
    // Settings: whether the "log out" confirmation is showing, and whether the
    // local secret key is revealed for backup.
    logout_pending: bool = false,
    // The media-proxy field in Settings (see `g_media_proxy_buf`).
    proxy_buffer: canvas.TextBuffer(200) = .{},
    proxy_saved: bool = false,
    // The last Save was refused because what is in the field is not an address.
    proxy_invalid: bool = false,
    // The Edit profile sheet: whether it is open, what is in its fields, and
    // whether the app has the reader's current profile to merge into.
    editing_profile: bool = false,
    profile_stage: ProfileStage = .fetching,
    // When the sheet started waiting, so a relay that never answers becomes a
    // stated fact rather than a spinner nobody can leave.
    profile_asked_at: i64 = 0,
    // Which key the name was read from, so the edit rewrites THAT key.
    profile_name_key: ProfileNameKey = .display_name,
    // Whether the sheet has been seeded from the reader's own profile, so the
    // background fetch landing later never overwrites what they have typed.
    profile_seeded: bool = false,
    // A field whose real value did not fit. Left empty and left alone.
    profile_name_long: bool = false,
    profile_about_long: bool = false,
    profile_picture_long: bool = false,
    profile_website_long: bool = false,
    profile_banner_long: bool = false,
    profile_lud16_long: bool = false,
    profile_nip05_long: bool = false,
    profile_name_buffer: canvas.TextBuffer(64) = .{},
    profile_about_buffer: canvas.TextBuffer(profile_about_capacity) = .{},
    profile_picture_buffer: canvas.TextBuffer(200) = .{},
    profile_website_buffer: canvas.TextBuffer(200) = .{},
    profile_banner_buffer: canvas.TextBuffer(200) = .{},
    profile_lud16_buffer: canvas.TextBuffer(96) = .{},
    profile_nip05_buffer: canvas.TextBuffer(96) = .{},
    // The add-a-relay field, and why the last press did nothing.
    relay_buffer: canvas.TextBuffer(96) = .{},
    relay_error: bool = false,
    relay_full: bool = false,
    // The add-a-media-server field in Settings, and why the last press did nothing.
    blossom_buffer: canvas.TextBuffer(96) = .{},
    blossom_error: BlossomEdit = .none,
    // The description of the picture waiting to be uploaded from the composer.
    upload_alt_buffer: canvas.TextBuffer(200) = .{},
    // The last Remove was refused because it would have emptied the list.
    relay_last: bool = false,
    // Which note's picture is expanded to fill the window, if any.
    expanded_note: ?i64 = null,
    /// Which of that note's pictures the viewer is showing. Zero for a note with
    /// one, which is every note the viewer could open before galleries existed.
    expanded_image: u8 = 0,
    /// The note this reader has asked to delete, while the confirmation is up.
    /// The one action here with no undo, so it is asked rather than done.
    deleting_note: ?i64 = null,
    /// A write that would start a list from nothing, held while the reader is
    /// asked. Every relay has finished without sending that list, and only the
    /// reader can say whether this account really has none.
    fresh_ask: ?FreshAsk = null,
    /// The Edit profile sheet, one press into publishing a first profile: the
    /// warning is up and the next Save goes through.
    profile_confirm_new: bool = false,
    /// Whether the mention picker has been dismissed for the query now in the
    /// draft. It has no open flag of its own: it shows whenever the draft ends
    /// in a `@word`, so Escape and a press outside had nothing to clear and it
    /// came back on the next rebuild. Cleared by the next edit, because a new
    /// query is a new question.
    mention_dismissed: bool = false,
    // Whether the notifications sheet is up, and which tab it shows.
    notifications_open: bool = false,
    /// Which notifications the sheet shows. EVERYONE by default, because that is
    /// what the bell counts.
    ///
    /// Defaulting to the follows-only view meant a stranger's reply lit the badge
    /// and then opened onto "Nothing from the people you follow yet", and opening
    /// marked it read on the way past, so the reader was told about something,
    /// shown nothing, and never told again. Someone the reader has never followed
    /// replying to them is not an edge case: for an inbox it is the ordinary
    /// case, and it is most of the reason to have one. Narrowing to follows is
    /// still one press away, as a filter the reader chooses rather than one
    /// applied silently underneath a number.
    notifications_everyone: bool = true,
    // How many pages of the inbox are shown. A page replaces rather than
    // appends, the same way a thread's does, because a sheet is a plain column
    // and an unbounded one would refuse the whole view.
    /// Which page of the sheet is showing, counted from zero. Pages REPLACE each
    /// other rather than accumulating, so this is an index, not a depth.
    // Whether the compose sheet is open. Compose is on demand from the "New
    // note" button in the titlebar, not a permanent bar, so the feed fills the
    // window.
    composing: bool = false,
    // Whether the guest dismissed the join strip this session. Dismissal only
    // hides the strip; the join surface stays reachable through every gated
    // verb and the status bar's Guest chip.
    guest_strip_dismissed: bool = false,
    // Whether the first-intent join sheet is up (the ladder: create, bring a
    // key, use a signer). Rises when a guest presses a gated verb, or from the
    // strip and the Guest chip.
    joining: bool = false,
    /// What the reader reached for before they had a key.
    ///
    /// One field, because there is one answer to "what happens after you sign
    /// in". The app used to carry two ad-hoc ones, a bool for the composer and an
    /// id for a like, and every verb added after them either grew a third or
    /// quietly remembered nothing: pressing Follow as a guest opened the sheet,
    /// signed you in, and dropped the follow on the floor, because there was
    /// nowhere to put it. A union makes forgetting a compile error rather than an
    /// omission.
    pending: Intent = .none,
    // The remembered intent: the guest reached for the composer, so composing
    // opens by itself the moment an identity exists. The sheet says so.

    // The other remembered intent: the guest reached for a like. The note id is
    // held here (0 = none) so the like completes the moment an identity exists.

    // Whether the join sheet is on its focused bunker-input step (chose "Use
    // your own signer") rather than the ladder.
    bunker_mode: bool = false,
    // The search field, which is also where an address is pasted: whether it is
    // up, what is typed in it, and why the last submit did not go anywhere. It
    // began as the way to open an address (Plaza could COPY one and had no way
    // to take one back), and kept its names when it learned to find people.
    address_open: bool = false,
    address_buffer: canvas.TextBuffer(220) = .{},
    address_error: AddressError = .none,
    // The open thread: the focused note's id (0 = the feed, not a thread). When
    // set, the thread is layered OVER the feed (which stays mounted, so its
    // scroll offset survives) with the note and its replies.
    viewing_thread: i64 = 0,
    // The open thread's root, snapshotted so it survives a store rebuild and a
    // reply can be opened as its own thread. Valid while viewing_thread != 0.
    thread_root: Note = .{},
    // The open thread's replies, cached from the store so they are pressable
    // (open as a sub-thread), get their pictures fetched, and hold across
    // rebuilds. Rebuilt each tick, oldest first.
    //
    // A SLICE, because a person's page outgrows a thread's cap: it pages down
    // the way the feed does. It starts on a thread's worth of storage and
    // `growLevelNotes` moves it onto a bigger buffer when a profile asks for one.
    thread_notes: []Note = &feed_state.g_level_boot,
    thread_notes_len: usize = 0,
    /// How many of the open person's notes the store is asked for. Grows a page
    /// at a time as the reader reaches the end of their list.
    profile_limit: usize = profile_page,
    /// Pages the open person's page has fetched by itself to fill a short tab.
    profile_autofill: u8 = 0,
    /// The cursor the last network ask for older notes started from, so the
    /// page does not keep asking from a place that gave it nothing to show.
    profile_asked_until: i64 = 0,
    // The back-stack of thread roots: opening a reply as a sub-thread pushes the
    // current root, so Back returns to it, and only the last Back returns to the
    // feed.
    thread_stack: [thread_depth_max]Screen = [_]Screen{.{}} ** thread_depth_max,
    thread_stack_len: usize = 0,
    /// Whose profile the CURRENT level shows, when it shows one. A thread and a
    /// profile are the same kind of thing to the back stack, so Back walks out
    /// of either without knowing which it is leaving.
    viewing_profile: ?[32]u8 = null,
    /// Whether the level on top is the bookmark list.
    viewing_bookmarks: bool = false,
    /// The topic being read, lowercased and without its `#`. A fixed buffer
    /// rather than a slice: a level sits on the back stack across rebuilds, and
    /// the arena the span was built from is reset every frame.
    topic_buf: [max_topic_bytes]u8 = undefined,
    topic_len: u8 = 0,
    /// Which of the profile's tabs is showing.
    profile_tab: ProfileTab = .notes,
    // Whether the first reply fetch is still out with nothing in hand, so the
    // thread shows skeleton rows rather than looking empty under the root.
    thread_loading: bool = false,
    // The open thread's fetch generation and when it opened, so the loading
    // skeletons retire the moment THIS thread's fetch reports back (or a grace
    // period elapses), never on a stale earlier thread's completion.
    thread_seq: u64 = 0,
    thread_open_at: i64 = 0,
    // The reply composer's edit state, bound through `reply_draft`.
    reply_buffer: canvas.TextBuffer(compose_capacity) = .{},
    // People the reader has switched off for the draft they are writing. An
    // exclusion set rather than an inclusion one, so it cannot go stale: if the
    // mention is deleted the pubkey stops being derived and the entry is simply
    // never consulted again.
    mentions_off: [max_mention_tags][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** max_mention_tags,
    mentions_off_len: usize = 0,
    /// Whether the level on screen was opened FROM notifications, so closing it
    /// goes back there rather than to the feed. Pressing a row used to drop the
    /// page entirely, and Back then landed on a feed the reader had not been
    /// looking at, with their place in the notifications list gone.
    notifications_return: bool = false,
    // The name beat: after creating an identity, one optional, skippable ask
    // so the account is not blank. Never for imported keys or signers.
    naming: bool = false,
    name_buffer: canvas.TextBuffer(64) = .{},
    // A small confirming toast ("Posted", "Name set"), cleared by the tick.
    toast_buf: [48]u8 = undefined,
    toast_len: usize = 0,
    toast_until: i64 = 0,
    // The backup nudge after the first local-key post this session: calm,
    // dismissible, stakes stated plainly.
    backup_nudge: bool = false,
    backup_nudge_dismissed: bool = false,
    // Where the feed is scrolled, so images load around the viewport instead of
    // only at the top. The windowed list replaces this estimate with the
    // runtime's exact visible range in the next milestone.
    feed_scroll: canvas.ScrollState = .{},
    // Settings' own scroll offset. Echoed from the scroll view and bound back to
    // it, which is what lets a press move the page: asking to log out grows the
    // page at its foot, and the question has to be scrolled into view or it is
    // answered by nobody.
    settings_scroll_y: f32 = 0,
    // How many notes the feed currently asks the store for; grows a page at a
    // time as the reader reaches the end.
    feed_limit: usize = feed_page,

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, the stage through
    // `show_onboarding`/`show_feed`/`show_settings`, the login field through
    // `login_draft`, so the raw fields are never bound by name.
    // Everything the FEED reads is listed here too: that screen is a Zig view
    // now, so markup never binds its state (the welcome and Settings fragments
    // still bind theirs, and are still checked).
    pub const view_unbound = .{
        "notes",                     "notes_len",              "live_relays",            "offline_relays",         "draft_buffer",
        "stage",                     "login_buffer",           "logout_pending",         "proxy_buffer",           "proxy_saved",
        "feed_scroll",               "feed_limit",             "draft",                  "draft_empty",            "identity",
        "has_notes",                 "empty",                  "status",                 "empty_text",             "footer",
        "note_list",                 "expanded_note",          "composing",              "caught_up",              "relay_health",
        "relays_online",             "scope_voices",           "is_guest",               "show_guest_strip",       "guest_strip_dismissed",
        "joining",                   "pending",                "naming",                 "name_buffer",            "name_draft",
        "name_empty",                "toast_buf",              "toast_len",              "toast_until",            "toast_text",
        "backup_nudge",              "backup_nudge_dismissed", "bunker_mode",            "pending_text",           "viewing_thread",
        "reply_buffer",              "reply_draft",            "reply_empty",            "thread_root",            "thread_notes",
        "thread_notes_len",          "thread_stack",           "thread_stack_len",       "thread_loading",         "thread_seq",
        "thread_open_at",            "address_open",           "address_buffer",         "address_error",          "address_draft",
        "address_empty",             "address_status",         "address_action",         "proxy_invalid",          "settings_scroll_y",
        // Read by the Zig view rather than bound by name in markup. The one
        // markup file is the join screen; everything else this app draws, it
        // draws itself, so these are unbound by design rather than by mistake.
        // Listed so the check has nothing left to say, and a NEW unbound field
        // stands out against silence instead of hiding in a hundred lines.
        "can_open_notary",           "client_tag_explainer",   "client_tag_on",          "currentLevel",           "deleting_note",
        "direct_fallback_explainer", "direct_fallback_on",     "draft_dropped",          "editing_profile",        "expanded_image",
        "levelOpen",                 "logout_idle",            "logout_warning",         "mention_dismissed",      "mentionsOff",
        "mentions_off",              "mentions_off_len",       "menu",                   "notifications_everyone", "notifications_open",
        "notifications_return",      "outbox_label",           "outbox_overflowed",      "outbox_pending",         "outbox_stuck",
        "post_delay_explainer",      "post_delay_label",       "previews_explainer",     "previews_on",            "profile_about",
        "profile_about_buffer",      "profile_about_long",     "profile_asked_at",       "profile_can_save",       "profile_name",
        "profile_name_buffer",       "profile_name_key",       "profile_name_long",      "profile_picture",        "profile_picture_buffer",
        "profile_picture_long",      "profile_seeded",         "profile_stage",          "profile_banner",         "profile_banner_buffer",
        "profile_banner_long",       "profile_invalid",        "profile_lud16",          "profile_lud16_buffer",   "profile_lud16_long",
        "profile_nip05",             "profile_nip05_buffer",   "profile_nip05_long",     "profile_website",        "profile_website_buffer",
        "profile_website_long",      "profile_status",         "profile_tab",            "profile_untouched",      "proxy_draft",
        "proxy_explainer",           "proxy_on",               "proxy_status",           "relay_buffer",           "relay_count",
        "relay_draft",               "relay_error",            "relay_full",             "relay_status",           "relays_paused",
        "scope_name",                "sensitive_explainer",    "sensitive_on",           "signer_line",            "signer_sub",
        "warn_buffer",               "warn_draft",             "warn_on",                "thread_outside_open",    "thread_page",
        "topic_buf",                 "topic_len",              "update_check_explainer", "update_check_on",        "version_line",
        "viewingTopic",              "viewing_bookmarks",      "blossom_buffer",         "blossom_draft",          "blossom_error",
        "blossom_status",            "upload_alt",             "upload_alt_buffer",      "profile_limit",          "profile_autofill",
        "profile_asked_until",       "relay_last",             "profile_can_retry",      "fresh_ask",              "profile_confirm_new",
    };

    /// Why the join sheet is up, in the reader's own terms. Empty when they
    /// opened it themselves rather than being sent there by a verb.
    pub fn pending_text(self: *const Model, ui: *AppUi) []const u8 {
        return pendingText(ui, self);
    }

    /// What is typed in the address field.
    pub fn address_draft(self: *const Model) []const u8 {
        return self.address_buffer.text();
    }
    /// Whether the address field is blank, which disables Open.
    pub fn address_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.address_buffer.text(), " \t\r\n").len == 0;
    }
    /// What the field says under itself: the last refusal, or what it accepts.
    pub fn address_status(self: *const Model) []const u8 {
        return switch (self.address_error) {
            .none => switch (classifySearch(self.address_buffer.text())) {
                .blank => "",
                .address => "An address. Enter opens it.",
                .key => "That looks like a key or a signer link. It is not searched for, and it stays on this device.",
                .nip05 => if (nip05Pending(self.address_buffer.text())) "Asking the domain who that is." else "A NIP-05 address. Enter asks its domain who that is.",
                .term => "Enter asks the search relays now.",
            },
            .unreadable => "That is not an address Plaza can read.",
            .wrong_kind => "That address is valid and names something Plaza has no screen for.",
            .not_found => "That domain does not list anyone by that name.",
            .lookup_failed => "That domain did not answer.",
        };
    }
    /// What the field's one button does with what is in it.
    pub fn address_action(self: *const Model) []const u8 {
        return switch (classifySearch(self.address_buffer.text())) {
            .blank, .address, .key => "Open",
            .nip05 => "Look up",
            .term => "Search relays",
        };
    }

    /// The name beat's current text.
    pub fn name_draft(self: *const Model) []const u8 {
        return self.name_buffer.text();
    }
    /// Whether the name field is blank, which disables Save.
    pub fn name_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.name_buffer.text(), " \t\r\n").len == 0;
    }
    /// The live toast text, empty when none is showing.
    pub fn toast_text(self: *const Model) []const u8 {
        if (self.toast_until == 0) return "";
        return self.toast_buf[0..self.toast_len];
    }

    /// The composer's current text (what `text="{draft}"` binds).
    pub fn draft(self: *const Model) []const u8 {
        return self.draft_buffer.text();
    }
    /// Whether the draft is blank (only whitespace), which disables Post.
    pub fn draft_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.draft_buffer.text(), " \t\r\n").len == 0;
    }
    /// The reply composer's current text.
    pub fn reply_draft(self: *const Model) []const u8 {
        return self.reply_buffer.text();
    }
    /// Whether the reply is blank, which disables Reply.
    pub fn reply_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.reply_buffer.text(), " \t\r\n").len == 0;
    }
    /// The composer's "posting as" line: the identity's abbreviated npub, marked
    /// when signing is routed through an external signer, or a setup note while
    /// the key is still being prepared.
    pub fn identity(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        // A remote sign that never came back: the draft has been restored to the
        // composer, so say why rather than let it silently reappear.
        if (keyholder.g_signer_kind == .remote and remote_signer.g_remote_sign_notice.load(.acquire))
            return "Your signer didn't respond. Draft restored, try again.";
        // The built-in signer, which is a separate process on loopback and can
        // refuse, be busy, or not be running at all.
        if (keyholder.g_signer_kind == .helper and keyholder.g_helper_sign_notice.load(.acquire))
            return "Notary could not sign that. Draft restored, try again.";
        if (keyholder.g_identity_npub_len == 0) return "Preparing your key…";
        // Show the user's own display name once their kind:0 is known, else npub.
        var who: []const u8 = keyholder.g_identity_npub_buf[0..keyholder.g_identity_npub_len];
        if (activePubkey()) |pk| {
            if (lookupProfile(pk)) |p| {
                if (p.name_len > 0) who = p.name();
            }
        }
        if (keyholder.g_signer_kind == .remote) {
            // The connection's honest state, not just its happy path: reaching,
            // signing as (which key), or unreachable.
            return switch (remote_signer.g_remote_status.load(.acquire)) {
                1 => std.fmt.allocPrint(arena, "Reaching your signer · {s}", .{who}) catch who,
                2 => std.fmt.allocPrint(arena, "Signing via your signer · {s}", .{who}) catch who,
                3 => "Your signer is unreachable. Posts will not sign.",
                else => std.fmt.allocPrint(arena, "Your signer · {s}", .{who}) catch who,
            };
        }
        return std.fmt.allocPrint(arena, "Posting as {s}", .{who}) catch who;
    }

    /// The onboarding sign-in field text (what `text="{login_draft}"` binds).
    pub fn login_draft(self: *const Model) []const u8 {
        return self.login_buffer.text();
    }
    /// Whether this install can make a key at all, which disables the welcome
    /// screen's create button. The join ladder swaps its whole card out; this
    /// screen is compiled markup with fixed text, so it binds the two things
    /// that can change: whether the button works, and the line under it.
    pub fn no_keyholder(self: *const Model) bool {
        _ = self;
        return keyholderMissing();
    }
    /// The line under the welcome screen's create button.
    pub fn create_hint(self: *const Model) []const u8 {
        _ = self;
        if (keyholderMissing()) return "Notary, the part of Plaza that holds your key, is missing from this install, so Plaza cannot make one. Reinstalling Plaza fixes it, or bring a key you already have.";
        return "A second to set up. No email, no signup.";
    }
    /// The welcome screen's opening line, which normally sells making a key.
    /// With no keyholder it cannot be made, and an invitation printed directly
    /// over a greyed-out button is the screen arguing with itself.
    pub fn welcome_lead(self: *const Model) []const u8 {
        _ = self;
        if (keyholderMissing()) return "Sign in with a key you already have and Plaza sets you up with a starter feed of great accounts. Your notes stay on your device and publish straight to the network.";
        return "Create an identity and Plaza sets you up with a starter feed of great accounts. Your notes stay on your device and publish straight to the network.";
    }
    /// Whether the sign-in field is blank, which disables Continue.
    pub fn login_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.login_buffer.text(), " \t\r\n").len == 0;
    }
    /// The status line under the sign-in field: a synchronous parse error, or
    /// the async bunker-connect state.
    pub fn login_status(self: *const Model) []const u8 {
        _ = self;
        switch (@as(LoginError, @enumFromInt(login.g_login_error.load(.acquire)))) {
            .format => return "Paste a bunker link, or bring your key in Notary.",
            .bad_key => return "That doesn't look like a valid key.",
            // Not an error the reader made. Their key is fine; it belongs in
            // the app that holds keys, and that app is opening.
            .key_goes_to_notary => return "Your key goes in Notary, not here. Opening it now.",
            // The link was fine and the signer did not answer it: the relay in
            // the link is down, or the signer is not running, or it said no.
            // Nothing was signed in, so there is nothing to undo.
            .signer_silent => return "Couldn't connect to your signer. Check that it is running and that the link is current, then try again.",
            .none => {},
        }
        return switch (remote_signer.g_remote_status.load(.acquire)) {
            1 => "Connecting to your signer…",
            3 => "Couldn't read that bunker link.",
            else => "",
        };
    }

    // -- Settings ------------------------------------------------------------

    /// Whether the logout confirmation is not yet showing.
    pub fn logout_idle(self: *const Model) bool {
        return !self.logout_pending;
    }
    /// The logout confirmation warning, sharper for a local key (it is deleted).
    pub fn logout_warning(self: *const Model) []const u8 {
        _ = self;
        // A note handed to a signer that has not answered exists in exactly one
        // place: the slot the sign-out is about to free. It cannot be parked in
        // the outbox the way a queued note is, because it has no signature and
        // therefore no id, and it cannot be left in the composer, because that
        // is the previous reader's writing sitting in front of the next account.
        // So the reader is told, and the press is theirs to make.
        if (signInFlight()) {
            return "A note you just posted has not been signed yet. Signing out now will lose it.";
        }
        return switch (keyholder.g_signer_kind) {
            .remote => "You'll be signed out and returned to the welcome screen. Your signer keeps your key.",
            // Nothing is deleted, and that is the change worth stating plainly.
            //
            // Signing out of Plaza used to ask Notary to forget the key, which
            // conflated two different acts: leaving a client, and taking your
            // identity off the machine. One press in one app should not destroy
            // an identity every other app was using. So Plaza stops using the
            // key and Notary keeps holding it.
            //
            // Which means the reader has to be told where it went, or "signed
            // out" reads as "gone" and they go looking for a key that is fine.
            .helper => "You'll be signed out of Plaza and returned to the welcome screen. Your key stays in Notary, so you can sign back in. To remove it from this Mac, open Notary.",
        };
    }
    /// The media-proxy field's text (what `text="{proxy_draft}"` binds).
    pub fn proxy_draft(self: *const Model) []const u8 {
        return self.proxy_buffer.text();
    }
    /// Confirmation under the media-proxy field.
    pub fn proxy_status(self: *const Model) []const u8 {
        if (self.proxy_invalid) return "Not saved. A proxy address starts with https:// or http:// and names a host.";
        if (!self.proxy_saved) return "";
        return if (prefs.g_media_proxy_len == 0) "Saved. Loading originals directly." else "Saved.";
    }
    /// What signs for this account, as a sentence rather than a badge.
    pub fn signer_line(self: *const Model) []const u8 {
        _ = self;
        return switch (keyholder.g_signer_kind) {
            .remote => "Signing via a remote signer",
            .helper => "Signing via Notary",
        };
    }
    /// Whether Notary is what holds this account's key, and whether there is a
    /// window to show it in. Both halves matter: a remote signer is somebody
    /// else's process on somebody else's machine and Notary has nothing to say
    /// about it, and an install that arrived without the window would offer a
    /// press that opens nothing.
    pub fn can_open_notary(self: *const Model) bool {
        _ = self;
        return openNotaryAvailable();
    }
    /// Where the key actually is, which is the part worth knowing.
    pub fn signer_sub(self: *const Model) []const u8 {
        _ = self;
        return switch (keyholder.g_signer_kind) {
            .remote => "The key never leaves your signer. Plaza asks it to sign.",
            .helper => "The key is held by Notary on this Mac, not by Plaza.",
        };
    }
    /// Whether the app is allowed to fetch what a note names.
    pub fn previews_on(self: *const Model) bool {
        _ = self;
        return prefs.g_media_previews;
    }
    /// Whether covered notes are drawn without their cover.
    pub fn sensitive_on(_: *const Model) bool {
        return prefs.g_show_sensitive;
    }
    pub fn sensitive_explainer(_: *const Model) []const u8 {
        return if (prefs.g_show_sensitive)
            "On. Notes their authors marked sensitive are drawn like any other, pictures included, and nothing asks first."
        else
            "Off. A note its author marked sensitive stays covered, and nothing it points at is fetched, until you press it.";
    }
    /// What is typed in the content warning's reason field.
    pub fn warn_draft(self: *const Model) []const u8 {
        return self.warn_buffer.text();
    }
    pub fn profile_name(self: *const Model) []const u8 {
        return self.profile_name_buffer.text();
    }
    pub fn profile_about(self: *const Model) []const u8 {
        return self.profile_about_buffer.text();
    }
    pub fn profile_picture(self: *const Model) []const u8 {
        return self.profile_picture_buffer.text();
    }
    pub fn profile_website(self: *const Model) []const u8 {
        return self.profile_website_buffer.text();
    }
    pub fn profile_banner(self: *const Model) []const u8 {
        return self.profile_banner_buffer.text();
    }
    pub fn profile_lud16(self: *const Model) []const u8 {
        return self.profile_lud16_buffer.text();
    }
    pub fn profile_nip05(self: *const Model) []const u8 {
        return self.profile_nip05_buffer.text();
    }
    /// What the sheet is able to do right now, said in the sheet.
    pub fn profile_status(self: *const Model) []const u8 {
        return switch (self.profile_stage) {
            .fetching => "Reading your current profile from your relays…",
            // Two different states wearing one name. For a key minted here,
            // absent is a fact and the first save is a first profile. For an
            // imported key it is only what the relays this app happens to dial
            // have said, and publishing over it would delete a profile living
            // somewhere they have not been asked.
            .absent => if (own_lists.g_identity_minted_here or startedFresh(.profile))
                "You have no profile yet. Saving publishes your first one."
            else switch (ownListsRead()) {
                // Every relay finished and none has a profile. The reader is the
                // only one who can say whether that is the whole story.
                .none_found => if (self.profile_confirm_new)
                    "A profile you keep in another app would be replaced. Press again only if this account is new."
                else
                    "No relay has a profile for you. If this account is new, Save publishes your first one.",
                .reading => "Plaza has not found a profile yet and is still hearing from your relays.",
                .incomplete => "Plaza cannot tell if you have a profile: not every relay that may keep one answered.",
            },
            // Deliberately NOT "you have no profile". Not hearing back is not
            // the same as being told there is nothing, and only one of those is
            // safe to publish over.
            .unread => "Could not read your current profile. Nothing will be published over it until it loads.",
            .have => "",
            .saving => "Signing…",
            .sent => "Saved here and sent to your relays. Other clients will show it as they pass it on.",
            .failed => "Could not sign this. Nothing was published, and your profile is unchanged.",
        };
    }
    pub fn update_check_on(_: *const Model) bool {
        return updateCheckOn();
    }
    /// Says what it does AND what it costs, because the cost is a request to a
    /// server on a timer and that is the thing worth being able to refuse.
    pub fn update_check_explainer(_: *const Model) []const u8 {
        return if (updateCheckOn())
            "Plaza asks GitHub for its newest release a few times a day, and says so here when there is one. Nothing else is sent."
        else
            "Plaza will not ask, and makes no request at all. You can check at github.com/zig-nostr/plaza/releases.";
    }
    pub fn client_tag_on(_: *const Model) bool {
        return clientTag();
    }
    /// Says what turning it on actually publishes, in the terms the reader cares
    /// about: not "adds a tag" but "every note says where it came from, forever".
    pub fn client_tag_explainer(_: *const Model) []const u8 {
        return if (clientTag())
            "On. Every note you post says it was written in Plaza. Anyone reading it in any client can see that."
        else
            "Off. Your notes say nothing about what you wrote them with.";
    }
    /// Whether all three fields are still empty, which is the only state where a
    /// late-arriving profile may fill them in.
    pub fn profile_untouched(self: *const Model) bool {
        return self.profile_name_buffer.text().len == 0 and
            self.profile_about_buffer.text().len == 0 and
            self.profile_picture_buffer.text().len == 0 and
            self.profile_website_buffer.text().len == 0 and
            self.profile_banner_buffer.text().len == 0 and
            self.profile_lud16_buffer.text().len == 0 and
            self.profile_nip05_buffer.text().len == 0;
    }
    /// The first field whose value no other client would be able to use, or an
    /// empty string when every field is either empty or plausible.
    ///
    /// Validated only as far as is honest. A lightning address that looks right
    /// can still have no LNURL endpoint behind it, and this cannot know that
    /// without asking. What it can catch is the shape being wrong, which is the
    /// difference between a field nobody can use and a field somebody typed a
    /// sentence into.
    ///
    /// Empty is always allowed. An empty field removes its key, which is a way
    /// of saying "I do not have one" and is not an error.
    pub fn profile_invalid(self: *const Model) []const u8 {
        if (!looksLikeUrl(trimmedField(self.profile_picture()))) return "Picture should start with https://";
        if (!looksLikeUrl(trimmedField(self.profile_banner()))) return "Banner should start with https://";
        if (!looksLikeUrl(trimmedField(self.profile_website()))) return "Website should start with https://";
        if (!looksLikeAddress(trimmedField(self.profile_lud16()))) return "Lightning address should look like you@wallet.example";
        if (!looksLikeAddress(trimmedField(self.profile_nip05()))) return "NIP-05 identifier should look like you@example.com";
        return "";
    }

    /// Saving is refused until the app HAS the profile it would be merging into.
    /// Whether asking the relays again can change what the sheet says: a read
    /// that did not finish, or one that finished empty for a key that was not
    /// made here (the profile may have been published since).
    pub fn profile_can_retry(self: *const Model) bool {
        return switch (self.profile_stage) {
            .unread => true,
            .absent => !noHistoryKnown(.profile),
            else => false,
        };
    }
    /// Publishing a merge of nothing is how a lightning address disappears.
    ///
    /// `.absent` is the case that needed the argument. It means "a relay
    /// answered and did not send a kind:0", which reads as "you have none" and
    /// is the same inference `canWriteFollows` and `canWriteRelayList` both
    /// refuse: on a cold import the relays being asked are the four this app was
    /// born with, and a clean answer from those is not evidence about a profile
    /// living somewhere else. Saving from `.absent` merged into a literal `{}`
    /// and published it, so a reader who typed a display name lost their
    /// lightning address, their NIP-05, their banner, their website and every
    /// NIP-39 proof in one press. A key minted in this app has no profile
    /// anywhere and is the one case where absent really is absent.
    pub fn profile_can_save(self: *const Model) bool {
        // `.sent` stays savable: a reader who spots a typo in the name they just
        // saved must be able to fix it, and a sheet whose Save is dead after one
        // press is a sheet they have to close and reopen to use again.
        // A field nobody else could read is not worth publishing, and a kind:0
        // is replaceable: the bad value would be what every other client sees.
        if (self.profile_invalid().len > 0) return false;
        return switch (self.profile_stage) {
            .have, .failed, .sent => true,
            // Not made here, and not yet said to be new: Save is live only once
            // every relay has finished without a profile, and then it asks.
            .absent => noHistoryKnown(.profile) or ownListsRead() == .none_found,
            .fetching, .saving, .unread => false,
        };
    }
    /// The add-a-relay field's text.
    pub fn relay_draft(self: *const Model) []const u8 {
        return self.relay_buffer.text();
    }
    /// Why the last Add did nothing, said in the field's own terms.
    pub fn relay_status(self: *const Model) []const u8 {
        if (self.relay_last) return "Plaza needs at least one relay. Add another first, then remove this one.";
        if (self.relay_full) return "That's the most relays this app keeps. Remove one first.";
        if (self.relay_error) return "A relay address starts with wss:// and names a host.";
        // Last, because the two above are about the press that just happened
        // and this one is about the account. An edit that will not be published
        // has to say so: silence here would read as "published", which is the
        // one thing it is not.
        if (relayWriteBlockedReason()) |why| return why;
        return "";
    }
    /// The add-a-media-server field's text.
    pub fn blossom_draft(self: *const Model) []const u8 {
        return self.blossom_buffer.text();
    }
    /// What the line under that field says: why the last press did nothing, or
    /// what the list is waiting on.
    pub fn blossom_status(self: *const Model) []const u8 {
        return blossomStatusText(self.blossom_error);
    }
    /// The description typed for the picture about to be uploaded.
    pub fn upload_alt(self: *const Model) []const u8 {
        return self.upload_alt_buffer.text();
    }
    /// What the previews switch is, in the terms that matter: not bandwidth.
    pub fn previews_explainer(self: *const Model) []const u8 {
        _ = self;
        return "Pictures, faces, link previews and NIP-05 checks are fetched from the hosts a note names. " ++
            "Off, none of that is asked for until you press a picture, and only your relays learn you are reading.";
    }
    pub fn proxy_on(self: *const Model) bool {
        _ = self;
        return prefs.g_media_proxy_on;
    }
    pub fn proxy_explainer(self: *const Model) []const u8 {
        _ = self;
        return "On, a picture's host never sees you, and it arrives already resized: a 2040x1536 photograph is 611 KB from the source and a fraction of that through the proxy. " ++
            "Off, pictures come straight from whoever hosts them, who then learn your address and how much you scroll.";
    }
    pub fn direct_fallback_on(self: *const Model) bool {
        _ = self;
        return prefs.g_media_direct_fallback;
    }
    pub fn direct_fallback_explainer(self: *const Model) []const u8 {
        _ = self;
        return "Public proxies refuse whole domains by policy, and those pictures simply never appear. " ++
            "On, Plaza asks that one host itself, which lets that host see you. Off, the picture stays blank and nobody new learns anything.";
    }
    /// What the pause is set to, on its own button.
    pub fn post_delay_label(self: *const Model) []const u8 {
        _ = self;
        return switch (compose.g_post_delay_s) {
            0 => "Off",
            5 => "5s",
            10 => "10s",
            else => "5s",
        };
    }

    pub fn post_delay_explainer(self: *const Model) []const u8 {
        _ = self;
        return if (compose.g_post_delay_s == 0)
            "A note is signed and sent the moment you press Post."
        else
            "Post waits, and becomes Undo. Nothing is signed until it runs out, so taking it back leaves nothing behind. Once a note is out, it cannot be recalled.";
    }

    /// How many notes are still waiting for their first relay. Read once per
    /// build, because the publisher writes the queue from its own thread and the
    /// view must see one answer for the whole frame.
    pub fn outbox_label(self: *const Model, arena: std.mem.Allocator) []const u8 {
        // First, because it is the worst thing this zone can have to say: a note
        // the reader wrote that was never offered to anybody. `g_outbox_overflow`
        // was set for this and read nowhere, so the promise under the banner,
        // that anything you write is kept until a relay takes it, was quietly
        // untrue in the one case it was written for.
        if (self.outbox_overflowed) return "a note could not be queued";
        // A note that gave up is not "posting". Saying so would be the same lie
        // the queue was built to stop telling.
        if (self.outbox_pending == 0 and self.outbox_stuck > 0) {
            if (self.outbox_stuck == 1) return "1 note did not go out";
            return std.fmt.allocPrint(arena, "{d} notes did not go out", .{self.outbox_stuck}) catch "notes did not go out";
        }
        const n = self.outbox_pending;
        if (n == 1) return "posting 1 note…";
        return std.fmt.allocPrint(arena, "posting {d} notes…", .{n}) catch "posting…";
    }
    /// The app version line for the Settings footer.
    pub fn version_line(self: *const Model) []const u8 {
        _ = self;
        return "Plaza " ++ plaza_version;
    }

    /// The feed, iterated by `<for each="note_list">`, newest first.
    pub fn note_list(self: *const Model, arena: std.mem.Allocator) []const Note {
        _ = arena;
        return self.notes[0..self.notes_len];
    }
    pub fn has_notes(self: *const Model) bool {
        return self.notes_len > 0;
    }
    /// No notes yet, show the centered connecting/offline state (the message
    /// itself, `empty_text`, differentiates dialing from a dropped relay).
    pub fn empty(self: *const Model) bool {
        return self.notes_len == 0;
    }
    /// Header status line: how much of the relay pool is live.
    pub fn status(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.live_relays > 0)
            return std.fmt.allocPrint(arena, "Live · {d}/{d} relays", .{ self.live_relays, self.relay_count }) catch "Live";
        if (self.relay_count > 0 and self.offline_relays >= self.relay_count) return "Offline, reconnecting…";
        return "Connecting…";
    }
    pub fn empty_text(self: *const Model) []const u8 {
        // In a place, the pool is not what the reader is waiting on. Its relay
        // is deliberately outside the eight, so "Connecting to the relay pool"
        // under a place header describes a connection that has nothing to do
        // with the empty screen it is explaining, and says "connecting" about a
        // socket that may have failed a minute ago.
        if (places.g_place != null) {
            // What the place calls it, when it says. Only these three lines,
            // and only inside the room: see `Place.empty_line_buf`.
            const p = activePlace();
            return switch (placeLink()) {
                .idle, .connecting => if (p) |m| (if (m.loadingLine().len > 0) m.loadingLine() else "Connecting to this place…") else "Connecting to this place…",
                .unreachable_relay => if (p) |m| (if (m.lostLine().len > 0) m.lostLine() else "Can't reach this place. Retrying…") else "Can't reach this place. Retrying…",
                .connected => if (p) |m| (if (m.emptyLine().len > 0) m.emptyLine() else "Nothing here yet.") else "Nothing here yet.",
                .no_feed => "This place has no feed to read.",
            };
        }
        if (self.relay_count > 0 and self.offline_relays >= self.relay_count) return "Can't reach any relay. Retrying…";
        return "Connecting to the relay pool…";
    }
    /// Status-bar summary.
    pub fn footer(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notes_len == 0) return "";
        return std.fmt.allocPrint(arena, "{d} notes", .{self.notes_len}) catch "";
    }

    /// The status bar's left text, which doubles as the caught-up footer: there
    /// is no separate spinner, the feed renders from disk before the window
    /// finishes opening.
    pub fn caught_up(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const scope = self.scope_name();
        if (self.notes_len == 0) return scope;
        return std.fmt.allocPrint(arena, "Caught up · {s} · {d} notes", .{ lowerScope(scope), self.notes_len }) catch scope;
    }

    /// The status bar's relay health, drawn after the online dot.
    pub fn relay_health(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}/{d} relays", .{ self.live_relays, self.relay_count }) catch "relays";
    }

    /// Whether at least one relay is connected (drives the status dot color).
    pub fn relays_online(self: *const Model) bool {
        return self.live_relays > 0;
    }

    /// Whether the reader is browsing without an identity. Reading never
    /// needs one; the gated verbs ask at first intent.
    pub fn is_guest(self: *const Model) bool {
        _ = self;
        return activePubkey() == null;
    }

    /// Whether the guest join strip is showing (guest, and not dismissed).
    pub fn show_guest_strip(self: *const Model) bool {
        return self.is_guest() and !self.guest_strip_dismissed;
    }

    /// What the feed is scoped to. It stops being a hand-picked pack the moment
    /// the reader has a follow list of their own, and the line has to stop
    /// saying so: calling somebody's own follows "hand-picked" by this app is
    /// exactly the kind of small lie that makes a reader distrust the big
    /// statements too.
    pub fn scope_name(self: *const Model) []const u8 {
        _ = self;
        // Inside a place the feed is the place's, so saying "Following" is
        // simply false: those are not the reader's follows. It names the
        // place's own feed instead.
        if (places.g_place) |*m| {
            if (currentPlaceFeed(m)) |f| {
                if (f.name_len > 0) return f.name();
            }
            return "This place";
        }
        return if (homeReadsPack()) "Starter pack" else "Following";
    }

    /// The feed's scope line: how many voices it is scoped to, and whose choice
    /// that was.
    pub fn scope_voices(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        const shown = followSet().len;
        if (homeReadsPack()) {
            return std.fmt.allocPrint(arena, "{d} voices · hand-picked", .{shown}) catch "hand-picked";
        }
        // One number, because the feed reads the whole list. This used to state
        // two ("128 of 300 accounts") back when it read a slice, and that was
        // worth the clutter then: telling somebody who follows five hundred
        // people that they follow 128 is a lie about their own data.
        if (shown == 1) return "1 account · yours";
        return std.fmt.allocPrint(arena, "{d} accounts · yours", .{shown}) catch "yours";
    }

    /// The note with this id, if it is still in the feed or the open thread. A
    /// thread's root and replies are not in the feed window but are still
    /// pressable (like, image, open-as-thread), so they resolve here too.
    pub fn mentionsOff(self: *const Model) []const [32]u8 {
        return self.mentions_off[0..self.mentions_off_len];
    }

    pub fn noteById(self: *const Model, note_id: i64) ?*const Note {
        for (self.notes[0..self.notes_len]) |*note| {
            if (note.id == note_id) return note;
        }
        // A profile's rows live in the same buffer, so they resolve the same way.
        // Without this every press on a profile row (open, like, expand a
        // picture) is a silent no-op, which is worse than an inert control
        // because it looks live.
        if (self.viewing_thread != 0 or self.viewing_profile != null) {
            if (self.thread_root.id == note_id) return &self.thread_root;
            for (self.thread_notes[0..self.thread_notes_len]) |*note| {
                if (note.id == note_id) return note;
            }
        }
        return null;
    }

    /// Which level of the thread stack is on screen. Every per-level table is
    /// indexed by this, and it is clamped because the stack saturates at
    /// `thread_depth_max` by replacing its top rather than growing.
    pub fn currentLevel(self: *const Model) usize {
        return @min(self.thread_stack_len, thread_depth_max);
    }

    /// The open profile's notes, newest first, read from the local store. The
    /// same shape as the thread's refresh: the store is the app, so the screen
    /// fills from disk before any relay answers and the backfill only widens it.
    /// Whether ANY level is stacked over the feed. Was asked as
    /// `viewing_profile != null or viewing_thread != 0` in four places, which is
    /// a question that has to be updated in four places every time a third kind
    /// of level exists.
    pub fn levelOpen(self: *const Model) bool {
        return self.viewing_profile != null or self.viewing_thread != 0 or
            self.topic_len > 0 or self.viewing_bookmarks;
    }

    /// The bookmarked notes this machine actually holds, newest first.
    ///
    /// A bookmark whose note was never fetched is simply not shown. Drawing a
    /// row for an id with no event behind it would be a list of things the
    /// reader cannot read, and the honest answer is the ones that are here.
    pub fn refreshBookmarkNotes(self: *Model, now_s: i64) void {
        const store = g_store orelse return;
        var n: usize = 0;
        var i: usize = 0;
        const total = bookmarkCount();
        while (i < total and n < thread_reply_cap) : (i += 1) {
            const id = bookmarkAt(i) orelse continue;
            var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
            defer se.deinit();
            if (se.event.kind != 1) continue;
            self.thread_notes[n] = noteFrom(se.event, now_s);
            n += 1;
        }
        self.thread_notes_len = n;
    }

    pub fn viewingTopic(self: *const Model) ?[]const u8 {
        return if (self.topic_len == 0) null else self.topic_buf[0..self.topic_len];
    }

    /// Everything this reader already holds carrying that `t` tag, newest
    /// first. The store indexes tags, so this is one disk read and it answers
    /// before any relay is asked, which is the whole point of keeping a store.
    pub fn refreshTopicNotes(self: *Model, now_s: i64) void {
        const topic = self.viewingTopic() orelse return;
        const store = g_store orelse return;
        const values = [_][]const u8{topic};
        var tags: [1]nostr.filter.TagFilter = undefined;
        var result = store.query(std.heap.page_allocator, topicFilter(&values, &tags)) catch return;
        defer result.deinit();
        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= thread_reply_cap) break;
            // A tag is written under by strangers, and a muted one is hidden
            // here the way the feed and a thread hide them. Jumble's note list
            // does the same for its hashtag page
            // (src/components/NoteList/index.tsx:147).
            if (isMuted(ev.pubkey)) continue;
            self.thread_notes[n] = noteFrom(ev, now_s);
            // Queue the author's profile so a name and a face resolve for a
            // stranger, which is most of who writes under a tag.
            wantProfile(ev.pubkey);
            n += 1;
        }
        self.thread_notes_len = n;
    }

    /// Ends the topic's loading line. A topic is done waiting when something is
    /// on screen, when its fetch has asked every relay and come back, or when
    /// it has been long enough that a relay holding its EOSE back is no reason
    /// to keep the reader looking at a spinner. The same three exits a thread
    /// has. Without the last two a tag nobody has used was "looking" for ever.
    fn settleTopicLoading(self: *Model, now_s: i64) void {
        if (self.topic_len == 0 or !self.thread_loading) return;
        const done = navigation.g_thread_done_seq.load(.acquire) >= self.thread_seq;
        const timed_out = now_s - self.thread_open_at > thread_loading_grace_s;
        if (self.thread_notes_len > 0 or done or timed_out) self.thread_loading = false;
    }

    pub fn refreshProfileNotes(self: *Model, now_s: i64) void {
        const pk = self.viewing_profile orelse return;
        const store = g_store orelse return;
        // Comments too. A person who answers in the other vocabulary was
        // simply absent from their own profile, and the page looked like
        // somebody who had stopped writing rather than one this app could not
        // read.
        const kinds = [_]u16{ 1, comment_kind };
        const authors = [_][32]u8{pk};
        const want = @min(self.profile_limit, profile_notes_max);
        self.growLevelNotes(want);
        var result = store.query(std.heap.page_allocator, .{
            .authors = &authors,
            .kinds = &kinds,
            .limit = @intCast(@min(want, self.thread_notes.len)),
        }) catch return;
        defer result.deinit();

        // A note already on the page is carried over rather than parsed again.
        // This runs on the tick whenever the store moved, which is most ticks
        // while any relay is streaming, and a page paged down to its ceiling is
        // fifteen hundred notes: parsing every one each time put that whole cost
        // on the render thread once a second to produce the list already on
        // screen. The feed keeps its cards the same way (`buildReuseIndex`).
        //
        // A name landing changes only the notes that mention somebody, since
        // that label is the one thing baked into the text; those are parsed
        // again and the rest are kept.
        const names_same = feed_state.g_profile_notes_names == profile_cache.g_names_generation;
        feed_state.g_profile_notes_names = profile_cache.g_names_generation;
        const old = self.thread_notes[0..self.thread_notes_len];
        const slots = buildReuseIndex(old);
        const n = @min(result.events.len, self.thread_notes.len);
        // In place, oldest first. The page almost always gains notes, above
        // the ones it holds (newer) or below them (an older page), so a note
        // moves to the same index or a later one, and walking up from the
        // bottom writes each slot after the note that was in it has moved. When
        // one was removed and a note moves the other way, its slot may have
        // been written first; `heldIndex` compares the full id, finds nothing,
        // and the note is parsed.
        var i = n;
        while (i > 0) {
            i -= 1;
            const ev = result.events[i];
            if (heldIndex(slots, old, ev.id)) |at| {
                if (names_same or self.thread_notes[at].mentions.len == 0) {
                    if (at != i) self.thread_notes[i] = self.thread_notes[at];
                    continue;
                }
            }
            self.thread_notes[i] = noteFrom(ev, now_s);
            feed_state.g_profile_parses +%= 1;
        }
        self.thread_notes_len = n;
    }

    /// Moves the level's notes onto a buffer of at least `want`, keeping what is
    /// in them. A profile is the only level that asks for more than a thread's
    /// cap; every other one stays on the buffer it started with.
    ///
    /// Doubling, so paging down a long page is a handful of allocations. The
    /// buffer it leaves is freed, as the feed's is: there is one model and it
    /// moves with the buffer. A `Note` is several kilobytes, so the 200, 400 and
    /// 800 note buffers a page grows through would otherwise stay behind as
    /// megabytes nothing reads. The first buffer is static and stays.
    fn growLevelNotes(self: *Model, want: usize) void {
        if (self.thread_notes.len >= want) return;
        if (feed_state.g_level_notes.len >= want) {
            if (self.thread_notes.ptr != feed_state.g_level_notes.ptr) {
                const held = @min(self.thread_notes_len, self.thread_notes.len);
                @memcpy(feed_state.g_level_notes[0..held], self.thread_notes[0..held]);
            }
            self.thread_notes = feed_state.g_level_notes;
            return;
        }
        var next = @max(feed_state.g_level_notes.len, thread_reply_cap);
        while (next < want) next *|= 2;
        const grown = std.heap.page_allocator.alloc(Note, next) catch return;
        const keep = @min(self.thread_notes_len, self.thread_notes.len);
        @memcpy(grown[0..keep], self.thread_notes[0..keep]);
        for (grown[keep..]) |*note| note.* = .{};
        if (feed_state.g_level_notes.ptr != @as([*]Note, &feed_state.g_level_boot)) std.heap.page_allocator.free(feed_state.g_level_notes);
        feed_state.g_level_notes = grown;
        self.thread_notes = grown;
    }

    /// Which of the profile's two tabs a note belongs to. "Notes" is what they
    /// wrote; "Replies" is what they wrote at somebody. A tab that mixed them
    /// would be a tab that lies about what it holds.
    pub fn profileNotesFor(self: *const Model, out: []usize, pubkey: [32]u8) []const usize {
        var n: usize = 0;
        // Only THIS person's notes. `thread_notes` is one buffer shared with the
        // thread screen, so a stacked level that is not the one being read holds
        // somebody else's rows, and counting those would give the retained list
        // a length that does not match what it draws.
        for (self.thread_notes[0..self.thread_notes_len], 0..) |note, i| {
            if (n >= out.len) break;
            if (!std.mem.eql(u8, &note.pubkey, &pubkey)) continue;
            const is_reply = note.has_reply_parent;
            if ((self.profile_tab == .replies) != is_reply) continue;
            out[n] = i;
            n += 1;
        }
        return out[0..n];
    }

    /// Rebuilds the open thread's replies from the store: every kind:1 that
    /// e-tags the root, oldest first, into the `thread_notes` cache. Local-first,
    /// the same path the feed uses; cheap enough to run each tick so
    /// late-arriving replies appear and relative times stay fresh.
    pub fn refreshThreadNotes(self: *Model, now_s: i64) void {
        if (self.viewing_thread == 0) return;
        const store = g_store orelse return;
        // The whole subtree, not just the direct children: the closure walk is
        // what keeps a SUB-thread's deep replies visible (they tag the true
        // root and their direct parent, never a mid-thread note).
        var ids: [thread_reply_cap][32]u8 = undefined;
        const id_count = collectThreadIds(store, self.thread_root.event_id, &ids);

        var n: usize = 0;
        for (ids[0..id_count]) |id| {
            if (n >= thread_reply_cap) break;
            var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
            defer se.deinit();
            // A muted person's reply is hidden the same way their note is. The
            // thread's ROOT is not checked: opening a thread is asking to read
            // that note, and answering with an empty screen would be the app
            // refusing a question the reader just asked.
            if (isMuted(se.event.pubkey)) continue;
            self.thread_notes[n] = noteFrom(se.event, now_s);
            // Queue the replier's profile so a name, avatar, and handle resolve
            // for a reply from someone outside the follow set.
            wantProfile(se.event.pubkey);
            n += 1;
        }
        // Whether this thread's own fetch has asked every relay and come back, or
        // given up waiting on one that never sends its EOSE. Until then the
        // replies are still streaming in and belong to one batch.
        const settled = self.threadFetchSettled(now_s);
        stampArrival(arrivalTableFor(self.thread_stack_len, self.thread_root.event_id), self.thread_notes[0..n], settled);
        // In reading order, so seat each reply under the note it answers.
        arrangeThread(self.thread_notes[0..n], self.thread_root.event_id);
        self.thread_notes_len = n;
        self.settleThreadLoading(now_s);
    }

    /// Whether the open thread's own fetch has asked every relay and come back,
    /// or been given up on after `thread_loading_grace_s` for a relay that never
    /// sends its EOSE.
    fn threadFetchSettled(self: *const Model, now_s: i64) bool {
        const done = navigation.g_thread_done_seq.load(.acquire) == self.thread_seq;
        const timed_out = now_s - self.thread_open_at > thread_loading_grace_s;
        return done or timed_out;
    }

    /// Stops the loading skeletons once replies are in hand, or once the fetch is
    /// done or timed out, so a note that simply has no replies resolves to
    /// "No replies yet" rather than stalling under skeletons. Runs every tick,
    /// not only when the store moved: a quiet relay and an unchanged store is
    /// exactly the case where the answer is "there is nothing", and nothing
    /// changing is what would otherwise never let the skeletons retire.
    fn settleThreadLoading(self: *Model, now_s: i64) void {
        if (!self.thread_loading) return;
        if (self.thread_notes_len > 0 or self.threadFetchSettled(now_s)) self.thread_loading = false;
    }

    /// The reply count for the thread breadcrumb: the crowd count the feed's
    /// engagement subscription already knows (so it reads right the instant a
    /// thread opens, before the replies are fetched), or the fetched count once
    /// that is higher.
    fn threadReplyCount(self: *const Model) usize {
        const crowd: usize = engagementFor(self.thread_root.id).replies;
        return @max(crowd, self.thread_notes_len);
    }

    /// The span of notes at or near the viewport, which is what gets pictures.
    /// Card heights vary, so this estimates from the average (total content over
    /// note count) and pads generously; being a row or two wide only costs a
    /// prefetch. Before the first scroll event it reports the top of the feed.
    pub fn visibleRange(self: *const Model) RowRange {
        if (self.notes_len == 0) return .{ .first = 0, .last = 0 };
        // The windowed list reports the exact rows it put on screen, so this is
        // no longer an estimate. Before the first build it reports the top.
        const last_row = self.notes_len - 1;
        if (feed_media.g_visible_last == 0 and feed_media.g_visible_first == 0) {
            return .{ .first = 0, .last = @min(last_row, max_media_images - 1) };
        }
        return .{ .first = @min(feed_media.g_visible_first, last_row), .last = @min(feed_media.g_visible_last, last_row) };
    }

    /// The rows to have READY, which is wider than the rows on screen.
    ///
    /// A face or a picture is fetched only for a row the viewport already holds,
    /// so scrolling meant watching them arrive: the row lands blank, asks the
    /// network, and fills in a moment later, over and over, for as long as you
    /// keep moving. The bytes are what take time, and nothing about fetching them
    /// requires the row to be visible.
    ///
    /// So a band either side of the viewport is warmed into the disk cache
    /// ahead of arriving. Either side on purpose: scrolling back up is as common
    /// as scrolling down, and a cache that only ever looks forward makes the way
    /// back feel broken in a way the way down does not.
    pub fn prefetchRange(self: *const Model) RowRange {
        const w = self.visibleRange();
        if (self.notes_len == 0) return w;
        const last_row = self.notes_len - 1;
        return .{
            .first = w.first -| feed_prefetch_rows,
            .last = @min(last_row, w.last + feed_prefetch_rows),
        };
    }

    /// Reconciles the feed with the store. Updates the connection line every
    /// tick; re-queries and rebuilds the note cards only when the store's event
    /// count changed since the last rebuild; and re-computes relative times for
    /// the notes on screen. `now_s` is the current wall-clock second.
    fn refresh(self: *Model, now_s: i64) void {
        var live: usize = 0;
        var offline: usize = 0;
        // Only slots that hold a relay: a dormant slot's status is whatever it
        // was when its relay was removed, and counting it would report the app
        // offline from a relay the reader deleted.
        for (0..relaySlots()) |i| {
            if (relayAt(i) == null) continue;
            switch (@as(Conn, @enumFromInt(relay_conn.g_relay_status[i].load(.acquire)))) {
                // A quiet relay still holds its socket and nothing has failed,
                // so it counts as live here. Saying otherwise would put the app
                // behind an "offline, reconnecting" banner on a slow night.
                .connected, .quiet => live += 1,
                .offline => offline += 1,
                .connecting => {},
            }
        }
        self.live_relays = live;
        self.offline_relays = offline;
        // Sampled together, so a frame never mixes a fresh numerator with a
        // stale denominator and reads "4/3 relays".
        self.relay_count = relayCount();

        // A relay came up, or the pool changed size: whatever could not be found
        // a moment ago may be findable now, so everything still unresolved goes
        // back in the queue immediately rather than waiting out its backoff. This
        // is the case that produced the report: three tries spent while nothing
        // was connected wrote a note off, and nothing ever asked again.
        if (live != quote_cache.g_last_live_relays or self.relay_count != quote_cache.g_last_relay_count) {
            quote_cache.g_last_live_relays = live;
            quote_cache.g_last_relay_count = self.relay_count;
            requeueMissingQuotes();
        }

        const store = g_store orelse return;

        const count = store.eventCount() catch return;
        // Three ways the view can be behind the store. The count catches
        // anything landing by any route; the other two are the feed's own, and
        // either can be true on a tick where the count has not moved (a
        // deletion cancels an insert, or nothing was stored at all and the
        // reader simply changed who they follow).
        // A place's notes arrive on its own socket and go into the store like
        // anything else, so for a place the reader has never seen this fires on
        // the count alone. For one they HAVE seen it does not: every note is
        // already stored, the ingest is a duplicate, the count does not move,
        // and nothing below ever runs. That is a room that sits on "Connecting"
        // forever while its relay is connected and answering.
        //
        // `rebuildNotes` already treats this counter as a reason to rebuild.
        // The bug was one level up: it never got the chance, because deciding
        // whether to call it at all did not know about places.
        const place_rev = places.g_place_rev.load(.monotonic);
        const stale = count != g_last_count or
            feed_state.g_arrival_pending.load(.acquire) or
            feed_state.g_feed_rebuild_all.load(.acquire) or
            place_rev != feed_state.g_notes_place_rev or
            self.feed_limit != feed_state.g_notes_feed_limit;
        if (stale) {
            g_last_count = count;
            // Profiles first, so a note's mentions resolve to names as it builds.
            refreshProfiles(store);
            rebuildNotes(self, store, now_s);
            // A grown store may hold quoted events the feed references now.
            refreshQuotes(store);
        }
        // Off the store-changed guard, on its own flag: a relay list is rare
        // and the ranking reads every one of them, so it runs when one lands
        // and not once a second because a reaction did. And not on the tick the
        // list lands either, because they land in flurries.
        maybeRankRelaySuggestions(store);
        for (self.notes[0..self.notes_len]) |*note| note.setTime(now_s);
    }

    fn rebuildNotes(self: *Model, store: *nostr.store.Store, now_s: i64) void {
        // Whatever the feed ends up holding, the relays get told about it. On
        // every path out of here, including the two that return early.
        defer publishFeedWatch(self.notes[0..self.notes_len]);
        // Notes and the two repost kinds. `rebuildNotesFromStore` reads one
        // query per kind for the reason given there, so this list costs three
        // cursors per author rather than multiplying into one query the store
        // would refuse to index.
        const kinds = [_]u16{ 1, repost_kind, generic_repost_kind };
        // Scope the feed to the follow set (the starter pack) plus the user's own
        // notes, so it reads as a real follow feed, not a firehose. Filtering
        // here (not just at the subscription) also hides notes an earlier,
        // unscoped run may have left in the store.
        var authors: [max_follows + 1][32]u8 = undefined;
        var authors_len: usize = 0;
        for (followSet()) |pk| {
            if (authors_len >= max_follows) break;
            authors[authors_len] = pk;
            authors_len += 1;
        }
        if (activePubkey()) |pk| {
            authors[authors_len] = pk;
            authors_len += 1;
        }
        // Only as much as the reader has paged into, so the rebuild cost stays
        // flat until they actually ask for more.
        // No ceiling. The reader asked for this many, so the storage grows to
        // hold them and the query asks for exactly that.
        const limit = @min(self.feed_limit, ensureFeedCapacity(self.feed_limit));
        // After a growth the old slice is freed, so re-point before using it.
        self.notes = feed_state.g_feed_notes;

        // Mention labels are baked into content at parse time, so a new display
        // name (the generation) forces one full parse pass to refresh them.
        const reuse_ok = profile_cache.g_names_generation == g_notes_names_generation;
        g_notes_names_generation = profile_cache.g_names_generation;

        // Always, and before deciding anything: whatever is waiting is either
        // spliced now or covered by the full read below, and leaving it in the
        // buffer would splice it a second time on the next tick.
        const arrived = takeFeedArrivals();

        // What the list in hand cannot be brought up to date FROM. Everything
        // else is an addition, and an addition is a merge.
        //
        //   the flag       the author set changed, the reader signed in or out,
        //                  or a deletion landed
        //   lost           more arrived between two ticks than the buffer holds
        //   !reuse_ok      a name moved, so every card's baked text is stale
        //   limit moved    the reader paged down, so notes below the old window
        //                  belong now and no arrival describes them
        // A place's notes arrive on its own socket, not through the ingest
        // buffer the splice path drains, so nothing in `arrived` ever describes
        // them. Its revision counter is what says there is something new, and
        // `refresh` consults the same counter before it gets here.
        const place_rev = places.g_place_rev.load(.monotonic);
        const place_moved = place_rev != feed_state.g_notes_place_rev;
        feed_state.g_notes_place_rev = place_rev;

        const full = feed_state.g_feed_rebuild_all.swap(false, .acq_rel) or
            place_moved or
            arrived.lost or
            !reuse_ok or
            limit != feed_state.g_notes_limit or
            self.feed_limit != feed_state.g_notes_feed_limit;
        feed_state.g_notes_limit = limit;
        feed_state.g_notes_feed_limit = self.feed_limit;

        if (full) {
            // In a place, the feed IS the place. Not your follows with a
            // header on top, which is what a lens would be and is exactly the
            // thing the room decision rejected.
            if (places.g_place != null) {
                self.rebuildNotesFromPlace(store, now_s, limit, reuse_ok);
            } else {
                self.rebuildNotesFromStore(store, now_s, authors[0..authors_len], &kinds, limit, reuse_ok);
            }
            return;
        }
        if (arrived.n == 0) return;
        self.spliceArrivals(store, now_s, authors[0..authors_len], &kinds, limit, arrived.n);
    }

    /// Reads the whole window back from the store: a cursor per followed author
    /// and a linear pick across all of them, per note returned. The expensive
    /// one, and the reason for everything above it.
    /// The same rebuild, reading the ids the place's relay sent rather than a
    /// set of authors. Shares `noteFrom`, the reuse index and the mute filter,
    /// because a note in a place is a note.
    fn rebuildNotesFromPlace(
        self: *Model,
        store: *nostr.store.Store,
        now_s: i64,
        limit: usize,
        reuse_ok: bool,
    ) void {
        var ids: [place_feed_cap][32]u8 = undefined;
        var ids_len: usize = 0;
        {
            lockPlaceIds();
            defer unlockPlaceIds();
            ids_len = places.g_place_ids_len;
            @memcpy(ids[0..ids_len], places.g_place_ids[0..ids_len]);
        }
        if (ids_len == 0) {
            self.notes_len = 0;
            return;
        }

        var result = store.query(std.heap.page_allocator, .{
            .ids = ids[0..ids_len],
            .limit = @intCast(limit),
        }) catch return;
        defer result.deinit();
        feed_state.g_feed_work.full_reads += 1;

        const old = feed_state.g_feed_scratch;
        const old_len = self.notes_len;
        @memcpy(old[0..old_len], self.notes[0..old_len]);
        const slots = if (reuse_ok) buildReuseIndex(old[0..old_len]) else &.{};

        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= limit) break;
            // The reader's own mutes still apply inside a place. So what they
            // see is not exactly what the host published, and that is the right
            // way round: a host cannot un-mute somebody for you.
            if (isMuted(ev.pubkey)) continue;
            self.notes[n] = blk: {
                if (heldIndex(slots, old[0..old_len], ev.id)) |at| break :blk old[at];
                feed_state.g_feed_work.parses += 1;
                break :blk noteFrom(ev, now_s);
            };
            n += 1;
        }
        self.notes_len = n;
    }

    fn rebuildNotesFromStore(
        self: *Model,
        store: *nostr.store.Store,
        now_s: i64,
        authors: []const [32]u8,
        kinds: []const u16,
        limit: usize,
        reuse_ok: bool,
    ) void {
        // ONE QUERY PER KIND, merged here, rather than one query naming them all.
        //
        // The store picks its index on the product of authors and kinds: at or
        // under `max_merge_streams` (4096) it opens a cursor per author-kind
        // pair on `idx_author_kind`; over it, it drops to the plain author index
        // and pays a decode for every event those authors ever wrote. A full
        // follow list is 2049 authors, so one kind fits with room to spare and
        // two do not: 4098 pairs misses the cap by two, and the feed would
        // quietly become a full scan of everything two thousand people have
        // ever posted.
        //
        // Splitting by kind means the product is always authors times one,
        // whatever this list grows to. It is robust by construction rather than
        // correct up to a follow count nobody is watching, and it holds fewer
        // cursors open at once than the single query did. The events of one kind
        // come back newest-first, so merging them is a pick across `kinds.len`
        // cursors, which is the same thing the store does internally with three
        // streams instead of six thousand.
        var results: [feed_kind_cap]nostr.store.QueryResult = undefined;
        var results_len: usize = 0;
        defer for (results[0..results_len]) |*r| r.deinit();
        for (kinds) |kd| {
            if (results_len >= results.len) break;
            const one = [_]u16{kd};
            results[results_len] = store.query(std.heap.page_allocator, .{
                .authors = authors,
                .kinds = &one,
                .limit = @intCast(limit),
                // `return`, not `continue`. A failed read used to abandon the
                // whole rebuild and leave the feed as it was; skipping one kind
                // instead would silently show a feed missing everything of that
                // kind, which looks like an empty day rather than a failure.
                // The defer above frees whatever was opened before this.
            }) catch return;
            results_len += 1;
        }
        feed_state.g_feed_work.full_reads += 1;

        // Where each kind's result has been read up to.
        var cursors = [_]usize{0} ** feed_kind_cap;
        // What this pass has already placed, for the repost dedup below.
        const placed = placedReset(limit);

        // The old cards, so new positions can take them over by id.
        const old = feed_state.g_feed_scratch;
        const old_len = self.notes_len;
        @memcpy(old[0..old_len], self.notes[0..old_len]);
        const slots = if (reuse_ok) buildReuseIndex(old[0..old_len]) else &.{};

        var n: usize = 0;
        while (n < limit) {
            // The newest unread event across the per-kind results. Linear over
            // `kinds.len`, which is three.
            var best: ?usize = null;
            for (results[0..results_len], 0..) |r, i| {
                if (cursors[i] >= r.events.len) continue;
                if (best == null or
                    eventNewer(r.events[cursors[i]], results[best.?].events[cursors[best.?]])) best = i;
            }
            const bi = best orelse break;
            const ev = results[bi].events[cursors[bi]];
            cursors[bi] += 1;

            // A muted author never becomes a card. Filtered here rather than in
            // the query because the store has no idea who this reader muted, and
            // rather than at render time because a hidden row would still hold a
            // slot in a window that pages by count.
            if (isMuted(ev.pubkey)) continue;
            // A repost becomes the note it points at, so what is placed, reused
            // and deduped below is the REPOSTED note and not the wrapper.
            const card = feedCardFrom(store, ev, now_s) orelse continue;
            // One row per reposted note. Two follows passing the same note on is
            // one card, and a repost of something the window already holds does
            // not draw it twice. All four reference clients key this on the
            // reposted note; Amethyst's is `distinctBy { replyTo.last().idHex }`
            // with the comment "only the most recent repost per feed", and
            // reading newest-first is what makes the first one seen the keeper.
            if (placedTake(placed, self.notes[0..n], card.event_id, n)) continue;
            self.notes[n] = blk: {
                if (heldIndex(slots, old[0..old_len], card.event_id)) |at| {
                    var held = old[at];
                    // A held card may have been drawn plain before, or passed on
                    // by somebody else. The wrapper in hand is the newest one
                    // that named it, so the byline comes from this pass.
                    held.reposter = card.reposter;
                    held.has_reposter = card.has_reposter;
                    break :blk held;
                }
                feed_state.g_feed_work.parses += 1;
                break :blk card;
            };
            n += 1;
        }
        self.notes_len = n;
    }

    /// Merges the notes that just landed into the list already on screen.
    ///
    /// The ids come from the ingest threads, so the store is asked for exactly
    /// those and nothing else: a direct read per id, no cursor per follow and no
    /// pick across two thousand streams. Everything already held is carried over
    /// as it is, so no card is re-parsed and no picture is re-fetched.
    fn spliceArrivals(
        self: *Model,
        store: *nostr.store.Store,
        now_s: i64,
        authors: []const [32]u8,
        kinds: []const u16,
        limit: usize,
        arrived: usize,
    ) void {
        var result = store.query(std.heap.page_allocator, .{
            .ids = feed_state.g_arrival_taken[0..arrived],
            .kinds = kinds,
        }) catch {
            // The ids are gone with the buffer, so the only honest recovery is
            // to read the window back next tick.
            invalidateFeed();
            return;
        };
        defer result.deinit();
        feed_state.g_feed_work.splices += 1;
        if (result.events.len == 0) return;

        // Which of them this feed is actually about. The store was asked by id,
        // not by author, on purpose: an author list is checked one name at a
        // time, and asking about a handful of arrivals should not walk two
        // thousand follows per arrival. Only the ones that are NOT already held
        // pay that walk, and those are few.
        const held = buildReuseIndex(self.notes[0..self.notes_len]);
        var keep: usize = 0;
        for (result.events, 0..) |ev, i| {
            if (keep >= feed_state.g_splice_keep.len) break;
            if (ev.kind != 1) continue;
            if (heldIndex(held, self.notes[0..self.notes_len], ev.id) != null) continue;
            if (!authorInSet(authors, ev.pubkey)) continue;
            if (isMuted(ev.pubkey)) continue;
            // The window is full and this is older than everything in it, so it
            // would be dropped by the truncation below. Not worth parsing.
            if (self.notes_len >= limit and self.notes_len > 0 and
                !eventNewerThanNote(ev, self.notes[self.notes_len - 1])) continue;
            feed_state.g_splice_keep[keep] = @intCast(i);
            keep += 1;
        }
        if (keep == 0) return;

        // Two sorted runs into one. `result.events` is newest-first (the store
        // sorts it) and so is the list on screen, so this is one pass with no
        // sort and no search. Through the scratch copy rather than in place: an
        // in-place merge is only safe in one direction, and which direction
        // depends on whether the window is growing or already full.
        const old = feed_state.g_feed_scratch;
        const old_len = self.notes_len;
        @memcpy(old[0..old_len], self.notes[0..old_len]);

        const total = @min(old_len + keep, limit);
        var oi: usize = 0;
        var fi: usize = 0;
        for (0..total) |n| {
            const take_new = blk: {
                if (fi >= keep) break :blk false;
                if (oi >= old_len) break :blk true;
                break :blk eventNewerThanNote(result.events[feed_state.g_splice_keep[fi]], old[oi]);
            };
            if (take_new) {
                self.notes[n] = noteFrom(result.events[feed_state.g_splice_keep[fi]], now_s);
                feed_state.g_feed_work.parses += 1;
                fi += 1;
            } else {
                self.notes[n] = old[oi];
                oi += 1;
            }
        }
        self.notes_len = total;
    }
};

pub fn setIdentityForTest(secret: [32]u8) void {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    feed_state.g_test_secret = secret;
    adoptHelperIdentity(kp.public_key);
}

/// Clears the active identity again. For tests.
pub fn clearIdentityForTest() void {
    follows.g_home_scope = .following;
    keyholder.g_identity_npub_len = 0;
    keyholder.g_signer_kind = .helper;
    feed_state.g_test_secret = null;
    keyholder.g_helper_has_identity = false;
}

/// Forces the next reconcile to do the full work rather than take the
/// unchanged-store fast path, so a benchmark measures a rebuild.
pub fn invalidateFeedForTest() void {
    invalidateFeed();
}

/// Reconciles profiles and notes against `store` directly, bypassing change
/// detection entirely. For tests that drive the store themselves rather than
/// through `plazaIngest`, which is where an arrival announces itself: without
/// the announcement there is nothing to splice, so this asks for the full read.
///
/// Tests of the change-detection layer itself go through `plazaIngestForTest`
/// and `Model.refresh`, which is what the app runs.
/// Rebuilds the open thread's replies from the store. The real one runs off the
/// tick, which a test has no way to turn.
pub fn refreshThreadNotesForTest(model: *Model, now_s: i64) void {
    model.refreshThreadNotes(now_s);
}

pub fn reconcileForTest(model: *Model, store: *nostr.store.Store, now_s: i64) void {
    invalidateFeed();
    refreshProfiles(store);
    model.rebuildNotes(store, now_s);
}

/// A tick as the app actually takes one, including the gate that decides
/// whether the feed is rebuilt AT ALL.
///
/// `reconcileForTest` goes straight to `rebuildNotes` and invalidates on the
/// way in, so every test using it rebuilds unconditionally. That is the right
/// tool for asking what a rebuild produces, and it is why a place could sit on
/// "Connecting" forever with nothing red: the decision NOT to rebuild is the
/// part it skips.
pub fn refreshForTest(model: *Model, store: *nostr.store.Store, now_s: i64) void {
    setStoreForTest(store);
    model.refresh(now_s);
}

/// One tick, exactly as the app's timer runs it: change detection and all. The
/// entry point for tests of how the feed decides what to do, as opposed to what
/// a rebuild produces.
pub fn tickForTest(model: *Model, now_s: i64) void {
    model.refresh(now_s);
}

/// The open thread's or profile's share of a tick, on its own.
pub fn tickOpenLevelForTest(model: *Model, now_s: i64) void {
    refreshOpenLevel(model, now_s);
}

/// Marks a thread's reply fetch as finished, the way its worker does.
pub fn markThreadFetchDoneForTest(seq: u64) void {
    navigation.g_thread_done_seq.store(seq, .release);
}

/// Empties the arrival buffer and asks for a full read next time, so a test
/// starts from a known place rather than from whatever the last one left.
pub fn resetFeedChangeDetectionForTest() void {
    clearFeedArrivals();
    invalidateFeed();
    feed_state.g_notes_limit = 0;
    feed_state.g_notes_feed_limit = 0;
    g_last_count = std.math.maxInt(usize);
}

/// Announces an id as newly arrived without storing anything. For the case the
/// app is not supposed to produce and the splice guards against anyway.
pub fn noteFeedArrivalForTest(id: [32]u8) void {
    noteFeedArrival(id);
}

/// Fills the arrival buffer past its capacity, the way a backfill does.
pub fn overflowFeedArrivalsForTest() void {
    for (0..feed_arrival_cap + 1) |i| {
        var id = [_]u8{0} ** 32;
        std.mem.writeInt(u64, id[0..8], i, .big);
        noteFeedArrival(id);
    }
}

pub fn profileParsesForTest() usize {
    return feed_state.g_profile_parses;
}

/// The refresh the tick runs when the store moved.
pub fn refreshProfileNotesForTest(model: *Model) void {
    model.refreshProfileNotes(nowSeconds());
}

/// Makes room for `n` notes and re-points `model` at the grown buffer. For tests
/// that fill the feed by hand rather than through the store: the app grows on
/// its way through `rebuildNotes`, and writing past the end without that is the
/// out-of-bounds it should be.
/// One more page, the way the reader's scroll asks for it. For tests, so they
/// page down through the real path rather than setting the limit by hand.
pub fn loadOlderForTest(model: *Model) void {
    model.feed_limit += feed_page;
}

pub fn reserveFeedForTest(model: *Model, n: usize) void {
    _ = ensureFeedCapacity(n);
    model.notes = feed_state.g_feed_notes;
}
// The names generation the current cards were parsed under (see
// `g_names_generation`).
var g_notes_names_generation: u64 = 0;

/// True when the well-known JSON maps the identifier's name to `pubkey`. This is
/// the whole trust test: a check is drawn on this and nothing weaker.
// --------------------------------------------------------------- the update
//
// Whoever installed Plaza is otherwise on that build until they happen to visit
// the site, which makes shipping a fix worth less than it should be.
//
// TOLD, not done. Plaza is ad-hoc signed and installed by a script that clears
// quarantine, and it is not going to replace its own bundle while running. A
// line saying a newer version exists, with one press to go and get it, is the
// honest amount of automation for how this app is distributed. The toolkit does
// ship a signed self-updater; it swaps the bundle and relaunches, it is macOS
// only while Plaza also ships Linux, and it wants a signed feed hosted
// somewhere. All three are reasons this does not use it.
//
// The releases API, because that is the same document `scripts/install-macos.sh`
// already reads. One source of truth for what the newest release is, rather than
// a second one to keep in step.

pub fn updateNewsForTest(body: []const u8) void {
    handleUpdateChecked(.{ .key = update_check_key, .outcome = .ok, .status = 200, .body = body, .truncated = false, .dropped_before = 0 });
}

pub fn resetUpdateStateForTest() void {
    updates.g_update_check = true;
    updates.g_update_version_len = 0;
    updates.g_update_url_len = 0;
    updates.g_update_asking = false;
    updates.g_update_dismissed = false;
    updates.g_update_next_at_ms = 0;
}

// --------------------------------------------------------------- image decode
//
// The canvas image registry decodes through the platform codec and refuses
// anything over 512x512, with no downscaler of its own. Most real avatars and
// nearly every feed photo are larger than that, so Plaza decodes and resizes
// them itself: the platform decoder is tried first (it knows every format the
// OS does, WebP and HEIC included), and stb takes over when it refuses.

/// Whether the vendored decoder can read `bytes` at all. Test seam: what makes
/// the platform fallback in `decodeAndRegister` load-bearing is precisely which
/// formats stb was NOT built for.
pub fn stbCanDecodeForTest(bytes: []const u8) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return false;
    stbi_image_free(px);
    return true;
}

pub fn avatarUrlForTest(buf: []u8, src: []const u8, direct: bool) []const u8 {
    return avatarUrl(buf, src, direct);
}

pub fn feedImageUrlForTest(buf: []u8, src: []const u8) []const u8 {
    return feedImageUrl(buf, src);
}

pub const feed_prefetch_rows_for_test = feed_prefetch_rows;
pub const gif_target_px_for_test = gif_target_px;
pub const media_target_px_for_test = media_target_px;

pub fn mediaUrlForTest(buf: []u8, src: []const u8, px: u32, fit: MediaFit) []const u8 {
    return mediaUrl(buf, src, px, fit);
}

/// The address warming asks for, so a test can hold it against the one the row
/// will look up. They are built in two places and must not drift.
pub fn setVisibleRangeForTest(first: usize, last: usize) void {
    feed_media.g_visible_first = first;
    feed_media.g_visible_last = last;
}

// ---------------------------------------------------------------- feed media
//
// Feed images take the image ids the avatars do not, through a small LRU keyed
// by note. Only the top of the feed loads for now: that is what the budget
// holds and what is on screen at rest. Windowed visibility (load exactly what
// is in view, evict what leaves) arrives with the virtual list.

/// Clears the media cache. For tests, which share the process globals.
/// Whether the slot for `note_id` was marked wanted by the most recent pass.
/// This is the thing the claim pass reads to decide what it may evict, so it is
/// the thing a test about "which pictures the level is spending its slots on"
/// has to ask about.
pub fn mediaSlotWantedForTest(note_id: i64) ?bool {
    const m = mediaSlotFor(note_id) orelse return null;
    return m.last_used == profile_cache.g_image_clock;
}

pub fn scanMediaFetchesForTest(fx: *Effects, model: *const Model) void {
    scanMediaFetches(fx, model);
}

pub fn warmAheadForTest(fx: *Effects, model: *const Model) void {
    warmAhead(fx, model);
}

/// Whether warming has asked for this picture address, the way `warmPicture`
/// builds it.
pub fn pictureWarmedForTest(src: []const u8) bool {
    var url_buf: [1024]u8 = undefined;
    return warmedAlready(feedImageUrl(&url_buf, src));
}

pub fn resetWarmForTest() void {
    image_pool.g_warm_ring = [_]WarmEntry{.{}} ** warm_ring_len;
    image_pool.g_warm_ring_next = 0;
}

pub fn scanLinkFetchesForTest(fx: *Effects, model: *const Model) void {
    scanLinkFetches(fx, model);
}

/// Whether the page behind `url` has been asked for (or is being).
pub fn linkRequestedForTest(url: []const u8) bool {
    const l = linkFor(url) orelse return false;
    return l.state == .fetching or l.attempts > 0;
}

/// Pretends a build put exactly these notes on screen in the front level.
pub fn recordVisibleNotesForTest(ids: []const i64) void {
    const set = &g_level_visible[0];
    set.reset();
    g_visible_level = 0;
    for (ids) |id| set.pushNote(id);
}

/// How many picture slots are currently held, and by which notes.
pub fn mediaSlotNoteIdsForTest(out: []i64) usize {
    var n: usize = 0;
    for (&feed_media.g_media) |*m| {
        if (!m.used or n == out.len) continue;
        out[n] = m.note_id;
        n += 1;
    }
    return n;
}

pub fn maxMediaImagesForTest() usize {
    return max_media_images;
}

pub const quote_picture_width_for_test = quote_picture_width;

/// Whether the pool could take this id back right now: held, and neither on
/// screen this pass nor mid-fetch.
pub fn imageIdTakeableForTest(id: u64) bool {
    if (id < 1 or id > image_registry_slots) return false;
    const owners = imageIdOwners();
    return imageIdSeen(owners[@intCast(id)]) != null;
}

pub fn resetMediaForTest() void {
    for (&feed_media.g_media) |*m| m.down.release();
    feed_media.g_media = [_]MediaSlot{.{}} ** max_media_images;
    profile_cache.g_image_clock = 0;
}

/// How many slots are holding a half-assembled picture. Zero at rest: a slice
/// buffer belongs to one fetch and dies with it.
pub fn mediaPartialCountForTest() usize {
    var n: usize = 0;
    for (&feed_media.g_media) |*m| {
        if (m.down.buf != null) n += 1;
    }
    return n;
}

pub fn mediaKeyForTest(note_id: i64, index: usize) i64 {
    return mediaKey(note_id, index);
}

pub fn markMediaFailedForTest(slot: *MediaSlot) void {
    slot.state = .failed;
}

pub fn mediaAttemptsForTest(note_id: i64) ?u8 {
    const m = mediaSlotFor(note_id) orelse return null;
    return m.attempts;
}

/// The host a slot's picture lives on, which `fireMediaAt` normally sets from
/// the note. A test that drives the response handler directly never went
/// through it.
pub fn setMediaSlotHostForTest(note_id: i64, host: []const u8) void {
    const m = mediaSlotFor(note_id) orelse return;
    const n = @min(host.len, m.host_buf.len);
    @memcpy(m.host_buf[0..n], host[0..n]);
    m.host_len = @intCast(n);
}

pub fn mediaIdleForTest(note_id: i64) bool {
    const m = mediaSlotFor(note_id) orelse return false;
    return m.state == .idle;
}

/// Whether this note's picture is now pinned to its own host rather than the
/// proxy, and whether it will be asked for again.
pub fn mediaFallbackStateForTest(note_id: i64) ?struct { idle: bool, direct: bool } {
    const m = mediaSlotFor(note_id) orelse return null;
    return .{ .idle = m.state == .idle, .direct = m.direct };
}

/// Delivers one picture-fetch response for `note_id` the way the runtime would,
/// so a test can drive the failure paths rather than the classifier alone.
/// How many faces are holding a half-assembled picture. Zero at rest.
pub fn avatarPartialCountForTest() usize {
    var n: usize = 0;
    for (&profile_cache.g_profiles) |*p| {
        if (p.used and p.down.buf != null) n += 1;
    }
    return n;
}

/// Feeds one delivered slice to a profile's face, exactly as a 206 does.
pub fn appendAvatarSliceForTest(pubkey: [32]u8, body: []const u8) ?SliceOutcome {
    const p = lookupProfile(pubkey) orelse return null;
    return p.down.append(body);
}

pub fn deliverAvatarResponseForTest(
    fx: *Effects,
    pubkey: [32]u8,
    outcome: native_sdk.EffectFetchOutcome,
    status: u16,
    body: []const u8,
) void {
    const p = lookupProfile(pubkey) orelse return;
    const index = (@intFromPtr(p) - @intFromPtr(&profile_cache.g_profiles[0])) / @sizeOf(Profile);
    handleAvatarFetched(fx, .{
        .key = avatar_fetch_key_base + index,
        .outcome = outcome,
        .status = status,
        .body = body,
    });
}

pub fn maxImageBytesForTest() usize {
    return max_image_bytes;
}

pub fn maxImageDownloadBytesForTest() usize {
    return max_image_download_bytes;
}

pub fn rangeHeaderForTest(buf: []u8, offset: usize) ?[]const u8 {
    return rangeHeader(buf, offset);
}

/// Feeds one delivered slice to a note's slot, exactly as a 206 response does.
pub fn appendMediaSliceForTest(note_id: i64, body: []const u8) ?SliceOutcome {
    const m = mediaSlotFor(note_id) orelse return null;
    return m.down.append(body);
}

/// What a note's slot has assembled so far, or null if it is holding nothing.
pub fn mediaPartialForTest(note_id: i64) ?[]const u8 {
    const m = mediaSlotFor(note_id) orelse return null;
    return m.down.bytes();
}

pub fn deliverMediaResponseForTest(
    fx: *Effects,
    note_id: i64,
    outcome: native_sdk.EffectFetchOutcome,
    status: u16,
    body: []const u8,
) void {
    const m = mediaSlotFor(note_id) orelse return;
    handleMediaFetched(fx, .{
        .key = media_fetch_key_base + mediaSlotIndex(m),
        .outcome = outcome,
        .status = status,
        .body = body,
    });
}

pub fn claimMediaSlotForTest(fx: *Effects, note_id: i64) ?*MediaSlot {
    return claimMediaSlot(fx, note_id);
}

pub fn touchMediaClockForTest() u64 {
    beginImagePass();
    return profile_cache.g_image_clock;
}

pub fn acquireImageIdForTest(fx: *Effects) ?u64 {
    return acquireImageId(fx);
}

/// What the pool thinks holds an id. The bug this guards against is a slot the
/// app holds and the pool calls `free`.
pub fn imageIdOwnerNameForTest(id: u64) []const u8 {
    if (id < 1 or id > image_registry_slots) return "out-of-range";
    const owners = imageIdOwners();
    return @tagName(owners[@intCast(id)]);
}

pub fn placeLogoUntouchableForTest() bool {
    return imageIdSeen(.place_logo) == null;
}

pub fn setPlaceLogoIdForTest(id: u64) void {
    g_place_logo_id = id;
}

pub fn markPlaceLogoSeenForTest() void {
    g_place_logo_seen = profile_cache.g_image_clock;
}

pub fn agePlaceLogoForTest() void {
    profile_cache.g_image_clock +%= 1;
}

/// The id the pool would hand out next, without taking it. Lets a test ask what
/// the rule decides without an effects channel to drop pixels through.
pub fn chooseImageIdForTest() ?u64 {
    const owners = imageIdOwners();
    const pick = chooseImageId(&owners) orelse return null;
    return pick.id;
}

pub fn imageClockForTest() u64 {
    return profile_cache.g_image_clock;
}

pub fn markAvatarWantedForTest(pubkey: [32]u8) void {
    markAvatarWanted(pubkey);
}

pub fn beginImagePassForTest() void {
    beginImagePass();
}

pub fn proxyRefusedCountForTest() usize {
    return feed_media.g_proxy_refused_count;
}

pub fn hostOfForTest(url: []const u8) []const u8 {
    return hostOf(url);
}

/// The same, recording where each mention's label landed into `mentions` when
/// one is given. A note wants that table so the label can be pressed; a profile's
/// "about" text is rendered the same way and has nowhere to put one.
pub const note_content_cap_for_test = note_content_cap;
pub fn noteContentCapForTest() usize {
    return note_content_cap;
}

pub fn invisibleForDisplayForTest(cp: u21) bool {
    return invisibleForDisplay(cp);
}

pub fn copyDisplayTextForTest(dst: []u8, src: []const u8) usize {
    return copyDisplayText(dst, src);
}

pub fn foldMathAlnumForTest(cp: u21) ?u8 {
    return foldMathAlnum(cp);
}

// -------------------------------------------------------------------- msg

/// The chrome's anchored menus. These are floating surfaces positioned against
/// their trigger, so each one is drawn as the trigger's sibling inside a stack
/// and rendered only while it is the open one.
pub const ChromeMenu = enum { none, scope, relays, account, outbox, place_feed };

pub const Msg = union(enum) {
    /// Read a different one of the open place's feeds.
    place_feed: u8,
    /// The repeating refresh timer fired: reconcile the feed with the store.
    tick: native_sdk.EffectTimer,
    /// A text edit in the composer, mirrored into the draft buffer.
    draft_edit: canvas.TextInputEvent,
    /// Post the current draft: sign, store locally, and publish to the pool.
    post,
    /// Open the compose sheet (a guest is routed to the join screen instead).
    open_compose,
    /// Dismiss the compose sheet.
    close_compose,
    /// Open the first-intent join sheet (create / bring a key / use a signer).
    open_join,
    /// Dismiss the join sheet; a remembered intent is forgotten with it.
    close_join,
    place_enter,
    place_leave,
    /// The Places icon: the switcher rail out, or folded away.
    toggle_places_rail,
    /// The place's Info card: what this place is, and the way out of it.
    open_place_info,
    close_place_info,
    /// Ask to leave, and back out of asking.
    place_leave_request,
    place_leave_cancel,
    /// Ask to delete a note of my own, then answer. A deletion cannot be taken
    /// back, so the press opens a question rather than publishing one.
    delete_note_request: i64,
    delete_note_confirm,
    delete_note_cancel,
    /// The answer to "start a new list?": yes carries on with the write that
    /// asked, no drops it.
    fresh_list_confirm,
    fresh_list_cancel,
    /// Add or remove a bookmark, and open the list of them.
    toggle_bookmark: i64,
    /// Save it where only this reader can read it. NIP-51's private half, sealed
    /// to their own key by whoever holds it.
    bookmark_privately: i64,
    open_bookmarks,
    /// Open one of the places you have entered, by its index in the list.
    place_open: u8,
    /// Back into the visit Home closed.
    place_resume,
    /// The keyboard's places grammar: out of the room and back into it, and
    /// walking the list either way.
    place_bounce,
    place_step: i8,
    /// The sheet's primary: mint a local identity and replay the intent.
    join_create,
    /// The sheet's import path: open the Notary window (a separate process),
    /// so a pasted key never enters Plaza. The remembered intent survives.
    open_notary_import,
    /// Leave the join screen back to the feed; reading never needs an identity.
    keep_browsing,
    /// The join sheet's "Use your own signer": go to the focused bunker input.
    open_bunker,
    /// Back out of the bunker input to the ladder.
    close_bunker,
    /// Open the field that takes an address, and dismiss it.
    open_address,
    close_address,
    /// A text edit in the address field, mirrored into its buffer.
    address_edit: canvas.TextInputEvent,
    /// Read what is in the address field and go where it points.
    address_submit,
    /// A person pressed in the results under it.
    search_pick: [32]u8,
    /// The well-known document for a NIP-05 address typed into it.
    nip05_found: native_sdk.EffectResponse,
    /// Hide the guest strip for this session.
    dismiss_guest_strip,
    /// Open one of the chrome's anchored menus (or close it, when it is already
    /// the open one, so a trigger toggles).
    toggle_menu: ChromeMenu,
    /// The bell, and what is behind it.
    toggle_notifications,
    close_notifications,
    notifications_tab: u8,
    notifications_read_all,
    /// The one action behind the note menu. `direction` says which way: 0 means
    /// a guest reached for it, 1 follow, 2 unfollow.
    ///
    /// It carries WHO, like every other row in that menu carries the note it was
    /// opened on. Carrying only a direction meant the handler had to find the
    /// person itself, and what it reached for was the open thread's root: so the
    /// row did nothing at all in the feed, where there is no open thread, and
    /// followed the wrong person inside one, since the label beside it was
    /// computed from the note actually clicked.
    follow_author: struct { who: [32]u8, direction: u8 },
    /// Opens a person as a level of their own.
    repost: i64,
    open_person: [32]u8,
    /// Which feed Home reads: 0 the starter pack, 1 the reader's follows.
    choose_home_scope: u8,
    /// Follow or unfollow the person whose profile is open: 1 follow, 2 unfollow.
    follow_person: u8,
    /// 1 mutes the open profile, 2 unmutes.
    mute_person: u8,
    /// Which of a profile's two tabs: 0 notes, 1 replies.
    profile_tab: u8,
    /// Opens the Edit profile sheet, and the three fields in it.
    open_profile_edit,
    close_profile_edit,
    profile_name_edit: canvas.TextInputEvent,
    profile_about_edit: canvas.TextInputEvent,
    profile_picture_edit: canvas.TextInputEvent,
    profile_website_edit: canvas.TextInputEvent,
    profile_banner_edit: canvas.TextInputEvent,
    profile_lud16_edit: canvas.TextInputEvent,
    profile_nip05_edit: canvas.TextInputEvent,
    profile_save,
    profile_retry,
    /// Ask the relays again for the reader's own follow, mute and bookmark
    /// lists, after the first ask went unanswered.
    retry_own_lists,
    /// Walks a relay through what it is for: both, read, write.
    relay_cycle: u8,
    /// The notice's answer for relay slot N: identify to it.
    auth_allow: u8,
    /// The notice's answer for relay slot N: do not.
    auth_deny: u8,
    /// The relay row's badge: ask first, identify, anonymous.
    auth_cycle: u8,
    /// A NIP-42 signature came back from the keyholder.
    helper_auth_signed: native_sdk.EffectResponse,
    /// Drops a relay from the pool.
    relay_remove: u8,
    /// The relay being typed into the add field.
    relay_edit: canvas.TextInputEvent,
    /// Adds what was typed, or the suggestion pressed.
    relay_add,
    relay_suggest: u8,
    /// Replaces the `@word` being typed with a real reference to this key.
    insert_mention: [32]u8,
    /// Close whatever chrome menu is open (Escape, or a press outside it).
    close_menu,
    /// Stop talking to the relays until resumed, or start again.
    toggle_relays_paused,
    /// Jump the feed to its newest note.
    jump_to_newest,
    go_home,
    /// Reveal the next page of a thread's replies.
    show_more_replies,
    /// Show or re-hide the replies from outside the follow graph.
    toggle_outside_replies,
    /// Copy a note's nevent address to the clipboard.
    copy_nevent: i64,
    /// Open a note on the web (njump), for sharing it outside nostr.
    open_web: i64,
    open_place_handler: i64,
    place_logo_fetched: native_sdk.EffectResponse,
    /// A text edit in the name beat's field.
    name_edit: canvas.TextInputEvent,
    /// Publish the chosen name as the account's kind:0 and move on.
    name_save,
    /// Skip the name beat; the account stays nameless for now.
    name_skip,
    /// From the backup nudge: open Settings at the backup card.
    backup_now,
    /// Dismiss the backup nudge for this session.
    backup_later,
    /// Onboarding: create a fresh local identity and enter the feed.
    create_identity,
    /// A text edit in the onboarding sign-in field.
    login_edit: canvas.TextInputEvent,
    /// Onboarding: sign in with the pasted nsec or bunker link and enter the feed.
    login_submit,
    /// Open the Settings screen.
    open_settings,
    /// Return from Settings to the feed.
    close_settings,
    /// Reveal (or hide) the local secret key for backup.
    /// Copy the signed-in npub to the clipboard.
    copy_npub,
    /// Copy the signed-in account's nprofile, which names the relays it
    /// publishes to, to the clipboard.
    copy_nprofile,
    /// Copy the local secret key (nsec) to the clipboard.
    /// Ask to log out: show the confirmation.
    logout_request,
    /// Dismiss the logout confirmation.
    logout_cancel,
    /// Confirm logout: wipe the session (and a local key) and return to onboarding.
    logout_confirm,
    /// The signer daemon exited (logged; the watchdog and respawn are later).
    /// One line of the daemon's stdout. Only one matters: the port it bound.
    /// Notary opened a NIP-51 list's private half.
    private_half: native_sdk.EffectResponse,
    /// Notary's answer to a seal: the ciphertext for a private bookmark write.
    private_seal: native_sdk.EffectResponse,
    helper_line: native_sdk.EffectLine,
    helper_exited: native_sdk.EffectExit,
    notary_exited: native_sdk.EffectExit,
    /// The signer daemon's /pubkey health-check answered.
    helper_pubkey: native_sdk.EffectResponse,
    /// A /setup (create) answered: adopt the new helper identity.
    helper_setup: native_sdk.EffectResponse,
    /// A /sign answered: ingest and publish the signed event.
    helper_signed: native_sdk.EffectResponse,
    /// An avatar fetch finished: register the image or fall back to initials.
    avatar_fetched: native_sdk.EffectResponse,
    avatar_warmed: native_sdk.EffectResponse,
    media_warmed: native_sdk.EffectResponse,
    banner_fetched: native_sdk.EffectResponse,
    /// A media fetch finished: decode, downscale if needed, and register it.
    media_fetched: native_sdk.EffectResponse,
    /// A NIP-05 well-known lookup finished: mark the author verified on a match.
    nip05_verified: native_sdk.EffectResponse,
    /// A page that was asked what it says about itself.
    link_fetched: native_sdk.EffectResponse,
    /// The releases API answered the update check.
    update_checked: native_sdk.EffectResponse,
    /// Go and get the newer version: opens the release page in a browser.
    open_update,
    /// Put the update line away for this session.
    dismiss_update,
    /// Settings: stop asking whether a newer version exists.
    update_check_toggle,
    /// A text edit in the Settings media-proxy field.
    proxy_edit: canvas.TextInputEvent,
    /// Save the media-proxy setting.
    proxy_save,
    /// Flips whether the app reaches out for what notes point at.
    previews_toggle,
    /// Settings: draw notes their authors marked sensitive without covering them.
    sensitive_toggle,
    /// Uncover one note whose author asked for it to be covered (by id).
    uncover_note: i64,
    /// The composer's "add a content warning" switch.
    warn_toggle,
    /// A text edit in the composer's content warning reason.
    warn_edit: canvas.TextInputEvent,
    proxy_toggle,
    post_delay_cycle,
    direct_fallback_toggle,
    /// Index into `hideables`.
    hide_toggle: u8,
    client_tag_toggle,
    /// The feed scrolled: remember where, so images load around the viewport.
    feed_scrolled: canvas.ScrollState,
    /// Where Settings is scrolled, echoed back so a press can move it.
    settings_scrolled: canvas.ScrollState,
    /// A link in a note was pressed: open it in the browser.
    open_url: []const u8,
    /// The animation timer fired: advance any playing GIFs.
    animate: native_sdk.EffectTimer,
    /// The profile-fetch timer: re-ask for wanted metadata, decoupled from the
    /// view refresh (see `profile_timer_key`).
    profiles: native_sdk.EffectTimer,
    /// Expand a note's picture to fill the window.
    expand_image: i64,
    /// Which picture of a gallery to open. A single picture still uses
    /// `expand_image`, which is the same thing with an implied zero.
    expand_image_at: struct { note: i64, index: u8 },
    /// One picture, asked for by the reader while previews are off.
    load_image: i64,
    /// Dismiss the expanded picture.
    close_image,
    /// Copy a note's words to the clipboard (by id).
    copy_note_text: i64,
    quote_note: i64,
    toggle_mention_off: [32]u8,
    /// Put the mention picker away without choosing anybody.
    close_mentions,
    /// Open the Notary window on what it is holding, from Settings.
    open_notary_window,
    /// Toggle a like on a note (by id): publish a kind:7 reaction, or a kind:5
    /// deletion to un-like. A guest press is remembered and routed to the join.
    like: i64,
    /// Open a note's thread (by id): the focused note and its replies.
    open_thread: i64,
    /// Open a quoted event as a thread (by its full 32-byte id).
    open_event: [32]u8,
    /// Leave the thread back to the feed.
    close_thread,
    /// A text edit in the thread's reply composer.
    reply_edit: canvas.TextInputEvent,
    /// Publish the reply composer's text as a reply to the open thread's note.
    reply_submit,
    /// Toggle a long note's body (by id) between the collapsed fold and full.
    toggle_expand: i64,
    /// The reader reached the end of the feed: ask the store for another page.
    load_older,
    /// Choose a picture to upload: 0 for a note, 1 for the avatar, 2 for the
    /// banner. Opens the file dialog; nothing is sent until the card asks.
    upload_pick: u8,
    /// Send the chosen picture.
    upload_go,
    /// Send it again after a failure.
    upload_retry,
    /// Put the upload away, whatever it is doing.
    upload_cancel,
    /// A text edit in the picture's description.
    upload_alt_edit: canvas.TextInputEvent,
    /// A text edit in Settings' add-a-media-server field.
    blossom_edit: canvas.TextInputEvent,
    /// Add what was typed to the media server list.
    blossom_add,
    /// Drop one server from the list, by its row.
    blossom_remove: u8,
    /// The reader reached the end of a person's page: another page of their
    /// notes, from the store and then from the relays.
    profile_older,
    /// A press that landed on a modal's own card rather than on a control in it.
    ///
    /// It does nothing, and that IS the job. A press does not land where it
    /// hits: the engine hit tests to the deepest widget and then walks UP to the
    /// nearest ancestor that claims presses, and a `.card` claims none, so a
    /// click on a sheet's own background used to walk straight past it to the
    /// full-window dialog behind and close the sheet the reader was using.
    /// Binding this is what makes the card claim the press and stop the walk.
    absorb_press,

    // Dispatched from Zig rather than markup: the effect results, and every
    // action on the feed screen (a Zig view now, not a markup file).
    pub const view_unbound = .{
        // Sent by Zig rather than wired to an on-* event in markup. The one
        // markup file is the join screen; every other control this app draws,
        // it draws itself, so these are dispatched from code by design.
        "tick",
        "animate",
        "profiles",
        "avatar_fetched",
        "avatar_warmed",
        "media_warmed",
        "banner_fetched",
        "place_logo_fetched",
        "media_fetched",
        "draft_edit",
        "post",
        "open_compose",
        "close_compose",
        "open_join",
        "close_join",
        "join_create",
        "open_notary_import",
        "open_bunker",
        "close_bunker",
        "nip05_verified",
        "link_fetched",
        "dismiss_guest_strip",
        "name_edit",
        "name_save",
        "name_skip",
        "backup_now",
        "backup_later",
        "private_half",
        "helper_line",
        "helper_exited",
        "notary_exited",
        "helper_pubkey",
        "helper_setup",
        "helper_signed",
        "open_settings",
        "feed_scrolled",
        "settings_scrolled",
        "open_url",
        "expand_image",
        "expand_image_at",
        "load_image",
        "close_image",
        "like",
        "repost",
        "hide_toggle",
        "proxy_toggle",
        "post_delay_cycle",
        "direct_fallback_toggle",
        "mute_person",
        "open_thread",
        "open_event",
        "close_thread",
        "reply_edit",
        "reply_submit",
        "toggle_expand",
        "load_older",
        "profile_older",
        "absorb_press",
        "open_notary_window",
        "copy_note_text",
        "quote_note",
        "close_mentions",
        "open_address",
        "close_address",
        "address_edit",
        "address_submit",
        "search_pick",
        "nip05_found",
        "update_checked",
        "open_update",
        "dismiss_update",
        "update_check_toggle",
        "bookmark_privately",
        "choose_home_scope",
        "client_tag_toggle",
        "close_menu",
        "close_notifications",
        "close_place_info",
        "close_profile_edit",
        "close_settings",
        "copy_nevent",
        "copy_nprofile",
        "copy_npub",
        "delete_note_cancel",
        "delete_note_confirm",
        "delete_note_request",
        "fresh_list_cancel",
        "fresh_list_confirm",
        "follow_author",
        "follow_person",
        "go_home",
        "insert_mention",
        "jump_to_newest",
        "logout_cancel",
        "logout_confirm",
        "logout_request",
        "notifications_read_all",
        "notifications_tab",
        "open_bookmarks",
        "open_person",
        "open_place_handler",
        "open_place_info",
        "open_profile_edit",
        "open_web",
        "place_bounce",
        "place_enter",
        "place_feed",
        "place_leave",
        "place_leave_cancel",
        "place_leave_request",
        "place_open",
        "place_resume",
        "place_step",
        "previews_toggle",
        "sensitive_toggle",
        "uncover_note",
        "warn_toggle",
        "warn_edit",
        "private_seal",
        "profile_about_edit",
        "profile_name_edit",
        "profile_picture_edit",
        "profile_banner_edit",
        "profile_lud16_edit",
        "profile_nip05_edit",
        "profile_website_edit",
        "profile_retry",
        "retry_own_lists",
        "profile_save",
        "profile_tab",
        "proxy_edit",
        "proxy_save",
        "auth_allow",
        "auth_deny",
        "auth_cycle",
        "helper_auth_signed",
        "relay_add",
        "relay_cycle",
        "relay_edit",
        "relay_remove",
        "relay_suggest",
        "upload_pick",
        "upload_go",
        "upload_retry",
        "upload_cancel",
        "upload_alt_edit",
        "blossom_edit",
        "blossom_add",
        "blossom_remove",
        "show_more_replies",
        "toggle_bookmark",
        "toggle_mention_off",
        "toggle_menu",
        "toggle_notifications",
        "toggle_outside_replies",
        "toggle_places_rail",
        "toggle_relays_paused",
    };
};

// ---------------------------------------------------------------- app + view

pub const AppUi = canvas.Ui(Msg);

// The two static screens stay declarative markup, compiled into the view at
// build time (so their bindings are still checked, now by the compiler). The
// feed is hand-written below: an inline image needs a runtime `ImageId`
// reference, which the markup grammar deliberately does not carry, so a media
// feed has to be a Zig view.
const OnboardingView = canvas.CompiledMarkupView(Model, Msg, @embedFile("onboarding.native"));
/// Settings, built in Zig. It was markup until the relay list needed a row that
/// carries its own index into three different messages, which a binding cannot
/// express: the same wall the feed hit. Cards below read top to bottom the way
/// the screen does.
///
/// It is a SHEET over the feed rather than a screen instead of it. As a screen
/// it had two faults that were really one fault: a 440 column centred on a bare
/// window reads as a modal that forgot to be one, and the grey behind that
/// column was a panel stretched by the scroll viewport, so it stopped dead at
/// the window's height and everything past the fold sat on bare black. A card
/// with the scroll INSIDE it cannot do that: the surface is the card's own, and
/// the scroll is bounded by it rather than the other way round.
fn settingsSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Exactly the number of `sections[n] =` lines below. It was full when this
    // screen grew a section, and the bounds check is what said so. Eight with
    // the media servers; an oversize array is legal and a lie.
    var sections: [8]AppUi.Node = undefined;
    var n: usize = 0;

    sections[n] = identitySection(ui, model);
    n += 1;
    sections[n] = settingsSection(
        ui,
        "RELAYS",
        "reads & writes route automatically · NIP-65",
        relayCard(ui, model),
    );
    n += 1;
    if (!model.is_guest()) {
        sections[n] = settingsSection(ui, "MEDIA SERVERS", "where pictures you add are uploaded", mediaServersCard(ui, model));
        n += 1;
    }
    sections[n] = settingsSection(ui, "APPEARANCE", "", appearanceCard(ui));
    n += 1;
    sections[n] = settingsSection(ui, "FEED", "", feedCard(ui, model));
    n += 1;
    sections[n] = settingsSection(ui, "NOTES", "what each one shows · what the feed stops asking for", notesCard(ui, model));
    n += 1;
    sections[n] = logoutSection(ui, model);
    n += 1;
    sections[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = model.version_line(), .scale = mono_hint_scale }}),
    });
    n += 1;

    // A PAGE, not a modal, and the reason is measured rather than stylistic.
    //
    // A modal is a translucent scrim across the whole window. Anything that
    // changes underneath one has to be repainted along with the scrim over it,
    // so every frame of scrolling inside a sheet repaints the entire window and
    // the cost grows with the window. On a 1600x1000 window, presenting a frame
    // took 117ms with settings open as a sheet and 18ms with a thread open,
    // which is the same screen area drawn as an opaque level. The feed alone was
    // 17ms. Eight frames a second against sixty, for a dimmed backdrop.
    //
    // Threads and profiles have always been opaque full-screen levels and have
    // always scrolled properly. This is settings joining them.
    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Settings" },
    }, .{
        settingsHeader(ui),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        ui.scroll(.{ .grow = 1, .value = model.settings_scroll_y, .on_scroll = AppUi.scrollMsg(.settings_scrolled) }, .{
            ui.row(.{ .gap = 0 }, .{
                ui.spacer(1),
                ui.column(.{ .gap = settings_section_gap, .width = settings_column_width }, .{
                    vgap(ui, 16),
                    ui.column(.{ .gap = settings_section_gap, .grow = 1 }, .{sections[0..n]}),
                    vgap(ui, 18),
                }),
                ui.spacer(1),
            }),
        }),
    });
}

/// The 38px header band. "Settings" sits centred in it, with the way out on the
/// left, so the title belongs to the sheet rather than to the column beneath it.
fn settingsHeader(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0, .height = settings_header_height, .padding = 0.01 }, .{
        hgap(ui, 10),
        // "Close", not "Back": this is a sheet over the feed now, and Back is
        // what the thread and profile headers say when there is a place behind
        // to return to. There is nothing behind this but the feed it covers.
        ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = Msg.close_settings }, "Close"),
        ui.spacer(1),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_sheet_title } },
            &.{.{ .text = "Settings", .weight = .medium, .scale = settings_title_scale }},
        ),
        ui.spacer(1),
        // The same width the Close button takes, so the title is centred in the
        // band rather than in what is left of it.
        hgap(ui, 62),
    });
}

/// A labelled section: the mono label, an optional caption beside it, then the
/// card. The label is mono per the design; the engine draws mono at one weight,
/// so it carries its emphasis through colour and size rather than through w600.
fn settingsSection(ui: *AppUi, label: []const u8, caption: []const u8, card: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
            if (caption.len > 0) hgap(ui, 8) else ui.spacer(0),
            if (caption.len > 0)
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = caption, .scale = mono_hint_scale }})
            else
                ui.spacer(0),
        }),
        vgap(ui, settings_label_gap),
        card,
    });
}

/// One settings card: the house card chrome, so every section on the screen
/// wears the same edge.
pub fn settingsCard(ui: *AppUi, children: anytype) AppUi.Node {
    const p = theme.palette;
    // Padding, not scaffolding. This was a row, two columns and four spacers
    // around the children: seven nodes per card to express an inset that the
    // card can state in one. Settings is the heaviest screen in the app and
    // half its nodes were whitespace like this.
    //
    // The inset is uniform 12 where it used to be 12 horizontal and 11
    // vertical, because the builder takes one number. One pixel, against six
    // nodes a card.
    return ui.el(.card, .{ .padding = 12, .style = .{ .background = p.surface_settings_card, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 } }, .{
        ui.column(.{ .gap = 0, .grow = 1 }, children),
    });
}

/// A card's internal rule: what separates who you are from what signs for you.
fn cardDivider(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 10),
        ui.el(.panel, .{ .height = 1, .padding = 0.01, .style = .{ .background = p.divider_card, .radius = 0, .stroke_width = 0 } }, .{}),
        vgap(ui, 10),
    });
}

/// The identity section: who you are, what signs for you, and, when the key is
/// on this machine, how to take a copy of it away with you.
fn identitySection(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    var rows: [5]AppUi.Node = undefined;
    var n: usize = 0;

    rows[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        meAvatar(ui, 38),
        hgap(ui, 10),
        ui.column(.{ .gap = 0, .grow = 1 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = accountName(), .weight = .medium, .scale = scope_title_scale }}),
            // The npub only when it is not already the line above it: an account
            // with no kind:0 yet would otherwise read its own key twice.
            if (accountHasName()) vgap(ui, 2) else ui.spacer(0),
            if (accountHasName())
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = npubShort(), .monospace = true, .scale = mono_meta_scale }})
            else
                ui.spacer(0),
        }),
        hgap(ui, 8),
        settingsLink(ui, "Copy npub", Msg.copy_npub),
        hgap(ui, 10),
        if (model.is_guest()) ui.spacer(0) else settingsLink(ui, "Edit profile", Msg.open_profile_edit),
    });
    n += 1;

    rows[n] = cardDivider(ui);
    n += 1;

    // What holds the key, said as a fact about this machine rather than as a
    // badge. The dot is green only for a signer that is answering.
    // The dot reports the signer. Painting it green unconditionally would say
    // "this is working" while a dead Notary daemon quietly refused every note.
    const signer_state = signerStatus();
    const signer_healthy = signerIsHealthy();
    rows[n] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.panel, .{ .width = 7, .height = 7, .padding = 0.01, .style = .{
            .background = signer_state.color,
            .radius = 4,
            .stroke_width = 0,
        } }, .{}),
        hgap(ui, 9),
        ui.column(.{ .gap = 0, .grow = 1 }, .{
            // The line says what signs for you; the sub-line says how that is
            // going. When the signer is unhealthy its own words take the
            // sub-line, because "Notary unreachable" is the thing worth reading
            // and a fixed reassurance underneath it would be a lie.
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = model.signer_line(), .weight = .medium, .scale = menu_scale }}),
            vgap(ui, 2),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = if (signer_healthy) p.text_faint else p.status_warning_text } },
                &.{.{ .text = if (signer_healthy) model.signer_sub() else signer_state.label, .scale = mono_hint_scale }},
            ),
        }),
        // The design puts a "Change…" here. There is no change-signer flow to
        // send it to: changing what signs means signing out and signing back in
        // differently, and the control for that is at the bottom of the screen
        // wearing the word it deserves. A gentler-looking link that opens a
        // confirmation about removing your key is the dishonest option.
        //
        // What DOES belong in that seat is a way to go and look at the thing this
        // row is a sentence about. Notary is a separate process holding the key
        // this account is, and until now the only time a reader ever saw it was
        // the few seconds of the ceremony that made the key.
        if (model.can_open_notary()) settingsLink(ui, "Open Notary", Msg.open_notary_window) else ui.spacer(0),
    });
    n += 1;

    // The backup used to be here, and could not work: a key minted in Plaza is
    // moved into the keyholder in the background, which clears the in-process
    // copy, so this panel vanished the moment it became relevant and its reveal
    // read a keypair that was gone.
    //
    // It lives in the signer's own window now, which is the process that holds
    // the key. Plaza asking for a key to show would be Plaza holding one, and
    // "the key never enters the client" is the sentence this whole arrangement
    // exists to keep true. The row above is what opens that window.

    return settingsSection(ui, "IDENTITY", "", settingsCard(ui, .{rows[0..n]}));
}

/// A quiet inline action: the design's "Copy npub", "Edit profile", "Change…".
/// Text, not a button, because a card full of buttons reads as a form.
pub fn settingsLink(ui: *AppUi, label: []const u8, msg: Msg) AppUi.Node {
    const p = theme.palette;
    return ui.el(.list_item, .{
        .padding = 0.01,
        .height = 18,
        .cross = .center,
        .on_press = msg,
        .style = .{ .radius = 4 },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = label, .scale = meta_scale }}),
    });
}

/// Appearance. Nothing here is adjustable yet, and the section says so by
/// showing where the app stands on each axis with the alternatives disabled: a
/// statement about the app rather than a row of dead controls.
fn appearanceCard(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return settingsCard(ui, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            themeRadio(ui, "Dark", true),
            hgap(ui, 14),
            themeRadio(ui, "System", false),
            hgap(ui, 14),
            themeRadio(ui, "Light", false),
            ui.spacer(1),
        }),
        vgap(ui, 9),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Plaza is dark only for now, at a comfortable density. Both are on the list.", .scale = mono_hint_scale }},
        ),
    });
}

/// One appearance choice. Only the selected one is live, and the others are
/// disabled rather than absent, so the axis is legible.
fn themeRadio(ui: *AppUi, label: []const u8, selected: bool) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.radio, .{
            .size = .sm,
            .selected = selected,
            // Even the selected one takes no press: there is nothing to switch
            // to. `disabled` also stops the control claiming a press it would
            // then drop, which is what a live-looking dead control does.
            .disabled = true,
            .opacity = if (selected) 1.0 else 0.55,
            .style = .{
                .border = if (selected) p.surface_control_solid else p.border_radio,
                .accent = p.surface_control_solid,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = label },
        }, .{}),
        hgap(ui, 6),
        ui.paragraph(
            .{ .style = .{ .foreground = if (selected) p.text_body_strong else p.text_muted_alt }, .opacity = if (selected) 1.0 else 0.55 },
            &.{.{ .text = label, .scale = menu_scale }},
        ),
    });
}

/// What the reader can take away, and what is gone right now.
///
/// The WHOLE registry is listed, not only what is hidden, and that is the point
/// of the screen rather than a detail of it. Hide something in the feed and
/// there is nothing left there to press to get it back; a list that showed only
/// what was hidden would be empty exactly when somebody came looking for it.
///
/// Each row says what hiding it does to the fetching, in its own words, because
/// two of these stop the app asking relays for anything and one does not, and a
/// screen that let you assume they were the same would be making a promise the
/// app does not keep.
fn notesCard(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    const p = theme.palette;
    var kids: [hideables.len * 3]AppUi.Node = undefined;
    var n: usize = 0;
    for (hideables, 0..) |h, i| {
        if (n > 0) {
            kids[n] = vgap(ui, 10);
            n += 1;
        }
        kids[n] = ui.el(.checkbox, .{
            .size = .sm,
            // Checked means SHOWN. The registry stores what is hidden, which is
            // the right way round for a file and the wrong way round for a
            // person: a box you tick to make something disappear reads as a
            // switch that does the opposite of what it says.
            .checked = !hiding.g_hidden[i],
            .text = h.label,
            .on_toggle = Msg{ .hide_toggle = @intCast(i) },
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = h.label, .focusable = true },
        }, .{});
        n += 1;
        kids[n] = ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = h.detail, .scale = mono_hint_scale }},
        );
        n += 1;
    }
    return settingsCard(ui, .{kids[0..n]});
}

/// The feed section: what the app is allowed to fetch on the reader's behalf,
/// and where pictures are resized. Both are privacy settings before they are
/// anything else, which is why each keeps its sentence.
fn feedCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return settingsCard(ui, .{
        // A real checkbox: it owns its whole row, because a control nested in a
        // pressable row claims the press and drops it.
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.previews_on(),
            .text = "Load media previews",
            .on_toggle = Msg.previews_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Load media previews", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.previews_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.sensitive_on(),
            .text = "Show sensitive notes without a warning",
            .on_toggle = Msg.sensitive_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Show sensitive notes without a warning", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.sensitive_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.client_tag_on(),
            .text = "Say notes were written in Plaza",
            .on_toggle = Msg.client_tag_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Say notes were written in Plaza", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.client_tag_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.update_check_on(),
            .text = "Tell me when a newer Plaza exists",
            .on_toggle = Msg.update_check_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Tell me when a newer Plaza exists", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.update_check_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.paragraph(
                .{ .grow = 1, .wrap = true },
                &.{.{ .text = "Hold notes and replies before sending", .scale = 1.0 }},
            ),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .post_delay_cycle }, model.post_delay_label()),
        }),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.post_delay_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.proxy_on(),
            .text = "Load pictures through a proxy",
            .on_toggle = Msg.proxy_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Load pictures through a proxy", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.proxy_explainer(), .scale = mono_hint_scale }},
        ),
        vgap(ui, 9),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.direct_fallback_on(),
            .text = "Ask the host when the proxy refuses",
            .on_toggle = Msg.direct_fallback_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Ask the host when the proxy refuses", .focusable = true },
        }, .{}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = model.direct_fallback_explainer(), .scale = mono_hint_scale }},
        ),
        cardDivider(ui),
        ui.paragraph(.{ .style = .{ .foreground = p.text_body_soft } }, &.{.{ .text = "Media proxy", .scale = menu_scale }}),
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Which service does the resizing. Point it at your own instance if you would rather not use a public one.", .scale = mono_hint_scale }},
        ),
        vgap(ui, 9),
        ui.inputGroup(
            .{ .semantics = .{ .label = "Media proxy" } },
            ui.el(.textarea, .{
                .text = model.proxy_draft(),
                .placeholder = "https://wsrv.nl/",
                .on_input = AppUi.inputMsg(.proxy_edit),
                .on_submit = Msg.proxy_save,
                .height = 30,
            }, .{}),
            ui.inputGroupActions(.{}, .{
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg.proxy_save }, "Save"),
            }),
        ),
        fieldNote(ui, model.proxy_status(), model.proxy_invalid),
    });
}

/// What a settings field has to say about itself, under the field rather than
/// beside its button. A sentence squeezed into the strip next to a button wraps
/// into a box that has a fixed height, and its second line ends up drawn over
/// whatever follows; under the field it has the card's whole width and pushes
/// the rest down instead. Nothing at all when there is nothing to say.
fn fieldNote(ui: *AppUi, text: []const u8, refusal: bool) AppUi.Node {
    if (text.len == 0) return ui.spacer(0);
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = if (refusal) p.status_warning_text else p.text_dim } },
            &.{.{ .text = text, .scale = mono_hint_scale }},
        ),
    });
}

/// A scroll offset past any page Settings can be. The scroll view clamps a
/// requested offset to the end of its content, so this means "the bottom".
pub const settings_scroll_end: f32 = 1.0e6;

/// Signing out: one press to ask, one card to confirm. The card is the whole
/// section when it is up, because a confirmation that shares a row with other
/// controls is a confirmation nobody reads.
fn logoutSection(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.logout_idle()) {
        return ui.row(.{ .gap = 0 }, .{
            ui.button(.{ .variant = .destructive, .on_press = Msg.logout_request }, "Log out"),
            ui.spacer(1),
        });
    }
    return settingsCard(ui, .{
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = theme.palette.text_primary } }, &.{.{ .text = model.logout_warning(), .scale = menu_scale }}),
        vgap(ui, 12),
        ui.row(.{ .cross = .center, .gap = 8 }, .{
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.logout_cancel }, "Cancel"),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.logout_confirm }, "Log out"),
        }),
    });
}

/// Walks a relay through what it is for. Both, then read, then write, then both
/// again: three states, because a relay that is neither is a relay you have
/// removed, and there is a button for that.
fn cycleRelay(i: usize) void {
    if (i >= relay_table.g_relays.len) return;
    const e = &relay_table.g_relays[i];
    if (!e.used) return;
    if (e.read and e.write) {
        e.write = false;
    } else if (e.read) {
        e.read = false;
        e.write = true;
    } else {
        e.read = true;
        e.write = true;
    }
}

/// Whether a relay may be taken out of the list: only while another remains.
fn mayRemoveRelay() bool {
    return relayCount() > 1;
}

/// Drops a relay. The SLOT stays claimed and dormant: its index is a promise to
/// everything that recorded one, and its thread simply finds nothing to dial.
fn removeRelay(i: usize) void {
    if (i >= relay_table.g_relays.len) return;
    // Recorded BEFORE the seat is wiped, because the publish splices onto the
    // list this account already published and "the pool has no seat for it" is
    // what decides a relay is carried forward. A removal looks exactly like
    // that from the outside.
    if (relayAt(i)) |e| noteRelayRemoved(e.url());
    lockRelayTable();
    relay_table.g_relays[i] = .{};
    unlockRelayTable();
    // The seat keeps its index, but nothing about the relay that sat in it: a
    // status left at `.connected` would keep counting toward "4/6 relays", and a
    // latency left behind would be shown beside whoever takes the seat next.
    forgetRelaySlotState(i);
}

/// Drops everything recorded ABOUT a slot rather than about the pool: its
/// connection state, its latency samples, and the per-note marks saying this
/// slot was the one that carried a note.
fn forgetRelaySlotState(i: usize) void {
    if (i >= max_relays) return;
    setRelayStatus(i, .offline);
    clearRelayRtt(i);
    forgetRelaySeen(i);
    // What a relay asked of the last occupant is not a question for the next.
    authSlotReset(i);
}

/// The URLs currently in the slots, so a table swap can tell which seats
/// actually changed hands.
pub fn snapshotRelayUrls(out: *[max_relays][96]u8, lens: *[max_relays]u8) void {
    lockRelayTable();
    defer unlockRelayTable();
    for (&relay_table.g_relays, 0..) |*e, i| {
        lens[i] = if (e.used) e.url_len else 0;
        if (e.used) @memcpy(out[i][0..e.url_len], e.url_buf[0..e.url_len]);
    }
}

/// Drops what was recorded against every slot whose OCCUPANT changed, and
/// leaves alone the slots still holding the same relay.
///
/// The whole-table version of this was `for (0..max_relays) |i|
/// forgetRelaySlotState(i)`, and it is why the pool read `0/5` forever after a
/// sign-out. Status, latency and seen-ness describe a LIVE CONNECTION, and the
/// thread that owns that connection is parked in a blocking read almost all of
/// the time: it cannot put a status back that somebody else cleared until its
/// relay next says something, and a quiet relay never does. So clearing the row
/// for a relay that is still perfectly connected does not go stale, it stays
/// wrong, and the bar reads nothing-is-working over a pool that is working.
///
/// The seat metaphor the per-slot state is built on still holds: it is about the
/// occupant, so it is dropped when the occupant changes and kept when it does
/// not. Signing out replaces a list with the bootstrap five, and most of the
/// time most of those seats do not change hands at all.
pub fn forgetChangedRelaySlotStates(before: *const [max_relays][96]u8, lens: *const [max_relays]u8) void {
    for (0..max_relays) |i| {
        const was: []const u8 = before[i][0..lens[i]];
        const now: []const u8 = if (relayAt(i)) |e| e.url() else "";
        // Same relay in the same seat: its connection, its latency and its
        // status all still describe something true.
        if (was.len != 0 and now.len != 0 and relayUrlEql(was, now)) continue;
        forgetRelaySlotState(i);
    }
}

/// The relay list: which relays this app talks to, and in which direction.
///
/// The badge is the control, not a label. Pressing it walks R and W, which is
/// the whole of NIP-65's vocabulary: a relay you read from, a relay you write
/// to, or both. Reads and writes actually follow it, so a relay set to R never
/// sees a note and a relay set to W is never asked a question.
fn relayCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const slots = relaySlots();
    const rows = ui.arena.alloc(AppUi.Node, slots + 4) catch return ui.spacer(0);
    var n: usize = 0;
    // No heading here: the section above the card already says RELAYS, and the
    // caption beside it already says what the markers do.
    rows[n] = ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
        &.{.{ .text = "Press a badge to change what a relay is for.", .scale = mono_hint_scale }},
    );
    n += 1;
    rows[n] = vgap(ui, 10);
    n += 1;
    for (0..slots) |i| {
        const e = relayAt(i) orelse continue;
        const state: Conn = @enumFromInt(relay_conn.g_relay_status[i].load(.monotonic));
        rows[n] = relayListRow(ui, e, i, state);
        n += 1;
    }
    rows[n] = relayAddRow(ui, model);
    n += 1;
    return settingsCard(ui, .{rows[0..n]});
}

/// One relay: how it is doing, where it is, what it is for, and a way out.
fn relayListRow(ui: *AppUi, e: *const RelayEntry, index: usize, state: Conn) AppUi.Node {
    const p = theme.palette;
    const dot: canvas.Color = switch (state) {
        .connected => p.status_success,
        // Amber, not green. The socket is open and nothing has failed, but the
        // last word from this relay is a minute old and a keepalive is out with
        // no answer. Green here is the lie this state exists to stop telling.
        .quiet => p.status_warning_text,
        .connecting => p.status_warning_text,
        .offline => p.status_offline,
    };
    const badge = relayBadgeText(e);
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.el(.panel, .{ .width = 7, .height = 7, .padding = 0.01, .style = .{ .background = dot, .radius = 4, .stroke_width = 0 } }, .{}),
            hgap(ui, 9),
            ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = e.url(), .monospace = true, .scale = mono_row_scale }}),
            hgap(ui, 9),
            // Reconnecting is worth saying: an amber dot alone reads as a fault
            // rather than as the app already doing something about it.
            if (state == .connecting)
                ui.paragraph(.{ .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = "reconnecting", .monospace = true, .scale = mono_chip_scale }})
            else if (state == .quiet)
                ui.paragraph(.{ .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = "quiet", .monospace = true, .scale = mono_chip_scale }})
            else if (relayRttMs(index)) |ms|
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = ui.fmt("{d} ms", .{ms}), .monospace = true, .scale = mono_chip_scale }})
            else
                ui.spacer(0),
            ui.spacer(1),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg{ .relay_cycle = @intCast(index) },
                .style = .{ .radius = 4, .border = p.border_chip, .stroke_width = 1 },
                .semantics = .{ .role = .button, .label = ui.fmt("Change what {s} is for", .{e.url()}), .focusable = true },
            }, .{
                hgap(ui, 5),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = badge, .monospace = true, .scale = mono_badge_scale }}),
                hgap(ui, 5),
            }),
            // Whether this relay may know who the reader is. Only once the
            // relay has asked or the reader has said, so a row that never
            // mentions identity does not grow a control about it.
            if (authBadgeText(index, e.url())) |text| ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 6),
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .height = 20,
                    .cross = .center,
                    .on_press = Msg{ .auth_cycle = @intCast(index) },
                    .style = .{ .radius = 4, .border = p.border_chip, .stroke_width = 1 },
                    .semantics = .{ .role = .button, .label = ui.fmt("Change whether {s} may know who you are", .{e.url()}), .focusable = true },
                }, .{
                    hgap(ui, 5),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = text, .monospace = true, .scale = mono_badge_scale }}),
                    hgap(ui, 5),
                }),
            }) else ui.spacer(0),
            hgap(ui, 8),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg{ .relay_remove = @intCast(index) },
                .style = .{ .radius = 4 },
                .semantics = .{ .role = .button, .label = ui.fmt("Remove {s}", .{e.url()}), .focusable = true },
            }, .{
                hgap(ui, 4),
                ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_dim } }, "x"),
                hgap(ui, 4),
            }),
        }),
        // A relay that is connected and giving nothing is the state this line
        // exists for: the dot is green, so without it the row reads as a relay
        // with nothing to say.
        if (authRowNote(index)) |note| ui.column(.{ .gap = 0 }, .{
            vgap(ui, 3),
            ui.row(.{ .gap = 0 }, .{
                hgap(ui, 16),
                ui.paragraph(.{ .wrap = true, .grow = 1, .style = .{ .foreground = p.status_warning_text } }, &.{.{ .text = note, .scale = mono_chip_scale }}),
            }),
        }) else ui.spacer(0),
        vgap(ui, 9),
    });
}

/// The relays this reader's follows write to, offered as one press each. Empty
/// until a follow's kind:10002 has actually been read, because a suggestion the
/// app invented would just be another default wearing a recommendation's face.
///
/// The chips are packed into rows HERE rather than left to the layout, because
/// rows and columns in this engine never flow-wrap their children: `wrap` is a
/// line policy for text leaves and is silently inert on a container. This row
/// carried `.wrap = true` and a comment describing wrapping that never
/// happened, so six suggested relays ran to x=1372 in a 760 window, straight
/// off the right edge of the card and the window with it.
fn relaySuggestions(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const count = relaySuggestionCount();
    if (count == 0) return ui.spacer(0);
    const chips = ui.arena.alloc(AppUi.Node, count) catch return ui.spacer(0);
    const widths = ui.arena.alloc(f32, count) catch return ui.spacer(0);
    const tokens = theme.tokens(Model)(model);
    var n: usize = 0;
    for (0..count) |i| {
        var buf: [96]u8 = undefined;
        const url = relaySuggestionCopy(i, &buf) orelse continue;
        // The arena copy is what the frame renders: `buf` dies with this loop.
        var shown: []const u8 = ui.arena.dupe(u8, relayShortName(url)) catch continue;
        // Measured with the engine's own sizing, against the same tokens the
        // frame is laid out with, so the packing below agrees with what the
        // layout will actually do rather than with an estimate of it. A name too
        // long for a row of its own is shortened until it fits, rather than
        // allowed to hang off the card: the text is monospace, so cutting
        // characters cuts width in proportion, and each cut is re-measured so
        // the loop cannot talk itself into a width the engine disagrees with.
        var chip = suggestionChip(ui, i, shown, tokens);
        var attempts: usize = 0;
        while (chip.width > settings_content_width and shown.len > 8 and attempts < 8) : (attempts += 1) {
            const room: usize = @intFromFloat(@max(1, settings_content_width - relay_chip_chrome));
            const have: usize = @intFromFloat(@max(1, chip.width - relay_chip_chrome));
            const keep = @max(@as(usize, 7), (shown.len * room) / have -| 1);
            if (keep >= shown.len) break;
            shown = ui.fmt("{s}\u{2026}", .{shown[0..keep]});
            chip = suggestionChip(ui, i, shown, tokens);
        }
        chips[n] = chip.node;
        widths[n] = chip.width;
        n += 1;
    }
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 10),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = "Relays the people you read write to", .scale = mono_meta_scale }},
        ),
        vgap(ui, 6),
        chipRows(ui, chips[0..n], widths[0..n], settings_content_width, relay_chip_gap),
    });
}

/// A gap between suggestion chips, across and down.
const relay_chip_gap: f32 = 6;

/// Everything a chip is wider than its words: seven either side of the label
/// and the hairline border. Stated rather than measured, because the engine
/// does not measure a `.list_item` from its children at all: asking it for an
/// intrinsic size returns the chrome alone, which is how the first version of
/// this packing measured every chip at 24 points and put six of them on one
/// row. The label is measured for real; this is added to it, and the rule in
/// the suite holds the sum against a laid-out frame.
const relay_chip_chrome: f32 = 15;

/// One suggestion, as a chip, with the width it will actually take.
fn suggestionChip(ui: *AppUi, index: usize, shown: []const u8, tokens: canvas.DesignTokens) struct { node: AppUi.Node, width: f32 } {
    const p = theme.palette;
    const label = ui.paragraph(
        .{ .style = .{ .foreground = p.text_muted_alt } },
        &.{.{ .text = ui.fmt("+ {s}", .{shown}), .monospace = true, .scale = mono_chip_scale }},
    );
    const node = ui.el(.list_item, .{
        .padding = 0.01,
        .height = 22,
        .cross = .center,
        .on_press = Msg{ .relay_suggest = @intCast(index) },
        .style = .{ .radius = 5, .border = p.border_chip, .stroke_width = 1 },
        .semantics = .{ .role = .button, .label = ui.fmt("Add {s}", .{shown}), .focusable = true },
    }, .{
        hgap(ui, 7),
        label,
        hgap(ui, 7),
    });
    return .{ .node = node, .width = canvas.intrinsicWidgetSize(label.widget, tokens).width + relay_chip_chrome };
}

/// Packs pre-measured children into rows no wider than `limit`, greedily: the
/// flow layout the engine does not do. A child wider than the limit on its own
/// still gets a row to itself, because the alternative is dropping it.
fn chipRows(ui: *AppUi, chips: []const AppUi.Node, widths: []const f32, limit: f32, gap: f32) AppUi.Node {
    // At worst one chip per row, plus a gap row between each.
    const lines = ui.arena.alloc(AppUi.Node, chips.len * 2) catch return ui.spacer(0);
    var line_count: usize = 0;
    var first: usize = 0;
    var used: f32 = 0;
    var i: usize = 0;
    while (i < chips.len) {
        const next = if (i == first) widths[i] else used + gap + widths[i];
        if (i > first and next > limit) {
            if (line_count > 0) {
                lines[line_count] = vgap(ui, gap);
                line_count += 1;
            }
            lines[line_count] = ui.row(.{ .gap = gap }, .{chips[first..i]});
            line_count += 1;
            first = i;
            used = widths[i];
            i += 1;
            continue;
        }
        used = next;
        i += 1;
    }
    if (first < chips.len) {
        if (line_count > 0) {
            lines[line_count] = vgap(ui, gap);
            line_count += 1;
        }
        lines[line_count] = ui.row(.{ .gap = gap }, .{chips[first..chips.len]});
        line_count += 1;
    }
    return ui.column(.{ .gap = 0 }, .{lines[0..line_count]});
}

/// A relay URL with the scheme and any trailing slash taken off. The scheme is
/// the same on every row, so it is the part that carries no information.
pub fn relayShortName(url: []const u8) []const u8 {
    var out = url;
    if (std.mem.startsWith(u8, out, "wss://")) out = out["wss://".len..];
    return std.mem.trimEnd(u8, out, "/");
}

/// Where a relay is added, and where the ones your follows use are offered.
fn relayAddRow(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.column(.{ .gap = 0 }, .{
        ui.inputGroup(
            .{ .semantics = .{ .label = "Add a relay" } },
            ui.el(.textarea, .{
                .text = model.relay_draft(),
                .placeholder = "wss://",
                .on_input = AppUi.inputMsg(.relay_edit),
                .on_submit = Msg.relay_add,
                .height = 30,
            }, .{}),
            ui.inputGroupActions(.{}, .{
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg.relay_add }, "Add"),
            }),
        ),
        fieldNote(ui, model.relay_status(), model.relay_error or model.relay_full or model.relay_last),
        relaySuggestions(ui, model),
    });
}

/// The root view: one screen at a time, chosen by the stage, with an expanded
/// picture layered over it when one is open.
pub fn appView(ui: *AppUi, model: *const Model) AppUi.Node {
    // A new tree, so the payloads the one before last handed out are free.
    g_view_build +%= 1;
    const view = appViewLayers(ui, model);
    return view;
}

fn appViewLayers(ui: *AppUi, model: *const Model) AppUi.Node {
    const base = switch (model.stage) {
        .onboarding => OnboardingView.build(ui, model),
        // Settings layers OVER the feed rather than replacing it, like every
        // other sheet: the feed stays mounted and keeps its scroll offset, and
        // it is what the sheet's scrim has to blur to look like glass. Without
        // its thread levels, for the node-budget reason `feedView` states.
        .settings => feedView(ui, model, false),
        .ready => feedView(ui, model, true),
    };
    if (model.deleting_note) |_| {
        return ui.stack(.{ .grow = 1 }, .{ base, deleteConfirm(ui) });
    }
    if (model.fresh_ask) |ask| {
        return ui.stack(.{ .grow = 1 }, .{ base, freshListConfirm(ui, ask) });
    }
    if (model.expanded_note) |note_id| {
        if (model.noteById(note_id)) |note| {
            // Layered OVER the feed rather than replacing it, so the scroll
            // region stays mounted and holds its offset. Swapping the tree out
            // unmounts it, and closing would drop the reader back at the top.
            return ui.stack(.{ .grow = 1 }, .{ base, imageViewer(ui, note, model.expanded_image) });
        }
    }
    if (model.stage == .ready and model.joining) {
        return ui.stack(.{ .grow = 1 }, .{ base, joinSheet(ui, model) });
    }
    if (model.stage == .ready and model.naming) {
        return ui.stack(.{ .grow = 1 }, .{ base, nameSheet(ui, model) });
    }
    if (model.stage == .ready and model.address_open) {
        return ui.stack(.{ .grow = 1 }, .{ base, addressSheet(ui, model) });
    }
    if (model.notifications_open) {
        return ui.stack(.{ .grow = 1 }, .{ base, notificationsSheet(ui, model) });
    }
    // Over the room it describes, so closing it puts the reader back exactly
    // where they were rather than at the top of a rebuilt feed.
    if (places.g_place_info != .closed) {
        if (activePlace()) |m| return ui.stack(.{ .grow = 1 }, .{ base, placeInfoCard(ui, m) });
    }
    if (model.stage == .settings) {
        // Both sheets, in order, when a profile is being edited: dropping the
        // one underneath would make Settings blink out and back as the reader
        // opens and closes the editor it was opened from.
        //
        // The address field is reachable here too, by its shortcut, and needs
        // the same treatment for the same reason.
        if (model.address_open) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), addressSheet(ui, model) });
        }
        if (model.editing_profile) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), profileSheet(ui, model) });
        }
        // The toast rides over Settings as well as over the feed. It was gated on
        // the feed alone, from when nothing in Settings could raise one; the
        // "Open Notary" control can, and its whole job on a refused press is to
        // say why nothing happened. A message that only appears on a screen the
        // reader is not looking at is the silent press it exists to prevent.
        if (model.toast_until != 0) {
            return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model), toastOverlay(ui, model) });
        }
        return ui.stack(.{ .grow = 1 }, .{ base, settingsSheet(ui, model) });
    }
    if (model.stage == .ready and model.composing) {
        return ui.stack(.{ .grow = 1 }, .{ base, composeSheet(ui, model) });
    }
    if (model.stage == .ready and model.toast_until != 0) {
        return ui.stack(.{ .grow = 1 }, .{ base, toastOverlay(ui, model) });
    }
    return base;
}

/// The name beat: one optional ask after creating an identity, so the account
/// is not blank. Fully skippable; the remembered intent replays either way.
fn nameSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalScrim(ui, "Name", .name_skip, ui.el(.dialog, .{
        .width = name_card_width,
        .on_dismiss = .name_skip,
        .semantics = .{ .label = "Name" },
    }, .{
        modalCard(ui, name_card_width, ui.column(.{ .grow = 1, .gap = 10, .padding = 16 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Want a name on it?", .weight = .bold, .scale = name_title_scale }},
            ),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = "Shown with your notes. Change it any time.", .scale = join_sub_scale }},
            ),
            ui.el(.textarea, .{
                .text = model.name_draft(),
                .placeholder = "A name people will see",
                .on_input = AppUi.inputMsg(.name_edit),
                .autofocus = true,
                .on_submit = .name_save,
                .height = 38,
                .style = .{ .background = p.surface_input, .border = p.border_focus, .radius = 9, .stroke_width = 1.5 },
            }, .{}),
            ui.row(.{ .gap = 0, .cross = .center }, .{
                // Never disabled. Blank is a valid answer to "want a name on
                // it?", and it means the same thing as Skip, so Done takes it
                // and moves on rather than sitting there greyed out while the
                // reader wonders what is wrong with an empty field.
                // Painted by a `.panel`, pressed by the row around it. A
                // `.list_item` given a background draws none, so the first
                // version of this button was white text on the card's own
                // dark surface: present, pressable, and unreadable.
                pressRow(ui, .{
                    .grow = 1,
                    .gap = 0,
                    .on_press = Msg.name_save,
                    .semantics = .{ .role = .button, .label = "Done", .focusable = true },
                }, .{
                    ui.el(.panel, .{
                        .grow = 1,
                        .padding = 0.01,
                        .style = .{ .background = p.accent, .radius = 8 },
                    }, .{
                        ui.row(.{ .height = 32, .cross = .center, .main = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .style = .{ .foreground = p.on_accent } },
                                &.{.{ .text = "Done", .weight = .medium, .scale = menu_scale }},
                            ),
                        }),
                    }),
                }),
                hgap(ui, 12),
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .height = list_row_height,
                    .on_press = Msg.name_skip,
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Skip", .focusable = true },
                }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_muted } },
                        &.{.{ .text = "Skip", .underline = true, .scale = menu_scale }},
                    ),
                }),
            }),
        })),
    }));
}

/// The Edit profile sheet. No mock draws it, so it is the modal-card recipe with
/// three fields; flagged in the PR for review.
///
/// The status line under the fields is the point of the sheet, not decoration: a
/// profile is REPLACEABLE, so saving rewrites the whole thing, and the sheet must
/// be able to say whether it actually has the reader's current profile to rewrite.
fn profileSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const status = model.profile_status();
    return modalScrim(ui, "Edit profile", Msg.close_profile_edit, ui.el(.dialog, .{
        .width = profile_edit_card_width,
        .on_dismiss = Msg.close_profile_edit,
        .semantics = .{ .label = "Edit profile" },
    }, .{
        // The card pads itself. A second 20 inside it was 44 on every side,
        // and those 40 rows were what pushed the buttons off the card.
        modalCard(ui, profile_edit_card_width, ui.column(.{ .grow = 1, .gap = 10 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Edit profile", .weight = .bold, .scale = 1.15 }},
            ),
            // The introduction gives way to whatever else needs the room. Seven
            // fields, three lines of introduction and a two-line status do not fit
            // a window at its minimum height: the button row was drawn below the
            // bottom edge, so Try again and Save could not be pressed in exactly
            // the states that need them. Nor while a picture is being added: the
            // card that takes the field's place is taller than the field.
            if (status.len == 0 and (if (uploads.g_upload) |job| job.target == .note else true))
                profileIntro(ui)
            else
                ui.spacer(0),
            profileField(ui, "Name", model.profile_name(), "A name people will see", .profile_name_edit),
            profileField(ui, "About", model.profile_about(), "A line about you", .profile_about_edit),
            profilePictureField(ui, model, "Picture", model.profile_picture(), .profile_picture_edit, .avatar),
            profilePictureField(ui, model, "Banner", model.profile_banner(), .profile_banner_edit, .banner),
            profileField(ui, "Website", model.profile_website(), "https://", .profile_website_edit),
            // The one with a consequence. `lud16` is how NIP-57 finds somebody's
            // LNURL callback, so an account set up only here could not be zapped
            // by anyone, in any client, until its owner opened something else.
            profileField(ui, "Lightning address", model.profile_lud16(), "you@wallet.example", .profile_lud16_edit),
            profileField(ui, "NIP-05 identifier", model.profile_nip05(), "you@example.com", .profile_nip05_edit),
            if (model.profile_invalid().len > 0)
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.status_warning_text } },
                    &.{.{ .text = model.profile_invalid(), .scale = mono_hint_scale }},
                )
            else
                ui.spacer(0),
            if (uploads.g_profile_upload_unsaved)
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = "The new picture is not published until you press Save.", .scale = mono_hint_scale }},
                )
            else
                ui.spacer(0),
            if (status.len > 0)
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = if (model.profile_stage == .failed) p.status_warning_text else p.text_dim } },
                    &.{.{ .text = status, .scale = mono_hint_scale }},
                )
            else
                ui.spacer(0),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = Msg.close_profile_edit }, "Close"),
                ui.spacer(1),
                if (model.profile_can_retry())
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.profile_retry }, "Try again")
                else
                    ui.spacer(0),
                if (model.profile_can_retry()) hgap(ui, 8) else ui.spacer(0),
                ui.button(.{
                    .size = .sm,
                    .variant = .primary,
                    .disabled = !model.profile_can_save(),
                    .on_press = Msg.profile_save,
                }, if (model.profile_confirm_new) "Publish first profile" else "Save"),
            }),
        })),
    }));
}

fn profileIntro(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = theme.palette.text_faint } },
        &.{.{ .text = "Everything this app can read from a profile, it can now write. Anything else your other clients put there is kept exactly as it is.", .scale = mono_hint_scale }},
    );
}

/// One labelled field in the sheet.
fn profileField(ui: *AppUi, label: []const u8, value: []const u8, placeholder: []const u8, comptime tag: std.meta.Tag(Msg)) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }}),
        vgap(ui, 5),
        ui.el(.textarea, .{
            .text = value,
            .placeholder = placeholder,
            .on_input = AppUi.inputMsg(tag),
            // REQUIRED, and not decoration: a textarea with on_input but no
            // on_submit renders, focuses, advertises set_text, and accepts
            // nothing. It reads as a live field and is inert.
            .on_submit = Msg.profile_save,
            .height = 34,
            .semantics = .{ .label = label },
        }, .{}),
    });
}

/// What people did that was aimed at the reader.
///
/// A plain capped column, deliberately NOT a virtual list. The runtime tracks at
/// most eight virtual windows per build and the app already declares all eight
/// at a full back stack, so a ninth here would be dropped: the list would render
/// once and then stop rebuilding as the reader scrolled, which reads as content
/// that vanishes. A page is capped and replaced rather than appended, which is
/// the same answer the thread reached for the same reason.
fn notificationsSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    var buf: [inbox_cap]InboxItem = undefined;
    resolveInboxBodies();
    const shown = inboxItems(&buf, !model.notifications_everyone);

    // A windowed list, not pages. Paging existed because every row was mounted
    // at once and the whole view is priced against a 1024-node ceiling that
    // refuses a frame WHOLE when crossed, so twenty rows was the arithmetic that
    // fit. A window mounts only what is on screen, which removes the ceiling as
    // a constraint and the pager with it: two hundred notifications are one
    // scroll rather than ten presses of a Next button.
    const options: AppUi.VirtualListOptions = .{
        .id = "notifications",
        .item_count = shown.len,
        .item_extent = 0,
        .extent_estimate = notificationExtentEstimate,
        .extent_context = &shown_ctx,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Notifications list" },
    };
    shown_ctx = .{ .items = shown };
    const window = ui.virtualWindow(options);
    inbox.g_inbox_visible = .{
        .first = @intCast(window.first_visible_index),
        .last = @intCast(window.last_visible_index),
        .len = shown.len,
    };
    // After the window, because it asks on behalf of the rows the window chose.
    wantInboxProfiles(shown);
    const rows = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.spacer(0);
    // Centred ONCE, around the list, never per row. A spacer-column-spacer
    // wrapper on each row is four nodes apiece, and fourteen mounted rows of
    // that is fifty-six nodes spent on horizontal alignment: enough on its own
    // to push this view through the 1024 ceiling that refuses a frame whole.
    for (rows, 0..) |*row, offset| {
        const i = window.start_index + offset;
        row.* = if (i < shown.len) notificationRow(ui, &shown[i]) else ui.spacer(0);
    }

    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Notifications" },
    }, .{
        notificationsHeader(ui),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        notificationsTabs(ui, model),
        if (shown.len == 0) notificationsEmpty(ui, model) else ui.spacer(0),
        ui.row(.{ .grow = 1, .gap = 0 }, .{
            ui.spacer(1),
            // Width only, never grow. In a row, grow claims the remaining
            // horizontal space and beats the fixed width: 620 resolved to 853
            // and ran 153px past the edge of the narrowest allowed window.
            // The row's cross-axis stretch is what gives it its height.
            ui.column(.{ .width = notifications_column_width }, .{
                ui.virtualList(options, window, .{rows}),
            }),
            ui.spacer(1),
        }),
        notificationsFooter(ui, shown.len),
    });
}

/// The rows the notifications window is measuring, so the extent callback can
/// price one without the view handing it a closure.
const NotificationCtx = struct { items: []const InboxItem = &.{} };
var shown_ctx: NotificationCtx = .{};

/// A cheap height for the notification at `index`, from the item alone: the
/// row's chrome plus however many lines its body wraps to.
fn notificationExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const ctx: *const NotificationCtx = @ptrCast(@alignCast(context orelse return 64));
    const i: usize = @intCast(index);
    if (i >= ctx.items.len) return 64;
    const item = &ctx.items[i];
    // 12 padding top and bottom, the name line, the time line, and the body.
    var extent: f32 = 12 * 2 + body_line_height + body_line_height + 6;
    if (warningCovered(item.warned, item.body_key)) {
        extent += cover_notice_height;
    } else if (item.body_len > 0) {
        const per_line: f32 = 58;
        const lines = @max(1.0, @ceil(@as(f32, @floatFromInt(item.body_len)) / per_line));
        extent += lines * body_line_height;
    }
    return extent;
}

/// The reading column for notifications, matching the feed's so a row is the
/// same width whichever screen it is on.
const notifications_column_width: f32 = feed_column_width;
pub const notifications_column_width_for_test = notifications_column_width;

/// How many rows the sheet draws at once.
///
/// This is a NODE budget, not a taste in page sizes. The sheet is stacked over
/// the feed rather than replacing it, because the feed's scroll offset lives in
/// its mounted list, so both trees are priced against the same 1024-node view
/// ceiling and a view past it is refused WHOLE: no frame at all, a window that
/// stops updating. The base costs about 413 nodes on the feed and about 573 over
/// a full back stack, the sheet's own chrome about 40, and a row eleven. Twenty
/// rows is 832 in the worst case, which leaves real margin rather than the nine
/// nodes the first arithmetic here left.
///
/// Pages REPLACE rather than accumulate, so this is the cost whether the reader
/// holds five notifications or two hundred, and all two hundred are reachable
/// instead of the first forty-eight.
///
/// Twenty, until the verb row under a note grew from four glyphs to six and the
/// base under this sheet grew with it. That is what this number IS: a budget,
/// not a taste in page sizes, and a budget whose inputs moved. Measured rather
/// than estimated this time, over every frame the app can draw: at twenty this
/// sheet over the deepest thread came to 922 of 1024, which is inside the
/// ceiling and outside the tenth of it the suite insists stays free.
pub const inbox_page = 16;

fn notificationsHeader(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 10, .height = 38, .padding = 0.01 }, .{
            hgap(ui, 10),
            // A page needs a way out. As a sheet this had the scrim to press and
            // Escape to dismiss; an opaque level has neither, so closing it was
            // the bell in a rail the page was covering.
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = list_row_height,
                .cross = .center,
                .on_press = Msg.close_notifications,
                .style = .{ .radius = 6, .quiet_hover = true },
                .semantics = .{ .role = .button, .label = "Back", .focusable = true },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 6),
                    ui.icon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
                    hgap(ui, 4),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "Back", .scale = stat_scale }}),
                    hgap(ui, 8),
                    vgap(ui, 26),
                }),
            }),
            hgap(ui, 4),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Notifications", .weight = .bold, .scale = settings_title_scale }},
            ),
            ui.spacer(1),
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = 20,
                .cross = .center,
                .on_press = Msg.notifications_read_all,
                .style = .{ .radius = 4 },
                .semantics = .{ .role = .button, .label = "Mark all read", .focusable = true },
            }, .{
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "Mark all read", .scale = status_scale }}),
            }),
            hgap(ui, 14),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

/// Two tabs, and the reason there are two: an inbox is the one surface where a
/// stranger decides what the reader sees, so the default holds only people they
/// already read.
fn notificationsTabs(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.row(.{ .cross = .center, .gap = 6, .padding = 0.01 }, .{
        hgap(ui, 14),
        vgap(ui, 42),
        profileTabFocused(ui, "Everyone", model.notifications_everyone, Msg{ .notifications_tab = 1 }, true),
        profileTab(ui, "People you follow", !model.notifications_everyone, Msg{ .notifications_tab = 0 }),
        ui.spacer(1),
    });
}

fn notificationsEmpty(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const text: []const u8 = if (model.notifications_everyone)
        "Nothing yet. When somebody replies, mentions, likes, reposts or zaps you, it lands here."
    else
        "Nothing from the people you follow yet. Everyone is in the other tab.";
    return ui.row(.{ .gap = 0, .padding = 14 }, .{
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
    });
}

fn notificationsFooter(ui: *AppUi, count: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
        ui.row(.{ .cross = .center, .gap = 0, .height = 30, .padding = 0.01 }, .{
            hgap(ui, 14),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = ui.fmt("{d} here", .{count}), .monospace = true, .scale = mono_meta_scale }},
            ),
            ui.spacer(1),
            // Said plainly, because it is a real limitation rather than a
            // detail: another client will not know what has been read here.
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "read state stays on this Mac", .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 14),
        }),
    });
}

/// How long ago this landed, in the app's one spelling of it.
fn inboxAge(ui: *AppUi, created_at: i64) []const u8 {
    var buf: [16]u8 = undefined;
    const written = Note.ageInto(&buf, created_at, nowSeconds()) catch return "";
    return ui.arena.dupe(u8, written) catch "";
}

/// One thing somebody did.
/// A notification's words as spans: styled the way the feed styles a note, and
/// carrying no link payloads.
///
/// The row is drawn from a copy the sheet made on its own stack (`inboxItems`
/// into a local buffer). A paragraph copies its span text into the frame, but
/// not a span's `link`: the runtime copies that after the view has returned,
/// when the stack it pointed into is gone. And this paragraph has no link
/// handler, so a payload pressed nothing anyway. A press anywhere on the row
/// opens the note.
fn inboxBodySpans(ui: *AppUi, body: []const u8, mentions: []const MentionRef) []const canvas.TextSpan {
    const styled = contentSpansIn(ui, body, mentions, 0);
    const spans = ui.arena.dupe(canvas.TextSpan, styled) catch return &.{};
    for (spans) |*span| span.link = "";
    return spans;
}

fn notificationRow(ui: *AppUi, item: *const InboxItem) AppUi.Node {
    const p = theme.palette;
    const read = item.created_at <= inboxReadThrough();
    const glyph: []const u8 = switch (item.verb) {
        .reply, .mention => "reply",
        .like => "like",
        .repost => "repeat",
        .zap => "zap",
    };
    const tint = switch (item.verb) {
        .zap => p.status_warning,
        .repost => p.status_success,
        .like => p.status_like,
        else => p.text_muted_alt,
    };
    // A reply says only the name. "replied to you" above a row that already
    // shows their reply is the same fact twice.
    const verb_text: []const u8 = switch (item.verb) {
        .reply => "",
        .mention => "mentioned you in a note",
        .like => "reacted to your note",
        .repost => "reposted your note",
        .zap => "zapped your note",
    };
    const body = item.body();
    const emoji = item.reactionGlyph();
    const open: Msg = if (item.hasTarget()) Msg{ .open_event = item.target_id } else Msg{ .open_person = item.author };

    // Name, verb and amount are SPANS of one paragraph, not three paragraphs.
    // The row is priced in widget nodes against a per-view ceiling that refuses
    // the whole screen when crossed, and the first cut of this row spent five
    // extra nodes apiece on things that are only text: twenty rows of that put
    // the notifications view at 924 against a ceiling of 1024 with 102 that has
    // to stay free. Spans cost nothing.
    var head: [3]canvas.TextSpan = undefined;
    var head_len: usize = 0;
    head[head_len] = .{ .text = personName(ui, item.author), .weight = .medium, .scale = nested_meta_scale };
    head_len += 1;
    if (verb_text.len > 0) {
        head[head_len] = .{ .text = ui.fmt(" {s}", .{verb_text}), .scale = nested_meta_scale };
        head_len += 1;
    }
    if (item.verb == .zap and item.msat > 0) {
        head[head_len] = .{ .text = ui.fmt("  {d} sats", .{item.msat / 1000}), .weight = .medium, .scale = nested_meta_scale };
        head_len += 1;
    }

    // Built by hand rather than with an `else ui.spacer(0)` per optional child,
    // because an empty spacer is still a node and this row has three of them.
    var kids: [3]AppUi.Node = undefined;
    var kids_len: usize = 0;
    kids[kids_len] = ui.el(.list_item, .{
        .padding = 0.01,
        .height = list_row_height,
        .on_press = Msg{ .open_person = item.author },
        .style = .{ .radius = 4, .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
    }, .{
        ui.paragraph(.{ .style = .{ .foreground = p.text_body_soft } }, head[0..head_len]),
    });
    kids_len += 1;
    if (warningCovered(item.warned, item.body_key)) {
        // The note's words are covered, so the row says so in their place, and
        // the chip uncovers them without leaving the list.
        kids[kids_len] = coverNotice(ui, item.warning_buf[0..item.warning_len], item.body_key);
        kids_len += 1;
    } else if (body.len > 0) {
        // Theirs for a reply, yours for everything else, and dimmer when it is
        // yours: you wrote it, so the new fact is who did what to it.
        const own = item.verb != .reply and item.verb != .mention;
        // Two lines and stop, cut in the spans before layout because the SDK
        // has no multi-line clamp. The same rule an ancestor's body follows, so
        // a long note cannot turn one notification into half a screen.
        // The words were rendered when the row was admitted (`bakeInboxBody`),
        // the way the feed renders a note, so a `nostr:npub…` is already a name
        // here and a `nostr:nevent…` is already a short label. What is left to
        // do is mark the names, from the offsets that bake recorded.
        const spans = clampSpansToLines(ui, inboxBodySpans(ui, body, item.mentions.all()), notification_body_lines);
        kids[kids_len] = ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = if (own) p.text_muted_alt else p.text_body } },
            spans,
        );
        kids_len += 1;
    }
    // What the row itself opens, as a stop the keyboard can reach. The row's
    // paragraphs wrap, and the toolkit measures a wrapping paragraph correctly
    // only inside a `row` or `data_row`, so the row stays one and cannot take
    // the focus ring itself. The age sits under the text and is one line, which
    // a list row measures correctly.
    //
    // Only when the row opens a note. A mention that answers nothing has no
    // target, so the row opens the person, and the name above is already that
    // stop: a third one to the same profile, called "Open note", would say the
    // wrong thing about where it goes.
    const opens_note = item.hasTarget();
    kids[kids_len] = pressRow(ui, .{
        .padding = 0.01,
        .height = notification_age_height,
        .on_press = if (opens_note) open else null,
        .style = .{ .radius = 4, .quiet_hover = true },
        .semantics = if (opens_note) .{ .role = .button, .label = "Open note", .focusable = true } else .{},
    }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = inboxAge(ui, item.created_at), .monospace = true, .scale = mono_meta_scale }},
        ),
    });
    kids_len += 1;

    return ui.column(.{ .gap = 0 }, .{
        ui.el(.data_row, .{
            .padding = 12,
            .gap = 10,
            // Top aligned: the row is several lines now, and a gutter glyph
            // floating beside the middle of a paragraph belongs to nothing.
            .cross = .start,
            // `open_event`, never `open_thread`. The thread route resolves an id
            // against the LOADED FEED, which is scoped to follows and holds at
            // most a few hundred notes; what a notification points at is almost
            // always an older note of the reader's own, or a stranger's note the
            // feed would never carry. So the obvious route made the common press
            // a silent no-op. This one asks the store by name.
            .on_press = open,
            .style = .{ .quiet_hover = true },
            .semantics = .{ .role = .button, .label = if (verb_text.len > 0) verb_text else "replied to you" },
        }, .{
            // The unread dot holds its width either way, so a row does not shift
            // sideways the moment it is read.
            ui.el(.panel, .{
                .width = 6,
                .height = 6,
                .padding = 0.01,
                .style = .{
                    .background = if (read) p.surface_window else p.accent,
                    .border = if (read) p.surface_window else p.accent,
                    .radius = 3,
                    .stroke_width = 0,
                },
            }, .{}),
            // Glyph and face together, centred against EACH OTHER, and that pair
            // top-aligned against the text. The row's own `.cross = .start` is
            // right for the avatar, which should hang beside the name and the
            // first line of the body, and wrong for a 14pt glyph, which then
            // floated at the very top with nothing beside it.
            ui.row(.{ .cross = .center, .gap = 10 }, .{
                // The reaction they actually sent, where a generic heart used to
                // be. A shortcode with no image would print as `:shakingeyes:`,
                // so only something short enough to read as a glyph is drawn.
                if (item.verb == .like and emoji.len > 0 and emoji.len <= 8)
                    ui.paragraph(.{ .style = .{ .foreground = p.text_body } }, &.{.{ .text = emoji, .scale = nested_meta_scale }})
                else
                    ui.appIcon(.{ .width = 14, .height = 14, .style = .{ .foreground = tint } }, glyph),
                // The face and the name go to the person, everything else goes
                // to the note. That is what the feed does and what Jumble does,
                // and without it the one thing a notification is most likely to
                // make you want (who IS this) was the one thing you could not
                // press.
                ui.el(.list_item, .{
                    .padding = 0.01,
                    .on_press = Msg{ .open_person = item.author },
                    .style = .{ .radius = 999, .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
                }, .{
                    personAvatar(ui, item.author, nested_avatar_size),
                }),
            }),
            ui.column(.{ .gap = 3, .grow = 1 }, kids[0..kids_len]),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

/// A small confirming toast, bottom center, retired by the tick.
fn toastOverlay(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .padding = 24 }, .{
        ui.row(.{ .padding = 10, .style = .{ .background = p.surface_toast, .border = p.border_modal, .radius = 10, .stroke_width = 1 } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_body } }, model.toast_text()),
        }),
    });
}

fn joinSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    return modalScrim(ui, "Join", .close_join, ui.el(.dialog, .{
        .width = join_sheet_width,
        .on_dismiss = .close_join,
        .semantics = .{ .label = "Join" },
    }, .{
        if (model.bunker_mode) bunkerCard(ui, model) else joinLadderCard(ui, model),
    }));
}

/// The width of the search sheet. The dialog and the card inside it share the
/// one number, for the reason `join_sheet_width` gives.
const search_sheet_width: f32 = 520;
/// How tall the results are before they scroll.
const search_results_height: f32 = 280;
/// The empty field's box, and what one relay's line costs under the list.
const search_empty_height: f32 = 140;
const search_relay_line_height: f32 = 19;
/// What a line of text in the card may span: the card less its padding. Wrapped
/// text is given this as a definite width because a leaf measures one line at
/// its natural width otherwise. The body is also given a definite HEIGHT, below,
/// because the card is sized from its content and wrapped text is not counted at
/// its wrapped height: the last control ran 16pt out of the bottom of the card.
/// A fixed body also means the sheet does not change size as results arrive.
const search_sheet_inner: f32 = search_sheet_width - 48;
/// Characters the second line of a row may spend on each of its two parts.
const search_identity_max = 24;
const search_source_max = 44;

/// The field that finds a person and takes an address.
///
/// It began as the place to paste an address (Plaza could put one on the
/// clipboard and had no way to take one back), and it is also where somebody
/// says who they mean. One field does both because the two never collide: a
/// string that starts `npub1` or has an `@` between two names is an address, and
/// anything else is a name. What Enter will do is said on the button, so the
/// reader is never guessing which of the two they have got.
fn addressSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const kind = classifySearch(model.address_draft());
    return modalScrim(ui, "Search", .close_address, ui.el(.dialog, .{
        .width = search_sheet_width,
        .on_dismiss = .close_address,
        .semantics = .{ .label = "Search" },
    }, .{
        modalCard(ui, search_sheet_width, ui.column(.{ .gap = 12 }, .{
            ui.row(.{ .cross = .center, .gap = 6 }, .{
                backControl(ui, "Back", .close_address),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = "Search", .weight = .bold, .scale = 1.3 }},
                ),
            }),
            ui.el(.textarea, .{
                .text = model.address_draft(),
                .placeholder = "A name, an npub or nprofile, name@domain, or a link",
                .on_input = AppUi.inputMsg(.address_edit),
                .autofocus = true,
                .on_submit = .address_submit,
                // Enter submits, as it does in every search box. Shift+Enter is
                // the newline, which nothing here has any use for. A pasted
                // address is long enough to wrap, so the field holds two lines.
                .submit_on_enter = true,
                .height = 56,
                .semantics = .{ .label = "Search" },
            }, .{}),
            // The refusal replaces the hint rather than sitting under it: two
            // lines where one is stale reads as the app disagreeing with itself.
            if (model.address_status().len > 0)
                ui.text(
                    .{ .size = .sm, .wrap = true, .style = .{ .foreground = if (model.address_error == .none) p.text_muted else p.status_warning_text } },
                    model.address_status(),
                )
            else
                ui.spacer(0),
            searchBody(ui, kind),
            ui.button(.{ .variant = .primary, .disabled = model.address_empty() or kind == .key, .on_press = .address_submit }, model.address_action()),
            vgap(ui, 5),
        })),
    }));
}

/// Everything between the field and its button: what to do with an empty field,
/// or the people found and the relays that were asked.
fn searchBody(ui: *AppUi, kind: SearchInput) AppUi.Node {
    const p = theme.palette;
    if (kind == .blank) return ui.column(.{ .height = search_empty_height }, .{searchEmpty(ui)});
    // An address is opened, not searched for, so there is nothing to list, and
    // a key is not searched for at all.
    if (kind == .address or kind == .key) return ui.spacer(0);

    const rows = people_search.g_search_rows[0..people_search.g_search_len];
    var nodes: [search_rows_max + 2]AppUi.Node = undefined;
    var n: usize = 0;
    var locals: usize = 0;
    for (rows) |r| {
        if (r.local) locals += 1;
    }
    if (locals > 0) {
        nodes[n] = searchSectionLabel(ui, ui.fmt("ON THIS DEVICE  {d}", .{locals}));
        n += 1;
        for (rows) |*r| {
            if (!r.local) continue;
            nodes[n] = searchRow(ui, r);
            n += 1;
        }
    }
    if (rows.len > locals) {
        nodes[n] = searchSectionLabel(ui, ui.fmt("FROM SEARCH RELAYS  {d}", .{rows.len - locals}));
        n += 1;
        for (rows) |*r| {
            if (r.local) continue;
            nodes[n] = searchRow(ui, r);
            n += 1;
        }
    }
    // Boxed to the list's own height, so the relays keep their place under it
    // whether or not anybody has turned up.
    const results: AppUi.Node = if (rows.len == 0)
        ui.column(.{ .height = if (kind == .nip05) 0 else search_results_height }, .{
            ui.paragraph(
                .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = searchNothingYet(kind), .scale = mono_hint_scale }},
            ),
        })
    else
        ui.scroll(.{ .height = search_results_height }, .{ui.column(.{ .gap = 2 }, .{nodes[0..n]})});
    // The relays are only worth naming when a name is being searched for: for a
    // NIP-05 address they are not the ones being asked.
    // Nothing to list and no relays to name: the line alone, not a tall empty box.
    if (kind == .nip05 and rows.len == 0) return results;
    const relay_lines: f32 = @floatFromInt(searchRelays().len);
    const height = search_results_height + if (kind == .term) 18 + relay_lines * search_relay_line_height else 0;
    return ui.column(.{ .height = height, .gap = 10 }, .{
        results,
        if (kind == .term) searchRelayLines(ui) else ui.spacer(0),
    });
}

/// What the list says when it has nothing in it, which depends on whether the
/// relays have been heard from.
fn searchNothingYet(kind: SearchInput) []const u8 {
    // An address is asked of its domain; the search relays are not part of it.
    if (kind == .nip05) return "No one on this device has that address.";
    var asking = false;
    var answered = false;
    for (searchRelays(), 0..) |_, i| {
        switch (searchRelayStatus(i).state) {
            .asking => asking = true,
            .answered, .declined, .unreachable_, .silent => answered = true,
            else => {},
        }
    }
    if (asking) return "No one on this device matches. Asking the search relays.";
    if (answered) return "No one on this device matches, and the search relays found no one.";
    return "No one on this device matches. The search relays are asked once you stop typing.";
}

fn searchSectionLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    return ui.paragraph(.{ .style = .{ .foreground = theme.palette.text_label } }, &.{.{ .text = text, .monospace = true, .scale = mono_meta_scale }});
}

/// The empty field: what it takes, and where a name goes when it is searched for.
fn searchEmpty(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const relays = searchRelays();
    var hosts: [search.relays_max][]const u8 = undefined;
    for (relays, 0..) |url, i| hosts[i] = relayShortName(url);
    return ui.column(.{ .gap = 8 }, .{
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_body } },
            &.{.{ .text = "Type a name to look through the profiles on this device. Nothing leaves it until you stop typing.", .scale = menu_scale }},
        ),
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = "An npub, an nprofile, name@domain or a link to a note or a place goes straight there.", .scale = menu_scale }},
        ),
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = ui.fmt("Then the search relays are asked for the name: {s}.", .{joinStrings(ui, hosts[0..relays.len], ", ")}), .scale = mono_hint_scale }},
        ),
    });
}

fn joinStrings(ui: *AppUi, parts: []const []const u8, sep: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) out.appendSlice(ui.arena, sep) catch return "";
        out.appendSlice(ui.arena, part) catch return "";
    }
    return out.items;
}

/// One line per search relay, so a relay that found no one is named rather than
/// absent, and one that could not be reached says that instead.
fn searchRelayLines(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const urls = searchRelays();
    var lines: [search.relays_max]AppUi.Node = undefined;
    for (urls, 0..) |url, i| {
        const st = searchRelayStatus(i);
        var buf: [32]u8 = undefined;
        const said = search.describe(&buf, st.state, st.count);
        const ink = switch (st.state) {
            .answered => if (st.count > 0) p.text_body_strong else p.text_muted,
            .unreachable_, .declined, .silent => p.status_warning_text,
            else => p.text_dim,
        };
        lines[i] = ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = relayShortName(url), .monospace = true, .scale = mono_meta_scale }}),
            ui.spacer(1),
            ui.paragraph(.{ .style = .{ .foreground = ink } }, &.{.{ .text = ui.fmt("{s}", .{said}), .monospace = true, .scale = mono_meta_scale }}),
        });
    }
    return ui.column(.{ .gap = 3 }, .{
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
        lines[0..urls.len],
    });
}

/// Where a result came from, in words: this machine, and each relay that named
/// them. Long lists give the first and a count, so the line stays on its row.
fn searchSourceText(ui: *AppUi, row: *const SearchRow) []const u8 {
    var parts: [search.relays_max + 1][]const u8 = undefined;
    var n: usize = 0;
    if (row.local) {
        parts[n] = "this device";
        n += 1;
    }
    for (searchRelays(), 0..) |url, i| {
        if (i >= search.relays_max) break;
        if (row.relays & (@as(u8, 1) << @intCast(i)) == 0) continue;
        parts[n] = relayShortName(url);
        n += 1;
    }
    const whole = joinStrings(ui, parts[0..n], ", ");
    if (whole.len <= search_source_max or n < 2) return whole;
    return ui.fmt("{s} +{d}", .{ parts[0], n - 1 });
}

/// One person in the results: the name, what they are called elsewhere, and
/// where this machine heard of them.
fn searchRow(ui: *AppUi, row: *const SearchRow) AppUi.Node {
    const p = theme.palette;
    const pk = row.pubkey;
    const prof = lookupProfile(pk);
    const name = if (prof) |pr| (if (pr.name_len > 0) pr.name() else "") else "";
    const shown = if (name.len > 0) name else personNpubShort(ui, pk);
    const verified = if (prof) |pr| pr.nip05_state == .verified else false;
    // The address only once it has been checked, as everywhere else in the app:
    // one nobody has confirmed is a claim, not a credential. The exception is
    // an address the term matched, shown plainly so a row is never a mystery
    // about why it is in the list.
    const identity: []const u8 = blk: {
        const pr = prof orelse break :blk "";
        if (verified) break :blk pr.nip05();
        if (pr.nip05_len > 0 and search.quality(pr.nip05(), people_search.g_search_term[0..people_search.g_search_term_len]) != null) break :blk pr.nip05();
        if (pr.username_len > 0) break :blk ui.fmt("@{s}", .{pr.username()});
        break :blk "";
    };
    const tint = avatarTint(pk);
    const hexdigits = "0123456789abcdef";

    // Built as slices so a line with nothing to say costs no node.
    var name_line: [2]AppUi.Node = undefined;
    var name_n: usize = 1;
    name_line[0] = ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = elide(ui, shown, 40), .weight = .medium, .scale = menu_scale }});
    if (verified) {
        name_line[1] = ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle");
        name_n = 2;
    }
    var second: [2]AppUi.Node = undefined;
    var second_n: usize = 0;
    if (identity.len > 0) {
        second[second_n] = ui.paragraph(.{ .style = .{ .foreground = identityInk() } }, &.{.{ .text = elide(ui, identity, search_identity_max), .scale = mono_row_scale }});
        second_n += 1;
    }
    second[second_n] = ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = searchSourceText(ui, row), .monospace = true, .scale = mono_chip_scale }});
    second_n += 1;

    return ui.el(.list_item, .{
        .padding = 6,
        .gap = 10,
        .cross = .center,
        .on_press = Msg{ .search_pick = pk },
        .style = .{ .radius = 8, .quiet_hover = true },
        .semantics = .{ .role = .button, .label = shown, .focusable = true },
    }, .{
        ui.avatar(.{
            .image = 0,
            .width = 30,
            .height = 30,
            .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
        }, ui.fmt("{c}{c}", .{ hexdigits[pk[0] >> 4], hexdigits[pk[0] & 0x0f] })),
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.row(.{ .cross = .center, .gap = 5 }, .{name_line[0..name_n]}),
            ui.row(.{ .cross = .center, .gap = 8 }, .{second[0..second_n]}),
        }),
    });
}

/// Why the sheet appeared, in the reader's own terms: the thing they reached for
/// is waiting, and named where naming it is possible.
///
/// A note that has scrolled out of the loaded window falls back to the plain
/// sentence rather than guessing, and a person whose kind:0 has not arrived reads
/// as their short npub, which is what every other surface in the app calls them
/// until it knows better.
fn pendingText(ui: *AppUi, model: *const Model) []const u8 {
    return switch (model.pending) {
        .none => "",
        .post => "Your note is waiting.",
        .reply => "Your reply is waiting.",
        // Clipped, because a display name is a stranger's string with no length
        // in it and no alphabet either. The pill wraps as well (see intentPill):
        // a codepoint cap bounds COUNT, not WIDTH, and fourteen full-width CJK
        // characters are about twice fourteen Latin ones, so the clip alone still
        // overran the card in some scripts.
        .like => |id| if (model.noteById(id)) |note|
            std.fmt.allocPrint(ui.arena, "Your like on {s}'s note is waiting.", .{personLabel(ui, note.author())}) catch "Your like is waiting."
        else
            "Your like is waiting.",
        .repost => |id| if (model.noteById(id)) |note|
            std.fmt.allocPrint(ui.arena, "Your repost of {s}'s note is waiting.", .{personLabel(ui, note.author())}) catch "Your repost is waiting."
        else
            "Your repost is waiting.",
        .follow => |pk| std.fmt.allocPrint(ui.arena, "Following {s} is waiting.", .{personLabel(ui, personName(ui, pk))}) catch "Your follow is waiting.",
    };
}

/// A person's name, short enough for one line of a pill.
///
/// The npub fallback is passed through UNCLIPPED. It is already an abbreviation,
/// `npub1abcdefghi…wxyz5`, and its whole job is the tail: clipping it to fourteen
/// codepoints ate three of the five identifying characters at the end and left
/// something that looks specific and is not.
fn personLabel(ui: *AppUi, name: []const u8) []const u8 {
    _ = ui;
    // The abbreviated npub carries an ellipsis, and it is the only thing in this
    // app that does. Substring, not scalar: the character is three bytes.
    if (std.mem.indexOf(u8, name, "…") != null) return name;
    return clipToChars(name, 14, 48);
}

/// The glyph for the verb that opened the sheet: the reader sees what they
/// reached for before they read a word.
///
/// A switch rather than a name looked up from a table, because both icon
/// builders take their name at COMPTIME (that is what compile-checks it), so a
/// glyph chosen at runtime has to be chosen as a whole node.
fn pendingGlyph(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const size = 11;
    return switch (model.pending) {
        .none, .post => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "edit"),
        .reply => ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "reply"),
        .like => ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = p.status_like } }, "like"),
        .repost => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.status_success } }, "repeat"),
        .follow => ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = p.text_muted } }, "plus"),
    };
}

/// What the reader reached for, as a pill above the question.
fn intentPill(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{ .background = p.surface_chip, .border = p.border_hairline, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 10),
                vgap(ui, 22),
                pendingGlyph(ui, model),
                hgap(ui, 6),
                // Bounded AND wrapping. `wrap` on its own does nothing to a
                // paragraph that is a plain flow child of a row (it takes its
                // intrinsic width and lays out past the card), and a clip on its
                // own bounds characters rather than pixels. Both, so no name in
                // any script can push this line out of the sheet.
                ui.column(.{ .grow = 1, .gap = 0 }, .{
                    ui.paragraph(
                        .{ .wrap = true, .style = .{ .foreground = p.text_muted_alt } },
                        &.{.{ .text = model.pending_text(ui), .scale = join_sub_scale }},
                    ),
                }),
                hgap(ui, 10),
            }),
        }),
        // The pill is as wide as its words and no wider, so the row it sits in
        // takes the slack rather than the pill stretching across the card.
        ui.spacer(1),
    });
}

/// One rung of the ladder: a glyph, what it is, and what it costs you.
///
/// `filled` is the recommended one, and there is exactly one. The other two are
/// outlines with a chevron, which is the shape this app uses everywhere else for
/// "this leads somewhere".
///
/// A null `press` is a rung this install cannot climb (see `keyholderMissing`).
/// It keeps the card's geometry so the ladder does not jump, and gives up
/// everything that says "press me": the accent fill, the chevron, the button
/// role, the focus stop. A rung that looks identical and does nothing is the
/// exact failure this whole change is about, so it must not merely stop working,
/// it has to stop LOOKING like it works.
fn joinCard(ui: *AppUi, comptime glyph: []const u8, comptime app: bool, title: []const u8, sub: []const u8, press: ?Msg, filled: bool) AppUi.Node {
    const p = theme.palette;
    const live = press != null;
    const ink = if (filled) p.on_accent else if (live) p.text_body_strong else p.text_muted;
    const sub_ink = if (filled) p.text_dim_on_light else p.text_muted;
    // The press is on the ROW and the paint is on a `.panel` inside it. A
    // `.list_item` carrying a background draws nothing at all (the same rule
    // `modalCard` is built around), so the first version of this card had the
    // recommended rung rendering as invisible white-on-black text.
    return pressRow(ui, .{
        .gap = 0,
        .on_press = press,
        .semantics = .{ .role = if (live) .button else .text, .label = title, .focusable = live },
    }, .{
        ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{
                .background = if (filled) p.accent else p.surface_card,
                .border = if (filled) p.accent else p.border_control,
                .radius = 11,
                .stroke_width = 1,
            },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 13),
                if (app)
                    ui.appIcon(.{ .width = 16, .height = 16, .style = .{ .foreground = ink } }, glyph)
                else
                    ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = ink } }, glyph),
                hgap(ui, 11),
                ui.column(.{ .grow = 1, .gap = 0 }, .{
                    vgap(ui, 11),
                    ui.paragraph(
                        .{ .style = .{ .foreground = ink } },
                        &.{.{ .text = title, .weight = .medium, .scale = join_card_title_scale }},
                    ),
                    vgap(ui, 3),
                    ui.paragraph(
                        .{ .wrap = true, .style = .{ .foreground = sub_ink } },
                        &.{.{ .text = sub, .scale = join_card_sub_scale }},
                    ),
                    vgap(ui, 11),
                }),
                hgap(ui, 11),
                // Only on the rungs that lead to another step. The filled card
                // finishes here: pressing it makes a key. A dead rung leads
                // nowhere at all, so it gets no chevron either.
                if (filled or !live) ui.spacer(0) else ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "chevron-right"),
                hgap(ui, 13),
            }),
        }),
    });
}

/// The mono section labels over each half of the ladder.
fn joinLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.paragraph(
        .{ .style = .{ .foreground = p.text_faint_alt } },
        &.{.{ .text = text, .monospace = true, .weight = .medium, .scale = join_label_scale }},
    );
}

/// The shared modal card: the SDK `.card` element paints the rounded, bordered
/// surface (a plain column does not paint its background at all), holding a
/// single content column so the sheet reads as a raised, bordered panel.
///
/// The press it absorbs is load-bearing, not decoration: the sheet around it is
/// a full-window dialog that closes when pressed, and a `.card` claims no press
/// of its own, so without this a click on the sheet's own background walks past
/// the card to the dialog and closes the sheet mid-use. See `Msg.absorb_press`.
/// The full-window dim behind a modal, and the press target that closes it.
///
/// The SDK owns where a `.dialog` sits: since 0.9.2 a dialog, drawer or sheet is
/// placed against the ROOT surface and centred there, its proposed frame
/// discarded, so `.grow = 1` on one does nothing at all. Plaza used to be the
/// dialog AND the backdrop in one element, which meant the upgrade quietly
/// shrank every scrim to a 420pt box: the dim stopped covering the window and a
/// press outside that box stopped closing anything.
///
/// So the two jobs are two elements now. This is the backdrop: a plain panel
/// that fills the window, carries the dim, and closes on a press. The `.dialog`
/// goes inside it and is nothing but the card, which is the shape the SDK's own
/// examples use.
///
/// `.grow = 1` here is belt and braces and I checked: removing it keeps every
/// test green, because the layer stack these sheets are mounted in stretches its
/// children anyway. It stays because a backdrop that only fills the window when
/// its parent happens to stretch it is one reparenting away from the bug this
/// function exists to fix. The dismiss press is the part a probe does catch.
fn modalScrim(ui: *AppUi, label: []const u8, dismiss: Msg, child: AppUi.Node) AppUi.Node {
    return ui.el(.panel, .{
        .grow = 1,
        .on_press = dismiss,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = label },
    }, .{child});
}

/// What a `.card` insets its content by on every side.
const modal_card_padding: f32 = 24;

fn modalCard(ui: *AppUi, width: f32, inner: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.card, .{
        .width = width,
        .on_press = Msg.absorb_press,
        .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 },
    }, .{inner});
}

fn joinHeading(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .style = .{ .foreground = theme.palette.text_primary } },
        &.{.{ .text = "How do you want to join?", .weight = .bold, .scale = join_title_scale }},
    );
}

fn joinSubheading(ui: *AppUi) AppUi.Node {
    return ui.paragraph(
        .{ .wrap = true, .style = .{ .foreground = theme.palette.text_muted } },
        &.{.{ .text = "Everything here is signed with a key of your own, not an account someone holds for you.", .scale = join_sub_scale }},
    );
}

/// The join ladder: three ways in, most confident first, always the way back.
fn joinLadderCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Gaps, not hand-placed spacers, and the card's own padding rather than a
    // second one inside it. The sheet used to inset itself with a vgap/hgap
    // frame around a gap:0 column, so every space in it was a separate number
    // nobody could see next to its neighbours: 16, 6, 13, 6, 7, 13, 8, 13, 16.
    //
    // It then had `.padding = 20` on top of the `.card`'s own 24, which is a
    // 44pt inset on a 420pt sheet, and `.grow = 1` stretched the column past
    // what its children needed so the last row overflowed 18pt into the bottom
    // padding: 50pt of air above the title and 26 below the way out. The card
    // pads itself; this column only says how far apart its groups sit.
    return modalCard(ui, join_sheet_width, ui.column(.{ .gap = 16 }, .{
        // Two shapes rather than one with a `spacer(0)` in it. A zero-size
        // child is still a child, so the gap above it was paid whether or not
        // there was a pill to separate: 6pt of air on top of the card's own
        // padding, which is why the title sat lower than the rungs sat left.
        if (model.pending.waiting())
            ui.column(.{ .gap = 6 }, .{
                intentPill(ui, model),
                joinHeading(ui),
                joinSubheading(ui),
            })
        else
            ui.column(.{ .gap = 6 }, .{
                joinHeading(ui),
                joinSubheading(ui),
            }),
        ui.column(.{ .gap = 8 }, .{
            joinLabel(ui, "NEW HERE"),
            // Making a key means the keyholder daemon making it, so with no
            // keyholder installed there is no route to a new identity at all:
            // this rung is not degraded, it is impossible. Say that, and say
            // what fixes it, rather than leaving the app's primary call to
            // action sitting there swallowing presses.
            //
            // The WHY goes under the card, not in it. A rung's subtitle is one
            // line: the row that holds it centres a column it has already been
            // sized against, so a subtitle that wraps to three lines runs past
            // the card's own bottom edge and paints the last line half outside
            // it. The tree cannot see that and every structural assertion
            // passed over it. Only the frames say so. Down here it is a plain
            // flow child, where wrapping is bounded and behaves.
            if (keyholderMissing())
                joinCard(ui, "plus", false, "Create your identity", "Not possible in this copy of Plaza.", null, false)
            else
                joinCard(ui, "plus", false, "Create your identity", "Ready in seconds. Nothing to write down.", .join_create, true),
            if (keyholderMissing())
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                    &.{.{ .text = "Notary, the part of Plaza that holds your key, is missing from this install, so Plaza cannot make one. Reinstalling Plaza fixes it.", .scale = join_card_sub_scale }},
                )
            else
                ui.spacer(0),
        }),
        ui.column(.{ .gap = 8 }, .{
            joinLabel(ui, "ALREADY ON NOSTR"),
            // With no keyholder there is nowhere for a key to go, and this rung
            // says so instead of offering a field.
            //
            // It used to fall back to pasting into Plaza, and the subtitle said
            // so honestly. That fallback is gone: Plaza has no field that can
            // hold a secret key, so the rung led to a screen that refuses every
            // key it is given. A dead end with an encouraging label on it is
            // worse than a disabled rung.
            if (keyholderMissing())
                joinCard(ui, "download", false, "Bring your key", "Not possible in this copy of Plaza.", null, false)
            else
                joinCard(ui, "download", false, "Bring your key", "Opens Notary. Plaza itself never sees it.", .open_notary_import, false),
            // The other answer to the same question, and the one that stays
            // here: your key is somewhere else already, so nothing has to move.
            joinCard(ui, "notary", true, "Use your own signer", "Already have one? Paste its bunker link.", .open_bunker, false),
        }),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.el(.list_item, .{
                .padding = 0.01,
                .height = list_row_height,
                .on_press = Msg.close_join,
                .style = .{ .quiet_hover = true },
                .autofocus = true,
                .semantics = .{ .role = .button, .label = "Keep browsing", .focusable = true },
            }, .{
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_secondary } },
                    &.{.{ .text = "Keep browsing", .weight = .medium, .underline = true, .scale = menu_scale }},
                ),
            }),
            ui.spacer(1),
        }),
        // The way out is a list item, which carries its own slack for the press
        // target, and that slack is not padding: it left the underline sitting
        // 6pt off the card's edge while every other side had 24. This is the
        // difference, measured from a screenshot rather than guessed.
        vgap(ui, 2),
    }));
}

/// The focused bunker step: the user already chose to use their own signer, so
/// this is one field, not the whole ladder again. Paste the link, connect.
fn bunkerCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalCard(ui, join_sheet_width, ui.column(.{ .gap = 12 }, .{
        ui.row(.{ .cross = .center, .gap = 6 }, .{
            backControl(ui, "Back", .close_bunker),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Connect your signer", .weight = .bold, .scale = 1.3 }},
            ),
        }),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Paste the bunker link your signer gave you. Your key stays in your signer, Plaza never sees it."),
        ui.el(.textarea, .{
            .text = model.login_draft(),
            .placeholder = "bunker://…",
            .on_input = AppUi.inputMsg(.login_edit),
            .autofocus = true,
            .on_submit = .login_submit,
            .height = 56,
        }, .{}),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, model.login_status()),
        ui.button(.{ .variant = .primary, .disabled = model.login_empty() or bunkerConnecting(), .on_press = .login_submit }, if (bunkerConnecting()) "Connecting…" else "Connect"),
        // Same as the ladder's way out: a button's own press slack is not
        // padding, so without this the Connect button sits 7pt off the card's
        // edge against 24 on the other three sides.
        vgap(ui, 5),
    }));
}

/// The compose sheet: a modal over the feed with the note field and the actions.
/// On demand from the titlebar's "New note", so the feed is not sharing the
/// window with a permanent composer. Escape or a click outside closes it.
fn composeSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // A PAGE, shaped like settings: a bar across the top, then the content in a
    // card down the middle of the window.
    //
    // It is not a modal for the reason settings is not: a modal is a translucent
    // scrim over the whole window, so every frame repaints the window entire and
    // the cost grows with it. On a 1600x1000 window a frame cost 183ms as a
    // sheet and 8ms as a page, and the worst of it was the app sitting idle with
    // a caret blinking in it.
    //
    // It was a bare rounded card flush against the top of the window for a
    // while, which is what a sheet looks like when the sheet around it is taken
    // away and nothing is put in its place.
    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "New note" },
    }, .{
        composeHeader(ui, model),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        ui.scroll(.{ .grow = 1 }, .{
            ui.row(.{ .gap = 0 }, .{
                ui.spacer(1),
                ui.column(.{ .gap = 0, .width = compose_sheet_width }, .{
                    vgap(ui, 16),
                    // The writer and their words, side by side: the disc says
                    // whose voice this is, which is the one thing a composer
                    // must not leave ambiguous when a signer can be swapped.
                    ui.el(.card, .{
                        .padding = 14,
                        .style = .{ .background = p.surface_settings_card, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 },
                    }, .{
                        ui.row(.{ .gap = 0, .cross = .start }, .{
                            meAvatar(ui, avatar_size),
                            hgap(ui, 12),
                            ui.column(.{ .grow = 1, .gap = 0 }, .{
                                ui.el(.textarea, .{
                                    .text = model.draft(),
                                    .placeholder = "What's on your mind?",
                                    .on_input = AppUi.inputMsg(.draft_edit),
                                    .on_submit = .post,
                                    .width = compose_editor_width,
                                    .height = compose_editor_height,
                                    // The caret starts here. A composer you have
                                    // to click into before you can type is a
                                    // composer that opened for no reason.
                                    // Edge-triggered on mount, so it never
                                    // re-steals the caret on a later rebuild.
                                    .autofocus = true,
                                    .style = .{ .background = p.surface_settings_card, .border = p.surface_settings_card, .stroke_width = 0 },
                                }, .{}),
                                // Under the field, because the caret cannot be
                                // located and a picker that floats elsewhere is
                                // a guess about where the reader is looking.
                                mentionPicker(ui, model),
                            }),
                        }),
                    }),
                    composeNotifyRow(ui, model),
                    composeWarningRow(ui, model),
                    vgap(ui, 10),
                    // Under the words, where the picture's address will land.
                    // The servers it goes to are named here, before anything is
                    // picked, and again on the card before anything is sent.
                    uploadStrip(ui, model, .note),
                    vgap(ui, 10),
                    // What pressing Post will do, in the terms that matter: how
                    // far the note goes, and how much room is left when that
                    // starts to matter.
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 2),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_dim } },
                            &.{.{ .text = composeReach(ui, model.draft().len, model.draft_dropped), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        ui.spacer(1),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = "Cmd + Enter", .monospace = true, .scale = mono_hint_scale }},
                        ),
                        hgap(ui, 2),
                    }),
                    vgap(ui, 18),
                }),
                ui.spacer(1),
            }),
        }),
    });
}

/// The composer's content warning: a switch, and once it is on a line for the
/// reason. The reason is optional because the tag is the warning; a note with an
/// empty one is still covered for everyone who reads it.
///
/// Under the card and above the reach line, where the other things that change
/// who sees what (the people it notifies) already sit.
fn composeWarningRow(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 12),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.warn_on,
            .text = "Add a content warning",
            .on_toggle = Msg.warn_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Add a content warning", .focusable = true },
        }, .{}),
        if (model.warn_on) vgap(ui, 8) else ui.spacer(0),
        if (model.warn_on) ui.inputGroup(
            .{ .semantics = .{ .label = "Content warning reason" } },
            ui.el(.textarea, .{
                .text = model.warn_draft(),
                .placeholder = "Reason (optional)",
                .on_input = AppUi.inputMsg(.warn_edit),
                .height = 40,
            }, .{}),
            null,
        ) else ui.spacer(0),
        if (model.warn_on) vgap(ui, 6) else ui.spacer(0),
        if (model.warn_on) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Readers see the reason and a button to show the note. Its pictures are not fetched until they do.", .scale = mono_hint_scale }},
        ) else ui.spacer(0),
    });
}

/// The composer's top bar: the way out on the left, what this is in the middle,
/// and the verb on the right. The same band settings wears, so the two full
/// screens in the app are not two different shapes.
fn composeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0, .height = settings_header_height, .padding = 0.01 }, .{
        hgap(ui, 10),
        ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_compose }, "Cancel"),
        ui.spacer(1),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_sheet_title } },
            &.{.{ .text = "New note", .weight = .medium, .scale = settings_title_scale }},
        ),
        ui.spacer(1),
        if (compose.g_post_due_s != 0)
            // Both shapes the request asked for, in one control: it counts, and
            // pressing it takes the note back. Never disabled while it counts,
            // because the whole value of the pause is being able to press it.
            ui.button(
                .{ .size = .sm, .variant = .secondary, .on_press = .post },
                std.fmt.allocPrint(ui.arena, "Undo · {d}", .{postSecondsLeft(compose.g_post_due_s, nowSeconds())}) catch "Undo",
            )
        else
            ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.draft_empty(), .on_press = .post }, "Post"),
        hgap(ui, 10),
    });
}

/// Replaces the `@word` being typed with a real `nostr:npub…` reference.
///
/// A plain `@name` is a string; only the reference is a link that another
/// client can resolve to a person, and it is what the note's own renderer turns
/// back into a name when it is read. The picker exists to make that the easy
/// path rather than the knowledgeable one.
fn insertMention(model: *Model, pubkey: [32]u8) void {
    const text = model.draft();
    // Through the same reader the picker used, so the cut is the run being
    // typed and never, say, the domain of an address written earlier.
    const query = mentionQuery(text) orelse return;
    const at = text.len - query.len - 1;
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch return;
    // Sized to what the draft can actually hold, so an insert that will not fit
    // is REFUSED rather than written short: the buffer truncates in silence,
    // and half a bech32 reference is one no client can resolve, published
    // without a word of warning.
    var buf: [compose_capacity]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, "{s}nostr:{s} ", .{ text[0..at], npub }) catch return;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(written);
    drafts.g_draft_dirty = true;
}

pub fn insertMentionForTest(model: *Model, pubkey: [32]u8) void {
    insertMention(model, pubkey);
}

/// One candidate for a mention, and why it is where it is in the list.
const MentionCandidate = struct {
    pubkey: [32]u8,
    name: []const u8,
    handle: []const u8,
    verified: bool,
    /// Lower sorts first. The design's ranking is follows, then follows-you,
    /// then everyone the app has seen; the middle tier needs the follows' own
    /// contact lists, which a later milestone builds, so it is empty here and
    /// the code is shaped to take it.
    tier: u8,
};

const mention_tier_follows: u8 = 0;
const mention_tier_follows_you: u8 = 1;
const mention_tier_seen: u8 = 2;
/// How many names the picker offers at once. A list longer than this is a
/// search, which is a different surface.
const mention_rows_max = 6;

/// The word being typed after an `@`, or null when the caret is not in one.
/// Only ever the LAST such run in the draft, because that is the one being
/// written: an `@name` earlier in the note is already said.
pub fn mentionQuery(text: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return null;
    // An `@` mid-word is an email or a handle already written, not a mention
    // being composed.
    if (at > 0) {
        const before = text[at - 1];
        if (!std.ascii.isWhitespace(before)) return null;
    }
    const word = text[at + 1 ..];
    // A space ends it: the reader has moved on and is no longer picking.
    for (word) |c| {
        if (std.ascii.isWhitespace(c)) return null;
    }
    return word;
}

/// The names to offer for `query`, best first. Matches on the display name and
/// on the handle, because a reader types whichever they remember.
fn mentionCandidates(ui: *AppUi, query: []const u8) []const MentionCandidate {
    const out = ui.arena.alloc(MentionCandidate, mention_rows_max) catch return &.{};
    var n: usize = 0;
    for (&profile_cache.g_profiles) |*pr| {
        if (!pr.used or n == out.len) continue;
        const name = pr.name();
        const user = pr.username();
        if (name.len == 0 and user.len == 0) continue;
        if (query.len > 0 and !startsWithFold(name, query) and !startsWithFold(user, query)) continue;
        out[n] = .{
            .pubkey = pr.pubkey,
            .name = if (name.len > 0) name else user,
            .handle = user,
            .verified = pr.nip05_state == .verified,
            // Everyone in the pack is someone the reader follows; anyone else
            // is someone the app has merely seen.
            .tier = if (inFollowGraph(pr.pubkey)) mention_tier_follows else mention_tier_seen,
        };
        n += 1;
    }
    std.mem.sort(MentionCandidate, out[0..n], {}, struct {
        fn lt(_: void, a: MentionCandidate, b: MentionCandidate) bool {
            if (a.tier != b.tier) return a.tier < b.tier;
            return a.name.len < b.name.len;
        }
    }.lt);
    return out[0..n];
}

/// Case-insensitive prefix match, which is how a reader types a name.
fn startsWithFold(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// The picker: the names the reader might mean, under the field they are typing
/// in. Anchored to the field rather than the caret, which cannot be located
/// (0.5), so it hangs under the whole editor.
fn mentionPicker(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (model.mention_dismissed) return ui.spacer(0);
    const query = mentionQuery(model.draft()) orelse return ui.spacer(0);
    const names = mentionCandidates(ui, query);
    if (names.len == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, names.len + 1) catch return ui.spacer(0);
    for (names, rows[0..names.len], 0..) |c, *row, i| {
        const tint = avatarTint(c.pubkey);
        const hexdigits = "0123456789abcdef";
        row.* = ui.el(.list_item, .{
            .padding = 0.01,
            .height = list_row_height,
            .cross = .center,
            .on_press = Msg{ .insert_mention = c.pubkey },
            .style = .{ .radius = 6, .background = if (i == 0) p.surface_menu_selected else null },
            .semantics = .{ .role = .button, .label = c.name, .focusable = true },
        }, .{
            hgap(ui, 8),
            ui.avatar(.{
                .image = 0,
                .width = 24,
                .height = 24,
                .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
            }, ui.fmt("{c}{c}", .{ hexdigits[c.pubkey[0] >> 4], hexdigits[c.pubkey[0] & 0x0f] })),
            hgap(ui, 9),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = c.name, .weight = .medium, .scale = menu_scale }}),
            if (c.verified) hgap(ui, 5) else ui.spacer(0),
            if (c.verified)
                ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle")
            else
                ui.spacer(0),
            hgap(ui, 6),
            if (c.handle.len > 0)
                ui.paragraph(.{ .style = .{ .foreground = identityInk() } }, &.{.{ .text = ui.fmt("@{s}", .{c.handle}), .scale = mono_row_scale }})
            else
                ui.spacer(0),
            ui.spacer(1),
            hgap(ui, 8),
        });
    }
    // What pressing one does, said once at the foot rather than per row.
    rows[names.len] = ui.column(.{ .gap = 0 }, .{
        vgap(ui, 2),
        ui.separator(.{ .style = .{ .foreground = p.border_menu, .background = p.border_menu } }),
        vgap(ui, 5),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "inserts a nostr: link, not just a name", .monospace = true, .scale = mono_chip_scale }},
            ),
        }),
        vgap(ui, 3),
    });
    return menuSurfacePlacedDismissing(ui, 320, .below, .start, Msg.close_mentions, rows);
}

/// How far a note will go, said before it goes rather than after: the relays
/// that will take a write, and that Plaza imposes no length of its own.
/// Who this note will notify, as names you can switch off.
///
/// Nothing here is new information at publish time: it is the same set the
/// event carries, shown before it goes out. A reply can tag a dozen people who
/// were merely present in a thread, and the first anybody knew about it used to
/// be somebody answering a conversation they had left.
/// The composer's notify row, derived from the draft as it stands.
fn composeNotifyRow(ui: *AppUi, model: *const Model) AppUi.Node {
    var people: [max_mention_tags][32]u8 = undefined;
    const n = notifiedBy(model.draft(), &people);
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{ vgap(ui, 10), notifyChips(ui, model, people[0..n]) });
}

/// The reply's notify row: whoever the text names, plus everybody already in
/// the thread, which is the set that surprises people.
fn replyNotifyRow(ui: *AppUi, model: *const Model, root: *const Note) AppUi.Node {
    var people: [max_mention_tags][32]u8 = undefined;
    var n = notifiedBy(model.reply_draft(), &people);
    const me = activePubkey();
    var pool: [1 + thread_reply_cap][32]u8 = undefined;
    var pool_len: usize = 0;
    pool[0] = root.pubkey;
    pool_len = 1;
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (pool_len == pool.len) break;
        pool[pool_len] = note.pubkey;
        pool_len += 1;
    }
    for (pool[0..pool_len]) |pubkey| {
        if (n == people.len) break;
        if (me) |mine| {
            if (std.mem.eql(u8, &mine, &pubkey)) continue;
        }
        var dup = false;
        for (people[0..n]) |seen| {
            if (std.mem.eql(u8, &seen, &pubkey)) dup = true;
        }
        if (dup) continue;
        people[n] = pubkey;
        n += 1;
    }
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{ vgap(ui, 8), notifyChips(ui, model, people[0..n]) });
}

fn notifyChips(ui: *AppUi, model: *const Model, people: []const [32]u8) AppUi.Node {
    const p = theme.palette;
    if (people.len == 0) return ui.spacer(0);

    // Chunked into rows by hand, because `wrap` is a text property in this
    // toolkit and not a row one: a single row of a dozen chips would run off
    // the side of the composer rather than folding under itself.
    //
    // Two per row, and the name clipped. Three of them blew 35px past the right
    // edge of the narrowest window the app allows, which the layout guard
    // caught: a chip is only as wide as the name inside it, and a display name
    // has no length any of this controls.
    const per_row = 2;
    const row_count = (people.len + per_row - 1) / per_row;
    const rows = ui.arena.alloc(AppUi.Node, row_count + 1) catch return ui.spacer(0);
    rows[0] = ui.paragraph(
        .{ .style = .{ .foreground = p.text_dim } },
        &.{.{ .text = "Notifies", .scale = stat_scale }},
    );

    var placed: usize = 0;
    for (rows[1..]) |*row| {
        const take = @min(per_row, people.len - placed);
        const kids = ui.arena.alloc(AppUi.Node, take) catch return ui.spacer(0);
        for (people[placed..][0..take], kids) |pubkey, *kid| {
            const off = mentionExcluded(model.mentionsOff(), pubkey);
            // Switched off stays on screen, dimmed, rather than disappearing:
            // a chip that vanished when pressed would leave nothing to press
            // to bring the person back.
            // The press and its focus ring live on the outer row, the chip's
            // fill and border on the panel inside it: a list row draws a fill
            // and a ring and no border.
            kid.* = pressRow(ui, .{
                .on_press = Msg{ .toggle_mention_off = pubkey },
                .style = .{ .radius = 999, .quiet_hover = true },
                .semantics = .{ .role = .button, .label = if (off) "Not notifying, press to switch back on" else "Notifying, press to switch off", .focusable = true },
            }, .{
                ui.el(.panel, .{
                    .padding = 0.01,
                    .style = .{
                        .background = if (off) p.surface_rail_tile else p.surface_input,
                        .border = p.border_chip,
                        .radius = 999,
                        .stroke_width = 1,
                    },
                }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 10),
                        ui.paragraph(
                            .{ .style = .{ .foreground = if (off) p.text_muted else p.text_secondary } },
                            &.{.{ .text = clipToChars(personName(ui, pubkey), 14, 42), .scale = stat_scale }},
                        ),
                        hgap(ui, 10),
                        vgap(ui, 24),
                    }),
                }),
            });
        }
        placed += take;
        row.* = ui.row(.{ .cross = .center, .gap = 6 }, kids);
    }
    return ui.column(.{ .gap = 6 }, rows);
}

pub const compose_capacity_for_test = compose_capacity;

pub fn composeReachForTest(arena: std.mem.Allocator, written: usize, dropped: usize) []const u8 {
    var ui = AppUi.init(arena);
    return composeReach(&ui, written, dropped);
}

fn composeReach(ui: *AppUi, written: usize, dropped: usize) []const u8 {
    // The overflow first, because it is the only thing here the writer has to
    // act on: some of what they pasted is not in the box and they cannot see
    // which part.
    if (dropped > 0) {
        return ui.fmt("{d} characters did not fit and were not kept", .{dropped});
    }
    // The room left, once there is little enough of it to matter. A composer
    // that silently stops accepting characters is the bug this replaces, and a
    // counter that is always on screen is a nag for the ninety-nine notes that
    // will never approach the limit.
    const left = compose_capacity -| written;
    if (left <= compose_capacity / 4) {
        const live_now = liveRelayCount();
        if (live_now == 0) return ui.fmt("{d} left · no relay is answering", .{left});
        return ui.fmt("posts to {d} {s} · {d} left", .{ live_now, if (live_now == 1) "relay" else "relays", left });
    }
    const live = liveRelayCount();
    if (live == 0) return "no relay is answering · it will wait in the outbox";
    return ui.fmt("posts to {d} {s}", .{ live, if (live == 1) "relay" else "relays" });
}

/// The one question this app asks before doing something it cannot undo.
///
/// The wording is the part worth getting right. A deletion is a REQUEST: relays
/// may honour it or ignore it, and the note may already sit on relays that will
/// never see the request. Saying "deleted" would be a promise Nostr cannot
/// keep, so this says what actually happens and lets the reader decide with
/// that in front of them.
fn deleteConfirm(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .padding = 20,
        .on_press = .delete_note_cancel,
        .semantics = .{ .label = "Delete this note?" },
    }, .{
        ui.column(.{ .gap = 12, .cross = .stretch }, .{
            ui.text(.{}, "Delete this note?"),
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = "This asks the relays you publish to drop it. Most will. Any that already passed it on, or that ignore the request, may keep serving it, so this cannot be undone and cannot be guaranteed." }},
            ),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .delete_note_cancel }, "Cancel"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .variant = .destructive, .on_press = .delete_note_confirm }, "Delete"),
            }),
        }),
    });
}

/// The question asked before a list is started from nothing.
///
/// Every relay Plaza reads from has finished and none sent this list, which is
/// the strongest thing the app can know and still not proof: the list may sit on
/// a relay Plaza has never dialed. So it asks the one party who can know, and says
/// what a wrong yes costs. A list is replaceable, and the new one would hold only
/// what this press adds.
fn freshListConfirm(ui: *AppUi, ask: FreshAsk) AppUi.Node {
    const p = theme.palette;
    const list = switch (ask.action) {
        .follow => "follow list",
        .mute => "mute list",
        .bookmark, .bookmark_privately => "bookmark list",
        .add_media_server => "media server list",
    };
    const holds = switch (ask.action) {
        .follow => "this one person",
        .mute => "this one person",
        .bookmark, .bookmark_privately => "this one note",
        .add_media_server => "this one server",
    };
    // A set width, and the panel drawn by a card that pads itself around one
    // column, like the join sheet. The dialog sizes what it holds as if a
    // paragraph were a single line, so a bare dialog (and then a card in one)
    // kept a one-line height while the text wrapped to five, and the buttons
    // fell out of the bottom of the box. So the card is given its height: the
    // lines the text wraps to at the inner width, priced a little wider per
    // character than the feed prices a note body so it errs toward air, plus
    // the title, the buttons and the gaps between them.
    const inner = join_sheet_width - 2 * modal_card_padding;
    const text = ui.fmt("None of your relays has a {s} for you. If you already have one somewhere Plaza has not looked, a new one would replace it with a list holding only {s}. Go on only if this account is new, or you know it has no {s}.", .{ list, holds, list });
    const lines = @max(1, @ceil(@as(f32, @floatFromInt(text.len)) / @floor(inner / 8)));
    const height = 2 * modal_card_padding + 18 + 12 + lines * body_line_height + 12 + 28;
    return modalScrim(ui, "Start a new list?", .fresh_list_cancel, ui.el(.dialog, .{
        .width = join_sheet_width,
        .on_dismiss = .fresh_list_cancel,
        .semantics = .{ .label = "Start a new list?" },
    }, .{
        ui.el(.card, .{
            .width = join_sheet_width,
            .height = height,
            .on_press = Msg.absorb_press,
            .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 },
        }, .{ui.column(.{ .gap = 12 }, .{
            ui.text(.{}, ui.fmt("Start a new {s}?", .{list})),
            ui.paragraph(
                .{ .wrap = true, .width = inner, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = text }},
            ),
            ui.row(.{ .width = inner, .cross = .center, .gap = 8 }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .fresh_list_cancel }, "Cancel"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .variant = .destructive, .on_press = .fresh_list_confirm }, "Start a new list"),
            }),
        })}),
    }));
}

/// The expanded picture, filling the window over the feed. The registry decodes
/// at most 512 pixels on a side, so rather than upscale a small copy into a
/// blur, this shows it as large as it honestly goes and offers the
/// full-resolution original in the browser. Pressing the backdrop closes it,
/// which also stops presses reaching the feed underneath.
fn imageViewer(ui: *AppUi, note: *const Note, index: u8) AppUi.Node {
    // WHICH picture, which the viewer used to have no opinion about. The
    // gallery cell dispatches the index it was drawn for and the update stores
    // it, and then this function was called with the note alone, so the index
    // was written twice and read nowhere. `media_id()` and `imageUrl()` are
    // both index 0, so every cell in a gallery opened the first picture.
    //
    // Clamped rather than trusted: the model outlives a rebuild, so a note that
    // came back from a relay with fewer pictures than the one that was pressed
    // would index past the end.
    const i: u8 = if (index < note.imageCount()) index else 0;
    const image_id = note.mediaIdAt(i);
    // A dialog, not a bare column: modal surfaces paint their own opaque
    // surface and always claim their own input, so the feed underneath neither
    // shows through nor scrolls, and Escape or a click outside closes it.
    // Stacking kinds layer their children, so the contents go in a column.
    // A PANEL rather than a dialog, and it is the one modal here that is not a
    // card. A picture wants the whole window; a `.dialog` since 0.9.2 is centred
    // at its preferred size inside a 24pt margin, which would frame the viewer
    // with a border of feed showing around it. The cost is Escape: dismissal is
    // a modal-surface event, so it goes with the dialog. A press anywhere still
    // closes, which is how the viewer was mostly used anyway.
    return ui.el(.panel, .{
        .grow = 1,
        .padding = 16,
        .on_press = .close_image,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Expanded image" },
    }, .{
        ui.column(.{ .grow = 1, .gap = 12, .cross = .stretch }, .{
            // The picture needs a definite box: an image is a leaf with no
            // intrinsic size, so it draws nothing unless a stretching parent
            // hands it one (a centred column collapses its width to zero).
            ui.row(.{ .grow = 1, .cross = .stretch }, .{
                if (image_id != 0) blk: {
                    var node = ui.image(.{
                        .image = image_id,
                        .grow = 1,
                        .semantics = .{ .label = "Expanded image" },
                    });
                    node.widget.image_fit = .contain;
                    break :blk node;
                } else ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Still loading…"),
            }),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .autofocus = true, .on_press = .close_image }, "Close"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg{ .open_url = note.imageAt(i).url() } }, "Open original"),
            }),
        }),
    });
}

/// The one options value both `virtualWindow` and `virtualList` read. The MODEL
/// owns the notes; the runtime only ever sees how many there are, an estimate
/// per row, and the window it asked for.
fn feedOptions(model: *const Model) AppUi.VirtualListOptions {
    return .{
        .id = "feed",
        .item_count = model.notes_len,
        // Variable-extent mode: cards are as tall as their wrapped text and
        // their picture. The estimate prices unbuilt rows; the engine patches in
        // measured heights as rows mount, and anchors the viewport so those
        // corrections never move what the reader is looking at.
        .item_extent = 0,
        .extent_estimate = noteExtentEstimate,
        .extent_context = model,
        // No gap between rows: the hairline under each row is the separation,
        // so a border can mean something (a quote, a reply) and rows do not
        // float apart with the divider lost in the space.
        .gap = 0,
        // No list inset: the row inset was narrower than the reading column, so
        // the column overflowed it on the right (flush) while the left inset read
        // as a gap. At 0 the centered reading column sits symmetric in the feed.
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        // Only bare builds (tests, previews) read this: under the app the
        // runtime supplies the real viewport. Without it a test resolves an
        // empty window and renders no rows at all.
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Feed" },
        .on_reach_end = .load_older,
    };
}

/// A cheap height estimate for the note at `index`, from model facts only
/// (never layout): the card's chrome, its wrapped lines, and its picture.
fn noteExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const model: *const Model = @ptrCast(@alignCast(context orelse return 96));
    const i: usize = @intCast(index);
    if (i >= model.notes_len) return feed_row_chrome;
    return noteRowEstimate(&model.notes[i], feed_row_chrome);
}

/// The shared card-height math behind the feed's and the thread's estimates.
/// `chrome` covers everything except the body's wrapped lines; the body wraps in
/// the 540px text column beside the 36px disc.
///
/// The line height is MEASURED, not the redesign's ratio. The mock sets the body
/// at 14.5/1.55 (22.475), but `widgetLineHeight` is `size * 1.25` with no token
/// and no per-element override anywhere in the SDK, so a body line is 18.125 here
/// and the feed reads tighter than the mock. Recorded as a wall in the plan.
fn noteRowEstimate(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, true);
}

/// The same, for a row that draws the body and NOTHING under it. A nested reply
/// is one: it builds an identity row and a body and stops, so pricing it for a
/// picture and a link card reported hundreds of pixels per reply it never drew.
fn noteRowEstimateBody(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, false);
}

fn noteRowEstimateWith(note: *const Note, chrome: f32, media: bool) f32 {
    const line_height: f32 = body_line_height;
    const chars_per_line: f32 = 70;
    // A covered note is its chrome and one chip: no body lines, no fold, no
    // picture, no link card and no quote, whatever it carries underneath.
    if (noteCovered(note)) {
        var covered = chrome + cover_notice_height;
        if (note.has_reply_parent) covered += line_height + 4;
        if (note.has_reposter) covered += line_height + 4;
        return covered;
    }
    // A collapsed long note shows only the fold, plus a line for "Show more".
    const collapsed = noteIsLong(note) and !isExpanded(note.id);
    const shown_chars: f32 = @floatFromInt(if (collapsed) collapsedLen(note.content(), note_collapse_chars) else note.content_len);
    const lines = @max(1, @ceil(shown_chars / chars_per_line));
    // A kind nothing can draw puts a chip where the body would be, so the row
    // is priced as that chip rather than as a line of text it does not have.
    // `@max(1, ...)` above would otherwise charge it a full line for a body of
    // length zero, which is close enough to hide in the slack and still wrong.
    const unsupported = kindRender(note.kind) == .unsupported;
    var extent = chrome + (if (unsupported) quote_pill_height else lines * line_height);
    if (collapsed) extent += line_height;
    // The reply line and its gap, priced whatever state it is in: it occupies
    // one line while it says "reply to a note" and one line once it names
    // somebody, so the row does not resize under the reader when the parent
    // resolves a moment later.
    if (note.has_reply_parent) extent += line_height + 4;
    // The line naming who passed this on, and the gap under it.
    if (note.has_reposter) extent += line_height + 4;
    if (!media) return extent;
    // A link card, once the page has answered; nothing before that.
    if (note.hasLink()) {
        if (linkFor(note.linkUrl())) |l| {
            if (l.state == .loaded) {
                extent += 3 + (if (l.description().len > 0) link_card_height else link_card_height_bare);
            }
        }
    }
    // A picture nobody asked for is one quiet chip, not a reserved box.
    if (note.hasImage()) {
        const shown = prefs.g_media_previews or isMediaAsked(note.id) or note.media_id() != 0;
        extent += (if (shown) pictureHeight(note) else picture_ask_height) + 8;
    }
    // The quote, which is only now a knowable height: the clamp is what makes it
    // one (the shot's own note beside 11f says quote rows clamp "so their height
    // is known at insert"). The bordered card it replaces was never priced at
    // all, so a feed of quoting notes reported less than it drew.
    // The card sits at its own byte span in the body, so a collapsed note shows
    // it only when the fold reaches past it, exactly as `noteBodyAt` decides.
    if (quoteCardShown(note, true)) {
        extent += quoteAsideExtent(note.quote.id);
    }
    return extent;
}

/// How tall a quote's aside draws: its margin, the identity block (the disc sets
/// it), and up to `quote_body_lines` lines of the quoted note. A quote still
/// resolving is priced at the skeleton it shows, so the row does not jump when
/// it lands.
fn quoteAsideExtent(id: [32]u8) f32 {
    const e = quoteFor(id) orelse return quote_quiet_chrome + quote_skeleton_height;
    return switch (e.state) {
        // The quiet states draw no identity block, so they do not carry its
        // chrome: only the 5 above, the sibling gap and the 2px pads. Pricing
        // them like the loaded aside over-charged every quoting row by nearly
        // three lines from first paint until its quote landed.
        .idle, .fetching => quote_quiet_chrome + quote_skeleton_height,
        .missing => quote_quiet_chrome + body_line_height,
        // The depth-1 pill, when the quoted note quotes something itself: it is
        // a row of its own under the body, and the row around it is priced.
        .loaded => blk: {
            // A covered quote swaps its body for the cover chip and draws no
            // picture; the pills under it are unchanged.
            const covered = quoteCovered(e);
            break :blk quote_aside_chrome +
                (if (covered) cover_notice_height else quoteBodyLines(e) * body_line_height) +
                (if (e.has_quote_of) quote_pill_height + 4 else 0) +
                (if (kindRender(e.kind) == .unsupported) quote_pill_height + 4 else 0) +
                (if (e.image_host_len > 0 and !covered) (if (quoteShowsPicture(e)) quotePictureBox(quotePictureAspect(e)).height else quote_pill_height) + 4 else 0);
        },
    };
}

/// The lines a cached quote's body draws, counted the way the clamp cuts them.
fn quoteBodyLines(e: *const QuoteEntry) f32 {
    // No body, no line. A quoted note that is nothing but a picture draws no
    // body at all, and charging it one line reserved a blank row under the name
    // that nothing ever filled.
    if (e.text_len == 0) return 0;
    var lines: usize = 1;
    var column: usize = 0;
    for (e.text_buf[0..e.text_len]) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= quote_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, quote_body_lines));
}

/// One thread level's row plan: row 0 is the root note, rows 1..n the replies
/// in conversation order, with skeleton rows (first fetch still out) or the
/// quiet empty line appended. Arena-allocated per frame so the virtual list's
/// estimate callback can price unbuilt rows from model facts.
pub const ThreadRows = struct {
    /// The model, so the composer row can read the draft and the signer state.
    model: *const Model,
    root: *const Note,
    /// The chain above the focal note, oldest first, drawn as the rows before
    /// it. Empty for a thread opened at its own root.
    ancestors: []const Ancestor,
    /// Top-level replies with their own replies folded in, so ONE row is one
    /// conversation rather than one note.
    blocks: []const ThreadBlock,
    /// How many of the in-graph blocks this page shows, and how many wait behind
    /// the line. `hidden` counts CONVERSATIONS, which is the row arithmetic;
    /// `hidden_held` counts the replies inside them, which is what the line says.
    shown: usize,
    hidden: usize,
    hidden_held: usize,
    /// Replies from outside the follow graph, held below the rest. They are never
    /// dropped: the row says how many there are and opens them.
    outside: []const ThreadBlock,
    /// How many REPLIES those blocks hold, which is what the line says. A block
    /// is one conversation: its own note, the replies drawn under it, and
    /// whatever those collapse into.
    outside_held: usize,
    outside_open: bool,
    skeletons: bool,
    empty: bool,
    /// The line that says the subscription is still open. Absent in the empty
    /// state, which says it in its own words.
    footer: bool,

    /// What sits at `index`, for both the builder and the estimator. ONE function
    /// answers it, because two parallel index walks is how a row draws itself at
    /// another row's height: every earlier version of this list had the plan
    /// written out twice and had to keep the arithmetic in step by hand.
    pub const Row = union(enum) {
        ancestor: usize,
        focal,
        composer,
        block: usize,
        show_more,
        outside_line,
        outside_block: usize,
        skeleton,
        empty,
        footer,
    };

    /// The chain, then the focal note, then the reply field, then one row per
    /// shown conversation, the lines that hold what is not shown, and the footer.
    /// The field is a ROW rather than a pinned footer because the design puts it
    /// under the note being answered, where it scrolls with the conversation
    /// instead of hovering over it.
    pub fn rowAt(self: *const ThreadRows, index: usize) Row {
        if (index < self.ancestors.len) return .{ .ancestor = index };
        var i = index - self.ancestors.len;
        if (i == 0) return .focal;
        if (i == 1) return .composer;
        i -= 2;
        if (i < self.shown) return .{ .block = i };
        i -= self.shown;
        if (self.hidden > 0) {
            if (i == 0) return .show_more;
            i -= 1;
        }
        if (self.outside.len > 0) {
            if (i == 0) return .outside_line;
            i -= 1;
            if (self.outside_open) {
                if (i < self.outside.len) return .{ .outside_block = i };
                i -= self.outside.len;
            }
        }
        if (self.skeletons) {
            if (i < thread_skeleton_rows) return .skeleton;
            i -= thread_skeleton_rows;
        }
        if (self.empty) {
            if (i == 0) return .empty;
            i -= 1;
        }
        return .footer;
    }

    pub fn count(self: *const ThreadRows) usize {
        return self.ancestors.len + 2 + self.shown + @intFromBool(self.hidden > 0) +
            @intFromBool(self.outside.len > 0) + (if (self.outside_open) self.outside.len else 0) +
            (if (self.skeletons) thread_skeleton_rows else 0) + @intFromBool(self.empty) +
            @intFromBool(self.footer);
    }
};

/// How many top-level replies a page of a thread shows, and how many more each
/// press of the line reveals. No shot states a number; twenty is a long read
/// already, and the line says exactly how many are behind it.
const thread_page_size: usize = 20;
const thread_skeleton_rows: usize = 3;

/// A cheap height estimate for one thread row, sharing the feed's note math.
/// A level's row heights, precomputed at build time and read back by the SDK
/// whenever it wants them.
///
/// The SDK RETAINS `extent_context` and calls the estimator through it long
/// after the build that supplied it returned: in a post-layout measure pass, and
/// since 0.7.2 from inside `virtualWindow` on a LATER build. Both lists used to
/// hand it an arena-allocated view context full of slices, on the reasoning that
/// the arena outlives the build. It does not outlive two: the runtime rotates a
/// small set of arenas and resets the one it is about to build into, so a
/// context handed over on build N is read on build N+2 with its slices pointing
/// at whatever the new build has since allocated there. That is a segfault in
/// `noteRowEstimateWith`, reading a Note out of a reused index, and it is what
/// took the app down on a mouse-up over a person's page.
///
/// So the retained context holds NO POINTERS. It is a table of numbers with
/// process lifetime, filled from the real row structures while they are alive
/// and valid, and read afterwards by an estimator that cannot dereference
/// anything. There is nothing left in it that a later frame can invalidate.
const RowExtents = struct {
    /// A tag, because the other half of the pairing cannot be checked by the
    /// compiler: `extent_context` is `?*const anyopaque` and accepts any
    /// pointer, so wiring the estimator to a view context instead of a table
    /// would read one struct as the other and hand the list garbage heights,
    /// silently. This turns that into a fallback the suite can catch.
    magic: u64 = row_extents_magic,
    heights: [row_extent_cap]f32 = [_]f32{0} ** row_extent_cap,
    len: usize = 0,

    fn reset(self: *RowExtents) void {
        self.len = 0;
    }

    fn push(self: *RowExtents, height: f32) void {
        if (self.len >= self.heights.len) return;
        self.heights[self.len] = height;
        self.len += 1;
    }

    fn at(self: *const RowExtents, index: usize) f32 {
        if (index >= self.len) return quiet_row_extent;
        return self.heights[index];
    }
};

const row_extents_magic: u64 = 0x524f57455854_4142;

/// Rows one retained table can price. A thread holds at most its cap plus the
/// rows around the replies; an article holds its body rows plus its head and
/// foot; a person's page holds as many notes as it will plus its header and
/// footer. Past it a row falls back to the quiet extent rather than being
/// priced, which is the estimate being wrong, not a crash.
const row_extent_cap = @max(thread_reply_cap * 2, @max(article.max_chunks + 2, profile_notes_max + 4));

/// Who and what is ON SCREEN in a level right now: the authors whose faces are
/// being drawn, and the notes whose pictures are.
///
/// The canvas registry holds SIXTEEN images for the whole window, split nine
/// faces, one banner and six pictures. That is ample, because only about a
/// screenful of rows is ever visible at once, and the feed has always spent it
/// that way: it marks and fetches `visibleRange()` and nothing else.
///
/// A thread and a person's page did not. They marked EVERY note in the level as
/// on screen, so in a long thread the first nine authors and the first six
/// pictures took every slot and held them: the allocator refuses to evict
/// anything marked wanted this pass, and everything was marked. Every other
/// author kept initials and every other picture stayed blank, for as long as the
/// level was open, and the bigger the thread the worse it got. This is what
/// "avatars and images do not load in big threads" was.
///
/// Filled during the build from the visible window, which is the only place that
/// knows which rows are on screen, and read on the next tick by the two passes
/// that lend slots. One frame stale, exactly like the feed's own range.
const VisibleSet = struct {
    authors: [visible_set_cap][32]u8 = undefined,
    author_count: usize = 0,
    notes: [visible_set_cap]i64 = undefined,
    note_count: usize = 0,

    fn reset(self: *VisibleSet) void {
        self.author_count = 0;
        self.note_count = 0;
    }

    fn pushAuthor(self: *VisibleSet, pubkey: [32]u8) void {
        if (self.author_count >= self.authors.len) return;
        for (self.authors[0..self.author_count]) |had| {
            if (std.mem.eql(u8, &had, &pubkey)) return;
        }
        self.authors[self.author_count] = pubkey;
        self.author_count += 1;
    }

    fn pushNote(self: *VisibleSet, id: i64) void {
        if (self.note_count >= self.notes.len) return;
        for (self.notes[0..self.note_count]) |had| {
            if (had == id) return;
        }
        self.notes[self.note_count] = id;
        self.note_count += 1;
    }
};

/// A screenful of rows, with the overscan the lists declare and a block's own
/// replies counted: comfortably more than can be on screen, and far fewer than a
/// long thread holds.
pub const visible_set_cap = 48;

/// One per mounted level. UI-thread only, like every other per-level cache here.
pub var g_level_visible: [thread_depth_max + 1]VisibleSet = [_]VisibleSet{.{}} ** (thread_depth_max + 1);
/// Which level is the one being READ, so the passes that lend slots spend them
/// on the level in front rather than on an occluded one underneath.
pub var g_visible_level: usize = 0;

/// One per mounted level, plus one for a person's page at that level. Levels are
/// UI-thread only, like every other per-level cache in this file.
var g_thread_extents: [thread_depth_max + 1]RowExtents = [_]RowExtents{.{}} ** (thread_depth_max + 1);
var g_profile_extents: [thread_depth_max + 1]RowExtents = [_]RowExtents{.{}} ** (thread_depth_max + 1);

/// Reads a precomputed height. The whole point is that this touches nothing but
/// its own numbers.
/// Records the authors and pictures on screen in a thread level.
///
/// A visible ROW is not one note: a block is a reply plus the replies drawn
/// under it, and all of them are on screen together. The overscan the list
/// declares is included, which is what makes a face arrive before the row
/// carrying it does.
fn recordThreadVisible(rows: *const ThreadRows, level: usize, first: usize, last: usize) void {
    const set = &g_level_visible[@min(level, g_level_visible.len - 1)];
    set.reset();
    g_visible_level = @min(level, g_level_visible.len - 1);
    var index = first;
    while (index <= last and index < rows.count()) : (index += 1) {
        switch (rows.rowAt(index)) {
            .ancestor => |ai| if (ai < rows.ancestors.len) {
                set.pushAuthor(rows.ancestors[ai].note.pubkey);
                set.pushNote(rows.ancestors[ai].note.id);
            },
            .focal => {
                set.pushAuthor(rows.root.pubkey);
                set.pushNote(rows.root.id);
            },
            .block => |bi| if (bi < rows.blocks.len) pushBlock(set, &rows.blocks[bi]),
            .outside_block => |oi| if (oi < rows.outside.len) pushBlock(set, &rows.outside[oi]),
            else => {},
        }
    }
}

fn pushBlock(set: *VisibleSet, block: *const ThreadBlock) void {
    set.pushAuthor(block.parent.pubkey);
    set.pushNote(block.parent.id);
    for (block.children) |*child| {
        set.pushAuthor(child.pubkey);
        set.pushNote(child.id);
    }
}

/// The same for a person's page: the subject owns a face first, then whichever
/// of their notes is on screen.
fn recordProfileVisible(rows: *const ProfileRows, level: usize, first: usize, last: usize) void {
    const set = &g_level_visible[@min(level, g_level_visible.len - 1)];
    set.reset();
    g_visible_level = @min(level, g_level_visible.len - 1);
    // The 72px face is the largest thing on the page, so the subject is first in
    // line whether or not their card is scrolled into view.
    set.pushAuthor(rows.subject());
    var index = first;
    while (index <= last and index < rows.count()) : (index += 1) {
        switch (rows.rowAt(index)) {
            .note => |ni| if (ni < rows.notes.len) {
                set.pushAuthor(rows.notes[ni].pubkey);
                set.pushNote(rows.notes[ni].id);
            },
            else => {},
        }
    }
}

/// Pretends a build put exactly these authors on screen in the front level.
pub fn recordVisibleAuthorsForTest(authors: []const [32]u8) void {
    const set = &g_level_visible[0];
    set.reset();
    g_visible_level = 0;
    for (authors) |pk| set.pushAuthor(pk);
}

fn rowExtentFromTable(context: ?*const anyopaque, index: u64) f32 {
    const table: *const RowExtents = @ptrCast(@alignCast(context orelse return quiet_row_extent));
    if (table.magic != row_extents_magic) return quiet_row_extent;
    return table.at(@intCast(index));
}

/// The retained tables, for a test that drops the build arena and then reads
/// them exactly as the SDK does.
pub fn threadExtentTableForTest(level: usize) *const anyopaque {
    return &g_thread_extents[@min(level, g_thread_extents.len - 1)];
}

pub fn profileExtentTableForTest(level: usize) *const anyopaque {
    return &g_profile_extents[@min(level, g_profile_extents.len - 1)];
}

pub fn rowExtentFromTableForTest(context: ?*const anyopaque, index: u64) f32 {
    return rowExtentFromTable(context, index);
}

pub fn extentTableLenForTest(context: ?*const anyopaque) usize {
    const table: *const RowExtents = @ptrCast(@alignCast(context orelse return 0));
    return table.len;
}

/// One thread row's height, measured from the live row structures.
///
/// TYPED, and deliberately: it takes a `*const ThreadRows` rather than the
/// SDK's `?*const anyopaque` callback shape, so it cannot be handed over as a
/// retained estimator. Only `rowExtentFromTable` has that shape now, and it
/// reads numbers. See `RowExtents` for what went wrong when this was the
/// callback.
fn threadRowHeight(rows: *const ThreadRows, i: usize) f32 {
    return switch (rows.rowAt(i)) {
        // An ancestor: the identity block pinned to its disc, a body clamped to
        // two lines, and the rail's segment down to the next disc.
        .ancestor => |ai| blk: {
            const a = &rows.ancestors[ai];
            const lead: f32 = if (ai == 0) ancestor_top_pad else 0;
            if (a.ghost != .none) break :blk lead + ghost_row_extent;
            break :blk lead + ancestor_row_chrome + @as(f32, @floatFromInt(a.lines)) * ancestor_line_height;
        },
        // The focal note carries the identity block, its exact-time line, the
        // stats row and the verb row on top of a body set one register up. Its
        // leading space belongs to the ancestor above it when there is one.
        .focal => noteRowEstimate(rows.root, focal_row_chrome) -
            (if (rows.ancestors.len > 0) focal_leading_pad else 0),
        // The reply field: a fixed shape whatever the thread holds.
        .composer => reply_row_extent,
        // A block is its top-level reply plus the level of conversation under it,
        // so it is priced as the sum: one reply's chrome and body, then each
        // child's.
        .block => |bi| blockExtent(&rows.blocks[bi]),
        .outside_block => |oi| blockExtent(&rows.outside[oi]),
        .show_more => show_more_extent,
        .outside_line => outside_row_extent,
        .footer => listening_row_extent,
        // A skeleton or the empty line: one fixed-shape row.
        .skeleton, .empty => thread_skeleton_extent,
    };
}

/// One conversation's height: the top-level reply, then each nested child, then
/// a line for whatever the branch continues into.
fn blockExtent(block: *const ThreadBlock) f32 {
    var extent = noteRowEstimate(block.parent, thread_reply_chrome);
    if (block.parent.parent_missing) extent += orphan_note_extent;
    for (block.children, block.deeper) |*child, deeper| {
        extent += noteRowEstimateBody(child, nested_reply_chrome) * nested_body_scale;
        if (deeper > 0) extent += branch_more_extent;
    }
    return extent;
}

/// How many lines an ancestor's clamped body wraps to: one or two, the clamp's
/// whole point.
pub fn ancestorBodyLines(note: *const Note) f32 {
    // The cover chip is a line and a half of this register tall, which two lines
    // price without ever under-reserving it.
    if (noteCovered(note)) return @floatFromInt(ancestor_body_lines);
    // No body, no line. An image-only reply is a common shape, and its content
    // is empty because the URL is lifted out of the text: pricing it at a line
    // the row never draws is space the level reports and does not fill.
    if (note.content_len == 0) return 0;
    var lines: usize = 1;
    var column: usize = 0;
    for (note.content()) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= ancestor_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, ancestor_body_lines));
}

/// One thread level's panel: header, the windowed root-and-replies list, and
/// the reply composer. Rendered for the open thread AND every ancestor still on
/// the back-stack (occluded beneath it), so each level's list stays mounted and
/// keeps its scroll offset. The list is a virtualList: only the rows in the
/// viewport are built, so a busy thread, or a stack of occluded ancestor
/// levels, stays far under the per-view widget budget (a plain scroll built
/// every reply of every level and blew straight through it). The list id is
/// the level key, so a level's scroll identity is stable as it moves between
/// current and ancestor.
fn threadPanel(ui: *AppUi, model: *const Model, root: *const Note, replies: []const Note, thread_loading: bool, level_key: u64, level: usize, occluded: bool) AppUi.Node {
    // While the first fetch is out with nothing in hand, a few skeleton rows say
    // "replies are coming"; once it has come back empty, a quiet line instead of
    // a lone root over blank space.
    const loading = replies.len == 0 and thread_loading;
    const empty = replies.len == 0 and !thread_loading;
    const rows_ctx = ui.arena.create(ThreadRows) catch return ui.column(.{}, .{});
    // Group first, then page: a page is twenty CONVERSATIONS, not twenty notes, so
    // a reply with a busy branch counts once.
    const grouped = groupThreadBlocks(ui, replies);
    // Replies from people the reader follows rank first; strangers are held below
    // one quiet line, never dropped. The partition is stable, so it preserves the
    // arrival and chronological order inside each tier.
    const split = splitByFollowGraph(ui, grouped, root.pubkey);
    const shown = @min(split.inside.len, model.thread_page[@min(level, model.thread_page.len - 1)] * thread_page_size);
    rows_ctx.* = .{
        .model = model,
        .root = root,
        .ancestors = ancestorsFor(ui, level, root, occluded),
        .blocks = split.inside,
        .shown = shown,
        .hidden = split.inside.len - shown,
        .hidden_held = heldReplies(split.inside[shown..]),
        .outside = split.outside,
        .outside_held = heldReplies(split.outside),
        .outside_open = model.thread_outside_open[@min(level, model.thread_outside_open.len - 1)],
        .skeletons = loading,
        .empty = empty,
        // The empty state says the same thing in its own words, so the footer
        // would only repeat it.
        .footer = !empty,
    };
    // Filled from the context while it is alive and valid, and handed to the
    // SDK in its place. See `RowExtents`.
    const table = &g_thread_extents[@min(level, g_thread_extents.len - 1)];
    table.reset();
    if (!occluded) {
        var row: usize = 0;
        const total = rows_ctx.count();
        while (row < total) : (row += 1) table.push(threadRowHeight(rows_ctx, row));
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("thread-{d}", .{level_key}),
        // Nothing to cover when nothing is drawn. A list that declares items and
        // builds none is permanently "undercovered", so the runtime answers by
        // rebuilding and re-laying out the whole view a second time, every time.
        // The feed learned this; the levels stacked under it have the same shape,
        // and at a back stack two deep or more there is always one occluded.
        .item_count = if (occluded) 0 else rows_ctx.count(),
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Thread" },
    };
    const window = ui.virtualWindow(options);
    // What is ACTUALLY on screen in this level, recorded where the row
    // structures are alive. The two passes that lend registry slots read it on
    // the next tick. See `VisibleSet`.
    if (!occluded) recordThreadVisible(rows_ctx, level, window.first_visible_index, window.last_visible_index);
    // An OCCLUDED level is behind an opaque panel: it is mounted to keep its
    // scroll offset, and nothing it builds can be seen. So it builds nothing.
    // The offset survives on the list's id and its content height, which comes
    // from the row COUNT and the estimates, not from the rows, so the walk back
    // still lands where the reader left. This is not only cheaper, it is what
    // keeps a deep back-stack inside the 1024-node ceiling: a view past it is
    // REFUSED whole, and six mounted levels of a busy thread crossed it.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = threadRowAt(ui, rows_ctx, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (occluded) ui.spacer(0) else threadHeader(ui, model),
        ui.virtualList(options, window, .{rows}),
    });
}

/// Builds the thread row at `index` (see `ThreadRows` for the plan), centred
/// like a feed row. `grow` on the wrapper is safe here: the virtual list
/// positions rows absolutely, so a growing row spreads WIDTH, exactly like the
/// feed's cards (the old plain-scroll column grew rows VERTICALLY instead,
/// which is why these wrappers were once forbidden).
fn threadRowAt(ui: *AppUi, rows_ctx: *const ThreadRows, index: usize) AppUi.Node {
    const plan = rows_ctx.rowAt(index);
    const inner = switch (plan) {
        .ancestor => |ai| ancestorRow(ui, &rows_ctx.ancestors[ai], ai == 0),
        .focal => threadRoot(ui, rows_ctx.root, rows_ctx.ancestors.len == 0),
        .composer => replyComposer(ui, rows_ctx.model, rows_ctx.root),
        // `first` draws the full-width rule under the note being answered, and
        // `last` suppresses the trailing one: a rule with nothing under it is a
        // dangling line, and its trailing space is what tips a thread that fits
        // into reporting more content than it draws. So the flags are about what
        // is ACTUALLY above and below the block, held replies included.
        .block => |bi| replyBlock(ui, &rows_ctx.blocks[bi], rows_ctx.root.pubkey, bi == 0, bi + 1 == rows_ctx.shown and rows_ctx.hidden == 0 and rows_ctx.outside.len == 0),
        .outside_block => |oi| replyBlock(ui, &rows_ctx.outside[oi], rows_ctx.root.pubkey, oi == 0 and rows_ctx.shown == 0, oi + 1 == rows_ctx.outside.len),
        .show_more => showMoreReplies(ui, rows_ctx.hidden_held),
        .outside_line => outsideGraphRow(ui, rows_ctx.outside_held, rows_ctx.outside_open),
        .footer => listeningFooter(ui),
        .empty => threadEmptyNote(ui),
        .skeleton => replySkeleton(ui),
    };
    var node = ui.row(.{ .grow = 1, .main = .center }, .{inner});
    // Stable row identity for the windowed reconciler: the note's own id, or a
    // synthetic high-bit key for the placeholder rows (their bit sits above the
    // masked 63-bit note-id space, so no collision).
    // A row with no note of its own is keyed by WHAT IT IS, not by where it sits:
    // a key folds into every descendant's identity, so keying the composer by
    // index would hand it a new identity, and drop the caret mid-typing, the
    // moment a missing ancestor resolves and every row below it shifts down.
    node.key = .{
        .int = switch (plan) {
            .focal => @intCast(rows_ctx.root.id),
            .block => |bi| @intCast(rows_ctx.blocks[bi].parent.id),
            .outside_block => |oi| @intCast(rows_ctx.outside[oi].parent.id),
            // A ghost row has no note behind it, so it takes a synthetic key like
            // the other placeholders, folding in its seat in the chain.
            .ancestor => |ai| if (rows_ctx.ancestors[ai].ghost == .none)
                @intCast(rows_ctx.ancestors[ai].note.id)
            else
                placeholderKey(@intFromEnum(std.meta.activeTag(plan)), ai),
            // Skeletons repeat, so they keep their position; every other
            // placeholder appears at most once in a level.
            .skeleton => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), index),
            else => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), 0),
        },
    };
    return node;
}

/// A key for a row with no note behind it: its kind, plus a discriminator for the
/// kinds that can repeat. The high bit sits above the masked 63-bit note-id
/// space, so it can never collide with a real note.
fn placeholderKey(kind: u64, nth: usize) u64 {
    return (@as(u64, 1) << 63) | (kind << 32) | @as(u64, @intCast(nth));
}

/// The open thread's replies read from the store at render time, into the arena,
/// oldest first. Used for the ANCESTOR levels (the current level reads its cached
/// `thread_notes` instead): they are occluded, so a per-frame read keeps their
/// scroll content stable without a second full reply cache. The `#e` closure
/// walk is the costly part, so its RESULT (the id set) is cached per level and
/// re-walked only when the store's event count moves; the notes themselves are
/// rebuilt into the frame arena from cheap point reads.
fn threadRepliesFromStore(ui: *AppUi, level: usize, root_event_id: [32]u8) []const Note {
    const store = g_store orelse return &.{};
    const cache = &thread_model.g_level_replies[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize) or cache.stamp != stamp or !std.mem.eql(u8, &cache.root, &root_event_id)) {
        cache.root = root_event_id;
        cache.stamp = stamp;
        cache.len = collectThreadIds(store, root_event_id, &cache.ids);
    }
    const now = nowSeconds();
    const notes = ui.arena.alloc(Note, cache.len) catch return &.{};
    var n: usize = 0;
    for (cache.ids[0..cache.len]) |id| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        notes[n] = noteFrom(se.event, now);
        n += 1;
    }
    // The SAME order the level had when it was the open thread, from the SAME
    // table: a level is mounted underneath precisely so the walk back lands where
    // the reader left it, and a second sort here would re-order the rows under an
    // offset restored for the first. This level is not fetching (its own fetch
    // finished before the reader moved on), so anything new here is genuinely
    // late and opens a batch.
    stampArrival(arrivalTableFor(level, root_event_id), notes[0..n], true);
    arrangeThread(notes[0..n], root_event_id);
    return notes[0..n];
}

/// The chain above the focal note, as rows: the ancestors in the store (oldest
/// first) with a ghost row on top when the chain does not reach the thread's
/// opening note. Built into the frame arena from the cached id list, like the
/// occluded levels' replies.
///
/// Every mounted level computes its own chain, INCLUDING the occluded ones: a
/// level's row plan has to be the same when it is beneath the current thread as
/// when it is the current thread, or its restored scroll offset would land
/// somewhere else on the way back.
fn ancestorsFor(ui: *AppUi, level: usize, focal: *const Note, occluded: bool) []const Ancestor {
    if (!focal.has_reply_parent) return &.{};
    const store = g_store orelse return &.{};
    if (level >= thread_model.g_ancestor_chains.len) return &.{};
    const chain = &thread_model.g_ancestor_chains[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize)) return &.{};
    if (chain.stamp != stamp or !std.mem.eql(u8, &chain.focal, &focal.event_id)) {
        refreshAncestorChain(chain, store, focal, stamp);
    }

    const ghost = @intFromBool(chain.gap != .none);
    const rows = ui.arena.alloc(Ancestor, chain.len + ghost) catch return &.{};
    if (ghost == 1) rows[0] = .{ .ghost = chain.gap, .is_root = chain.gap_is_root };
    var n: usize = ghost;
    // An occluded level draws nothing, so it reads nothing: the row count and
    // the cached line counts are the whole of what its estimates need, and its
    // content height (which is what its restored scroll offset is measured
    // against) comes out identical either way.
    if (occluded) {
        for (chain.lines[0..chain.len]) |lines| {
            rows[n] = .{ .lines = lines };
            n += 1;
        }
        return rows[0..n];
    }
    const now = nowSeconds();
    for (chain.ids[0..chain.len], chain.lines[0..chain.len]) |id, lines| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        rows[n] = .{ .note = noteFrom(se.event, now), .lines = lines };
        n += 1;
    }
    return rows[0..n];
}

/// The quiet line under a note that has no replies, so an empty thread reads as
/// "nothing here yet" rather than a lone post over a wall of blank space.
fn threadEmptyNote(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .main = .center }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "No replies yet. Yours would be the first.", .scale = stat_scale }}),
        }),
        vgap(ui, 12),
        // What the thread is doing about it, rather than a dead end: the
        // subscription is open and a reply will appear when one lands.
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = p.status_success, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = pluralize(ui, liveRelayCount(), "listening on {d} relay", "listening on {d} relays"), .monospace = true, .scale = mono_meta_scale }},
            ),
        }),
    });
}

/// A back control: a chevron, where it goes, and a press.
///
/// `ui.row`, NOT `ui.el(.data_row, ...)`, and that is the whole point of this
/// function existing. A `.data_row` does not take its width from its children:
/// it lays out at ZERO wide while its chevron and label paint outside it. The
/// row containing it then places the next sibling at the back control's own x
/// plus the gap, so the screen's title is drawn ON TOP of the thing that goes
/// back. Three headers did this, and the thread's read as one unbroken smear of
/// "Starter pack", "Thread" and "3 replies" in the same place.
///
/// The zero width is invisible to the widget tree and to mouse input, which
/// hit-tests to the label and walks UP to whatever claims the press. Only a
/// laid-out frame shows it, which is why `no control that can be pressed is
/// laid out at nothing` measures rather than inspects.
fn backControl(ui: *AppUi, label: []const u8, press: Msg) AppUi.Node {
    const p = theme.palette;
    return pressRow(ui, .{
        .cross = .center,
        .gap = 3,
        .padding = 4,
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Back", .focusable = true },
    }, .{
        ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
        ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_muted } }, label),
    });
}

/// What Back says it goes to, read from the same state `closeThread` acts on so
/// the two cannot disagree: the level stacked underneath, else Notifications when
/// that is the way back, else the feed.
fn backLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
    if (model.thread_stack_len > 0) return model.thread_stack[model.thread_stack_len - 1].backLabel(arena);
    if (model.notifications_return) return "Notifications";
    return model.scope_name();
}

/// The thread header: a Back affordance (to the parent thread, or the feed), the
/// "Thread" label, and the reply count (known from the crowd count up front, so
/// it reads right before the replies are fetched).
fn threadHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Back names WHERE it goes, never a bare "Thread" beside the "Thread" title.
    const back_label = backLabel(model, ui.arena);
    const count = model.threadReplyCount();
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            backControl(ui, back_label, .close_thread),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Thread", .weight = .bold }}),
            // The count reads once replies are known; before then it says nothing
            // rather than a misleading "0 replies" on a note that has some.
            if (count > 0)
                ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_faint_alt } }, ui.fmt("{d} {s}", .{ count, if (count == 1) "reply" else "replies" }))
            else
                ui.spacer(0),
            ui.spacer(1),
        }),
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

// ------------------------------------------------------------- the article reader
//
// A kind:30023 opened by id is a level of its own, drawn as a reader rather than
// as a thread. It is the same level in every other way (the back-stack, the
// scroll offset kept per level, the avatar and picture passes), so the only fork
// is in `feedView`, which asks `isArticleRoot` of the level's root.
//
// The body is not baked into the `Note`: that struct carries a few kilobytes of
// text because it is copied on every rebuild, and an article is tens of
// kilobytes. It is read from the store when the level is first drawn and kept
// here, cut into rows (see `article.chunk`) so that only the rows near the
// viewport are built, the way the feed and the thread are.

/// The reading column. The width a note's picture takes, so a cover lines up
/// with the text beneath it and the column is a comfortable line length with
/// real margin either side of it in the 620 point row.
const article_text_width: f32 = picture_column_width;
const article_title_scale: f32 = 25.0 / 14.5;
const article_summary_scale: f32 = 16.0 / 14.5;
const article_foot_pad: f32 = 56;

/// One article, loaded for reading. Owns its text; replaced when another opens.
const ArticleView = struct {
    arena: std.heap.ArenaAllocator,
    event_id: [32]u8,
    title: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    tags: [article.max_tags][]const u8 = [_][]const u8{""} ** article.max_tags,
    tag_count: usize = 0,
    published_at: i64 = 0,
    minutes: u32 = 1,
    chunks: [article.max_chunks]article.Chunk = undefined,
    chunk_count: usize = 0,
    truncated: bool = false,

    /// Rows in the list: the head, each piece of the body, and the foot.
    fn rowCount(self: *const ArticleView) usize {
        return self.chunk_count + 2;
    }
};

/// The cap on the body Plaza will read. Relays refuse events well under this, so
/// it bounds the copy rather than the article.
const article_body_cap = 1 << 20;

/// The article on screen. UI-thread only. Only the front level draws a body, so
/// one is enough: walking back to an article underneath reads it again, which is
/// one store lookup.
var g_article: ?*ArticleView = null;

/// The article behind `event_id`, read from the store the first time it is asked
/// for. Null when this machine does not hold it, or holds something that is not
/// a published article.
fn articleFor(event_id: [32]u8) ?*const ArticleView {
    if (g_article) |held| {
        if (std.mem.eql(u8, &held.event_id, &event_id)) return held;
    }
    const store = g_store orelse return null;
    var se = (store.getEvent(std.heap.page_allocator, event_id) catch return null) orelse return null;
    defer se.deinit();
    if (se.event.kind != article.kind) return null;

    const view = std.heap.page_allocator.create(ArticleView) catch return null;
    view.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .event_id = event_id };
    const a = view.arena.allocator();
    const meta = article.metaOf(se.event);
    const loaded = blk: {
        view.title = article.cleanLine(a, meta.title, 400, false) catch break :blk false;
        view.summary = article.cleanLine(a, meta.summary, 1200, true) catch break :blk false;
        view.body = a.dupe(u8, article.clipUtf8(se.event.content, article_body_cap)) catch break :blk false;
        for (meta.tags[0..meta.tag_count], 0..) |t, i| view.tags[i] = a.dupe(u8, t) catch break :blk false;
        break :blk true;
    };
    if (!loaded) {
        view.arena.deinit();
        std.heap.page_allocator.destroy(view);
        return null;
    }
    view.tag_count = meta.tag_count;
    view.published_at = meta.published_at;
    view.minutes = article.readingMinutes(view.body);
    const cut = article.chunk(view.body, &view.chunks);
    view.chunk_count = cut.len;
    view.truncated = cut.truncated;

    if (g_article) |old| {
        old.arena.deinit();
        std.heap.page_allocator.destroy(old);
    }
    g_article = view;
    return view;
}

/// Whether a level's root is an article to be read rather than a thread.
fn isArticleRoot(root: *const Note) bool {
    return root.kind == article.kind;
}

/// Forgets the loaded article, for a test that opens several in turn.
pub fn forgetArticleForTest() void {
    if (g_article) |old| {
        old.arena.deinit();
        std.heap.page_allocator.destroy(old);
    }
    g_article = null;
}

/// How many rows the reader built for the article behind `event_id`, and how many
/// the list was told about. The difference is the whole point of windowing.
pub fn articleRowCountForTest(event_id: [32]u8) usize {
    return if (articleFor(event_id)) |a| a.rowCount() else 0;
}

/// Row `index` of the article `root` names, built the way the reader builds it,
/// so a test can read every row and not only the ones a viewport would mount.
pub fn articleRowForTest(ui: *AppUi, root: *const Note, index: usize) AppUi.Node {
    return articleRowAt(ui, root, articleFor(root.event_id), index);
}

/// A height guess for the head: the byline, the title and summary at their
/// wrapped lengths, the cover, and the date line.
fn articleHeadHeight(root: *const Note, av: ?*const ArticleView) f32 {
    var h: f32 = 20 + avatar_size + 18 + 16 + 12 + 1 + 20;
    const title = if (av) |a| a.title else root.content();
    const title_lines = @max(@ceil(@as(f32, @floatFromInt(@max(title.len, 1))) / 39), 1);
    h += title_lines * 14.5 * article_title_scale * 1.3 + 10;
    if (av) |a| {
        if (a.summary.len > 0) {
            const lines = @max(@ceil(@as(f32, @floatFromInt(a.summary.len)) / 62), 1);
            h += lines * 14.5 * article_summary_scale * 1.4 + 12;
        }
    }
    if (root.hasImage()) h += pictureHeight(root) + 14;
    return h + 22;
}

fn articleFootHeight(av: ?*const ArticleView) f32 {
    const a = av orelse return article_foot_pad;
    return article_foot_pad + (if (a.tag_count > 0) @as(f32, 30) else 0) + (if (a.truncated) @as(f32, 30) else 0);
}

fn articleHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // The same answer the thread header gives, from the state Back acts on.
    const back_label = backLabel(model, ui.arena);
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            backControl(ui, back_label, .close_thread),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Article", .weight = .bold }}),
            ui.spacer(1),
        }),
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

/// The byline, the title, the summary, the cover and the date: what the card in
/// a feed would say, at the size of the thing being read.
fn articleHead(ui: *AppUi, root: *const Note, av: ?*const ArticleView) AppUi.Node {
    const p = theme.palette;
    const title = if (av) |a| a.title else root.content();
    return ui.column(.{ .width = article_text_width, .gap = 0 }, .{
        vgap(ui, 20),
        ui.row(.{ .gap = 0, .cross = .center }, .{
            noteAvatar(ui, root),
            hgap(ui, avatar_to_text_gap),
            identityBlock(ui, root),
            ui.spacer(1),
        }),
        vgap(ui, 18),
        if (title.len > 0)
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = title, .weight = .bold, .scale = article_title_scale }},
            )
        else
            ui.spacer(0),
        if (title.len > 0) vgap(ui, 10) else ui.spacer(0),
        if (av) |a| (if (a.summary.len > 0) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = a.summary, .scale = article_summary_scale }},
        ) else ui.spacer(0)) else ui.spacer(0),
        if (av) |a| (if (a.summary.len > 0) vgap(ui, 12) else ui.spacer(0)) else ui.spacer(0),
        if (root.hasImage()) notePicture(ui, root) else ui.spacer(0),
        if (root.hasImage()) vgap(ui, 14) else ui.spacer(0),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{
                .text = if (av) |a|
                    ui.fmt("{s} · {d} min read", .{ absoluteNoteTime(ui.arena, a.published_at), a.minutes })
                else
                    "Not on this machine yet",
                .monospace = true,
                .scale = mono_hint_scale,
            }},
        ),
        vgap(ui, 16),
        ui.separator(.{ .style = .{ .foreground = p.divider_card, .background = p.divider_card } }),
        vgap(ui, 12),
    });
}

/// The hashtags the author filed it under, as the same pressable topics a note's
/// hashtags are, and a line saying so when the body was cut.
fn articleFoot(ui: *AppUi, av: ?*const ArticleView) AppUi.Node {
    const p = theme.palette;
    const a = av orelse return vgap(ui, article_foot_pad);
    var spans: [article.max_tags * 2]canvas.TextSpan = undefined;
    var n: usize = 0;
    for (a.tags[0..a.tag_count]) |tag| {
        const link = topicLinkFor(tag) orelse continue;
        if (n > 0) {
            spans[n] = .{ .text = "  " };
            n += 1;
        }
        spans[n] = .{ .text = ui.fmt("#{s}", .{tag}), .color = .text_muted, .link = link };
        n += 1;
    }
    return ui.column(.{ .width = article_text_width, .gap = 0 }, .{
        vgap(ui, 8),
        if (n > 0) ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = p.text_muted } }, spans[0..n]) else ui.spacer(0),
        if (a.truncated) vgap(ui, 10) else ui.spacer(0),
        if (a.truncated) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = "This article is longer than Plaza shows. The rest is in the original.", .scale = join_sub_scale }},
        ) else ui.spacer(0),
        vgap(ui, article_foot_pad),
    });
}

/// One row of the list. `index` 0 is the head, the last is the foot, and the
/// ones between are the body, each rendered from its own slice of the markdown.
fn articleRowAt(ui: *AppUi, root: *const Note, av: ?*const ArticleView, index: usize) AppUi.Node {
    const inner: AppUi.Node = if (index == 0)
        articleHead(ui, root, av)
    else if (av) |a| (if (index > a.chunk_count)
        articleFoot(ui, av)
    else blk: {
        const c = a.chunks[index - 1];
        const piece = a.body[c.start..c.end];
        // A row cut out of the middle of a long code block gets its fence back,
        // or the rest of the listing would be read as prose.
        const source = if (c.in_fence) ui.fmt("```\n{s}", .{piece}) else piece;
        break :blk ui.column(.{ .width = article_text_width, .gap = 0 }, .{
            vgap(ui, 6),
            canvas.markdown.Markdown(Msg).view(ui, source, .{
                .on_link = AppUi.linkMsg(.open_url),
                .details_expanded = &article_details_open,
            }),
            vgap(ui, 6),
        });
    }) else articleFoot(ui, av);
    var node = ui.row(.{ .grow = 1, .main = .center }, .{inner});
    node.key = .{ .int = placeholderKey(@intFromEnum(KindOfRow.article), index) };
    return node;
}

/// A `<details>` block in an article is drawn open. The toolkit draws one closed
/// unless told otherwise, and opening it needs a message and a place in the model
/// per block per row; with neither, what the author put inside could not be read
/// at all.
const article_details_open = [_]bool{true} ** canvas.markdown.max_markdown_details_per_document;

/// Row identities in a reader share `placeholderKey`'s space with the thread's
/// placeholder rows; the number only has to differ from theirs.
const KindOfRow = enum(u64) { article = 40 };

/// The reader for one level: the header bar over a windowed list of the body.
/// `occluded` levels build nothing and keep their place, exactly as a thread's do.
fn articlePanel(ui: *AppUi, model: *const Model, root: *const Note, level_key: u64, level: usize, occluded: bool) AppUi.Node {
    const av = if (occluded) null else articleFor(root.event_id);
    const total: usize = if (av) |a| a.rowCount() else 1;
    const table = &g_thread_extents[@min(level, g_thread_extents.len - 1)];
    table.reset();
    if (!occluded) {
        table.push(articleHeadHeight(root, av));
        if (av) |a| {
            for (a.chunks[0..a.chunk_count]) |c| table.push(c.height);
            table.push(articleFootHeight(av));
        }
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("thread-{d}", .{level_key}),
        .item_count = if (occluded) 0 else total,
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 2,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Article" },
    };
    const window = ui.virtualWindow(options);
    if (!occluded) {
        const set = &g_level_visible[@min(level, g_level_visible.len - 1)];
        set.reset();
        g_visible_level = @min(level, g_level_visible.len - 1);
        // Only while the head is on screen: the face and the cover are both in
        // it, and a reader deep in the body has no use for either.
        if (window.first_visible_index == 0) {
            set.pushAuthor(root.pubkey);
            set.pushNote(root.id);
        }
    }
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = articleRowAt(ui, root, av, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (occluded) ui.spacer(0) else articleHeader(ui, model),
        ui.virtualList(options, window, .{rows}),
    });
}

/// A placeholder reply row shown while the first fetch is still out: a skeleton
/// avatar and lines the same shape a real reply takes, so the thread reads as
/// "loading" rather than "empty".
fn replySkeleton(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width }, .{
        ui.row(.{ .gap = 12, .cross = .start, .padding = 14 }, .{
            ui.el(.skeleton, .{ .width = avatar_size, .height = avatar_size }, .{}),
            ui.column(.{ .gap = 8, .grow = 1, .padding = 3 }, .{
                ui.el(.skeleton, .{ .width = 130, .height = 10 }, .{}),
                ui.el(.skeleton, .{ .height = 10 }, .{}),
                ui.el(.skeleton, .{ .width = 220, .height = 10 }, .{}),
            }),
        }),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
    });
}

/// The @handle for a thread identity line: the same label and the same ink rule
/// the feed's identity block uses (violet for a NIP-05, muted for a kind:0 name
/// or a short npub), or a thin skeleton while the profile is still loading, so the
/// line does not visibly fill in a beat later. `fill` grows the element to hang
/// the time to the far right (reply rows); the root note puts the handle on its
/// own line, so it does not.
fn identityHandle(ui: *AppUi, note: *const Note, fill: bool) AppUi.Node {
    const p = theme.palette;
    const label = note.handleLabel(ui.arena);
    const h = label.text;
    const ink = if (label.nip05) identityInk() else p.text_faint;
    if (h.len > 0) {
        return if (fill)
            ui.text(.{ .grow = 1, .style = .{ .foreground = ink } }, h)
        else
            ui.text(.{ .size = .sm, .style = .{ .foreground = ink } }, h);
    }
    // Profile still being fetched: a placeholder rather than an empty gap. Once
    // it resolves (handle or none) or we give up, this stops showing.
    if (profileLoading(note.pubkey)) {
        const bar = ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
        return if (fill) ui.row(.{ .grow = 1, .cross = .center }, .{bar}) else bar;
    }
    return if (fill) ui.spacer(1) else ui.spacer(0);
}

/// The focused root note: the same 40px avatar and 14px inset as the feed and
/// the replies (so every row's avatar and text share one left edge), set apart
/// by a slightly larger name, the name-over-handle stack, and the composer below.
fn threadRoot(ui: *AppUi, note: *const Note, leads: bool) AppUi.Node {
    const c = engagementFor(note.id);
    // A fixed-width column, centred by the scroll column's `cross = .center`. No
    // outer growing row: a `grow` child in the scroll's column grows vertically
    // and would overlap the next row. Every block inside sits 4px in, which is
    // the focal note's own inset within the reading column.
    return ui.column(.{
        .width = thread_column_width,
        .gap = 0,
        // The focal note answers a right-click like every other post. `in_thread`
        // drops "Open thread" from the list, which from the note the thread is
        // ABOUT would be an offer to arrive where the reader already is.
        .context_menu = noteContextItems(ui, note, true),
    }, .{
        // The space above the focal note, unless an ancestor row is up there: its
        // own bottom pad is the rail's segment down to this disc, and adding both
        // would break the chain's rhythm exactly where the eye follows it.
        if (leads) vgap(ui, focal_leading_pad) else ui.spacer(0),
        // The identity line, at the disc's height, with the overflow menu at the
        // far end. No timestamp here: the focal note states its time in full
        // below, where there is room to be exact.
        ui.row(.{ .gap = 0, .cross = .center }, .{
            hgap(ui, thread_inset),
            noteAvatar(ui, note),
            hgap(ui, avatar_to_text_gap),
            identityBlock(ui, note),
            ui.spacer(1),
            // No overflow trigger up here any more. Every post carries its menu
            // as the last verb under it now, this note included, and two
            // triggers keyed on the same note opened two identical menus at
            // once: the state is per NOTE, not per control.
            hgap(ui, thread_inset),
        }),
        vgap(ui, 9),
        // One register up from a feed row: this is the note being read.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                focalBody(ui, note),
                if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                vgap(ui, 9),
                focalMeta(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        vgap(ui, 12),
        focalStats(ui, c),
        focalVerbs(ui, note),
    });
}

/// The focal note's body: the SAME builder every other note uses, one register up.
/// Writing a second paragraph path here cost the embedded quote card, which is
/// exactly the kind of quiet loss a parallel implementation buys.
fn focalBody(ui: *AppUi, note: *const Note) AppUi.Node {
    return noteBodyAt(ui, note, false, focal_body_scale, theme.palette.text_focal);
}

/// When the focal note was written and how widely it is held.
///
/// The note's address used to sit here as a copyable pill, sixty characters of
/// bech32 under every focal note. It is in the note's own menu now, under
/// "Copy note address", which is where a reader looks for a thing to copy and
/// is not where a reader looks while reading.
fn focalMeta(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const seen = relaysSeenFor(note.id);
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{
                .text = if (seen > 0)
                    ui.fmt("{s} · {s}{s}", .{
                        absoluteNoteTime(ui.arena, note.created_at),
                        pluralize(ui, seen, "seen on {d} relay", "seen on {d} relays"),
                        viaSuffix(ui, note),
                    })
                else
                    // Nothing delivered it this session (it came off disk), so the
                    // line says when it was written and what wrote it, and stops.
                    ui.fmt("{s}{s}", .{ absoluteNoteTime(ui.arena, note.created_at), viaSuffix(ui, note) }),
                .monospace = true,
                .scale = mono_hint_scale,
            }},
        ),
        ui.spacer(1),
    });
}

/// The focal note's tallies, as words rather than icons: the verbs below carry
/// the actions, so these are the numbers, stated plainly.
///
/// A tally that has been turned off is GONE, not zeroed. It used to be zeroed,
/// which meant somebody who switched every count off in Settings watched the
/// feed lose its numbers and then opened a thread to "0 replies 0 reposts 0
/// likes 0 sats" across the top of it. That is worse than leaving them on: it
/// states four facts about the note, all four of them false, in the register the
/// app uses for facts. This line is nothing BUT counts, so when a count is
/// hidden there is nothing left for it to say, and when every one is hidden
/// there is nothing left for the band to say either.
fn focalStats(ui: *AppUi, c: Counts) AppUi.Node {
    const p = theme.palette;
    const stats = [_]struct { hidden: bool, count: u64, one: []const u8, many: []const u8 }{
        .{ .hidden = countHidden(.replies, .reply_counts), .count = c.replies, .one = "reply", .many = "replies" },
        .{ .hidden = countHidden(.reposts, .repost_counts), .count = c.reposts, .one = "repost", .many = "reposts" },
        .{ .hidden = countHidden(.reactions, .reaction_counts), .count = c.likes, .one = "like", .many = "likes" },
        .{ .hidden = countHidden(.zaps, .zap_totals), .count = c.zap_msat / 1000, .one = "sat", .many = "sats" },
    };
    // Two leading gaps, then at most a tally and its separating gap per stat,
    // then the trailing spacer. Counted from `stats` rather than written as the
    // 10 it currently comes to, so a fifth tally cannot outgrow its own row.
    const kids = ui.arena.alloc(AppUi.Node, 2 + stats.len * 2) catch return ui.spacer(0);
    var n: usize = 0;
    kids[n] = hgap(ui, thread_inset + 2);
    n += 1;
    kids[n] = vgap(ui, 33);
    n += 1;
    var any = false;
    for (stats) |stat| {
        if (stat.hidden) continue;
        // The gap belongs BETWEEN tallies, so it is charged by the one that
        // follows another rather than reserved by every one of them: hiding the
        // first would otherwise leave the row starting 18px further in than the
        // note above it.
        if (any) {
            kids[n] = hgap(ui, 18);
            n += 1;
        }
        kids[n] = statCount(ui, stat.count, stat.one, stat.many);
        n += 1;
        any = true;
    }
    if (!any) return ui.spacer(0);
    kids[n] = ui.spacer(1);
    n += 1;
    return ui.column(.{ .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        ui.row(.{ .cross = .center, .gap = 0 }, .{kids[0..n]}),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

fn statCount(ui: *AppUi, n: u64, singular: []const u8, plural: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{
        .{ .text = if (n == 0) "0" else formatCount(ui.arena, n), .weight = .medium, .color = .text, .scale = stat_scale },
        .{ .text = ui.fmt(" {s}", .{if (n == 1) singular else plural}), .scale = stat_scale },
    });
}

/// The focal note's verbs: the SAME row every other note carries.
///
/// It used to be two glyphs, a like and an open-on-the-web, shoved to opposite
/// ends of the column by a grow spacer. Two verbs is not the row a reader has
/// just scrolled past a screenful of, and forty pixels of nothing between them
/// reads as a row that lost its middle. The counts are left off, because the
/// stats line directly above states them in words: this is the same builder,
/// told not to repeat itself.
fn focalVerbs(ui: *AppUi, note: *const Note) AppUi.Node {
    if (!anyVerbShown()) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 2),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            engagementRowAt(ui, note, false),
        }),
        vgap(ui, 4),
    });
}

pub fn splitByFollowGraphForTest(ui: *AppUi, blocks: []const ThreadBlock, author: [32]u8) GraphSplit {
    return splitByFollowGraph(ui, blocks, author);
}

pub fn followSetForTest() []const [32]u8 {
    return followSet();
}

/// A profile's two tabs. "Notes" is what they wrote; "Replies" is what they
/// wrote at somebody else.
pub const ProfileTab = enum { notes, replies };

/// One level of the back stack: a thread, or a person.
///
/// Both are levels rather than layers because the SDK tracks at most 8 virtual
/// windows per build and an OCCLUDED level still registers one: the feed plus
/// six stacked levels plus the current is already exactly eight. A profile that
/// layered ON TOP of a full thread stack would be a ninth window, silently
/// dropped in a release build. Sharing the depth budget is what keeps that
/// impossible rather than merely unlikely.
pub const Screen = struct {
    /// The thread's root note. Unused when this level is a profile.
    note: Note = .{},
    /// Whose profile this level shows, when it is one.
    profile: ?[32]u8 = null,
    /// How far down that person's notes the reader had paged. Back reads this
    /// many again, so the list is as long as it was and the scroll offset the
    /// list kept lands on the note they left from, not past the end of a list
    /// cut back to its first page.
    profile_limit: usize = profile_page,
    /// Whether this level is the bookmark list.
    bookmarks: bool = false,
    /// The topic this level shows, when it is one. A VALUE rather than a slice:
    /// a level sits on the stack across rebuilds, and anything it pointed at in
    /// the frame arena would be gone by the time Back reached it.
    topic_buf: [max_topic_bytes]u8 = undefined,
    topic_len: u8 = 0,

    pub fn isProfile(self: Screen) bool {
        return self.profile != null;
    }

    pub fn topic(self: *const Screen) ?[]const u8 {
        return if (self.topic_len == 0) null else self.topic_buf[0..self.topic_len];
    }

    /// What Back says it goes to: a person's name, or the author of the note
    /// underneath. Back names WHERE it lands, never what it leaves.
    pub fn backLabel(self: *const Screen, arena: std.mem.Allocator) []const u8 {
        if (self.bookmarks) return "Bookmarks";
        if (self.topic()) |t| return std.fmt.allocPrint(arena, "#{s}", .{t}) catch t;
        if (self.profile) |pk| {
            if (lookupProfile(pk)) |prof| {
                if (prof.name_len > 0) return prof.name();
            }
            return "Profile";
        }
        return self.note.author();
    }
};

// ---------------------------------------------------------------- muting
//
// The reader's NIP-51 mute list, read and honoured. Not written: a mute list is
// REPLACEABLE, and the rule this app already learned about contact lists holds
// here too, that nothing may write over a record it has not read back first.
// Jumble does the careful version of that write (it re-fetches immediately
// before every change, and when the fetch comes back empty it ASKS rather than
// assuming there is nothing there, because "not found" and "the fetch failed"
// look identical). Doing that properly is its own change; honouring a list made
// elsewhere costs nothing and is most of the value, because muting is something
// people mostly did in whatever client they came from.

// ------------------------------------------------------------- bookmarks

/// The keyholder a test has, for the seal path.
pub fn sealPrivateBookmarkForTest(gpa: std.mem.Allocator, plaintext: []const u8) void {
    const secret = feed_state.g_test_secret orelse {
        private_lists.g_private_seal = .{};
        return;
    };
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        private_lists.g_private_seal = .{};
        return;
    };
    // A test binary has no runtime io, so it makes its own. The seal has to be
    // real: the point of this path is that what gets published decrypts back.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = g_io orelse threaded.io();
    const sealed = nostr.nip44.encrypt(gpa, io, signer, kp.secret_key, kp.public_key, plaintext) catch {
        private_lists.g_private_seal = .{};
        return;
    };
    defer gpa.free(sealed);
    bookmarks.g_test_sealed_len = @intCast(@min(sealed.len, bookmarks.g_test_sealed.len));
    @memcpy(bookmarks.g_test_sealed[0..bookmarks.g_test_sealed_len], sealed[0..bookmarks.g_test_sealed_len]);
}

pub fn lastSealedForTest() []const u8 {
    return bookmarks.g_test_sealed[0..bookmarks.g_test_sealed_len];
}

pub fn finishPrivateBookmarkForTest(model: *Model, fx: *Effects) void {
    finishPrivateBookmark(model, fx, bookmarks.g_test_sealed[0..bookmarks.g_test_sealed_len]);
}

pub fn writePrivateBookmarkForTest(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    return writePrivateBookmark(fx, event_id, adding);
}

pub fn writeBookmarkForTest(fx: *Effects, event_id: [32]u8, adding: bool) BookmarkWrite {
    return writeBookmark(fx, event_id, adding);
}

pub fn loadBookmarksFromStoreForTest() void {
    loadBookmarksFromStore();
}

pub fn forgetBookmarksForTest() void {
    forgetBookmarks();
}

/// Claims a private-half slot the way a reader hitting an encrypted list does,
/// and returns its index, WITHOUT the test keyholder answering it. That is what
/// a bunker reader's state actually looks like: the half is claimed and waiting
/// on a signer that answers over the relay rather than over HTTP.
pub fn claimPrivateHalfPendingForTest(content: []const u8) ?u8 {
    const id = privateHalfId(content);
    for (&private_lists.g_private_halves, 0..) |*h, i| {
        if (h.used) continue;
        if (content.len > private_lists.g_private_ciphertext[i].buf.len) return null;
        h.* = .{ .used = true, .state = .asking, .id = id };
        @memcpy(private_lists.g_private_ciphertext[i].buf[0..content.len], content);
        private_lists.g_private_ciphertext[i].len = @intCast(content.len);
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

fn slotIdForTest(index: u8) [32]u8 {
    if (index >= private_lists.g_private_halves.len) return no_half_id;
    return private_lists.g_private_halves[index].id;
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

/// Whether any parked bunker answer is still waiting for the tick, or still
/// holds plaintext.
pub fn halfInboxHoldsForTest() bool {
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_half_inbox) |*box| {
        if (box.used or box.plain_len != 0) return true;
    }
    return false;
}

/// What the tick does for every idle half when a bunker is the signer: the ask
/// goes out and the half waits for it. The test has no relay to send to.
pub fn markIdleHalvesAskedForTest() void {
    for (&private_lists.g_private_halves) |*h| {
        if (h.used and h.state == .idle) h.state = .asking;
    }
}

/// A decrypt request registered for the half in `index`, with no outcome yet,
/// as `requestRemoteDecrypt` does.
pub fn registerRemoteHalfAskForTest(index: u8, method: RemoteMethod) bool {
    return registerPending("halfask", method, null, false, .none, index, slotIdForTest(index), .{});
}

pub fn privateHalfRetryAtForTest(index: u8) i64 {
    if (index >= private_lists.g_private_halves.len) return -1;
    return private_lists.g_private_halves[index].retry_at_s;
}

pub fn privateHalfRetryDelayForTest() i64 {
    return private_half_retry_s;
}

/// The sweep `scanPrivateHalves` runs each tick, with the clock stated.
pub fn rearmPrivateHalvesForTest(now: i64) void {
    rearmPrivateHalves(now, false);
}

pub fn privateHalfStateForTest(index: u8) []const u8 {
    if (index >= private_lists.g_private_halves.len or !private_lists.g_private_halves[index].used) return "none";
    return switch (private_lists.g_private_halves[index].state) {
        .idle => "idle",
        .asking => "asking",
        .open => "open",
        .refused => "refused",
        .unreadable => "unreadable",
    };
}

pub fn openPrivateHalfForTest(content: []const u8, plain: []const u8) void {
    const id = privateHalfId(content);
    for (&private_lists.g_private_halves) |*h| {
        if (!h.used or std.mem.eql(u8, &h.id, &id)) {
            h.* = .{ .used = true, .state = .open, .id = id };
            const n = @min(plain.len, h.plain_buf.len);
            @memcpy(h.plain_buf[0..n], plain[0..n]);
            h.plain_len = @intCast(n);
            return;
        }
    }
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

/// Delivers one decrypt answer for slot zero the way the runtime would, so a
/// test can drive a keyholder that refuses.
pub fn deliverPrivateHalfForTest(status: u16, body: []const u8) void {
    deliverPrivateHalfKeyedForTest(privateHalfAskKeyForTest(0), status, body);
}

/// The same under a stated key, so an answer can be delivered after the ask it
/// belongs to is long gone.
pub fn deliverPrivateHalfKeyedForTest(key: u64, status: u16, body: []const u8) void {
    handlePrivateHalf(.{ .key = key, .outcome = if (status == 0) .connect_failed else .ok, .status = status, .body = body });
}

/// The key the ask now in flight on slot `index` went out under.
pub fn privateHalfAskKeyForTest(index: u8) u64 {
    return privateHalfKey(index, private_lists.g_private_halves[index].ask_seq);
}

/// Puts slot zero in the "asked, waiting" state for a given ciphertext.
pub fn askPrivateHalfForTest(content: []const u8) void {
    private_lists.g_private_halves[0] = .{ .used = true, .state = .idle, .id = privateHalfId(content) };
    _ = beginHelperAsk(0);
    const n = @min(content.len, private_lists.g_private_ciphertext[0].buf.len);
    @memcpy(private_lists.g_private_ciphertext[0].buf[0..n], content[0..n]);
    private_lists.g_private_ciphertext[0].len = @intCast(n);
}

pub fn privateMutesForTest(content: []const u8, out: [][32]u8) usize {
    return privateMutes(std.heap.page_allocator, content, out);
}

pub fn privateHalfIsReadableForTest(content: []const u8) bool {
    return privateHalfIsReadable(std.heap.page_allocator, content);
}

pub fn forgetPrivateHalvesForTest() void {
    forgetPrivateHalves();
}

pub fn privateHalfGateNameForTest(content: []const u8) []const u8 {
    return @tagName(privateHalfGate(std.heap.page_allocator, content));
}

pub fn writeMuteForTest(fx: *Effects, pubkey: [32]u8, muting: bool) MuteWrite {
    return writeMute(fx, pubkey, muting);
}

/// How many people are on the reader's OWN list, whichever feed is being read.
/// The menu names both feeds at once, so it cannot ask `followTotal`: that one
/// answers for the feed in front of you.
pub fn setHomeScopeForTest(next: HomeScope) void {
    setHomeScope(next);
}

pub fn starterPackLenForTest() usize {
    return starter_pack.len;
}

pub fn forgetOwnListMemoForTest() void {
    forgetOwnListMemo();
}

pub fn ownRelaysAllFinishedForTest() bool {
    return ownRelaysAllFinished();
}

pub fn noteOwnOutboxForTest(ev: nostr.event.Event) void {
    noteOwnOutbox(ev);
}

pub fn noHistoryKnownForTest(kind: ListKind) bool {
    return noHistoryKnown(kind);
}

pub fn needsFreshConsentForTest(kind: ListKind) bool {
    return needsFreshConsent(kind);
}

pub fn confirmStartFreshForTest(kind: ListKind) bool {
    return confirmStartFresh(kind);
}

pub fn retryOwnListsReadForTest() void {
    retryOwnListsRead();
}

/// Pretends the wait has run for `seconds`, for a test that cannot sleep.
pub fn ownListsWaitedForTest(seconds: i64) void {
    const pk = activePubkey() orelse return;
    own_lists.g_own_lists_since = nowSeconds() - seconds;
    own_lists.g_own_lists_since_for = pk;
}

/// What pressing "Create your identity" does to the sign-out latch: drops it
/// before any new key exists. The pubkey latch is what has to hold after this.
pub fn loggedOutForTest() bool {
    return keyholder.g_logged_out;
}

pub fn clearLoggedOutLatchForTest() void {
    keyholder.g_logged_out = false;
}

pub fn setIdentityMintedForTest(minted: bool) void {
    own_lists.g_identity_minted_here = minted;
}

/// The relay now in slot `index` answered. Slots with no relay are ignored, as
/// the ingest thread for an empty seat never dials anything.
pub fn noteContactsAnsweredByForTest(index: usize, pk: [32]u8) void {
    const e = relayAt(index) orelse return;
    noteContactsAnsweredBy(index, e.url(), pk);
}

/// A relay answered from seat `index` at `url`, whatever sits there now: what an
/// answer that arrived just before the seat changed hands leaves behind.
pub fn noteContactsAnsweredFromForTest(index: usize, url: []const u8, pk: [32]u8) void {
    noteContactsAnsweredBy(index, url, pk);
}

pub fn contactsConfirmedAbsentForTest() bool {
    return contactsConfirmedAbsent();
}

pub fn haveOwnContactListForTest() bool {
    return haveOwnContactList();
}

pub fn pendingUndoIsNoneForTest() bool {
    return follows.g_pending_undo == .none;
}

/// Arms an undo directly, for the writes whose real path needs a live note, a
/// live `Effects` or a relay behind it. Arming itself is not what these check:
/// `signAndPublish` takes the record as an argument, so a write cannot reach
/// the signer without one. What they check is that each record puts the right
/// thing back.
pub fn armUndoForTest(u: PendingUndo) void {
    armUndo(u);
}

pub fn markRepostedByMeForTest(note_id: i64) void {
    markRepostedByMe(note_id);
}

pub fn repostedByMeForTest(note_id: i64) bool {
    return engagementFor(note_id).reposted_by_me;
}

pub fn armUnlikeUndoForTest(note_id: i64, reaction_id: [32]u8) void {
    armUndo(.{ .unlike = .{ .note_id = note_id, .reaction_id = reaction_id } });
}

pub fn applyUndoForTest(model: *Model) void {
    applyUndo(model);
}

/// Puts the app in the state a bunker or a Notary key leaves it in: a contact
/// list signed, handed to the signer, and not yet in the store. That gap cannot
/// be driven from a test, because the async paths need a live `Effects`, so the
/// state they produce is set up directly and the write is then driven for real.
pub fn setPendingFollowBaseForTest(tags: []const nostr.event.Tag, content: []const u8, created_at: i64) void {
    setPendingFollowBase(tags, content, created_at);
}

pub fn clearPendingFollowBaseForTest() void {
    clearPendingFollowBase();
}

pub fn pendingFollowCountForTest() ?usize {
    const tags = follows.g_pending_follow_tags orelse return null;
    return countPeople(tags);
}

pub fn countPeopleForTest(tags: []const nostr.event.Tag) usize {
    return countPeople(tags);
}

pub fn shrinkAllowedForTest(before: usize, after: usize, following: bool) bool {
    return shrinkAllowed(before, after, following);
}

pub fn writeFollowForTest(fx: *Effects, pubkey: [32]u8, following: bool) bool {
    return writeFollow(fx, pubkey, following) == .published;
}

pub fn followsFromTagsForTest(tags: []const nostr.event.Tag, out: [][32]u8) usize {
    return followsFromTags(tags, out);
}

pub fn setFollowsForTest(list: []const [32]u8, created_at: i64) bool {
    return setFollows(list, created_at);
}

pub fn forgetFollowsForTest() void {
    follows.g_home_scope = .following;
    forgetFollows();
}

pub fn forgetMutesForTest() void {
    forgetMutes();
    forgetBookmarks();
}

pub fn setMutesForTest(list: []const [32]u8, created_at: i64) bool {
    return setMutes(list, created_at);
}

pub fn loadMutesFromStoreForTest() void {
    loadMutesFromStore();
    loadBookmarksFromStore();
}

pub fn ingestMuteListForTest(ev: nostr.event.Event) void {
    ingestMuteList(ev);
}

pub fn loadFollowsFromStoreForTest() void {
    loadFollowsFromStore();
}

pub fn ingestContactListForTest(ev: nostr.event.Event) void {
    ingestContactList(ev);
}

/// Groups the arranged (depth-stamped, conversation-ordered) replies into blocks.
/// The arrangement is a DFS, so a parent's subtree is contiguous: everything at
/// depth 2 until the next top-level reply is a child, and anything deeper counts
/// against the child it hangs beneath.
pub fn groupThreadBlocks(ui: *AppUi, notes: []const Note) []const ThreadBlock {
    if (notes.len == 0) return &.{};
    const blocks = ui.arena.alloc(ThreadBlock, notes.len) catch return &.{};
    const deeper_pool = ui.arena.alloc(usize, notes.len) catch return &.{};
    var block_count: usize = 0;
    var pool_used: usize = 0;
    var i: usize = 0;
    while (i < notes.len) {
        const parent = &notes[i];
        i += 1;
        const child_start = i;
        var child_count: usize = 0;
        while (i < notes.len and notes[i].depth >= 2) {
            if (notes[i].depth == 2) {
                deeper_pool[pool_used + child_count] = 0;
                child_count += 1;
            } else if (child_count > 0) {
                // Deeper than the one level shown: counted against the child whose
                // branch it continues.
                deeper_pool[pool_used + child_count - 1] += 1;
            }
            i += 1;
        }
        blocks[block_count] = .{
            .parent = parent,
            .children = notes[child_start..][0..child_count],
            .deeper = deeper_pool[pool_used..][0..child_count],
        };
        block_count += 1;
        pool_used += child_count;
    }
    return blocks[0..block_count];
}

/// How many indent steps a reply at `depth` shows. Direct replies (depth 1)
/// sit flush; each further level steps in once, capped so a long back-and-forth
/// never squeezes the text to a sliver; past the cap, deeper replies share the
/// cap's inset (the convention every threaded reader settles on).
const thread_indent_cap = 3;
const thread_indent_step: f32 = 24;

pub fn threadIndentLevels(depth: u8) usize {
    if (depth <= 1) return 0;
    return @min(@as(usize, depth - 1), thread_indent_cap);
}

/// The nesting gutter to the left of an indented reply: one fixed-width cell
/// per ancestor level, each carrying a hairline rail, so siblings at a depth
/// visibly hang off the same line. Empty (and costless) at the top level.
fn threadGutter(ui: *AppUi, levels: usize) AppUi.Node {
    if (levels == 0) return ui.spacer(0);
    const p = theme.palette;
    const cells = ui.arena.alloc(AppUi.Node, levels) catch return ui.spacer(0);
    for (cells) |*cell| {
        // The rail fills the row's height on its own via cross-axis stretch.
        cell.* = ui.row(.{ .width = thread_indent_step, .main = .center }, .{
            ui.separator(.{ .width = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
        });
    }
    return ui.row(.{}, .{cells});
}

/// One top-level reply and the level of conversation under it. The block draws
/// the reply at note size against a rail, then each of its own replies at a
/// smaller register hanging off that rail, then a line for whatever the branch
/// continues into.
///
/// The reply itself is a feed-style row, with an "OP" chip when the replier is
/// the thread's original author, seated under the note it answers by the nesting
/// gutter. The WRAPPER row carries the press and the hover wash, so every
/// horizontal pixel of the row (gutter included) opens this reply as its own
/// thread and washes as one unit; the picture and the engagement controls keep
/// their own presses as the deeper hit targets. The bottom hairline lives INSIDE
/// the content column: it starts after the gutter (so it aligns with the content
/// it separates) and the gutter's rails span the wrapper's full height across it,
/// keeping a sibling run's rail continuous.
///
/// The rail replaces the round-4 indent gutter: the redesign nests ONE level in
/// place and sends the rest to their own thread, rather than stepping every reply
/// further right until the text runs out of room.
/// One line saying this reply answers something the app does not have.
///
/// The same words the ghost row uses at the top of an ancestor chain, for the
/// same reason: the note is not claimed to be gone, only absent from here. It
/// may arrive when a relay answers.
fn orphanNote(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.appIcon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_dim } }, "clock"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "The note this answers is not on your relays yet", .scale = stat_scale }},
            ),
        }),
        vgap(ui, 6),
    });
}

fn replyBlock(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    const p = theme.palette;
    const note = block.parent;
    const kids = ui.arena.alloc(AppUi.Node, block.children.len * 2) catch return ui.spacer(0);
    var n: usize = 0;
    for (block.children, block.deeper) |*child, deeper| {
        kids[n] = nestedReply(ui, child, root_author);
        n += 1;
        if (deeper > 0) {
            kids[n] = branchMore(ui, child, deeper);
            n += 1;
        }
    }

    var node = ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The first block takes the full-width rule that separates the replies
        // from the note they answer; between blocks the rule is inset to the text,
        // so the rails run unbroken down the gutter.
        if (first)
            ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } })
        else
            ui.spacer(0),
        vgap(ui, 12),
        if (note.parent_missing)
            ui.row(.{ .gap = 0 }, .{ hgap(ui, thread_inset + avatar_size + avatar_to_text_gap), orphanNote(ui) })
        else
            ui.spacer(0),
        // No `cross` here: the default stretches the children, which is what
        // gives the rail a height to grow into. Pinned to the top, the disc's
        // column would be exactly as tall as the disc and the rail would draw
        // nothing at all, which is how it shipped invisible.
        // The reply's OWN row, and only it: the wash belongs to the row under the
        // pointer, and a band covering this reply plus everything nested under it
        // is one highlight over three rows.
        ui.el(.data_row, .{
            .width = thread_column_width,
            .padding = 0.01,
            .on_press = Msg{ .open_thread = note.id },
            .context_menu = noteContextItems(ui, note, false),
            .semantics = .{ .label = "Open thread" },
        }, .{
            hgap(ui, thread_inset),
            // The disc, with the rail below it: the line a reply's own replies
            // hang from. It runs to the bottom of this row and the children's
            // section picks it up from there, so the line reads as one.
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    if (isTakenAway(.replies))
                        threadTime(ui, note, true, .{}, .{ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale))})
                    else
                        ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale)),
                }),
                vgap(ui, 5),
                noteBody(ui, note, true),
                if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                vgap(ui, 8),
                engagementRow(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        // What hangs off this reply: its own replies and the line into whatever
        // the branch continues into, in the same gutter so the rail runs on.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.row(.{ .width = avatar_size, .main = .center }, .{
                ui.separator(.{ .width = 2, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.column(.{ .gap = 0 }, .{kids[0..n]}),
                vgap(ui, if (last) 4 else 12),
                // The rule between blocks starts at the text, not the window edge,
                // so the rail crosses it without a break. The last block draws
                // none: a rule with nothing under it is a dangling line, and its
                // trailing space is what tips a thread that fits into reporting
                // more content than it draws.
                if (last)
                    ui.spacer(0)
                else
                    ui.separator(.{ .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
            }),
            hgap(ui, thread_inset),
        }),
    });
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// One note in the chain above the focal note: the same disc and identity block
/// as a reply, a body clamped to two lines, and the rail running down to the next
/// disc. Pressing it focuses that note, which is how a reader walks back up a
/// conversation without leaving the thread.
///
/// The chain is drawn INLINE rather than as the stack of panels it used to be:
/// one scroll, so the ancestors read as the run-up to the note being read instead
/// of as screens behind it. The panel stack stays mounted underneath purely to
/// hold each level's scroll offset for the walk back.
fn ancestorRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    if (ancestor.ghost != .none) return ghostRow(ui, ancestor, first);
    const p = theme.palette;
    const note = &ancestor.note;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        // The row stretches its children (the default cross alignment), which is
        // what gives the rail a height to grow into: pinned to the top instead,
        // the avatar column would be exactly as tall as the disc and the rail
        // would draw nothing.
        // A `list_item`, which is the kind the renderer washes on hover, given an
        // explicit width so it constrains the body instead of sizing to it.
        pressRow(ui, .{
            .width = thread_column_width,
            .padding = 0.01,
            // By EVENT id: an ancestor is neither in the feed nor in the open
            // thread's replies, so the render key `open_thread` resolves through
            // would find nothing and the press would quietly do nothing.
            .on_press = Msg{ .open_event = note.event_id },
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "Focus this note", .focusable = true },
        }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                // The rail, filling whatever is left of the row: the line that
                // ties this note to the one it leads to.
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale)),
                }),
                // The gap stays whatever the body is: it is a term of the row's
                // chrome, and dropping it would make the estimate wrong by 4px
                // for exactly the rows nothing measures.
                vgap(ui, ancestor_identity_gap),
                if (note.content_len == 0 and !noteCovered(note)) ui.spacer(0) else ancestorBody(ui, note),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// An ancestor's body, cut to two lines. The SDK has no multi-line clamp, so the
/// cut is made in the SPANS: building them from the whole text first keeps a
/// mention reading as `@name` rather than as half of a bech32 token.
fn ancestorBody(ui: *AppUi, note: *const Note) AppUi.Node {
    if (noteCovered(note)) return coverNotice(ui, note.warning(), note.id);
    const spans = clampSpansToLines(ui, noteSpans(ui, note, note.content()), ancestor_body_lines);
    return textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
}

/// `spans` cut to at most `lines` lines, with an ellipsis where the cut falls.
///
/// Lines are counted the way the estimator counts them, by characters against a
/// column width, plus every newline the text writes for itself: a note that
/// breaks its own lines is the case a character budget alone gets wrong, and it
/// is a common shape (a note that ends in a `nostr:` reference on its own line).
fn clampSpansToLines(ui: *AppUi, spans: []const canvas.TextSpan, lines: usize) []const canvas.TextSpan {
    const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch return spans;
    // One column of the last line belongs to the ellipsis. Cutting at the full
    // budget and THEN appending it wrapped one character onto a third line,
    // which is a line the estimator does not price and the design does not have.
    const budget = ancestor_chars_per_line - 1;
    var n: usize = 0;
    var line: usize = 1;
    var column: usize = 0;
    for (spans) |span| {
        var cut: ?usize = null;
        for (span.text, 0..) |c, i| {
            // A continuation byte is the middle of a character, not another one.
            if ((c & 0xc0) == 0x80) continue;
            if (c == '\n' or column >= budget) {
                line += 1;
                column = 0;
                if (line > lines) {
                    cut = i;
                    break;
                }
            }
            if (c != '\n') column += 1;
        }
        if (cut) |at| {
            // Back off to a word boundary, so the ellipsis follows a whole word.
            // The budget is the WHOLE span, not `at`: `collapsedLen` returns the
            // length unchanged when the text already fits, so cutting a slice at
            // its own length backs off nowhere.
            const end = collapsedLen(span.text, at);
            if (end > 0) {
                out[n] = span;
                out[n].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, span.text[0..end], " \n")});
                n += 1;
            } else if (n > 0) {
                out[n - 1].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, out[n - 1].text, " \n")});
            }
            return out[0..n];
        }
        out[n] = span;
        n += 1;
    }
    return out[0..n];
}

/// The ancestor row and one reply block, for a test that asserts what they PAINT
/// (the rail between two discs is a grown separator, so it only exists when the
/// row hands its avatar column a height, which is exactly what once went wrong).
pub fn ancestorRowForTest(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    return ancestorRow(ui, ancestor, first);
}

pub fn replyBlockForTest(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    return replyBlock(ui, block, root_author, first, last);
}

/// The rows a level can hold whose height is a fixed constant, so a test can
/// measure each one and hold its estimate to what it actually draws. Every
/// constant here was hand-calibrated once and then drifted.
pub fn ghostRowForTest(ui: *AppUi, capped: bool) AppUi.Node {
    const ancestor: Ancestor = .{ .ghost = if (capped) .capped else .missing };
    return ghostRow(ui, &ancestor, true);
}

pub fn listeningFooterForTest(ui: *AppUi) AppUi.Node {
    return listeningFooter(ui);
}

pub fn outsideGraphRowForTest(ui: *AppUi, open: bool) AppUi.Node {
    return outsideGraphRow(ui, 2, open);
}

pub fn showMoreRepliesForTest(ui: *AppUi) AppUi.Node {
    return showMoreReplies(ui, 3);
}

pub const ghost_row_extent_for_test = ghost_row_extent;
pub const listening_row_extent_for_test = listening_row_extent;
pub const outside_row_extent_for_test = outside_row_extent;
pub const show_more_extent_for_test = show_more_extent;
pub const ancestor_row_chrome_for_test = ancestor_row_chrome;

pub fn ancestorBodyLinesForTest(note: *const Note) f32 {
    return ancestorBodyLines(note);
}

/// The gap at the top of the chain: a dashed seat where a note would be, saying
/// what is missing and what the app is doing about it. Never a spinner over the
/// thread, and never a claim that the note does not exist.
fn ghostRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    const p = theme.palette;
    const capped = ancestor.ghost == .capped;
    const headline: []const u8 = if (capped)
        "Earlier notes in this thread are not shown"
    else if (ancestor.is_root)
        "Root note not on your relays yet"
    else
        "The note this answers is not on your relays yet";
    const detail: []const u8 = if (capped)
        ui.fmt("showing the {d} nearest below", .{thread_ancestor_max})
    else
        pluralize(ui, liveRelayCount(), "asking {d} relay · fills in when one answers", "asking {d} relays · fills in when one answers");
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                // The empty seat: the canvas has no dashed strokes, so the ring is
                // an icon with its dashes baked into the geometry, with the glyph
                // stacked over it.
                ui.stack(.{ .width = avatar_size, .height = avatar_size }, .{
                    ui.appIcon(.{ .width = avatar_size, .height = avatar_size, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                    ui.column(.{ .width = avatar_size, .height = avatar_size, .main = .center, .cross = .center }, .{
                        // A runtime choice of glyph, so `appIcon` (which resolves
                        // the built-in names too) rather than comptime `icon`.
                        ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_dim } }, if (capped) "chevron-up" else "clock"),
                    }),
                }),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 2),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = headline, .scale = nested_name_scale }}),
                vgap(ui, 3),
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = detail, .monospace = true, .scale = mono_meta_scale }}),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// The line at the foot of a thread: the subscription is still open, and what
/// arrives is appended rather than shuffled into what has already been read,
/// which is the promise the reply order keeps.
fn listeningFooter(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const live = liveRelayCount();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The last conversation above closes at 4px (it draws no rule of its
        // own, so nothing dangles), and this makes up the rest of the step.
        vgap(ui, 8),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_row, .background = p.divider_row } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = if (live > 0) p.status_success else p.status_offline, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{
                .text = if (live > 0)
                    "listening · new replies land as relays answer, appended, never reordered"
                else
                    "no relay connected · replies land when one answers",
                .monospace = true,
                .scale = mono_meta_scale,
            }}),
        }),
        vgap(ui, 10),
    });
}

/// A reply to a reply: the one level of nesting the redesign draws in place, at a
/// smaller disc and a smaller register than the reply it answers.
fn nestedReply(ui: *AppUi, note: *const Note, root_author: [32]u8) AppUi.Node {
    const p = theme.palette;
    const is_author = std.mem.eql(u8, &note.pubkey, &root_author);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.el(.data_row, .{
            .grow = 1,
            .padding = 0.01,
            .cross = .start,
            .on_press = Msg{ .open_thread = note.id },
            .context_menu = noteContextItems(ui, note, false),
            .semantics = .{ .label = "Open thread" },
        }, .{
            avatarDisc(ui, note, nested_avatar_size),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .center }, .{
                    ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = note.author(), .weight = .medium, .scale = nested_name_scale }}),
                    // The original poster, marked in their own thread. In the
                    // author's avatar tint, so the chip reads as them.
                    if (is_author) opChip(ui, note.pubkey) else ui.spacer(0),
                    if (note.verified())
                        ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle")
                    else
                        ui.spacer(0),
                    nestedHandle(ui, note),
                    ui.spacer(1),
                    // A nested reply draws no verbs, so its time is the only way
                    // the keyboard has into it (see `threadTime`).
                    threadTime(ui, note, true, .{}, .{ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, nested_meta_scale))}),
                }),
                vgap(ui, 3),
                noteBodyAt(ui, note, true, nested_body_scale, p.text_nested),
            }),
        }),
    });
}

/// The OP chip: the thread's author, marked where they answer inside it.
fn opChip(ui: *AppUi, pubkey: [32]u8) AppUi.Node {
    const tint = avatarTint(pubkey);
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = tint.bg, .border = tint.border, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = tint.glyph } }, &.{.{ .text = "OP", .weight = .medium, .monospace = true, .scale = op_chip_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// A nested reply's handle, one register below the reply it answers.
///
/// The same ladder the row above it uses, not `Note.handle`. These sit on the
/// same screen, so an author whose NIP-05 reads `dergigi@primal.net` in one and
/// `@dergigi` in the other is the app spelling one identity two ways within a
/// thread.
fn nestedHandle(ui: *AppUi, note: *const Note) AppUi.Node {
    const handle = note.handleLabel(ui.arena).text;
    if (handle.len == 0) return ui.spacer(0);
    return ui.paragraph(
        .{ .style = .{ .foreground = identityInk() } },
        &.{.{ .text = handle, .scale = nested_meta_scale }},
    );
}

/// The line that holds the strangers: how many replies came from outside the
/// follow graph, and a press that shows them. They are never deleted, only held,
/// which is what the line says.
fn outsideGraphRow(ui: *AppUi, count: usize, open: bool) AppUi.Node {
    const p = theme.palette;
    // The row's own padding sits INSIDE it, so the wash covers the band the shot
    // pads rather than a stripe through the middle of it. The height is stated
    // because a `list_item` carries a 28px intrinsic row floor, and this line is
    // a single 18px text line: without it the quiet line grows ten pixels looser
    // than the shot.
    return pressRow(
        ui,
        .{
            .width = thread_column_width,
            .height = outside_row_extent,
            .padding = 0.01,
            .cross = .center,
            .on_press = .toggle_outside_replies,
            .style = .{ .radius = 0 },
            // The row is a disclosure, so it says which way it is pointing: the
            // glyph, the verb in the label, and the accessible expanded state.
            .expanded = open,
            .semantics = .{ .role = .button, .label = if (open) "Hide replies from outside your graph" else "Show replies from outside your graph", .focusable = true },
        },
        .{
            hgap(ui, 52),
            // The glyph is chosen at runtime, so `appIcon` (which resolves the
            // built-in names too) rather than the comptime-checked `icon`.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_dim } }, if (open) "chevron-up" else "eye"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = pluralize(ui, count, "{d} reply from outside your graph", "{d} replies from outside your graph"), .scale = meta_scale }},
            ),
            hgap(ui, 7),
            // What the line is doing right now: holding them, or having shown
            // them. Saying "held below" under replies that are on screen would
            // be the same kind of stale label the round keeps finding.
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = if (open) "shown, below your graph" else "held below, never deleted", .monospace = true, .scale = mono_meta_scale }},
            ),
        },
    );
}

/// The line under a page of replies: how many conversations are still folded, and
/// a press that reveals the next page.
fn showMoreReplies(ui: *AppUi, hidden: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 12),
        // Height stated for the same reason as the held line: a `list_item` (the
        // kind that washes) carries a 28px intrinsic floor.
        pressRow(ui, .{
            .width = thread_column_width,
            .height = show_more_extent - 12 - 10,
            .padding = 0.01,
            .cross = .center,
            .on_press = .show_more_replies,
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "Show more replies", .focusable = true },
        }, .{
            hgap(ui, 52),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = pluralize(ui, hidden, "Show {d} more reply", "Show {d} more replies"), .weight = .medium, .scale = stat_scale }},
            ),
        }),
        vgap(ui, 10),
    });
}

/// What a branch continues into: how many replies hang below the level shown, and
/// a press that opens that reply as its own thread, where they all fit.
fn branchMore(ui: *AppUi, child: *const Note, deeper: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 6),
        pressRow(ui, .{
            .grow = 1,
            .height = branch_more_extent - 6,
            .padding = 0.01,
            .cross = .center,
            .on_press = Msg{ .open_thread = child.id },
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "More in this branch", .focusable = true },
        }, .{
            // Indented to the nested rail, so the line reads as part of the branch
            // it belongs to.
            hgap(ui, nested_avatar_size + 10),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "arrow-right"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = ui.fmt("More in this branch · {d}", .{deeper}), .weight = .medium, .scale = stat_scale }},
            ),
        }),
    });
}

/// The pinned reply composer at the bottom of a thread: type a reply and send it
/// to the root note. Pre-filled with whom you are answering.
fn replyComposer(ui: *AppUi, model: *const Model, root: *const Note) AppUi.Node {
    const p = theme.palette;
    const ready = !model.reply_empty();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        // Top-aligned, because the field is taller than one line now: the avatar
        // belongs beside the first line of what you are writing, not floating in
        // the middle of a half-empty box.
        ui.row(.{ .cross = .start, .gap = 0 }, .{
            hgap(ui, thread_inset),
            meAvatar(ui, avatar_size),
            hgap(ui, avatar_to_text_gap),
            // A `textarea`, not a `text_field`: Enter inserts a newline here and
            // the primary chord submits, which is the whole point. A reply is
            // often the paragraph the note deserved, and a single line asked
            // people to write it somewhere else and paste it back.
            //
            // The pill had to go with it. A capsule only reads as one on a
            // single line; at three it becomes a lozenge with the text pushed
            // off its own corners, so the shape follows the content and matches
            // the cards everywhere else.
            ui.el(.textarea, .{
                .grow = 1,
                .height = reply_editor_height,
                .padding = 14,
                .text = model.reply_draft(),
                // By handle, as the shot addresses them: a reply is to an account,
                // and the name above already said who that is.
                .placeholder = ui.fmt("Reply to {s}…", .{replyTarget(ui, root)}),
                .on_input = AppUi.inputMsg(.reply_edit),
                .on_submit = .reply_submit,
                .style = .{ .background = p.surface_input, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 },
            }, .{}),
            hgap(ui, 10),
            // The verb sits beside the field, quiet until there is something to
            // send: an empty reply has nothing to confirm.
            pressRow(ui, .{
                .cross = .center,
                .gap = 0,
                // Pressable while it counts even though the field is now empty of
                // intent: taking it back is the whole point, so `ready` must not
                // gate the press once something is held.
                .on_press = if (ready or compose.g_reply_due_s != 0) Msg.reply_submit else null,
                .style = .{ .quiet_hover = true },
                // A button that is currently unavailable, said in the words the
                // platform has for it. `disabled` empties the widget's advertised
                // actions at the source (`semanticActions` returns nothing for a
                // disabled widget), so it announces the true thing to a screen
                // reader, "Reply, dimmed", rather than a button that is silent
                // about why pressing it does nothing.
                .disabled = !ready,
                .semantics = .{ .role = .button, .label = if (compose.g_reply_due_s != 0) "Undo" else "Reply", .focusable = ready or compose.g_reply_due_s != 0 },
            }, .{
                ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = if (ready or compose.g_reply_due_s != 0) roomVerbFill() else p.surface_rail_tile, .radius = 8, .stroke_width = 0 } }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 14),
                        vgap(ui, 30),
                        ui.paragraph(
                            .{ .style = .{ .foreground = if (ready or compose.g_reply_due_s != 0) roomVerbInk() else p.text_muted } },
                            &.{.{
                                .text = if (compose.g_reply_due_s != 0)
                                    std.fmt.allocPrint(ui.arena, "Undo · {d}", .{postSecondsLeft(compose.g_reply_due_s, nowSeconds())}) catch "Undo"
                                else
                                    "Reply",
                                .weight = .medium,
                                .scale = stat_scale,
                            }},
                        ),
                        hgap(ui, 14),
                    }),
                }),
            }),
            hgap(ui, thread_inset),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset + avatar_size + avatar_to_text_gap),
            replyNotifyRow(ui, model, root),
        }),
        vgap(ui, 10),
    });
}

/// Wraps a thread level's panel in a full-bleed opaque panel that occludes
/// whatever is beneath it (a bare column does not reliably paint its background;
/// the `.card` element does). Keyed by the level's root id so the whole level
/// keeps its identity, and its scroll offset, as levels push and pop above it.
fn threadOccluder(ui: *AppUi, level_key: u64, panel: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // A bare `.card` injects the house 24px content padding whenever `padding`
    // is left at zero (zero IS the unset sentinel), which framed the whole
    // thread page in a margin the feed does not have. A hair above zero opts
    // out while staying invisibly small, so the thread sits flush like the feed.
    return ui.el(.card, .{ .grow = 1, .padding = 0.01, .global_key = .{ .int = level_key }, .style = .{ .background = p.surface_window, .border = p.surface_window, .radius = 0, .stroke_width = 0 } }, .{panel});
}

/// The band, drawn from the registered image. `cover` so a wide picture fills
/// the strip rather than letterboxing inside it.
fn bannerImage(ui: *AppUi) AppUi.Node {
    var node = ui.image(.{
        .image = g_banner_image_id,
        .height = profile_banner_height,
        .grow = 1,
        .semantics = .{ .label = "Profile banner" },
    });
    node.widget.image_fit = .cover;
    return node;
}

/// The banner currently registered, and for whom. One at a time, because one
/// screen shows one.
var g_banner_for: ?[32]u8 = null;
/// Who the in-flight fetch was started for, which is not always who is on
/// screen by the time it lands.
var g_banner_asked_for: ?[32]u8 = null;
pub var g_banner_state: enum { idle, fetching, loaded, failed } = .idle;
var g_banner_url_buf: [1024]u8 = undefined;
var g_banner_url_len: u16 = 0;
/// The host the banner actually lives on, kept for the same reason a picture
/// slot keeps one: while the proxy is in the way, the fetch URL's host is the
/// proxy's, and a refusal has to be written down under the real one.
var g_banner_host_buf: [96]u8 = undefined;
var g_banner_host_len: u8 = 0;
/// Ask the banner's own host rather than the proxy, for the same reason a face
/// does. Cleared whenever the banner is started for somebody else.
var g_banner_direct: bool = false;

fn bannerUrl() []const u8 {
    return g_banner_url_buf[0..g_banner_url_len];
}

/// Whether a banner is registered for `pubkey` right now.
fn bannerReady(pubkey: [32]u8) bool {
    const who = g_banner_for orelse return false;
    return g_banner_state == .loaded and std.mem.eql(u8, &who, &pubkey);
}

/// Asks for the open profile's banner, once per person.
fn scanBannerFetch(fx: *Effects, model: *const Model) void {
    const pubkey = model.viewing_profile orelse {
        // Left the screen: the next person starts clean, and the slot goes back
        // to the pool rather than sitting on a picture nobody can see. The feed
        // underneath is exactly what wants it.
        if (g_banner_image_id != 0) {
            _ = fx.unregisterImage(g_banner_image_id);
            g_banner_image_id = 0;
        }
        g_banner_for = null;
        g_banner_state = .idle;
        return;
    };
    // On screen this pass, so the allocator will not take it out from under the
    // reader while they are looking at it.
    g_banner_seen = profile_cache.g_image_clock;
    if (!prefs.g_media_previews) return;
    const changed = if (g_banner_for) |who| !std.mem.eql(u8, &who, &pubkey) else true;
    if (changed) {
        g_banner_for = pubkey;
        g_banner_state = .idle;
        g_banner_url_len = 0;
        // A different person's banner is a different host, so it goes through
        // the proxy first like any other.
        g_banner_direct = false;
    }
    if (g_banner_state != .idle) return;

    const raw = personBanner(pubkey);
    if (raw.len == 0) return;
    var url_buf: [1024]u8 = undefined;
    const url = if (g_banner_direct or proxyRefusesHost(raw)) raw else mediaUrl(&url_buf, raw, banner_target_px, .inside);
    const bhost = hostOf(raw);
    const bn = @min(bhost.len, g_banner_host_buf.len);
    @memcpy(g_banner_host_buf[0..bn], bhost[0..bn]);
    g_banner_host_len = @intCast(bn);
    const n = @min(url.len, g_banner_url_buf.len);
    @memcpy(g_banner_url_buf[0..n], url[0..n]);
    g_banner_url_len = @intCast(n);

    // A slot from the shared pool, the same one faces and pictures come from.
    // The banner marks itself on screen every pass a profile is open, so the
    // allocator will not take it back underneath the reader.
    if (g_banner_image_id == 0) {
        g_banner_image_id = acquireImageId(fx) orelse return;
    }
    if (loadCachedImage(fx, g_banner_image_id, bannerUrl(), banner_target_px)) |_| {
        g_banner_state = .loaded;
        return;
    }
    g_banner_state = .fetching;
    g_banner_asked_for = pubkey;
    g_banner_down.release();
    fetchSlice(fx, banner_fetch_key, bannerUrl(), 0, Effects.responseMsg(.banner_fetched));
}

/// A banner too big for one response body. The widest of the three, drawn at
/// 660x132, so the least likely of them to arrive in one piece.
var g_banner_down: Download = .{};

/// Deliberately not 4000: that is `link_fetch_key_base + 0`, and the runtime
/// rejects a second fetch under a key already in flight, so a banner and the
/// first link preview would refuse each other.
const banner_fetch_key: u64 = 5000;

fn handleBannerFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key != banner_fetch_key) return;
    // WHOSE banner this is. A fetch takes as long as it takes, and the reader
    // may have walked to somebody else meanwhile: without this the bytes paint
    // over the person now on screen AND are cached under their URL, so the wrong
    // face persists across restarts.
    const asked_for = g_banner_asked_for orelse return;
    const showing = g_banner_for orelse return;
    if (!std.mem.eql(u8, &asked_for, &showing)) {
        g_banner_down.release();
        g_banner_state = .idle;
        return;
    }
    // Every effect slot was busy: ask again next tick.
    if (response.outcome == .rejected) {
        g_banner_down.release();
        g_banner_state = .idle;
        return;
    }
    // A slice of a banner bigger than one body.
    if (response.outcome == .ok and response.status == 206 and !response.truncated and response.body.len > 0) {
        const outcome = g_banner_down.append(response.body) orelse {
            g_banner_down.release();
            g_banner_state = .failed;
            return;
        };
        if (outcome == .want_more) {
            fetchSlice(fx, banner_fetch_key, bannerUrl(), g_banner_down.len, Effects.responseMsg(.banner_fetched));
            return;
        }
        const whole = g_banner_down.bytes() orelse response.body;
        finishBanner(fx, whole);
        g_banner_down.release();
        return;
    }
    // Anything but a clean, whole, OK image body leaves the flat band, which is
    // a perfectly good banner.
    if (response.outcome != .ok or response.status != 200 or response.truncated or
        response.body.len == 0 or response.body.len > max_image_bytes)
    {
        g_banner_down.release();
        // The proxy refusing the HOST, not the picture. Once, and only while
        // the proxy is what was used.
        if (prefs.g_media_direct_fallback and prefs.g_media_proxy_on and !g_banner_direct and
            proxyRefusedHost(response.outcome, response.status))
        {
            rememberHostRefusal(g_banner_host_buf[0..g_banner_host_len]);
            g_banner_direct = true;
            g_banner_state = .idle;
            return;
        }
        g_banner_state = .failed;
        return;
    }
    g_banner_down.release();
    finishBanner(fx, response.body);
}

/// Decodes a complete banner into the slot it holds.
fn finishBanner(fx: *Effects, bytes: []const u8) void {
    if (decodeAndRegister(fx, g_banner_image_id, bytes, banner_target_px)) |_| {
        g_banner_state = .loaded;
        storeCachedImage(bannerUrl(), bytes);
    } else {
        g_banner_state = .failed;
    }
}

// ----------------------------------------------------------------- a person
//
// Everything the profile screen needs about somebody, read from the RAW kind:0
// rather than the name-and-face cache. The cache models four fields and drops
// the rest, which is right for a feed row and useless here: a profile is mostly
// the fields it does not keep.
//
// Cached per pubkey for the life of a level, because a virtual list rebuilds its
// visible rows every frame and a JSON parse per frame is not free.

/// The abbreviated npub exactly as the view renders it, so a test can count how
/// many times a screen says it without hard-coding the truncation. For tests.
pub fn npubShortForTest(arena: std.mem.Allocator, pubkey: [32]u8) []const u8 {
    return npubShortOf(arena, pubkey);
}

/// Puts a NIP-05 on a cached profile in a stated verification state, so a view
/// test can ask what the page shows without a well-known round trip.
pub fn setProfileNip05ForTest(pubkey: [32]u8, id: []const u8, verified: bool) void {
    const p = upsertProfile(pubkey) orelse return;
    const n = @min(id.len, p.nip05_buf.len);
    @memcpy(p.nip05_buf[0..n], id[0..n]);
    p.nip05_len = @intCast(n);
    p.nip05_state = if (verified) .verified else .failed;
}

/// Fills a cached profile's text fields to whatever length is asked for, so a
/// sweep can render the WORST case rather than a realistic one.
///
/// Every one of these is a stranger's string arriving over a relay, and the
/// only thing bounding it is the buffer it is copied into. A row that fits a
/// name is not the question; a row that fits a name of sixty-four characters
/// is, because that is what the buffer allows and therefore what will
/// eventually arrive.
pub fn fillProfileTextForTest(pubkey: [32]u8, name: []const u8, username: []const u8, website: []const u8) void {
    const p = upsertProfile(pubkey) orelse return;
    const n = @min(name.len, p.name_buf.len);
    @memcpy(p.name_buf[0..n], name[0..n]);
    p.name_len = @intCast(n);
    const u = @min(username.len, p.username_buf.len);
    @memcpy(p.username_buf[0..u], username[0..u]);
    p.username_len = @intCast(u);
    const w = @min(website.len, p.website_buf.len);
    @memcpy(p.website_buf[0..w], website[0..w]);
    p.website_len = @intCast(w);
}

pub fn verifiedNip05ForTest(pubkey: [32]u8) []const u8 {
    return verifiedNip05(pubkey);
}

/// The 44px band above a person: Back, and who this is.
fn profileHeaderBand(ui: *AppUi, model: *const Model, pubkey: [32]u8) AppUi.Node {
    return levelBand(ui, model, elide(ui, personName(ui, pubkey), profile_band_name_max));
}

/// The strip across the top of a stacked list level: Back, naming where it
/// lands, and what this level is. Every level that sits over the feed owes the
/// reader a way off it, and a topic and the bookmark list went without one
/// because only a person's page had this band.
fn levelBand(ui: *AppUi, model: *const Model, title: []const u8) AppUi.Node {
    const p = theme.palette;
    const back_label = backLabel(model, ui.arena);
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            backControl(ui, back_label, Msg.close_thread),
            ui.spacer(1),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = title, .weight = .medium, .scale = menu_scale }},
            ),
            ui.spacer(1),
            hgap(ui, 48),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

/// How tall the person card is. Measured, not guessed: a bio wraps and a links
/// row may be absent, and a virtual list that mis-measures its first row scrolls
/// to the wrong place for every row after it.
fn profileCardExtent(rows: *const ProfileRows) f32 {
    var h: f32 = profile_banner_height + profile_card_chrome;
    const about = personAbout(rows.subject());
    if (about.len > 0) {
        // Roughly 62 characters to a line at the body scale, over the 660 column.
        const lines: f32 = @floatFromInt(1 + about.len / 62);
        h += lines * profile_bio_line_height + 9;
    }
    if (personWebsite(rows.subject()).len > 0 or personLud16(rows.subject()).len > 0) h += profile_links_height;
    return h;
}

/// Whether this page belongs to the reader looking at it.
///
/// The profile was written for a stranger, because for a long time a stranger was
/// the only person it could be about: the way onto it was pressing somebody's face
/// in the feed. Now the rail's seat opens the reader's own, so every sentence that
/// says "they" has to say "you" here, and the first reader through that door is a
/// brand new account whose page is entirely empty states.
fn isMe(pubkey: [32]u8) bool {
    const me = activePubkey() orelse return false;
    return std.mem.eql(u8, &me, &pubkey);
}

/// The person: their banner, their face, what they say about themselves, and
/// what this app can honestly tell the reader about them.
fn profileCard(ui: *AppUi, model: *const Model, pubkey: [32]u8) AppUi.Node {
    const p = theme.palette;
    const about = personAbout(pubkey);
    const website = personWebsite(pubkey);
    const lud16 = personLud16(pubkey);
    const is_me = isMe(pubkey);
    const named = personIsNamed(pubkey);
    const follows_me = followsMe(pubkey);
    // Nothing to show and no room to leave for it: with neither the npub nor the
    // follows-you note, the row measures zero and its 5px lead-in would sit under
    // the name as dead space. That is the freshly minted key's own page.
    // Their NIP-05, once it has actually been checked. It goes ahead of the npub
    // because it is the identifier a person chose and can prove, where the npub
    // is the one the maths chose.
    const handle = verifiedNip05(pubkey);

    return ui.column(.{ .gap = 0 }, .{
        // The banner, with the face riding up over its lower edge. There is no
        // negative margin on this engine, so the two are STACKED: one child is
        // the banner plus the disc's overhang, the other is that same height
        // made of a gap and then the disc. Equal heights, so the stack is
        // exactly as tall as the band plus what hangs below it, and the name
        // row after it starts clear of both.
        ui.stack(.{}, .{
            ui.column(.{ .gap = 0 }, .{
                // A flat band until an image is afforded: an empty box that
                // holds its height beats a jump when one arrives.
                if (bannerReady(pubkey))
                    bannerImage(ui)
                else
                    ui.el(.panel, .{
                        .height = profile_banner_height,
                        .padding = 0.01,
                        .style = .{ .background = p.surface_stripe_a, .border = p.surface_stripe_a, .radius = 0, .stroke_width = 0 },
                    }, .{}),
                vgap(ui, profile_avatar_size - profile_avatar_lift),
            }),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, profile_banner_height - profile_avatar_lift),
                // Bottom-aligned, not top. The disc is the tallest thing here
                // and it deliberately overhangs the banner, so aligning the
                // cluster to the TOP of this row put it ON the band, over the
                // subject's own picture. Against the bottom it lands in the
                // overhang, clear of the banner and level with the face.
                ui.row(.{ .cross = .end, .gap = 0 }, .{
                    hgap(ui, 20),
                    personAvatar(ui, pubkey, profile_avatar_size),
                    ui.spacer(1),
                    profileActions(ui, model, pubkey, is_me),
                    hgap(ui, 20),
                }),
            }),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 20),
            ui.column(.{ .gap = 0, .grow = 1 }, .{
                vgap(ui, 8),
                ui.row(.{ .cross = .center, .gap = 7 }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_primary } },
                        &.{.{ .text = elide(ui, personName(ui, pubkey), profile_name_max), .weight = .bold, .scale = profile_name_scale }},
                    ),
                    personCheck(ui, pubkey),
                }),
                // The npub is skipped when the name line IS that string. A key
                // with no kind:0 has no name, so `personName` hands back the
                // short npub, and printing it again directly underneath says
                // nothing twice. The reader most likely to see it is the one
                // whose key was minted a minute ago and has not named it yet,
                // which is the same reader the rail's seat now opens this page
                // for.
                //
                // `.gap = 0` with the 8 spelled out, NOT a gap of 8 with a
                // zero-width spacer standing in for the npub. A row gap is
                // charged for every flow child whatever its extent, so the
                // spacer would still push "follows you" 8px past the left rule
                // that the name, bio, links and counts all share. `handleLine`
                // documents this exact trap and I walked into it anyway.
                // One fact per line, in the order they are worth: the name,
                // the address that was verified, the key itself, then where to
                // pay them. They used to share a row, which read as one long
                // strip of identifiers and put the npub, the thing most likely
                // to be copied, in the middle of it.
                if (handle.len > 0) vgap(ui, 5) else ui.spacer(0),
                if (handle.len > 0)
                    ui.paragraph(
                        .{ .style = .{ .foreground = identityInk() } },
                        &.{.{ .text = elide(ui, handle, profile_handle_max), .scale = meta_scale }},
                    )
                else
                    ui.spacer(0),
                if (named) vgap(ui, 4) else ui.spacer(0),
                if (named)
                    ui.row(.{ .cross = .center, .gap = 8 }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = personNpubShort(ui, pubkey), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        // Kept beside the key rather than given a line of its
                        // own: it is a fact about the two of you, not another
                        // way to address them.
                        if (follows_me)
                            ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "follows you", .scale = meta_scale }})
                        else
                            ui.spacer(0),
                    })
                else
                    ui.spacer(0),
                // A key with no name of its own shows no npub either, because
                // the name line already IS that string. The badge still has to
                // appear: hanging it off the npub's branch made it vanish for
                // exactly the readers whose page has least on it, and a test
                // written for the old layout caught that.
                if (follows_me and !named) vgap(ui, 4) else ui.spacer(0),
                if (follows_me and !named)
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "follows you", .scale = meta_scale }})
                else
                    ui.spacer(0),
                if (lud16.len > 0) vgap(ui, 4) else ui.spacer(0),
                if (lud16.len > 0)
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_muted_alt } },
                        &.{.{ .text = elide(ui, lud16, profile_handle_max), .monospace = true, .scale = mono_hint_scale }},
                    )
                else
                    ui.spacer(0),
                if (about.len > 0) vgap(ui, 9) else ui.spacer(0),
                if (about.len > 0)
                    ui.paragraph(
                        .{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_body_soft } },
                        &.{.{ .text = about }},
                    )
                else
                    ui.spacer(0),
                if (website.len > 0) profileLinks(ui, website) else ui.spacer(0),
                vgap(ui, 9),
                profileCounts(ui, pubkey, is_me),
                if (!is_me) ownListsHint(ui) else ui.spacer(0),
                vgap(ui, 14),
                profileTabs(ui, model),
            }),
            hgap(ui, 20),
        }),
    });
}

/// The line under a profile's counts when Follow or Mute is off because the
/// reader's own list has not been read. It says which list, how far the read got
/// and, once the wait ran out, offers to ask again: a greyed button with a
/// sentence that never changes is a dead end.
fn ownListsHint(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const follow_off = followBlockedReason() != null;
    const mute_off = muteBlockedReason() != null;
    if (!follow_off and !mute_off) return ui.spacer(0);
    const state = ownListsRead();
    const both = follow_off and mute_off;
    const lists = if (both) "follow and mute lists" else if (follow_off) "follow list" else "mute list";
    const what = if (both) "Following and muting are" else if (follow_off) "Following is" else "Muting is";
    const text = switch (state) {
        .reading => ui.fmt("Still reading your own {s}. {s} off until {s}, because writing before then would replace {s}.", .{
            lists, what, if (both) "they arrive" else "it arrives", if (both) "them" else "it",
        }),
        .incomplete => ui.fmt("{s} Plaza could not finish reading your {s}. {s} off rather than replace a list it has not seen.{s}", .{
            ownListsProgress(ui), lists, what, ownListsAdvice(),
        }),
        // Both controls are live here (the press asks first), so there is
        // nothing off to explain.
        .none_found => return ui.spacer(0),
    };
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = text, .scale = mono_hint_scale }},
        ),
        if (state == .incomplete)
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 6),
                ui.row(.{ .gap = 0 }, .{ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.retry_own_lists }, "Try again")}),
            })
        else
            ui.spacer(0),
    });
}

/// The action cluster: zap (inert), the overflow menu, and Follow.
fn profileActions(ui: *AppUi, model: *const Model, pubkey: [32]u8, is_me: bool) AppUi.Node {
    _ = model;
    if (is_me) {
        const p = theme.palette;
        // Your own page. Editing lives in Settings, and a second door to it here
        // would be a second thing to keep true.
        return ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "This is you", .scale = meta_scale }});
    }
    const following = isFollowedByMe(pubkey);
    const muted = isMuted(pubkey);
    return ui.row(.{ .cross = .center, .gap = 8 }, .{
        // Muting is quieter than following, in the layout as well as in what it
        // does: a ghost button beside the primary one, and it says the state it
        // is in rather than the verb it performs when that state is unusual.
        if (muteBlockedReason() != null)
            ui.button(.{ .size = .sm, .variant = .ghost, .disabled = true, .on_press = Msg{ .mute_person = 1 } }, "Mute")
        else if (muted)
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .mute_person = 2 } }, "Muted")
        else
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .mute_person = 1 } }, "Mute"),
        // Disabled rather than absent while the app is still reading the
        // reader's own list: a control that vanishes is a control they will
        // wonder about, and one that silently no-ops is worse. The sentence
        // explaining it sits under the counts, where there is room for it.
        if (followBlockedReason() != null)
            ui.button(.{ .size = .sm, .variant = .primary, .disabled = true, .on_press = Msg{ .follow_person = 1 } }, "Follow")
        else if (following)
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .follow_person = 2 } }, "Following")
        else
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = Msg{ .follow_person = 1 } }, "Follow"),
    });
}

/// Where they point people, when they point anywhere.
/// The website line. The lightning address used to share this row and now sits
/// with the other ways to address someone, directly under the key.
///
/// Shortened rather than bounded: a stranger's `website` is printed whole, up to
/// the 128 bytes of the buffer that holds it, and the profile page is the one
/// screen that never picks up the fixed reading column, so nothing above this
/// leaf would have stopped it at the window's edge.
fn profileLinks(ui: *AppUi, website: []const u8) AppUi.Node {
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .cross = .center, .gap = 14 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = identityInk() } },
                &.{.{ .text = elide(ui, website, profile_handle_max), .scale = meta_scale }},
            ),
            ui.spacer(1),
        }),
    });
}

/// What this app can honestly count.
///
/// Following is theirs to state: it is the length of their own contact list.
/// FOLLOWERS is not. Nothing in a local store can know who follows somebody,
/// and the honest options are an indexer's number or none. This app does not
/// state numbers it cannot verify, so it says nothing rather than a figure the
/// reader would reasonably believe.
fn profileCounts(ui: *AppUi, pubkey: [32]u8, is_me: bool) AppUi.Node {
    const p = theme.palette;
    const following = personFollowingCount(pubkey);
    return ui.row(.{ .cross = .center, .gap = 16 }, .{
        if (following) |n|
            ui.row(.{ .cross = .center, .gap = 5 }, .{
                ui.paragraph(.{ .style = .{ .foreground = p.text_body_strong } }, &.{.{ .text = ui.fmt("{d}", .{n}), .weight = .medium, .scale = menu_scale }}),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "following", .scale = menu_scale }}),
            })
        else
            ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{
                .text = if (is_me) "Your follow list has not arrived yet" else "Their follow list has not arrived yet",
                .scale = mono_hint_scale,
            }}),
        ui.spacer(1),
    });
}

/// Notes, or replies. Two tabs that mean exactly what they say.
fn profileTabs(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.row(.{ .cross = .center, .gap = 6 }, .{
        profileTab(ui, "Notes", model.profile_tab == .notes, Msg{ .profile_tab = 0 }),
        profileTab(ui, "Replies", model.profile_tab == .replies, Msg{ .profile_tab = 1 }),
        ui.spacer(1),
    });
}

fn profileTab(ui: *AppUi, label: []const u8, active: bool, msg: Msg) AppUi.Node {
    return profileTabFocused(ui, label, active, msg, false);
}

/// The same tab, optionally taking the keyboard when it mounts. The
/// notifications sheet has no way-out control of its own, so its first tab is
/// what gives Escape a focused widget to resolve from; switching tabs is the
/// worst an accidental Return can do from there.
fn profileTabFocused(ui: *AppUi, label: []const u8, active: bool, msg: Msg, focus: bool) AppUi.Node {
    const p = theme.palette;
    return ui.el(.list_item, .{
        .padding = 0.01,
        .height = 26,
        .cross = .center,
        .autofocus = focus,
        .on_press = msg,
        .style = .{
            .background = if (active) p.surface_settings_card else p.surface_window,
            .border = if (active) p.border_chip else p.surface_window,
            .radius = 8,
            .stroke_width = 1,
        },
        .semantics = .{ .role = .tab, .label = label, .focusable = true },
    }, .{
        hgap(ui, 11),
        ui.paragraph(
            .{ .style = .{ .foreground = if (active) p.text_primary else p.text_muted_alt } },
            // One weight for both. The active tab already has its own fill,
            // border and text colour, and changing the weight as well moved the
            // glyph metrics, so the two labels sat on different baselines inside
            // boxes that were centred correctly. The tabs looked misaligned and
            // the row was never the problem.
            &.{.{ .text = label, .scale = menu_scale }},
        ),
        hgap(ui, 11),
    });
}

/// The quiet line under an empty tab.
fn profileEmptyRow(ui: *AppUi, rows: *const ProfileRows) AppUi.Node {
    const p = theme.palette;
    // A key minted a minute ago has written nothing, so this is the ONE screen a
    // new reader is most likely to see first, and "Nothing they have written" is
    // the app talking about them behind their back on their own page.
    const mine = isMe(rows.subject());
    // A tag and the bookmark list are about no person, so the sentences below
    // about what somebody "has written" are not theirs to say.
    const text: []const u8 = if (rows.header == .topic)
        if (rows.loading) "Looking for notes with this tag…" else "No notes with this tag yet."
    else if (rows.header == .bookmarks)
        // Saved but never fetched is not the same as nothing saved, and the
        // card above already says those are not listed.
        if (bookmarkCount() == 0) "Nothing saved here yet." else "None of your saved notes are on this machine yet."
    else if (rows.loading)
        if (mine) "Looking for what you have written…" else "Looking for what they have written…"
    else if (rows.model.profile_tab == .replies)
        if (mine) "Nothing you have written at anyone is here yet." else "Nothing they have written at anyone is here yet."
    else if (mine) "Nothing you have written is here yet." else "Nothing they have written is here yet.";
    return ui.row(.{ .cross = .center, .gap = 0, .height = quiet_row_extent }, .{
        hgap(ui, 20),
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
        hgap(ui, 20),
    });
}

/// A profile level's key, in the same space as a thread's so the two never
/// collide when they sit in one stack. The top bit marks it a person.
fn profileLevelKey(level: usize, pubkey: [32]u8) u64 {
    const hi = @as(u64, level) << 59;
    const lo = std.mem.readInt(u64, pubkey[0..8], .big) & ((@as(u64, 1) << 58) - 1);
    return hi | lo | (@as(u64, 1) << 58);
}

/// What a profile level draws: the person, then what they have written.
///
/// One virtual list, with the whole profile header as row 0. The header is tall
/// and variable (a bio wraps, a links row may be absent) and it scrolls away
/// with the notes, which is what the design asks for and what a column above a
/// list cannot do. This is the same heterogeneous-row shape the thread already
/// uses for its ancestors.
/// What a stacked list level is showing. One value rather than a pubkey plus an
/// optional topic plus a flag, because those three encode a choice of one and
/// nothing stops two of them being set at once.
const LevelHeader = union(enum) {
    person: [32]u8,
    topic: []const u8,
    bookmarks,
};

fn profilePanel(
    ui: *AppUi,
    model: *const Model,
    header: LevelHeader,
    notes: []const Note,
    loading: bool,
    level_key: u64,
    level: usize,
    occluded: bool,
) AppUi.Node {
    const rows_ctx = ui.arena.create(ProfileRows) catch return ui.column(.{}, .{});
    // From the ARENA, never the stack. The SDK RETAINS `extent_context` and calls
    // the estimator again in a post-layout measure pass, long after this function
    // has returned: a slice of a local here is read back out of a reclaimed frame,
    // and the index it yields then indexes `notes` with whatever layout left on
    // that word. The arena survives to the top of the next build, which is
    // exactly as long as the retained table needs it.
    const indices = ui.arena.alloc(usize, notes.len) catch return ui.column(.{}, .{});
    // An occluded level still reports its REAL row count: the retained list keeps
    // its scroll offset from the count and the extents, so claiming two rows here
    // would collapse the person's scroll and Back would land at the top.
    // A topic's rows were already chosen by the store query, so every note
    // handed in belongs. A person's are filtered here because `thread_notes` is
    // one buffer shared with the thread screen.
    const shown = switch (header) {
        .person => |pk| model.profileNotesFor(indices, pk),
        // A topic's rows and a bookmark's were already chosen, by the store
        // query and by the list itself, so every note handed in belongs. A
        // person's are filtered here because `thread_notes` is one buffer
        // shared with the thread screen.
        else => blk: {
            var n: usize = 0;
            while (n < notes.len and n < indices.len) : (n += 1) indices[n] = n;
            break :blk indices[0..n];
        },
    };
    rows_ctx.* = .{
        .model = model,
        .header = header,
        .notes = notes,
        .shown = shown,
        .loading = loading,
        .footer = switch (header) {
            .person => |pk| profileFooter(model, pk, shown.len),
            else => .none,
        },
    };
    const table = &g_profile_extents[@min(level, g_profile_extents.len - 1)];
    table.reset();
    if (!occluded) {
        var row: usize = 0;
        const total = rows_ctx.count();
        while (row < total) : (row += 1) table.push(profileRowHeight(rows_ctx, row));
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("person-{d}", .{level_key}),
        // Nothing to cover when nothing is drawn, for the same reason the thread
        // list above says so: a list that declares items and builds none is
        // permanently "undercovered", and the runtime answers that by rebuilding
        // and re-laying out the whole view a second time, every time.
        .item_count = if (occluded) 0 else rows_ctx.count(),
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Profile" },
        // Only a person's page pages. A topic and the bookmark list hold what
        // the store was asked for and have nothing older to reach.
        .on_reach_end = switch (header) {
            .person => .profile_older,
            else => null,
        },
    };
    const window = ui.virtualWindow(options);
    if (!occluded) recordProfileVisible(rows_ctx, level, window.first_visible_index, window.last_visible_index);
    if (!occluded and header == .person) {
        profile_notes.g_profile_bottom_in_view = window.start_index + window.itemCount() >= rows_ctx.count();
    }
    // An occluded level builds no rows, for the same reason a thread's does not:
    // the offset survives on the list's id and its content height, and six built
    // levels of anything cross the 1024-node ceiling that refuses a view whole.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = profileRowAt(ui, rows_ctx, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        // Back is the same for every kind of level; what the band names is
        // not. The header row under it still says what the list is.
        if (occluded) ui.spacer(0) else switch (header) {
            .person => |pk| profileHeaderBand(ui, model, pk),
            .topic => |t| levelBand(ui, model, elide(ui, ui.fmt("#{s}", .{t}), profile_band_name_max)),
            .bookmarks => levelBand(ui, model, "Bookmarks"),
        },
        ui.virtualList(options, window, .{rows}),
    });
}

/// The rows a profile level holds: the person, then their notes.
/// The rows of a stacked LIST level: a person's page, or a topic's.
///
/// One struct rather than two because the two differ in exactly one row, the
/// header, and in which notes they show. A parallel panel would mean a second
/// retained extent table, a second virtual list id scheme and a second copy of
/// the occlusion rules, all to draw the same list of notes under a different
/// first row.
const ProfileRows = struct {
    model: *const Model,
    header: LevelHeader,
    notes: []const Note,
    shown: []const usize,
    loading: bool,
    /// What closes the list. Only a person's page has one.
    footer: ProfileFooter = .none,

    const Row = union(enum) { person, topic, bookmarks, note: usize, empty, footer };

    /// The person this level is about, or all-zero when it is not about one.
    /// The callers below are all person-only paths reached from a `.person`
    /// row; the zero keeps them total rather than making each one a switch.
    fn subject(self: *const ProfileRows) [32]u8 {
        return switch (self.header) {
            .person => |pk| pk,
            else => @splat(0),
        };
    }

    fn count(self: *const ProfileRows) usize {
        // The person, then a row per note, or one quiet line when there are none.
        const body: usize = if (self.shown.len == 0) 1 else self.shown.len;
        return 1 + body + @intFromBool(self.footer != .none);
    }

    fn rowAt(self: *const ProfileRows, index: usize) Row {
        if (index == 0) return switch (self.header) {
            .person => .person,
            .topic => .topic,
            .bookmarks => .bookmarks,
        };
        if (self.shown.len == 0) return .empty;
        const i = index - 1;
        if (i == self.shown.len and self.footer != .none) return .footer;
        if (i >= self.shown.len) return .empty;
        return .{ .note = self.shown[i] };
    }
};

/// How a person's list ends.
const ProfileFooter = enum {
    /// More may be on the way, or the reader has not asked yet.
    none,
    /// A page of older notes is being fetched.
    loading,
    /// Every relay asked said there is nothing older.
    end,
    /// The page holds as many notes as it will, and there may be more.
    ceiling,
};

/// What closes the open person's list right now. Read at build time from the
/// round in flight and the latch, both of which the tick moves.
fn profileFooter(model: *const Model, pubkey: [32]u8, shown: usize) ProfileFooter {
    // An empty tab has its own line, and a list that says "that is all" before
    // it shows anything is saying something else.
    if (shown == 0) return .none;
    if (model.thread_notes_len >= profile_notes_max) return .ceiling;
    if (profileEndReached(pubkey)) return .end;
    if (profile_notes.g_profile_older_busy.load(.monotonic)) return .loading;
    return .none;
}

pub fn profileFooterForTest(model: *const Model, pubkey: [32]u8, shown: usize) u8 {
    return @intFromEnum(profileFooter(model, pubkey, shown));
}

/// The line under the last note.
fn profileFooterRow(ui: *AppUi, footer: ProfileFooter) AppUi.Node {
    const p = theme.palette;
    const text: []const u8 = switch (footer) {
        .loading => "Looking for older notes…",
        .end => "That is everything the relays have from them.",
        .ceiling => ui.fmt("This page holds their latest {d} notes.", .{profile_notes_max}),
        .none => "",
    };
    // Under the notes, in their column, rather than at the window's left edge.
    return ui.row(.{ .grow = 1, .main = .center, .height = quiet_row_extent }, .{
        ui.row(.{ .width = feed_column_width, .cross = .center, .gap = 0 }, .{
            hgap(ui, row_pad_side),
            ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
            hgap(ui, row_pad_side),
        }),
    });
}

/// One person-page row's height, from the live rows. Typed for the same reason
/// `threadRowHeight` is.
fn profileRowHeight(rows: *const ProfileRows, index: usize) f32 {
    return switch (rows.rowAt(index)) {
        .person => profileCardExtent(rows),
        // The topic header is a title and two wrapped lines. Estimated rather
        // than measured, like every other row here: the retained table only
        // needs to be close enough that the scrollbar does not jump.
        .topic => 96,
        .bookmarks => 96,
        .note => |ni| noteRowEstimate(&rows.notes[ni], feed_row_chrome),
        .empty, .footer => quiet_row_extent,
    };
}

fn profileRowAt(ui: *AppUi, rows: *const ProfileRows, index: usize) AppUi.Node {
    return switch (rows.rowAt(index)) {
        .person => profileCard(ui, rows.model, rows.subject()),
        .topic => topicCard(ui, switch (rows.header) {
            .topic => |t| t,
            else => "",
        }),
        .bookmarks => bookmarksCard(ui),
        .note => |ni| noteCard(ui, &rows.notes[ni]),
        .empty => profileEmptyRow(ui, rows),
        .footer => profileFooterRow(ui, rows.footer),
    };
}

/// The header of a topic level: the tag, and what this list actually is.
///
/// Said plainly because it is not the same promise a feed makes. This is what
/// this reader's own relays have served and this machine has kept, not
/// everything on Nostr carrying the tag, and a topic view that implied the
/// latter would be claiming a search Plaza does not do.
fn topicCard(ui: *AppUi, topic: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .padding = 16, .gap = 6, .cross = .stretch }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("#{s}", .{topic})),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
            &.{.{ .text = "Notes carrying this tag, from your relays. Read from this machine first, so what is already here is on screen before anything is asked for." }},
        ),
    });
}

/// The header of the bookmark list.
///
/// It says where they live, because that is the part a reader cannot see. A
/// bookmark here is a NIP-51 kind:10003 published to their relays, so it
/// follows them to any client, and one saved privately elsewhere shows up here
/// too. Both halves are read; new ones are saved to the public half.
fn bookmarksCard(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .padding = 16, .gap = 6, .cross = .stretch }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Bookmarks"),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
            &.{.{ .text = "Saved to your relays, so they follow you to any client. Private ones you saved elsewhere are shown here too. Notes this machine has not fetched are not listed." }},
        ),
    });
}

/// A stable, collision-free scroll identity for a thread level: the level index
/// in the high bits (distinct per position, so an ancestor keeps its key and
/// offset while deeper levels push and pop, and two levels never collide even if
/// the same note appears twice) and the root note id in the low bits (so when
/// the stack is saturated at `thread_depth_max` and `enterThread` replaces the
/// top root in place, the new level gets a fresh key and opens at the top rather
/// than inheriting the dropped thread's offset).
/// The same scheme `profileLevelKey` uses, over the topic's bytes: a level index
/// in the high bits so two levels never collide, and a hash of the topic in the
/// low bits so opening `#zig` twice at the same depth reuses its offset.
/// There is one bookmark list, so it needs no hash: a fixed key plus the level
/// index is enough to keep two stacked copies apart.
const bookmarks_level_key: u64 = 0x7000_0000_0000_0000;

fn topicLevelKey(level: usize, topic: []const u8) u64 {
    const hi = @as(u64, level) << 59;
    var hash: u64 = 1469598103934665603;
    for (topic) |c| {
        hash ^= c;
        hash *%= 1099511628211;
    }
    return hi | (hash & ((@as(u64, 1) << 59) - 1));
}

fn threadLevelKey(level: usize, root_id: i64) u64 {
    const hi = @as(u64, level) << 59;
    const lo = @as(u64, @intCast(root_id)) & ((@as(u64, 1) << 59) - 1);
    return hi | lo;
}

/// The feed screen, and everything layered on it.
///
/// `levels` is what the Settings sheet passes false: see `settingsSheet`. The
/// thread stack is the most expensive thing this app builds, and a view past
/// `max_canvas_widget_nodes_per_view` is refused WHOLE, so the deepest stack
/// under the largest sheet is the frame that decides whether the window can
/// draw at all. Settings used to REPLACE this tree, which unmounted every level
/// and lost its scroll offset anyway, so not building them behind the sheet
/// costs nothing that was not already gone and buys back most of the ceiling.
/// Every other sheet keeps its levels, because for those the offsets survive
/// today and dropping them would be a real loss.
fn feedView(ui: *AppUi, model: *const Model, levels: bool) AppUi.Node {
    const p = theme.palette;
    // The feed is always built (so it is always mounted): a thread is layered
    // OVER it, not swapped in, so the feed's scroll offset survives and closing
    // a thread returns the reader to where they were, not the top. EACH open
    // thread level is layered too (occluded ancestors under the current one), so
    // every level keeps its own scroll offset and Back never lands a parent
    // thread at the top.
    const feed = feedContent(ui, model);
    const content = if (levels and model.levelOpen()) blk: {
        // feed + one panel per level: the back-stacked levels (oldest first),
        // then the current one on top. A level is a thread or a person; both
        // spend one virtual window either way, which is why they share a stack.
        const kids = ui.arena.alloc(AppUi.Node, 2 + model.thread_stack_len) catch break :blk feed;
        kids[0] = feed;
        for (0..model.thread_stack_len) |d| {
            const screen = &model.thread_stack[d];
            if (screen.bookmarks) {
                const lk = bookmarks_level_key + d;
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .bookmarks, &.{}, false, lk, d, true));
                continue;
            }
            if (screen.topic()) |t| {
                const lk = topicLevelKey(d, t);
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .topic = t }, &.{}, false, lk, d, true));
                continue;
            }
            if (screen.profile) |pk| {
                const lk = profileLevelKey(d, pk);
                kids[1 + d] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .person = pk }, &.{}, false, lk, d, true));
                continue;
            }
            const root = &screen.note;
            const lk = threadLevelKey(d, root.id);
            kids[1 + d] = threadOccluder(ui, lk, if (isArticleRoot(root))
                articlePanel(ui, model, root, lk, d, true)
            else
                threadPanel(ui, model, root, threadRepliesFromStore(ui, d, root.event_id), false, lk, d, true));
        }
        if (model.viewing_bookmarks) {
            const lk = bookmarks_level_key + model.thread_stack_len;
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .bookmarks, model.thread_notes[0..model.thread_notes_len], false, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        if (model.viewingTopic()) |t| {
            const lk = topicLevelKey(model.thread_stack_len, t);
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .topic = t }, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        if (model.viewing_profile) |pk| {
            const lk = profileLevelKey(model.thread_stack_len, pk);
            kids[kids.len - 1] = threadOccluder(ui, lk, profilePanel(ui, model, .{ .person = pk }, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
            break :blk ui.stack(.{ .grow = 1 }, .{kids});
        }
        const lk = threadLevelKey(model.thread_stack_len, model.thread_root.id);
        kids[kids.len - 1] = threadOccluder(ui, lk, if (isArticleRoot(&model.thread_root))
            articlePanel(ui, model, &model.thread_root, lk, model.thread_stack_len, false)
        else
            threadPanel(ui, model, &model.thread_root, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
        break :blk ui.stack(.{ .grow = 1 }, .{kids});
    } else feed;

    // The window is the rail plus the content. The old titlebar of buttons is
    // gone: home, compose, settings, and the account seat live on the rail, so
    // the feed owns the full width below the OS titlebar.
    const second_rail = places.g_rail_open;
    return ui.row(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        railView(ui, model),
        // A 1px vertical rule between the rail and the content. No `grow`: in a
        // row that would stretch it along the WIDTH and eat the feed's space; it
        // fills the height on its own via the row's cross-axis stretch.
        ui.separator(.{ .width = 1, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        // The second rail, and its own rule. Contents are a pure function of
        // which primary section is selected, so there is nothing to consult here
        // beyond that: Home has no second rail, Places is a list of yours.
        if (second_rail) placesRail(ui) else ui.spacer(0),
        if (second_rail)
            ui.separator(.{ .width = 1, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } })
        else
            ui.spacer(0),
        // The bar sits BESIDE the rail and BELOW everything else, which is the
        // only place it is always visible. It used to be the last row of the
        // feed's own column, so every level layered over the feed (a thread, a
        // person) covered it: the pool's health, the outbox and the signer
        // vanished the moment a reader opened a note, which is not a moment to
        // stop telling them whether their notes can go out.
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            content,
            statusBar(ui, model),
        }),
    });
}

/// The feed content column: the guest banner, the scope line, the note list, and
/// the status bar.
fn feedContent(ui: *AppUi, model: *const Model) AppUi.Node {
    // The data-window seam: the runtime resolves scroll offset and viewport
    // into a visible index range, and only those rows are built. A feed of any
    // length then costs what the handful on screen costs.
    var options = feedOptions(model);
    // Nothing to cover when nothing is drawn. The runtime re-runs the WHOLE build
    // and layout a second time whenever a declared window reports fewer built
    // rows than its item count and viewport imply, which an occluded list does by
    // construction: it declares two hundred items and builds none, so it is
    // permanently "undercovered" and every rebuild costs two. That is the exact
    // opposite of what occluding it was for, and it lands on the most ordinary
    // state in the app: one thread open over the feed, rebuilt on every tick,
    // every scroll and every keystroke.
    //
    // A count of zero is the runtime's own early-out (`item_count == 0` skips the
    // coverage check). The retained scroll offset rides on the list's ID and the
    // extent table behind it, neither of which this touches, so the feed is still
    // where the reader left it on the way back.
    const window = ui.virtualWindow(options);
    // A SHEET counts too, and for a long time it did not. Settings, the
    // composer, the notifications panel and the join ladder all sit over the
    // feed on a scrim, and the feed underneath was being built in full on every
    // frame of scrolling one of them.
    //
    // Measured on a real 105 MB store: scrolling settings cost 1775us to rebuild
    // and 6806us to lay out, with 747 nodes mounted. Without the feed beneath
    // it: 142us, 933us, 240 nodes. Seven times the layout work, for rows behind
    // a 55% scrim and a blur.
    //
    // The trade is visible and worth naming: those bands either side of a sheet
    // now show the app's background rather than a blurred, dimmed feed.
    const occluded = model.levelOpen() or
        model.stage == .settings or model.composing or model.notifications_open or model.joining;
    if (occluded) options.item_count = 0;
    // A level drawn opaquely over the feed hides every one of these rows, and
    // building them anyway spent about a third of the whole 1024-node view
    // budget on things nobody can see. The thread and the profile have taken an
    // `occluded` parameter since they were written; the feed never did, because
    // for a long time it was the only list there was.
    //
    // The list stays MOUNTED, so its scroll offset survives exactly as an occluded
    // level's does: the offset rides on the id and the retained extents, not on
    // the rows built this frame.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch {
            ui.failed = true;
            return ui.column(.{}, .{});
        };
        for (built, 0..) |*row, offset| row.* = noteCard(ui, &model.notes[window.start_index + offset]);
        break :blk built;
    };

    // Exactly which rows are on screen, which is what decides where the image
    // budget goes. Recorded here because the runtime resolves it during the
    // build, while the fetch pass runs later, in `update`. Left alone while
    // occluded: the picture passes have their own branches for the level that
    // is actually being read, and zeroing this would make the feed reload every
    // face on the way back.
    if (!occluded) {
        feed_media.g_visible_first = window.first_visible_index;
        feed_media.g_visible_last = window.last_visible_index;
    }

    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (model.show_guest_strip()) guestBanner(ui, model) else ui.spacer(0),
        // Under the guest strip, because being signed out is the bigger fact.
        offlineBanner(ui, model),
        // A relay is waiting on an answer only the reader can give.
        relayAuthBanner(ui),
        // Under all of them. A newer version existing is the least urgent and
        // the only one the reader can put away.
        updateBanner(ui),
        // ONE header, not two. A place stacked its own banner on top of the
        // scope line, so the top of the room was the place's name over the
        // place's feed name over a rule, in two different rhythms. In a place
        // the place header IS the scope line, and it keeps the same 11/9 insets
        // so nothing jumps on the way in or out.
        if (activePlace()) |m| placeHeader(ui, model, m) else scopeHeader(ui, model),
        if (model.notes_len == 0)
            ui.column(.{ .gap = 12, .main = .center, .cross = .center, .grow = 1, .padding = 24 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.empty_text()),
            })
        else
            // The list owns its scroll state, keyed by the id in `feedOptions`,
            // so the offset survives every rebuild (and the image viewer
            // opening over it) without the model mirroring it.
            ui.virtualList(options, window, .{rows}),
        if (model.backup_nudge) backupNudge(ui) else ui.spacer(0),
    });
}

/// The 56px primary rail: the destinations up top, then the compose verb, the
/// Settings gear, and the "you" seat pinned to the bottom. This replaces the old
/// titlebar of buttons: destinations on the edge, the feed owns the width. A
/// guest's gated tiles (compose, settings, you) route to the join sheet.
///
/// Three of the five destinations the design names. Search and Messages are not
/// built and are therefore not here: a rail item that goes nowhere is worse than
/// one fewer, which is the same rule that keeps Groups off until NIP-29 ships.
///
/// Our split is inverted from the strongest prior art and that is a choice.
/// Flotilla and Discord put the COMMUNITIES on the primary rail with three or
/// four fixed destinations pinned under them; we put destinations primary and
/// places secondary, which is Slack's shape. The deciding factor is how many
/// top-level things the app ends up with: Discord has essentially one, so
/// servers earn the outer rail, and Plaza is heading for five or six.
fn railView(ui: *AppUi, model: *const Model) AppUi.Node {
    const guest = model.is_guest();
    const compose_press: Msg = if (guest) .open_join else .open_compose;
    const settings_press: Msg = if (guest) .open_join else .open_settings;
    // Gap 0 with explicit steps: the rail insets are 10 above and 12 below, which
    // one uniform padding cannot state. The 10 on each side is exactly what
    // centring a 36px tile in the 56px rail leaves, so it stays as padding.
    return ui.column(.{ .width = 56, .cross = .center, .gap = 0, .padding = 10, .style_tokens = .{ .background = .background } }, .{
        // Home: the mark, and the way back to your own feed from wherever the
        // reader has got to, INCLUDING out of a place. It looked like the app's
        // own button for a long time and did nothing when pressed, which is the
        // one thing a mark in that position should never be.
        railDest(ui, "mark", 21, Msg.go_home, "Home", places.g_place == null),
        vgap(ui, rail_gap),
        // The bell, with what is waiting on it. Signed out there is no inbox to
        // have, so there is no bell: a tile that could only ever say zero is a
        // tile that says nothing.
        //
        // It takes no selected plate, and that is not an oversight: it opens a
        // SHEET over whatever is underneath rather than being a section of its
        // own, so a plate would claim a selection the app does not have.
        if (guest) ui.spacer(0) else railBell(ui),
        if (guest) ui.spacer(0) else vgap(ui, rail_gap),
        // Places: the switcher rail, out or folded away. Shown even with an
        // empty list, because the rail's empty state is how somebody learns
        // what a place is and that a link opens one, which in v1 is the only
        // way in. The plate says you are IN a place, which is the fact worth
        // showing; whether the rail happens to be out is visible on its own.
        railDest(ui, "places", 17, Msg.toggle_places_rail, "Places", places.g_place != null),
        vgap(ui, rail_gap),
        // An address, and the way in for anything somebody hands you.
        //
        // The design names five rail destinations and Search is one of the two
        // that were left out, because a tile that goes nowhere is worse than one
        // fewer. It goes somewhere now.
        //
        // No selected plate, for the bell's reason rather than as an oversight:
        // it opens a SHEET over whatever is underneath rather than being a
        // section of its own, and a plate would claim a selection the app does
        // not have.
        //
        // Shown to guests too. Reading needs no key, and a link somebody sent is
        // one of the first things a person who has not signed in arrives with.
        // That is the same call the account menu's row makes.
        railTile(ui, "search", 16, .open_address, "Search", false),
        // The bottom cluster hangs off the floor of the rail: verbs, then meta.
        ui.spacer(1),
        // Compose: the one bright tile.
        railTile(ui, "edit", 15, compose_press, "New note", true),
        vgap(ui, rail_gap),
        // Settings.
        railTile(ui, "settings", 16, settings_press, "Settings", false),
        vgap(ui, rail_gap),
        // The account seat: a dashed "you" as a guest, the account once signed in.
        railYou(ui, guest),
        vgap(ui, 2),
    });
}

/// A primary-rail destination: the same 36px tile as a verb, plus the one thing
/// a destination has that a verb does not, which is being where you are.
///
/// The plate says where you are, and the two that have one are exclusive by
/// construction: Home is plated out of a place, the pin is plated in one, and
/// there is no third state. Discord's left-edge indicator bar reads better but
/// has nowhere to live here: the 56px rail is a 36px tile between two 10px
/// insets, and a bar inside the tile's own box paints on top of the plate
/// instead of beside it.
fn railDest(ui: *AppUi, comptime icon: []const u8, size: f32, press: Msg, label: []const u8, selected: bool) AppUi.Node {
    const p = theme.palette;
    const tint = if (selected) p.text_primary else p.text_muted;
    const glyph = ui.appIcon(.{ .width = size, .height = size, .style = .{ .foreground = tint } }, icon);
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        if (selected)
            tilePlate(ui, .{ .background = p.surface_rail_tile, .border = p.border_hairline, .radius = 9, .stroke_width = 1 }, "", glyph)
        else
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The width of the second rail. Every point of it is added to the window's
/// floor in `app.zon`, because a floor cannot be conditional and the narrowest
/// window has to hold the widest arrangement.
const places_rail_width: f32 = 180;
/// Everything to the left of the reading area when both rails are out: the two
/// rails and the 1pt rule after each. The window's default size is stated in
/// terms of this, so a rail that changes width takes the window with it.
pub const rails_width: f32 = 56 + 1 + places_rail_width + 1;
const place_row_height: f32 = 34;
const place_tile_size: f32 = 24;
const places_rail_inset: f32 = 12;
/// What is left for a name once the inset, the tile and the gap are spent. A
/// DEFINITE width, so a long one ellipsizes instead of pushing the rail wide.
const place_name_width: f32 = places_rail_width - places_rail_inset * 2 - place_tile_size - 8;

/// The second rail: the places you have entered, and the one you are visiting.
///
/// Contents are a pure function of which primary section is selected, which is
/// why this takes nothing but the arena: Places is the only section with a
/// second rail, so being drawn at all is the whole of the condition.
///
/// It does not scroll and needs no overflow rule. Flotilla computes an item
/// limit from the window height and moves the rest into a popover, which is the
/// right answer at its scale; eight places at 34 points fit inside the 680pt
/// window floor with room to spare, and a rule for a case that cannot happen is
/// a rule nobody can check.
fn placesRail(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const visiting = visitingPlace();
    const rows = ui.arena.alloc(AppUi.Node, places.g_places_len) catch {
        ui.failed = true;
        return ui.column(.{ .width = places_rail_width }, .{});
    };
    for (rows, 0..) |*row, i| {
        const open = if (activePlaceIndex()) |c| c == i else false;
        row.* = placeRow(ui, &places.g_places[i], Msg{ .place_open = @intCast(i) }, open);
    }
    return ui.column(.{ .width = places_rail_width, .gap = 0, .style = .{ .background = p.surface_subbar } }, .{
        vgap(ui, 14),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, places_rail_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Places", .weight = .bold, .scale = scope_title_scale }},
            ),
        }),
        vgap(ui, 10),
        // The visit sits above the list and outside it, because that is exactly
        // what a visit is: you are in this place, and it is not one of yours.
        if (visiting != null) railSectionLabel(ui, "Visiting") else ui.spacer(0),
        if (visiting) |m| placeRow(
            ui,
            m,
            // Nothing to press while you are already in it.
            if (places.g_place != null and !places.g_place_kept) null else Msg.place_resume,
            places.g_place != null and !places.g_place_kept,
        ) else ui.spacer(0),
        if (visiting != null and places.g_places_len > 0) vgap(ui, 10) else ui.spacer(0),
        if (visiting != null and places.g_places_len > 0) railSectionLabel(ui, "Entered") else ui.spacer(0),
        ui.column(.{ .gap = 0 }, .{rows}),
        if (places.g_places_len == 0 and visiting == null) placesRailEmpty(ui) else ui.spacer(0),
        ui.spacer(1),
    });
}

/// A small quiet label over a group of rail rows.
fn railSectionLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, places_rail_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint } },
                &.{.{ .text = text, .monospace = true, .scale = mono_meta_scale }},
            ),
        }),
        vgap(ui, 4),
    });
}

/// The tile a place wears on the rail, and the whole of what makes that rail
/// legible rather than a column of identical grey squares with a letter in each.
///
/// Two sources, in order. A place that states `defaultPrimaryColor` gets
/// exactly that, so the rail matches the branding the community uses everywhere
/// else. A place that states nothing falls back to the SAME pubkey-keyed
/// rotation a face gets: it costs nothing, needs no configuration, and still
/// tells two places apart, which the flat `surface_link_tile` never did.
fn placeTileColors(m: *const Place) struct { bg: canvas.Color, ink: canvas.Color } {
    if (m.color) |c| return .{ .bg = c.primary, .ink = c.on_primary };
    const tint = avatarTint(m.author);
    return .{ .bg = tint.bg, .ink = tint.glyph };
}

pub fn placeTileColorsForTest(m: *const Place) struct { bg: canvas.Color, ink: canvas.Color } {
    const c = placeTileColors(m);
    return .{ .bg = c.bg, .ink = c.ink };
}

/// One place on the second rail: a letter tile and a name.
///
/// A LETTER tile, not the host's picture, and that is a budget decision rather
/// than a taste one. The canvas registers sixteen images at a time, and a rail
/// of eight would spend half of them on chrome that is always on screen, taken
/// from the faces in the feed. `image_src` (a source-crop rect) would let one
/// 512x512 slot hold sixty-four tiles at 64x64; it exists on the internal widget
/// and is not exposed on the app-facing options, which is filed upstream as
/// vercel-labs/native#387. Until that lands, letters.
fn placeRow(ui: *AppUi, m: *const Place, press: ?Msg, selected: bool) AppUi.Node {
    const p = theme.palette;
    const name = if (m.name_len > 0) m.name() else "A place";
    // The first BYTE, uppercased when it is a lowercase ASCII letter. A name
    // starting with a multi-byte character would be cut mid-codepoint by a
    // one-byte slice, so anything that is not printable ASCII falls back to a
    // dot rather than to half a character.
    const head = name[0];
    const initial: []const u8 = if (head >= 'a' and head <= 'z')
        ui.fmt("{c}", .{head - 32})
    else if (head > 0x20 and head < 0x7f)
        ui.fmt("{c}", .{head})
    else
        "\u{2022}";
    const tile = placeTileColors(m);
    return pressRow(ui, .{
        .width = places_rail_width,
        .height = place_row_height,
        .cross = .center,
        .padding = 0,
        .on_press = press,
        // Square, as the `data_row` this was drew it: a list row rounds its wash
        // unless told otherwise.
        .style = if (selected)
            .{ .background = p.surface_menu_selected, .radius = 0 }
        else
            .{ .quiet_hover = true, .radius = 0 },
        .semantics = .{
            .role = if (press == null) .none else .button,
            .label = if (press == null) name else ui.fmt("Open {s}", .{name}),
            .focusable = press != null,
        },
    }, .{
        ui.row(.{ .cross = .center, .gap = 0, .height = place_row_height }, .{
            hgap(ui, places_rail_inset),
            ui.el(.panel, .{
                .width = place_tile_size,
                .height = place_tile_size,
                .padding = 0.01,
                .style = .{ .background = tile.bg, .radius = 6, .stroke_width = 0 },
            }, .{
                ui.column(.{ .width = place_tile_size, .height = place_tile_size, .main = .center, .cross = .center }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = tile.ink } },
                        &.{.{ .text = initial, .monospace = true, .weight = .medium, .scale = mono_meta_scale }},
                    ),
                }),
            }),
            hgap(ui, 8),
            ui.paragraph(
                .{ .width = place_name_width, .style = .{ .foreground = if (selected) p.text_primary else p.text_muted } },
                &.{.{ .text = name, .scale = meta_scale }},
            ),
        }),
    });
}

/// What the rail says before there is anything in it.
///
/// It names the one way in that v1 has. A link is the only door, so a rail that
/// simply looked empty would be the feature failing to explain itself on the
/// only screen where it could.
fn placesRailEmpty(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .start, .gap = 0 }, .{
        hgap(ui, places_rail_inset),
        ui.paragraph(
            .{ .wrap = true, .width = places_rail_width - places_rail_inset * 2, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "No places yet. A plaza:// link opens one, and entering it keeps it here. Only you can see this list.", .scale = mono_hint_scale }},
        ),
    });
}

/// A 36px rail plate with one centered glyph.
///
/// The plate is a `.panel`, not a styled column. The renderer draws NOTHING for
/// the layout kinds (stack, row, column and friends), which is why every rail tile
/// had been painting as bare window, the bright compose tile included. A `.card`
/// paints but carries a 240x120 intrinsic size that blew the rail apart; `.panel`
/// paints AND sizes to its children. It layers its children, so the sizing column
/// inside does the centring, and the 0.01 padding is belt and braces: the house
/// padding substitution only reaches kinds that declare a default layout, which a
/// panel does not, so the plate sits flush either way.
fn tilePlate(ui: *AppUi, style: canvas.WidgetStyle, label: []const u8, glyph: AppUi.Node) AppUi.Node {
    // An empty label leaves the plate anonymous, which is what a plate inside a
    // named pressable row wants: two nodes with one name read as two controls.
    // Every caller is inside one now, so every caller passes "".
    return ui.el(.panel, .{ .padding = 0.01, .style = style, .semantics = .{ .label = label } }, .{
        ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The bell tile, with its count.
///
/// No mock draws the badge anywhere, so this is the smallest thing that reads as
/// one: a small light pill on the tile's top-right corner, absent at zero,
/// capped at "9+". Flagged in the PR.
fn railBell(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const unread = inboxUnread();
    return pressRow(ui, .{
        .width = 36,
        .height = 36,
        .main = .center,
        .cross = .center,
        .padding = 0,
        .on_press = Msg.toggle_notifications,
        .style = .{ .quiet_hover = true },
        .semantics = .{
            .role = .button,
            .label = if (unread == 0) "Notifications" else ui.fmt("Notifications, {d} unread", .{unread}),
            .focusable = true,
        },
    }, .{
        ui.stack(.{ .width = 36, .height = 36 }, .{
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{
                ui.appIcon(.{ .width = 17, .height = 17, .style = .{ .foreground = p.text_muted } }, "bell"),
            }),
            if (unread == 0) ui.spacer(0) else badgePill(ui, unread),
        }),
    });
}

/// The count itself, pinned to the tile's top-right.
fn badgePill(ui: *AppUi, count: usize) AppUi.Node {
    const p = theme.palette;
    const label = if (count > 9) "9+" else ui.fmt("{d}", .{count});
    return ui.column(.{ .width = 36, .height = 36, .main = .start, .cross = .end }, .{
        // The digit sits in a ROW inside the panel, not in the panel.
        //
        // `.panel` is a stacking kind: it hands every child the whole content box
        // and takes the MAX of them for its own size rather than the sum. The two
        // four-pixel spacers were therefore layered behind the digit instead of
        // inset either side of it, and contributed nothing at all. The pill's
        // width was the glyph advance, about five and a half points, so the
        // declared radius of 7 clamped to half of that and the "pill" painted as
        // a narrow lozenge with the number running edge to edge.
        ui.el(.panel, .{
            .padding = 0.01,
            .height = 13,
            // A floor, so one digit and two are the same shape rather than the
            // badge changing width with the count. It sets only the minimum, so a
            // wider label still grows: "9+" hugs to about nineteen, and anything
            // longer has room inside the 36-point rail column.
            .min_width = 19,
            .style = .{ .background = p.accent, .border = p.accent, .radius = 7, .stroke_width = 1 },
        }, .{
            // Centred on purpose: the stack gives this row the panel's whole
            // width, so once `min_width` exceeds what the digit needs, the row is
            // what keeps the number in the middle instead of against the left
            // edge.
            ui.row(.{ .main = .center, .cross = .center, .gap = 0 }, .{
                hgap(ui, 4),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.on_accent } },
                    &.{.{ .text = label, .monospace = true, .weight = .medium, .scale = 9.0 / 14.5 }},
                ),
                hgap(ui, 4),
            }),
        }),
    });
}

/// One pressable rail tile: a 36px plate with a centered icon. `bright` paints
/// the accent fill (the compose verb); the rest are quiet with a muted glyph.
fn railTile(ui: *AppUi, comptime icon: []const u8, size: f32, press: Msg, label: []const u8, bright: bool) AppUi.Node {
    const p = theme.palette;
    const tint = if (bright) roomVerbInk() else p.text_muted;
    const glyph = ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = tint } }, icon);
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        // Only the compose tile carries a plate. The quiet tiles are a glyph on
        // the rail itself, so they take no panel at all: a panel with no stated
        // background falls back to the house card fill and would draw a plate the
        // redesign does not have.
        if (bright)
            tilePlate(ui, .{ .background = roomVerbFill(), .radius = 9, .stroke_width = 0 }, "", glyph)
        else
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The account seat at the bottom of the rail. A guest gets a dashed circle
/// marked "you" that opens the join sheet; a signed-in user gets a small tinted
/// initials avatar that opens their own page.
fn railYou(ui: *AppUi, guest: bool) AppUi.Node {
    const p = theme.palette;
    // The seat is the reader's own face, so it goes where every other face in
    // the app goes: that person's page. It pointed at Settings for as long as
    // there was no profile screen to point at, which quietly taught that "you"
    // means "your preferences". Settings keeps its own tile one row up, and
    // editing still lives there, which is what the profile's own "This is you"
    // says instead of standing up a second door to it.
    //
    // The key comes from `activePubkey` rather than from the `guest` flag so the
    // branch and the payload cannot disagree: with no identity there is no
    // `.open_person` carrying thirty-two bytes that belong to nobody.
    const press: Msg = if (activePubkey()) |me| Msg{ .open_person = me } else .open_join;
    return pressRow(ui, .{
        .on_press = press,
        // The tile's own box, stated. Left unsized, this row measured ZERO wide
        // (a `data_row` hugs its content and the seat inside it is centred, not
        // stretched), so the account seat floated free of the rail's column
        // while every glyph tile sat squarely in its 36. It was the one tile on
        // the rail that did not line up.
        .width = 36,
        .height = 36,
        .main = .center,
        .cross = .center,
        .padding = 0,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "You", .focusable = true },
    }, .{
        // The same 36x36 centring box every other rail tile uses. Without it the
        // 28px seat sat at the row's natural position while the 36px glyph tiles
        // sat centred in theirs, so the account avatar hung 4px off the rail's
        // shared centre line: the one tile on the rail that did not line up.
        ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{
            if (guest)
                // The seat reads as an outline waiting to be filled, so its ring
                // is dashed. The canvas has no dashed strokes, so the ring is an
                // icon whose dashes are baked into its geometry, with the label
                // stacked over it.
                ui.stack(.{ .width = 28, .height = 28 }, .{
                    ui.appIcon(.{ .width = 28, .height = 28, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                    ui.column(.{ .width = 28, .height = 28, .main = .center, .cross = .center }, .{
                        ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "you", .monospace = true, .scale = 8.5 / 14.5 }}),
                    }),
                })
            else
                youAvatar(ui),
        }),
    });
}

/// The signed-in account avatar for the rail: a 28px tinted circle with the
/// pubkey's initials (the same warm tint the feed uses for that key).
fn youAvatar(ui: *AppUi) AppUi.Node {
    return meAvatar(ui, 28);
}

/// The registered avatar image id for `pubkey`, or 0 to draw initials.
///
/// The `.loaded` gate is load-bearing rather than cautious. The renderer takes
/// the image branch for ANY non-zero id and draws the initials only in the else,
/// so an id that has been lent but whose bytes have not arrived paints an EMPTY
/// disc instead of falling back. A slot is claimed before the fetch and survives
/// a failed one, so both of those states have to report zero.
fn avatarImageId(pubkey: [32]u8) u64 {
    const p = lookupProfile(pubkey) orelse return 0;
    if (p.avatar_state != .loaded) return 0;
    return p.image_id;
}

/// The signed-in reader's own disc at a stated size: the rail seats a 28, the
/// thread's reply row a 36 to match the note it answers.
///
/// It drew initials and only initials, because it never passed an image. Every
/// other link already worked: the reader's own kind:0 is asked for by the feed
/// subscription and by `ownProfileWorker`, `refreshProfiles` puts their pubkey
/// in the author list explicitly, and `assignAvatarSlots` pushes them FIRST so
/// they get one of the scarce ids ahead of any feed author. All of that ran, and
/// then the widget was built without the id it had earned.
fn meAvatar(ui: *AppUi, size: f32) AppUi.Node {
    const pk = activePubkey() orelse return ui.spacer(0);
    const tint = avatarTint(pk);
    const hexdigits = "0123456789abcdef";
    return ui.avatar(.{
        .width = size,
        .height = size,
        .image = avatarImageId(pk),
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
    }, ui.fmt("{c}{c}", .{ hexdigits[pk[0] >> 4], hexdigits[pk[0] & 0x0f] }));
}

/// The backup nudge: calm, dismissible, the stakes stated plainly. Rises once,
/// after the first local-key post of a session.
fn backupNudge(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .style = .{ .background = p.surface_subbar } }, .{
        ui.column(.{ .height = 1, .style = .{ .background = p.divider_chrome } }, .{}),
        ui.row(.{ .cross = .center, .gap = 10, .padding = 10 }, .{
            ui.text(
                .{ .size = .sm, .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.",
            ),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .backup_now }, "Back up"),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .backup_later }, "Not now"),
        }),
    });
}

/// The guest banner: a full-width top bar over the feed with the invitation and
/// the two join CTAs, always present here so sign-in is never more than one bar
/// away. Dismissible, and safely so: the rail's compose and account tiles and
/// the status bar's Guest chip all keep a way in after it is closed.
fn guestBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    const p = theme.palette;
    // On a `.panel`, not a column: a column paints no background at all, so the
    // banner had been reading as plain window behind its own copy.
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_subbar, .stroke_width = 0, .radius = 0 } }, .{
        ui.column(.{ .gap = 0 }, .{
            vgap(ui, 8),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, chrome_inset),
                ui.paragraph(
                    .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                    &.{.{ .text = "Browsing as a guest. Reading is yours forever. Join in when something moves you.", .scale = meta_scale }},
                ),
                hgap(ui, 10),
                pillButton(ui, "Create identity", .open_join, true, p.surface_subbar),
                hgap(ui, 10),
                pillButton(ui, "Sign in", .open_join, false, p.surface_subbar),
                hgap(ui, 10),
                // An icon press, not a text button: the built-in x glyph (the
                // U+2715 codepoint is outside Geist's coverage, rendered tofu).
                // Padded well past the 12px glyph: the target is the press, not the
                // drawing.
                pressRow(ui, .{
                    .padding = 6,
                    .on_press = .dismiss_guest_strip,
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Dismiss", .focusable = true },
                }, .{
                    ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "x"),
                }),
                hgap(ui, chrome_inset),
            }),
            vgap(ui, 8),
            ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        }),
    });
}

/// The feed's scope line: which feed this is (the starter pack) and how wide it
/// reaches. A property of the feed, not a destination to choose between.
/// The header of the place you are in: who it belongs to, what they wrote, and
/// the way out.
///
/// While VISITING it also carries the one affordance that matters, and it is a
/// quiet line rather than a wall: entering keeps the place, and nothing else in
/// the app is gated on it. You can already read here and post here.
///
/// It says entering is private on the spot rather than in settings, because a
/// list of the communities somebody belongs to is sensitive and they should
/// learn that where the decision is, not afterwards.
/// How much of a stranger's naming fits on the room's one header line.
///
/// The line is the name, the connection state, the feed's name, About and the
/// verb, all inside the 620pt column with 16pt insets. The app's own strings
/// and the two buttons are the budget; the two names arrive from a place a
/// stranger published, at 64 and 48 bytes, and both of them at full length
/// overflowed the window by 240pt at its floor.
///
/// These came down when Info joined the row: the overflow sweep measures the
/// worst case (longest name, longest feed name, "cannot reach this place",
/// Info and Enter together) and it was 20pt over at the floor.
///
/// Named for the LINE, not for the place: `place_name_cap` and
/// `place_feed_name_cap` are what the buffers hold (64 and 48), and these are
/// what one header line can show of them.
const header_name_cap = 20;
const header_feed_cap = 14;

/// The width of the Info card. Wide enough for a paragraph of somebody's
/// markdown without becoming a page.
const place_info_card_width: f32 = 620;

/// How tall the host's own text may be inside that card before it scrolls.
///
/// The card had no bound at all, and nothing showed it until a place arrived
/// with a real `homeMarkdown`: headings and a couple of lists grow a dialog
/// TALLER THAN THE WINDOW, and what falls off the bottom edge is the footer:
/// Close, and Leave. A reader who wants out of a place is exactly the reader
/// looking for those, and they were unreachable.
///
/// A scroll region rather than a shorter excerpt, because Info is the surface
/// where the WHOLE text belongs; cutting it is the welcome's job, not this one.
/// The most of a host's welcome that is shown before it scrolls.
const place_info_home_max: f32 = 380;

/// The place's own mark, drawn in its Info card.
///
/// A much smaller pipeline than the profile banner's, on purpose. That one
/// slices a body too big for one response, falls back off the proxy when a host
/// refuses it, and buffers the pieces. A logo is a small square from a site the
/// community chose: if it does not arrive whole, first time, there is no logo
/// and the card is fine without one.
pub var g_place_logo_id: u64 = 0;
/// Which place's logo is loaded, so walking into another room does not leave
/// the last community's mark on screen.
///
/// Host AND `d`, the pair that identifies a place everywhere else in this file.
/// The host alone is not a place: one community can run several rooms, and they
/// do not share a mark.
var g_place_logo_for: [32]u8 = @splat(0);
var g_place_logo_for_ident_buf: [64]u8 = @splat(0);
var g_place_logo_for_ident_len: u8 = 0;
/// Which place the in-flight fetch was started FOR, which is not always the
/// place on screen by the time it lands. `g_banner_asked_for` carries this for
/// faces, for the same reason and with the same consequence if it is missing.
var g_place_logo_asked_for: [32]u8 = @splat(0);
var g_place_logo_asked_ident_buf: [64]u8 = @splat(0);
var g_place_logo_asked_ident_len: u8 = 0;
pub var g_place_logo_state: enum { idle, fetching, loaded, failed } = .idle;
/// The pass this logo was last on screen. The pool may not take a slot that is
/// being looked at, and it only knows that because this is stamped every pass a
/// place is open.
pub var g_place_logo_seen: u64 = 0;

const place_logo_fetch_key: u64 = 5200;
const place_logo_px: u32 = 96;

/// Drops the mark on screen and hands its slot back to the pool.
///
/// Every exit from a room goes through here: leaving for your own feed, and
/// walking straight into a different room. The second one is the one that was
/// missing, and a logo is not the kind of state that can be left to be
/// overwritten later, because the next room may have nothing to overwrite it
/// with.
fn forgetPlaceLogo(fx: *Effects) void {
    if (g_place_logo_id != 0) {
        _ = fx.unregisterImage(g_place_logo_id);
        g_place_logo_id = 0;
    }
    g_place_logo_for = @splat(0);
    g_place_logo_for_ident_len = 0;
    g_place_logo_state = .idle;
}

/// Whether the mark on screen belongs to the room on screen, for the test.
pub fn placeLogoShownForTest() bool {
    return g_place_logo_state == .loaded and g_place_logo_id != 0;
}

/// A real effect queue whose requests are only recorded, so a handler that asks
/// for a clipboard write or a timer can run to its end in a test. The caller
/// owns it and must `deinit` it.
pub fn recordingEffectsForTest(fx: *Effects, allocator: std.mem.Allocator) void {
    fx.* = Effects.init(allocator);
    fx.executor = .fake;
}

/// An `Effects` bound to nothing, so every effect asked of it is refused. The
/// tests below drive a DECISION, not an effect, and the alternative is passing
/// `undefined` and hoping the path taken never reads it.
pub fn inertEffectsForTest() Effects {
    var fx: Effects = undefined;
    // The one binding the logo path reads. Unbound means `unregisterImage`
    // refuses and returns, which is exactly the behaviour a test wants: the
    // slot bookkeeping is the pool's, and this is not a test about the pool.
    fx.images = null;
    return fx;
}

/// A mark loaded and on screen for a given place, the way a finished fetch
/// leaves it, so a test can walk out of that room and see what stays behind.
pub fn setPlaceLogoLoadedForTest(id: u64, pubkey: [32]u8, ident: []const u8) void {
    g_place_logo_id = id;
    g_place_logo_for = pubkey;
    g_place_logo_for_ident_len = @intCast(copyBounded(&g_place_logo_for_ident_buf, ident));
    g_place_logo_state = .loaded;
}

pub fn scanPlaceLogoForTest(fx: *Effects, model: *const Model) void {
    scanPlaceLogo(fx, model);
}

/// A fetch in flight, started by a given place.
pub fn setPlaceLogoAskedForTest(pubkey: [32]u8, ident: []const u8) void {
    g_place_logo_asked_for = pubkey;
    g_place_logo_asked_ident_len = @intCast(copyBounded(&g_place_logo_asked_ident_buf, ident));
    g_place_logo_state = .fetching;
}

pub fn placeLogoStateNameForTest() []const u8 {
    return @tagName(g_place_logo_state);
}

/// Hands the logo pipeline a fetched body, the way the effect loop does.
pub fn deliverPlaceLogoBodyForTest(fx: *Effects, body: []const u8) void {
    handlePlaceLogoFetched(fx, .{
        .key = place_logo_fetch_key,
        .outcome = .ok,
        .status = 200,
        .body = body,
    });
}

/// Fetches the place's mark once, and forgets it when the reader leaves.
fn scanPlaceLogo(fx: *Effects, model: *const Model) void {
    _ = model;
    const place = activePlace() orelse {
        // Out of every room: the slot goes back to the pool rather than holding
        // a picture nobody can see. The feed underneath is what wants it.
        forgetPlaceLogo(fx);
        return;
    };
    // On screen this pass, so the allocator will not take the slot out from
    // under the reader. Stamped before any early return below: a logo that is
    // loaded and simply not being re-fetched still needs its slot kept.
    g_place_logo_seen = profile_cache.g_image_clock;

    // A different community is a different mark, and this is decided BEFORE any
    // return below can skip it. It used to sit under the two guards that follow,
    // so a room with no logo of its own took the early return and left the last
    // room's mark loaded and on screen: one community's logo on another
    // community's card, which is what was reported. Walking OUT of a room
    // already cleared it, so only walking room to room could show it.
    //
    // Compared by identity rather than by the URL: two places may ship the same
    // logo and still be different rooms.
    if (!std.mem.eql(u8, &g_place_logo_for, &place.author) or
        !std.mem.eql(u8, g_place_logo_for_ident_buf[0..g_place_logo_for_ident_len], place.ident()))
    {
        forgetPlaceLogo(fx);
        g_place_logo_for = place.author;
        g_place_logo_for_ident_len = @intCast(copyBounded(&g_place_logo_for_ident_buf, place.ident()));
        // Cleared above, so this pass is the new room's first: stamp it again or
        // the pool may take the slot this is about to ask for.
        g_place_logo_seen = profile_cache.g_image_clock;
    }
    if (!prefs.g_media_previews) return;
    const logo = place.logo();
    if (logo.len == 0) return;
    if (g_place_logo_state != .idle) return;

    if (g_place_logo_id == 0) {
        g_place_logo_id = acquireImageId(fx) orelse return;
    }
    if (loadCachedImage(fx, g_place_logo_id, logo, place_logo_px)) |_| {
        g_place_logo_state = .loaded;
        return;
    }
    g_place_logo_state = .fetching;
    // Stamped with the asker, next to the ask.
    g_place_logo_asked_for = place.author;
    g_place_logo_asked_ident_len = @intCast(copyBounded(&g_place_logo_asked_ident_buf, place.ident()));
    fetchSlice(fx, place_logo_fetch_key, logo, 0, Effects.responseMsg(.place_logo_fetched));
}

fn handlePlaceLogoFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key != place_logo_fetch_key) return;
    const arrived_for = activePlace() orelse {
        g_place_logo_state = .idle;
        return;
    };
    // The body was asked for by a ROOM, and the reader can walk into a different
    // one while it is in flight. Painting it now would put one community's mark
    // on another community's card and, worse, cache it under the NEW room's URL
    // (`storeCachedImage` below keys on `place.logo()`), so the wrong logo would
    // come back on every later visit and every later launch. Set idle rather
    // than failed: this body is wrong, the room's own logo has not been tried.
    if (!std.mem.eql(u8, &g_place_logo_asked_for, &arrived_for.author) or
        !std.mem.eql(u8, g_place_logo_asked_ident_buf[0..g_place_logo_asked_ident_len], arrived_for.ident()))
    {
        g_place_logo_state = .idle;
        return;
    }
    // Every effect slot was busy: ask again next tick.
    if (response.outcome == .rejected) {
        g_place_logo_state = .idle;
        return;
    }
    // 206 as well as 200. The fetch asks for a RANGE, so a server that honours
    // it answers Partial Content even when what came back is the whole file,
    // which is the usual case for something this small. Accepting only 200
    // threw a perfectly good logo away.
    //
    // No accumulator behind this: if a logo really is too big for one response,
    // the decode below fails and there is no logo, which is what this pipeline
    // promises. See `g_place_logo_id`.
    const usable = response.outcome == .ok and (response.status == 200 or response.status == 206);
    if (!usable or response.truncated or
        response.body.len == 0 or response.body.len > max_image_bytes)
    {
        g_place_logo_state = .failed;
        return;
    }
    if (decodeAndRegister(fx, g_place_logo_id, response.body, place_logo_px)) |_| {
        g_place_logo_state = .loaded;
        storeCachedImage(arrived_for.logo(), response.body);
    } else {
        g_place_logo_state = .failed;
    }
}

/// How wide the welcome may be inside the card.
///
/// The card is 620 and the welcome was laid out at 580, which put its left edge
/// where the padding says and ran its right edge onto the card's border. The
/// inset is 40 a side, not 20. Measured off what is drawn rather than derived
/// from the padding value, because what the reader sees is the thing that was
/// wrong.
const place_info_home_width: f32 = place_info_card_width - 80;

/// How tall the welcome needs to be, so a short one does not leave a void.
///
/// This was a fixed 380 and a two-line welcome sat above three hundred points
/// of nothing, with the Close button stranded at the bottom of an empty box.
/// There is no `max_height` on a canvas node, so the height has to be worked
/// out rather than declared.
///
/// An ESTIMATE, deliberately generous. Over-guessing costs a little scroll at
/// the end; under-guessing cuts the host's last line off, and of the two only
/// one loses somebody's words.
fn placeHomeHeight(text: []const u8) f32 {
    // At 540 points and this body size, about 72 characters fit on a line.
    // Read off a render at that width: the second paragraph of the welcome that
    // prompted all this wraps after 73.
    // Measured off a real render rather than guessed: the welcome that prompted
    // this wraps after 82 and its second paragraph fits 165 in two lines.
    const per_line: usize = 72;
    const line_height: f32 = 21;
    // Lines of text and gaps BETWEEN blocks are charged separately: the
    // renderer puts 12 points between blocks, not a blank line's worth, and
    // several blank lines in a row are still one break.
    const block_gap: f32 = 12;
    var lines: usize = 0;
    var breaks: usize = 0;
    var in_gap = true; // leading blanks are not a break
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const shown = visibleLen(line);
        if (shown == 0) {
            if (!in_gap) breaks += 1;
            in_gap = true;
            continue;
        }
        in_gap = false;
        lines += (shown + per_line - 1) / per_line;
    }
    // No slack on the end. This is a SCROLL, so guessing low costs a little
    // scrolling and guessing high leaves a void with the buttons stranded below
    // it, which is the bug this function exists for. I had that backwards once.
    const wanted = @as(f32, @floatFromInt(lines)) * line_height +
        @as(f32, @floatFromInt(breaks)) * block_gap;
    return @min(wanted, place_info_home_max);
}

/// How much of a markdown line a reader actually sees.
///
/// Counting raw bytes is what made the first estimate useless: one paragraph of
/// this welcome carries `[experimental customizeable client](/nevent1q…)`, and
/// that address is two hundred characters that are never drawn. The line looked
/// four times longer than it reads.
fn visibleLen(line: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    // Leading heading markers and quote marks are syntax, not text.
    while (i < line.len and (line[i] == '#' or line[i] == '>' or line[i] == ' ')) i += 1;
    while (i < line.len) {
        // `](url)` is an address. Skip to its closing paren.
        if (line[i] == ']' and i + 1 < line.len and line[i + 1] == '(') {
            if (std.mem.indexOfScalarPos(u8, line, i + 2, ')')) |end| {
                i = end + 1;
                continue;
            }
        }
        // The brackets and emphasis marks themselves are not drawn either.
        if (line[i] == '[' or line[i] == ']' or line[i] == '*' or line[i] == '`') {
            i += 1;
            continue;
        }
        n += 1;
        i += 1;
    }
    return n;
}

pub fn visibleLenForTest(line: []const u8) usize {
    return visibleLen(line);
}

pub fn placeHomeHeightForTest(text: []const u8) f32 {
    return placeHomeHeight(text);
}

/// What a place is, who hosts it, where it reads from, and the way out.
///
/// Everything the old inline banner said, in a card nobody has to scroll past.
/// Leave lives here rather than in the header for two reasons: it is the one
/// destructive verb in a place and it was sitting a few pixels from Enter, and
/// a reader who is about to leave is exactly the reader who should be looking
/// at what this place is.
/// The host's own words, with image syntax carrying no alt text removed.
///
/// The renderer draws an image as its ALT TEXT, which is the right call for a
/// client that spends its whole image budget on faces. `![alt](url)` therefore
/// reads as "alt". But `![](url)`, which is valid markdown and what Hallway's
/// Monero instance writes, has no alt to draw: the renderer does not take it as
/// an image at all, so the reader gets a literal `![]` followed by the raw URL
/// as a link.
///
/// An image with no alt text says nothing that can be written down, so nothing
/// is what it should leave behind.
fn placeHome(ui: *AppUi, m: *const Place) []const u8 {
    return stripEmptyImages(ui.arena, m.home());
}

pub fn stripEmptyImagesForTest(arena: std.mem.Allocator, src: []const u8) []const u8 {
    return stripEmptyImages(arena, src);
}

fn stripEmptyImages(arena: std.mem.Allocator, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "![](") == null) return src;
    var out = std.ArrayList(u8).initCapacity(arena, src.len) catch return src;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "![](")) {
            // To the closing paren of the URL. An unclosed one is not image
            // syntax, so it is left exactly as the host wrote it.
            if (std.mem.indexOfScalarPos(u8, src, i + 4, ')')) |end| {
                i = end + 1;
                continue;
            }
        }
        out.append(arena, src[i]) catch return src;
        i += 1;
    }
    return out.items;
}

fn placeInfoCard(ui: *AppUi, m: *const Place) AppUi.Node {
    const p = theme.palette;
    const leaving = places.g_place_info == .leaving;
    var npub_buf: [96]u8 = undefined;
    const host = abbreviateNpub(&npub_buf, m.author);
    const relay = if (currentPlaceFeed(m)) |f| f.relay() else "";
    return modalScrim(ui, "About this place", .close_place_info, ui.el(.dialog, .{
        .width = place_info_card_width,
        .on_dismiss = .close_place_info,
        .semantics = .{ .label = "About this place" },
    }, .{
        modalCard(ui, place_info_card_width, ui.column(.{ .grow = 1, .gap = 0, .padding = 20 }, .{
            // The mark beside the name when the community ships one and it has
            // arrived. Nothing reserved for it otherwise: a gap where a logo
            // might have been is worse than a title on its own.
            if (g_place_logo_state == .loaded and g_place_logo_id != 0) ui.row(.{ .cross = .center, .gap = 10 }, .{
                ui.image(.{ .image = g_place_logo_id, .width = 28, .height = 28, .semantics = .{ .label = "Place logo" } }),
                ui.paragraph(
                    .{ .grow = 1, .wrap = true, .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = if (m.name_len > 0) m.name() else "A place", .weight = .bold, .scale = join_title_scale }},
                ),
            }) else ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = if (m.name_len > 0) m.name() else "A place", .weight = .bold, .scale = join_title_scale }},
            ),
            vgap(ui, 10),
            placeInfoRow(ui, "Host", ui.fmt("@{s}", .{host})),
            if (relay.len > 0) vgap(ui, 4) else ui.spacer(0),
            if (relay.len > 0) placeInfoRow(ui, "Reads", relay) else ui.spacer(0),
            // The host's own words, in the one place that is theirs to fill.
            if (m.home_len > 0) vgap(ui, 12) else ui.spacer(0),
            if (m.home_len > 0) ui.separator(.{ .style = .{ .foreground = p.divider_card, .background = p.divider_card } }) else ui.spacer(0),
            if (m.home_len > 0) vgap(ui, 4) else ui.spacer(0),
            // The scroll is given the width too, not only the column inside it.
            //
            // Without it the host's paragraphs laid out wider than the card and
            // the overflow was cut, mid-word, with the rest of the sentence
            // continuing on the next line: readable enough to look deliberate
            // and wrong enough to lose a word every line. The markdown renderer
            // never sets `.wrap` on its paragraphs, so the width it is handed is
            // the only thing deciding where a line ends.
            if (m.home_len > 0) ui.scroll(.{ .width = place_info_home_width, .height = placeHomeHeight(placeHome(ui, m)) }, .{
                ui.column(.{ .width = place_info_home_width, .gap = 0 }, .{
                    // With its links live. Passing no options renders them
                    // styled and inert, which is worse than not styling them:
                    // the reader is shown something that looks pressable and
                    // does nothing. They go through `open_url` like every other
                    // link in the app, so the same host checks apply to a
                    // stranger's welcome as to a stranger's note.
                    canvas.markdown.Markdown(Msg).view(ui, placeHome(ui, m), .{ .on_link = AppUi.linkMsg(.open_url) }),
                }),
            }) else ui.spacer(0),
            vgap(ui, 14),
            // Asking, then the answer. The warning is the whole footer while it
            // is up: a confirmation sharing a row with other controls is a
            // confirmation nobody reads.
            if (leaving) ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Leave this place? It comes off your rail and the notes it was holding are forgotten. The link still works, so you can walk back in.", .scale = join_sub_scale }},
            ) else ui.spacer(0),
            if (leaving) vgap(ui, 12) else ui.spacer(0),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                if (leaving)
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.place_leave_cancel }, "Cancel")
                else
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.close_place_info }, "Close"),
                ui.spacer(1),
                // Nothing to leave while visiting: a visit is not kept, so there
                // is no list to come off. Home closes the room either way.
                if (!places.g_place_kept)
                    ui.spacer(0)
                else if (leaving)
                    ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.place_leave }, "Leave")
                else
                    ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.place_leave_request }, "Leave"),
            }),
        })),
    }));
}

/// One labelled fact about a place: a quiet name, then the value in mono.
fn placeInfoRow(ui: *AppUi, label: []const u8, value: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(
            .{ .width = 54, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = label, .scale = mono_meta_scale }},
        ),
        ui.paragraph(
            .{ .width = place_info_card_width - 40 - 54, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = value, .monospace = true, .scale = mono_meta_scale }},
        ),
    });
}

/// The header of a room, which is the scope line while you are in one.
///
/// The place's name is the title, the feed it is reading is the meta on the
/// right where the follow feed puts its count of voices, and the verb is one
/// button. The host's own text and the note about privacy are shown only while
/// VISITING: they are the pitch, and a pitch that stays on screen after the
/// answer is a banner in the way of the thing it was selling.
fn placeHeader(ui: *AppUi, model: *const Model, m: *const Place) AppUi.Node {
    const p = theme.palette;
    const visiting = !places.g_place_kept;
    const menu_open = model.menu == .place_feed;
    const feed = currentPlaceFeed(m);
    const feed_name = if (feed) |f| (if (f.name_len > 0) f.name() else "") else "";
    return ui.row(.{ .main = .center }, .{ui.column(.{ .width = feed_column_width, .gap = 0 }, .{
        vgap(ui, 11),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = elide(ui, if (m.name_len > 0) m.name() else "A place", header_name_cap), .weight = .bold, .scale = scope_title_scale }},
            ),
            hgap(ui, 8),
            // What THIS place's socket is doing, which the status bar cannot
            // say: it counts the pool, and this relay is deliberately not in
            // it. Silent once connected, because a working connection is not
            // news.
            switch (placeLink()) {
                .connecting => ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint } },
                    &.{.{ .text = "connecting", .monospace = true, .scale = mono_meta_scale }},
                ),
                .unreachable_relay => ui.paragraph(
                    .{ .style = .{ .foreground = p.status_warning } },
                    &.{.{ .text = "cannot reach this place", .monospace = true, .scale = mono_meta_scale }},
                ),
                else => ui.spacer(0),
            },
            ui.spacer(1),
            // One feed is a LABEL; several is a switcher. A chevron beside a
            // name that goes nowhere is a promise the room cannot keep, so it
            // appears only when there is somewhere to go.
            if (feed_name.len == 0)
                ui.spacer(0)
            else if (m.feeds_len > 1)
                ui.stack(.{}, .{
                    pressRow(ui, .{
                        .cross = .center,
                        .gap = 5,
                        .on_press = Msg{ .toggle_menu = .place_feed },
                        .style = .{ .quiet_hover = true },
                        .semantics = .{ .role = .button, .label = "Choose feed", .focusable = true },
                    }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_faint_alt } },
                            &.{.{ .text = elide(ui, feed_name, header_feed_cap), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_faint_alt } }, "chevron-down"),
                    }),
                    if (menu_open) placeFeedMenu(ui, m) else ui.spacer(0),
                })
            else
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = elide(ui, feed_name, header_feed_cap), .monospace = true, .scale = mono_meta_scale }},
                ),
            if (feed_name.len > 0) hgap(ui, 10) else ui.spacer(0),
            // One control, whatever state you are in: what this place is, who
            // hosts it, where it reads from, and the way out. Leave used to sit
            // right here, a few pixels from Enter, and one press did it.
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.open_place_info }, "Info"),
            // Entering is the only verb the header keeps, because it is the one
            // the reader came for and it should cost one press.
            if (visiting) hgap(ui, 4) else ui.spacer(0),
            if (visiting)
                ui.button(.{ .size = .sm, .variant = .primary, .on_press = Msg.place_enter }, "Enter")
            else
                ui.spacer(0),
            hgap(ui, chrome_inset),
        }),
        if (visiting) vgap(ui, 6) else ui.spacer(0),
        if (visiting) ui.row(.{ .cross = .start, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.paragraph(
                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_faint } },
                &.{.{ .text = "Just visiting. Entering keeps this place on your rail, and nobody else can see which places you have entered.", .scale = mono_hint_scale }},
            ),
            hgap(ui, chrome_inset),
        }) else ui.spacer(0),
        vgap(ui, 9),
        ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    })});
}

fn scopeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // The scope name and the pack's size, on one line with the redesign's 11/16/9
    // insets. The label and the meta sit at opposite ends, so they are separate
    // runs rather than the single paragraph they shared when they were adjacent.
    //
    // No action lives here any more. Compose is the rail's bright tile, and a
    // guest reaches the join sheet from the banner or the rail's seat, so the
    // scope line is what it says it is: a label.
    // Centred WITHOUT grow: a row that is a child of a column grows on the
    // column's axis, so `.grow` here would stretch the header down the window and
    // shove the feed with it. A row already stretches across, which is all the
    // centring needs.
    return ui.row(.{ .main = .center }, .{ui.column(.{ .width = feed_column_width, .gap = 0 }, .{
        vgap(ui, 11),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            // The name AND its chevron are the trigger, so the menu opens under
            // the word it names rather than off a 11px glyph.
            ui.stack(.{}, .{
                pressRow(ui, .{
                    .cross = .center,
                    .gap = 7,
                    .on_press = Msg{ .toggle_menu = .scope },
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Choose feed", .focusable = true },
                }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_primary } },
                        &.{.{ .text = model.scope_name(), .weight = .bold, .scale = scope_title_scale }},
                    ),
                    ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
                }),
                if (model.menu == .scope) scopeMenu(ui, model.scope_name()) else ui.spacer(0),
            }),
            ui.spacer(1),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint_alt } },
                &.{.{ .text = model.scope_voices(ui.arena), .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, chrome_inset),
        }),
        vgap(ui, 9),
        ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    })});
}

/// The status bar: the caught-up line on the left (there is no spinner, the feed
/// renders from disk), relay health on the right after an online dot.
fn statusBar(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        // Four zones, every one pressable, and colour only where something needs
        // the reader. The chip row's own inset is 8, and the chips space at 4.
        ui.row(.{ .height = 30, .cross = .center, .gap = 0 }, .{
            hgap(ui, 8),
            // Feed state. Pressing it brings the newest note back to the top.
            statusChip(ui, .{
                .press = .jump_to_newest,
                .label = model.caught_up(ui.arena),
                .semantics = "Refresh the feed",
            }),
            ui.spacer(1),
            outboxZone(ui, model),
            relayZone(ui, model),
            hgap(ui, 4),
            signerZone(ui, model),
            hgap(ui, 8),
        }),
    });
}

/// The scope menu. One entry today, and it is the current one, so this exists to
/// say what the chevron means rather than to offer a choice: the reader learns
/// where scopes live before there is a second one to pick.
fn scopeMenu(ui: *AppUi, scope: []const u8) AppUi.Node {
    // One feed is a LABEL, several is a switcher: the same rule the place header
    // follows. Until the reader has followed somebody there is only the pack,
    // and a menu offering a feed with nobody in it is a promise Home cannot
    // keep.
    if (!homeScopeSwitchable()) {
        const rows = ui.arena.alloc(AppUi.Node, 2) catch return ui.spacer(0);
        rows[0] = menuRow(ui, scope, "check", null, .close_menu);
        // Why there is nothing to choose, and what would change that, so the
        // menu is not a chevron that opens onto the word already on screen. One
        // line, because a wrapped paragraph is not counted in the surface's
        // height and the second line would hang out of the bottom of it.
        rows[1] = ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 9),
            vgap(ui, 25),
            ui.paragraph(
                .{ .style = .{ .foreground = theme.palette.text_label } },
                &.{.{ .text = "Follow someone to add your Following feed.", .scale = mono_hint_scale }},
            ),
        });
        return menuSurfacePlaced(ui, 280, .below, .start, rows);
    }
    const rows = ui.arena.alloc(AppUi.Node, 2) catch return ui.spacer(0);
    const on_pack = homeReadsPack();
    // The pack first, because it is where a new key starts and the row they are
    // looking for is the one they are leaving.
    rows[0] = menuRow(
        ui,
        "Starter pack",
        if (on_pack) "check" else null,
        "hand-picked",
        Msg{ .choose_home_scope = 0 },
    );
    rows[1] = menuRow(
        ui,
        "Following",
        if (on_pack) null else "check",
        if (followTotalOwned() == 1) "1 account" else ui.fmt("{d} accounts", .{followTotalOwned()}),
        Msg{ .choose_home_scope = 1 },
    );
    // The scope line sits at the top of the window, so its menu drops down.
    return menuSurfacePlaced(ui, 240, .below, .start, rows);
}

/// The place's feeds, with the one being read checked.
///
/// Hallway communities routinely list several (its own default document has
/// five), and a room that showed one was not a smaller feature, it was most of
/// the community missing. The menu is the scope menu's shape on purpose: this
/// IS the scope line while you are in a place, so choosing a feed should look
/// like choosing a feed.
fn placeFeedMenu(ui: *AppUi, m: *const Place) AppUi.Node {
    const n = m.feeds_len;
    const rows = ui.arena.alloc(AppUi.Node, n) catch return ui.spacer(0);
    const open_index = @min(places.g_place_feed, if (n == 0) 0 else n - 1);
    for (rows, 0..) |*row, i| {
        const f = &m.feeds[i];
        // A feed with no name of its own is its relay's host, the same
        // substitution the header and the parser already make.
        const label = if (f.name_len > 0) f.name() else relayHost(f.relay());
        const glyph: ?[]const u8 = if (i == open_index) "check" else null;
        row.* = menuRow(ui, label, glyph, null, Msg{ .place_feed = @intCast(i) });
    }
    return menuSurfacePlaced(ui, 220, .below, .start, rows);
}

/// A scope name as it reads mid-sentence.
///
/// Only the app's OWN two names are lowered. It used to return "starter pack"
/// for anything that was not "Following", which was safe while those were the
/// only two scopes there were, and became a plain lie the moment a place could
/// be one: the status bar said "caught up, starter pack" under a header naming
/// somebody else's room. A place's feed name is a stranger's proper noun and is
/// left exactly as they wrote it.
fn lowerScope(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "Following")) return "following";
    if (std.mem.eql(u8, scope, "Starter pack")) return "starter pack";
    return scope;
}

pub fn lowerScopeForTest(scope: []const u8) []const u8 {
    return lowerScope(scope);
}

/// The web gateway a note is shared through: the community's when the place you
/// are reading in names one, and njump otherwise.
///
/// njump is not a fallback here so much as the app's own answer, and a place
/// that states nothing is not asking for a different one.
fn shareBase() []const u8 {
    const m = activePlace() orelse return default_share_base;
    if (m.share_len == 0) return default_share_base;
    return m.share();
}

const default_share_base = "https://njump.me/";

/// What a note offers beyond its verbs: where it is, what it says, and what to
/// do about whoever wrote it. Reached by right-clicking anywhere on the row.
///
/// This is the only list. There used to be a second one behind an ellipsis in
/// the verb row, carrying the same actions, which meant two lists to keep in
/// step and a reader finding different things depending on which way they
/// reached. The runtime presents these as the platform's own menu where there is
/// one, and as an anchored surface where there is not.
/// Every row this menu can carry, so the count is stated once instead of being
/// the sum of the branches below.
///
/// It was 7, and eight rows could be written. In the feed (`in_thread` false)
/// inside a place declaring a handler for kind 1, the tally runs: open thread,
/// copy address, quote, copy text, open on the web, open in the handler,
/// separator, follow. The eighth landed at index 7 of a seven-element
/// allocation and the function then returned `items[0..8]` from it.
///
/// One row was bounds-checked, the handler row, and the two written after it
/// were not, so the guard sat directly above the overrun it did not prevent.
/// That is the actual lesson and it is why `push` below exists: a rule applied
/// at one call site is not a rule. Debug catches this as a panic; ReleaseFast,
/// which is what ships, has no bounds check and writes past the allocation.
const note_context_capacity = 10;

fn noteContextItems(ui: *AppUi, note: *const Note, in_thread: bool) []const AppUi.ContextMenuItem {
    const items = ui.arena.alloc(AppUi.ContextMenuItem, note_context_capacity) catch return &.{};
    var n: usize = 0;
    // The only way a row is written. Adding one is adding a `push`, and a row
    // too many is a row dropped rather than memory scribbled on.
    const push = struct {
        fn f(dst: []AppUi.ContextMenuItem, at: *usize, item: AppUi.ContextMenuItem) void {
            if (at.* >= dst.len) return;
            dst[at.*] = item;
            at.* += 1;
        }
    }.f;

    if (!in_thread) push(items, &n, .{ .label = "Open thread", .msg = Msg{ .open_thread = note.id } });
    push(items, &n, .{ .label = "Copy note address", .msg = Msg{ .copy_nevent = note.id } });
    push(items, &n, .{ .label = "Quote", .msg = Msg{ .quote_note = note.id } });
    push(items, &n, .{ .label = "Copy text", .msg = Msg{ .copy_note_text = note.id } });
    push(items, &n, .{ .label = ui.fmt("Open on {s}", .{shareHost(shareBase())}), .msg = Msg{ .open_web = note.id } });
    // And where THIS community reads its notes, when it says. Beside the app's
    // own row rather than instead of it: a place naming a handler is telling
    // the reader where it lives, not taking njump away from them.
    if (activePlace()) |place| {
        if (place.handlerFor(1)) |h| {
            push(items, &n, .{ .label = ui.fmt("Open in {s}", .{h.name()}), .msg = Msg{ .open_place_handler = note.id } });
        }
    }
    push(items, &n, .{ .separator = true });
    push(items, &n, bookmarkContextItem(note));
    push(items, &n, privateBookmarkContextItem(note));
    if (isMine(note.pubkey)) {
        push(items, &n, .{ .label = "Delete", .msg = Msg{ .delete_note_request = note.id } });
    }
    push(items, &n, followContextItem(note.pubkey));
    return items[0..n];
}

/// The bookmark row, in whatever state it is honestly in.
///
/// Disabled with the reason on it rather than silently dead, the way Follow is.
/// A reader whose own list has not arrived yet is looking at a button this app
/// must not press, and saying so is the point: pressing it would publish a list
/// of one note over everything they had saved.
fn bookmarkContextItem(note: *const Note) AppUi.ContextMenuItem {
    if (activePubkey() == null) return .{ .label = "Bookmark", .enabled = false };
    if (bookmarkBlockedReason()) |reason| return blockedListItem(reason);
    if (isBookmarked(note.event_id)) {
        return .{ .label = "Remove bookmark", .msg = Msg{ .toggle_bookmark = note.id } };
    }
    return .{ .label = "Bookmark", .msg = Msg{ .toggle_bookmark = note.id } };
}

/// The private-bookmark row.
///
/// Only offered for ADDING. Removing one is the same press as removing a public
/// one: `toggle_bookmark` looks at where the entry actually is, so a reader is
/// never asked to remember which half they put it in.
///
/// Absent once the note is already bookmarked either way, because "bookmark
/// privately" on something already saved is a question about moving it between
/// halves, and that is a different feature.
fn privateBookmarkContextItem(note: *const Note) AppUi.ContextMenuItem {
    if (activePubkey() == null) return .{ .label = "Bookmark privately", .enabled = false };
    if (bookmarkBlockedReason() != null) return .{ .label = "Bookmark privately", .enabled = false };
    if (isBookmarked(note.event_id)) return .{ .label = "Bookmark privately", .enabled = false };
    return .{ .label = "Bookmark privately", .msg = Msg{ .bookmark_privately = note.id } };
}

/// Whether this account wrote it. Absent rather than disabled is the right
/// treatment for Delete on somebody else's note: a greyed row offers a thing
/// that is not on offer, where a greyed Follow explains a state the reader is
/// actually in.
fn isMine(author: [32]u8) bool {
    const me = activePubkey() orelse return false;
    return std.mem.eql(u8, &me, &author);
}

/// A menu row for a list that cannot be written yet. While Plaza is still
/// reading it is a statement; once the wait ran out the same row is the way to
/// ask the relays again, so the reader is never left with a dead row.
fn blockedListItem(reason: []const u8) AppUi.ContextMenuItem {
    if (ownListsRead() == .incomplete) return .{ .label = reason, .msg = Msg.retry_own_lists };
    return .{ .label = reason, .enabled = false };
}

/// The follow entry for a right-click, in whatever state it is honestly in.
///
/// Disabled rather than absent where it cannot act, so the reason is visible
/// instead of the action silently missing. Not "Follow", greyed: the app is
/// still looking for a list it must not write over, and saying so is the point.
/// A silently dead Follow is what every client that got this safety right got
/// wrong.
fn followContextItem(author: [32]u8) AppUi.ContextMenuItem {
    const me = activePubkey();
    if (me) |pk| {
        if (std.mem.eql(u8, &pk, &author)) return .{ .label = "This is you", .enabled = false };
    } else return .{ .label = "Follow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 0 } } };
    if (followBlockedReason()) |reason| return blockedListItem(reason);
    if (isFollowedByMe(author)) return .{ .label = "Unfollow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 2 } } };
    return .{ .label = "Follow", .msg = Msg{ .follow_author = .{ .who = author, .direction = 1 } } };
}

/// A rule between groups of menu items.
fn menuSeparatorRow(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 4),
        ui.el(.panel, .{ .height = 1, .padding = 0.01, .style = .{ .background = p.divider_card, .radius = 0, .stroke_width = 0 } }, .{}),
        vgap(ui, 4),
    });
}

/// The chrome's floating surface: a menu anchored to the trigger it hangs off.
///
/// Anchoring makes the surface leave its parent's flow entirely: it takes no
/// space in the row, paints in a late window-level pass above everything, and
/// escapes every ancestor clip, which is what lets a 30px status bar open a
/// 340px panel. It opens ABOVE, since the bar sits on the floor of the window,
/// and the runtime flips it if there is no room.
///
/// `on_dismiss` is what makes Escape and a press outside close it, so the model
/// never needs to hear about the click that landed elsewhere.
fn menuSurface(ui: *AppUi, width: f32, children: []const AppUi.Node) AppUi.Node {
    // A status-bar menu hangs off the right end of its chip, above the bar.
    return menuSurfacePlaced(ui, width, .above, .end, children);
}

/// The same surface with its placement stated, for a trigger that is not on the
/// floor of the window.
fn menuSurfacePlaced(ui: *AppUi, width: f32, placement: canvas.WidgetAnchorPlacement, alignment: canvas.WidgetAnchorAlignment, children: []const AppUi.Node) AppUi.Node {
    return menuSurfacePlacedDismissing(ui, width, placement, alignment, Msg.close_menu, children);
}

/// The same surface, told what to send when the reader clicks away. A menu whose
/// dismiss clears somebody else's state stays open and flickers back.
fn menuSurfacePlacedDismissing(ui: *AppUi, width: f32, placement: canvas.WidgetAnchorPlacement, alignment: canvas.WidgetAnchorAlignment, dismiss: Msg, children: []const AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dropdown_menu, .{
        .width = width,
        .anchor = placement,
        .anchor_alignment = alignment,
        .anchor_offset = 6,
        .padding = 5,
        .on_dismiss = dismiss,
        .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 9, .stroke_width = 1 },
    }, .{
        ui.column(.{ .gap = 0 }, .{children}),
    });
}

/// One row in a chrome menu: a label, an optional glyph and an optional trailing
/// hint, at the redesign's 6 by 9 padding.
fn menuRow(ui: *AppUi, label: []const u8, glyph: ?[]const u8, hint: ?[]const u8, press: ?Msg) AppUi.Node {
    const p = theme.palette;
    // A plain row, deliberately: the `menu_item` kind is what the renderer would
    // wash on hover, but it lays its children out and then draws none of them
    // (the rows measured 330x32 and painted nothing at all). So a menu row has
    // no hover state until that is understood; the design specifies a SELECTED
    // row surface, which is a different state and is drawn.
    return pressRow(ui, .{
        .cross = .center,
        .gap = 0,
        .on_press = press,
        // Some rows in this menu are statements, not choices: "This is you", and
        // the line explaining why following is not offered yet. Those carry no
        // press, so they are not buttons and must not say they are.
        .semantics = .{
            .role = if (press != null) .button else .none,
            .label = label,
            .focusable = press != null,
        },
    }, .{
        hgap(ui, 9),
        vgap(ui, 25),
        if (glyph) |name| ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_secondary } }, name) else ui.spacer(0),
        if (glyph != null) hgap(ui, 9) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = p.text_body } }, &.{.{ .text = label, .scale = menu_scale }}),
        ui.spacer(1),
        if (hint) |text|
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = text, .monospace = true, .scale = mono_hint_scale }})
        else
            ui.spacer(0),
        hgap(ui, 9),
    });
}

/// A rule between groups of menu rows.
fn menuSeparator(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 4),
        ui.row(.{ .gap = 0 }, .{ hgap(ui, 7), ui.separator(.{ .grow = 1, .style = .{ .foreground = p.border_menu, .background = p.border_menu } }), hgap(ui, 7) }),
        vgap(ui, 4),
    });
}

/// The relay popover: every relay in the pool, what it is doing, and how fast it
/// answers, then the two things a reader can do about it.
fn relayPopover(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const slots = relaySlots();
    const rows = ui.arena.alloc(AppUi.Node, slots + 4) catch return ui.spacer(0);
    // The header says what the list means, so nobody reads it as a picker.
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 24),
        ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Relays", .weight = .medium, .scale = menu_scale }}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "reads & writes route automatically", .monospace = true, .scale = mono_meta_scale }}),
        ui.spacer(1),
        hgap(ui, 9),
    });
    // Compacted, NEVER indexed by slot: a dormant slot in the middle would
    // otherwise leave a row nobody wrote, and the arena hands out uninitialised
    // memory that the widget walker would then follow.
    var n: usize = 1;
    for (0..slots) |i| {
        const entry = relayAt(i) orelse continue;
        // Every relay the reader has, marked with what it is for. Hiding the
        // read-only ones would make this list disagree with both the chip
        // counting them and the Settings card listing them.
        rows[n] = relayRow(ui, entry.url(), i, relayBadgeText(entry), model);
        n += 1;
    }
    rows[n] = menuSeparator(ui);
    rows[n + 1] = menuRow(ui, if (model.relays_paused) "Resume Relays" else "Pause Relays", null, null, .toggle_relays_paused);
    rows[n + 2] = menuRow(ui, "Relay Settings…", null, "Cmd+,", .open_settings);
    return menuSurface(ui, 340, rows[0 .. n + 3]);
}

/// One relay in the popover: its state as a dot, its host, what it is for, and
/// how long it took to answer.
fn relayRow(ui: *AppUi, url: []const u8, index: usize, badge: []const u8, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const state: Conn = @enumFromInt(relay_conn.g_relay_status[index].load(.monotonic));
    // A relay leaves within a wake, so during a pause some rows are still
    // genuinely connected. Each row reports ITSELF: claiming the whole list is
    // paused while notes are still arriving on it is the dishonesty this is for.
    // Holding a socket, whichever way. The row still reads as a working relay
    // (its round trip is real, its badge means something), and only the dot and
    // the word say that the last evidence of life is a minute old.
    const connected = connHolds(state);
    const paused = model.relays_paused and !connected;
    const dot = if (paused)
        p.text_faint_alt
    else if (state == .connected)
        p.status_success
    else if (state == .connecting or state == .quiet)
        p.status_warning
    else
        p.status_offline;
    // The host alone: the scheme is the same on every row and carries no news.
    const host = if (std.mem.startsWith(u8, url, "wss://")) url["wss://".len..] else url;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 21),
        ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = dot, .radius = 3, .stroke_width = 0 } }, .{}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = if (connected) p.text_body else p.text_muted_alt } }, &.{.{ .text = host, .monospace = true, .scale = mono_row_scale }}),
        ui.spacer(1),
        // What the relay is for is true whether or not it is answering, so the
        // badge stays put when it drops. A row that loses its marker while
        // offline would read as a relay whose purpose changed.
        relayBadge(ui, badge),
        hgap(ui, 8),
        // A connected relay reports its round trip; one that is still dialling or
        // has dropped says so in words instead of showing a stale number.
        ui.paragraph(
            .{ .style = .{ .foreground = if (connected) p.text_muted_alt else p.status_warning_text } },
            &.{.{
                .text = if (paused)
                    "paused"
                else if (state == .quiet)
                    "quiet"
                else if (connected)
                    (if (relayRttMs(index)) |ms| ui.fmt("{d}ms", .{ms}) else "…")
                else if (state == .connecting)
                    "connecting"
                else
                    "offline",
                .monospace = true,
                .scale = mono_meta_scale,
            }},
        ),
        hgap(ui, 9),
    });
}

/// What a relay is for, in NIP-65's own two letters.
fn relayBadgeText(e: *const RelayEntry) []const u8 {
    if (e.read and e.write) return "R·W";
    if (e.read) return "R";
    if (e.write) return "W";
    // A relay that is neither is not reachable in the UI (the badge cycles
    // through three live states), but a list read from disk or from a
    // kind:10002 with an unknown marker can land here. Saying so beats
    // claiming a direction it does not have.
    return "off";
}

/// The R·W chip on a relay row: what the relay is used for.
fn relayBadge(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_menu, .border = p.border_dashed, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = text, .monospace = true, .scale = mono_badge_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// The signed-in account's display name, or its npub until a kind:0 arrives.
fn accountName() []const u8 {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| {
            if (profile.name_len > 0) return profile.name();
        }
    }
    return npubShort();
}

/// Whether a kind:0 name is known, so the npub is worth showing beneath it.
fn accountHasName() bool {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| return profile.name_len > 0;
    }
    return false;
}

fn npubShort() []const u8 {
    return keyholder.g_identity_npub_buf[0..keyholder.g_identity_npub_len];
}

/// The account menu: who you are, and the two things to do about it. No mock
/// draws this, so it is the menu recipe with the identity row on top; flagged in
/// the PR for review.
fn accountMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    // Both conditions are read ONCE, here, and the allocation is counted from
    // the same two booleans that gate the writes below.
    //
    // Written as a bare number this was correct three times and wrong once. It
    // was 5, shrank to 5-1 when a row was removed (right, at the time), and then
    // "Bookmarks" was added back without it moving, so the ordinary signed-in
    // menu wrote "Settings..." one node past the end of its own allocation. In
    // Debug that is a panic; the shipping build is ReleaseFast and has no bounds
    // check, so it was a silent write into the arena.
    //
    // A count that is a separate number from the writes it bounds only agrees
    // with them by coincidence. This one cannot drift: another conditional row
    // means another boolean and another term, in the same expression.
    const show_notary = openNotaryAvailable();
    const show_bookmarks = activePubkey() != null;
    const show_profile_address = activePubkey() != null;
    const row_count: usize = 4 + @as(usize, @intFromBool(show_notary)) + @as(usize, @intFromBool(show_bookmarks)) +
        @as(usize, @intFromBool(show_profile_address));
    const rows = ui.arena.alloc(AppUi.Node, row_count) catch return ui.spacer(0);
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 34),
        youAvatar(ui),
        hgap(ui, 9),
        ui.column(.{ .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = accountName(), .weight = .medium, .scale = menu_scale }}),
            // The npub only when it is not already the name above it: an account
            // with no kind:0 yet would otherwise read its own key twice.
            if (accountHasName())
                ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = npubShort(), .monospace = true, .scale = mono_meta_scale }})
            else
                ui.spacer(0),
        }),
        ui.spacer(1),
        hgap(ui, 9),
    });
    rows[1] = menuSeparator(ui);
    var n: usize = 2;
    // The chip this menu hangs off says "Notary ready", so the way to Notary
    // belongs here as well as in Settings: this is where a reader looks when
    // they are wondering about their signer, because it is the thing that just
    // told them about it.
    if (show_notary) {
        rows[n] = menuRow(ui, "Open Notary", null, null, .open_notary_window);
        n += 1;
    }
    // Where a bookmark can be found again, which is the half of the feature that
    // makes the other half worth having. Signed-in only: a guest cannot have a
    // list, and a row that opens an empty screen is a worse answer than no row.
    if (show_bookmarks) {
        rows[n] = menuRow(ui, ui.fmt("Bookmarks ({d})", .{bookmarkCount()}), null, null, .open_bookmarks);
        n += 1;
    }
    // The account's address with the relays it publishes to in it. Signed-in
    // only: a guest has no account to address. Settings keeps the bare npub.
    if (show_profile_address) {
        rows[n] = menuRow(ui, "Copy profile address", null, null, .copy_nprofile);
        n += 1;
    }
    // No glyph. "Open Notary" carries none either, and one icon among two reads
    // as a mistake rather than as emphasis.
    //
    // No "Sign out" here. It only ever opened Settings with the confirmation
    // showing, so it was a second door to a room this menu already has a door
    // to, and the one thing on a status menu that could end a session is a
    // strange thing to keep a press away from the relay count.
    // Guests too, deliberately. Opening an address is reading, and reading
    // needs no key: a link somebody sent is one of the first things a person
    // who has not signed in arrives with.
    rows[n] = menuRow(ui, "Search…", null, "Cmd+L", .open_address);
    n += 1;
    rows[n] = menuRow(ui, "Settings…", null, "Cmd+,", .open_settings);
    n += 1;
    return menuSurface(ui, 240, rows[0..n]);
}

/// The banner 11p draws when no relay is answering. It says what still works,
/// which is nearly everything: the store is the app, so reading continues, and a
/// note written now is queued rather than refused. A spinner would say the
/// opposite.
fn offlineBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (liveRelayCount() > 0) return ui.spacer(0);
    const queued = model.outbox_pending;
    // A pause is the reader's own doing, so it is not worded or coloured as a
    // fault, and it carries the way out.
    if (model.relays_paused) return pausedBanner(ui, queued);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_offline, .border = p.border_offline, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.status_warning } }, "alert"),
                            hgap(ui, 8),
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.status_warning_text } },
                                &.{.{ .text = offlineBannerText(ui, queued, relayCount() == 0), .scale = meta_scale }},
                            ),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The line saying a newer Plaza exists.
///
/// TOLD, not done: it names the version and gives one press to the release
/// page, where the notes and the downloads are. It does not download anything
/// and it does not replace the app, because an ad-hoc signed bundle installed
/// by a script is not something to swap out from under somebody.
///
/// The offline banner's shape, one tone quieter. That banner is about something
/// broken right now; this is news, and it can wait. It is also the only one of
/// the three strips a reader can put away.
fn updateBanner(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const version = pendingUpdateVersion();
    if (version.len == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{ .text = ui.fmt("Plaza {s} is out. You are on {s}.", .{ version, plaza_version }), .scale = meta_scale }},
                            ),
                            hgap(ui, 8),
                            // The verb, and it says where it goes rather than
                            // "Update": nothing here updates anything.
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.open_update,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "See what is new", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "See what is new", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.dismiss_update,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "Dismiss the update notice", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_muted } },
                                    &.{.{ .text = "Not now", .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The line asking whether a relay may know who the reader is.
///
/// Shown only for a relay that has refused something for want of AUTH, once per
/// relay: the answer is kept, so it does not come back on the next launch or the
/// next reconnect, and it can be changed from the relay's row. A relay that
/// sends a challenge and gates nothing never raises it. It blocks nothing. The feed on every other relay carries on while it stands, and
/// so does this relay's own socket; the subscriptions it refused wait for the
/// answer.
///
/// The update banner's shape, because that is the register this app already
/// uses for something worth saying that is not broken: a quiet panel, plain
/// words, and the two verbs as underlined text rather than as buttons.
fn relayAuthBanner(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const asking = authAskingSummary() orelse return ui.spacer(0);
    const index = asking.first;
    const e = relayAt(index) orelse return ui.spacer(0);
    const name = relayShortName(e.url());
    const more = asking.count - 1;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{
                                    .text = if (more == 0)
                                        ui.fmt("{s} asks you to identify yourself to it.", .{name})
                                    else if (more == 1)
                                        ui.fmt("{s} asks you to identify yourself to it. 1 more is waiting.", .{name})
                                    else
                                        ui.fmt("{s} asks you to identify yourself to it. {d} more are waiting.", .{ name, more }),
                                    .scale = meta_scale,
                                }},
                            ),
                            hgap(ui, 8),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg{ .auth_allow = @intCast(index) },
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = ui.fmt("Let {s} know who you are", .{name}), .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "Allow", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg{ .auth_deny = @intCast(index) },
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = ui.fmt("Do not identify yourself to {s}", .{name}), .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_muted } },
                                    &.{.{ .text = "Don't allow", .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// The strip shown while the reader has paused the relays. The update notice's
/// quieter tone, because nothing is broken, and one press to undo it.
fn pausedBanner(ui: *AppUi, queued: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_body } },
                                &.{.{ .text = pausedBannerText(ui, queued), .scale = meta_scale }},
                            ),
                            hgap(ui, 12),
                            pressRow(ui, .{
                                .cross = .center,
                                .gap = 0,
                                .on_press = Msg.toggle_relays_paused,
                                .style = .{ .quiet_hover = true },
                                .semantics = .{ .role = .button, .label = "Resume relays", .focusable = true },
                            }, .{
                                ui.paragraph(
                                    .{ .style = .{ .foreground = p.text_primary } },
                                    &.{.{ .text = "Resume", .weight = .medium, .underline = true, .scale = meta_scale }},
                                ),
                            }),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

fn pausedBannerText(ui: *AppUi, queued: usize) []const u8 {
    if (queued == 0) return "Relays are paused. Reading continues from this machine, and anything you write is kept until you resume.";
    return ui.fmt("Relays are paused. Reading continues from this machine, and {d} {s} waiting to go out until you resume.", .{ queued, if (queued == 1) "note is" else "notes are" });
}

pub fn pausedBannerTextForTest(arena: std.mem.Allocator, queued: usize) []const u8 {
    var ui = AppUi.init(arena);
    return pausedBannerText(&ui, queued);
}

/// What the banner says, which depends on whether anything is owed, and on
/// whether the pool is empty: "no relay is answering" is wrong about a list
/// with nobody in it, and sends the reader looking for a fault.
fn offlineBannerText(ui: *AppUi, queued: usize, none_set: bool) []const u8 {
    if (none_set) return "No relays are set up, so nothing can be fetched or sent. Add one in Settings.";
    if (queued == 0) return "No relay is answering. Reading continues from this machine; anything you write is kept until one does.";
    return ui.fmt("No relay is answering. Reading continues from this machine, and {d} {s} waiting to go out.", .{ queued, if (queued == 1) "note is" else "notes are" });
}

pub fn offlineBannerTextForTest(arena: std.mem.Allocator, queued: usize, none_set: bool) []const u8 {
    var ui = AppUi.init(arena);
    return offlineBannerText(&ui, queued, none_set);
}

/// What the app still owes the reader. Absent when nothing is queued, which is
/// most of the time: a zone that is always there teaches nothing, and an empty
/// popover under it would be worse.
///
/// Amber, because this is work in progress rather than a warning: a note on its
/// way is the ordinary case. The glyph takes the text's own hex, not the
/// brighter alert amber.
fn outboxZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (model.outbox_pending == 0 and model.outbox_stuck == 0 and !model.outbox_overflowed) return ui.spacer(0);
    const stuck = model.outbox_overflowed or (model.outbox_pending == 0 and model.outbox_stuck > 0);
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = 22,
            .cross = .center,
            .on_press = Msg{ .toggle_menu = .outbox },
            .style = .{ .radius = 6, .background = if (model.menu == .outbox) p.surface_chip else null },
            .semantics = .{ .role = .button, .label = "Notes on their way", .focusable = true },
        }, .{
            hgap(ui, 7),
            // A runtime choice of glyph, so `appIcon` rather than the
            // comptime-checked `icon`.
            ui.appIcon(.{ .width = 11, .height = 11, .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } }, if (stuck) "alert" else "arrow-up"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } },
                &.{.{ .text = model.outbox_label(ui.arena), .scale = status_scale }},
            ),
            hgap(ui, 7),
        }),
        if (model.menu == .outbox) outboxMenu(ui) else ui.spacer(0),
        hgap(ui, 4),
    });
}

/// One card per note on its way, newest first. No mock exists for this surface;
/// it is the smallest thing that answers the question the zone raises, which is
/// "which note, and how far did it get".
fn outboxMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    var entries: [outbox_cap]OutboxEntry = undefined;
    const n = outboxSnapshot(&entries);
    if (n == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, n) catch return ui.spacer(0);
    for (rows, entries[0..n]) |*row, e| {
        const title = switch (e.state()) {
            .queued => "Waiting for a relay",
            .sending => "Sending",
            .sent => "Sent",
            .stuck => "No relay took it",
        };
        row.* = ui.column(.{ .gap = 0 }, .{
            vgap(ui, 6),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 9),
                ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{
                    .background = switch (e.state()) {
                        .queued => p.status_offline,
                        .sending => p.status_warning_text,
                        .sent => p.status_success,
                        .stuck => p.status_offline,
                    },
                    .radius = 3,
                    .stroke_width = 0,
                } }, .{}),
                hgap(ui, 8),
                ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = title, .weight = .medium, .scale = menu_scale }}),
                ui.spacer(1),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = ui.fmt("{d}/{d} relays", .{ e.ackCount(), writeRelayCount() }), .monospace = true, .scale = mono_hint_scale }},
                ),
                hgap(ui, 9),
            }),
            vgap(ui, 6),
        });
    }
    return menuSurface(ui, 240, rows);
}

/// The relay zone: the pool's health, and the popover that explains it. The chip
/// is highlighted while the pool is healthy, because that is when the number is
/// worth reading at a glance; a degraded pool speaks through its dot instead.
fn relayZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const paused = model.relays_paused;
    // Both halves of the ratio come from the SAME sample. `model.live_relays`
    // and `model.relay_count` are read together once a second in `refresh`;
    // pairing that numerator with a live `relayCount()` reads "5/3 relays" for a
    // second after a removal, because the count drops the instant they press and
    // the live tally waits for the next tick.
    const total = model.relay_count;
    const live = @min(model.live_relays, total);
    // A paused pool that still has a socket open is PAUSING, not paused: a relay
    // leaves at its next message, and the bar refuses to claim otherwise.
    const settling = paused and live > 0;
    const dot = if (paused)
        p.text_faint_alt
    else if (live == 0)
        p.status_offline
    else if (!poolIsHealthyOf(live, total))
        p.status_warning
    else
        p.status_success;
    // No latency on the bar. A round-trip figure that swings with whichever
    // relay answered last is a number nobody acts on, and it sat where the
    // reader looks for whether the pool is up. The per-relay pings are still in
    // the card this chip opens, next to the relay each one belongs to, which is
    // the only place the number means anything.
    const label = if (settling)
        ui.fmt("pausing · {d}/{d} relays", .{ live, total })
    else if (paused)
        ui.fmt("paused · 0/{d} relays", .{total})
    else
        ui.fmt("{d}/{d} relays", .{ live, total });
    // And no plate. The dot already carries the pool's health, so the surface
    // behind it was a second voice saying the same thing, in the busiest corner
    // of the window.
    const plated = false;
    // The trigger and its floating surface are siblings in a stack: that is the
    // sanctioned shape, and the anchored surface takes no space in the row.
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = Msg{ .toggle_menu = .relays },
            .label = label,
            .semantics = "Relays",
            .dot = dot,
            .chevron = true,
            .highlighted = plated,
            .ink = if (plated) p.text_secondary else p.text_muted,
        }),
        if (model.menu == .relays) relayPopover(ui, model) else ui.spacer(0),
    });
}

/// The signer zone: whether Plaza can sign right now, and the account menu.
fn signerZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const guest = model.is_guest();
    // Name the signer that is actually in use, and say whether it can sign right
    // now. Claiming "Notary ready" for a local key or an unreachable bunker would
    // be a chip that lies about where the reader's key lives.
    const signer = signerStatus();
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = if (guest) .open_join else Msg{ .toggle_menu = .account },
            .label = if (guest) "Guest" else signer.label,
            .semantics = if (guest) "Join" else "Account",
            .glyph = if (guest) "plus" else signer.glyph,
            .glyph_color = if (guest) p.text_faint_alt else signer.color,
        }),
        if (model.menu == .account) accountMenu(ui) else ui.spacer(0),
    });
}

/// Whether the pool counts as healthy: MOST of it answering, not all of it. The
/// redesign's at-rest bar reads "4/5 relays" in green while its working bar reads
/// "3/5" in amber, so the line sits at four fifths. A relay pool always has a
/// straggler, and a bar that goes amber for one is a bar nobody reads.
pub fn poolIsHealthyForTest(live: usize) bool {
    return poolIsHealthy(live);
}

fn poolIsHealthy(live: usize) bool {
    return poolIsHealthyOf(live, relayCount());
}

/// The same line, against a total the caller already has, so a chip judges its
/// health on the pair of numbers it is about to print.
///
/// Stated as "one straggler is fine", which is what the rule above says it means,
/// rather than as four fifths. Those agree for a pool of five or more and part
/// company below it: at four relays, four fifths demands FOUR of four, so one
/// relay down turns the dot amber and leaves it there. That went unnoticed when
/// the bootstrap list dropped from five to four in this same change, and the
/// four-fifths test kept passing while asserting the opposite of its own name,
/// because the arithmetic had moved under it.
///
/// The second clause is not decoration. Without it a ONE relay pool with nothing
/// connected reads healthy, since `0 + 1 >= 1`.
fn poolIsHealthyOf(live: usize, total: usize) bool {
    if (total == 0) return false;
    return live + 1 >= total and live * 2 >= total;
}

/// What the status bar says about signing: which signer holds the key, and
/// whether it can be reached.
const SignerStatus = struct { label: []const u8, glyph: []const u8, color: canvas.Color };

/// Whether the thing that signs is actually able to sign right now. The chrome
/// carries this as a colour; the identity card needs it as a fact.
pub fn signerIsHealthy() bool {
    return switch (keyholder.g_signer_kind) {
        .helper => helperState() == .ready,
        .remote => !remote_signer.g_remote_sign_notice.load(.acquire),
    };
}

fn signerStatus() SignerStatus {
    const p = theme.palette;
    return switch (keyholder.g_signer_kind) {
        // Notary: a separate process, so its health is a real question.
        //
        // Not installed is its own answer, ahead of the state machine. A session
        // restored onto an install with no Notary in it signs back in before the
        // probe has even run, and "unreachable" would send that reader looking
        // for a daemon that has crashed or a port that is busy. Nothing is
        // coming up; the install is short a file.
        .helper => if (keyholderMissing())
            .{ .label = "Notary is not installed", .glyph = "notary", .color = p.status_warning }
        else switch (helperState()) {
            .ready => .{ .label = "Notary ready", .glyph = "notary", .color = p.status_success },
            // It HOLDS your key. Saying "has no key" here was the bug: it reads
            // as an empty keyholder waiting to be set up, when what it wants is
            // a passphrase.
            .locked => .{ .label = "Notary is locked", .glyph = "notary", .color = p.status_warning },
            .empty => .{ .label = "Notary has no key", .glyph = "notary", .color = p.status_warning },
            .unreachable_ => .{ .label = "Notary unreachable", .glyph = "notary", .color = p.text_faint_alt },
            .starting => .{ .label = "Notary starting", .glyph = "notary", .color = p.status_warning },
        },
        // A remote bunker: reachable is the whole question, and the remote path
        // already tracks a failed round trip.
        .remote => if (remote_signer.g_remote_sign_notice.load(.acquire))
            .{ .label = "Signer unreachable", .glyph = "notary", .color = p.status_warning }
        else
            .{ .label = "Signer connected", .glyph = "notary", .color = p.status_success },
    };
}

/// One status-bar zone: a quiet pressable chip, highlighted only when it is
/// carrying live state the reader should look at.
const StatusChip = struct {
    press: Msg,
    label: []const u8,
    semantics: []const u8,
    /// A leading dot, for the relay zone's health.
    dot: ?canvas.Color = null,
    /// A leading glyph, for the signer zone and the offline warning.
    glyph: ?[]const u8 = null,
    glyph_color: canvas.Color = theme.palette.text_muted,
    /// A trailing chevron, for a chip that opens a menu.
    chevron: bool = false,
    highlighted: bool = false,
    ink: canvas.Color = theme.palette.text_muted,
};

fn statusChip(ui: *AppUi, chip: StatusChip) AppUi.Node {
    const p = theme.palette;
    // Gap 0 and explicit steps: a `gap` would space around the absent parts too,
    // so a chip with no dot and no chevron would carry their spacing anyway.
    const body = ui.row(.{ .cross = .center, .gap = 0 }, .{
        if (chip.dot) |color|
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = color, .radius = 3, .stroke_width = 0 } }, .{})
        else
            ui.spacer(0),
        if (chip.dot != null) hgap(ui, 6) else ui.spacer(0),
        if (chip.glyph) |name|
            // `appIcon` takes a RUNTIME name and resolves built-ins first, then
            // the app table, so one call serves both vocabularies.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = chip.glyph_color } }, name)
        else
            ui.spacer(0),
        if (chip.glyph != null) hgap(ui, 6) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = chip.ink } }, &.{.{ .text = chip.label, .scale = status_scale }}),
        if (chip.chevron) hgap(ui, 6) else ui.spacer(0),
        if (chip.chevron)
            ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_muted } }, "chevron-up")
        else
            ui.spacer(0),
    });
    // A highlighted chip carries a plate, so it needs a surface that paints; a
    // quiet one is text on the bar.
    const inner = if (chip.highlighted)
        ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_chip, .radius = 6, .stroke_width = 0 } }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), vgap(ui, 22), body, hgap(ui, 8) }),
        })
    else
        ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), body, hgap(ui, 8) });
    return pressRow(ui, .{
        .cross = .center,
        .on_press = chip.press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = chip.semantics, .focusable = true },
    }, .{inner});
}

/// The ink identity takes: a handle, a mention, a link inside a note.
///
/// Violet outside a place, and the community's own colour inside one. This is
/// the half of a place's colour a reader actually notices. A feed is mostly
/// handles and links, so recolouring them is the difference between one tinted
/// button and a room that reads as somebody's. The rule the violet enforces is
/// not suspended by that, it is applied: colour here means identity, and a
/// place is an identity.
///
/// `on_dark` and not the fill colour, because this is TEXT on the near-black
/// window and Hallway's `primary` is a background value. See `theme.PlaceColor`.
fn identityInk() canvas.Color {
    const m = activePlace() orelse return theme.palette.accent_identity;
    const c = m.color orelse return theme.palette.accent_identity;
    return c.on_dark;
}

/// The fill under the room's bright verb, and the ink knocked out of it.
///
/// Porcelain outside a place. Inside one this is the community's colour, and
/// the ink is HALLWAY'S `primary-foreground` rather than Plaza's `on_accent`:
/// those agree on a dark fill and disagree loudly on a light one, and YELLOW is
/// a light one.
///
/// Only the verbs that belong to the ROOM take it: composing into this place,
/// replying in it. The name sheet's Done, the join ladder and the notification
/// unread dot stay porcelain: they are the app talking, not the community, and
/// the dot in particular means a STATE, which no room gets to repaint.
fn roomVerbFill() canvas.Color {
    const m = activePlace() orelse return theme.palette.accent;
    const c = m.color orelse return theme.palette.accent;
    return c.primary;
}

fn roomVerbInk() canvas.Color {
    const m = activePlace() orelse return theme.palette.on_accent;
    const c = m.color orelse return theme.palette.on_accent;
    return c.on_primary;
}

/// The warm avatar tint for an author, chosen deterministically from the
/// pubkey so a face keeps the same color across sessions. Neutral graphite is
/// the last entry and the natural fallback for an all-zero key.
pub fn avatarTint(pubkey: [32]u8) theme.palette.Tint {
    const key = @as(usize, pubkey[0]) +% pubkey[15] +% pubkey[31];
    return theme.palette.avatar_tints[key % theme.palette.avatar_tints.len];
}

/// The corner an avatar takes at this size: Hallway's `avatarStyleDefault`.
///
/// Half the size is a disc, which is Plaza's own shape and what every surface
/// outside a place keeps. A place asking for "square" gets a rounded square
/// rather than a hard corner, because the faces sit against 1px rules at 32px
/// and a true 0 radius reads as a rendering fault at that size.
///
/// Asked of the OPEN place rather than stored per note: the shape belongs to
/// the room being read, so walking out restores the disc without touching a
/// single note.
fn avatarRadius(size: f32) f32 {
    const m = activePlace() orelse return size / 2;
    return if (m.square_avatars) size * 0.18 else size / 2;
}

/// A chrome pill: the redesign's 26px-high button, filled for the primary verb
/// and outlined for the quiet one. The house button is a different shape (28 high
/// on its own scale), so the chrome states its own.
fn pillButton(ui: *AppUi, label: []const u8, press: Msg, filled: bool, on_surface: canvas.Color) AppUi.Node {
    const p = theme.palette;
    // The outlined variant paints the surface it sits on, not "nothing": a panel
    // with no stated background falls back to the house card fill, which would
    // draw a plate the redesign's ghost button does not have.
    const style: canvas.WidgetStyle = if (filled)
        .{ .background = p.accent, .radius = 7, .stroke_width = 0 }
    else
        .{ .background = on_surface, .border = p.border_control, .radius = 7, .stroke_width = 1 };
    const ink = if (filled) p.on_accent else p.text_secondary;
    // The shot sets the filled label at 600 and the ghost at 500; the bundled
    // family steps 400 / 500 / 700, so both land on medium.
    const weight: canvas.TextSpanWeight = .medium;
    // The fill and the outline live on a `.panel`: a row paints no background at
    // all (the renderer draws nothing for the layout kinds), which is why the
    // filled pill was reading as dark-on-dark text with no button under it.
    return pressRow(ui, .{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        ui.el(.panel, .{ .padding = 0.01, .style = style }, .{
            ui.row(.{ .height = 26, .cross = .center, .gap = 0 }, .{
                hgap(ui, 11),
                ui.paragraph(.{ .style = .{ .foreground = ink } }, &.{.{ .text = label, .weight = weight, .scale = meta_scale }}),
                hgap(ui, 11),
            }),
        }),
    });
}

/// A metadata run: the 12px register, in the ink the caller names.
fn metaText(ui: *AppUi, text: []const u8, color: canvas.Color) AppUi.Node {
    return ui.paragraph(.{ .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = meta_scale }});
}

/// The same, in a box it is not allowed to outgrow.
///
/// The width goes on the TEXT ELEMENT, not on an ancestor, and that distinction
/// is the whole fix. A definite width on the containing column does nothing: a
/// text leaf with no `wrap` measures as one line at its natural width whatever
/// its parents are, and `overflow = .ellipsis` cannot elide anything, because
/// an ellipsis needs a box to be too small for. I bounded the column, then the
/// column's parent, and the offending run measured exactly as wide both times.
/// Cuts `text` to at most `max` bytes and marks the cut with an ellipsis.
///
/// Because the engine has no max-width. `width` is a DEFINITE size: it bounds
/// the text, and it also makes the box exactly that wide whatever is in it. For
/// a leaf that owns its whole line that is precisely right. For one with a
/// neighbour it is wrong in a way that looks like a different bug: bounding a
/// profile's name that way put the verified check on the far side of the page,
/// and bounding the handle put a hand's width of nothing between it and the
/// npub. So where something sits beside the text, the string is shortened
/// instead and the box goes on hugging it.
///
/// Cuts on a UTF-8 boundary, so a name ending in an emoji or any non-Latin
/// script loses the character rather than being left as half of one.
fn elide(ui: *AppUi, text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return ui.fmt("{s}\u{2026}", .{text[0..end]});
}

fn metaTextIn(ui: *AppUi, text: []const u8, color: canvas.Color, width: f32) AppUi.Node {
    return ui.paragraph(.{ .width = width, .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = meta_scale }});
}

/// How much of a note's identity row belongs to the name and the handle.
///
/// The row is the identity block, a 6px gap, then the time. The time is the
/// app's own string, so it is the part that can be budgeted; the name and the
/// handle are a stranger's, so they get what is left and are held to it.
/// Sixty-four characters of display name and a hundred and twenty-eight of
/// NIP-05 both fit the buffers that receive them, which is to say both will
/// arrive eventually.
///
/// 148, and it has been wrong twice in opposite directions.
///
/// It was 124, set against "4h via Amethyst" while the real longest is
/// "11h via Damus Notedeck": a client name may be fourteen characters and an
/// age may be three. That string did not elide, it WRAPPED, onto a second line
/// the row had reserved no height for, so it painted over the handle beneath
/// and was clipped away again depending on what else was on screen. That was
/// the flicker somebody saw scrolling past it.
///
/// 136 stopped the wrap and was still too narrow: it was measured against
/// "11h" and "35m" is wider, so the same client name overflowed by eight
/// points. It did not show, because the box was definite and the engine elided
/// the tail. Now that the box hugs its text (see the paragraph that draws it),
/// an overflow has nowhere to hide, so this is measured against the widest AGE
/// as well as the longest NAME.
///
/// It cannot cover a name of fourteen wide glyphs; that would want two hundred
/// points and eat the column the name and handle live in. Such a name overflows
/// a little rather than eliding, which is the one thing this arrangement gives
/// up, and it is a `client` tag nobody ships against a row that still reads.
const time_column_width: f32 = 148;
const identity_text_width: f32 = picture_column_width - 6 - time_column_width;

/// How long a stranger's string may be where something sits BESIDE it.
///
/// Lengths, not widths, and that is the engine's doing rather than a
/// preference: `width` is definite, so it would fix the box at that size and
/// send the verified check, the npub and "follows you" off to the right of a
/// three-letter name. See `elide`.
///
/// Chosen against the column each one lives in and then measured: the sweep
/// renders these at the capacity of the buffers that hold them, so a budget
/// that is too generous fails rather than shipping.
const profile_name_max: usize = 28;
const profile_band_name_max: usize = 32;
const profile_handle_max: usize = 34;

/// A row that answers a press, built so the keyboard can use it.
///
/// A `row`, a `column` or a `data_row` with an `on_press` answers a click and
/// nothing else. The toolkit gives Tab a stop, a focus ring and a Return or
/// Space activation to its own controls and to `list_item`, and the layout kinds
/// get none of the three: Tab can land on one, nothing is drawn, and the key
/// does nothing. So every hand-built pressable is a `list_item`, which is the
/// toolkit's row-with-children, and this is the one place that says so. A row
/// with no press stays a plain row, because a statement is not a stop.
///
/// `list_item` insets its children by default, which a row never did, so the
/// padding is zeroed unless the caller states one. Its height floor is the
/// toolkit's row height; a caller whose row is shorter gives it a `height`.
fn pressRow(ui: *AppUi, options: AppUi.ElementOptions, children: anytype) AppUi.Node {
    if (options.on_press == null) return ui.row(options, children);
    var o = options;
    if (o.padding == null) o.padding = 0.01;
    return ui.el(.list_item, o, children);
}

/// A note's time, made the keyboard's way into the note's thread when nothing
/// else in the row is.
///
/// A row whose body wraps stays a `data_row` (see `pressRow`), so the row is the
/// pointer's target and cannot be a stop of its own. The Reply verb under the
/// note opens the same thread and is the stop. Where there is no Reply verb (a
/// nested reply never draws one, and a reader can take the verb away) the time
/// is, so no thread can be opened by the pointer alone. With `stop` false this
/// is the plain row it always was.
fn threadTime(ui: *AppUi, note: *const Note, stop: bool, options: AppUi.ElementOptions, children: anytype) AppUi.Node {
    var o = options;
    if (stop) {
        o.on_press = Msg{ .open_thread = note.id };
        o.style = .{ .radius = 4, .quiet_hover = true };
        o.semantics = .{ .role = .button, .label = "Open thread", .focusable = true };
    }
    return pressRow(ui, o, children);
}

/// Fixed empty space along ONE axis. `ui.spacer(n)` takes a GROW factor, not a
/// size, so it cannot express an inset; these are the sized counterparts, used
/// wherever the redesign asks for a step that a uniform `padding` or `gap` cannot
/// state (a row inset of 12 top, 16 sides and 14 bottom; a column whose steps are
/// 5, 8 and 10). One axis each, so a spacer in a row never claims height and one
/// in a column never claims width.
pub fn hgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .width = size }, .{});
}

pub fn vgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .height = size }, .{});
}

/// The author disc: 36px, the tint keyed off the pubkey, initials when no
/// picture has been registered. The size is the redesign's, and it is what the
/// identity block beside it is pinned to.
fn noteAvatar(ui: *AppUi, note: *const Note) AppUi.Node {
    // The face is the way to the person. An `avatar` is not a hit target, so the
    // press needs a box around it, and that box is sized to the disc EXACTLY:
    // the reply rail hangs on the disc's centre line, computed as
    // `thread_inset + avatar_size / 2`, so a wrapper even a pixel wider moves
    // the rail off the avatars it is supposed to connect.
    return ui.el(.list_item, .{
        .width = avatar_size,
        .height = avatar_size,
        .padding = 0.01,
        .on_press = Msg{ .open_person = note.pubkey },
        // The hit target follows the disc's own shape, or a square face wears a
        // circular hover wash.
        .style = .{ .radius = avatarRadius(avatar_size), .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
    }, .{
        avatarDisc(ui, note, avatar_size),
    });
}

/// The same disc at an explicit size, for the surfaces that draw a smaller or
/// larger one (a nested thread child, a quote pill, a profile header).
fn avatarDisc(ui: *AppUi, note: *const Note, size: f32) AppUi.Node {
    const tint = avatarTint(note.pubkey);
    return ui.avatar(.{
        .image = note.avatar_id(),
        .width = size,
        .height = size,
        // The radius is stated rather than left to the widget: `avatar` falls
        // back to a full pill only when the style names none, and the place's
        // `avatarStyleDefault` is exactly the case that wants to name one.
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1, .radius = avatarRadius(size) },
    }, note.initials());
}

/// The identity block: the name over the handle, in a box pinned to the avatar's
/// height so the two lines sit against the disc's top and bottom edges. The
/// second line carries the verified check only when the author's NIP-05 actually
/// resolves to their pubkey; without a handle at all the block is just the name,
/// and the box still holds its height so a row never changes shape.
///
/// The redesign insets the two lines by 1px top and bottom. Padding is uniform
/// on this engine, and a 1px horizontal inset would push the name off the body's
/// left edge, so the box takes no padding: the name sits 1px higher and the
/// handle 1px lower than the mock, and every text run stays on one rail.
fn identityBlock(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // DEFINITE, and definite on the LEAF as well as the box.
    //
    // This used to say `grow`, reasoning that the block would take the width
    // left after the timestamp and a long display name would ellipsize inside
    // it. That is not what `grow` does: it hands out SPARE space and never
    // takes any back, so a name wider than the row keeps its full width and
    // takes the handle, the time and the card's right edge with it. Sixty-four
    // characters of display name reached 354px past the window.
    return ui.column(.{ .height = avatar_size, .width = identity_text_width, .main = .space_between }, .{
        ui.paragraph(
            .{ .width = identity_text_width, .style = .{ .foreground = p.text_primary } },
            &.{.{ .text = note.author(), .weight = .medium, .scale = name_scale }},
        ),
        handleLine(ui, note),
    });
}

/// The identity block's second line: the verified check, then the handle. The
/// check appears only when the author's NIP-05 resolved back to their pubkey, so
/// a claimed identity never wears a mark it has not earned.
fn handleLine(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // Checked BEFORE the label: a profile in flight shows the bar, never a
    // placeholder handle that swaps a beat later.
    if (profileLoading(note.pubkey)) return ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
    const label = note.handleLabel(ui.arena);
    if (label.text.len == 0) return ui.spacer(0);
    // Bounded, and bounded by LESS when a check sits in front of it, so the two
    // together fit the block rather than the handle alone fitting it.
    const room = if (note.verified()) identity_text_width - 12 - 5 else identity_text_width;
    const handle = metaTextIn(ui, label.text, if (label.nip05) identityInk() else p.text_faint, room);
    // The check and its 5px gap exist only when there IS a check. A row gap is
    // charged for every flow child, so substituting a zero-width spacer for the
    // glyph would still indent the handle 5px past the name's rail.
    if (!note.verified()) return handle;
    return ui.row(.{ .gap = 5, .cross = .center }, .{
        ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.status_success } }, "check-circle"),
        handle,
    });
}

/// How wide one verb's slot is, and how big its glyph is.
///
/// A SLOT, not a gap, and that is the whole point. The verbs used to sit in a
/// row with a 30px gap and a count beside each glyph, so the width of every
/// count pushed everything after it along: the heart landed at a different x on
/// every note in the feed, and a column of notes read as a column of rows that
/// could not agree where anything went. A fixed slot per verb puts every glyph
/// in the same column down the whole feed, whatever the counts do inside it.
///
/// 64 holds the glyph, its gap and the widest count `formatCount` can produce
/// (`999.9k`) without the next slot moving.
const verb_slot_width: f32 = 64;
/// And how tall. The row used to be exactly as tall as its glyphs measured
/// (18.125), so the verbs sat hard against the rule above them and the row
/// below: a strip of icons rather than a row of controls. This is the same
/// height the chrome gives its own pressable rows.
pub const verb_slot_height: f32 = 30;
const verb_icon_size: f32 = 15;

/// The engagement row: reply, repost and like, in that fixed order, each an icon
/// and its crowd count (the count omitted at zero), then the note's zap total as
/// a plain figure.
///
/// It used to carry two more. A bookmark, which had nothing behind it and was
/// drawn quiet to say so, and an ellipsis that opened the note's menu. Both are
/// gone. The bookmark was a control that could only ever disappoint somebody who
/// pressed it, and the ellipsis offered exactly what a right-click on the row
/// already offers, so it was a second door to one room, taking up a slot and a
/// hit target to get there. The right-click menu is the door now
/// (`noteContextItems`), on every row and on the focal note.
///
/// Reply, repost and like work. The zap total is only a figure: Plaza cannot
/// send a zap yet, so it is drawn as text rather than as a control that
/// answers a press with nothing.
fn engagementRow(ui: *AppUi, note: *const Note) AppUi.Node {
    if (!verbRowShown(note)) return ui.spacer(0);
    return engagementRowAt(ui, note, true);
}

/// Whether a note's row (with its counts) draws anything: a verb, or a zap
/// total on its own. Turning the three verbs off while keeping zaps on is a
/// reader asking for the totals and nothing else, so the row stays for a note
/// that has one. The count table is only read in that case, which is rare: with
/// any verb on, the row is drawn anyway.
fn verbRowShown(note: *const Note) bool {
    if (anyVerbShown()) return true;
    return zapTotalSats(engagementFor(note.id), true) > 0;
}

/// A note's zap total in sats as the row draws it, or 0 when there is none to
/// draw: zaps taken away, the totals hidden, or a row told to leave its counts
/// off.
fn zapTotalSats(c: Counts, counts: bool) u64 {
    if (isTakenAway(.zaps) or !counts or countHidden(.zaps, .zap_totals)) return 0;
    return c.zap_msat / 1000;
}

/// Whether the verb row has anything left to draw.
///
/// Three verbs, each removable in Settings. The zap total is not one of them: it
/// is a figure that exists on some notes and not others, so counting it here
/// would keep an empty row, and the band of nothing above it, on every note
/// that has none.
fn anyVerbShown() bool {
    return !isTakenAway(.replies) or !isTakenAway(.reposts) or !isTakenAway(.reactions);
}

/// The same row, told whether to carry its counts. The focal note in a thread
/// does not: the stats line above it already states every one of them in words,
/// and a number said twice in two registers is the second one looking like a
/// control.
fn engagementRowAt(ui: *AppUi, note: *const Note, counts: bool) AppUi.Node {
    const p = theme.palette;
    const glyph = AppUi.ElementOptions{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = p.text_metric } };
    const c = engagementFor(note.id);
    return ui.row(.{ .gap = 0, .cross = .center }, .{
        // Reply opens the note's thread, where the pinned composer answers it.
        // It is also the keyboard's way into that thread, because the note row
        // around it is a pointer target only (see `threadTime`).
        if (isTakenAway(.replies)) ui.spacer(0) else verbSlot(ui, verbWithCount(ui, ui.appIcon(glyph, "reply"), if (counts and !countHidden(.replies, .reply_counts)) c.replies else 0, p.text_metric, .{
            .on_press = Msg{ .open_thread = note.id },
            .style = .{ .quiet_hover = true },
            .semantics = .{ .role = .button, .label = "Reply", .focusable = true },
        })),
        if (isTakenAway(.reposts)) ui.spacer(0) else verbSlot(ui, repostAction(ui, note, c, counts)),
        if (isTakenAway(.reactions)) ui.spacer(0) else verbSlot(ui, likeAction(ui, note, counts)),
        // Plaza cannot send a zap yet, so the total is a figure and not a verb:
        // no bolt, no hover, nothing to press. It is the summed sats (msat /
        // 1000), and nothing at all when there are none or the count is hidden.
        zapTotal(ui, zapTotalSats(c, counts)),
    });
}

/// What a note was zapped, as plain text in the verb row. Read-only on purpose:
/// it carries no press, no hover and no role, and draws no icon, so it cannot be
/// mistaken for the verbs beside it. Absent at zero rather than "0 sats".
fn zapTotal(ui: *AppUi, sats: u64) AppUi.Node {
    if (sats == 0) return ui.spacer(0);
    return ui.row(.{ .height = verb_slot_height, .cross = .center, .gap = 0 }, .{
        metaText(ui, ui.fmt("{s} {s}", .{ formatCount(ui.arena, sats), if (sats == 1) "sat" else "sats" }), theme.palette.text_metric),
    });
}

/// One verb in its slot: the control at the left, the rest of the slot empty.
///
/// The slot is a fixed-width container rather than a fixed-width CONTROL, so a
/// press still has to land on the glyph and its count. A 64-wide hit target
/// would reach across the space between two verbs and answer for its neighbour,
/// and the neighbour of the heart is a glyph that does nothing yet: aiming at
/// the inert one and landing on the live one would publish a reaction.
fn verbSlot(ui: *AppUi, inner: AppUi.Node) AppUi.Node {
    return ui.row(.{ .width = verb_slot_width, .height = verb_slot_height, .cross = .center, .gap = 0 }, .{inner});
}

/// A verb's glyph and its count, as one control.
///
/// The count is left OUT of the children rather than substituted with an empty
/// node when it is zero. Both a row gap and a widget node are charged per flow
/// child whether or not it draws anything, and most notes in a feed carry zero
/// on most of these: a placeholder per empty count came to a tenth of the
/// window's whole widget budget across a screen of rows.
fn verbWithCount(ui: *AppUi, glyph: AppUi.Node, count: u64, color: canvas.Color, options: AppUi.ElementOptions) AppUi.Node {
    var kids: [2]AppUi.Node = undefined;
    kids[0] = glyph;
    var n: usize = 1;
    if (count > 0) {
        kids[1] = metaText(ui, formatCount(ui.arena, count), color);
        n = 2;
    }
    var opts = options;
    opts.gap = 6;
    opts.cross = .center;
    return pressRow(ui, opts, .{kids[0..n]});
}

/// A count beside an action icon, or nothing at zero (so the icon stands alone
/// rather than showing a "0").
fn countLabel(ui: *AppUi, n: u64, color: canvas.Color) AppUi.Node {
    // `ui.spacer(0)` would still be charged the row's 6px gap, leaving a hole
    // where the count is not, so a zero count collapses the gap too.
    if (n == 0) return ui.el(.stack, .{ .width = 0, .height = 0 }, .{});
    return metaText(ui, formatCount(ui.arena, n), color);
}

/// The like control: a pressable heart and its count. Liked is never colour
/// alone (spec): the glyph fills red AND the count turns red together. The count
/// is the crowd's likes plus this session's own optimistic +1, which is dropped
/// once our own reaction comes back through the subscription (so it is not
/// counted twice).
fn likeAction(ui: *AppUi, note: *const Note, counts: bool) AppUi.Node {
    // Our own reaction id (if we liked this note), so the count can retire the
    // optimistic +1 once the reaction is folded into the crowd total.
    const my_reaction: ?[32]u8 = if (likeEntry(note.id)) |e| e.reaction_id else null;
    const liked = my_reaction != null;
    const count = likeCountFor(note.id, my_reaction);
    const tint = if (liked) theme.palette.status_like else theme.palette.text_metric;
    // Hidden means the NUMBER goes, not the verb. You can still like a note
    // with the count taken away; what you lose is being told how many others
    // did, which is the part the preference is about.
    const shown = if (counts and !countHidden(.reactions, .reaction_counts)) count else 0;
    return verbWithCount(ui, ui.appIcon(.{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = tint } }, "like"), shown, tint, .{
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .like = note.id },
        .semantics = .{ .role = .button, .label = if (liked) "Unlike" else "Like", .focusable = true },
    });
}

/// The repost verb: pressable, and tinted once it is ours.
///
/// The tint is the same success green a repost notification uses, so the one
/// colour means the same thing in both places.
fn repostAction(ui: *AppUi, note: *const Note, c: Counts, counts: bool) AppUi.Node {
    const tint = if (c.reposted_by_me) theme.palette.status_success else theme.palette.text_metric;
    return verbWithCount(ui, ui.icon(.{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = tint } }, "repeat"), if (counts and !countHidden(.reposts, .repost_counts)) c.reposts else 0, tint, .{
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .repost = note.id },
        .semantics = .{ .role = .button, .label = if (c.reposted_by_me) "Reposted" else "Repost", .focusable = true },
    });
}

/// Formats an engagement count: the integer below 1000, one-decimal `k` above,
/// and empty at zero so the caller draws the icon alone rather than a "0".
pub fn formatCount(arena: std.mem.Allocator, n: u64) []const u8 {
    if (n == 0) return "";
    if (n < 1000) return std.fmt.allocPrint(arena, "{d}", .{n}) catch "";
    const k = @as(f64, @floatFromInt(n)) / 1000.0;
    return std.fmt.allocPrint(arena, "{d:.1}k", .{k}) catch "";
}

// Which long notes the reader has expanded past the "Show more" fold, by note
// id. Session-only and small: few notes are open at once, so a linear set with
// LRU-ish eviction is plenty. Id 0 marks an empty slot (a note's id is masked
// non-negative and never 0 in practice, the same sentinel `viewing_thread` uses).
const expanded_cap = 64;
/// The pictures the reader has asked for while previews are off. A per-note UI
/// fact, so it lives beside the reader rather than on the Note, which is rebuilt
/// from the store on every refresh. Oldest asked is dropped when it fills, the
/// same shape as the expanded-notes ring.
const asked_cap = 32;
var g_media_asked = [_]i64{0} ** asked_cap;

pub fn isMediaAsked(note_id: i64) bool {
    for (g_media_asked) |a| {
        if (a == note_id) return true;
    }
    return false;
}

fn askForMedia(note_id: i64) void {
    if (isMediaAsked(note_id)) return;
    for (&g_media_asked) |*a| {
        if (a.* == 0) {
            a.* = note_id;
            return;
        }
    }
    std.mem.copyForwards(i64, g_media_asked[0 .. asked_cap - 1], g_media_asked[1..]);
    g_media_asked[asked_cap - 1] = note_id;
}

pub fn askForMediaForTest(note_id: i64) void {
    askForMedia(note_id);
}

pub fn forgetAskedMediaForTest() void {
    g_media_asked = [_]i64{0} ** asked_cap;
}

/// The covered notes the reader has uncovered, by note id.
///
/// Session-only and per note, deliberately: a warning is about one note, so
/// pressing it must not carry to the next launch or to any other note. A ring
/// like the two above, oldest dropped when it fills, which re-covers a note the
/// reader uncovered long ago and has since scrolled far away from.
const uncovered_cap = 64;
var g_uncovered = [_]i64{0} ** uncovered_cap;

pub fn isUncovered(note_id: i64) bool {
    for (g_uncovered) |u| {
        if (u == note_id) return true;
    }
    return false;
}

fn uncoverNote(note_id: i64) void {
    if (note_id == 0 or isUncovered(note_id)) return;
    for (&g_uncovered) |*u| {
        if (u.* == 0) {
            u.* = note_id;
            return;
        }
    }
    std.mem.copyForwards(i64, g_uncovered[0 .. uncovered_cap - 1], g_uncovered[1..]);
    g_uncovered[uncovered_cap - 1] = note_id;
}

/// The key a quote of `id` is uncovered by, which is the key the same note
/// carries in the feed.
pub fn feedKeyForTest(id: [32]u8) i64 {
    return feedKeyOf(id);
}

pub fn uncoverNoteForTest(note_id: i64) void {
    uncoverNote(note_id);
}

pub fn forgetUncoveredForTest() void {
    g_uncovered = [_]i64{0} ** uncovered_cap;
}

/// Whether something the author marked sensitive is covered right now: the
/// author asked, the reader has not turned the warnings off, and has not pressed
/// this one. The ONE answer every surface asks, so the text, the pictures, the
/// link card, the fetches and the row's height cannot disagree about it.
pub fn warningCovered(warned: bool, key: i64) bool {
    return warned and !prefs.g_show_sensitive and !isUncovered(key);
}

/// Whether `note` is covered. Its pictures and link are covered with it, and
/// nothing is fetched for them while it is.
pub fn noteCovered(note: *const Note) bool {
    return warningCovered(note.warned, note.id);
}

/// A covered note draws no picture and no link card, whatever it carries.
pub fn showsImage(note: *const Note) bool {
    return note.hasImage() and !noteCovered(note);
}

fn showsLink(note: *const Note) bool {
    return note.hasLink() and !noteCovered(note);
}

var g_expanded = [_]i64{0} ** expanded_cap;

pub fn isExpanded(note_id: i64) bool {
    for (g_expanded) |e| {
        if (e == note_id) return true;
    }
    return false;
}

/// Toggles whether `note_id`'s long body is expanded. Evicts the oldest slot
/// when the (generous) set is full rather than refusing to expand.
fn toggleExpanded(note_id: i64) void {
    for (&g_expanded) |*e| {
        if (e.* == note_id) {
            e.* = 0;
            return;
        }
    }
    for (&g_expanded) |*e| {
        if (e.* == 0) {
            e.* = note_id;
            return;
        }
    }
    g_expanded[0] = note_id;
}

/// The byte length of `text` to show collapsed: the whole thing when it is not
/// long, else a prefix near `max` that ends on a codepoint boundary and, when
/// one is close, a word boundary, so the fold never cuts mid-word or mid-glyph.
pub fn collapsedLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var end = max;
    // Back to the start of a codepoint (never mid-sequence).
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    // Prefer the last space/newline in the final quarter, so a word stays whole.
    const floor = (max * 3) / 4;
    var w = end;
    while (w > floor and text[w - 1] != ' ' and text[w - 1] != '\n') w -= 1;
    if (w > floor) end = w;
    return end;
}

/// Whether a note is long enough to collapse: comfortably past the fold, so a
/// note only a line or two over is shown whole rather than hiding a few words.
pub fn noteIsLong(note: *const Note) bool {
    return note.content_len > note_collapse_chars + 80;
}

/// A styled body paragraph, the same shape everywhere text is rendered.
fn textPara(ui: *AppUi, spans: []const canvas.TextSpan) AppUi.Node {
    return textParaAt(ui, spans, 1, theme.palette.text_body);
}

/// The same paragraph at a stated register and ink: the thread's focal note reads
/// one step up from a feed row, and a shade brighter.
fn textParaAt(ui: *AppUi, spans: []const canvas.TextSpan, scale: f32, ink: canvas.Color) AppUi.Node {
    // A paragraph one step DOWN is asked for by its SIZE, never by scaling
    // every span in it, and the difference is a point of vertical position.
    //
    // The line box and the baseline come from `size * max(1, largest span
    // scale)`. That floor of 1 is the whole problem: a paragraph whose spans
    // are all scaled DOWN is still boxed and baselined as though it were full
    // size, so the nested register drew 13.5pt text on a 14.5pt baseline inside
    // an 18.125pt box instead of a 13.5pt baseline in a 16.875pt one. A point
    // lower than the text around it, with a point and a quarter of extra air
    // above, which is what a reply's context line looked like next to the note
    // it belongs to.
    //
    // `.sm` is `body_size - 1`, which is exactly the 13.5 the ratio was
    // approximating, and the spans then sit at scale 1 of a genuinely smaller
    // paragraph. Scaling UP is unaffected and stays a scale: the floor only
    // bites below 1.
    if (scale == nested_body_scale) {
        return ui.paragraph(.{
            .size = .sm,
            .wrap = true,
            .on_link = AppUi.linkMsg(.open_url),
            .style = .{ .foreground = ink },
        }, spans);
    }
    const sized = if (scale == 1) spans else blk: {
        const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch break :blk spans;
        for (spans, out) |src, *dst| {
            dst.* = src;
            // A span that already states its own scale keeps its ratio to the
            // body around it.
            dst.scale = (if (src.scale == 0) 1 else src.scale) * scale;
        }
        break :blk out;
    };
    return ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = ink } }, sized);
}

/// A note's body: the styled text, an embedded quote card where the note quotes
/// another event, and a "Show more" affordance when it is long (unless the reader
/// has expanded it, or `collapsible` is false, as for a thread's focused root).
/// The body splits around the quoted event's raw token (its byte span), never
/// cutting the card; a quote at or past the fold appears only once expanded.
fn noteBody(ui: *AppUi, note: *const Note, collapsible: bool) AppUi.Node {
    return noteBodyAt(ui, note, collapsible, 1, theme.palette.text_body);
}

/// The body at a stated register: everything above, one step larger, for the note
/// a thread is about.
fn noteBodyAt(ui: *AppUi, note: *const Note, collapsible: bool, scale: f32, ink: canvas.Color) AppUi.Node {
    const p = theme.palette;
    // The author's warning replaces the whole body: the words, the quote card
    // and the fold with it. One chip, in the space the body would have taken.
    if (noteCovered(note)) return coverNotice(ui, note.warning(), note.id);
    // A kind nothing here can draw says which kind, where the body would be.
    // `noteFrom` leaves the body empty for these, and an empty paragraph is
    // what made such a card read as a note that had failed to load rather than
    // as one this app was never going to draw.
    if (kindRender(note.kind) == .unsupported) return unsupportedKindChip(ui, note.kind);
    const full = note.content();
    const long = collapsible and noteIsLong(note);
    const expanded = long and isExpanded(note.id);
    const cut: usize = if (long and !expanded) collapsedLen(full, note_collapse_chars) else full.len;
    const q = note.quote;
    const card_end = @as(usize, q.off) + @as(usize, q.len);
    const has_card = q.kind == .event and card_end <= cut;

    // Fast path unchanged: a plain note with no fold is exactly one paragraph.
    if (!has_card and !long) return textParaAt(ui, noteSpans(ui, note, full[0..cut]), scale, ink);

    var kids: [5]AppUi.Node = undefined;
    var n: usize = 0;
    if (has_card) {
        const head = std.mem.trim(u8, full[0..q.off], " \t\r\n");
        if (head.len > 0) {
            kids[n] = textParaAt(ui, noteSpans(ui, note, head), scale, ink);
            n += 1;
        }
        kids[n] = quoteRule(ui, q.id);
        n += 1;
        const tail = std.mem.trim(u8, full[card_end..cut], " \t\r\n");
        if (tail.len > 0) {
            kids[n] = textParaAt(ui, noteSpans(ui, note, tail), scale, ink);
            n += 1;
        }
    } else {
        kids[n] = textParaAt(ui, noteSpans(ui, note, full[0..cut]), scale, ink);
        n += 1;
    }
    if (long) {
        // A deeper hit target than the row's open-thread press, so tapping it
        // toggles the fold rather than opening the thread.
        kids[n] = pressRow(ui, .{ .on_press = Msg{ .toggle_expand = note.id }, .padding = 2, .style = .{ .quiet_hover = true }, .semantics = .{ .role = .button, .label = if (expanded) "Show less" else "Show more", .focusable = true } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_secondary } }, if (expanded) "Show less" else "Show more"),
        });
        n += 1;
    }
    return ui.column(.{ .gap = 8 }, .{kids[0..n]});
}

/// The line above a reply saying what it answers.
///
/// A feed that mixes replies in with root notes shows half a conversation: an
/// answer with no question reads as a non sequitur, and worse, as though the
/// person said it unprompted. Every other client puts the missing half back,
/// and this is that line.
///
/// Deliberately ONE line and no avatar. The picture would want a registry slot,
/// and there are sixteen for the whole app; a screenful of replies would spend
/// them all on thumbnails of notes the reader is not reading. The name and the
/// opening words are what identify a conversation anyway.
fn replyContext(ui: *AppUi, note: *const Note) AppUi.Node {
    const e = quoteFor(note.reply_parent);
    if (e == null) {
        // The parent's cache slot was reclaimed (it is one LRU shared with
        // quotes). Ask again so the next tick fills it, and say the neutral
        // thing meanwhile rather than flickering a wrong name.
        wantQuote(note.reply_parent);
        return replyContextLine(ui, "reply to a note", "");
    }
    const q = e.?;
    if (q.state == .idle or q.state == .fetching) return replyContextLine(ui, "reply to a note", "");
    if (q.state == .missing) {
        // The same sentence the thread's ancestor row uses for the same fact,
        // because it IS the same fact.
        return replyContextLine(ui, "reply to a note not on your relays yet", "");
    }

    const name = quoteAuthorName(ui, q.pubkey);
    const label = std.fmt.allocPrint(ui.arena, "reply to {s}", .{name}) catch "reply to a note";
    return replyContextLine(ui, label, quoteShownText(q));
}

/// One muted line: who was answered, then the opening of what they said.
///
/// The snippet is a SEPARATE span so it can carry its own dimmer colour, which
/// is what keeps the name readable when the two run together. Both elide rather
/// than wrap: this is a pointer at a conversation, not a second note.
fn replyContextLine(ui: *AppUi, label: []const u8, snippet: []const u8) AppUi.Node {
    const p = theme.palette;
    var spans: [2]canvas.TextSpan = undefined;
    var n: usize = 0;
    // The name carries the weight and the snippet does not, so the two read
    // apart on one line without needing a second colour.
    spans[n] = .{ .text = label, .weight = .medium };
    n += 1;
    if (snippet.len > 0) {
        // One line's worth. The cache already clamps to `quote_text_cap`, and a
        // paragraph that elides needs less than that or it never reaches the
        // ellipsis before running out of box.
        const cut = firstLineOf(snippet, reply_context_snippet_chars);
        if (cut.len > 0) {
            spans[n] = .{ .text = std.fmt.allocPrint(ui.arena, "  {s}", .{cut}) catch "", .scale = 0 };
            n += 1;
        }
    }
    // `.sm`, not spans scaled to 13.5/14.5, and the difference is a point of
    // vertical position rather than a nicety.
    //
    // A paragraph's line box and baseline come from `size * max(1, largest span
    // scale)`. The floor of 1 is what matters: a paragraph whose spans are ALL
    // scaled DOWN is still boxed and baselined as though it were full size, so
    // this line drew its 13.5pt text on a 14.5pt baseline inside an 18.125pt box
    // instead of a 13.5pt baseline in a 16.875pt one. A point lower than the
    // text beside it, with a point and a quarter of extra air above.
    //
    // The size TOKEN says the same thing without the floor applying: `.sm` is
    // `body_size - 1`, which is exactly the 13.5 the ratio was approximating,
    // and the spans then sit at scale 1 of a genuinely smaller paragraph.
    return ui.paragraph(
        .{ .size = .sm, .width = picture_column_width, .style = .{ .foreground = p.text_muted } },
        spans[0..n],
    );
}

/// The opening of `text`, stopping at the first newline and at `max` bytes, on a
/// UTF-8 boundary. A snippet cut mid-codepoint draws a replacement glyph, which
/// is a worse thing to show than a shorter snippet.
fn firstLineOf(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var end = @min(trimmed.len, max);
    if (std.mem.indexOfScalar(u8, trimmed[0..end], '\n')) |nl| end = nl;
    // Back off to a character boundary by looking at the byte AT the cut, not
    // the one before it. Stripping trailing continuation bytes is not enough:
    // it leaves the lead byte they belonged to, which is a broken sequence of
    // its own. If the first EXCLUDED byte is a continuation, the cut landed
    // mid-character, so walk back until it is not.
    if (end < trimmed.len) {
        while (end > 0 and (trimmed[end] & 0xc0) == 0x80) end -= 1;
    }
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}

pub fn firstLineOfForTest(text: []const u8, max: usize) []const u8 {
    return firstLineOf(text, max);
}

/// Renders just the reply line and returns its concatenated text, so a test can
/// read what a reader would see without standing up a whole feed.
pub fn buildReplyContextForTest(arena: std.mem.Allocator, note: *const Note) ![]const u8 {
    var ui = AppUi.init(arena);
    const node = replyContext(&ui, note);
    const tree = try ui.finalize(node);
    var out: std.ArrayList(u8) = .empty;
    try collectText(tree.root, arena, &out);
    return out.items;
}

fn collectText(w: canvas.Widget, arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (w.text.len > 0) {
        try out.appendSlice(arena, w.text);
        try out.append(arena, ' ');
    }
    for (w.children) |c| try collectText(c, arena, out);
}

/// An embedded quote card for a quoted event `id`: a bordered inset showing the
/// quoted author and a truncated body, tappable to open it. Loading and
/// unavailable states are non-pressable and hold the same height, so the feed
/// never reflows as the quote resolves. The author is drawn as initials-on-tint
/// (`image = 0`), so a quote card never competes for the scarce avatar ids.
fn quoteRule(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const e = quoteFor(id);
    if (e == null or e.?.state == .idle or e.?.state == .fetching) {
        // A reused feed note (never re-parsed) whose quote slot was reclaimed by
        // a newer quote lands here with no cache entry; re-queue it so the next
        // tick resolves it again instead of showing a skeleton forever.
        if (e == null) wantQuote(id);
        return quoteAside(ui, null, quoteSkeleton(ui));
    }
    const q = e.?;
    if (q.state == .missing) {
        // "Yet", because that is now true. This card said "unavailable" from
        // when three unanswered tries ended the search for good; the search does
        // not end any more, so the card must not say it does. It is the same
        // sentence the ancestor row above a thread has always used for the same
        // situation, which is the other reason to use it.
        return quoteAside(ui, null, ui.paragraph(
            .{ .size = .sm, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = "Not on your relays yet" }},
        ));
    }

    // A synthetic note, so the quote wears the SAME identity recipe as every
    // other row instead of a second one built from the cache's parts. Writing a
    // parallel builder is what cost the focal note its quote card once already.
    const note = ui.arena.create(Note) catch return ui.spacer(0);
    note.* = .{ .pubkey = q.pubkey, .created_at = q.created_at, .kind = q.kind };
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[q.pubkey[0] >> 4], hexdigits[q.pubkey[0] & 0x0f] };
    setAuthor(note, q.pubkey);
    note.setTime(nowSeconds());
    const text = q.text_buf[0..q.text_len];
    @memcpy(note.content_buf[0..text.len], text);
    note.content_len = @intCast(text.len);
    // The quoted note's OWN reference is drawn as the pill below, so it comes
    // out of the body: left in, it is a hundred characters of bech32 that no
    // line break can split, which runs straight out of the reading column.
    findQuoteRef(note);
    if (note.quote.kind == .event) {
        const cut_start = @as(usize, note.quote.off);
        const cut_end = cut_start + @as(usize, note.quote.len);
        if (cut_end <= note.content_len) {
            const tail = note.content_buf[cut_end..note.content_len];
            std.mem.copyForwards(u8, note.content_buf[cut_start..], tail);
            note.content_len = @intCast(cut_start + tail.len);
            const trimmed = std.mem.trimEnd(u8, note.content_buf[0..note.content_len], " \n\r\t");
            note.content_len = @intCast(trimmed.len);
        }
    }

    // `grow` so the quote fills the column beside the rule: hugging its content,
    // the body wrapped at about half the width the shot gives it.
    return quoteAside(ui, id, ui.column(.{ .grow = 1, .gap = 4 }, .{
        ui.row(.{ .gap = 10, .cross = .start }, .{
            avatarDisc(ui, note, avatar_size),
            identityBlock(ui, note),
            // The same grow every other row that carries a time has. Without it
            // the time sat wherever the name left it, so it was LEFT aligned in
            // a card whose every other row is right aligned, and its right edge
            // moved with the width of the text: "1d" and "12h" ended seven
            // points apart.
            ui.spacer(1),
            ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, &.{.{ .text = note.time(), .scale = meta_scale }}),
        }),
        // Four lines of the quoted note, and no more: a quote is an aside, and
        // its height has to be known where the outer row is priced.
        if (quoteCovered(q)) coverNotice(ui, q.warning_buf[0..q.warning_len], feedKeyOf(id)) else if (q.text_len > 0) quoteBody(ui, note) else ui.spacer(0),
        // What the card cannot draw, said rather than left blank. The chip for
        // an unsupported kind sits beside the one for a picture because they
        // answer the same question: a card with a name, a time and nothing
        // under it reads as a rendering fault, and this says which it is.
        if (kindRender(q.kind) == .unsupported) unsupportedKindChip(ui, q.kind) else ui.spacer(0),
        if (q.image_host_len > 0 and !quoteCovered(q)) quoteMediaChip(ui, q) else ui.spacer(0),
        // A quote of a quote stops here. One more body would be a third voice in
        // a row, so the second hop is a pill that says where it goes.
        if (q.has_quote_of) quotingPill(ui, q.quote_of) else ui.spacer(0),
    }));
}

/// The quoted note's own words, four lines of them. Labelled, because the one
/// thing worth asserting about it is how WIDE it is: hugging its content instead
/// of filling the column beside the rule, it wrapped at about half the width the
/// shot gives it and read as a column of its own rather than an aside.
fn quoteBody(ui: *AppUi, note: *const Note) AppUi.Node {
    const spans = clampSpansToLines(ui, noteSpans(ui, note, note.content()), quote_body_lines);
    var node = textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
    node.widget.semantics.label = "Quoted note body";
    return node;
}

/// Says that an event is of a kind this app has no way to draw, and which kind.
///
/// The kind NUMBER, deliberately. A reader who sees "kind 31923" can look it up
/// or open the event somewhere that draws it; a reader looking at a blank card
/// has been told nothing, and cannot tell a kind Plaza will never draw from a
/// note that failed to load. Jumble draws the same conclusion and puts a client
/// picker next to it (`src/components/NoteContent/UnknownNote.tsx`).
fn unsupportedKindChip(ui: *AppUi, kind: u16) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .height = quote_pill_height,
            .padding = 0.01,
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 8),
                // `dashed-ring`, which is this app's placeholder glyph, used at
                // avatar size wherever there is nothing yet to draw. `appIcon`
                // takes an APP-REGISTERED name and there are ten of them; an
                // unregistered one draws the missing-icon fallback, a slashed
                // circle, with no compile error and no test failure. This said
                // "file" when it shipped, and drew exactly that.
                ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "dashed-ring"),
                hgap(ui, 6),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Plaza cannot draw a kind {d} event", .{kind}), .scale = meta_scale }},
                ),
                hgap(ui, 8),
            }),
        }),
        ui.spacer(1),
    });
}

/// Whether the card draws the picture itself rather than naming it. Previews
/// off keeps the old, honest chip (nothing is fetched, so nothing could be
/// drawn), and so does a quote with no address worth fetching.
fn quoteShowsPicture(q: *const QuoteEntry) bool {
    return prefs.g_media_previews and q.image_url_len > 0 and !quoteCovered(q);
}

/// The shape to reserve for a quote's picture: what its `imeta` declares, else
/// what it measured the last time it was decoded (remembered past its slot, so
/// an evicted picture does not shrink the card), else the feed's guess.
fn quotePictureAspect(q: *const QuoteEntry) f32 {
    if (q.image_aspect > 0) return q.image_aspect;
    return recalledAspect(quoteMediaKey(q.id)) orelse picture_default_aspect;
}

pub const QuotePictureBox = struct { width: f32, height: f32 };

/// The box a quote's picture is drawn in, for a given height over width.
///
/// Total on purpose: a note can declare any dimensions it likes and a decode can
/// report none, so zero, negative, infinite and absurd shapes all land on a box
/// the card can be priced for.
pub fn quotePictureBox(aspect: f32) QuotePictureBox {
    const shape = if (std.math.isFinite(aspect) and aspect > 0) aspect else picture_default_aspect;
    const height = quote_picture_width * std.math.clamp(shape, quote_picture_min_aspect, quote_picture_max_aspect);
    // Taller than the cap: the box is the picture's own shape at the capped
    // height, so `contain` leaves no bare gutters inside the border.
    const width = if (shape > quote_picture_max_aspect) height / shape else quote_picture_width;
    return .{ .width = width, .height = height };
}

/// The picture a quote card holds, drawn from the media slot the scan pass gave
/// it: its blurhash (or stripes) while it loads, the picture when it has arrived,
/// a plain box when it will not come. All three are the same size. A picture
/// whose note declares its shape lands without moving the card; one that does
/// not is sized by the feed's guess until it has been decoded once, as a feed
/// picture is.
///
/// With previews off, or no address worth fetching, the card names the picture
/// and where it is from instead. Not a control either way: pressing the CARD
/// already opens the quoted note, and a second press target here would only be a
/// shorter way to the same place.
fn quoteMediaChip(ui: *AppUi, q: *const QuoteEntry) AppUi.Node {
    const host = q.image_host_buf[0..q.image_host_len];

    if (quoteShowsPicture(q)) {
        const p = theme.palette;
        const box = quotePictureBox(quotePictureAspect(q));
        const slot = mediaSlotFor(quoteMediaKey(q.id));
        const inner: AppUi.Node = if (slot != null and slot.?.state == .loaded and slot.?.image_id != 0) blk: {
            var picture = ui.image(.{
                .image = slot.?.image_id,
                .grow = 1,
                .semantics = .{ .label = "Picture in the quoted note" },
            });
            picture.widget.image_fit = .contain;
            break :blk picture;
        } else if (slot != null and slot.?.state == .failed)
            ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 6 }, .{
                ui.appIcon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_dim } }, "image"),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Picture from {s} would not load", .{host}), .scale = meta_scale }},
                ),
            })
        else
            // Its own colours when the note carries a blurhash, stripes when it
            // does not. Flat cells and not a registered image, so the wait costs
            // no registry id: the id is claimed for the picture itself.
            blurGrid(ui, q.imageBlurhash(), box.height);
        return ui.row(.{ .gap = 0 }, .{
            ui.el(.data_row, .{
                .width = box.width,
                .height = box.height,
                .padding = 0,
                .style = .{ .radius = picture_radius, .border = p.border_hairline, .stroke_width = 1, .background = p.surface_inset },
            }, .{inner}),
            ui.spacer(1),
        });
    }

    // Otherwise show a pill saying the picture is there and where it's from.
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .height = quote_pill_height,
            .padding = 0.01,
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 8),
                ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "image"),
                hgap(ui, 6),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Picture from {s}", .{host}), .scale = meta_scale }},
                ),
                hgap(ui, 8),
            }),
        }),
        ui.spacer(1),
    });
}

/// 11g's pill: where the quoted note's own quote goes, one hop, as a line rather
/// than a third nested body. Pressing it walks that hop.
fn quotingPill(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const tint = avatarTint(quotingPillAuthor(id));
    const hexdigits = "0123456789abcdef";
    const author = quotingPillAuthor(id);
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = quote_pill_height,
            .cross = .center,
            .on_press = Msg{ .open_event = id },
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Quoted note inside it", .focusable = true },
        }, .{
            hgap(ui, 4),
            ui.avatar(.{
                .image = 0,
                .width = 14,
                .height = 14,
                .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
            }, ui.fmt("{c}{c}", .{ hexdigits[author[0] >> 4], hexdigits[author[0] & 0x0f] })),
            hgap(ui, 6),
            // ONE line, elided at the tail: the pill says where the hop goes and
            // begins what it says, and a long note may not push the row wider.
            // `wrap = false` is what makes the single-line overflow policy apply.
            ui.text(.{
                .width = quote_pill_label_width,
                .wrap = false,
                .overflow = .ellipsis,
                .size = .sm,
                .style = .{ .foreground = p.text_muted_alt },
            }, quotingPillLabel(ui, id)),
            hgap(ui, 9),
        }),
        // Hugging its content, so the pill is a pill and not a bar.
        ui.spacer(1),
    });
}

/// `text` with its line breaks folded into spaces, for a control that is one
/// line by construction. A widget that measures single-line still PAINTS the
/// newlines its text carries, so an unfolded label draws its second line over
/// whatever is under the row.
fn oneLine(ui: *AppUi, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n") == null) return text;
    const out = ui.arena.alloc(u8, text.len) catch return text;
    var n: usize = 0;
    var last_space = false;
    for (text) |c| {
        const space = c == '\n' or c == '\r' or c == ' ' or c == '\t';
        if (space) {
            if (last_space or n == 0) continue;
            out[n] = ' ';
        } else {
            out[n] = c;
        }
        last_space = space;
        n += 1;
    }
    return out[0..n];
}

pub fn oneLineForTest(ui: *AppUi, text: []const u8) []const u8 {
    return oneLine(ui, text);
}

/// Whose note the pill walks to, once that note is resolved; a zero key until
/// then, which tints the disc neutrally rather than guessing.
fn quotingPillAuthor(id: [32]u8) [32]u8 {
    const e = quoteFor(id) orelse return [_]u8{0} ** 32;
    if (e.state != .loaded) return [_]u8{0} ** 32;
    return e.pubkey;
}

/// What the pill says. It names the author once that note has arrived, and says
/// plainly that it is still coming until then, rather than showing a name it
/// does not have.
fn quotingPillLabel(ui: *AppUi, id: [32]u8) []const u8 {
    // Re-queued when the entry is gone, the same way the aside itself does it:
    // the pill's target is asked for once, when the note holding it is filled,
    // and the 64-entry cache can evict it while the pill is still on screen. Then
    // nothing would ever ask again, because the note holding it is loaded and a
    // loaded entry is never revisited.
    const e = quoteFor(id) orelse {
        wantQuote(id);
        return "Quoting a note";
    };
    return switch (e.state) {
        // Whose note, and the start of what it says: the shot's own pill reads
        // "Quoting @edith · Shipping it: the feed renders…", so the reader can
        // tell whether the hop is worth taking before taking it.
        .loaded => switch (kindRender(e.kind)) {
            // Naming the kind beats naming the author and then showing nothing:
            // a kind whose content is empty by design drew "Quoting @somebody"
            // with a blank after it, which reads as a note that failed to load.
            .unsupported => ui.fmt("Quoting a kind {d} event", .{e.kind}),
            else => ui.fmt("Quoting {s} · {s}", .{
                quotePillHandle(ui, e.pubkey),
                if (quoteCovered(e)) "content warning" else oneLine(ui, e.text_buf[0..e.text_len]),
            }),
        },
        .missing => "Quotes a note no relay has",
        else => "Quoting a note",
    };
}

/// The handle for a pill: `@name` when the author has one, else their display
/// name, else a short npub. The pill is one line, so it names them the shortest
/// true way rather than the fullest.
fn quotePillHandle(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.nip05_len > 0) {
            const nip05 = pr.nip05();
            if (std.mem.indexOfScalar(u8, nip05, '@')) |at| {
                const local = nip05[0..at];
                const shown = if (std.mem.eql(u8, local, "_")) nip05[at + 1 ..] else local;
                if (shown.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{shown}) catch "";
            }
        }
        const user = pr.username();
        if (user.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{user}) catch "";
    }
    return quoteAuthorName(ui, pubkey);
}

/// The rule down the left of a quote, and whatever sits beside it. The redesign
/// replaces the bordered card with this: a card inside a row reads as a second
/// surface competing with the note, where the rule reads as an aside, which is
/// what a quote is.
///
/// `id` non-null makes the block open that note. The rule brightening on hover
/// (11f) is not expressible: hover is a background wash on one widget, and a
/// wash here would be a state the design does not draw.
fn quoteAside(ui: *AppUi, id: ?[32]u8, body: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // `grow` on the row, so the aside is as wide as the column it sits in. Its
    // parent is a column, where grow is the vertical axis for the WRAPPER but the
    // width for this row's own sizing: without it the row took its intrinsic
    // width, which for a long quote measured three times the window.
    const inner = ui.row(.{ .grow = 1, .gap = 0 }, .{
        // The rule takes the row's height from the default cross STRETCH. It must
        // not `grow`: grow in a row is the horizontal axis, so a growing 2px rule
        // and the growing content column split the width between them, and the
        // quote wrapped at half the space the shot gives it. The thread's rail
        // uses the same construct correctly because it sits in a COLUMN, where
        // grow is the axis it wants.
        ui.separator(.{ .width = 2, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
        hgap(ui, 12),
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            vgap(ui, 2),
            body,
            vgap(ui, 2),
        }),
    });
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 5),
        if (id) |event_id|
            // A plain row: it paints nothing, which is right, because 11f gives a
            // quote no hover state (its rule brightening is not expressible) and
            // a wash here would invent one. It also MEASURES, which `list_item`
            // does not: the width-aware measurer has no case for that kind, so a
            // wrapping quote body would measure one line tall and draw over the
            // verbs under it.
            pressRow(ui, .{
                .grow = 1,
                // By EVENT id, read straight from the store: a quoted note is in
                // neither the feed nor the open thread's replies.
                .on_press = Msg{ .open_event = event_id },
                .semantics = .{ .role = .button, .label = "Quoted note", .focusable = true },
            }, .{inner})
        else
            inner,
    });
}

/// Seeds a resolved quote, so a test can render the aside and price it without a
/// relay. Returns the id it was filed under.
pub fn seedQuoteForTest(id: [32]u8, pubkey: [32]u8, created_at: i64, text: []const u8) void {
    wantQuote(id);
    const e = quoteFor(id) orelse return;
    e.pubkey = pubkey;
    e.created_at = created_at;
    // These fixtures were written before a quote entry carried a kind, and
    // every one of them means "a note". Left at the 0 default they would each
    // claim to hold an event of a kind nothing can draw.
    e.kind = 1;
    const keep = @min(text.len, e.text_buf.len);
    @memcpy(e.text_buf[0..keep], text[0..keep]);
    e.text_len = @intCast(keep);
    e.state = .loaded;
}

/// Puts a resolved parent in the cache, as an answered fetch would.
pub fn fillQuoteForTest(id: [32]u8, pubkey: [32]u8, text: []const u8) void {
    wantQuote(id);
    const q = quoteFor(id) orelse return;
    q.state = .loaded;
    q.pubkey = pubkey;
    // These fixtures were written before a quote entry carried a kind, and
    // every one of them means "a note". Left at the 0 default they would each
    // claim to hold an event of a kind nothing can draw.
    q.kind = 1;
    const n = @min(text.len, q.text_buf.len);
    @memcpy(q.text_buf[0..n], text[0..n]);
    q.text_len = @intCast(n);
}

/// How many relay hints the cache entry for `id` is holding, or null when there
/// is no entry. For asserting that a decoded address actually left its hints
/// somewhere the fetch will find them.
pub fn quoteHintCountForTest(id: [32]u8) ?u8 {
    for (&quote_cache.g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) return q.hints.count;
    }
    return null;
}

/// The same, for the person an `nprofile1` named.
pub fn profileHintCountForTest(pubkey: [32]u8) ?u8 {
    for (&profile_cache.g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return w.hints.count;
    }
    return null;
}

pub fn wantQuoteForTest(id: [32]u8) void {
    wantQuote(id);
}

/// Wants a quoted event the way an `nevent1` naming relays does.
pub fn wantQuoteHintedForTest(id: [32]u8, hints: []const []const u8) void {
    wantQuoteHinted(id, hints);
}

/// The relays a quote's fetch would dial, empty when it is not cached.
pub fn quoteHintsForTest(id: [32]u8) RelayHints {
    for (&quote_cache.g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) return q.hints;
    }
    return .{};
}

/// The real fill path, over a real store: what a quote card knows about the
/// note it draws comes from here and nowhere else.
pub fn refreshProfilesForTest(store: *nostr.store.Store) void {
    refreshProfiles(store);
}
pub fn quoteTextForTest(id: [32]u8) ?[]const u8 {
    const q = quoteFor(id) orelse return null;
    if (q.state != .loaded) return null;
    return q.text_buf[0..q.text_len];
}
pub fn refreshQuotesForTest(store: *nostr.store.Store) void {
    refreshQuotes(store);
}

pub fn requeueMissingQuotesForTest() void {
    requeueMissingQuotes();
}

pub fn requestWantedQuotesForTest() void {
    requestWantedQuotes();
}

pub fn advanceQuoteRoundForTest(rounds: u64) void {
    quote_cache.g_quote_round +%= rounds;
}

pub fn rearmWantedQuotesForTest() void {
    rearmWantedQuotes();
}

pub fn quoteBackoffRoundsForTest(attempts: u8) u64 {
    return quoteBackoffRounds(attempts);
}

/// Marks a cached quote as one its author asked to have covered.
pub fn warnQuoteForTest(id: [32]u8, reason: []const u8) void {
    const q = quoteFor(id) orelse return;
    q.warned = true;
    @memcpy(q.warning_buf[0..reason.len], reason);
    q.warning_len = @intCast(reason.len);
}

pub fn quoteForTest(id: [32]u8) ?*QuoteEntry {
    return quoteFor(id);
}

pub fn dropQuoteForTest(id: [32]u8) void {
    for (&quote_cache.g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) q.* = .{};
    }
}

pub fn quotingPillLabelForTest(ui: *AppUi, id: [32]u8) []const u8 {
    return quotingPillLabel(ui, id);
}

pub fn quoteBodyLinesForTest(e: *const QuoteEntry) f32 {
    return quoteBodyLines(e);
}

/// The media-slot key a quote's picture is filed under.
pub fn quoteMediaKeyForTest(id: [32]u8) i64 {
    return quoteMediaKey(id);
}

/// Where the slot filed under `key` is in its life, and the registry id it
/// holds (0 for none), or null when no slot exists. Looks without claiming.
pub fn mediaSlotStateForTest(key: i64) ?struct { state: []const u8, image_id: u64, url: []const u8 } {
    const m = mediaSlotFor(key) orelse return null;
    return .{ .state = @tagName(m.state), .image_id = m.image_id, .url = m.url() };
}

pub fn toggleExpandedForTest(note_id: i64) void {
    toggleExpanded(note_id);
}

/// Leaves the slot under `key` the way a finished fetch would: a registry id
/// taken from the pool, marked loaded at this size. The decode itself needs a
/// platform codec a test does not have.
pub fn markMediaLoadedForTest(fx: *Effects, key: i64, width: usize, height: usize) ?u64 {
    const slot = claimMediaSlot(fx, key) orelse return null;
    if (slot.image_id == 0) slot.image_id = acquireImageId(fx) orelse return null;
    slot.state = .loaded;
    slot.width = width;
    slot.height = height;
    rememberAspect(slot.note_id, width, height);
    return slot.image_id;
}

pub fn noteRowEstimateForTest(note: *const Note, chrome: f32) f32 {
    return noteRowEstimate(note, chrome);
}

/// The quoted author's display name (from the profile cache) or a short npub.
fn quoteAuthorName(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.name_len > 0) return pr.name();
    }
    const buf = ui.arena.alloc(u8, 24) catch return "";
    return abbreviateNpub(buf, pubkey);
}

/// The focal note's timestamp in full: the time and the date, since a note being
/// read deserves to say exactly when it was written rather than "3h".
fn absoluteNoteTime(arena: std.mem.Allocator, created_at: i64) []const u8 {
    // LOCAL time, because a reader reads a clock, not an offset. Neither the SDK
    // nor the standard library carries a timezone database, so the offset comes
    // from libc, which knows the zone and the daylight rule. Off macOS (the
    // portability build) there is no such call wired, and the line says UTC
    // rather than pretending.
    const shifted = created_at + localOffsetSeconds(created_at);
    const secs: u64 = @intCast(@max(shifted, 0));
    const days = secs / 86_400;
    const day_secs = secs % 86_400;
    const hour24 = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const pm = hour24 >= 12;
    const hour12 = if (hour24 % 12 == 0) 12 else hour24 % 12;
    // Civil date from the Unix epoch, by Howard Hinnant's algorithm: exact, and
    // no dependency on a timezone database the app does not carry.
    const z = @as(i64, @intCast(days)) + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_name = months[@intCast(@min(@max(m - 1, 0), 11))];
    return std.fmt.allocPrint(arena, "{d}:{d:0>2} {s}{s} · {s} {d}, {d}", .{
        hour12, minute, if (pm) "PM" else "AM", if (comptime builtin.os.tag == .windows) " UTC" else "", month_name, d, year,
    }) catch "";
}

/// Seconds to add to a Unix timestamp to get local wall-clock time, from libc's
/// own zone handling (so daylight saving is right, and right for the DATE in
/// question rather than for today).
fn localOffsetSeconds(unix_seconds: i64) i64 {
    // Not macOS-only. `c_tm` below is laid out for the BSD and glibc `struct
    // tm` (it carries `tm_gmtoff` and `tm_zone`), and `localtime_r` is in glibc
    // as well, so a Linux build reads the reader's real zone and their real
    // daylight saving. Gated on Windows instead, which has `localtime_s` and a
    // different struct, and where this would be a link error rather than a
    // wrong answer.
    if (comptime builtin.os.tag == .windows) return 0;
    var tm: c_tm = std.mem.zeroes(c_tm);
    const t: i64 = unix_seconds;
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.tm_gmtoff;
}

/// The fields of `struct tm` this needs, in libc's order. Only `tm_gmtoff` is
/// read; the rest are here so the struct is the right size for libc to fill.
const c_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn localtime_r(timer: *const i64, result: *c_tm) ?*c_tm;

/// Who a reply is addressed to: the handle when one is known, else the display
/// name, which is all a profile without a nip05 offers.
fn replyTarget(ui: *AppUi, note: *const Note) []const u8 {
    const handle = note.handle(ui.arena);
    return if (handle.len > 0) handle else note.author();
}

/// One phrase or the other, by count. English, and the only two shapes the
/// chrome needs.
fn pluralize(ui: *AppUi, n: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return if (n == 1) ui.fmt(one, .{n}) else ui.fmt(many, .{n});
}

/// How many relays are connected right now.
fn liveRelayCount() usize {
    var n: usize = 0;
    for (0..relaySlots()) |i| {
        // A dormant seat is not a live relay whatever its last status said.
        if (relayAt(i) == null) continue;
        const state: Conn = @enumFromInt(relay_conn.g_relay_status[i].load(.monotonic));
        // Quiet counts. It holds a socket, its subscriptions are still open on
        // the relay, and a note published now goes out on it.
        if (connHolds(state)) n += 1;
    }
    return n;
}

/// The quoted note's relative timestamp, computed for the frame.
fn quoteTime(ui: *AppUi, created_at: i64) []const u8 {
    const dt = nowSeconds() - created_at;
    if (dt < 60) return "now";
    if (dt < 3600) return ui.fmt("{d}m", .{@divTrunc(dt, 60)});
    if (dt < 86_400) return ui.fmt("{d}h", .{@divTrunc(dt, 3600)});
    if (dt < 604_800) return ui.fmt("{d}d", .{@divTrunc(dt, 86_400)});
    return ui.fmt("{d}w", .{@divTrunc(dt, 604_800)});
}

/// One feed note: a bare row on the window, no card. Avatar column, then an
/// identity line (name, and the time hung to the right), the body, any image,
/// and the engagement row. The content is a fixed reading column centered in
/// the window, with a hairline under each row as the only separation. Keyed by
/// the note id so the list diff holds scroll position across reconciles.
/// Who passed this note on, above the card.
///
/// The reposter in the quiet colour over the author's row in the normal one,
/// which is the shape Amethyst uses: the wrapper's byline is greyed
/// (`NoteCompose.kt:2013`, `textColor = grayText` when `isRepost`) and the note
/// underneath is drawn as itself.
///
/// No icon. `appIcon` resolves an APP-REGISTERED name and this app registers
/// ten, none of them a repost glyph; an unregistered name draws the
/// missing-icon fallback rather than failing, so a word is the honest choice
/// until there is a glyph to use.
fn repostByline(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .gap = 0, .cross = .center }, .{
            hgap(ui, row_pad_side),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint_alt } },
                &.{.{ .text = ui.fmt("{s} reposted", .{quotePillHandle(ui, note.reposter)}), .scale = meta_scale }},
            ),
        }),
        vgap(ui, 4),
    });
}

fn noteCard(ui: *AppUi, note: *const Note) AppUi.Node {
    var node = ui.row(.{ .grow = 1, .main = .center }, .{
        ui.column(.{ .width = feed_column_width }, .{
            // A `list_item`, because that is the kind the renderer washes on
            // hover, and the row wash is the redesign's one hover state. It has
            // to be given an explicit WIDTH: a list_item sizes to its content,
            // and without one the body paragraph ran to its unwrapped width and
            // overflowed the reading column. Its children lay out on the
            // horizontal axis, so the single column below is what holds the
            // vertical stack. The inner controls (like, reply, links, the
            // picture) keep their own presses as the deeper hit targets.
            //
            // Every inset is stated once, on the axis that owns it: this column
            // carries the redesign's 12 above and 14 below, the row inside it
            // carries 16 on each side and the 12 between disc and text, and the
            // content column's own steps are 5, 8 and 10. A uniform `padding`
            // cannot express any of that, and a `gap` on the row would also apply
            // around each inset box, which is what threw the first attempt 12px
            // off the reading rail.
            ui.el(.data_row, .{ .width = feed_column_width, .padding = 0.01, .on_press = Msg{ .open_thread = note.id }, .context_menu = noteContextItems(ui, note, false), .semantics = .{ .label = "Open thread" } }, .{ui.column(.{ .gap = 0, .width = feed_column_width }, .{
                vgap(ui, row_pad_top),
                if (note.has_reposter) repostByline(ui, note) else ui.spacer(0),
                ui.row(.{ .gap = 0, .cross = .start }, .{
                    hgap(ui, row_pad_side),
                    noteAvatar(ui, note),
                    hgap(ui, avatar_to_text_gap),
                    // DEFINITE, not `grow`. `grow` hands out SPARE space and
                    // never takes any back, so a column whose widest child is
                    // already wider than the row keeps that width and pushes
                    // everything to its right off the card. This is the same
                    // width the picture and the link card already use, and it
                    // is what makes an ellipsis on anything inside possible:
                    // an ellipsis needs a box to be too small for.
                    ui.column(.{ .gap = 0, .width = picture_column_width }, .{
                        // The identity header: the name over the handle in a box
                        // the avatar's height, with the time hung top-right.
                        ui.row(.{ .gap = 6, .cross = .start }, .{
                            identityBlock(ui, note),
                            // Right-aligned in a stated column, so it ends at
                            // the card's edge whatever it says. Left to hug its
                            // text it began at a fixed x (the identity block
                            // beside it is a definite width) and stopped
                            // wherever it ran out, leaving a ragged gap after
                            // "6m via Damus" that grew as the string got
                            // shorter.
                            //
                            // ONE line, always. A paragraph in a stated width
                            // wraps, and a client name long enough to need a
                            // second line got one: "11h via Damus Notedeck"
                            // broke after "Damus" and hung "Notedeck" under it,
                            // into the handle's row. Scrolling then flickered it
                            // between two lines and one, because the row's
                            // height and the width this box is measured at are
                            // settled in different passes and a wrap sits right
                            // on the boundary between them. A single line cannot
                            // do that, and the engine trims the tail with the
                            // same metrics it paints with, so a name that does
                            // not fit ends in an ellipsis instead of moving the
                            // furniture.
                            threadTime(ui, note, isTakenAway(.replies), .{ .gap = 0, .width = time_column_width }, .{
                                ui.spacer(1),
                                ui.paragraph(
                                    .{
                                        .wrap = false,
                                        .text_alignment = .end,
                                        .style = .{ .foreground = theme.palette.text_faint_alt },
                                    },
                                    timeSpans(ui, note, meta_scale),
                                ),
                            }),
                        }),
                        vgap(ui, 5),
                        // What this answers, above the answer. Feed only: in a
                        // thread the parent is the row directly above, so the
                        // line would restate what is already on screen.
                        if (note.has_reply_parent) replyContext(ui, note) else ui.spacer(0),
                        if (note.has_reply_parent) vgap(ui, 4) else ui.spacer(0),
                        noteBody(ui, note, true),
                        // The picture. The space is reserved at the picture's own
                        // shape whether or not it has loaded, so the feed never
                        // shifts as images arrive.
                        if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                        if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                        if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                        if (verbRowShown(note)) vgap(ui, 10) else ui.spacer(0),
                        engagementRow(ui, note),
                    }),
                    hgap(ui, row_pad_side),
                }),
                vgap(ui, row_pad_bottom),
            })}),
            // The only separation between rows: a hairline. The `.separator`
            // element paints a real line (an empty column with a background does
            // not, which is why every divider was invisible before).
            ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = theme.palette.divider_row, .background = theme.palette.divider_row } }),
        }),
    });
    // The note id is masked non-negative at build time, so this cast is safe.
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// Splits rendered note text into styled runs so a note reads like a note.
/// Every interactive run takes the identity violet, because each one names a
/// person or something they wrote: an `@mention` (one weight up, the way a name
/// is set), a `#hashtag`, a bare `nostr:` event reference, and a web link. A
/// link and a hashtag carry a pressable payload (the URL, the topic), and a
/// recorded mention gets one in `contentSpansIn`. A hashtag too long to be a
/// topic carries none and stays muted rather than look pressable. The design
/// shows no hashtag, so their color follows the redesign's stated rule ("violet
/// for identity and content") rather than a shot.
/// Every span's text is a subslice of the note's own content, so nothing is
/// copied. A paragraph holds at most 32 runs, so a link-heavy note keeps its
/// tail as one plain run rather than losing it.
pub fn contentSpans(ui: *AppUi, text: []const u8) []const canvas.TextSpan {
    return contentSpansIn(ui, text, &.{}, 0);
}

/// Spans for a piece of a note's rendered content, with its mentions pressable.
///
/// `mentions` are the note's, whose offsets are relative to the whole of
/// `content_buf`; `base` is where `text` starts inside it. The body splits
/// around a quote card and trims what is left, so what reaches one paragraph is
/// usually a piece rather than the whole.
///
/// A recorded mention is authoritative and is checked before anything else. That
/// is not only about the link: the `@` heuristic below reads a mention as ending
/// at the first space, so `@Sepehr Safari` was styled as far as `@Sepehr` and the
/// surname fell out of the run. A recorded range knows exactly how long the label
/// is because it is what wrote it.
pub fn contentSpansIn(ui: *AppUi, text: []const u8, mentions: []const MentionRef, base: usize) []const canvas.TextSpan {
    @setRuntimeSafety(true); // Splits a stranger's text into runs, and does it on every rebuild.
    const max_spans = 32;
    if (text.len == 0) return &.{};
    const spans = ui.arena.alloc(canvas.TextSpan, max_spans) catch return &.{};

    var n: usize = 0;
    var i: usize = 0;
    var plain_start: usize = 0;
    // Mentions are recorded as the content is walked, so the table is in offset
    // order, and this walk is in offset order too: one cursor covers it. Scanning
    // the whole table at every byte would multiply the per-byte work in this loop
    // by the number of mentions, and this loop runs over every note on screen.
    // A piece of the body can start part-way in, so the cursor skips what is
    // behind it rather than assuming it starts at the first.
    var next: usize = 0;
    while (i < text.len) {
        while (next < mentions.len and mentions[next].off < base + i) next += 1;
        // A label straddling the end of this piece is passed over rather than
        // clipped: the fold cuts the text at a character count, so the last
        // mention before it can be half-present, and half a name is not
        // something to make pressable.
        if (next < mentions.len and mentions[next].off == base + i and mentions[next].len <= text.len - i) {
            const ref = &mentions[next];
            if (n + 2 > max_spans) break;
            if (i > plain_start) {
                spans[n] = .{ .text = text[plain_start..i] };
                n += 1;
            }
            // The same colour and weight the heuristic gives a mention, plus the
            // payload that makes it go somewhere. The renderer underlines every
            // span carrying a link, so this reads as pressable without asking.
            spans[n] = .{ .text = text[i..][0..ref.len], .color = .info, .weight = .medium, .link = ref.link() };
            n += 1;
            i += ref.len;
            plain_start = i;
            continue;
        }
        const is_url = std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://");
        const is_mention = text[i] == '@' and i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1]);
        // A hashtag is `#` + word characters at a word boundary, so `C#` and a
        // URL fragment (`…#section`) are left as plain text.
        const is_hashtag = text[i] == '#' and i + 1 < text.len and isHashtagChar(text[i + 1]) and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]));
        // A `nostr:nevent`/`note`/`naddr` reference (the first is usually lifted
        // into a quote card upstream; a second one, or one inside a quoted body,
        // still reads as a reference here). No link: there is no in-app target
        // for a bare extra ref yet.
        const is_eventref = isEventRefStart(text, i);
        if (!is_url and !is_mention and !is_hashtag and !is_eventref) {
            i += 1;
            continue;
        }
        // Two slots for this run plus the trailing plain run.
        if (n + 3 > max_spans) break;
        if (i > plain_start) {
            spans[n] = .{ .text = text[plain_start..i] };
            n += 1;
        }
        var j = i;
        if (is_hashtag) {
            // Just the tag word: trailing punctuation (`#nostr!`) stays plain.
            j = i + 1;
            while (j < text.len and isHashtagChar(text[j])) j += 1;
        } else {
            while (j < text.len and !std.ascii.isWhitespace(text[j])) j += 1;
        }
        const run = text[i..j];
        // Content color is the identity violet, reached through the `info`
        // token (a span names a token field, not a Color). A @mention
        // additionally sits one weight up, the way a name does.
        //
        // Colour and nothing else, which the renderer now honours. It used to
        // underline every span carrying a link payload whatever `underline`
        // said, so a paragraph with three URLs came out striped; leaving
        // `underline` unset stated the intent and got a hairline anyway. SDK
        // 0.9.2 made the flag mean what it says, so the intent and the pixels
        // finally agree. Mentions are marked by weight and colour, not a rule.
        // A hashtag opens its topic, so it takes the same violet as the other
        // runs that go somewhere. Only one that carries the topic does: a tag
        // too long to be a topic (`contentTags` drops it too) has nowhere to go,
        // and the violet on a run that does nothing when pressed is the trap
        // this colour must never set, so that one stays muted.
        spans[n] = if (is_url)
            .{ .text = run, .color = .info, .link = run }
        else if (is_mention)
            .{ .text = run, .color = .info, .weight = .medium }
        else if (is_hashtag) blk: {
            const link = topicLinkFor(run[1..]) orelse break :blk canvas.TextSpan{ .text = run, .color = .text_muted };
            break :blk canvas.TextSpan{ .text = run, .color = .info, .link = link };
        } else .{ .text = run, .color = .info };
        n += 1;
        i = j;
        plain_start = j;
    }
    if (plain_start < text.len and n < max_spans) {
        spans[n] = .{ .text = text[plain_start..] };
        n += 1;
    }
    return spans[0..n];
}

/// Spans for a sub-slice of `note`'s content, with the note's mentions mapped
/// onto it. `text` must be a piece of `note.content()`; anything else falls back
/// to the plain reading, since the offsets would mean nothing.
fn noteSpans(ui: *AppUi, note: *const Note, text: []const u8) []const canvas.TextSpan {
    const whole = note.content();
    const start = @intFromPtr(text.ptr);
    const first = @intFromPtr(whole.ptr);
    if (start < first or start + text.len > first + whole.len) return contentSpans(ui, text);
    return contentSpansIn(ui, text, note.mentions.all(), start - first);
}

/// The height a note's picture occupies, whether or not it has loaded. Taken
/// from the note's declared `imeta` shape, else the shape it turned out to be
/// last time it was decoded, else a gentle default. Clamped so one very tall
/// image cannot take over the feed.
pub fn pictureHeight(note: *const Note) f32 {
    // The picture spans the reading column, which is what 11o draws, and takes
    // exactly the height the note's own `imeta` implies at that width. It was
    // based on a 300px box and clamped at 320px, so a tall picture was reserved
    // at a height it never drew and the row shifted when the bytes arrived, which
    // is the whole thing a declared shape exists to prevent.
    //
    // The cap is on the ASPECT, not the pixels: a very tall picture is contained
    // rather than allowed to take over the feed, and contained at a height the
    // estimate can state exactly.
    return picture_column_width * @min(pictureAspect(note), picture_max_aspect);
}

/// The shape to draw at: what the note declares, else what this picture measured
/// when it was last decoded (remembered past its slot, so an evicted picture does
/// not shrink and shift the feed), else a landscape guess.
fn pictureAspect(note: *const Note) f32 {
    if (note.imageAt(0).aspect > 0) return note.imageAt(0).aspect;
    return recalledAspect(note.id) orelse picture_default_aspect;
}

/// A note's picture: the image once registered, or a placeholder holding the
/// exact same space while it loads. Drawn with `contain` at its own aspect, so
/// it is never stretched and stays undistorted as the window resizes. Pressing
/// it opens the viewer.
fn notePicture(ui: *AppUi, note: *const Note) AppUi.Node {
    const height = pictureHeight(note);
    const image_id = note.media_id();
    // Previews off and this one not asked for: a quiet line saying what is there
    // and what pressing it costs, not a box of reserved space for a picture that
    // is not coming.
    if (!prefs.g_media_previews and !isMediaAsked(note.id) and image_id == 0) return pictureAskChip(ui, note);
    // Asked for and not had. The striped box below means "still coming", and it
    // meant that for a 404 too: the view only asked whether the picture was
    // LOADED, so every state that is not loaded drew the same waiting frame and
    // a picture that was never going to arrive waited forever.
    if (image_id == 0 and mediaFailed(note.id)) return pictureFailedBox(ui, note, height);
    if (image_id == 0) {
        // The same box the picture will fill, striped: reserved space, not an
        // empty frame, and not a skeleton either, which reads as a row of text
        // still loading rather than as a photograph.
        return pictureBox(ui, note, height, pictureBlur(ui, note, height));
    }
    var picture = ui.image(.{ .image = image_id, .grow = 1 });
    // `ui.image` leaves the fit at `stretch`, which distorts the picture into
    // whatever box it is given (and worse as the window resizes).
    picture.widget.image_fit = .contain;
    // The picture sits in a pressable row rather than carrying the press
    // itself: an image is a leaf, and the hit target belongs on a container.
    // `quiet_hover` keeps it from washing over on hover like a list row, and the
    // box is sized to the drawn picture so only the picture itself is pressable,
    // not the empty width beside a narrow one.
    //
    // The link role is what puts the pointing hand over it: the engine follows
    // the native convention, where the hand marks a link and ordinary controls
    // keep the arrow, so this is the one role that advertises "clickable".
    return pictureBox(ui, note, height, picture);
}

/// Gap between gallery cells, and the height a multi-picture row draws at.
///
/// One height for every cell, because a row of pictures at their own aspects is
/// a ragged edge, and the point of a gallery is that it reads as one object.
/// Each picture is drawn `cover` inside its cell, which is the crop every other
/// client uses here: `contain` would letterbox portrait shots into slivers.
const gallery_gap: f32 = 4;
const gallery_height: f32 = 190;

/// A note's pictures. One fills the column at its own shape, as it always has;
/// several become a row of equal cells.
fn noteGallery(ui: *AppUi, note: *const Note) AppUi.Node {
    const count = note.imageCount();
    if (count <= 1) return notePicture(ui, note);

    // Previews off: one chip for the whole set rather than one per picture,
    // because the reader is deciding about the note, not about picture three.
    if (!prefs.g_media_previews and !isMediaAsked(note.id)) return pictureAskChip(ui, note);

    const cells = @min(count, max_note_images);
    const width = (picture_column_width - gallery_gap * @as(f32, @floatFromInt(cells - 1))) / @as(f32, @floatFromInt(cells));

    var kids: [max_note_images * 2 - 1]AppUi.Node = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        if (i > 0) {
            kids[n] = hgap(ui, gallery_gap);
            n += 1;
        }
        kids[n] = galleryCell(ui, note, i, width);
        n += 1;
    }
    return ui.row(.{ .gap = 0, .cross = .start }, .{kids[0..n]});
}

/// One cell of a gallery: the picture once it has a slot, its blurhash while it
/// does not, and a plain box when it will not come.
///
/// The blurhash matters more here than for a single picture. There are sixteen
/// registration slots in the whole app and a gallery wants several at once, so
/// the later cells of a busy screen routinely have none. A blurhash is drawn as
/// flat colour cells rather than a registered image, so it costs nothing and the
/// row still reads as photographs.
fn galleryCell(ui: *AppUi, note: *const Note, index: usize, width: f32) AppUi.Node {
    const p = theme.palette;
    const image_id = note.mediaIdAt(index);
    const failed = image_id == 0 and mediaFailed(mediaKey(note.id, index));

    const inner: AppUi.Node = if (image_id != 0) blk: {
        var picture = ui.image(.{ .image = image_id, .grow = 1 });
        // `cover`, not `contain`: every cell is the same height, so a portrait
        // shot letterboxed into one would be a sliver in a band of background.
        picture.widget.image_fit = .cover;
        break :blk picture;
    } else if (failed)
        ui.el(.panel, .{ .grow = 1, .style = .{ .background = p.surface_inset } }, .{})
    else
        blurGrid(ui, note.imageAt(index).blurhash(), gallery_height);

    return ui.el(.list_item, .{
        .width = width,
        .height = gallery_height,
        .padding = 0,
        .on_press = Msg{ .expand_image_at = .{ .note = note.id, .index = @intCast(index) } },
        .style = .{ .radius = 10, .background = p.surface_inset, .quiet_hover = true },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{inner});
}

/// A quoted note on its way: the SHAPE of the card that will replace it.
///
/// It used to be one 34px bar, which says "something is loading" and nothing
/// about what. A quote card is a face, a name and a line or two of somebody
/// else's words, so the wait looks like that: a disc, a short bar where the
/// name goes, and two body lines, the second one short the way a last line is.
/// Same height as the bar it replaces, so nothing about the row's pricing moves.
fn quoteSkeleton(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0, .cross = .start }, .{
        ui.el(.skeleton, .{ .width = 18, .height = 18, .style = .{ .radius = 999, .background = p.surface_inset } }, .{}),
        hgap(ui, 8),
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            ui.el(.skeleton, .{ .width = 96, .height = 8, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
            vgap(ui, 7),
            ui.el(.skeleton, .{ .height = 7, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
            vgap(ui, 5),
            ui.el(.skeleton, .{ .width = 148, .height = 7, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
        }),
    });
}

/// A picture that could not be had, in the space it would have taken.
///
/// The same box at the same height, because the row is priced for it and a
/// picture failing must not make the feed jump. What is IN it is different: the
/// picture glyph, a plain sentence, and the host it came from, because "this
/// one host is not answering" is the useful half and it is often the whole
/// story. Pressing opens the original, which is the one thing left that might
/// work, rather than an expanded view of nothing.
fn pictureFailedBox(ui: *AppUi, note: *const Note, height: f32) AppUi.Node {
    const p = theme.palette;
    const host = urlHost(note.imageUrl());
    return pressRow(ui, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true, .background = p.surface_inset, .radius = picture_radius, .border = p.border_hairline, .stroke_width = 1 },
        .on_press = Msg{ .open_url = note.imageUrl() },
        .semantics = .{ .role = .link, .label = "This picture could not be loaded, press to open the original", .focusable = true },
    }, .{
        ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 0 }, .{
            ui.appIcon(.{ .width = 18, .height = 18, .style = .{ .foreground = p.text_dim } }, "image"),
            vgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = "This picture would not load", .scale = mono_hint_scale }},
            ),
            if (host.len > 0) vgap(ui, 4) else ui.spacer(0),
            if (host.len > 0)
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = ui.fmt("{s} · press to open it", .{host}), .monospace = true, .scale = mono_meta_scale }},
                )
            else
                ui.spacer(0),
        }),
    });
}

/// The picture's frame: the reading column at the declared height, with the
/// radius and hairline 11o gives it, whatever is inside it, and the chips laid
/// over the corners. A `data_row` lays children out horizontally, so the chips
/// ride a stack: there is no way to place a child at a point.
fn pictureBox(ui: *AppUi, note: *const Note, height: f32, content: AppUi.Node) AppUi.Node {
    return pressRow(ui, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true, .radius = picture_radius, .border = theme.palette.border_hairline, .stroke_width = 1 },
        .on_press = Msg{ .expand_image = note.id },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{
        ui.stack(.{ .grow = 1 }, .{
            content,
            pictureChips(ui, note),
        }),
    });
}

/// What a picture is while previews are off: one quiet chip naming it and its
/// weight, which loads that one when pressed. The weight is the note's own claim
/// and may be missing, in which case the chip does not invent one.
fn pictureAskChip(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const bytes = note.imageAt(0).bytes;
    const many = note.imageCount() > 1;
    const label = if (many and bytes > 0)
        ui.fmt("{d} images · from {s} · load", .{ note.imageCount(), byteSize(ui.arena, bytes) })
    else if (many)
        ui.fmt("{d} images · load", .{note.imageCount()})
    else if (bytes > 0)
        ui.fmt("image · {s} · load", .{byteSize(ui.arena, bytes)})
    else
        "image · load";
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = picture_ask_height,
            .cross = .center,
            .on_press = Msg{ .load_image = note.id },
            .style = .{ .background = p.surface_inset, .border = p.border_chip, .radius = 6, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Load this image", .focusable = true },
        }, .{
            hgap(ui, 9),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 9),
        }),
        ui.spacer(1),
    });
}

/// What a note is while its author's content warning is up: one quiet chip
/// where the words and the pictures would be, saying so, giving the reason when
/// there is one, and uncovering THIS note when pressed.
///
/// The same chip the ask-for-a-picture line wears (inset ground, hairline,
/// mono-register text), because it is the same kind of thing: a control that
/// stands in for content the reader has not yet agreed to see. It hugs its text
/// rather than spanning the column, which also means it needs no width from the
/// caller and reads the same in a feed row, a reply and a quote card.
///
/// The warning triangle is the one warm mark in it. Nothing else here is
/// coloured, so a covered note reads as covered from across the window without
/// the reason having to be legible.
///
/// The notice is one line so a covered row's height stays known and the feed
/// keeps its rhythm. It also never wraps, so the reason shown is cut hard (see
/// `coverReasonShown`) to keep the chip inside the narrowest column it can be
/// drawn in: a nested reply, an ancestor row, a quote card.
fn coverNotice(ui: *AppUi, reason: []const u8, key: i64) AppUi.Node {
    const p = theme.palette;
    const shown = coverReasonShown(ui, reason);
    const label = if (shown.len > 0)
        ui.fmt("Content warning: {s}", .{shown})
    else
        "Content warning";
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = cover_notice_height,
            .cross = .center,
            .on_press = Msg{ .uncover_note = key },
            .style = .{ .background = p.surface_inset, .border = p.border_chip, .radius = 6, .stroke_width = 1, .quiet_hover = true },
            .semantics = .{ .role = .button, .label = "Show this note", .focusable = true },
        }, .{
            hgap(ui, 9),
            ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.status_warning } }, "alert"),
            hgap(ui, 8),
            ui.paragraph(
                .{ .wrap = false, .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 10),
            ui.paragraph(
                .{ .wrap = false, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = "Show", .weight = .medium, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 9),
        }),
        ui.spacer(1),
    });
}

/// How much of a reason the chip shows, in width units: a narrow character is
/// one and a wide one (CJK, emoji) is two, because the chip hugs its text and
/// never wraps, so the cap is on how wide the line gets and not on how many
/// codepoints it holds.
const cover_reason_units = 24;

/// `reason` cut to `cover_reason_units`, with an ellipsis where it was cut. The
/// full reason is still in the note; the chip is a label, not the place to read it.
pub fn coverReasonShown(ui: *AppUi, reason: []const u8) []const u8 {
    var i: usize = 0;
    var units: usize = 0;
    while (i < reason.len) {
        const len = std.unicode.utf8ByteSequenceLength(reason[i]) catch break;
        if (i + len > reason.len) break;
        const cp = std.unicode.utf8Decode(reason[i .. i + len]) catch break;
        const w: usize = if (cp >= 0x2E80) 2 else 1;
        if (units + w > cover_reason_units) {
            return ui.fmt("{s}\u{2026}", .{std.mem.trimEnd(u8, reason[0..i], " ")});
        }
        units += w;
        i += len;
    }
    return reason[0..i];
}

/// A decoded blurhash: the low-frequency colour of a picture, which is all a
/// blurhash carries. Drawn as a grid of flat cells rather than an image, because
/// every one of the runtime's sixteen image slots is already spent on faces and
/// photographs, and a placeholder must not evict the thing it is standing in for.
pub const Blur = struct {
    /// Row-major, `cells_x * cells_y` colours.
    cells: [blur_cells_x * blur_cells_y]canvas.Color = undefined,
    ok: bool = false,
};

/// Deliberately coarse. Every cell is a widget node, and a view past 1024 nodes
/// is REFUSED WHOLE, not degraded: six loading pictures at 8x6 came to 797 nodes
/// on their own, and a wider window mounting nine rows crossed the ceiling and
/// blanked the feed. A blurhash carries only low frequencies, so 4x3 shows what
/// it has for 19 nodes instead of 55.
const blur_cells_x = 4;
const blur_cells_y = 3;

/// blurhash's own alphabet.
fn base83(c: u8) ?f32 {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";
    const i = std.mem.indexOfScalar(u8, alphabet, c) orelse return null;
    return @floatFromInt(i);
}

fn base83Value(hash: []const u8, from: usize, len: usize) ?f32 {
    @setRuntimeSafety(true); // Slices the hash at offsets its own header implied.
    if (from + len > hash.len) return null;
    var value: f32 = 0;
    for (hash[from .. from + len]) |c| {
        const digit = base83(c) orelse return null;
        value = value * 83 + digit;
    }
    return value;
}

/// sRGB companding, the two halves of it the format needs.
fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// Decodes a blurhash into a small grid of colours. The format is a handful of
/// cosine components; sampling them at each cell's centre is the same sum the
/// reference decoder runs per pixel, at the resolution the eye gets from a
/// placeholder anyway.
pub fn decodeBlurhash(hash: []const u8) Blur {
    @setRuntimeSafety(true); // Component counts decoded out of the hash index a fixed array.
    var out: Blur = .{};
    if (hash.len < 6) return out;
    const size_flag = base83Value(hash, 0, 1) orelse return out;
    const comp_x: usize = @intFromFloat(@mod(size_flag, 9) + 1);
    const comp_y: usize = @intFromFloat(@floor(size_flag / 9) + 1);
    if (hash.len != 4 + 2 * comp_x * comp_y) return out;

    const quant_max = base83Value(hash, 1, 1) orelse return out;
    const max_ac = (quant_max + 1) / 166.0;

    // The DC term is the average colour, straight sRGB bytes.
    const dc = base83Value(hash, 2, 4) orelse return out;
    const dc_int: u32 = @intFromFloat(dc);
    var colours: [9 * 9][3]f32 = undefined;
    colours[0] = .{
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 16) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 8) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(dc_int & 255)) / 255.0),
    };

    var i: usize = 1;
    while (i < comp_x * comp_y) : (i += 1) {
        const ac = base83Value(hash, 4 + i * 2, 2) orelse return out;
        const ac_int: u32 = @intFromFloat(ac);
        colours[i] = .{
            signPow((@as(f32, @floatFromInt(ac_int / (19 * 19))) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt((ac_int / 19) % 19)) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt(ac_int % 19)) - 9) / 9, 2.0) * max_ac,
        };
    }

    for (0..blur_cells_y) |cy| {
        for (0..blur_cells_x) |cx| {
            // The centre of the cell, in the 0..1 the basis is defined over.
            const x = (@as(f32, @floatFromInt(cx)) + 0.5) / @as(f32, @floatFromInt(blur_cells_x));
            const y = (@as(f32, @floatFromInt(cy)) + 0.5) / @as(f32, @floatFromInt(blur_cells_y));
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            for (0..comp_y) |j| {
                for (0..comp_x) |k| {
                    const basis = @cos(std.math.pi * x * @as(f32, @floatFromInt(k))) *
                        @cos(std.math.pi * y * @as(f32, @floatFromInt(j)));
                    const c = colours[j * comp_x + k];
                    r += c[0] * basis;
                    g += c[1] * basis;
                    b += c[2] * basis;
                }
            }
            out.cells[cy * blur_cells_x + cx] = canvas.Color.rgba8(
                @intFromFloat(linearToSrgb(r) * 255 + 0.5),
                @intFromFloat(linearToSrgb(g) * 255 + 0.5),
                @intFromFloat(linearToSrgb(b) * 255 + 0.5),
                255,
            );
        }
    }
    out.ok = true;
    return out;
}

fn signPow(value: f32, exp: f32) f32 {
    const magnitude = std.math.pow(f32, @abs(value), exp);
    return if (value < 0) -magnitude else magnitude;
}

/// What a picture that has not arrived looks like: its own colours when the note
/// carries a blurhash, stripes when it does not.
fn pictureBlur(ui: *AppUi, note: *const Note, height: f32) AppUi.Node {
    return blurGrid(ui, note.imageBlurhash(), height);
}

/// The same, for a picture that is not the note's first: a gallery cell knows
/// its own hash and has no business asking the note for it.
fn blurGrid(ui: *AppUi, hash: []const u8, height: f32) AppUi.Node {
    if (hash.len == 0) return pictureStripes(ui, height);
    const blur = decodeBlurhash(hash);
    if (!blur.ok) return pictureStripes(ui, height);

    // Flat cells, not an image: the runtime has sixteen image slots and they are
    // all spent on faces and photographs, so a placeholder must not evict the
    // thing it stands in for. A blurhash carries only low frequencies anyway,
    // which is what a grid of them shows.
    const rows = ui.arena.alloc(AppUi.Node, blur_cells_y) catch return pictureStripes(ui, height);
    for (rows, 0..) |*row, y| {
        const cells = ui.arena.alloc(AppUi.Node, blur_cells_x) catch return pictureStripes(ui, height);
        for (cells, 0..) |*cell, x| {
            cell.* = ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = blur.cells[y * blur_cells_x + x], .radius = 0, .stroke_width = 0 },
            }, .{});
        }
        row.* = ui.row(.{ .grow = 1, .gap = 0 }, .{cells});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{rows});
}

/// The fill under a picture that has not arrived. The shot draws 45 degree
/// stripes; the canvas has no gradients at the widget level and no rotation, so
/// they run flat, which keeps what the stripes are FOR (this is a photograph
/// arriving, not a paragraph) without pretending to an angle.
fn pictureStripes(ui: *AppUi, height: f32) AppUi.Node {
    const p = theme.palette;
    // The band count is capped, so the BANDS grow instead: a stated height that
    // stopped at the cap left the bottom of a tall box as bare window inside its
    // own border.
    const count: usize = @min(@max(1, @as(usize, @intFromFloat(@ceil(height / 14)))), picture_stripe_cap);
    const bands = ui.arena.alloc(AppUi.Node, count) catch return ui.spacer(0);
    for (bands, 0..) |*b, i| {
        b.* = ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{ .background = if (i % 2 == 0) p.surface_stripe_a else p.surface_stripe_b, .radius = 0, .stroke_width = 0 },
        }, .{});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{bands});
}

/// 11o's link preview: what the page on the other end says it is. One per note,
/// under the body, and the URL stays in the text as well, because the card is a
/// courtesy and the address is the fact.
///
/// The tile is a letter, never a favicon: a favicon would want one of the
/// sixteen image slots the whole runtime has, and those belong to faces and
/// photographs.
/// How wide the text beside a link preview's tile may be.
///
/// Spelled out from the parts rather than left to `grow`, because the row's
/// other children are all fixed: the gap before the tile, the tile, the gap
/// after it, and the gap at the end. What is left is what the title and the
/// description have to live inside, and a test measures the result rather than
/// trusting this arithmetic.
const link_card_tile_size: f32 = 30;
const link_card_text_width: f32 = picture_column_width - 12 - link_card_tile_size - 10 - 12;
/// And how many characters of description fit that width at its scale. A length
/// rather than a width because the engine will not elide this one: see the call.
const link_desc_max: usize = 78;

/// A video the note carries, said plainly.
///
/// Recognition only. Plaza draws no frame and plays nothing yet: the toolkit
/// has the whole transport for it and Plaza calls none of it, and deciding who
/// owns the one player in a scrolling column is the other half of this. What
/// this fixes is that a video used to be indistinguishable from a web page, so
/// it got a page's card and a page's fetch.
///
/// The host, because that is who you are about to hand a request to, and the
/// note's own `alt` when it wrote one.
fn videoCard(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const url = note.linkUrl();
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 3),
        ui.el(.list_item, .{
            .width = picture_column_width,
            .padding = 0.01,
            .on_press = Msg{ .open_url = url },
            .style = .{ .background = p.surface_link_card, .border = p.border_chip_alt, .radius = 10, .stroke_width = 1 },
            .semantics = .{ .role = .link, .label = "Open video", .focusable = true },
        }, .{
            hgap(ui, 12),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 10),
                ui.el(.panel, .{
                    .width = 30,
                    .height = 30,
                    .padding = 0.01,
                    .style = .{ .background = p.surface_link_tile, .radius = 7, .stroke_width = 0 },
                }, .{
                    ui.column(.{ .width = 30, .height = 30, .main = .center, .cross = .center }, .{
                        ui.icon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_secondary } }, "play"),
                    }),
                }),
                vgap(ui, 10),
            }),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 10),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_body } },
                    &.{.{ .text = "Video", .weight = .medium, .scale = meta_scale }},
                ),
                vgap(ui, 2),
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                    &.{.{ .text = urlHost(url), .monospace = true, .scale = mono_meta_scale }},
                ),
                vgap(ui, 10),
            }),
            hgap(ui, 12),
        }),
    });
}

fn linkCard(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const url = note.linkUrl();
    const entry = linkFor(url);
    // Nothing to show until the page has answered. No skeleton: a card that
    // might never come is worse than a link that reads as a link.
    if (entry == null or entry.?.state != .loaded) return ui.spacer(0);
    const link = entry.?;
    const initial = std.ascii.toUpper(if (link.domain().len > 0) link.domain()[0] else '?');

    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 3),
        ui.el(.list_item, .{
            .width = picture_column_width,
            .padding = 0.01,
            // The URL slice lives in the note, which lives in the model, and the
            // opener copies it before it runs.
            .on_press = Msg{ .open_url = url },
            .style = .{ .background = p.surface_link_card, .border = p.border_chip_alt, .radius = 10, .stroke_width = 1 },
            .semantics = .{ .role = .link, .label = "Open link", .focusable = true },
        }, .{
            hgap(ui, 12),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 10),
                ui.el(.panel, .{
                    .width = 30,
                    .height = 30,
                    .padding = 0.01,
                    .style = .{ .background = p.surface_link_tile, .radius = 7, .stroke_width = 0 },
                }, .{
                    ui.column(.{ .width = 30, .height = 30, .main = .center, .cross = .center }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = ui.fmt("{c}", .{initial}), .monospace = true, .weight = .medium, .scale = meta_scale }},
                        ),
                    }),
                }),
            }),
            hgap(ui, 10),
            // A STATED width, not `grow`. `grow` hands out SPARE space and never
            // takes any back, so a child whose natural size already exceeds the
            // row has nothing to grow into and is simply left at its natural
            // size. A page title and description with `wrap = false` are as wide
            // as the sentence, which for a link preview is far wider than the
            // card, so the row overflowed the card, the card overflowed the
            // column, and the description ran off the right of the window. The
            // ellipsis never fired because ellipsis needs a box to be too small
            // FOR, and the leaf was never given one.
            ui.column(.{ .width = link_card_text_width, .gap = 0 }, .{
                vgap(ui, 10),
                ui.paragraph(
                    .{ .width = link_card_text_width, .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = link.domain(), .monospace = true, .scale = mono_chip_scale }},
                ),
                vgap(ui, 2),
                // The width is on THESE, not only on the column around them.
                // That is what the first attempt got wrong: it stated the
                // width one level up and asserted the geometry against the
                // card, which passed, while a title still ran to the window's
                // right edge and was cut off there with no ellipsis. A text
                // leaf with no wrap measures as one line at its natural width
                // whatever its ancestors say, so `.overflow = .ellipsis` had
                // nothing to elide against. Safe to state here because nothing
                // sits beside these in the column: a definite width on a leaf
                // with a neighbour would push the neighbour away instead.
                ui.text(.{
                    .width = link_card_text_width,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .size = .sm,
                    .style = .{ .foreground = p.text_link_title },
                }, link.title()),
                if (link.description().len == 0) ui.spacer(0) else vgap(ui, 2),
                // Shortened here rather than left to `.overflow`, unlike the
                // title directly above it. The engine's ellipsis works on a
                // plain `ui.text` and not on a paragraph built from SPANS: the
                // title came back correctly elided while this line, with the
                // same width and the same overflow setting, ran flat off the
                // end of the card. The span is kept because it carries the
                // smaller scale a description wants.
                if (link.description().len == 0) ui.spacer(0) else ui.paragraph(.{
                    .width = link_card_text_width,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .style = .{ .foreground = p.text_muted },
                }, &.{.{ .text = elide(ui, link.description(), link_desc_max), .scale = mono_row_scale }}),
                vgap(ui, 10),
            }),
            hgap(ui, 12),
        }),
    });
}

/// The two chips 11o lays over a picture: its declared size at the top right and
/// its alt text at the bottom left. Both read at rest, because hover cannot
/// restyle or reveal a child.
fn pictureChips(ui: *AppUi, note: *const Note) AppUi.Node {
    const dims = note.imageChipLabel(ui.arena);
    const alt = note.image_has_alt;
    if (dims.len == 0 and !alt) return ui.spacer(0);
    return ui.column(.{ .grow = 1, .gap = 0 }, .{
        ui.row(.{ .grow = 1, .main = .end, .cross = .start, .gap = 0 }, .{
            if (dims.len == 0) ui.spacer(0) else pictureChip(ui, dims, false),
            hgap(ui, picture_chip_inset),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, picture_chip_inset),
            if (!alt) ui.spacer(0) else pictureChip(ui, "ALT", true),
            ui.spacer(1),
        }),
        vgap(ui, picture_chip_inset),
    });
}

/// One chip over a picture: mono, small, on a scrim dark enough to read against
/// any photograph.
fn pictureChip(ui: *AppUi, label: []const u8, emphatic: bool) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, picture_chip_inset),
        ui.el(.panel, .{
            .padding = 0.01,
            .height = picture_chip_height,
            .style = .{ .background = p.scrim_chip, .border = p.border_chip_alt, .radius = 5, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 7),
                // A scaled span, because the 10px mono register has no size enum
                // rung. No stated width: 11o draws both of these as pills hugging
                // their text, and a fixed one made "ALT" a 194px bar across the
                // bottom of every described picture. Both labels are bounded by
                // construction, the longest being `1600×900 · 240 KB`.
                ui.paragraph(.{
                    .wrap = false,
                    .style = .{ .foreground = if (emphatic) p.text_secondary else p.text_muted_alt },
                }, &.{.{
                    .text = label,
                    .monospace = true,
                    .weight = if (emphatic) .medium else .regular,
                    .scale = mono_chip_scale,
                }}),
                hgap(ui, 7),
            }),
        }),
    });
}

/// How wide the drawn picture is: its own shape at the reserved height, never
/// wider than the card. `contain` centres a narrow picture in its box, so
/// matching the box to the picture is what keeps the press on the picture.
pub fn pictureWidth(note: *const Note) f32 {
    // The TRUE aspect, not the capped one: a picture taller than the cap is
    // drawn `contain`ed at the reserved height, so its drawn width is what the
    // shape says, and the box must be that or the gutters either side are bare
    // window inside the border, and pressable.
    const aspect = pictureAspect(note);
    if (aspect <= 0) return picture_column_width;
    // The box IS the picture: a portrait photo drawn `contain`ed inside a
    // column-wide box would leave bare window either side, inside the border,
    // and all of it pressable. Matching the box to what is drawn keeps the press
    // on the picture and the chips on its corners.
    return @min(picture_column_width, pictureHeight(note) / aspect);
}

const PlazaApp = native_sdk.UiApp(Model, Msg);

/// The keyboard, as the shell delivers it: a shortcut declared in the manifest
/// arrives here by id and becomes an ordinary message, so a key does exactly
/// what the control it stands for does, and never a second implementation of it.
///
/// What each one means depends on what is open, and that is decided in `update`
/// where the model is, not here: this only names the intent.
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "new-note")) return .open_compose;
    if (std.mem.eql(u8, name, "settings")) return .open_settings;
    if (std.mem.eql(u8, name, "open-address")) return .open_address;
    // The same message the rail's own tile sends, so the key and the tile
    // cannot drift into two behaviours.
    if (std.mem.eql(u8, name, "places-rail")) return .toggle_places_rail;
    if (std.mem.eql(u8, name, "place-bounce")) return .place_bounce;
    if (std.mem.eql(u8, name, "place-prev")) return Msg{ .place_step = -1 };
    if (std.mem.eql(u8, name, "place-next")) return Msg{ .place_step = 1 };
    return null;
}

pub fn onCommandForTest(name: []const u8) ?Msg {
    return onCommand(name);
}

/// The running app, so the key handler can read the tree the window is showing.
/// Set once in `main`, read only from the thread that delivers keys.
var g_app: ?*PlazaApp = null;

/// What Return or Space does to a focused widget the toolkit has no answer for.
///
/// The toolkit answers those two keys for its own controls and for `list_item`
/// (see `pressRow`), and for nothing else. The one thing it focuses and then
/// ignores is an inline link in a paragraph: Tab lands on a link in a note, and
/// Return does nothing. This is the one place that says what the key means
/// there, and it is what a click means: the widget's own press.
///
/// Disabled widgets are skipped, and so are the editable kinds, where Space and
/// Return are typing.
pub fn keyActivation(tree: AppUi.Tree, keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (!canvas.isWidgetActivationKey(keyboard.key)) return null;
    const id = keyboard.focused_id orelse return null;
    const widget = tree.findWidget(id) orelse return null;
    if (widget.state.disabled or canvas.isWidgetTextEntry(widget)) return null;
    return tree.msgFor(id, .press);
}

fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    const app = g_app orelse return null;
    const tree = app.tree orelse return null;
    return keyActivation(tree, keyboard);
}
pub const Effects = PlazaApp.Effects;
/// The effects type, exported so tests can exercise the fx-free slot paths.
pub const EffectsForTest = Effects;

pub fn writePendingLinkForTest(io: std.Io, dir: *std.Io.Dir, link: []const u8, now_s: i64) void {
    writePendingLinkIn(io, dir, link, now_s);
}

pub fn takeWrittenLinkForTest(io: std.Io, dir: *std.Io.Dir, buf: []u8, now_s: i64) ?[]const u8 {
    return takeWrittenLinkIn(io, dir, buf, now_s);
}

pub fn captureArgvLinkForTest(link: []const u8) void {
    if (link.len > links.g_argv_link_buf.len) return;
    @memcpy(links.g_argv_link_buf[0..link.len], link);
    links.g_argv_link_len = link.len;
}

pub fn takePendingLinkForTest(buf: []u8) ?[]const u8 {
    return takePendingLink(buf);
}

pub fn placeFeedIndexForTest() u8 {
    return places.g_place_feed;
}

pub fn setPlaceInfoForTest(state: PlaceInfo) void {
    places.g_place_info = state;
}

pub fn togglePlacesRailForTest() void {
    togglePlacesRail();
}
pub fn setRailForTest(open: bool) void {
    places.g_rail_open = open;
}

pub fn forgetPlacesForTest() void {
    forgetPlaces();
}

/// The predicate above, for the test: the arrival path it guards needs a store,
/// a relay and a link, and the decision it makes does not.
pub fn samePlaceForTest(pubkey: [32]u8, ident: []const u8) bool {
    var w: @TypeOf(places.g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    w.ident_len = @intCast(copyBounded(&w.ident_buf, ident));
    return samePlace(w);
}

/// How many remembered notes a place ARRIVING from a link inherits from the
/// room already open. The consequence, not the predicate: those ids are saved
/// onto the arriving place's row, so a room that inherits the wrong ones shows
/// another place's notes on every later visit, from the rail, forever.
pub fn arrivalInheritsRoomForTest(pubkey: [32]u8, ident: []const u8) u16 {
    var m = Place{};
    m.author = pubkey;
    m.ident_len = @intCast(copyBounded(&m.ident_buf, ident));
    var w: @TypeOf(places.g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    w.ident_len = @intCast(copyBounded(&w.ident_buf, ident));
    _ = adoptOpenRoom(w, &m);
    return m.seen_len;
}

/// Drives the REAL entry path. It spawns a worker that dials and fails without
/// a relay, which is harmless: the seeding this asserts happens before it.
pub fn startPlaceFeedForTest(i: usize) void {
    startPlaceFeed(&places.g_places[i]);
}

/// Arms the fetch a `plaza://` link arms, without the link or the sockets.
pub fn armPlaceFetchForTest(pubkey: [32]u8, ident: []const u8) void {
    var want: @TypeOf(places.g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    want.ident_len = @intCast(copyBounded(&want.ident_buf, ident));
    places.g_place_want = want;
}

/// One tick of the store-side half of that fetch.
pub fn refreshPlaceFetchForTest() void {
    _ = placeFetchStep();
}

/// The same tick with the reader's side of it: the toast a fetch that ends
/// without a place leaves.
pub fn refreshPlaceFetchNoticeForTest(model: *Model) void {
    refreshPlaceFetch(model);
}

/// The link has been followed and a copy shown, which is the state the fetch
/// window is in while it watches for a newer one.
pub fn markPlaceFetchAppliedForTest() void {
    if (places.g_place_want) |*w| w.applied = true;
}

/// Whether the window is still watching. Closed is what walking away must
/// produce: an open window re-applies its place over the room on screen.
pub fn placeFetchArmedForTest() bool {
    return places.g_place_want != null;
}
pub fn savePlacesForTest() void {
    savePlaces();
}

pub fn setPlaceLinkForTest(state: PlaceLink) void {
    setPlaceLink(state);
}

/// Runs a feed worker that belongs to a room already left, against a url that
/// fails before any socket is opened.
pub fn runStalePlaceFeedWorkerForTest() void {
    var url_buf: [place_relay_cap]u8 = undefined;
    const url = "http://not-a-relay";
    @memcpy(url_buf[0..url.len], url);
    const stale = places.g_place_gen.load(.monotonic) -% 1;
    placeFeedWorker(url_buf, url.len, undefined, 0, stale, undefined, 0);
}

/// Arrives in a place that has a named feed, which is the ordinary case.
pub fn visitPlaceWithFeedForTest(author: [32]u8, ident: []const u8, name: []const u8, feed: []const u8) void {
    visitPlaceForTest(author, ident, name);
    if (places.g_place) |*m| {
        m.feeds[0].name_len = @intCast(copyBounded(&m.feeds[0].name_buf, feed));
        m.feeds[0].relay_len = @intCast(copyBounded(&m.feeds[0].relay_buf, "wss://example.test"));
        m.feeds_len = 1;
    }
}

pub fn flushPlaceIdsForTest(now_s: i64) void {
    flushPlaceIds(now_s);
}
pub fn setPlaceHomeForTest(text: []const u8) void {
    if (places.g_place) |*m| m.home_len = @intCast(copyBounded(&m.home_buf, text));
}
pub fn setKeptPlaceSeenLenForTest(i: usize, n: u16) void {
    places.g_places[i].seen_len = n;
}

pub fn seedPlaceFeedForTest(ids: []const [32]u8) void {
    seedPlaceFeed(ids);
}
pub fn clearPlaceFeedForTest() void {
    clearPlaceFeed();
}
pub fn rememberPlaceIdsForTest() void {
    rememberPlaceIds();
}
pub fn keptPlaceSeenLenForTest(i: usize) u16 {
    return places.g_places[i].seen_len;
}
pub fn seedFromKeptPlaceForTest(i: usize) void {
    seedPlaceFeed(places.g_places[i].seen[0..places.g_places[i].seen_len]);
}

pub fn resetPlacesForTest() void {
    // The feed ids too, or one test's room leaks into the next one's.
    clearPlaceFeed();
    places.g_rail_open = false;
    places.g_place_info = .closed;
    places.g_place_flushed_at = 0;
    places.g_place_flushed_rev = 0;
    places.g_place = null;
    places.g_place_feed = 0;
    places.g_place_kept = false;
    places.g_visited = null;
    places.g_place_last = 0;
    places.g_places = @splat(.{});
    places.g_places_len = 0;
}

/// Arrives in a place the way a link does: in it, kept only if it already was.
pub fn visitPlaceForTest(author: [32]u8, ident: []const u8, name: []const u8) void {
    var m = Place{};
    m.author = author;
    m.ident_len = @intCast(copyBounded(&m.ident_buf, ident));
    m.name_len = @intCast(copyBounded(&m.name_buf, name));
    places.g_place = m;
    places.g_place_feed = 0;
    places.g_place_kept = placeIndexOf(m.author, m.ident()) != null;
}

/// Arrives in a place parsed from a real Hallway document.
///
/// The other visit helpers build a `Place` by hand, which cannot exercise the
/// fields the PARSER resolves (the colour, the avatar shape, a feed's kinds),
/// so a test using them would assert against whatever the test itself set.
pub fn visitParsedPlaceForTest(gpa: std.mem.Allocator, content: []const u8) bool {
    var m = parsePlace(gpa, content) orelse return false;
    m.author = @splat(0x7a);
    m.ident_len = @intCast(copyBounded(&m.ident_buf, "parsed"));
    places.g_place = m;
    places.g_place_feed = 0;
    places.g_place_kept = placeIndexOf(m.author, m.ident()) != null;
    return true;
}

pub fn clearActivePlaceForTest() void {
    places.g_place = null;
    places.g_place_feed = 0;
    places.g_place_kept = false;
}

pub fn identityInkForTest() canvas.Color {
    return identityInk();
}

pub fn roomVerbFillForTest() canvas.Color {
    return roomVerbFill();
}

pub fn avatarRadiusForTest(size: f32) f32 {
    return avatarRadius(size);
}

pub fn openKeptPlaceForTest(i: usize) void {
    openKeptPlace(i);
}
pub fn goToOwnPlazaForTest() void {
    goToOwnPlaza();
}
pub fn bouncePlaceForTest() void {
    bouncePlace();
}
pub fn stepPlaceForTest(delta: i8) void {
    stepPlace(delta);
}
pub fn activePlaceIndexForTest() ?usize {
    return activePlaceIndex();
}

pub fn restoreOpenPlaceForTest() void {
    restoreOpenPlace();
}

pub fn bootPlaceIndexForTest() ?usize {
    return bootPlaceIndex();
}
pub fn applyActivePlaceLineForTest(value: []const u8) void {
    applyActivePlaceLine(value);
}
pub fn visitingPlaceForTest() ?*const Place {
    return visitingPlace();
}
pub fn resumeVisitForTest() void {
    resumeVisit();
}

pub fn boot(model: *Model, fx: *Effects) void {
    // FIRST, before anything slow. On a cold launch macOS sends the Apple Event
    // moments after the app starts, so a handler installed after the store is
    // opened misses the very link that launched Plaza.
    if (has_url_scheme) plaza_url_scheme_install();
    // How the theme asks which room is open. Installed before the places are
    // loaded, so the very first frame of a restored place is already wearing its
    // colour rather than flashing porcelain for one rebuild.
    installThemeHooks();
    if (g_io) |io| {
        if (g_environ) |environ| {
            loadPlaces(io, environ);
            restoreOpenPlace();
        }
    }
    model.refresh(nowSeconds());
    // What was written but not sent when the app last closed, back in the
    // composer where it was left.
    var draft_buf: [note_content_cap]u8 = undefined;
    var warn_buf: [warning_input_capacity]u8 = undefined;
    const stashed = loadDraft(&draft_buf, &warn_buf);
    applyStashedDraft(model, stashed);
    // What was owed when the app last closed. Read before the first frame, so a
    // note written offline yesterday is visible as owed rather than lost, and
    // offered again as soon as a relay answers. Whose queue that is comes from
    // the session that was just restored; a guest starts with empty slots.
    syncOutboxOwner();
    // Local-first, all the way to the first frame: cached avatars and pictures
    // are registered here, so a returning user gets faces WITH the notes rather
    // than a tick later. Only what is on disk resolves now; the rest is fetched
    // from the first tick onward.
    wantProfilesAhead(model);
    beginImagePass();
    assignAvatarSlots(fx, model);
    scanAvatarFetches(fx);
    scanMediaFetches(fx, model);
    warmAhead(fx, model);
    scanLinkFetches(fx, model);
    scanNip05Fetches(fx);
    fx.startTimer(.{
        .key = refresh_timer_key,
        .interval_ms = refresh_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // One timer drives every playing GIF; a timer each would exhaust the table.
    fx.startTimer(.{
        .key = animation_timer_key,
        .interval_ms = animation_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.animate),
    });
    // Bring up the isolated signer; the tick health-checks it until it answers.
    spawnHelper(fx);
    // Background metadata fetching on its own cadence, off the view refresh.
    fx.startTimer(.{
        .key = profile_timer_key,
        .interval_ms = profile_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.profiles),
    });
}

/// What `plainLineBreaks` wrote, how long the whole input comes to once its
/// breaks are plain (including whatever did not fit in `out`), and whether it
/// had to change anything.
pub const PlainLineBreaks = struct { text: []const u8, full_len: usize, changed: bool };

/// Every line break that macOS draws as one and the toolkit does not lay out as
/// one becomes a plain LF: CR on its own, vertical tab, form feed, NEL (U+0085),
/// and the Unicode line and paragraph separators (U+2028, U+2029). Writes what
/// fits into `out`, never cutting a UTF-8 sequence, and counts the rest.
///
/// The toolkit breaks a line only at LF, so it lays "end.\rNext" out as one
/// word on one row. On macOS the host then draws each of those rows through
/// AppKit, which DOES break there, so the words after the break land a row
/// lower, on top of the next row. That is what made a pasted note look
/// scrambled (#165), reproduced with each of these separators by pasting into
/// the composer.
///
/// CRLF is left as it is. The layout breaks at its LF, so its CR is the last
/// byte of a row and nothing is drawn after it: it has always drawn correctly,
/// and changing it would cost the reader the caret and undo (see
/// `applyPlainEdit`) for nothing.
pub fn plainLineBreaks(in: []const u8, out: []u8) PlainLineBreaks {
    var written: usize = 0;
    var full: usize = 0;
    var changed = false;
    var i: usize = 0;
    while (i < in.len) {
        var take: usize = 1;
        var plain = false;
        switch (in[i]) {
            '\r' => plain = !(i + 1 < in.len and in[i + 1] == '\n'),
            0x0B, 0x0C => plain = true,
            0xC2 => if (i + 1 < in.len and in[i + 1] == 0x85) {
                plain = true;
                take = 2;
            },
            0xE2 => if (i + 2 < in.len and in[i + 1] == 0x80 and (in[i + 2] == 0xA8 or in[i + 2] == 0xA9)) {
                plain = true;
                take = 3;
            },
            else => {},
        }
        // Anything else is copied with the rest of its UTF-8 sequence, so a
        // full `out` never ends halfway through a character.
        if (!plain) take = @min(std.unicode.utf8ByteSequenceLength(in[i]) catch 1, in.len - i);
        const len: usize = if (plain) 1 else take;
        // Written only while everything before it was: the text is always a
        // prefix of the whole.
        if (written == full and written + len <= out.len) {
            if (plain) out[written] = '\n' else @memcpy(out[written..][0..len], in[i..][0..len]);
            written += len;
        }
        changed = changed or plain;
        full += len;
        i += take;
    }
    return .{ .text = out[0..written], .full_len = full, .changed = changed };
}

/// Applies an edit to a multi-line text buffer with its line breaks made plain
/// first (see `plainLineBreaks`). Returns what an insert asked to add, counted
/// after that, so a caller can tell how much a clamp refused.
///
/// The editor keeps its own copy of the text, and it holds far more than this
/// buffer does. Whenever this buffer ends up with different text from what the
/// editor inserted, because a separator was replaced or because the paste was
/// cut to fit, the editor takes this text and puts ITS caret at the end: the
/// toolkit gives an app no way to say where the caret should be. So this
/// buffer's caret goes to the end too, or the next key would land where the
/// reader cannot see it. A cut can also split a CRLF and leave a lone CR at the
/// cut, so the whole text is made plain again then. The editor's undo history
/// for the box starts again from there, which is the price of both.
///
/// An insert refused outright changes nothing here, and the editor keeps its
/// own copy, so nothing is moved.
fn applyPlainEdit(comptime capacity: usize, buffer: *canvas.TextBuffer(capacity), edit: canvas.TextInputEvent) usize {
    switch (edit) {
        .insert_text => |inserted| {
            var scratch: [capacity]u8 = undefined;
            const plain = plainLineBreaks(inserted, &scratch);
            const before_len = buffer.len;
            const before_selection = buffer.selection;
            buffer.apply(.{ .insert_text = plain.text });
            // Anything past `scratch` is more than the whole buffer holds, so
            // it is a clamp even when the buffer took all of `plain.text`.
            const clamped = buffer.truncated or plain.full_len > plain.text.len;
            buffer.truncated = clamped;
            const refused = clamped and buffer.len == before_len and
                std.meta.eql(buffer.selection, before_selection);
            if (!refused and (plain.changed or clamped)) {
                var whole: [capacity]u8 = undefined;
                buffer.set(plainLineBreaks(buffer.text(), &whole).text);
            }
            return plain.full_len;
        },
        else => {
            buffer.apply(edit);
            return 0;
        },
    }
}

/// Puts text into a buffer with its line breaks made plain, for text that
/// arrives other than by typing: a draft restored from disk, which an older
/// Plaza may have saved with a CR in it.
pub fn setPlain(comptime capacity: usize, buffer: *canvas.TextBuffer(capacity), text: []const u8) void {
    var scratch: [capacity]u8 = undefined;
    buffer.set(plainLineBreaks(text, &scratch).text);
}

/// Keeps the open level current, once a tick: what a backfill has since put in
/// the store, the loading line, and the relative times.
///
/// Every kind of level a fetch fills has to be named here (the bookmark list
/// fires no fetch, so it has nothing to hear). The store-moved guard below skips
/// the read when nothing arrived, which is right, but it means a level that is
/// left out never hears about its own fetch: the topic view was, so what its
/// relays sent was ingested and then never drawn, and its loading line never
/// ended.
fn refreshOpenLevel(model: *Model, now: i64) void {
    const level_count = if (g_store) |st| (st.eventCount() catch g_last_level_count) else g_last_level_count;
    if (level_count != g_last_level_count) {
        g_last_level_count = level_count;
        model.refreshThreadNotes(now);
        // And the open person's notes, for the same reason and with
        // the same consequence if it is missed: without this the
        // backfill this screen fires never appears, and the quiet
        // line saying they have written nothing stays up over a
        // store that has since filled with their notes.
        model.refreshProfileNotes(now);
        model.refreshTopicNotes(now);
    }
    // Relative times were a side effect of the rebuild, so they have
    // to be kept up now that the rebuild is conditional. "2m" going
    // stale is exactly the sort of thing a guard like this breaks
    // quietly.
    for (model.thread_notes[0..model.thread_notes_len]) |*note| note.setTime(now);
    if (model.viewing_profile != null) {
        model.thread_loading = model.thread_notes_len == 0 and
            navigation.g_thread_done_seq.load(.acquire) < model.thread_seq;
    } else if (model.viewing_thread != 0) {
        // Every tick, not only when the store moved: a thread nobody answered
        // leaves the store unchanged, and that is exactly when the skeletons
        // have to give way to "No replies yet".
        model.settleThreadLoading(now);
    }
    model.settleTopicLoading(now);
}

/// Forgets the store count the last tick saw, so a test's first tick reads.
pub fn forgetLevelCountForTest() void {
    g_last_level_count = std.math.maxInt(usize);
}

/// One tick of the open level's upkeep, for a test.
pub fn refreshOpenLevelForTest(model: *Model, now: i64) void {
    refreshOpenLevel(model, now);
}

/// Marks the fetch for generation `seq` as finished, the way its worker does
/// when every relay has answered, for a test that has no worker.
pub fn finishLevelFetchForTest(seq: u64) void {
    navigation.g_thread_done_seq.store(seq, .release);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) {
                const now = nowSeconds();
                // A `plaza://` link somebody clicked, drained once per tick.
                // Polling rather than an effect because the Apple Event lands
                // on the main thread outside the SDK's event loop entirely,
                // so there is nothing to subscribe to.
                var link_buf: [2048]u8 = undefined;
                if (takePendingLink(&link_buf)) |link| handlePlazaLink(model, fx, link);
                refreshPlaceFetch(model);
                // Beside it, and after it: a place arriving from a link moves
                // the reader into a room, and that is a walk away from a note
                // they asked for a moment earlier.
                refreshEventFetch(model);
                refreshAddressFetch(model);
                searchTick(model, awakeMs());
                flushPlaceIds(now);
                model.refresh(now);
                // Keep the open thread's replies current: late replies appear and
                // relative times stay fresh, the same cadence as the feed.
                //
                // Only when the store actually moved, which is the guard the
                // feed rebuild ten lines up has always had and these two never
                // did. Unconditional, they were a full `store.query`, a
                // `collectThreadIds` closure walk that queries again per level,
                // and a re-parse of every reply into a fresh `Note` — once a
                // second, on the render thread, for as long as a thread or a
                // profile stayed open, almost always to produce exactly the
                // list that was already on screen.
                //
                // The open paths call these directly, so a thread still fills
                // the moment it is opened; this only skips the repeat.
                refreshOpenLevel(model, now);
                // And the bottom of the open person's list, which may be in view
                // with nothing left to scroll that would ask for more.
                loadAtProfileBottom(model);
                // Anything still owed goes back out whenever a relay is up: this
                // is the drain, and it is idempotent, since an entry already in
                // flight is skipped.
                // The Edit profile sheet waits on a real answer before it lets
                // anything be published over a profile it has not read.
                if (model.editing_profile and model.profile_stage == .absent and !model.profile_seeded) {
                    // Absent was what the relays had said by then, not a promise.
                    // A profile that arrives after it is shown rather than left
                    // for a Save to merge blank fields into.
                    const gpa = std.heap.page_allocator;
                    if (ownProfileJson(gpa)) |own| {
                        defer freeOwnProfile(gpa, own);
                        seedProfileFields(model, own.json, true);
                        model.profile_stage = .have;
                        model.profile_confirm_new = false;
                    }
                } else if (model.editing_profile and model.profile_stage == .fetching) {
                    const gpa = std.heap.page_allocator;
                    if (ownProfileJson(gpa)) |own| {
                        defer freeOwnProfile(gpa, own);
                        // A profile arriving a few seconds late must not replace
                        // the sentence the reader is in the middle of typing,
                        // which is what the second argument protects. It used to
                        // be all or nothing: one typed character skipped the
                        // seeding of ALL THREE fields, and the flip to `.have`
                        // below ran anyway, so Save lit up over two empty fields
                        // that had never been read and the merge deleted them.
                        if (!model.profile_seeded) seedProfileFields(model, own.json, true);
                        model.profile_stage = .have;
                    } else if (ownProfileAnswered()) {
                        model.profile_stage = .absent;
                    } else if (now - model.profile_asked_at > own_profile_wait_s) {
                        model.profile_stage = .unread;
                    }
                }
                // A logout's reset that never reached the daemon, re-sent. Left
                // undone, the daemon keeps the key the reader just left and the
                // health-check would sign them back into it.
                // Their published relay list, taken on this thread so no ingest
                // thread ever swaps the pool out from under the others.
                _ = adoptRelayList();
                // Starts the clock on reading the reader's own lists at sign-in
                // rather than the first time a control asks about them.
                if (activePubkey() != null) _ = ownListsRead();
                flushRelayList(fx, now);
                // At most one write a second, and only when something changed.
                if (inboxNeedsSave()) saveInbox();
                // Before anything reads or walks the queue: the slots belong
                // to whoever is signed in now, and a sign-in or a logout since
                // the last tick means they change hands here.
                syncOutboxOwner();
                if (liveRelayCount() > 0) drainOutbox(std.heap.page_allocator);
                sweepOutbox(now);
                // At most one write a second, and only when something changed.
                if (drafts.g_draft_dirty) {
                    drafts.g_draft_dirty = false;
                    saveDraft(model.draft(), draftWarningOf(model));
                }
                const counts = outboxCounts();
                model.outbox_pending = counts.trying;
                model.outbox_stuck = counts.stuck;
                // The banner is about a note that was dropped, and a note can
                // still be dropped by the paths that reach `ingestAndPublish`
                // without going through the composer. It used to latch for the
                // life of the process: the queue drained, later posts landed,
                // and the status bar went on saying a note could not be queued
                // for the rest of the run. It retires when there is room again,
                // which is the condition it was reporting the absence of.
                if (outbox.g_outbox_overflow.load(.monotonic) and outboxHasRoom()) {
                    outbox.g_outbox_overflow.store(false, .monotonic);
                }
                model.outbox_overflowed = outbox.g_outbox_overflow.load(.monotonic);
                if (outbox.g_outbox_rev.load(.monotonic) != outbox.g_outbox_saved_rev) {
                    outbox.g_outbox_saved_rev = outbox.g_outbox_rev.load(.monotonic);
                    saveOutbox();
                }
                // Start any pending image fetches (needs effects, so here, not
                // in refresh). The feed reads loaded images at render time.
                wantProfilesAhead(model);
                beginImagePass();
                assignAvatarSlots(fx, model);
                scanAvatarFetches(fx);
                scanBannerFetch(fx, model);
                scanPlaceLogo(fx, model);
                scanMediaFetches(fx, model);
                warmAhead(fx, model);
                scanLinkFetches(fx, model);
                scanNip05Fetches(fx);
                // A list whose private half Notary has not opened yet. Reading
                // it needs the keyholder now that no secret lives here.
                scanPrivateHalves(fx);
                // Complete a like a guest reached for, now that they have signed
                // in and the feed above has rebuilt.
                drivePendingIntent(model, fx);
                // A held note whose clock has run out. This is the only place a
                // note is signed without a press, and the press it stands in for
                // already happened: the reader asked, and then did not take it
                // back.
                if (postIsDue(compose.g_post_due_s, nowSeconds())) _ = firePost(model, fx, compose.g_held_route);
                if (postIsDue(compose.g_reply_due_s, nowSeconds())) fireReply(model, fx, compose.g_held_route);
                // Retire timed-out or refused signer requests, restoring a lost
                // draft to the composer (this thread owns it).
                if (keyholder.g_signer_kind == .remote) scanPendingRemote(model, fx);
                driveBunkerConnect(model);
                // The same question for the built-in signer, which had no
                // answer to it at all: a sign that failed simply ended.
                if (keyholder.g_signer_kind == .helper) scanHelperSign(model);
                // A relay that asked who the reader is, and was told yes: get
                // the answer signed. The reader thread sends it.
                driveRelayAuth(fx);
                // A picture on its way: a token that came back, a send that
                // finished, a signer that never answered.
                driveUpload(model);
                // Health-check the signer daemon until the loopback IPC answers,
                // then fire any queued key setup.
                pollHelper(fx);
                driveHelperSetup(fx);
                // Whether a newer Plaza exists, on its own slow clock. Returns
                // at once when the reader has switched it off.
                maybeCheckForUpdate(fx);
                // A toast lives a few seconds, then the tick retires it.
                if (model.toast_until != 0 and nowSeconds() >= model.toast_until) {
                    model.toast_until = 0;
                    model.toast_len = 0;
                }
            }
        },
        .animate => |t| {
            if (t.outcome == .fired) advanceAnimations(fx, model);
        },
        .profiles => |t| {
            if (t.outcome == .fired) {
                // Quotes still re-arm on a round counter. Profiles no longer
                // need to: each pubkey carries its own last-tried stamp and
                // backs off on its own, so asking every tick costs nothing for
                // the ones that are waiting and retries the rest when due.
                profile_cache.g_profile_round +%= 1;
                quote_cache.g_quote_round +%= 1;
                if (quote_cache.g_quote_round % quote_rearm_rounds == 0) rearmWantedQuotes();
                requestWantedProfiles();
                requestWantedQuotes();
            }
        },
        .private_half => |response| handlePrivateHalf(response),
        .private_seal => |response| handlePrivateSeal(model, fx, response),

        .helper_line => |line| {
            // The daemon says where it landed, and until it does there is
            // nowhere to send anything. Everything else it prints is for a
            // human reading a terminal.
            const text = std.mem.trim(u8, line.line, " \t\r\n");
            if (!std.mem.startsWith(u8, text, helper_port_prefix)) return;
            const rest = std.mem.trim(u8, text[helper_port_prefix.len..], " \t");
            const port = std.fmt.parseInt(u16, rest, 10) catch return;
            if (port == 0) return;
            keyholder.g_helper_port = port;
            // It came up and said where it is, so the budget for starting it
            // again is whole. Without this, three sign-outs across one long
            // session would spend it and the fourth would be refused.
            keyholder.g_helper_restarts = 0;
        },

        .helper_exited => |e| {
            if (e.reason != .exited) std.debug.print("plaza: [helper] exited\n", .{});
            // Start it again. Signing out from the key window ends the process
            // deliberately, and a crash ends it accidentally; either way this
            // app used to be left holding a port number for something that was
            // gone, unable to sign anything until it was restarted.
            //
            // The port and the identity go with it. The new one comes up
            // locked, which is the truthful state and the one the reader is
            // then asked to leave.
            keyholder.g_helper_port = 0;
            keyholder.g_helper_state.store(@intFromEnum(HelperState.starting), .release);
            if (keyholder.g_helper_restarts < helper_restart_limit) {
                keyholder.g_helper_restarts += 1;
                spawnHelper(fx);
            } else {
                keyholder.g_helper_state.store(@intFromEnum(HelperState.unreachable_), .release);
                setToast(model, "Your keyholder keeps stopping. Reopen the app.");
            }
        },
        .notary_exited => |e| handleNotaryExited(model, e),
        .helper_pubkey => |response| {
            handleHelperPubkey(model, response);
            // A queued setup fires the moment the daemon is reachable.
            driveHelperSetup(fx);
            // And a locked keyholder asks for its passphrase rather than just
            // reporting that it is locked.
            driveUnlockPrompt(fx);
        },
        .helper_setup => |response| handleHelperSetup(model, response),
        .helper_signed => |response| handleHelperSigned(response),
        .avatar_fetched => |response| handleAvatarFetched(fx, response),
        .avatar_warmed => |response| handleAvatarWarmed(response),
        .media_warmed => |response| handleMediaWarmed(response),
        .banner_fetched => |response| handleBannerFetched(fx, response),
        .draft_edit => |edit| {
            // What this edit meant to add, before it is clamped. Only an insert
            // can overflow; every other edit is rejected whole.
            const before = model.draft_buffer.len;
            const wanted = applyPlainEdit(compose_capacity, &model.draft_buffer, edit);
            // The buffer's own words for this flag are "loud seam for paste:
            // check after applying a clipboard insert", and nothing here ever
            // did. A paste past the cap lost the overflow in silence: the
            // counter read "0 left", which says the composer is exactly full,
            // not that a third of what you just pasted is gone.
            if (model.draft_buffer.truncated and wanted > 0) {
                model.draft_dropped = wanted -| (model.draft_buffer.len -| before);
            } else if (wanted > 0) {
                // A later paste that DID fit answers the earlier warning.
                model.draft_dropped = 0;
            }
            // A new query is a new question, so a dismissal only covers the one
            // the reader dismissed. Without this, putting the picker away once
            // would put it away for the rest of the note.
            model.mention_dismissed = false;
            // Marked, not written: the tick flushes it. Saving on CLOSE alone
            // was the wrong half, because the state a writer is in when the
            // machine sleeps or the app is killed is the sheet OPEN.
            drafts.g_draft_dirty = true;
            // The user is composing again: retire a stale "signer didn't respond".
            remote_signer.g_remote_sign_notice.store(false, .release);
            keyholder.g_helper_sign_notice.store(false, .release);
        },
        .post => {
            // Every precondition, before anything is signed or said. A message
            // is reachable from more places than the button that names it: the
            // field's own submit chord, a future menu entry, a key. Publishing
            // is not something to do on a model that was not showing a
            // composer, and a draft restored from disk must never leave the
            // machine without the reader seeing it in one.
            if (!model.composing or model.stage != .ready or model.is_guest()) return;
            if (model.draft_empty()) return;
            // Nothing after this runs unless the note actually went to a
            // signer. It used to run regardless: the composer emptied, the draft
            // file was deleted and the toast said "Posted" for a sign that had
            // been refused before it left the process.
            // Held, not sent. Nothing is signed until the clock runs out, and
            // pressing again takes it back while that is still true.
            if (compose.g_post_due_s != 0) {
                compose.g_post_due_s = 0;
                setToast(model, "Kept here.");
                return;
            }
            if (compose.g_post_delay_s > 0) {
                // The room it is being written in, taken NOW. The pause exists
                // so the reader can change their mind, and they are free to walk
                // somewhere else while it counts.
                compose.g_held_route = routeForOpenPlace();
                compose.g_post_due_s = nowSeconds() + compose.g_post_delay_s;
                return;
            }
            _ = firePost(model, fx, null);
        },
        .open_compose => {
            // The keyboard reaches past the sheet: this is a declared shortcut,
            // so the shell delivers it whatever is on screen, and `appView` draws
            // the sheet ABOVE the composer. Without this the composer arms itself
            // unseen and appears unbidden the moment the sheet is dismissed.
            model.notifications_open = false;
            // The gate is on press, not on sight: a guest reaching for the
            // composer is exactly first intent, so the sheet rises and
            // remembers what was reached for.
            if (model.is_guest()) {
                model.joining = true;
                model.pending = .post;
            } else model.composing = true;
        },
        .open_person => |pk| openPerson(model, pk),
        .follow_person => |direction| {
            if (model.is_guest()) {
                // REMEMBERED, not merely gated. This press used to open the sheet
                // and forget what it was for, so signing in landed the reader on
                // the feed still not following the person they had just asked to
                // follow, with nothing to say why.
                if (model.viewing_profile) |who| model.pending = .{ .follow = who };
                model.joining = true;
                return;
            }
            const who = model.viewing_profile orelse return;
            if (direction == 1 and askFreshFirst(model, .{ .action = .follow, .who = who })) return;
            sayFollowWrite(model, writeFollow(fx, who, direction == 1), direction == 1);
        },
        .mute_person => |direction| {
            // A guest has nothing to mute FROM: there is no list to splice and
            // no key to sign with. Unlike a follow, this is not worth
            // remembering across a sign-in either, since muting is about a feed
            // they do not have yet.
            if (model.is_guest()) {
                model.joining = true;
                return;
            }
            const who = model.viewing_profile orelse return;
            if (direction == 1 and askFreshFirst(model, .{ .action = .mute, .who = who })) return;
            sayMuteWrite(model, writeMute(fx, who, direction == 1), direction == 1);
        },
        .choose_home_scope => |which| {
            model.menu = .none;
            setHomeScope(if (which == 0) .starter_pack else .following);
            // Remembered, or the choice lasts until the next launch and the
            // reader has to make it again every morning.
            saveSettings();
        },
        .profile_tab => |which| {
            model.profile_tab = if (which == 1) .replies else .notes;
            model.profile_autofill = 0;
        },
        .toggle_notifications => {
            model.notifications_open = !model.notifications_open;
            // Opening IS reading: the reader is looking at them. The mark moves
            // to the newest item held, never to the wall clock, so a backfill
            // arriving later with older stamps is not born already read.
            if (model.notifications_open) {
                inboxMarkAllRead();
                markInboxDirty();
            }
        },
        .close_notifications => model.notifications_open = false,
        .notifications_tab => |which| {
            model.notifications_everyone = which == 1;
            // The other tab holds a different set, so page four of this one is
            // not page four of that one.
        },
        .notifications_read_all => {
            inboxMarkAllRead();
            markInboxDirty();
        },
        .follow_author => |press| {
            // A guest reaching for Follow is first intent, the same as reaching
            // for the composer: the sheet rises rather than the press failing.
            // Remembered for whoever the menu was opened on, in the feed as well
            // as in a thread: it used to be kept only inside a thread, and then
            // for the thread's root rather than for the person clicked.
            if (press.direction == 0 or model.is_guest()) {
                model.pending = .{ .follow = press.who };
                model.joining = true;
                return;
            }
            if (press.direction == 1 and askFreshFirst(model, .{ .action = .follow, .who = press.who })) return;
            sayFollowWrite(model, writeFollow(fx, press.who, press.direction == 1), press.direction == 1);
        },
        .open_profile_edit => openProfileEdit(model),
        .close_profile_edit => {
            model.editing_profile = false;
            uploads.g_profile_upload_unsaved = false;
            // A picture on its way to the avatar or banner has nowhere to go
            // once the sheet is closed.
            if (uploads.g_upload) |job| {
                if (job.target != .note) uploadCancel(model);
            }
        },
        .profile_name_edit => |edit| model.profile_name_buffer.apply(edit),
        .profile_about_edit => |edit| _ = applyPlainEdit(profile_about_capacity, &model.profile_about_buffer, edit),
        .profile_picture_edit => |edit| model.profile_picture_buffer.apply(edit),
        .profile_website_edit => |edit| model.profile_website_buffer.apply(edit),
        .profile_banner_edit => |edit| model.profile_banner_buffer.apply(edit),
        .profile_lud16_edit => |edit| model.profile_lud16_buffer.apply(edit),
        .profile_nip05_edit => |edit| model.profile_nip05_buffer.apply(edit),
        .profile_save => {
            uploads.g_profile_upload_unsaved = false;
            saveProfile(model, fx);
        },
        .retry_own_lists => {
            retryOwnListsRead();
            setToast(model, "Asking your relays again.");
        },
        .profile_retry => {
            model.profile_confirm_new = false;
            forgetOwnProfileAnswer();
            model.profile_asked_at = nowSeconds();
            model.profile_stage = .fetching;
            startOwnProfileFetch();
        },
        .auth_allow => |i| authAnswer(i, true),
        .auth_deny => |i| authAnswer(i, false),
        .auth_cycle => |i| authCycle(i),
        .helper_auth_signed => |response| handleHelperAuthSigned(response),
        .upload_pick => |which| {
            const target = std.enums.fromInt(UploadTarget, which) orelse return;
            uploadPick(model, fx, target);
        },
        .upload_go => uploadGo(model, fx),
        .upload_retry => uploadRetry(model, fx),
        .upload_cancel => uploadCancel(model),
        .upload_alt_edit => |edit| model.upload_alt_buffer.apply(edit),
        .blossom_edit => |edit| {
            model.blossom_buffer.apply(edit);
            // Typing answers whatever the field last complained about.
            model.blossom_error = .none;
        },
        .blossom_add => blossomAdd(model, fx),
        .blossom_remove => |i| blossomRemove(model, fx, i),
        .relay_cycle => |i| {
            cycleRelay(i);
            // The ack bits name slots, and this slot's direction just changed.
            relayListEdited();
        },
        .relay_remove => |i| {
            // The last relay stays. With none, nothing is read and nothing is
            // written, and the empty list would be what gets published over the
            // one this account already has. Replacing it is add-then-remove.
            if (!mayRemoveRelay()) {
                model.relay_last = true;
                model.relay_full = false;
                model.relay_error = false;
                return;
            }
            removeRelay(i);
            // They just did what the full-pool message asked for.
            model.relay_full = false;
            model.relay_last = false;
            relayListEdited();
        },
        .relay_edit => |edit| {
            model.relay_buffer.apply(edit);
            // Typing is the reader answering what the field asked. Keeping the
            // old complaint under a field they are fixing makes the app look
            // like it is not watching.
            model.relay_error = false;
            model.relay_full = false;
            model.relay_last = false;
        },
        .relay_add => {
            const typed = std.mem.trim(u8, model.relay_buffer.text(), " \t\r\n");
            // Both flags answer THIS press. A full-pool message left standing
            // after the reader removed a relay would hide the real reason the
            // next add failed.
            model.relay_full = false;
            model.relay_error = false;
            model.relay_last = false;
            if (!isRelayUrl(typed)) {
                model.relay_error = true;
                return;
            }
            if (addRelay(typed, true, true) == null) {
                model.relay_full = true;
                return;
            }
            model.relay_full = false;
            model.relay_buffer.clear();
            relayListEdited();
        },
        .relay_suggest => |i| {
            var buf: [96]u8 = undefined;
            const url = relaySuggestionCopy(i, &buf) orelse return;
            if (addRelay(url, true, true) == null) {
                // A silent press is the app refusing without saying so.
                model.relay_full = true;
                return;
            }
            model.relay_full = false;
            model.relay_last = false;
            forgetRelaySuggestion(i);
            relayListEdited();
        },
        .insert_mention => |pubkey| insertMention(model, pubkey),
        .close_compose => {
            // A held note goes with the sheet. Leaving it armed would publish,
            // seconds later, the note whose composer the reader had just
            // dismissed, and the draft below would be the text of something
            // already on its way out.
            compose.g_post_due_s = 0;
            model.composing = false;
            model.draft_dropped = 0;
            // Closing the sheet stashes what is in it. The words survived a
            // closed sheet already; this is what carries them past a quit.
            saveDraft(model.draft(), draftWarningOf(model));
        },
        .open_join => model.joining = true,
        // Enter: keep this place. That is all it does, and it is private.
        .place_enter => {
            if (places.g_place) |m| {
                if (places.g_places_len < places.g_places.len and placeIndexOf(m.author, m.ident()) == null) {
                    places.g_places[places.g_places_len] = m;
                    places.g_places_len += 1;
                    places.g_place_kept = true;
                    places.g_place_last = places.g_places_len - 1;
                    // In the list now, so it is no longer the visit the rail
                    // holds a seat for.
                    places.g_visited = null;
                    savePlaces();
                    // Entering is the moment the rail has something to show,
                    // so it shows it: the place the reader just kept, now with
                    // a seat of its own. It is off until then, because a column
                    // that can only say it is empty is worse than no column.
                    showPlacesRail();
                    saveSettings();
                }
            }
        },
        // Leave: out of the list, and out of the place. The link still works.
        .place_leave => {
            if (places.g_place) |m| {
                if (placeIndexOf(m.author, m.ident())) |i| {
                    for (i..places.g_places_len - 1) |j| places.g_places[j] = places.g_places[j + 1];
                    places.g_places_len -= 1;
                    savePlaces();
                }
            }
            places.g_place = null;
            places.g_place_feed = 0;
            places.g_place_kept = false;
            places.g_place_info = .closed;
            // The visiting seat is deliberately NOT cleared here, and it took a
            // probe to see why: entering already clears it, and the seat only
            // ever holds a place that is not in the list, so a place being left
            // cannot be the one sitting in it. A second clear for a case that
            // cannot happen is a line no test can ever fail on.
            clearPlaceFeed();
            feed_state.g_feed_rebuild_all.store(true, .release);
            saveSettings();
        },
        .toggle_places_rail => togglePlacesRail(),
        .open_place_info => places.g_place_info = .open,
        .close_place_info => places.g_place_info = .closed,
        .toggle_bookmark => |note_id| {
            const note = model.noteById(note_id) orelse return;
            const adding = !isBookmarked(note.event_id);
            if (adding and askFreshFirst(model, .{ .action = .bookmark, .note_id = note_id })) return;
            sayBookmarkWrite(model, writeBookmark(fx, note.event_id, adding), adding);
        },
        .bookmark_privately => |note_id| {
            const note = model.noteById(note_id) orelse return;
            if (askFreshFirst(model, .{ .action = .bookmark_privately, .note_id = note_id })) return;
            // A seal is a round trip, so nothing is said until it lands: the
            // toast comes from `finishPrivateBookmark`, or from the refusal.
            switch (writePrivateBookmark(fx, note.event_id, true)) {
                .published => {},
                else => |outcome| sayBookmarkWrite(model, outcome, true),
            }
        },
        .open_bookmarks => openBookmarks(model),
        .delete_note_request => |id| model.deleting_note = id,
        .delete_note_cancel => model.deleting_note = null,
        .fresh_list_cancel => model.fresh_ask = null,
        .fresh_list_confirm => {
            const ask = model.fresh_ask orelse return;
            model.fresh_ask = null;
            // Said before anything is written: the question was put while every
            // relay had finished, and the yes is only taken if that still holds,
            // and only for the account it was asked about.
            const still_me = if (activePubkey()) |me| std.mem.eql(u8, &me, &ask.of) else false;
            // The list turned up while the question was open: the write below
            // splices onto it like any other, and no yes is recorded, so nothing
            // is left armed to start one from nothing later.
            const arrived = still_me and listHeld(ask.kind());
            if (!still_me or (!arrived and !confirmStartFresh(ask.kind()))) {
                setToast(model, "Your relays changed meanwhile. Nothing changed.");
                return;
            }
            switch (ask.action) {
                .follow => sayFollowWrite(model, writeFollow(fx, ask.who, true), true),
                .mute => sayMuteWrite(model, writeMute(fx, ask.who, true), true),
                .bookmark => {
                    const note = model.noteById(ask.note_id) orelse return;
                    sayBookmarkWrite(model, writeBookmark(fx, note.event_id, true), true);
                },
                .bookmark_privately => {
                    const note = model.noteById(ask.note_id) orelse return;
                    switch (writePrivateBookmark(fx, note.event_id, true)) {
                        .published => {},
                        else => |outcome| sayBookmarkWrite(model, outcome, true),
                    }
                },
                .add_media_server => sayBlossomAdd(model, writeBlossomServers(fx, ask.server(), null)),
            }
        },
        .delete_note_confirm => {
            const id = model.deleting_note;
            model.deleting_note = null;
            if (id) |note_id| deleteNote(model, fx, note_id);
        },
        .place_leave_request => places.g_place_info = .leaving,
        .place_leave_cancel => places.g_place_info = .open,
        .place_resume => resumeVisit(),
        // No `showPlacesRail` here: the press came FROM the rail, so it is
        // already out, and forcing it would undo a fold the reader just did.
        .place_open => |i| openKeptPlace(i),
        .place_bounce => bouncePlace(),
        .place_step => |delta| stepPlace(delta),
        .close_join => {
            if (bunkerConnecting()) abandonRemoteSigner(.none);
            model.joining = false;
            model.bunker_mode = false;
            // Dismissing the sheet is an answer: they chose not to sign in, so
            // the verb they reached for is dropped rather than lying in wait to
            // fire at some later sign-in they made for another reason.
            model.pending = .none;
        },
        .join_create => {
            model.joining = false;
            // `g_identity_minted_here` is NOT set here. It says the key provably
            // has no history, which is what lets a contact list be published
            // without reading one back first, and at this point there is no key
            // at all: the ceremony can still fail, and the reader can still go
            // and import an account with eight hundred follows instead. It is set
            // when a mint is CONFIRMED, in handleNotaryExited and in
            // handleHelperSetup's create branch.
            beginCreate(model, fx);
        },
        .open_notary_import => {
            // Key material never enters Plaza: the Notary window takes the
            // paste and hands it to the daemon; Plaza signs in when the key
            // appears (handleHelperPubkey). If the window binary is missing,
            // fall back to the in-Plaza field rather than a dead button.
            model.joining = false;
            // Whatever a previous press left behind, this is not a mint. Both
            // flags are the reader's answer to "where does this key come from",
            // and they just answered differently.
            keyholder.g_ceremony = .none;
            keyholder.g_ceremony_adopted = false;
            own_lists.g_identity_minted_here = false;
            // And a sign-out earlier in this run latched adopt-on-appear off.
            //
            // The ceremony happens in the other process and exits 0 for an
            // import, so `handleNotaryExited` classifies it as "not a mint" and
            // signs nobody in: the health check is the ONLY thing that carries
            // the result back. A latch left over swallows the whole import. The
            // key lands in the daemon, the poll refuses it once a second, and the
            // reader sits in guest mode until they quit and reopen.
            //
            // `beginCreate` drops it for the create ceremony with a comment
            // saying it has to do by hand what `queueHelperSetup` would have
            // done. This is the third spawn site and it never got that line, so
            // "Create your identity" after a sign-out worked and "Bring your key"
            // was dead, which is what made it look intermittent: the latch is
            // false at launch, so it only bites on a run where something signed
            // out first. The pubkey latch below it is what still keeps the key
            // that just LEFT from walking back in.
            keyholder.g_logged_out = false;
            // No fallback to a Plaza field. There is no field in this app that
            // can take a key, so dropping to one would be offering a screen
            // that refuses whatever is typed into it.
            if (!ceremonyCanTakeKey()) setToast(model, "Notary is missing from this install.") else if (!spawnNotaryWindow(fx, .import_key)) setToast(model, "Your keyholder is starting. Try again shortly.");
        },
        .keep_browsing => {
            model.stage = .ready;
            model.pending = .none;
        },
        .open_bunker => {
            model.bunker_mode = true;
            keyholder.g_ceremony = .none;
            keyholder.g_ceremony_adopted = false;
            own_lists.g_identity_minted_here = false;
        },
        .close_bunker => {
            if (bunkerConnecting()) abandonRemoteSigner(.none);
            model.bunker_mode = false;
            model.login_buffer.clear();
            login.g_login_error.store(@intFromEnum(LoginError.none), .release);
        },
        .open_address => {
            // Cmd+L with the field already up leaves it as it is: what is typed
            // in it and what that found. Starting over would empty the list
            // under a term that is still there, and never ask the relays for it.
            if (!model.address_open) {
                model.address_error = .none;
                searchOpen();
            }
            model.address_open = true;
            // The row that opens this lives in the account menu, and a menu
            // left standing under a sheet is a menu the reader has to dismiss
            // twice.
            model.menu = .none;
        },
        .close_address => closeAddress(model),
        .address_edit => |edit| {
            model.address_buffer.apply(edit);
            // Typing IS the answer to the refusal, so the refusal goes now
            // rather than on the next submit. A red line under a field the
            // reader is already fixing is describing a string that is gone.
            model.address_error = .none;
            searchOnEdit(model);
        },
        .address_submit => submitAddress(model, fx),
        .search_pick => |pubkey| searchPick(model, pubkey),
        .nip05_found => |response| handleNip05Found(model, response),
        .dismiss_guest_strip => model.guest_strip_dismissed = true,
        // A trigger toggles its own menu and replaces any other, so the chrome
        // never shows two floating surfaces at once.
        .toggle_menu => |which| model.menu = if (model.menu == which) .none else which,
        // Reading a different feed of the SAME place. Nothing is re-fetched and
        // the place does not change: only the socket moves, and the room's list
        // is rebuilt because the notes in it are about to mean something else.
        .place_feed => |i| {
            model.menu = .none;
            const m = places.g_place orelse return;
            if (i >= m.feeds_len or i == places.g_place_feed) return;
            places.g_place_feed = i;
            startPlaceFeed(&places.g_place.?);
            feed_state.g_feed_rebuild_all.store(true, .release);
        },
        .close_menu => model.menu = .none,
        .toggle_relays_paused => {
            model.relays_paused = !model.relays_paused;
            setRelaysPaused(model.relays_paused);
            model.menu = .none;
        },
        // The feed's own list holds the scroll, and there is no API to set an
        // offset, so "newest" is the reconcile that puts the newest note back at
        // the top: the same thing the tick does, asked for on purpose.
        // There is no API to set a list's scroll offset, so this cannot scroll
        // the feed. What it CAN do is make sure nothing is stale before the
        // reader looks: force the next tick to rebuild from the store.
        .show_more_replies => model.thread_page[model.currentLevel()] += 1,
        .toggle_outside_replies => {
            const level = model.currentLevel();
            model.thread_outside_open[level] = !model.thread_outside_open[level];
        },
        .jump_to_newest => {
            invalidateFeed();
            model.menu = .none;
            // The press rebuilds the feed from what the store holds, which is
            // instant and changes nothing a reader can see when they are already
            // caught up. Without a word that reads as a button that did nothing.
            setToast(model, "Feed refreshed");
        },
        .copy_nevent => |id| {
            const note = model.noteById(id) orelse return;
            var addr_buf: [note_address_cap]u8 = undefined;
            const addr = noteAddress(&addr_buf, note, hint_cap) orelse return;
            writeClipboardText(fx, copy_nevent_key, addr);
            setToast(model, "Address copied");
        },
        // njump renders any nostr event as a web page, which is how a note is
        // shared with someone who is not on nostr yet.
        .place_logo_fetched => |response| handlePlaceLogoFetched(fx, response),
        .open_place_handler => |id| {
            const note = model.noteById(id) orelse return;
            const place = activePlace() orelse return;
            const h = place.handlerFor(1) orelse return;
            // The pattern was checked at parse time and carries exactly one
            // `{e}`. What goes in its place is written here as hex from the id
            // this app already holds, so nothing a stranger typed reaches the
            // address.
            var id_hex: [64]u8 = undefined;
            hexLower(&id_hex, note.event_id);
            const pattern = h.pattern();
            const at = std.mem.indexOf(u8, pattern, "{e}") orelse return;
            var url_buf: [place_handler_url_cap + 64]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "{s}{s}{s}", .{
                pattern[0..at],
                &id_hex,
                pattern[at + 3 ..],
            }) catch return;
            openExternally(fx, url);
        },
        .open_web => |id| {
            const note = model.noteById(id) orelse return;
            var addr_buf: [note_address_cap]u8 = undefined;
            const addr = noteAddress(&addr_buf, note, hint_cap) orelse return;
            // The base is validated at parse time (`isSafeShareUrl`) and the
            // menu row already named the host, so by here the only question
            // left is whether it ends in the separator.
            const base = shareBase();
            var url_buf: [512]u8 = undefined;
            const url = if (std.mem.endsWith(u8, base, "/"))
                std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base, addr }) catch return
            else
                std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ base, addr }) catch return;
            openExternally(fx, url);
        },
        // Quoting is composing with the note already referenced. The composer
        // opens holding a `nostr:nevent…`, which `contentTags` turns into the
        // `q` tag at publish, so the reference in the text and the tag on the
        // event can never disagree: they are derived from the same bytes.
        .quote_note => |id| {
            if (model.is_guest()) {
                model.joining = true;
                model.pending = .post;
                return;
            }
            const note = model.noteById(id) orelse return;
            // One relay, not two: this address is typed into the draft and
            // stays there as text, and the `q` tag derived from it carries one.
            var addr_buf: [note_address_cap]u8 = undefined;
            const addr = noteAddress(&addr_buf, note, 1) orelse return;
            // Appended, not overwritten. Something half-written in the composer
            // is the reader's, and a quote arriving on top of it would be this
            // app deciding their draft was worth less than its own convenience.
            const existing = model.draft_buffer.text();
            var line: [compose_capacity]u8 = undefined;
            const sep: []const u8 = if (existing.len == 0) "" else "\n\n";
            const text = std.fmt.bufPrint(&line, "{s}{s}nostr:{s}", .{ existing, sep, addr }) catch return;
            model.draft_buffer.set(text);
            model.viewing_thread = 0;
            model.composing = true;
        },
        // Switching somebody off, or back on. Keyed on the pubkey rather than a
        // position, because the list is re-derived from the text every frame
        // and an index would point at somebody else the moment the draft is
        // edited above it.
        .toggle_mention_off => |pubkey| {
            for (model.mentions_off[0..model.mentions_off_len], 0..) |off, i| {
                if (!std.mem.eql(u8, &off, &pubkey)) continue;
                model.mentions_off[i] = model.mentions_off[model.mentions_off_len - 1];
                model.mentions_off_len -= 1;
                return;
            }
            if (model.mentions_off_len < model.mentions_off.len) {
                model.mentions_off[model.mentions_off_len] = pubkey;
                model.mentions_off_len += 1;
            }
        },
        .close_mentions => model.mention_dismissed = true,
        .copy_note_text => |id| {
            // The words as the note wrote them, not as the feed renders them:
            // a paste that came back with `@name` where the author typed a
            // `nostr:` reference is not the note, it is a screenshot of one.
            const note = model.noteById(id) orelse return;
            fx.writeClipboard(.{ .key = copy_note_text_key, .text = note.content() });
            setToast(model, "Copied");
        },
        .name_edit => |edit| model.name_buffer.apply(edit),
        .name_save => {
            model.naming = false;
            // Nothing typed means nothing to publish. Writing an empty kind:0
            // would replace whatever profile the key already has with a blank
            // one, which is the replaceable-event footgun in miniature.
            if (model.name_empty()) {
                replayPending(model);
                return;
            }
            publishName(model, fx);
            setToast(model, "Name set");
            replayPending(model);
        },
        .name_skip => {
            model.naming = false;
            // Skipping is a decision not to publish this name, so the text goes
            // with it. Kept, it came back in the sheet the next time the beat
            // armed, on a DIFFERENT key, where Enter alone would publish it: the
            // Done button is deliberately never disabled.
            model.name_buffer.clear();
            replayPending(model);
        },
        .backup_now => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
            enterSettings(model);
        },
        .backup_later => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
        },
        .create_identity => beginCreate(model, fx),
        .login_edit => |edit| model.login_buffer.apply(edit),
        .login_submit => {
            login.g_login_error.store(@intFromEnum(LoginError.none), .release);
            const raw = std.mem.trim(u8, model.login_buffer.text(), " \t\r\n");
            switch (classifyLogin(raw)) {
                // A secret key, pasted into a client. Plaza does not take it,
                // and does not take it INTO MEMORY either: the text stays in
                // the field the reader typed it in, and the reader is sent to
                // the app that holds keys.
                //
                // Refusing rather than accepting is the whole shape of this
                // change. A client that accepts an nsec is a client holding the
                // one thing that cannot be replaced if it leaks, and every
                // other app on the machine can read what this one writes down.
                .nsec => {
                    login.g_login_error.store(@intFromEnum(LoginError.key_goes_to_notary), .release);
                    if (!spawnNotaryWindow(fx, .import_key)) setToast(model, "Your keyholder is starting. Try again shortly.");
                },
                // Pair with the external signer from the bunker URL; on success
                // the feed comes up and posts route through it. A bad URL keeps
                // us on onboarding with an error (see `login_status`).
                .bunker => {
                    // One connection at a time: a second press would replace the
                    // pairing the first is still waiting on.
                    if (bunkerConnecting()) return;
                    // Not signed in yet. The sheet stays up saying "Connecting
                    // to your signer…" and `driveBunkerConnect` finishes the
                    // sign-in on the signer's answer, or reports why not.
                    _ = connectRemoteSigner(raw);
                },
                .invalid => login.g_login_error.store(@intFromEnum(LoginError.format), .release),
            }
        },
        .open_settings => enterSettings(model),
        .proxy_edit => |edit| {
            model.proxy_buffer.apply(edit);
            model.proxy_saved = false;
            model.proxy_invalid = false;
        },
        .proxy_save => {
            const typed = std.mem.trim(u8, model.proxy_buffer.text(), " \t\r\n");
            // Empty is a choice (load originals); anything else has to be an
            // address. Kept in the field so it can be fixed rather than retyped.
            if (typed.len != 0 and !isMediaProxyUrl(typed)) {
                model.proxy_invalid = true;
                model.proxy_saved = false;
                return;
            }
            model.proxy_invalid = false;
            setMediaProxy(typed);
            saveSettings();
            model.proxy_saved = true;
            // Retry anything that failed to load under the previous setting.
            retryFailedImages();
        },
        .client_tag_toggle => {
            setClientTag(!clientTag());
            saveSettings();
        },
        .post_delay_cycle => {
            // Off, five, ten, and round. A cycle rather than a field: there are
            // only a few useful answers and none of them is worth a keyboard.
            compose.g_post_delay_s = switch (compose.g_post_delay_s) {
                0 => 5,
                5 => 10,
                else => 0,
            };
            // Turning it off must not strand a note that is already waiting on
            // a clock nothing will read again.
            if (compose.g_post_delay_s == 0) compose.g_post_due_s = 0;
            saveSettings();
        },
        .proxy_toggle => {
            setMediaProxyOn(!mediaProxyOn());
            saveSettings();
            // Every picture's URL is built from this, so what is on screen was
            // fetched under the old answer. Retrying the ones that failed is the
            // point of the switch: turning the proxy off is how somebody fixes a
            // blank picture, and it would be a strange switch that left it blank.
            retryFailedImages();
        },
        .direct_fallback_toggle => {
            setMediaDirectFallback(!mediaDirectFallback());
            saveSettings();
            if (mediaDirectFallback()) retryFailedImages();
        },
        .hide_toggle => |i| {
            if (i < hideables.len) {
                setHidden(@enumFromInt(i), !hiding.g_hidden[i]);
                saveSettings();
            }
        },
        .previews_toggle => {
            setMediaPreviews(!mediaPreviews());
            saveSettings();
            // Turning it back on should fill the feed in without a restart.
            if (mediaPreviews()) {
                retryFailedImages();
                scanAvatarFetches(fx);
                scanMediaFetches(fx, model);
                warmAhead(fx, model);
                scanLinkFetches(fx, model);
            }
        },
        .sensitive_toggle => {
            setShowSensitive(!showSensitive());
            saveSettings();
            // Turning the warnings off uncovers every pending picture at once,
            // so fill the feed in without waiting for the next tick.
            if (showSensitive()) {
                scanMediaFetches(fx, model);
                scanLinkFetches(fx, model);
            }
        },
        .uncover_note => |key| {
            uncoverNote(key);
            // The pictures and the link card were held back, not just hidden:
            // ask for them now rather than on the next tick.
            scanMediaFetches(fx, model);
            scanLinkFetches(fx, model);
        },
        .warn_toggle => {
            model.warn_on = !model.warn_on;
            if (!model.warn_on) model.warn_buffer.clear();
            drafts.g_draft_dirty = true;
        },
        .warn_edit => |edit| {
            model.warn_buffer.apply(edit);
            drafts.g_draft_dirty = true;
        },
        .media_fetched => |response| handleMediaFetched(fx, response),
        .nip05_verified => |response| handleNip05Fetched(response),
        .link_fetched => |response| handleLinkFetched(response),
        .update_checked => |response| handleUpdateChecked(response),
        .open_update => {
            // The release page: the notes and the downloads are both on it, so
            // "what is in it" and "where do I get it" are one press.
            const url = pendingUpdateUrl();
            if (url.len == 0) return;
            openExternally(fx, url);
            // Put away on the press. Somebody who has gone to look does not
            // need the line still there when they come back.
            updates.g_update_dismissed = true;
        },
        .dismiss_update => updates.g_update_dismissed = true,
        .update_check_toggle => {
            setUpdateCheck(!updateCheckOn());
            saveSettings();
        },
        // A paragraph carries one link handler, so a mention arrives here beside
        // the ordinary links. Its payload is not a URL and never reaches the
        // browser; see `mention_link_tag`.
        .open_url => |url| {
            // Checked before the mention form and before the browser: all three
            // ride one message, and only the sentinel tells them apart.
            if (topicLinkValue(url)) |topic| {
                openTopic(model, topic);
            } else if (mentionLinkPubkey(url)) |pubkey| openPerson(model, pubkey) else openExternally(fx, url);
        },
        .expand_image => |note_id| {
            model.expanded_note = note_id;
            model.expanded_image = 0;
        },
        .expand_image_at => |what| {
            model.expanded_note = what.note;
            model.expanded_image = what.index;
        },
        .load_image => |note_id| {
            askForMedia(note_id);
            scanMediaFetches(fx, model);
        },
        .close_image => model.expanded_note = null,
        .open_notary_window => if (!spawnNotaryWindow(fx, .status)) setToast(model, "Your keyholder is starting. Try again shortly."),
        // Deliberately empty: see `Msg.absorb_press`. The press has already done
        // its work by the time it arrives here, which was to stop somewhere.
        .absorb_press => {},
        .like => |note_id| toggleLike(model, fx, note_id),
        .repost => |note_id| repost(model, fx, note_id),
        .open_thread => |note_id| openThread(model, note_id),
        .open_event => |id| {
            // The sheet closes on the PRESS, before the navigation is attempted,
            // never on arrival. Every route out of here has an early return in
            // front of it (a store miss for a note nobody fetched, an identity
            // check for a person already on screen), and each one returns BEFORE
            // anything that could close the sheet. Closing on arrival therefore
            // left it up in exactly the cases where the reader has least idea why
            // nothing moved.
            leaveNotifications(model);
            openEvent(model, id);
        },
        // A held reply belongs to the thread being left. Leaving it armed would
        // publish it into a conversation the reader had walked away from,
        // seconds later; `parkReplyDraft` stops it and keeps the text.
        .close_thread => closeThread(model),
        .go_home => goHome(model),
        .reply_edit => |edit| _ = applyPlainEdit(compose_capacity, &model.reply_buffer, edit),
        .reply_submit => {
            // The one verb that was gated nowhere: a guest could type a reply and
            // press send, and `publishReply` would reach for a signer that does
            // not exist and return, losing nothing but doing nothing and saying
            // nothing either.
            if (model.is_guest()) {
                if (model.viewing_thread != 0) model.pending = .{ .reply = model.viewing_thread };
                model.joining = true;
                return;
            }
            // The same pause a note gets, for the same reason: a reply is exactly
            // as final, and the setting says notes without meaning only notes.
            if (compose.g_reply_due_s != 0) {
                compose.g_reply_due_s = 0;
                setToast(model, "Kept here.");
                return;
            }
            if (compose.g_post_delay_s > 0) {
                compose.g_held_route = routeForOpenPlace();
                compose.g_reply_due_s = nowSeconds() + compose.g_post_delay_s;
                return;
            }
            fireReply(model, fx, null);
        },
        .toggle_expand => |note_id| toggleExpanded(note_id),
        .settings_scrolled => |scroll| model.settings_scroll_y = scroll.offset_y,
        .feed_scrolled => |scroll| {
            model.feed_scroll = scroll;
            // Load what just came into view without waiting for the next tick:
            // hand avatar ids to the newly-visible authors, then their faces and
            // pictures.
            wantProfilesAhead(model);
            assignAvatarSlots(fx, model);
            scanAvatarFetches(fx);
            scanMediaFetches(fx, model);
            // The band beyond the new viewport, which is the whole point of
            // running this on a scroll rather than only on the tick.
            warmAhead(fx, model);
            scanLinkFetches(fx, model);
        },
        .load_older => {
            // One more page from the store, up to what the feed can hold.
            // No ceiling to stop at. The store answers with what it has, and
            // `notes_len` lands wherever that is; asking for more than exists
            // simply returns the same feed and the reader has reached the end
            // of what this app has been told about.
            const held = model.notes_len;
            model.feed_limit += feed_page;
            invalidateFeed();
            model.refresh(nowSeconds());
            // The store had no more to give, so ask the relays for what came
            // before the oldest note in hand. Store first, network second.
            if (model.notes_len == held and model.notes_len > 0 and !feedEndReached()) {
                fetchOlderNotes(model.notes[model.notes_len - 1].created_at - 1);
            }
        },
        .profile_older => loadOlderProfile(model),
        .close_settings => leaveSettings(model),
        // The bare npub stays an npub. It is the account's identifier and the
        // form every tool that takes a key accepts, so it carries no relays; the
        // form that does is `copy_nprofile`, from the account menu.
        .copy_npub => {
            const pk = activePubkey() orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const npub = nostr.nip19.encodeNpub(fba.allocator(), pk) catch return;
            writeClipboardText(fx, copy_npub_key, npub);
            setToast(model, "npub copied");
        },
        .copy_nprofile => {
            const pk = activePubkey() orelse return;
            var addr_buf: [note_address_cap]u8 = undefined;
            const addr = profileAddress(&addr_buf, pk) orelse return;
            writeClipboardText(fx, copy_nprofile_key, addr);
            model.menu = .none;
            setToast(model, "Profile address copied");
        },
        .logout_request => {
            model.logout_pending = true;
            // The question is taller than the button it replaces and sits at the
            // very foot of the page, so it opens below the window's edge. The
            // scroll view clamps this to the end of the content.
            model.settings_scroll_y = settings_scroll_end;
        },
        .logout_cancel => model.logout_pending = false,
        .logout_confirm => performLogout(model, fx),
    }
}

/// Shows a small confirming toast for a few seconds (the tick retires it).
/// Says what a follow press did, when it did not do the obvious thing.
///
/// Silent on success, because the button moving IS the answer and a toast on
/// every press would be noise. Not silent on a refusal: `writeFollow` has four
/// of those, all reachable, and the reader used to get a button that stayed
/// where it was and no reason at all. The most ordinary one is pressing Follow
/// in the first seconds after opening the app, before this account's own list
/// has come back from the relays.
/// Closes the notifications sheet on the way into a level, and remembers whether
/// the sheet is where that level's Back should land.
///
/// Only from the feed. Once a level is open, Back returns to it before anything
/// else, and the flag already says how the reader reached the bottom of the
/// stack: a thread opened from the sheet, then its author, then Back, is that
/// thread again, and Back from there is the sheet. Rewriting the flag on the
/// way to the author used to turn that last Back into the feed.
pub fn leaveNotifications(model: *Model) void {
    if (!model.levelOpen()) model.notifications_return = model.notifications_open;
    model.notifications_open = false;
}

pub fn sayFollowWrite(model: *Model, outcome: FollowWrite, following: bool) void {
    switch (outcome) {
        .published => if (following) setToast(model, "Following"),
        // Nothing changed because nothing needed to. Saying so would be noise.
        .nothing_to_do => {},
        .signer_busy => setToast(model, "Your signer is busy. Try that again in a moment."),
        .no_list_yet => setToast(model, noListToast("follow list")),
        // The guard fired, which means the list this app was about to publish
        // was not the list it meant to. Saying "try again" would be wrong: the
        // right move is to leave it alone until the real list is back.
        .would_shrink => setToast(model, "That would change several names. Nothing sent."),
        .failed => setToast(model, "That did not save, and nothing was published."),
    }
}

/// What a bookmark write did, in the reader's terms.
fn sayBookmarkWrite(model: *Model, outcome: BookmarkWrite, adding: bool) void {
    switch (outcome) {
        .published => setToast(model, if (adding) "Bookmarked" else "Bookmark removed"),
        .nothing_to_do => {},
        .signer_busy => setToast(model, "Your signer is busy. Try that again in a moment."),
        .no_list_yet => setToast(model, noListToast("bookmarks")),
        // Waiting is a delay and says so. Declined has already asked again on
        // this press, so it says where to approve it. Unreadable is a limit, so
        // it does not say "try again": the right move is to leave the list
        // alone, because writing without the half would erase every private
        // bookmark in it. All three stay inside the toast's 48 bytes, so none
        // is cut.
        .private_half_waiting => setToast(model, "Opening your private bookmarks. Try again soon."),
        .private_half_declined => setToast(model, "Signer declined. Asked again, approve it there."),
        .private_half_unreadable => setToast(model, "Cannot open private bookmarks. Nothing was sent."),
        .failed => setToast(model, "That did not save, and nothing was published."),
    }
}

/// What a mute write did, in the reader's terms.
fn sayMuteWrite(model: *Model, outcome: MuteWrite, muting: bool) void {
    switch (outcome) {
        .published => setToast(model, if (muting) "Muted" else "Unmuted"),
        .nothing_to_do => {},
        .signer_busy => setToast(model, "Your signer is busy. Try that again in a moment."),
        .no_list_yet => setToast(model, noListToast("mute list")),
        // Waiting is a delay and says so. Declined has already asked again on
        // this press, so it says where to approve it. Unreadable is the one
        // message about a limit rather than a delay, so it does not say "try again":
        // trying again will do the same thing. The reader's private mutes are
        // safe precisely because nothing was published. All three stay inside
        // the toast's 48 bytes, so none is cut.
        .private_half_waiting => setToast(model, "Opening your private mutes. Try again shortly."),
        .private_half_declined => setToast(model, "Signer declined. Asked again, approve it there."),
        .private_half_unreadable => setToast(model, "Cannot read your private mutes. Nothing changed."),
        .would_shrink => setToast(model, "That would change several names. Nothing sent."),
        .failed => setToast(model, "That did not save, and nothing was published."),
    }
}

pub fn sayMuteWriteForTest(model: *Model, outcome: MuteWrite, muting: bool) void {
    sayMuteWrite(model, outcome, muting);
}

pub fn sayBookmarkWriteForTest(model: *Model, outcome: BookmarkWrite, adding: bool) void {
    sayBookmarkWrite(model, outcome, adding);
}

/// Puts `text` on the clipboard. A test build records it instead, because the
/// effect queue behind `fx` does not exist there and the text is the thing worth
/// checking: what Plaza hands another client.
fn writeClipboardText(fx: *Effects, key: u64, text: []const u8) void {
    if (builtin.is_test) {
        g_last_clipboard_len = copyBounded(&g_last_clipboard, text);
        return;
    }
    fx.writeClipboard(.{ .key = key, .text = text });
}
var g_last_clipboard: [note_address_cap]u8 = undefined;
var g_last_clipboard_len: usize = 0;
pub fn lastClipboardForTest() []const u8 {
    return g_last_clipboard[0..g_last_clipboard_len];
}

/// Every sentence `noListToast` can say, for the test that checks each fits.
pub fn noListToastsForTest() [9][]const u8 {
    var out: [9][]const u8 = undefined;
    var n: usize = 0;
    inline for (.{ "follow list", "mute list", "bookmarks" }) |what| {
        for ([_]OwnListsRead{ .reading, .incomplete, .none_found }) |read| {
            out[n] = noListToastIn(what, read);
            n += 1;
        }
    }
    return out;
}

pub const place_looking_toast_for_test = place_looking_toast;

pub fn setToast(model: *Model, text: []const u8) void {
    const n = @min(text.len, model.toast_buf.len);
    @memcpy(model.toast_buf[0..n], text[0..n]);
    model.toast_len = n;
    model.toast_until = nowSeconds() + 3;
}

/// Puts Settings away. Shared by its own Close and by anything opened over it
/// that goes somewhere, because the page it goes to is drawn under Settings.
pub fn leaveSettings(model: *Model) void {
    model.logout_pending = false;
    model.stage = .ready;
}

pub const ProfileStage = enum { fetching, absent, unread, have, saving, sent, failed };

/// Which key in the profile object the sheet's one Name field stands for. NIP-01
/// has `name` (a handle) and `display_name` (a fuller name), and some clients
/// still write the legacy `displayName`. The sheet edits whichever one the
/// reader's profile actually uses.
pub const ProfileNameKey = enum { display_name, display_name_legacy, name };

pub fn noteOwnContactsAnsweredForTest(pk: [32]u8) void {
    noteOwnContactsAnswered(pk);
}

// There was a `g_own_relays_answered` here, set by the first EOSE from any relay
// and read as permission to publish a kind:10002. It is GONE rather than merely
// unused: an inference that wrong, left sitting in the file under a reassuring
// name, is one grep away from becoming a gate again. `canWriteRelayList` is the
// rule now, and the reason is written there.

/// This account's newest stored event of `kind`, its tags flattened to one
/// string. For tests that need to see what a publish actually WROTE rather than
/// whether it returned true: a splice that quietly drops half the list still
/// publishes, so the return value proves nothing about what went out.
/// This account's newest stored event of `kind`, its CONTENT. For the one
/// property that tags cannot show: that an encrypted half nobody here reads was
/// carried through a write rather than replaced with nothing.
pub fn ownRecordContentForTest(gpa: std.mem.Allocator, kind: u16) ?[]u8 {
    const own = ownRecordJson(gpa, kind) orelse return null;
    defer freeOwnProfile(gpa, own);
    return gpa.dupe(u8, own.json) catch null;
}

pub fn ownRecordTagsJoinedForTest(gpa: std.mem.Allocator, kind: u16) ?[]u8 {
    const own = ownRecordJson(gpa, kind) orelse return null;
    defer freeOwnProfile(gpa, own);
    var out = std.ArrayList(u8).empty;
    for (own.tags) |tag| {
        for (tag) |field| {
            out.appendSlice(gpa, field) catch return null;
            out.append(gpa, ' ') catch return null;
        }
        out.append(gpa, '\n') catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Publishes one event the way any press does, so a test can ask what actually
/// went out rather than what a helper built.
pub fn signAndPublishForTest(fx: *Effects, created: i64, kind: u16, tags: []const nostr.event.Tag, content: []const u8) void {
    const gpa = std.heap.page_allocator;
    const owned = gpa.dupe(u8, content) catch return;
    signAndPublish(fx, gpa, created, kind, tags, owned, false, .none, null);
}

pub fn activePubkeyForTest() ?[32]u8 {
    return activePubkey();
}

pub fn forgetOwnProfileAnswerForTest() void {
    forgetOwnProfileAnswer();
}

/// Records an answer the way the worker's `defer` does.
pub fn recordOwnProfileAnswerForTest(pk: [32]u8, answered: bool) void {
    lockOwnProfile();
    own_profile.g_own_profile_asked_for = pk;
    own_profile.g_own_profile_answered.store(answered, .release);
    unlockOwnProfile();
}

pub fn ownProfileAnsweredForTest() bool {
    return ownProfileAnswered();
}

pub fn seedProfileFieldsForTest(model: *Model, json: []const u8, keep_typed: bool) void {
    seedProfileFields(model, json, keep_typed);
}

/// The merge, exposed so a test can prove what survives it. This is the whole
/// safety argument of the Edit profile sheet in one function.
pub fn mergeProfileJsonForTest(gpa: std.mem.Allocator, existing: []const u8, model: *const Model) ?[]u8 {
    return mergeProfileJson(gpa, existing, model);
}

/// Drives the name beat's whole write, not just its merge. The tags it forwards
/// are invisible to `mergeNameJsonForTest`, which only sees the content.
pub fn publishNameForTest(model: *Model, fx: *Effects) void {
    publishName(model, fx);
}

pub fn mergeNameJsonForTest(gpa: std.mem.Allocator, existing: []const u8, name: []const u8) ?[]u8 {
    return mergeNameJson(gpa, existing, name);
}

pub fn askVerdictForTest(msg: nostr.message.RelayMessage) []const u8 {
    return @tagName(askVerdict(msg));
}

/// The replay seam, exercised without disk or relays. For tests.
pub fn replayPendingForTest(model: *Model) void {
    replayPending(model);
}

/// Restores a helper identity from a session pubkey hex. For tests.
pub fn restoreHelperForTest(pubkey_hex: []const u8) bool {
    return restoreHelperIdentity(pubkey_hex);
}

/// Sets what the create ceremony has reported, which is the only thing that
/// tells an appearing key apart from any other. For tests.
pub fn setCeremonyForTest(state: enum { none, running, created }) void {
    keyholder.g_ceremony = switch (state) {
        .none => .none,
        .running => .running,
        .created => .created,
    };
    keyholder.g_ceremony_adopted = false;
}

/// Parks the daemon health flag at "unreachable", so a queued setup stays queued
/// instead of reaching for an effects layer a unit test does not have. For tests.
pub fn setHelperUnreachableForTest() void {
    keyholder.g_helper_state.store(0, .release);
    keyholder.g_helper_setup = .none;
    keyholder.g_helper_pending_in_flight = .none;
}

pub fn ceremonyOwesNameForTest() bool {
    return keyholder.g_ceremony_adopted;
}

pub fn identityMintedForTest() bool {
    return own_lists.g_identity_minted_here;
}

/// Delivers the ceremony window's exit, which is how Plaza learns what it did.
/// For tests.
pub fn handleNotaryExitedForTest(model: *Model, e: native_sdk.EffectExit) void {
    handleNotaryExited(model, e);
}

/// Delivers a daemon /pubkey answer, which is how a key made or imported in the
/// other process reaches Plaza. For tests.
pub fn handleHelperPubkeyForTest(model: *Model, response: native_sdk.EffectResponse) void {
    handleHelperPubkey(model, response);
}

/// Starts connecting to a bunker the way `connectRemoteSigner` does, without a
/// socket or a thread: the connection state is set, nobody is signed in, and a
/// `connect` request is waiting for its answer. Returns that request's id. For
/// tests.
pub fn beginBunkerConnectForTest(pubkey: [32]u8, id_out: *[24]u8) []const u8 {
    remote_signer.g_remote_pubkey = pubkey;
    keyholder.g_signer_kind = .remote;
    remote_signer.g_remote_status.store(1, .release);
    remote_signer.g_remote_sign_notice.store(false, .release);
    remote_signer.g_remote_confirming.store(true, .release);
    login.g_login_error.store(@intFromEnum(LoginError.none), .release);
    _ = remote_signer.g_remote_generation.fetchAdd(1, .monotonic);
    const id = "connect-for-test";
    @memcpy(id_out[0..id.len], id);
    _ = registerPending(id, .connect, null, false, .none, 0, no_half_id, .{});
    return id_out[0..id.len];
}

/// Lends the app an io for the one place a test reaches for it (minting the
/// ephemeral client key). For tests.
pub fn setIoForTest(io: ?std.Io) void {
    g_io = io;
}

/// The id of the `connect` request a pasted link left waiting, if any. For
/// tests.
pub fn pendingConnectIdForTest(out: *[24]u8) ?[]const u8 {
    pendingLock();
    defer pendingUnlock();
    for (&remote_signer.g_pending) |*slot| {
        if (slot.active and slot.method == .connect) {
            @memcpy(out[0..slot.id_len], slot.id());
            return out[0..slot.id_len];
        }
    }
    return null;
}

/// What the listener does with a `connect` answer from the signer. For tests.
pub fn answerBunkerConnectForTest(id: []const u8) void {
    _ = takeAnswered(id);
}

/// Whether the pairing secret `needle` is still anywhere in the buffer that
/// held it, or a client key is still held. For tests.
pub fn remoteSecretHeldForTest(needle: []const u8) bool {
    if (remote_signer.g_remote_client_kp != null) return true;
    return std.mem.indexOf(u8, &remote_signer.g_remote_secret_buf, needle) != null;
}

/// Which listener generation is current, so a test can see one was stopped.
/// For tests.
pub fn remoteGenerationForTest() u64 {
    return remote_signer.g_remote_generation.load(.acquire);
}

pub fn connectWentQuietForTest() bool {
    return connectWentQuiet();
}

pub fn driveBunkerConnectForTest(model: *Model) void {
    driveBunkerConnect(model);
}

/// Puts every piece of bunker state back to a guest's. For tests.
pub fn resetBunkerConnectForTest() void {
    abandonRemoteSigner(.none);
    remote_signer.g_remote_confirming.store(false, .release);
}

/// Drives the remote-signer connection state (0 idle, 1 reaching, 2 connected,
/// 3 unreachable) plus a remote identity, so the presentation is testable
/// without a live bunker. For tests.
pub fn setRemoteStateForTest(status: u8, npub_len: usize) void {
    keyholder.g_signer_kind = if (status == 0) .helper else .remote;
    remote_signer.g_remote_status.store(status, .release);
    remote_signer.g_remote_sign_notice.store(false, .release);
    if (npub_len > 0) {
        const stub = "npub1testsigner";
        const n = @min(stub.len, keyholder.g_identity_npub_buf.len);
        @memcpy(keyholder.g_identity_npub_buf[0..n], stub[0..n]);
        keyholder.g_identity_npub_len = n;
    } else keyholder.g_identity_npub_len = 0;
}

/// Switches to the feed and brings the store + ingest pool up if they are not
/// already running. Shared by all sign-in paths (create, import, remote signer).
/// A fresh identity means the feed's author filter changed, so force a rebuild
/// on the next tick by invalidating the change guard.
pub fn enterFeed(model: *Model) void {
    model.stage = .ready;
    invalidateFeed();
    if (g_store == null) {
        if (g_io) |io| if (g_environ) |env| startFeed(io, env);
    }
    // Whoever was signed in before, their follows leave with them. Then this
    // account's own list is read back out of the store, so a local-first app
    // does not forget who you follow every time you open it. Both bump the
    // generation, which is what makes the open sockets re-ask for the records
    // of the account that is actually signed in.
    forgetFollows();
    forgetMutes();
    forgetBookmarks();
    // A picture on its way belongs to whoever asked for it.
    dropUpload();
    forgetBlossom();
    loadFollowsFromStore();
    loadMutesFromStore();
    loadBookmarksFromStore();
    loadBlossomFromStore();
    // And what people sent this account while it was away.
    loadInbox();
}

pub fn initialModel() Model {
    var model = Model{};
    attachFeedStorage(&model);
    return model;
}

// -------------------------------------------------------------- compose & post
//
// Posting is local-first: a composed note is signed, written to the local store
// straight away (so it shows in the feed on the next tick), and published to the
// pool on a detached thread. The feed dedupes by event id, so when a relay later
// echoes our own note back through the ingest subscriptions it collapses onto
// the local copy.

pub fn replyHeldForTest() bool {
    return compose.g_reply_due_s != 0;
}

pub fn holdReplyForTest(now_s: i64) void {
    compose.g_reply_due_s = now_s + (if (compose.g_post_delay_s == 0) @as(i64, 5) else compose.g_post_delay_s);
}

pub fn postDelayForTest() i64 {
    return compose.g_post_delay_s;
}

/// Gives the open place one write relay of its own, the way a parsed document
/// would. The routing tests are about WHEN the relay list is read, not about
/// parsing it.
pub fn setPlaceWriteRelayForTest(url: []const u8) void {
    if (places.g_place == null) return;
    const m = &places.g_place.?;
    m.write_relay_lens[0] = @intCast(copyBounded(&m.write_relays[0], url));
    m.write_relays_len = 1;
}

pub fn setPostDelayForTest(seconds: i64) void {
    compose.g_post_delay_s = seconds;
}

pub fn postHeldForTest() bool {
    return compose.g_post_due_s != 0;
}

pub fn holdPostForTest(now_s: i64) void {
    compose.g_post_due_s = now_s + compose.g_post_delay_s;
}

// ------------------------------------------------------------ picture upload
//
// Putting a picture into a note, an avatar or a banner.
//
// The protocol is Blossom and `blossom.zig` holds it. What lives here is what
// only the app can know: who is signed in, which signer will sign, which draft or
// profile field the address belongs in, and what is on screen while it happens.
//
// The shape of one upload, because it spans three threads and a signer:
//
//   1. The reader presses a button, a file dialog opens, and a file is chosen.
//      Nothing has left the machine.
//   2. A worker reads it, checks what it is, removes location and camera
//      metadata and works out the hash, size and blurhash. The card now says what
//      will be sent and to which servers, and waits for a press on Upload.
//   3. The press asks the signer for a kind:24242 token naming that hash. It goes
//      through exactly the signer every other event goes through, so a Notary or
//      a NIP-46 bunker prompts as it would for a note. The token is never stored
//      and never published: it is a bearer credential for one file.
//   4. A second worker sends the picture, server by server, until one takes it.
//   5. The tick puts the returned address where the picture was asked for.
//
// A job is shared between the UI thread and at most one worker at a time, and it
// is reference counted so that cancelling while a worker is mid-write cannot free
// what the worker is reading. The UI holds one reference; each worker holds one
// while it runs.

pub fn appendPictureToDraftForTest(model: *Model, url: []const u8) bool {
    return appendPictureToDraft(model, url);
}

/// Records a picture as if it had just been uploaded. For tests.
pub fn rememberUploadedForTest(url: []const u8, mime: []const u8, sha_hex: []const u8, size: usize, width: u32, height: u32, hash: []const u8, alt: []const u8) void {
    var entry: UploadedPicture = .{ .used = true, .mime = mime, .size = size, .width = width, .height = height };
    @memcpy(entry.url_buf[0..url.len], url);
    entry.url_len = @intCast(url.len);
    @memcpy(entry.sha_buf[0..sha_hex.len], sha_hex);
    @memcpy(entry.blur_buf[0..hash.len], hash);
    entry.blur_len = @intCast(hash.len);
    @memcpy(entry.alt_buf[0..alt.len], alt);
    entry.alt_len = @intCast(alt.len);
    uploads.g_uploaded[uploads.g_uploaded_next % uploads.g_uploaded.len] = entry;
    uploads.g_uploaded_next +%= 1;
}

pub fn forgetUploadedForTest() void {
    uploads.g_uploaded = [_]UploadedPicture{.{}} ** 8;
    uploads.g_uploaded_next = 0;
}

// Test seams for the upload: the file dialog stood in for, the phases read, and
// the stages that happen on a thread or in a signer driven by hand.

pub fn setPickPathForTest(path: ?[]const u8) void {
    uploads.g_pick_path_override = path;
}

pub fn uploadPickForTest(model: *Model, fx: *Effects, target: u8) void {
    uploadPick(model, fx, std.enums.fromInt(UploadTarget, target) orelse return);
}

pub fn uploadGoForTest(model: *Model, fx: *Effects) void {
    uploadGo(model, fx);
}

pub fn uploadRetryForTest(model: *Model, fx: *Effects) void {
    uploadRetry(model, fx);
}

pub fn uploadCancelForTest(model: *Model) void {
    uploadCancel(model);
}

pub fn driveUploadForTest(model: *Model) void {
    driveUpload(model);
}

pub fn dropUploadForTest() void {
    dropUpload();
}

/// The phase of the job on screen, or "none".
pub fn uploadStateForTest() []const u8 {
    const job = uploads.g_upload orelse return "none";
    return @tagName(job.phase());
}

/// Why the job failed, or empty.
pub fn uploadMessageForTest() []const u8 {
    const job = uploads.g_upload orelse return "";
    return job.message();
}

/// Moves the job's token back in time, as if it had been signed `seconds` ago.
pub fn ageUploadTokenForTest(seconds: i64) void {
    const job = uploads.g_upload orelse return;
    job.signing_since_s -= seconds;
}

pub fn uploadSentBytesForTest() usize {
    const job = uploads.g_upload orelse return 0;
    return job.progress.sent.load(.acquire);
}

/// Makes `urls` this account's server list, as if a kind:10063 had been read.
pub fn setBlossomServersForTest(urls: []const []const u8) void {
    const gpa = std.heap.page_allocator;
    const tags = gpa.alloc(nostr.event.Tag, urls.len) catch return;
    for (urls, 0..) |url, i| tags[i] = gpa.dupe([]const u8, &.{ "server", url }) catch return;
    setBlossomServers(tags, 1);
}

pub fn forgetBlossomForTest() void {
    forgetBlossom();
}

pub fn loadBlossomFromStoreForTest() void {
    loadBlossomFromStore();
}

pub fn ingestAndPublishForTest(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    ingestAndPublish(gpa, ev, null, .none);
}

pub fn clearLastPublishedForTest() void {
    keyholder.g_last_published = null;
    keyholder.g_last_published_tags = &.{};
}

pub fn ownRecordCreatedAtForTest(kind: u16) i64 {
    return ownRecordCreatedAt(kind);
}

/// A token as the bunker's listener thread would park it.
pub fn parkUploadSignForTest(event_json: ?[]const u8) void {
    parkUploadSign(event_json);
}

pub fn tokenNamesFileForTest(tags: []const nostr.event.Tag, sha256_hex: []const u8, now: i64) bool {
    return tokenNamesFile(tags, sha256_hex, now);
}

/// The clock a token's expiry is checked against.
pub fn nowSecondsForTest() i64 {
    return nowSeconds();
}

/// Says the probe found nothing on any relay, for the account that is signed in.
pub fn markBlossomProbeCleanForTest(clean: bool) void {
    lockBlossom();
    media_servers.g_blossom_probe_for = activePubkey();
    unlockBlossom();
    media_servers.g_blossom_probe_state.store(if (clean) probe_clean else probe_unknown, .release);
}

// ------------------------------------------------------- the reader's servers

pub fn blossomProbeWantedForTest() bool {
    const pk = activePubkey() orelse return false;
    lockBlossom();
    defer unlockBlossom();
    return blossomProbeWantedUnlocked(pk);
}

pub fn probeReplyAnswersForTest(tag: std.meta.Tag(nostr.message.RelayMessage)) bool {
    return probeReplyAnswers(tag);
}

pub fn writeBlossomServersForTest(fx: *Effects, add: ?[]const u8, remove: ?[]const u8) BlossomWrite {
    return writeBlossomServers(fx, add, remove);
}

pub fn blossomServersForTest(out: *[blossom.max_servers][]const u8) usize {
    const s = uploadServers();
    for (0..s.count) |i| out[i] = std.heap.page_allocator.dupe(u8, s.at(i)) catch "";
    return s.count;
}

pub fn blossomOwnListForTest() bool {
    return uploadServers().own;
}

pub const BlossomEdit = enum { none, invalid, busy, unread, full, failed };

// -------------------------------------------------------------------- views

// ------------------------------------------------------------------------ likes
//
// A like is a NIP-25 kind:7 reaction with content "+", e/p/k-tagging the note.
// It rides the same three sign paths as a post and is local-first and optimistic:
// the heart fills the instant it is pressed (read from `g_my_likes` at render),
// and the reaction publishes in the background. Un-like is a NIP-09 kind:5
// deletion e-tagging our own reaction, since NIP-25 has no un-react. A guest
// press cannot sign, so it is remembered and completed after sign-in.

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

// -------------------------------------------------------------------- the outbox
//
// What happens to a note between pressing Post and knowing it is somewhere else.
//
// Publishing used to be fire-and-forget: a detached thread dialled every relay,
// wrote the frame, read one message to flush it, and dropped the verdict. The
// note was in the local store, so the feed showed it, and whether it ever
// reached anyone was not a question the app could answer.
//
// Now every publish goes through a queue. Each entry names an event that is
// already in the store's own tables (we ingest what we sign) and carries one bit
// per relay: did that relay say OK. The queue is the app's answer to "is my note
// out there", the status bar reads it, and it survives a quit, because a note
// written on a train and lost on landing is the worst thing a client can do.
//
// The queue is small on purpose. It is not a retry engine for a broken network;
// it is a record of what has not been acknowledged yet, drained whenever a relay
// comes back.

pub fn outboxHasRoomForTest() bool {
    return outboxHasRoom();
}

/// The queue's own seams, so a test drives the real state machine rather than a
/// copy of it.
pub fn resetOutboxForTest() void {
    outboxLock();
    defer outboxUnlock();
    for (&outbox.g_outbox) |*e| e.* = .{};
    relay_conn.g_outbox_woke_at.store(0, .monotonic);
    relay_conn.g_outbox_woke_ever.store(false, .monotonic);
}

pub fn outboxStateForTest(id: [32]u8) ?OutboxState {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return null;
    return e.state();
}

pub fn outboxRoundsForTest(id: [32]u8) ?u8 {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return null;
    return e.rounds;
}

pub fn enqueueOutboxForTest(id: [32]u8, author: [32]u8, now_s: i64) bool {
    return enqueueOutbox(id, author, now_s, .none);
}

pub fn recordOutboxAckForTest(id: [32]u8, relay_index: usize, accepted: bool) void {
    recordOutboxAck(id, relay_index, accepted);
}

pub fn countOutboxRoundForTest(id: [32]u8) void {
    markOutboxSending(id, true);
    markOutboxSending(id, false);
}

pub fn sweepOutboxForTest(now_s: i64) void {
    sweepOutbox(now_s);
}

pub fn outboxRetryDelayForTest(rounds: u8) i64 {
    return outboxRetryDelay(rounds);
}

pub const rounds_before_stuck_for_test = rounds_before_stuck;
pub const outbox_sent_linger_for_test = outbox_sent_linger_s;

pub fn collectOutboxDueForTest(ids: *[outbox_cap][32]u8, now_s: i64) usize {
    return collectOutboxDue(ids, now_s);
}

pub fn syncOutboxOwnerForTest() void {
    syncOutboxOwner();
}

pub fn loadOutboxForTest(owner: [32]u8) void {
    loadOutbox(owner);
}

pub fn saveOutboxForTest() void {
    saveOutbox();
}

pub fn outboxOwnerForTest() ?[32]u8 {
    return outbox.g_outbox_owner;
}

pub fn clearOutboxOwnerForTest() void {
    outbox.g_outbox_owner = null;
}

pub fn outboxAuthorAtForTest(i: usize) ?[32]u8 {
    outboxLock();
    defer outboxUnlock();
    if (!outbox.g_outbox[i].used) return null;
    return outbox.g_outbox[i].author;
}

pub fn outboxUsedSlotsForTest() usize {
    outboxLock();
    defer outboxUnlock();
    var n: usize = 0;
    for (&outbox.g_outbox) |*e| {
        if (e.used) n += 1;
    }
    return n;
}

pub const outbox_cap_for_test = outbox_cap;

/// Whether `url` is already one of the reader's own relays.
pub fn poolHasRelayForTest(url: []const u8) bool {
    return poolHasRelay(url);
}

/// What the route a held note is carrying names, for the test: the relay list a
/// publish walk would actually dial, taken from the value and not from whatever
/// room happens to be open when it is read.
pub fn heldRouteRelaysForTest(out: [][]const u8) usize {
    var n: usize = 0;
    while (n < compose.g_held_route.len and n < out.len) : (n += 1) out[n] = compose.g_held_route.url(n);
    return n;
}

pub fn routeForOpenPlaceRelaysForTest(out: [][]const u8) usize {
    const r = routeForOpenPlace();
    outbox.g_route_probe = r;
    var n: usize = 0;
    while (n < outbox.g_route_probe.len and n < out.len) : (n += 1) out[n] = outbox.g_route_probe.url(n);
    return n;
}

// ------------------------------------------------------------------------ threads
//
// A thread is the focused note plus the kind:1 replies that e-tag it. It is
// layered OVER the feed, which stays mounted so its scroll offset survives.
// Opening one snapshots the root, reads any replies already in the store, and
// fires a one-shot fetch of the rest (with their engagement) into the store; the
// replies are cached in the model so they are pressable (open as a sub-thread)
// and get their pictures fetched, the same local-first path the feed uses.

/// The level bookkeeping, for a test that walks a stack up and down. Both take
/// the same paths the app does, so what they assert is what a reader gets.
pub fn enterThreadForTest(model: *Model, root: Note) void {
    enterThread(model, root);
}

pub fn closeThreadForTest(model: *Model) void {
    closeThread(model);
}

/// The thread a kept reply is filed under, for a test of where a reply went.
pub fn keptReplyDraftForTest(event_id: [32]u8) ?[]const u8 {
    for (&drafts.g_reply_drafts) |*d| {
        if (d.used and std.mem.eql(u8, &d.event_id, &event_id)) return d.text[0..d.len];
    }
    return null;
}

pub fn feedEndLatchesForTest(asked: usize, answered: usize, added: usize) bool {
    return feedEndLatches(asked, answered, added);
}
pub fn setFeedEndForTest() void {
    navigation.g_feed_end_reached.store(true, .monotonic);
}

pub fn resetFeedEndForTest() void {
    resetFeedEnd();
    navigation.g_older_busy.store(false, .monotonic);
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

// ------------------------------------------------------- finding a person
//
// The field that opens an address finds people by name as well, because it is
// the one place somebody goes to say who they mean. Two sources answer it, and
// they are not mixed up: every profile already on this machine, instantly and
// with the network off, then NIP-50 search relays, whose results are folded in
// as they land and each marked with the relay that gave it.

// --- test seams

/// Back to a fresh start: no index, no rows, no relay state.
pub fn searchResetForTest() void {
    searchReset();
    lockSearchIndex();
    people_search.g_search_index.deinit(std.heap.page_allocator);
    people_search.g_search_index_ready = false;
    unlockSearchIndex();
    people_search.g_search_asked = 0;
    people_search.g_search_typed_ms = 0;
    people_search.g_nip05_ask = null;
}

/// Builds the index now, on this thread, from the store.
pub fn searchIndexRefreshForTest() void {
    searchIndexRefresh();
}

pub fn searchIndexLenForTest() usize {
    lockSearchIndex();
    defer unlockSearchIndex();
    return people_search.g_search_index.entries.len;
}

pub fn searchRowCountForTest() usize {
    return people_search.g_search_len;
}

pub fn searchRowPubkeyForTest(i: usize) [32]u8 {
    return people_search.g_search_rows[i].pubkey;
}

pub fn searchRowLocalForTest(i: usize) bool {
    return people_search.g_search_rows[i].local;
}

/// Bit `n` set means search relay `n` returned this row.
pub fn searchRowRelaysForTest(i: usize) u8 {
    return people_search.g_search_rows[i].relays;
}

pub fn searchTickForTest(model: *const Model, now_ms: i64) void {
    searchTick(model, now_ms);
}

/// Whether the term on screen has been put to the relays.
pub fn searchAskedForTest() bool {
    return people_search.g_search_term_len > 0 and people_search.g_search_asked == people_search.g_search_gen.load(.acquire);
}

pub fn searchGenForTest() u32 {
    return people_search.g_search_gen.load(.acquire);
}

/// A relay thread's hand-off, without the thread.
pub const search_inbox_cap_for_test = search_inbox_cap;

pub fn searchArrivedForTest(gen: u32, relay: u8, pubkey: [32]u8) void {
    searchArrived(gen, relay, pubkey);
}

/// What a relay thread does with one event.
pub fn searchAcceptForTest(gen: u32, relay: u8, signer: nostr.keys.Signer, ev: nostr.event.Event) bool {
    const job = SearchJob{ .gen = gen, .relay = relay, .url = "", .term = undefined, .term_len = 0 };
    return searchAccept(std.heap.page_allocator, signer, job, ev);
}

pub fn searchSetStatusForTest(relay: usize, state: search.RelayState, count: u16) void {
    people_search.g_search_status[relay].store((search.Status{ .gen = people_search.g_search_gen.load(.acquire), .state = state, .count = count }).pack(), .release);
}

pub fn searchRelayCountForTest() usize {
    return searchRelays().len;
}

pub fn searchRelayUrlForTest(i: usize) []const u8 {
    return searchRelays()[i];
}

pub fn nip05AskedForTest() bool {
    return people_search.g_nip05_ask != null;
}

pub fn handleNip05FoundForTest(model: *Model, response: native_sdk.EffectResponse) void {
    handleNip05Found(model, response);
}

/// The key the lookup now awaited went out under.
pub fn nip05AskKeyForTest() u64 {
    return people_search.g_nip05_ask_key;
}
pub const search_scan_page_for_test = search_scan_page;

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
    return navigation.g_event_want != null;
}

pub fn forgetEventFetchForTest() void {
    navigation.g_event_want = null;
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
    profile_notes.g_profile_end.store(profileEndKey(pubkey), .monotonic);
}

pub fn resetProfileEndForTest() void {
    resetProfileEnd();
    profile_notes.g_profile_older_busy.store(false, .monotonic);
    profile_notes.g_profile_older_ask = null;
}

pub fn profileOlderAskForTest() ?ProfileOlderAsk {
    return profile_notes.g_profile_older_ask;
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

/// Puts the page's first fetch back in flight, or lands it, for a test that has
/// no socket to do either.
pub fn setFirstProfileFetchOutForTest(model: *Model, out: bool) void {
    const done = navigation.g_thread_done_seq.load(.acquire);
    if (out) {
        model.thread_seq = done + 1;
    } else {
        navigation.g_thread_done_seq.store(model.thread_seq, .release);
    }
}

pub fn loadOlderProfileForTest(model: *Model) void {
    loadOlderProfile(model);
}

pub fn loadAtProfileBottomForTest(model: *Model, bottom_in_view: bool) void {
    profile_notes.g_profile_bottom_in_view = bottom_in_view;
    loadAtProfileBottom(model);
}

/// Fetches a note's replies (and their engagement) into the store, on a detached
/// thread. One dial per relay: opening a thread is a rare, human-paced action, so
// --------------------------------------------------------- the relay-list sweep
//
// Who to ask about the people nobody in the pool can answer for.
//
// Every author whose kind:10002 Plaza does not hold is asked of the indexers,
// once per run. Eager over the whole follow list rather than lazily on a miss,
// because the routing table has to be warm BEFORE the first feed REQ or the
// feed goes to the wrong relays and the round trip is paid twice: three of the
// four clients read do the eager sweep for exactly that reason, and welshman,
// the one that does not, is also the one with no negative caching and an
// unbounded retry.
//
// DEFERRED, and named rather than quietly skipped: the answer is not written
// down across launches, so an author who has genuinely never published a
// relay list is asked again next time Plaza starts. Within a run they are
// asked once. Jumble is the only client of the five that persists a negative
// result, and doing it properly means a `checked_at` per pubkey in the store
// with a staleness rule, which is its own change.

pub fn sweepRelayListsForTest() void {
    sweepRelayLists();
}
pub fn collectUnroutedForTest(out: [][32]u8) usize {
    return collectUnrouted(out);
}
pub fn indexerRelaysForTest() []const []const u8 {
    return &indexer_relays;
}
pub fn indexerChunkForTest() usize {
    return indexer_chunk;
}
pub fn resetIndexerAskedForTest() void {
    routing.g_indexer_asked_len = 0;
    routing.g_indexed.store(0, .monotonic);
}
pub fn markIndexerAskedForTest(pk: [32]u8) void {
    if (routing.g_indexer_asked_len >= routing.g_indexer_asked.len) return;
    routing.g_indexer_asked[routing.g_indexer_asked_len] = pk;
    routing.g_indexer_asked_len += 1;
}
pub fn indexerAskedLenForTest() usize {
    return routing.g_indexer_asked_len;
}

pub fn relayFetchAllowedForTest() bool {
    return relayFetchAllowed();
}

// ------------------------------------------------------- remote signer (NIP-46)
//
// Signing can be routed to an external signer (Notary) over NIP-46 so the user's
// secret key never enters Plaza. Plaza is the CLIENT: it holds an ephemeral
// transport keypair, and the user's identity is the bunker's own pubkey. The
// wire is kind:24133 events whose content is a NIP-44-encrypted request/response
// `p`-tagged to the recipient. A persistent listener thread holds the bunker
// relay and processes responses; each request (connect, then one per post) goes
// out on its own short-lived connection, so a blocked receive never stalls a
// send. A signed note returns as a response `result`, stored and published to
// the feed pool exactly like a locally signed one.

pub fn remoteDecryptMethodNameForTest(payload: []const u8) []const u8 {
    return @tagName(remoteDecryptMethod(payload));
}

// -------------------------------------------------------------------- app run

// CoreText/CoreGraphics, for registering the bundled faces process-wide by
// PostScript name. Already linked: the SDK's AppKit host uses CTFontManager.
const ct = if (builtin.os.tag == .macos) struct {
    const CGDataProviderRef = ?*anyopaque;
    const CGFontRef = ?*anyopaque;
    const CFTypeRef = ?*anyopaque;
    extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: [*]const u8, size: usize, release: ?*anyopaque) CGDataProviderRef;
    extern "c" fn CGDataProviderRelease(provider: CGDataProviderRef) void;
    extern "c" fn CGFontCreateWithDataProvider(provider: CGDataProviderRef) CGFontRef;
    extern "c" fn CGFontRelease(font: CGFontRef) void;
    extern "c" fn CTFontManagerRegisterGraphicsFont(font: CGFontRef, err: ?*CFTypeRef) bool;
    extern "c" fn CFRelease(ref: CFTypeRef) void;
} else struct {};

/// Installs Plaza's own vector icons (plaza_icons.zig) so `ui.appIcon` names
/// resolve like built-ins. Idempotent: it just publishes a static table. The
/// tests call it too, so a view built in a test draws the real glyphs instead of
/// the missing-icon fallback (and an icon regression can actually fail a test).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&plaza_icons.app_icons);
}

/// Registers the bundled Geist faces (theme.zig) with CoreText from the
/// binary's own bytes, process scope, so the host's by-name resolution of the
/// default sans/mono ids (and the reserved medium/bold span ids) finds them
/// on EVERY launch path: the live window, a dev run from any working
/// directory, and headless session replay. Best-effort per face: a face that
/// is already registered (a system-installed Geist, a second call) fails
/// quietly, and by-name lookup still resolves; either copy is the same OFL
/// family.
fn registerFontFaces() void {
    if (comptime builtin.os.tag != .macos) return;
    const faces = [_][]const u8{ theme.geist_ttf, theme.geist_medium_ttf, theme.geist_bold_ttf, theme.geist_mono_ttf };
    for (faces) |ttf| {
        const provider = ct.CGDataProviderCreateWithData(null, ttf.ptr, ttf.len, null) orelse continue;
        defer ct.CGDataProviderRelease(provider);
        const font = ct.CGFontCreateWithDataProvider(provider) orelse continue;
        defer ct.CGFontRelease(font);
        var err: ct.CFTypeRef = null;
        _ = ct.CTFontManagerRegisterGraphicsFont(font, &err);
        if (err) |e| ct.CFRelease(e);
    }
}

/// The faces registered off macOS, and none on it. A slice rather than an
/// optional because that is the shape `Options.fonts` takes.
///
/// The emoji face is for the renderer's colour fallback; nothing asks to be
/// drawn in its id. The two weights are the opposite: the toolkit maps a span's
/// weight onto reserved ids of its own and bundles no face for any of them, so
/// off macOS medium and bold ink REGULAR outlines and the app has no
/// typographic hierarchy at all. Filling those ids is the only way to get the
/// weights, and it is the same two files CoreText is handed on macOS, already
/// embedded, so it costs no binary.
const registered_fonts: []const PlazaApp.FontRegistration = if (builtin.os.tag == .macos)
    &.{}
else
    &.{
        // Twemoji FIRST. The renderer's fallback walks these in order, so a
        // codepoint two faces both carry goes to the one registered earlier,
        // and an emoji should be drawn as a picture rather than as whichever
        // text face happens to have a monochrome glyph for it.
        .{ .id = theme.emoji_font_id, .name = "Twemoji.ttf", .ttf = theme.emoji_ttf },
        .{ .id = canvas.default_sans_medium_font_id, .name = "Geist-Medium.ttf", .ttf = theme.geist_medium_ttf },
        .{ .id = canvas.default_sans_bold_font_id, .name = "Geist-Bold.ttf", .ttf = theme.geist_bold_ttf },
        // The scripts Geist does not carry. Nothing is ever drawn IN these ids;
        // they are here so the faces exist for the fallback to find. See
        // `theme.noto_ttf`.
        .{ .id = theme.noto_font_id, .name = "NotoSans-Regular.ttf", .ttf = theme.noto_ttf },
        .{ .id = theme.noto_sc_font_id, .name = "NotoSansSC-Regular.ttf", .ttf = theme.noto_sc_ttf },
        .{ .id = theme.noto_kr_font_id, .name = "NotoSansKR-Hangul.ttf", .ttf = theme.noto_kr_ttf },
    };

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    g_environ = init.environ_map;
    // Before anything else reads it: a link is why this process exists when the
    // reader followed one, and the ceremony below can take a while.
    captureArgvLink(init.minimal.args);

    // The bundled Geist faces, registered with CoreText before the platform
    // host exists, so every later font lookup resolves them (see theme.zig).
    registerFontFaces();

    // The glyphs the built-in set does not carry. Registered before the first
    // view build.
    registerIcons();

    // A returning user has a persisted session: restore it (load the local key,
    // or silently reconnect the bunker) so they are signed straight back in.
    // Best-effort: on failure the app still runs, as a guest.
    loadSettings(init.io, init.environ_map);
    _ = restoreSession(init.io, init.environ_map);
    // Resolve the keyholder daemon (its path and a fresh bearer token); boot
    // spawns it. Non-fatal, but not free either: Plaza has not minted a key in
    // this process since the key moved out of it, so an install that arrived
    // without the daemon cannot make one, and `keyholderMissing` is how the join
    // screens say so instead of offering a button that swallows the press.
    resolveHelper(init);
    resolveNotaryWindow(init);

    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = appView,
        .on_command = onCommand,
        .on_key = onKey,
        // On macOS: none. The typography tokens sit on the BUILT-IN ids (the
        // toolkit's default sans IS Geist), which is the only routing that
        // gives span weights real medium and bold faces, and `registerFontFaces`
        // hands the faces to CoreText, which then cascades to the system for
        // anything Geist lacks.
        //
        // Everywhere else: the colour emoji face and the two Geist weights,
        // because none of that exists there. See `registered_fonts`.
        .fonts = registered_fonts,
        // The dark, cool-grey, white-accent look (see theme.zig).
        .tokens_fn = theme.tokens(Model),
    });
    defer app_state.destroy();
    g_app = app_state;
    app_state.model = initialModel();
    // Guest-first: the app opens INTO the feed, never a welcome wall. A
    // restored session is signed straight back in; a newcomer browses as a
    // guest (the feed reads fine without an identity) and is asked for one at
    // first intent, not at launch. Either way the store and the pool start
    // before the window appears, so the first frame renders from disk.
    app_state.model.stage = .ready;
    startFeed(init.io, init.environ_map);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "plaza",
        .window_title = "Plaza",
        .bundle_id = "com.zig-nostr.plaza",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &.{ "zero://inline", "zero://app" },
                // The toolkit refuses `openUrl` unless the policy says a link
                // may reach the system browser, so this has to be anything but
                // the default `.deny`.
                //
                // `*` and not `"https://*"`, which is what this said until a
                // reader reported that no link opened anywhere. The toolkit's
                // pattern language cannot express a scheme-wide wildcard:
                // `security.externalWildcardPrefixValid` requires a host AND a
                // path slash after the scheme, so `"https://*"` leaves an empty
                // rest, finds no `/`, and is discarded as malformed. A policy
                // of two discarded patterns matches nothing and denies
                // everything, silently, because the refusal is an error nobody
                // surfaces.
                //
                // So the real gate is `isSafeExternalUrl`, which runs FIRST and
                // already refuses anything that is not http(s) with no control
                // characters. This one is the toolkit's own, and the honest
                // way to say "whatever the first gate passed" is `*`.
                .external_links = external_link_policy,
            },
        },
    }, init);
}

/// Opens the local-first store and spawns the background ingest thread. The
/// store is heap-allocated and the thread detached, both living for the whole
/// process: LMDB commits each event durably, and the ingest thread can be
/// blocked in a relay read at quit, so we deliberately never tear them down,
/// process exit reclaims them without racing the detached thread. A failure
/// here is non-fatal: the app runs with an empty feed that reads "offline".
fn startFeed(io: std.Io, environ: *const std.process.Environ.Map) void {
    if (g_store != null) return; // already running
    const gpa = std.heap.page_allocator;
    const store = gpa.create(nostr.store.Store) catch return;
    store.* = openFeedStore(io, environ) catch |err| {
        std.debug.print("plaza: local store unavailable: {s}\n", .{@errorName(err)});
        gpa.destroy(store);
        return;
    };
    g_store = store;
    seedFeedNewest(store);
    // The reader's own follow list is already on disk from last session. Read it
    // before the first frame, so a local-first app opens on THEIR feed rather
    // than on nine strangers while it waits for a relay.
    loadFollowsFromStore();
    loadMutesFromStore();
    loadBookmarksFromStore();
    loadBlossomFromStore();
    loadInbox();

    // The reader's own list, or the one the app was born with. Read before the
    // threads start, so the first dial goes where they asked.
    loadRelays(io, environ);
    loadAuthChoices(io, environ);

    // One ingest thread per SLOT, not per relay: a slot's thread outlives the
    // relay in it, so adding one later is a slot claim rather than a thread
    // spawn from the UI, and removing one leaves a thread that finds the slot
    // dormant and waits. Each dials independently, so a slow or down relay never
    // holds up the others, and all write into the one shared store (LMDB
    // serialises the concurrent writers).
    for (0..max_relays) |i| {
        const thread = std.Thread.spawn(.{}, ingestRelay, .{ gpa, i }) catch |err| {
            std.debug.print("plaza: [{s}] could not start: {s}\n", .{ relayUrlAt(i), @errorName(err) });
            setRelayStatus(i, .offline);
            continue;
        };
        thread.detach();
    }

    // And one per discovered relay: where the reader's follows turned out to
    // be, which the pool would never ask because it only knows the reader's own
    // list. Spawned even before the table has anything in it, because these are
    // slot threads like the pool's: they park until a slot is filled.
    for (0..max_discovered_relays) |i| {
        if (std.Thread.spawn(.{}, discoveredRelayThread, .{ gpa, i })) |t| {
            t.detach();
        } else |err| {
            std.debug.print("plaza: discovered relay {d} did not start: {s}\n", .{ i, @errorName(err) });
        }
    }

    // One more, watching all of them. It has to be a separate thread and not
    // work folded into the eight: each of those is blocked inside `receive`
    // exactly when there is something to notice, and a thread waiting on a dead
    // peer is the last thing that can tell it has stopped answering.
    if (std.Thread.spawn(.{}, relayKeeper, .{gpa})) |keeper| {
        keeper.detach();
    } else |err| {
        // Not fatal. Without it the pool behaves the way it did before: a
        // half-open socket sits there. Said out loud rather than swallowed,
        // because "the feed silently stopped updating" is the symptom and it
        // looks nothing like its cause.
        std.debug.print("plaza: relay keepalive did not start ({s}); a dropped connection will not be noticed\n", .{@errorName(err)});
    }
}

/// How much address space the store may grow into.
///
/// LMDB never grows past its map size, and the library's default is 1 GiB. There
/// is no pruning here and no retention window: the store only grows, at a
/// measured 2.4 MB a day on a development machine with a modest follow set and
/// the app not even running continuously. A reader on eight relays all day with
/// a real follow list, taking kind:6 and kind:7 engagement as well, gets there
/// materially faster.
///
/// Arriving is silent and it is the reader's own notes that pay. `plazaIngest`
/// is `catch {}` at the write of a note this app just signed, deliberately, so a
/// duplicate id cannot stop it reaching the pool, and a full map takes the same
/// branch. `saveOutbox` fails the same way, so the queue index never lands, and
/// `loadOutbox` drops on the next launch every entry whose event is not in the
/// store. The banner goes on saying the app is posting them.
///
/// A map size is address space, not a file: LMDB reserves it and the file stays
/// sparse. So the cheapest honest answer is to reserve far more of it than this
/// app can plausibly use, which moves the wall from a few years out to further
/// away than the format. Detecting MDB_MAP_FULL properly needs the library to
/// tell it apart from every other LMDB error, and pruning is a feature; both are
/// worth having and neither is a reason to leave the wall where it is.
const feed_store_map_size: usize = 32 << 30;

/// Opens (creating if needed) the feed store at `$HOME/.plaza/feed.mdb`.
fn openFeedStore(io: std.Io, environ: *const std.process.Environ.Map) !nostr.store.Store {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    dir.close(io);

    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/feed.mdb", .{dir_path});
    return nostr.store.Store.open(db_path, .{ .map_size = feed_store_map_size });
}

// ----------------------------------------------------------------- identity
//
// Plaza's local signing identity lives beside the feed store, at
// `$HOME/.plaza/identity.key` (the raw 32-byte secret, mode 0600). It is created
// on the user's onboarding action, not silently: a first run with no key file
// opens the welcome screen, and "Create your identity" generates and persists
// it. This is the zero-config local signer; connecting an external signer
// (Notary, over NIP-46) so the key never touches the client is the next
// onboarding option, and swaps in at `signAndPublish`.

/// The document one place writes, for the round-trip test.
pub fn writePlaceDocumentForTest(gpa: std.mem.Allocator, out: *std.ArrayList(u8), m: *const Place) !void {
    return writePlaceDocument(gpa, out, m);
}

pub fn settingsWritesForTest() usize {
    return prefs.g_settings_writes;
}

pub fn writeDraftForTest(io: std.Io, dir: *std.Io.Dir, text: []const u8, warn: ?[]const u8) void {
    writeDraft(io, dir, text, warn);
}

pub fn draftWarningForModelForTest(model: *const Model) ?[]const u8 {
    return draftWarningOf(model);
}

/// Restores a launch's composer from `dir`, the way startup does.
pub fn loadDraftIntoForTest(io: std.Io, dir: *std.Io.Dir, model: *Model) void {
    var draft_buf: [note_content_cap]u8 = undefined;
    var warn_buf: [warning_input_capacity]u8 = undefined;
    const stashed = readDraft(io, dir, &draft_buf, &warn_buf);
    applyStashedDraft(model, stashed);
}

/// Logs out: deletes the session (and, for a local key, the key file itself),
/// resets the identity globals, and returns to onboarding. The feed store and
/// its ingest threads keep running (they serve the starter pack regardless of
/// who is signed in); a subsequent sign-in reuses them. The user is never locked
/// in, a local key can always be copied from Settings first, and a remote
/// signer keeps the user's key throughout.
/// Drives the whole sign-out, so a test can assert what does NOT survive it. The
/// list of things it clears is the interesting part, and every one of them was
/// added after something of the previous account's turned up under the next
/// account's key.
pub fn performLogoutForTest(model: *Model, fx: *Effects) void {
    performLogout(model, fx);
}

pub fn loggedOutPubkeyForTest() ?[32]u8 {
    return keyholder.g_logged_out_pk;
}

// ----------------------------------------------------------- background ingest
//
// Each relay's ingest loop runs on its own thread with its own `std.Io.Threaded`
// and its own secp256k1 context, the io backend and the signer are not shared
// across threads, the exact shape the Notary daemon uses per relay. It dials,
// subscribes for recent kind:1, verifies each event, and writes it into the
// shared store; the UI thread reads it back through `Model.refresh`.

/// Opens, or replaces, the engagement subscription over the first `count`
/// watched notes.
///
/// A REQ under an existing id IS a replacement, so widening the watched set
/// costs one message and no CLOSE.
/// Records a feed note's id so its engagement can be watched, deduped and
/// bounded.
///
/// Shared by the pool threads and the routed ones, because they had drifted:
/// the pool watched engagement and the routed relays did not, and after the
/// outbox landed the routed relays are the ones carrying most of the feed. One
/// function is what stops that happening again.
///
/// The cap keeps the `#e` filter a size relays actually accept.
pub const engagementWatchCapForTest = engagement_watch_cap;

pub fn rememberFeedIdForTest(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: *usize,
    ev: nostr.event.Event,
) void {
    rememberFeedId(ids, hex, len, ev);
}

pub fn publishFeedWatchForTest(notes: []const Note) void {
    publishFeedWatch(notes);
}

pub fn mergeFeedWatchForTest(
    ids: *[engagement_watch_cap]i64,
    hex: *[engagement_watch_cap][64]u8,
    len: usize,
) usize {
    return mergeFeedWatch(ids, hex, len);
}

pub fn feedWatchGenerationForTest() u32 {
    return feedWatchGeneration();
}

// -- Every socket asks only about the people it can answer for ---------------
//
// The pool used to ask all eight of its relays about every followed author, and
// the routed relays asked about theirs. That is a hybrid: the routing bought
// reach, and none of it bought the pool relays a smaller question. Jumble and
// Amethyst both route the WHOLE feed, and this is that.
//
// Each pool relay is asked about the follows who write THERE, plus the
// residual: everyone no relay in either set is going to be asked about. The
// residual is what makes the change safe, and defining it correctly is the
// whole risk. It is NOT "authors with no relay list". It is every author not
// covered by any chosen relay, list or no list, because an author who publishes
// only to a relay that did not make the cut is otherwise asked of nobody at all
// and simply vanishes from the feed. No error, no empty state, which is the
// exact failure the outbox model exists to fix and the easiest one to
// reintroduce while fixing it.
//
// So the invariant, and there is a test for it by name: every followed author
// appears in at least one relay's filters.

pub fn poolAuthorsForTest(index: usize, out: *[max_follows + 1][32]u8) usize {
    return poolAuthors(index, out);
}
pub fn poolAuthorsOrAllForTest(index: usize, out: *[max_follows + 1][32]u8) usize {
    return poolAuthorsOrAll(index, out);
}
pub fn discoveredAuthorsForTest(index: usize, out: *[discovered_authors_cap][32]u8) usize {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= routing.g_discovered.len) return 0;
    const d = &routing.g_discovered[index];
    @memcpy(out[0..d.authors_len], d.authors[0..d.authors_len]);
    return d.authors_len;
}
pub fn clearRoutesForTest() void {
    lockDiscovered();
    defer unlockDiscovered();
    for (&routing.g_pool_routed) |*p| {
        p.url_len = 0;
        p.authors_len = 0;
    }
    routing.g_residual_len = 0;
}

pub fn forgetDiscoveredForTest() void {
    forgetDiscovered();
}

pub const outboxSubIdForTest = outbox_sub_id;

pub fn routeFollowUpForTest(live_url: []const u8, live_gen: u32, slot_url: []const u8, slot_gen: u32) RouteFollowUp {
    return routeFollowUp(live_url, live_gen, slot_url, slot_gen);
}

pub fn residualCountForTest() usize {
    lockDiscovered();
    defer unlockDiscovered();
    return routing.g_residual_len;
}

// -- Being asked who you are (NIP-42) ----------------------------------------
//
// A relay may send `["AUTH", <challenge>]`. Answering means signing a kind:22242
// event that names the relay and echoes the challenge, with the reader's key.
// That tells the relay whose connection this is, so it is never done without the
// reader's say: the first time a relay refuses us for want of it, a notice names
// the relay and the reader chooses Allow or Don't allow. The answer is kept per account and relay, so a
// second account on the same machine is asked for itself, and it can be changed
// in the relay's row.
//
// Nothing here happens because a relay greeted us. Plenty of public relays send
// a challenge on every connection and gate nothing, and answering those would
// both ask the reader about relays that do not care and tell those relays who
// they are. So a challenge is only kept, quietly, as the latest one that relay
// sent. The reader's choice is consulted when the relay actually refuses
// something with an `auth-required:` reason: allow answers and re-sends what was
// refused, don't allow does nothing, and ask raises the notice. A relay that
// never refuses anything is never asked about and never sent an AUTH.
//
// Three parties are involved and none of them may wait on another. The relay's
// reader thread hears the AUTH and the CLOSED and later sends the reply. The UI
// thread gets the signature, because the signer is reached through effects
// (Notary's loopback door, or a bunker over NIP-46) and a person may take a
// while to approve. So they meet in a per-relay slot under a spin lock, and each
// only reads the slot or moves it one step. The reader never blocks on a
// signature: it keeps reading, and the feed on every other relay is untouched.
//
// What is copied, and from where:
//   - A challenge is stored and an `auth-required:` CLOSED reuses it, because a
//     relay does not re-issue one (Amethyst RelayAuthenticator.kt:176-178,
//     :231-237, :273-290).
//   - Authentication is started by the refusal and not by the challenge: Jumble
//     calls its authenticator only from the `auth-required` branch of a REQ's
//     close handler (relay-subscription.ts:86-89), never when the challenge
//     arrives.
//   - The AUTH's OK is what re-sends the refused subscriptions, once, so a
//     refusal cannot loop (Amethyst RelayAuthenticator.kt:293-305; Jumble
//     relay-subscription.ts:86-100 restarts the REQ only after `authenticate`
//     resolves and only if it has not authed before).
//   - Whether to identify is the reader's decision per relay, asked once and
//     remembered (Amethyst AuthCoordinator.kt:117-149, :193-226). A CLOSED
//     that stays refused is a finished subscription, counted as settled and
//     not as data (Jumble relay-subscription.ts:107-110).

pub fn answerHelperAuthForTest(a: std.mem.Allocator, unsigned_json: []const u8) void {
    const secret = feed_state.g_test_secret orelse return;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = signer.keyPairFromSecretKey(secret) catch return;
    var parsed = nostr.event.fromJson(a, unsigned_json) catch return;
    defer parsed.deinit();
    const ev = parsed.value;
    const signed = nostr.event.create(a, signer, kp, ev.created_at, ev.kind, ev.tags, ev.content, null) catch return;
    const signed_json = nostr.event.toJson(a, signed) catch return;
    const body = (nostr.signer_ipc.SignEvent{ .event = signed_json }).toJson(a) catch return;
    handleHelperAuthSigned(.{ .key = helper_auth_key, .outcome = .ok, .status = 200, .body = body });
}

pub fn resetRelayAuthForTest() void {
    authLock();
    relay_auth.g_auth_choices = @splat(.{});
    relay_auth.g_auth_slots = @splat(.{});
    authUnlock();
    relay_auth.g_helper_auth_active = false;
    relay_auth.g_helper_auth_index = 0;
}

pub fn authChoiceForTest(url: []const u8) AuthChoice {
    return authChoiceFor(url);
}
pub fn authChoiceOfForTest(account: [32]u8, url: []const u8) AuthChoice {
    return authChoiceOf(account, url);
}
pub fn setAuthChoiceForTest(account: [32]u8, url: []const u8, choice: AuthChoice) bool {
    return setAuthChoice(account, url, choice);
}
pub fn authFileForTest(buf: []u8) ?[]const u8 {
    return formatAuthChoicesFile(buf);
}
pub fn applyAuthFileForTest(raw: []const u8) void {
    applyAuthChoicesFile(raw);
}
pub fn authPhaseNameForTest(index: usize) []const u8 {
    return @tagName(authSlotPhase(index));
}
pub fn authRowNoteForTest(index: usize) ?[]const u8 {
    return authRowNote(index);
}
pub fn authBadgeTextForTest(index: usize, url: []const u8) ?[]const u8 {
    return authBadgeText(index, url);
}
pub fn driveRelayAuthForTest(fx: *Effects) void {
    driveRelayAuth(fx);
}
pub fn authAnswerForTest(index: usize, allow: bool) void {
    authAnswer(index, allow);
}
pub fn authCycleForTest(index: usize) void {
    authCycle(index);
}
pub fn authSweepForTest(now_s: i64) void {
    authSweep(now_s);
}
pub fn authHelperBusyForTest() bool {
    return relay_auth.g_helper_auth_active;
}
/// The keyholder's answer to the request that was out has arrived and been
/// dropped, as `handleHelperAuthSigned` does, leaving it free for the next.
pub fn authHelperFreeForTest() void {
    relay_auth.g_helper_auth_active = false;
}
/// The connection on `index` has ended.
pub fn authSlotResetForTest(index: usize) void {
    authSlotReset(index);
}
pub fn authDeliverSignedForTest(index: usize, ev: nostr.event.Event) void {
    var verifier = nostr.keys.Signer.init();
    defer verifier.deinit();
    authDeliverSigned(std.heap.page_allocator, verifier, index, ev);
}

/// The reader thread's reaction, driven by a test with a stand-in relay.
pub const AuthSessionForTest = AuthSession;
pub const AuthReactionForTest = AuthReaction;
pub fn authReactForTest(sess: *AuthSession, url: []const u8, msg: nostr.message.RelayMessage, now_ms: i64) AuthReaction {
    return authReact(sess, url, msg, now_ms);
}
pub fn authPollForTest(sess: *AuthSession, url: []const u8, relay: anytype, now_ms: i64) []const u8 {
    return @tagName(authPoll(sess, url, relay, now_ms, identityGeneration()));
}
pub const auth_gate_wait_ms_for_test = auth_gate_wait_ms;

// re-exports: tuning.zig
pub const RowRange = tuning.RowRange;
pub const ancestor_body_lines = tuning.ancestor_body_lines;
pub const ancestor_bottom_pad = tuning.ancestor_bottom_pad;
pub const ancestor_chars_per_line = tuning.ancestor_chars_per_line;
pub const ancestor_identity_gap = tuning.ancestor_identity_gap;
pub const ancestor_line_height = tuning.ancestor_line_height;
pub const ancestor_row_chrome = tuning.ancestor_row_chrome;
pub const ancestor_top_pad = tuning.ancestor_top_pad;
pub const animation_interval_ms = tuning.animation_interval_ms;
pub const animation_timer_key = tuning.animation_timer_key;
pub const avatar_fetch_key_base = tuning.avatar_fetch_key_base;
pub const avatar_size = tuning.avatar_size;
pub const avatar_target_px = tuning.avatar_target_px;
pub const avatar_to_text_gap = tuning.avatar_to_text_gap;
pub const avatar_warm_key_base = tuning.avatar_warm_key_base;
pub const banner_target_px = tuning.banner_target_px;
pub const body_line_height = tuning.body_line_height;
pub const branch_more_extent = tuning.branch_more_extent;
pub const chrome_inset = tuning.chrome_inset;
pub const compose_capacity = tuning.compose_capacity;
pub const compose_editor_height = tuning.compose_editor_height;
pub const compose_editor_width = tuning.compose_editor_width;
pub const compose_sheet_width = tuning.compose_sheet_width;
pub const copy_nevent_key = tuning.copy_nevent_key;
pub const copy_note_text_key = tuning.copy_note_text_key;
pub const copy_nprofile_key = tuning.copy_nprofile_key;
pub const copy_npub_key = tuning.copy_npub_key;
pub const cover_notice_height = tuning.cover_notice_height;
pub const engagement_kinds = tuning.engagement_kinds;
pub const engagement_request_limit = tuning.engagement_request_limit;
pub const engagement_row_height = tuning.engagement_row_height;
pub const engagement_watch_cap = tuning.engagement_watch_cap;
pub const engagement_widen_ms = tuning.engagement_widen_ms;
pub const feed_page = tuning.feed_page;
pub const feed_prefetch_rows = tuning.feed_prefetch_rows;
pub const feed_request_limit = tuning.feed_request_limit;
pub const feed_row_chrome = tuning.feed_row_chrome;
pub const focal_body_scale = tuning.focal_body_scale;
pub const focal_leading_pad = tuning.focal_leading_pad;
pub const focal_row_chrome = tuning.focal_row_chrome;
pub const ghost_row_extent = tuning.ghost_row_extent;
pub const gif_target_px = tuning.gif_target_px;
pub const image_registry_slots = tuning.image_registry_slots;
pub const join_card_sub_scale = tuning.join_card_sub_scale;
pub const join_card_title_scale = tuning.join_card_title_scale;
pub const join_label_scale = tuning.join_label_scale;
pub const join_sheet_width = tuning.join_sheet_width;
pub const join_sub_scale = tuning.join_sub_scale;
pub const join_title_scale = tuning.join_title_scale;
pub const link_card_height = tuning.link_card_height;
pub const link_card_height_bare = tuning.link_card_height_bare;
pub const link_fetch_key_base = tuning.link_fetch_key_base;
pub const list_row_height = tuning.list_row_height;
pub const listening_row_extent = tuning.listening_row_extent;
pub const max_gif_frames = tuning.max_gif_frames;
pub const max_gif_total_bytes = tuning.max_gif_total_bytes;
pub const max_image_bytes = tuning.max_image_bytes;
pub const max_image_download_bytes = tuning.max_image_download_bytes;
pub const max_media_images = tuning.max_media_images;
pub const max_playing_gifs = tuning.max_playing_gifs;
pub const max_registered_image_bytes = tuning.max_registered_image_bytes;
pub const media_fetch_key_base = tuning.media_fetch_key_base;
pub const media_target_px = tuning.media_target_px;
pub const media_warm_key_base = tuning.media_warm_key_base;
pub const menu_scale = tuning.menu_scale;
pub const meta_scale = tuning.meta_scale;
pub const meta_size = tuning.meta_size;
pub const mono_badge_scale = tuning.mono_badge_scale;
pub const mono_chip_scale = tuning.mono_chip_scale;
pub const mono_hint_scale = tuning.mono_hint_scale;
pub const mono_meta_scale = tuning.mono_meta_scale;
pub const mono_row_scale = tuning.mono_row_scale;
pub const name_card_width = tuning.name_card_width;
pub const name_scale = tuning.name_scale;
pub const name_title_scale = tuning.name_title_scale;
pub const nested_avatar_size = tuning.nested_avatar_size;
pub const nested_body_scale = tuning.nested_body_scale;
pub const nested_line_height = tuning.nested_line_height;
pub const nested_meta_scale = tuning.nested_meta_scale;
pub const nested_name_scale = tuning.nested_name_scale;
pub const nested_reply_chrome = tuning.nested_reply_chrome;
pub const nip05_fetch_key_base = tuning.nip05_fetch_key_base;
pub const nip05_lookup_key_base = tuning.nip05_lookup_key_base;
pub const nip05_lookup_keys = tuning.nip05_lookup_keys;
pub const note_collapse_chars = tuning.note_collapse_chars;
pub const note_content_cap = tuning.note_content_cap;
pub const notification_age_height = tuning.notification_age_height;
pub const notification_body_lines = tuning.notification_body_lines;
pub const op_chip_scale = tuning.op_chip_scale;
pub const orphan_note_extent = tuning.orphan_note_extent;
pub const outside_row_extent = tuning.outside_row_extent;
pub const picture_ask_height = tuning.picture_ask_height;
pub const picture_chip_height = tuning.picture_chip_height;
pub const picture_chip_inset = tuning.picture_chip_inset;
pub const picture_column_width = tuning.picture_column_width;
pub const picture_default_aspect = tuning.picture_default_aspect;
pub const picture_max_aspect = tuning.picture_max_aspect;
pub const picture_radius = tuning.picture_radius;
pub const picture_stripe_cap = tuning.picture_stripe_cap;
pub const plaza_version = tuning.plaza_version;
pub const profile_about_capacity = tuning.profile_about_capacity;
pub const profile_autofill_max = tuning.profile_autofill_max;
pub const profile_avatar_lift = tuning.profile_avatar_lift;
pub const profile_avatar_size = tuning.profile_avatar_size;
pub const profile_banner_height = tuning.profile_banner_height;
pub const profile_bio_line_height = tuning.profile_bio_line_height;
pub const profile_cap = tuning.profile_cap;
pub const profile_card_chrome = tuning.profile_card_chrome;
pub const profile_edit_card_width = tuning.profile_edit_card_width;
pub const profile_fill_rows = tuning.profile_fill_rows;
pub const profile_interval_ms = tuning.profile_interval_ms;
pub const profile_links_height = tuning.profile_links_height;
pub const profile_name_scale = tuning.profile_name_scale;
pub const profile_notes_max = tuning.profile_notes_max;
pub const profile_page = tuning.profile_page;
pub const profile_relay_page = tuning.profile_relay_page;
pub const profile_timer_key = tuning.profile_timer_key;
pub const quiet_row_extent = tuning.quiet_row_extent;
pub const quote_aside_chrome = tuning.quote_aside_chrome;
pub const quote_body_lines = tuning.quote_body_lines;
pub const quote_picture_max_aspect = tuning.quote_picture_max_aspect;
pub const quote_picture_min_aspect = tuning.quote_picture_min_aspect;
pub const quote_picture_width = tuning.quote_picture_width;
pub const quote_pill_height = tuning.quote_pill_height;
pub const quote_pill_label_width = tuning.quote_pill_label_width;
pub const quote_quiet_chrome = tuning.quote_quiet_chrome;
pub const quote_skeleton_height = tuning.quote_skeleton_height;
pub const rail_gap = tuning.rail_gap;
pub const refresh_interval_ms = tuning.refresh_interval_ms;
pub const refresh_timer_key = tuning.refresh_timer_key;
pub const reply_context_snippet_chars = tuning.reply_context_snippet_chars;
pub const reply_editor_height = tuning.reply_editor_height;
pub const reply_row_extent = tuning.reply_row_extent;
pub const row_pad_bottom = tuning.row_pad_bottom;
pub const row_pad_side = tuning.row_pad_side;
pub const row_pad_top = tuning.row_pad_top;
pub const scope_title_scale = tuning.scope_title_scale;
pub const secret_file_permissions = tuning.secret_file_permissions;
pub const settings_card_radius = tuning.settings_card_radius;
pub const settings_column_width = tuning.settings_column_width;
pub const settings_content_width = tuning.settings_content_width;
pub const settings_header_height = tuning.settings_header_height;
pub const settings_label_gap = tuning.settings_label_gap;
pub const settings_section_gap = tuning.settings_section_gap;
pub const settings_title_scale = tuning.settings_title_scale;
pub const show_more_extent = tuning.show_more_extent;
pub const starter_pack = tuning.starter_pack;
pub const stat_scale = tuning.stat_scale;
pub const status_scale = tuning.status_scale;
pub const thread_depth_max = tuning.thread_depth_max;
pub const thread_inset = tuning.thread_inset;
pub const thread_loading_grace_s = tuning.thread_loading_grace_s;
pub const thread_reply_cap = tuning.thread_reply_cap;
pub const thread_reply_chrome = tuning.thread_reply_chrome;
pub const thread_skeleton_extent = tuning.thread_skeleton_extent;
pub const update_check_key = tuning.update_check_key;

// re-exports: hiding.zig
pub const Hideable = hiding.Hideable;
pub const HideableInfo = hiding.HideableInfo;
pub const applyHiddenLine = hiding.applyHiddenLine;
pub const countHidden = hiding.countHidden;
pub const engagementKinds = hiding.engagementKinds;
pub const hiddenCount = hiding.hiddenCount;
pub const hiddenLine = hiding.hiddenLine;
pub const hideables = hiding.hideables;
pub const isTakenAway = hiding.isTakenAway;
pub const setHidden = hiding.setHidden;

// re-exports: prefs.zig
pub const clientTag = prefs.clientTag;
pub const client_tag_name = prefs.client_tag_name;
pub const isMediaProxyUrl = prefs.isMediaProxyUrl;
pub const loadSettings = prefs.loadSettings;
pub const mediaDirectFallback = prefs.mediaDirectFallback;
pub const mediaPreviews = prefs.mediaPreviews;
pub const mediaProxy = prefs.mediaProxy;
pub const mediaProxyOn = prefs.mediaProxyOn;
pub const saveSettings = prefs.saveSettings;
pub const setClientTag = prefs.setClientTag;
pub const setMediaDirectFallback = prefs.setMediaDirectFallback;
pub const setMediaPreviews = prefs.setMediaPreviews;
pub const setMediaProxy = prefs.setMediaProxy;
pub const setMediaProxyOn = prefs.setMediaProxyOn;
pub const setShowSensitive = prefs.setShowSensitive;
pub const showSensitive = prefs.showSensitive;

// re-exports: updates.zig
pub const ReleaseNews = updates.ReleaseNews;
pub const handleUpdateChecked = updates.handleUpdateChecked;
pub const maybeCheckForUpdate = updates.maybeCheckForUpdate;
pub const newerRelease = updates.newerRelease;
pub const pendingUpdateUrl = updates.pendingUpdateUrl;
pub const pendingUpdateVersion = updates.pendingUpdateVersion;
pub const setUpdateCheck = updates.setUpdateCheck;
pub const updateCheckDue = updates.updateCheckDue;
pub const updateCheckOn = updates.updateCheckOn;

// re-exports: links.zig
pub const captureArgvLink = links.captureArgvLink;
pub const external_link_policy = links.external_link_policy;
pub const handlePlazaLink = links.handlePlazaLink;
pub const has_url_scheme = links.has_url_scheme;
pub const isSafeExternalUrl = links.isSafeExternalUrl;
pub const openExternally = links.openExternally;
pub const parsePlazaLink = links.parsePlazaLink;
pub const plaza_url_scheme_install = links.plaza_url_scheme_install;
pub const takePendingLink = links.takePendingLink;
pub const takeWrittenLinkIn = links.takeWrittenLinkIn;
pub const writePendingLinkIn = links.writePendingLinkIn;

// re-exports: login.zig
pub const AddressParse = login.AddressParse;
pub const AddressTarget = login.AddressTarget;
pub const LoginError = login.LoginError;
pub const LoginTarget = login.LoginTarget;
pub const Nip05Address = login.Nip05Address;
pub const SearchInput = login.SearchInput;
pub const classifyLogin = login.classifyLogin;
pub const classifySearch = login.classifySearch;
pub const nip05Address = login.nip05Address;
pub const nip05LookupUrl = login.nip05LookupUrl;
pub const nip05Resolve = login.nip05Resolve;
pub const parseAddress = login.parseAddress;

// re-exports: places.zig
pub const Place = places.Place;
pub const PlaceInfo = places.PlaceInfo;
pub const PlaceLink = places.PlaceLink;
pub const RelayHints = places.RelayHints;
pub const activePlace = places.activePlace;
pub const activePlaceIndex = places.activePlaceIndex;
pub const activePlaceLine = places.activePlaceLine;
pub const adoptOpenRoom = places.adoptOpenRoom;
pub const applyActivePlaceLine = places.applyActivePlaceLine;
pub const askPlace = places.askPlace;
pub const bootPlaceIndex = places.bootPlaceIndex;
pub const bouncePlace = places.bouncePlace;
pub const clearPlaceFeed = places.clearPlaceFeed;
pub const copyBounded = places.copyBounded;
pub const currentPlaceFeed = places.currentPlaceFeed;
pub const flushPlaceIds = places.flushPlaceIds;
pub const forgetPlaces = places.forgetPlaces;
pub const goToOwnPlaza = places.goToOwnPlaza;
pub const installThemeHooks = places.installThemeHooks;
pub const isSafeHandlerUrl = places.isSafeHandlerUrl;
pub const isSafeRelayUrl = places.isSafeRelayUrl;
pub const isSafeShareUrl = places.isSafeShareUrl;
pub const keptPlaceCount = places.keptPlaceCount;
pub const loadPlaces = places.loadPlaces;
pub const lockPlaceIds = places.lockPlaceIds;
pub const openKeptPlace = places.openKeptPlace;
pub const parsePlace = places.parsePlace;
pub const placeFeedCount = places.placeFeedCount;
pub const placeFeedWorker = places.placeFeedWorker;
pub const placeFetchStep = places.placeFetchStep;
pub const placeIndexOf = places.placeIndexOf;
pub const placeInfo = places.placeInfo;
pub const placeIsKept = places.placeIsKept;
pub const placeLink = places.placeLink;
pub const place_feed_cap = places.place_feed_cap;
pub const place_handler_url_cap = places.place_handler_url_cap;
pub const place_kind = places.place_kind;
pub const place_looking_toast = places.place_looking_toast;
pub const place_relay_cap = places.place_relay_cap;
pub const place_relays_cap = places.place_relays_cap;
pub const railOpen = places.railOpen;
pub const refreshPlaceFetch = places.refreshPlaceFetch;
pub const relayHost = places.relayHost;
pub const rememberPlaceIds = places.rememberPlaceIds;
pub const restoreOpenPlace = places.restoreOpenPlace;
pub const resumeVisit = places.resumeVisit;
pub const samePlace = places.samePlace;
pub const savePlaces = places.savePlaces;
pub const seedPlaceFeed = places.seedPlaceFeed;
pub const setPlaceLink = places.setPlaceLink;
pub const shareHost = places.shareHost;
pub const showPlacesRail = places.showPlacesRail;
pub const startPlaceFeed = places.startPlaceFeed;
pub const stepPlace = places.stepPlace;
pub const togglePlacesRail = places.togglePlacesRail;
pub const unlockPlaceIds = places.unlockPlaceIds;
pub const visitingPlace = places.visitingPlace;
pub const writePlaceDocument = places.writePlaceDocument;

// re-exports: relay_table.zig
pub const RelayDial = relay_table.RelayDial;
pub const RelayEntry = relay_table.RelayEntry;
pub const RelayUse = relay_table.RelayUse;
pub const addRelay = relay_table.addRelay;
pub const applyRelaysFile = relay_table.applyRelaysFile;
pub const bootstrap_relays = relay_table.bootstrap_relays;
pub const forgetRelayRemovals = relay_table.forgetRelayRemovals;
pub const formatRelaysFile = relay_table.formatRelaysFile;
pub const indexer_chunk = relay_table.indexer_chunk;
pub const indexer_relays = relay_table.indexer_relays;
pub const isRelayUrl = relay_table.isRelayUrl;
pub const loadRelays = relay_table.loadRelays;
pub const lockRelayTable = relay_table.lockRelayTable;
pub const max_relay_suggestions = relay_table.max_relay_suggestions;
pub const max_relays = relay_table.max_relays;
pub const noteRelayRemoved = relay_table.noteRelayRemoved;
pub const poolHoldsRelay = relay_table.poolHoldsRelay;
pub const relayAt = relay_table.relayAt;
pub const relayCount = relay_table.relayCount;
pub const relaySlots = relay_table.relaySlots;
pub const relaySnapshot = relay_table.relaySnapshot;
pub const relayUrlAt = relay_table.relayUrlAt;
pub const relayWasRemoved = relay_table.relayWasRemoved;
pub const relay_list_kind = relay_table.relay_list_kind;
pub const resetRelaysToBootstrap = relay_table.resetRelaysToBootstrap;
pub const saveRelays = relay_table.saveRelays;
pub const seedBootstrapRelays = relay_table.seedBootstrapRelays;
pub const unlockRelayTable = relay_table.unlockRelayTable;
pub const writeRelayCount = relay_table.writeRelayCount;

// re-exports: relay_list.zig
pub const adoptRelayList = relay_list.adoptRelayList;
pub const applyOwnRelayList = relay_list.applyOwnRelayList;
pub const canWriteRelayList = relay_list.canWriteRelayList;
pub const clearRelayListPublish = relay_list.clearRelayListPublish;
pub const flushRelayList = relay_list.flushRelayList;
pub const heldRelayListStamp = relay_list.heldRelayListStamp;
pub const ingestRelayList = relay_list.ingestRelayList;
pub const isReaderNote = relay_list.isReaderNote;
pub const publishRelayListReporting = relay_list.publishRelayListReporting;
pub const relayListDue = relay_list.relayListDue;
pub const relayListEdited = relay_list.relayListEdited;
pub const relayListIsOwned = relay_list.relayListIsOwned;
pub const relayWriteBlockedReason = relay_list.relayWriteBlockedReason;
pub const setRelayListStamp = relay_list.setRelayListStamp;

// re-exports: routing.zig
pub const RelayRank = routing.RelayRank;
pub const RouteCoverage = routing.RouteCoverage;
pub const RouteFollowUp = routing.RouteFollowUp;
pub const clearRelayRefusal = routing.clearRelayRefusal;
pub const clearRoutedLive = routing.clearRoutedLive;
pub const collectUnrouted = routing.collectUnrouted;
pub const discoveredAuthorCount = routing.discoveredAuthorCount;
pub const discoveredCount = routing.discoveredCount;
pub const discoveredSnapshot = routing.discoveredSnapshot;
pub const discoveredUrlCopy = routing.discoveredUrlCopy;
pub const discovered_authors_cap = routing.discovered_authors_cap;
pub const foldWriteRelays = routing.foldWriteRelays;
pub const followRouteChanges = routing.followRouteChanges;
pub const forgetDiscovered = routing.forgetDiscovered;
pub const forgetRelaySeen = routing.forgetRelaySeen;
pub const forgetRelaySuggestion = routing.forgetRelaySuggestion;
pub const lockDiscovered = routing.lockDiscovered;
pub const lockRefused = routing.lockRefused;
pub const markRelaySeen = routing.markRelaySeen;
pub const max_discovered_relays = routing.max_discovered_relays;
pub const maybeRankRelaySuggestions = routing.maybeRankRelaySuggestions;
pub const noteRelayRefusal = routing.noteRelayRefusal;
pub const noteRelayRefusalAt = routing.noteRelayRefusalAt;
pub const nowMillis = routing.nowMillis;
pub const outbox_relays_per_author = routing.outbox_relays_per_author;
pub const outbox_sub_id = routing.outbox_sub_id;
pub const poolAuthors = routing.poolAuthors;
pub const poolAuthorsOrAll = routing.poolAuthorsOrAll;
pub const rankRelaySuggestions = routing.rankRelaySuggestions;
pub const refusedRelays = routing.refusedRelays;
pub const relayFetchAllowed = routing.relayFetchAllowed;
pub const relayIsRefused = routing.relayIsRefused;
pub const relaySuggestionCopy = routing.relaySuggestionCopy;
pub const relaySuggestionCount = routing.relaySuggestionCount;
pub const relayUrlEql = routing.relayUrlEql;
pub const relaysSeenFor = routing.relaysSeenFor;
pub const routeFollowUp = routing.routeFollowUp;
pub const routeRecomputeDue = routing.routeRecomputeDue;
pub const route_coverage_target = routing.route_coverage_target;
pub const route_recompute_min_ms = routing.route_recompute_min_ms;
pub const route_settle_max_ms = routing.route_settle_max_ms;
pub const route_settle_ms = routing.route_settle_ms;
pub const routedSlotStillNames = routing.routedSlotStillNames;
pub const routed_refusal_ms = routing.routed_refusal_ms;
pub const routed_refusal_slots = routing.routed_refusal_slots;
pub const routed_refusal_strikes = routing.routed_refusal_strikes;
pub const sameRoute = routing.sameRoute;
pub const selectWriteRelays = routing.selectWriteRelays;
pub const setRoutedLive = routing.setRoutedLive;
pub const sweepRelayLists = routing.sweepRelayLists;
pub const unlockDiscovered = routing.unlockDiscovered;
pub const unlockRefused = routing.unlockRefused;
pub const worthEvicting = routing.worthEvicting;
pub const writeTagUrls = routing.writeTagUrls;

// re-exports: relay_conn.zig
pub const Conn = relay_conn.Conn;
pub const askPool = relay_conn.askPool;
pub const askableSlots = relay_conn.askableSlots;
pub const bunker_watch_slot = relay_conn.bunker_watch_slot;
pub const clearRelayRtt = relay_conn.clearRelayRtt;
pub const connHolds = relay_conn.connHolds;
pub const discovered_watch_base = relay_conn.discovered_watch_base;
pub const expiredOneShots = relay_conn.expiredOneShots;
pub const feed_sub_base = relay_conn.feed_sub_base;
pub const ingest_wake = relay_conn.ingest_wake;
pub const isFeedSub = relay_conn.isFeedSub;
pub const isOneShotSub = relay_conn.isOneShotSub;
pub const lockLiveRelay = relay_conn.lockLiveRelay;
pub const networkAllowed = relay_conn.networkAllowed;
pub const offerLiveRelay = relay_conn.offerLiveRelay;
pub const one_shot_already_cut = relay_conn.one_shot_already_cut;
pub const one_shot_budget_ms = relay_conn.one_shot_budget_ms;
pub const one_shot_slots = relay_conn.one_shot_slots;
pub const one_shot_sub_prefix = relay_conn.one_shot_sub_prefix;
pub const probeFilters = relay_conn.probeFilters;
pub const probe_interval_ms = relay_conn.probe_interval_ms;
pub const probe_sub = relay_conn.probe_sub;
pub const recordRelayRtt = relay_conn.recordRelayRtt;
pub const relayKeeper = relay_conn.relayKeeper;
pub const relayRttMs = relay_conn.relayRttMs;
pub const relay_watch_slots = relay_conn.relay_watch_slots;
pub const relaysPaused = relay_conn.relaysPaused;
pub const releaseOneShot = relay_conn.releaseOneShot;
pub const setRelayStatus = relay_conn.setRelayStatus;
pub const setRelaysPaused = relay_conn.setRelaysPaused;
pub const unlockLiveRelay = relay_conn.unlockLiveRelay;
pub const watchOneShot = relay_conn.watchOneShot;

// re-exports: store_glue.zig
pub const ownListBackups = store_glue.ownListBackups;
pub const ownRecordCreatedAt = store_glue.ownRecordCreatedAt;
pub const ownRecordExists = store_glue.ownRecordExists;
pub const plazaIngest = store_glue.plazaIngest;
pub const plazaIngestFrom = store_glue.plazaIngestFrom;

// re-exports: feed_state.zig
pub const FeedWork = feed_state.FeedWork;
pub const attachFeedStorage = feed_state.attachFeedStorage;
pub const authorInSet = feed_state.authorInSet;
pub const buildReuseIndex = feed_state.buildReuseIndex;
pub const clearFeedArrivals = feed_state.clearFeedArrivals;
pub const ensureFeedCapacity = feed_state.ensureFeedCapacity;
pub const eventNewer = feed_state.eventNewer;
pub const eventNewerThanNote = feed_state.eventNewerThanNote;
pub const feedCardFrom = feed_state.feedCardFrom;
pub const feedKeyOf = feed_state.feedKeyOf;
pub const feedSince = feed_state.feedSince;
pub const feedWork = feed_state.feedWork;
pub const feed_arrival_cap = feed_state.feed_arrival_cap;
pub const heldIndex = feed_state.heldIndex;
pub const invalidateFeed = feed_state.invalidateFeed;
pub const noteFeedArrival = feed_state.noteFeedArrival;
pub const noteFeedNewest = feed_state.noteFeedNewest;
pub const noteIdOf = feed_state.noteIdOf;
pub const placedReset = feed_state.placedReset;
pub const placedTake = feed_state.placedTake;
pub const resetFeedWork = feed_state.resetFeedWork;
pub const seedFeedNewest = feed_state.seedFeedNewest;
pub const takeFeedArrivals = feed_state.takeFeedArrivals;

// re-exports: thread_model.zig
pub const Ancestor = thread_model.Ancestor;
pub const AncestorGap = thread_model.AncestorGap;
pub const ArrivalTable = thread_model.ArrivalTable;
pub const GraphSplit = thread_model.GraphSplit;
pub const ThreadBlock = thread_model.ThreadBlock;
pub const arrangeThread = thread_model.arrangeThread;
pub const arrivalTableFor = thread_model.arrivalTableFor;
pub const collectThreadIds = thread_model.collectThreadIds;
pub const heldReplies = thread_model.heldReplies;
pub const nip10Parent = thread_model.nip10Parent;
pub const nip10References = thread_model.nip10References;
pub const nip10Root = thread_model.nip10Root;
pub const nip22Parent = thread_model.nip22Parent;
pub const nip22Root = thread_model.nip22Root;
pub const refreshAncestorChain = thread_model.refreshAncestorChain;
pub const replyParent = thread_model.replyParent;
pub const replyReferences = thread_model.replyReferences;
pub const replyRoot = thread_model.replyRoot;
pub const sortThreadNotes = thread_model.sortThreadNotes;
pub const splitByFollowGraph = thread_model.splitByFollowGraph;
pub const stampArrival = thread_model.stampArrival;
pub const threadQueryIds = thread_model.threadQueryIds;
pub const thread_ancestor_max = thread_model.thread_ancestor_max;

// re-exports: note_build.zig
pub const Imeta = note_build.Imeta;
pub const KindRender = note_build.KindRender;
pub const MediaKind = note_build.MediaKind;
pub const abbreviateNpub = note_build.abbreviateNpub;
pub const byteSize = note_build.byteSize;
pub const classifyMedia = note_build.classifyMedia;
pub const collectImageUrls = note_build.collectImageUrls;
pub const comment_kind = note_build.comment_kind;
pub const copyDisplayText = note_build.copyDisplayText;
pub const findQuoteRef = note_build.findQuoteRef;
pub const firstImageUrl = note_build.firstImageUrl;
pub const foldMathAlnum = note_build.foldMathAlnum;
pub const generic_repost_kind = note_build.generic_repost_kind;
pub const imetaAspect = note_build.imetaAspect;
pub const imetaFor = note_build.imetaFor;
pub const invisibleForDisplay = note_build.invisibleForDisplay;
pub const isBech32Char = note_build.isBech32Char;
pub const isEventRefStart = note_build.isEventRefStart;
pub const isHashtagChar = note_build.isHashtagChar;
pub const isRepostKind = note_build.isRepostKind;
pub const kindRender = note_build.kindRender;
pub const looksLikeImageUrl = note_build.looksLikeImageUrl;
pub const noteFrom = note_build.noteFrom;
pub const parseMentionAt = note_build.parseMentionAt;
pub const refPrecededByBoundary = note_build.refPrecededByBoundary;
pub const renderContent = note_build.renderContent;
pub const renderContentInto = note_build.renderContentInto;
pub const repostTargetId = note_build.repostTargetId;
pub const repost_kind = note_build.repost_kind;
pub const setAuthor = note_build.setAuthor;
pub const titleOf = note_build.titleOf;
pub const urlHost = note_build.urlHost;
pub const utf8SafeLen = note_build.utf8SafeLen;

// re-exports: profile_cache.zig
pub const Profile = profile_cache.Profile;
pub const WantedProfile = profile_cache.WantedProfile;
pub const buildRoutedFilters = profile_cache.buildRoutedFilters;
pub const clearProfilePicture = profile_cache.clearProfilePicture;
pub const handleNip05Fetched = profile_cache.handleNip05Fetched;
pub const lookupProfile = profile_cache.lookupProfile;
pub const markAvatarWanted = profile_cache.markAvatarWanted;
pub const nip05Matches = profile_cache.nip05Matches;
pub const parseMetadataInto = profile_cache.parseMetadataInto;
pub const profileLoading = profile_cache.profileLoading;
pub const quote_rearm_rounds = profile_cache.quote_rearm_rounds;
pub const refreshProfiles = profile_cache.refreshProfiles;
pub const requestWantedProfiles = profile_cache.requestWantedProfiles;
pub const scanNip05Fetches = profile_cache.scanNip05Fetches;
pub const upsertProfile = profile_cache.upsertProfile;
pub const validNip05Domain = profile_cache.validNip05Domain;
pub const validNip05Name = profile_cache.validNip05Name;
pub const wantProfile = profile_cache.wantProfile;
pub const wantProfileHinted = profile_cache.wantProfileHinted;
pub const wantProfilesAhead = profile_cache.wantProfilesAhead;
pub const wanted_profiles_cap = profile_cache.wanted_profiles_cap;

// re-exports: person_card.zig
pub const followsMe = person_card.followsMe;
pub const nip05Display = person_card.nip05Display;
pub const npubShortOf = person_card.npubShortOf;
pub const personAbout = person_card.personAbout;
pub const personAvatar = person_card.personAvatar;
pub const personBanner = person_card.personBanner;
pub const personCheck = person_card.personCheck;
pub const personFollowingCount = person_card.personFollowingCount;
pub const personIsNamed = person_card.personIsNamed;
pub const personLud16 = person_card.personLud16;
pub const personName = person_card.personName;
pub const personNpubShort = person_card.personNpubShort;
pub const personWebsite = person_card.personWebsite;
pub const verifiedNip05 = person_card.verifiedNip05;

// re-exports: quote_cache.zig
pub const QuoteEntry = quote_cache.QuoteEntry;
pub const QuoteState = quote_cache.QuoteState;
pub const address_dials_per_round = quote_cache.address_dials_per_round;
pub const noteHasEventQuote = quote_cache.noteHasEventQuote;
pub const quoteBackoffRounds = quote_cache.quoteBackoffRounds;
pub const quoteCovered = quote_cache.quoteCovered;
pub const quoteFor = quote_cache.quoteFor;
pub const quoteShownText = quote_cache.quoteShownText;
pub const quote_cache_cap = quote_cache.quote_cache_cap;
pub const quote_hint_dials_per_pass = quote_cache.quote_hint_dials_per_pass;
pub const rearmWantedQuotes = quote_cache.rearmWantedQuotes;
pub const refreshQuotes = quote_cache.refreshQuotes;
pub const requestWantedQuotes = quote_cache.requestWantedQuotes;
pub const requeueMissingQuotes = quote_cache.requeueMissingQuotes;
pub const wantQuote = quote_cache.wantQuote;
pub const wantQuoteHinted = quote_cache.wantQuoteHinted;

// re-exports: addresses.zig
pub const Address = addresses.Address;
pub const AddressQuery = addresses.AddressQuery;
pub const AddressSlot = addresses.AddressSlot;
pub const addressFor = addresses.addressFor;
pub const addressPoolFilters = addresses.addressPoolFilters;
pub const address_pool_batch = addresses.address_pool_batch;
pub const address_table_cap = addresses.address_table_cap;
pub const askAddressesOnPool = addresses.askAddressesOnPool;
pub const dialAddress = addresses.dialAddress;
pub const isPublicRelayUrl = addresses.isPublicRelayUrl;
pub const newestAddressId = addresses.newestAddressId;
pub const openAddressedArticle = addresses.openAddressedArticle;
pub const refreshAddressFetch = addresses.refreshAddressFetch;
pub const registerAddress = addresses.registerAddress;
pub const storedWriteRelays = addresses.storedWriteRelays;

// re-exports: link_preview.zig
pub const PageMeta = link_preview.PageMeta;
pub const firstLinkUrl = link_preview.firstLinkUrl;
pub const handleLinkFetched = link_preview.handleLinkFetched;
pub const isPrivateAddress = link_preview.isPrivateAddress;
pub const linkFor = link_preview.linkFor;
pub const parsePageMeta = link_preview.parsePageMeta;
pub const previewableUrl = link_preview.previewableUrl;
pub const scanLinkFetches = link_preview.scanLinkFetches;
pub const shouldPreviewLink = link_preview.shouldPreviewLink;
pub const storeLinkMeta = link_preview.storeLinkMeta;
pub const urlDomain = link_preview.urlDomain;
pub const wantLink = link_preview.wantLink;

// re-exports: relay_hints.zig
pub const HintList = relay_hints.HintList;
pub const UrlList = relay_hints.UrlList;
pub const hintOrEmpty = relay_hints.hintOrEmpty;
pub const hint_cap = relay_hints.hint_cap;
pub const hintsFor = relay_hints.hintsFor;
pub const isHintableRelay = relay_hints.isHintableRelay;
pub const noteAddress = relay_hints.noteAddress;
pub const note_address_cap = relay_hints.note_address_cap;
pub const pTagFor = relay_hints.pTagFor;
pub const profileAddress = relay_hints.profileAddress;
pub const recordSeenOn = relay_hints.recordSeenOn;
pub const recordSeenOnId = relay_hints.recordSeenOnId;
pub const seenOnLock = relay_hints.seenOnLock;
pub const seenOnUnlock = relay_hints.seenOnUnlock;

// re-exports: engagement.zig
pub const Counts = engagement.Counts;
pub const Engagement = engagement.Engagement;
pub const MyLike = engagement.MyLike;
pub const bolt11Msat = engagement.bolt11Msat;
pub const countEngagement = engagement.countEngagement;
pub const engagementFor = engagement.engagementFor;
pub const engagementLock = engagement.engagementLock;
pub const engagementTarget = engagement.engagementTarget;
pub const engagementUnlock = engagement.engagementUnlock;
pub const engagement_cap = engagement.engagement_cap;
pub const ensureEngagement = engagement.ensureEngagement;
pub const forgetLike = engagement.forgetLike;
pub const idPrefix = engagement.idPrefix;
pub const isLiked = engagement.isLiked;
pub const likeCountFor = engagement.likeCountFor;
pub const likeEntry = engagement.likeEntry;
pub const my_likes_cap = engagement.my_likes_cap;
pub const rememberLike = engagement.rememberLike;
pub const seen_engagement_cap = engagement.seen_engagement_cap;
pub const zap_msat_ceiling = engagement.zap_msat_ceiling;

// re-exports: inbox.zig
pub const InboxItem = inbox.InboxItem;
pub const InboxVerb = inbox.InboxVerb;
pub const bakeBody = inbox.bakeBody;
pub const collapseEventRefs = inbox.collapseEventRefs;
pub const inboxAdd = inbox.inboxAdd;
pub const inboxItems = inbox.inboxItems;
pub const inboxMarkAllRead = inbox.inboxMarkAllRead;
pub const inboxNeedsSave = inbox.inboxNeedsSave;
pub const inboxNewest = inbox.inboxNewest;
pub const inboxPageCount = inbox.inboxPageCount;
pub const inboxReadThrough = inbox.inboxReadThrough;
pub const inboxUnread = inbox.inboxUnread;
pub const inboxVerbFor = inbox.inboxVerbFor;
pub const inbox_cap = inbox.inbox_cap;
pub const inbox_kinds = inbox.inbox_kinds;
pub const inbox_per_author_max = inbox.inbox_per_author_max;
pub const loadInbox = inbox.loadInbox;
pub const lockInbox = inbox.lockInbox;
pub const markInboxDirty = inbox.markInboxDirty;
pub const resetInbox = inbox.resetInbox;
pub const resetInboxLocked = inbox.resetInboxLocked;
pub const resolveInboxBodies = inbox.resolveInboxBodies;
pub const saveInbox = inbox.saveInbox;
pub const subscribeInbox = inbox.subscribeInbox;
pub const unlockInbox = inbox.unlockInbox;
pub const wantInboxProfiles = inbox.wantInboxProfiles;

// re-exports: image_cache.zig
pub const MediaFit = image_cache.MediaFit;
pub const avatarUrl = image_cache.avatarUrl;
pub const cacheName = image_cache.cacheName;
pub const cachedImageExists = image_cache.cachedImageExists;
pub const decodeAndRegister = image_cache.decodeAndRegister;
pub const feedImageUrl = image_cache.feedImageUrl;
pub const feedImageUrlDirect = image_cache.feedImageUrlDirect;
pub const imageSizeUsable = image_cache.imageSizeUsable;
pub const isGifUrl = image_cache.isGifUrl;
pub const loadCachedImage = image_cache.loadCachedImage;
pub const mediaCacheDir = image_cache.mediaCacheDir;
pub const mediaUrl = image_cache.mediaUrl;
pub const stbi_image_free = image_cache.stbi_image_free;
pub const stbi_load_from_memory = image_cache.stbi_load_from_memory;
pub const stbi_load_gif_from_memory = image_cache.stbi_load_gif_from_memory;
pub const storeCachedImage = image_cache.storeCachedImage;

// re-exports: image_pool.zig
pub const WarmEntry = image_pool.WarmEntry;
pub const acquireImageId = image_pool.acquireImageId;
pub const assignAvatarSlots = image_pool.assignAvatarSlots;
pub const beginImagePass = image_pool.beginImagePass;
pub const chooseImageId = image_pool.chooseImageId;
pub const handleAvatarFetched = image_pool.handleAvatarFetched;
pub const handleAvatarWarmed = image_pool.handleAvatarWarmed;
pub const handleMediaWarmed = image_pool.handleMediaWarmed;
pub const imageIdOwners = image_pool.imageIdOwners;
pub const imageIdSeen = image_pool.imageIdSeen;
pub const scanAvatarFetches = image_pool.scanAvatarFetches;
pub const warmAhead = image_pool.warmAhead;
pub const warm_ring_len = image_pool.warm_ring_len;
pub const warmedAlready = image_pool.warmedAlready;

// re-exports: feed_media.zig
pub const Download = feed_media.Download;
pub const ImageFailure = feed_media.ImageFailure;
pub const MediaSlot = feed_media.MediaSlot;
pub const SliceOutcome = feed_media.SliceOutcome;
pub const advanceAnimations = feed_media.advanceAnimations;
pub const claimMediaSlot = feed_media.claimMediaSlot;
pub const classifyImageFailure = feed_media.classifyImageFailure;
pub const fetchSlice = feed_media.fetchSlice;
pub const forgetProxyRefusals = feed_media.forgetProxyRefusals;
pub const handleMediaFetched = feed_media.handleMediaFetched;
pub const hostOf = feed_media.hostOf;
pub const max_image_attempts = feed_media.max_image_attempts;
pub const mediaFailed = feed_media.mediaFailed;
pub const mediaKey = feed_media.mediaKey;
pub const mediaSlotFor = feed_media.mediaSlotFor;
pub const mediaSlotIndex = feed_media.mediaSlotIndex;
pub const proxyRefusedHost = feed_media.proxyRefusedHost;
pub const proxyRefusesHost = feed_media.proxyRefusesHost;
pub const quoteCardShown = feed_media.quoteCardShown;
pub const quoteMediaKey = feed_media.quoteMediaKey;
pub const rangeHeader = feed_media.rangeHeader;
pub const recalledAspect = feed_media.recalledAspect;
pub const rememberAspect = feed_media.rememberAspect;
pub const rememberHostRefusal = feed_media.rememberHostRefusal;
pub const rememberProxyRefusal = feed_media.rememberProxyRefusal;
pub const retryFailedImages = feed_media.retryFailedImages;
pub const scanMediaFetches = feed_media.scanMediaFetches;

// re-exports: own_lists.zig
pub const FreshAsk = own_lists.FreshAsk;
pub const ListKind = own_lists.ListKind;
pub const OwnListsRead = own_lists.OwnListsRead;
pub const askFreshFirst = own_lists.askFreshFirst;
pub const bookmarkBlockedReason = own_lists.bookmarkBlockedReason;
pub const confirmStartFresh = own_lists.confirmStartFresh;
pub const contactsConfirmedAbsent = own_lists.contactsConfirmedAbsent;
pub const followBlockedReason = own_lists.followBlockedReason;
pub const forgetFresh = own_lists.forgetFresh;
pub const forgetOwnListMemo = own_lists.forgetOwnListMemo;
pub const haveOwnContactList = own_lists.haveOwnContactList;
pub const listHeld = own_lists.listHeld;
pub const muteBlockedReason = own_lists.muteBlockedReason;
pub const needsFreshConsent = own_lists.needsFreshConsent;
pub const noHistoryKnown = own_lists.noHistoryKnown;
pub const noListToast = own_lists.noListToast;
pub const noListToastIn = own_lists.noListToastIn;
pub const noteContactsAnsweredBy = own_lists.noteContactsAnsweredBy;
pub const noteOwnContactListStored = own_lists.noteOwnContactListStored;
pub const noteOwnOutbox = own_lists.noteOwnOutbox;
pub const ownListsAdvice = own_lists.ownListsAdvice;
pub const ownListsProgress = own_lists.ownListsProgress;
pub const ownListsRead = own_lists.ownListsRead;
pub const ownRelaysAllFinished = own_lists.ownRelaysAllFinished;
pub const retryOwnListsRead = own_lists.retryOwnListsRead;
pub const startedFresh = own_lists.startedFresh;
pub const takeFresh = own_lists.takeFresh;

// re-exports: follows.zig
pub const FollowWrite = follows.FollowWrite;
pub const HomeScope = follows.HomeScope;
pub const PendingUndo = follows.PendingUndo;
pub const applyUndo = follows.applyUndo;
pub const armUndo = follows.armUndo;
pub const bookmark_list_kind = follows.bookmark_list_kind;
pub const buildFeedFilters = follows.buildFeedFilters;
pub const bumpIdentityGeneration = follows.bumpIdentityGeneration;
pub const canWriteFollows = follows.canWriteFollows;
pub const clearPendingFollowBase = follows.clearPendingFollowBase;
pub const contact_list_kind = follows.contact_list_kind;
pub const countPeople = follows.countPeople;
pub const feed_filter_kinds = follows.feed_filter_kinds;
pub const feed_kind_cap = follows.feed_kind_cap;
pub const followGeneration = follows.followGeneration;
pub const followSet = follows.followSet;
pub const followSnapshot = follows.followSnapshot;
pub const followTotal = follows.followTotal;
pub const followTotalOwned = follows.followTotalOwned;
pub const follow_chunk = follows.follow_chunk;
pub const followsFromTags = follows.followsFromTags;
pub const forgetFollows = follows.forgetFollows;
pub const hexEqlIgnoreCase = follows.hexEqlIgnoreCase;
pub const homeReadsPack = follows.homeReadsPack;
pub const homeScope = follows.homeScope;
pub const homeScopeSwitchable = follows.homeScopeSwitchable;
pub const identityGeneration = follows.identityGeneration;
pub const inFollowGraph = follows.inFollowGraph;
pub const ingestContactList = follows.ingestContactList;
pub const isFollowedByMe = follows.isFollowedByMe;
pub const isInReadGraph = follows.isInReadGraph;
pub const loadFollowsFromStore = follows.loadFollowsFromStore;
pub const max_bookmarks = follows.max_bookmarks;
pub const max_feed_filters = follows.max_feed_filters;
pub const max_follows = follows.max_follows;
pub const max_mutes = follows.max_mutes;
pub const mute_list_kind = follows.mute_list_kind;
pub const releasePendingFollowBase = follows.releasePendingFollowBase;
pub const releaseUndo = follows.releaseUndo;
pub const setFollows = follows.setFollows;
pub const setHomeScope = follows.setHomeScope;
pub const setPendingFollowBase = follows.setPendingFollowBase;
pub const shrinkAllowed = follows.shrinkAllowed;
pub const writeFollow = follows.writeFollow;

// re-exports: mutes.zig
pub const MuteWrite = mutes.MuteWrite;
pub const forgetMutes = mutes.forgetMutes;
pub const ingestMuteList = mutes.ingestMuteList;
pub const isMuted = mutes.isMuted;
pub const loadMutesFromStore = mutes.loadMutesFromStore;
pub const lockMutes = mutes.lockMutes;
pub const muteCount = mutes.muteCount;
pub const mutesAreOwned = mutes.mutesAreOwned;
pub const privateMutes = mutes.privateMutes;
pub const setMutes = mutes.setMutes;
pub const unlockMutes = mutes.unlockMutes;
pub const writeMute = mutes.writeMute;

// re-exports: bookmarks.zig
pub const BookmarkWrite = bookmarks.BookmarkWrite;
pub const bookmarkAt = bookmarks.bookmarkAt;
pub const bookmarkCount = bookmarks.bookmarkCount;
pub const bookmarksAreOwned = bookmarks.bookmarksAreOwned;
pub const finishPrivateBookmark = bookmarks.finishPrivateBookmark;
pub const forgetBookmarks = bookmarks.forgetBookmarks;
pub const handlePrivateSeal = bookmarks.handlePrivateSeal;
pub const ingestBookmarkList = bookmarks.ingestBookmarkList;
pub const isBookmarked = bookmarks.isBookmarked;
pub const loadBookmarksFromStore = bookmarks.loadBookmarksFromStore;
pub const writeBookmark = bookmarks.writeBookmark;
pub const writePrivateBookmark = bookmarks.writePrivateBookmark;

// re-exports: private_lists.zig
pub const HalfAskEnd = private_lists.HalfAskEnd;
pub const beginHelperAsk = private_lists.beginHelperAsk;
pub const endHalfAsk = private_lists.endHalfAsk;
pub const forgetPrivateHalves = private_lists.forgetPrivateHalves;
pub const halfAwaiting = private_lists.halfAwaiting;
pub const handlePrivateHalf = private_lists.handlePrivateHalf;
pub const parkHalfAnswer = private_lists.parkHalfAnswer;
pub const privateHalfGate = private_lists.privateHalfGate;
pub const privateHalfId = private_lists.privateHalfId;
pub const privateHalfIsReadable = private_lists.privateHalfIsReadable;
pub const privateHalfKey = private_lists.privateHalfKey;
pub const privateHalfOpened = private_lists.privateHalfOpened;
pub const private_half_retry_s = private_lists.private_half_retry_s;
pub const private_seal_key = private_lists.private_seal_key;
pub const rearmPrivateHalves = private_lists.rearmPrivateHalves;
pub const sameRecord = private_lists.sameRecord;
pub const scanPrivateHalves = private_lists.scanPrivateHalves;

// re-exports: keyholder.zig
pub const HelperState = keyholder.HelperState;
pub const adoptHelperIdentity = keyholder.adoptHelperIdentity;
pub const beginCreate = keyholder.beginCreate;
pub const ceremonyCanTakeKey = keyholder.ceremonyCanTakeKey;
pub const driveHelperSetup = keyholder.driveHelperSetup;
pub const driveUnlockPrompt = keyholder.driveUnlockPrompt;
pub const exeDir = keyholder.exeDir;
pub const handleHelperPubkey = keyholder.handleHelperPubkey;
pub const handleHelperSetup = keyholder.handleHelperSetup;
pub const handleHelperSigned = keyholder.handleHelperSigned;
pub const handleNotaryExited = keyholder.handleNotaryExited;
pub const helperFetch = keyholder.helperFetch;
pub const helperReachable = keyholder.helperReachable;
pub const helperSetupMayFire = keyholder.helperSetupMayFire;
pub const helperState = keyholder.helperState;
pub const helperToken = keyholder.helperToken;
pub const helper_poll_key = keyholder.helper_poll_key;
pub const helper_port_prefix = keyholder.helper_port_prefix;
pub const helper_restart_limit = keyholder.helper_restart_limit;
pub const helper_sign_key = keyholder.helper_sign_key;
pub const helper_sign_timeout_ms = keyholder.helper_sign_timeout_ms;
pub const helper_sign_timeout_s = keyholder.helper_sign_timeout_s;
pub const keyholderMissing = keyholder.keyholderMissing;
pub const openNotaryAvailable = keyholder.openNotaryAvailable;
pub const pollHelper = keyholder.pollHelper;
pub const releaseHelperSign = keyholder.releaseHelperSign;
pub const requestHelperSign = keyholder.requestHelperSign;
pub const resolveHelper = keyholder.resolveHelper;
pub const resolveNotaryWindow = keyholder.resolveNotaryWindow;
pub const resolveSibling = keyholder.resolveSibling;
pub const restoreHelperIdentity = keyholder.restoreHelperIdentity;
pub const scanHelperSign = keyholder.scanHelperSign;
pub const signInFlight = keyholder.signInFlight;
pub const signerReady = keyholder.signerReady;
pub const spawnHelper = keyholder.spawnHelper;
pub const spawnNotaryWindow = keyholder.spawnNotaryWindow;

// re-exports: remote_signer.zig
pub const RemoteMethod = remote_signer.RemoteMethod;
pub const abandonRemoteSigner = remote_signer.abandonRemoteSigner;
pub const bunkerConnecting = remote_signer.bunkerConnecting;
pub const clearPending = remote_signer.clearPending;
pub const connectRemoteSigner = remote_signer.connectRemoteSigner;
pub const connectWentQuiet = remote_signer.connectWentQuiet;
pub const driveBunkerConnect = remote_signer.driveBunkerConnect;
pub const failPending = remote_signer.failPending;
pub const handleNip46Response = remote_signer.handleNip46Response;
pub const hexLower = remote_signer.hexLower;
pub const isNip04Payload = remote_signer.isNip04Payload;
pub const newRemoteGeneration = remote_signer.newRemoteGeneration;
pub const newRequestId = remote_signer.newRequestId;
pub const nip46ReceiveLoop = remote_signer.nip46ReceiveLoop;
pub const no_half_id = remote_signer.no_half_id;
pub const pendingLock = remote_signer.pendingLock;
pub const pendingUnlock = remote_signer.pendingUnlock;
pub const registerPending = remote_signer.registerPending;
pub const remoteDecryptMethod = remote_signer.remoteDecryptMethod;
pub const requestRemoteDecrypt = remote_signer.requestRemoteDecrypt;
pub const requestRemoteEncrypt = remote_signer.requestRemoteEncrypt;
pub const requestRemoteSign = remote_signer.requestRemoteSign;
pub const requestRemoteSignAs = remote_signer.requestRemoteSignAs;
pub const scanPendingRemote = remote_signer.scanPendingRemote;
pub const sendConnect = remote_signer.sendConnect;
pub const sendRequest = remote_signer.sendRequest;
pub const takeAnswered = remote_signer.takeAnswered;
pub const takePending = remote_signer.takePending;

// re-exports: drafts.zig
pub const applyStashedDraft = drafts.applyStashedDraft;
pub const draftWarningOf = drafts.draftWarningOf;
pub const forgetReplyDrafts = drafts.forgetReplyDrafts;
pub const keepReplyDraft = drafts.keepReplyDraft;
pub const loadDraft = drafts.loadDraft;
pub const parkReplyDraft = drafts.parkReplyDraft;
pub const readDraft = drafts.readDraft;
pub const saveDraft = drafts.saveDraft;
pub const takeReplyDraft = drafts.takeReplyDraft;
pub const writeDraft = drafts.writeDraft;

// re-exports: session.zig
pub const legacyKeyOnDisk = session.legacyKeyOnDisk;
pub const performLogout = session.performLogout;
pub const persistSession = session.persistSession;
pub const plazaDir = session.plazaDir;
pub const restoreSession = session.restoreSession;

// re-exports: own_profile.zig
pub const OwnProfile = own_profile.OwnProfile;
pub const askVerdict = own_profile.askVerdict;
pub const forgetOwnProfileAnswer = own_profile.forgetOwnProfileAnswer;
pub const forgetOwnRecordAnswers = own_profile.forgetOwnRecordAnswers;
pub const freeOwnProfile = own_profile.freeOwnProfile;
pub const lockOwnProfile = own_profile.lockOwnProfile;
pub const looksLikeAddress = own_profile.looksLikeAddress;
pub const looksLikeUrl = own_profile.looksLikeUrl;
pub const mergeNameJson = own_profile.mergeNameJson;
pub const mergeProfileJson = own_profile.mergeProfileJson;
pub const noteOwnContactsAnswered = own_profile.noteOwnContactsAnswered;
pub const openProfileEdit = own_profile.openProfileEdit;
pub const ownContactsAnswered = own_profile.ownContactsAnswered;
pub const ownProfileAnswered = own_profile.ownProfileAnswered;
pub const ownProfileJson = own_profile.ownProfileJson;
pub const ownRecordJson = own_profile.ownRecordJson;
pub const own_profile_wait_s = own_profile.own_profile_wait_s;
pub const publishName = own_profile.publishName;
pub const replayPending = own_profile.replayPending;
pub const saveProfile = own_profile.saveProfile;
pub const seedProfileFields = own_profile.seedProfileFields;
pub const startOwnProfileFetch = own_profile.startOwnProfileFetch;
pub const stringField = own_profile.stringField;
pub const trimmedField = own_profile.trimmedField;
pub const unlockOwnProfile = own_profile.unlockOwnProfile;

// re-exports: uploads.zig
pub const UploadJob = uploads.UploadJob;
pub const UploadTarget = uploads.UploadTarget;
pub const UploadedPicture = uploads.UploadedPicture;
pub const acceptUploadAuth = uploads.acceptUploadAuth;
pub const appendPictureToDraft = uploads.appendPictureToDraft;
pub const blossom_list_kind = uploads.blossom_list_kind;
pub const driveUpload = uploads.driveUpload;
pub const dropUpload = uploads.dropUpload;
pub const parkUploadSign = uploads.parkUploadSign;
pub const tokenNamesFile = uploads.tokenNamesFile;
pub const uploadCancel = uploads.uploadCancel;
pub const uploadGo = uploads.uploadGo;
pub const uploadJobFor = uploads.uploadJobFor;
pub const uploadPick = uploads.uploadPick;
pub const uploadRetry = uploads.uploadRetry;
pub const uploadSignFailed = uploads.uploadSignFailed;
pub const uploadedImeta = uploads.uploadedImeta;
pub const uploadedPictureFor = uploads.uploadedPictureFor;

// re-exports: media_servers.zig
pub const BlossomWrite = media_servers.BlossomWrite;
pub const blossomAdd = media_servers.blossomAdd;
pub const blossomProbeAsking = media_servers.blossomProbeAsking;
pub const blossomProbeWantedUnlocked = media_servers.blossomProbeWantedUnlocked;
pub const blossomRemove = media_servers.blossomRemove;
pub const canWriteBlossomList = media_servers.canWriteBlossomList;
pub const forgetBlossom = media_servers.forgetBlossom;
pub const haveOwnBlossomList = media_servers.haveOwnBlossomList;
pub const ingestBlossomList = media_servers.ingestBlossomList;
pub const loadBlossomFromStore = media_servers.loadBlossomFromStore;
pub const lockBlossom = media_servers.lockBlossom;
pub const probeReplyAnswers = media_servers.probeReplyAnswers;
pub const probe_clean = media_servers.probe_clean;
pub const probe_unknown = media_servers.probe_unknown;
pub const sayBlossomAdd = media_servers.sayBlossomAdd;
pub const setBlossomServers = media_servers.setBlossomServers;
pub const startBlossomProbe = media_servers.startBlossomProbe;
pub const unlockBlossom = media_servers.unlockBlossom;
pub const uploadServers = media_servers.uploadServers;
pub const writeBlossomServers = media_servers.writeBlossomServers;

// re-exports: view_upload.zig
pub const blossomStatusText = view_upload.blossomStatusText;
pub const mediaServersCard = view_upload.mediaServersCard;
pub const profilePictureField = view_upload.profilePictureField;
pub const uploadStrip = view_upload.uploadStrip;

// re-exports: compose.zig
pub const WarnCarry = compose.WarnCarry;
pub const clearRepostedByMe = compose.clearRepostedByMe;
pub const clientOf = compose.clientOf;
pub const client_name_bytes = compose.client_name_bytes;
pub const clipToChars = compose.clipToChars;
pub const contentNames = compose.contentNames;
pub const contentTags = compose.contentTags;
pub const contentWarningIn = compose.contentWarningIn;
pub const contentWarningOf = compose.contentWarningOf;
pub const deletableTarget = compose.deletableTarget;
pub const deleteNote = compose.deleteNote;
pub const drivePendingIntent = compose.drivePendingIntent;
pub const dupeTags = compose.dupeTags;
pub const firePost = compose.firePost;
pub const fireReply = compose.fireReply;
pub const hexAlloc = compose.hexAlloc;
pub const ingestAndPublish = compose.ingestAndPublish;
pub const like = compose.like;
pub const markOutboxSending = compose.markOutboxSending;
pub const markRepostedByMe = compose.markRepostedByMe;
pub const max_mention_tags = compose.max_mention_tags;
pub const max_topic_bytes = compose.max_topic_bytes;
pub const mentionExcluded = compose.mentionExcluded;
pub const notifiedBy = compose.notifiedBy;
pub const postIsDue = compose.postIsDue;
pub const postSecondsLeft = compose.postSecondsLeft;
pub const publishWorker = compose.publishWorker;
pub const repost = compose.repost;
pub const repostContent = compose.repostContent;
pub const signAndPublish = compose.signAndPublish;
pub const submitPost = compose.submitPost;
pub const timeSpans = compose.timeSpans;
pub const toggleLike = compose.toggleLike;
pub const viaSuffix = compose.viaSuffix;
pub const warning_input_capacity = compose.warning_input_capacity;
pub const warning_reason_bytes = compose.warning_reason_bytes;
pub const withClientTag = compose.withClientTag;
pub const withContentWarning = compose.withContentWarning;

// re-exports: outbox.zig
pub const OutboxCounts = outbox.OutboxCounts;
pub const OutboxEntry = outbox.OutboxEntry;
pub const OutboxState = outbox.OutboxState;
pub const PlaceRoute = outbox.PlaceRoute;
pub const collectOutboxDue = outbox.collectOutboxDue;
pub const drainOutbox = outbox.drainOutbox;
pub const enqueueOutbox = outbox.enqueueOutbox;
pub const forgetOutboxAcks = outbox.forgetOutboxAcks;
pub const loadOutbox = outbox.loadOutbox;
pub const outboxCounts = outbox.outboxCounts;
pub const outboxEntryFor = outbox.outboxEntryFor;
pub const outboxHasRoom = outbox.outboxHasRoom;
pub const outboxLock = outbox.outboxLock;
pub const outboxPending = outbox.outboxPending;
pub const outboxRetryDelay = outbox.outboxRetryDelay;
pub const outboxSnapshot = outbox.outboxSnapshot;
pub const outboxUnlock = outbox.outboxUnlock;
pub const outbox_cap = outbox.outbox_cap;
pub const outbox_sent_linger_s = outbox.outbox_sent_linger_s;
pub const poolHasRelay = outbox.poolHasRelay;
pub const publishEvent = outbox.publishEvent;
pub const recordOutboxAck = outbox.recordOutboxAck;
pub const rounds_before_stuck = outbox.rounds_before_stuck;
pub const routeForOpenPlace = outbox.routeForOpenPlace;
pub const saveOutbox = outbox.saveOutbox;
pub const sweepOutbox = outbox.sweepOutbox;
pub const syncOutboxOwner = outbox.syncOutboxOwner;

// re-exports: people_search.zig
pub const SearchJob = people_search.SearchJob;
pub const SearchRow = people_search.SearchRow;
pub const awakeMs = people_search.awakeMs;
pub const handleNip05Found = people_search.handleNip05Found;
pub const hydrateProfiles = people_search.hydrateProfiles;
pub const lockSearchIndex = people_search.lockSearchIndex;
pub const nip05Pending = people_search.nip05Pending;
pub const searchAccept = people_search.searchAccept;
pub const searchArrived = people_search.searchArrived;
pub const searchIndexRefresh = people_search.searchIndexRefresh;
pub const searchOnEdit = people_search.searchOnEdit;
pub const searchOpen = people_search.searchOpen;
pub const searchPick = people_search.searchPick;
pub const searchRelayStatus = people_search.searchRelayStatus;
pub const searchRelays = people_search.searchRelays;
pub const searchReset = people_search.searchReset;
pub const searchTick = people_search.searchTick;
pub const search_inbox_cap = people_search.search_inbox_cap;
pub const search_rows_max = people_search.search_rows_max;
pub const search_scan_page = people_search.search_scan_page;
pub const submitAddress = people_search.submitAddress;
pub const unlockSearchIndex = people_search.unlockSearchIndex;

// re-exports: profile_notes.zig
pub const ProfileOlderAsk = profile_notes.ProfileOlderAsk;
pub const ProfileSeen = profile_notes.ProfileSeen;
pub const armProfileReach = profile_notes.armProfileReach;
pub const buildProfileNewestFilter = profile_notes.buildProfileNewestFilter;
pub const buildProfileOlderFilter = profile_notes.buildProfileOlderFilter;
pub const loadAtProfileBottom = profile_notes.loadAtProfileBottom;
pub const loadOlderProfile = profile_notes.loadOlderProfile;
pub const noteProfileReach = profile_notes.noteProfileReach;
pub const profileEndKey = profile_notes.profileEndKey;
pub const profileEndReached = profile_notes.profileEndReached;
pub const profileReach = profile_notes.profileReach;
pub const profileRound = profile_notes.profileRound;
pub const profileRoundEnded = profile_notes.profileRoundEnded;
pub const profileTargets = profile_notes.profileTargets;
pub const profile_round_targets = profile_notes.profile_round_targets;
pub const resetProfileEnd = profile_notes.resetProfileEnd;
pub const roundReach = profile_notes.roundReach;
pub const writeRelaysOf = profile_notes.writeRelaysOf;

// re-exports: navigation.zig
pub const Standing = navigation.Standing;
pub const buildOlderFilters = navigation.buildOlderFilters;
pub const closeAddress = navigation.closeAddress;
pub const closeThread = navigation.closeThread;
pub const engagementFilter = navigation.engagementFilter;
pub const enterEvent = navigation.enterEvent;
pub const enterProfile = navigation.enterProfile;
pub const enterSettings = navigation.enterSettings;
pub const enterThread = navigation.enterThread;
pub const feedEndLatches = navigation.feedEndLatches;
pub const feedEndReached = navigation.feedEndReached;
pub const fetchOlderNotes = navigation.fetchOlderNotes;
pub const goHome = navigation.goHome;
pub const openAddress = navigation.openAddress;
pub const openBookmarks = navigation.openBookmarks;
pub const openEvent = navigation.openEvent;
pub const openPerson = navigation.openPerson;
pub const openThread = navigation.openThread;
pub const openTopic = navigation.openTopic;
pub const profile_fetch_messages = navigation.profile_fetch_messages;
pub const refreshEventFetch = navigation.refreshEventFetch;
pub const resetFeedEnd = navigation.resetFeedEnd;
pub const standingNow = navigation.standingNow;
pub const swapThreadRoot = navigation.swapThreadRoot;
pub const topicFilter = navigation.topicFilter;

// re-exports: relay_auth.zig
pub const AuthChoice = relay_auth.AuthChoice;
pub const AuthReaction = relay_auth.AuthReaction;
pub const AuthSession = relay_auth.AuthSession;
pub const applyAuthChoicesFile = relay_auth.applyAuthChoicesFile;
pub const authAnswer = relay_auth.authAnswer;
pub const authAsking = relay_auth.authAsking;
pub const authAskingCount = relay_auth.authAskingCount;
pub const authAskingSummary = relay_auth.authAskingSummary;
pub const authBadgeText = relay_auth.authBadgeText;
pub const authChoiceFor = relay_auth.authChoiceFor;
pub const authChoiceOf = relay_auth.authChoiceOf;
pub const authCycle = relay_auth.authCycle;
pub const authDeliverSigned = relay_auth.authDeliverSigned;
pub const authFailSigning = relay_auth.authFailSigning;
pub const authLock = relay_auth.authLock;
pub const authPoll = relay_auth.authPoll;
pub const authReact = relay_auth.authReact;
pub const authRowNote = relay_auth.authRowNote;
pub const authSlotPhase = relay_auth.authSlotPhase;
pub const authSlotReset = relay_auth.authSlotReset;
pub const authSweep = relay_auth.authSweep;
pub const authUnlock = relay_auth.authUnlock;
pub const auth_gate_wait_ms = relay_auth.auth_gate_wait_ms;
pub const driveRelayAuth = relay_auth.driveRelayAuth;
pub const formatAuthChoicesFile = relay_auth.formatAuthChoicesFile;
pub const handleHelperAuthSigned = relay_auth.handleHelperAuthSigned;
pub const helper_auth_key = relay_auth.helper_auth_key;
pub const loadAuthChoices = relay_auth.loadAuthChoices;
pub const setAuthChoice = relay_auth.setAuthChoice;

// re-exports: ingest.zig
pub const discoveredRelayThread = ingest.discoveredRelayThread;
pub const feedWatchGeneration = ingest.feedWatchGeneration;
pub const ingestRelay = ingest.ingestRelay;
pub const mergeFeedWatch = ingest.mergeFeedWatch;
pub const nextReconnectAttempts = ingest.nextReconnectAttempts;
pub const publishFeedWatch = ingest.publishFeedWatch;
pub const reconnectDelayMs = ingest.reconnectDelayMs;
pub const reconnectJitterMs = ingest.reconnectJitterMs;
pub const rememberFeedId = ingest.rememberFeedId;

test {
    _ = @import("tests.zig");
    _ = @import("blossom.zig");
}

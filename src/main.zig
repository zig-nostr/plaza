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
const view_media = @import("view_media.zig");
const view_note = @import("view_note.zig");
const view_chrome = @import("view_chrome.zig");
const view_place = @import("view_place.zig");
const view_rail = @import("view_rail.zig");
const view_feed = @import("view_feed.zig");
const view_profile = @import("view_profile.zig");
const view_article = @import("view_article.zig");
const view_thread = @import("view_thread.zig");
const view_compose = @import("view_compose.zig");
const view_notifications = @import("view_notifications.zig");
const view_search = @import("view_search.zig");
const view_sheets = @import("view_sheets.zig");
const view_settings = @import("view_settings.zig");

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
pub const thread_column_width: f32 = feed_column_width;

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
pub fn topicLinkFor(word: []const u8) ?[]const u8 {
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
    const set = &view_thread.g_level_visible[0];
    set.reset();
    view_thread.g_visible_level = 0;
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
    view_place.g_place_logo_id = id;
}

pub fn markPlaceLogoSeenForTest() void {
    view_place.g_place_logo_seen = profile_cache.g_image_clock;
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

pub const notifications_column_width_for_test = notifications_column_width;

pub fn insertMentionForTest(model: *Model, pubkey: [32]u8) void {
    insertMention(model, pubkey);
}

pub const compose_capacity_for_test = compose_capacity;

pub fn composeReachForTest(arena: std.mem.Allocator, written: usize, dropped: usize) []const u8 {
    var ui = AppUi.init(arena);
    return composeReach(&ui, written, dropped);
}

/// Pretends a build put exactly these authors on screen in the front level.
pub fn recordVisibleAuthorsForTest(authors: []const [32]u8) void {
    const set = &view_thread.g_level_visible[0];
    set.reset();
    view_thread.g_visible_level = 0;
    for (authors) |pk| set.pushAuthor(pk);
}

/// The retained tables, for a test that drops the build arena and then reads
/// them exactly as the SDK does.
pub fn threadExtentTableForTest(level: usize) *const anyopaque {
    return &view_thread.g_thread_extents[@min(level, view_thread.g_thread_extents.len - 1)];
}

pub fn profileExtentTableForTest(level: usize) *const anyopaque {
    return &view_thread.g_profile_extents[@min(level, view_thread.g_profile_extents.len - 1)];
}

pub fn rowExtentFromTableForTest(context: ?*const anyopaque, index: u64) f32 {
    return rowExtentFromTable(context, index);
}

pub fn extentTableLenForTest(context: ?*const anyopaque) usize {
    const table: *const RowExtents = @ptrCast(@alignCast(context orelse return 0));
    return table.len;
}

/// The thread header: a Back affordance (to the parent thread, or the feed), the
/// "Thread" label, and the reply count (known from the crowd count up front, so
/// it reads right before the replies are fetched).
pub fn threadHeader(ui: *AppUi, model: *const Model) AppUi.Node {
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

/// Forgets the loaded article, for a test that opens several in turn.
pub fn forgetArticleForTest() void {
    if (view_article.g_article) |old| {
        old.arena.deinit();
        std.heap.page_allocator.destroy(old);
    }
    view_article.g_article = null;
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

pub fn profileFooterForTest(model: *const Model, pubkey: [32]u8, shown: usize) u8 {
    return @intFromEnum(profileFooter(model, pubkey, shown));
}

pub fn placeTileColorsForTest(m: *const Place) struct { bg: canvas.Color, ink: canvas.Color } {
    const c = placeTileColors(m);
    return .{ .bg = c.bg, .ink = c.ink };
}

/// Whether the mark on screen belongs to the room on screen, for the test.
pub fn placeLogoShownForTest() bool {
    return view_place.g_place_logo_state == .loaded and view_place.g_place_logo_id != 0;
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
    view_place.g_place_logo_id = id;
    view_place.g_place_logo_for = pubkey;
    view_place.g_place_logo_for_ident_len = @intCast(copyBounded(&view_place.g_place_logo_for_ident_buf, ident));
    view_place.g_place_logo_state = .loaded;
}

pub fn scanPlaceLogoForTest(fx: *Effects, model: *const Model) void {
    scanPlaceLogo(fx, model);
}

/// A fetch in flight, started by a given place.
pub fn setPlaceLogoAskedForTest(pubkey: [32]u8, ident: []const u8) void {
    view_place.g_place_logo_asked_for = pubkey;
    view_place.g_place_logo_asked_ident_len = @intCast(copyBounded(&view_place.g_place_logo_asked_ident_buf, ident));
    view_place.g_place_logo_state = .fetching;
}

pub fn placeLogoStateNameForTest() []const u8 {
    return @tagName(view_place.g_place_logo_state);
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

pub fn visibleLenForTest(line: []const u8) usize {
    return visibleLen(line);
}

pub fn placeHomeHeightForTest(text: []const u8) f32 {
    return placeHomeHeight(text);
}

pub fn stripEmptyImagesForTest(arena: std.mem.Allocator, src: []const u8) []const u8 {
    return stripEmptyImages(arena, src);
}

pub fn lowerScopeForTest(scope: []const u8) []const u8 {
    return lowerScope(scope);
}

pub fn pausedBannerTextForTest(arena: std.mem.Allocator, queued: usize) []const u8 {
    var ui = AppUi.init(arena);
    return pausedBannerText(&ui, queued);
}

pub fn offlineBannerTextForTest(arena: std.mem.Allocator, queued: usize, none_set: bool) []const u8 {
    var ui = AppUi.init(arena);
    return offlineBannerText(&ui, queued, none_set);
}

/// Whether the pool counts as healthy: MOST of it answering, not all of it. The
/// redesign's at-rest bar reads "4/5 relays" in green while its working bar reads
/// "3/5" in amber, so the line sits at four fifths. A relay pool always has a
/// straggler, and a bar that goes amber for one is a bar nobody reads.
pub fn poolIsHealthyForTest(live: usize) bool {
    return poolIsHealthy(live);
}

pub fn askForMediaForTest(note_id: i64) void {
    askForMedia(note_id);
}

pub fn forgetAskedMediaForTest() void {
    view_note.g_media_asked = [_]i64{0} ** asked_cap;
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
    view_note.g_uncovered = [_]i64{0} ** uncovered_cap;
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

pub fn oneLineForTest(ui: *AppUi, text: []const u8) []const u8 {
    return oneLine(ui, text);
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

// re-exports: view_media.zig
pub const Blur = view_media.Blur;
pub const blurGrid = view_media.blurGrid;
pub const coverNotice = view_media.coverNotice;
pub const coverReasonShown = view_media.coverReasonShown;
pub const decodeBlurhash = view_media.decodeBlurhash;
pub const linkCard = view_media.linkCard;
pub const noteGallery = view_media.noteGallery;
pub const notePicture = view_media.notePicture;
pub const pictureHeight = view_media.pictureHeight;
pub const pictureWidth = view_media.pictureWidth;
pub const quoteSkeleton = view_media.quoteSkeleton;
pub const videoCard = view_media.videoCard;

// re-exports: view_note.zig
pub const QuotePictureBox = view_note.QuotePictureBox;
pub const absoluteNoteTime = view_note.absoluteNoteTime;
pub const anyVerbShown = view_note.anyVerbShown;
pub const askForMedia = view_note.askForMedia;
pub const asked_cap = view_note.asked_cap;
pub const avatarDisc = view_note.avatarDisc;
pub const collapsedLen = view_note.collapsedLen;
pub const collectText = view_note.collectText;
pub const contentSpans = view_note.contentSpans;
pub const contentSpansIn = view_note.contentSpansIn;
pub const elide = view_note.elide;
pub const engagementRow = view_note.engagementRow;
pub const engagementRowAt = view_note.engagementRowAt;
pub const firstLineOf = view_note.firstLineOf;
pub const formatCount = view_note.formatCount;
pub const hgap = view_note.hgap;
pub const identityBlock = view_note.identityBlock;
pub const isExpanded = view_note.isExpanded;
pub const isMediaAsked = view_note.isMediaAsked;
pub const isUncovered = view_note.isUncovered;
pub const liveRelayCount = view_note.liveRelayCount;
pub const noteAvatar = view_note.noteAvatar;
pub const noteBody = view_note.noteBody;
pub const noteBodyAt = view_note.noteBodyAt;
pub const noteCard = view_note.noteCard;
pub const noteCovered = view_note.noteCovered;
pub const noteIsLong = view_note.noteIsLong;
pub const noteSpans = view_note.noteSpans;
pub const oneLine = view_note.oneLine;
pub const pluralize = view_note.pluralize;
pub const pressRow = view_note.pressRow;
pub const profile_band_name_max = view_note.profile_band_name_max;
pub const profile_handle_max = view_note.profile_handle_max;
pub const profile_name_max = view_note.profile_name_max;
pub const quotePictureAspect = view_note.quotePictureAspect;
pub const quotePictureBox = view_note.quotePictureBox;
pub const quoteShowsPicture = view_note.quoteShowsPicture;
pub const quotingPillLabel = view_note.quotingPillLabel;
pub const replyContext = view_note.replyContext;
pub const replyTarget = view_note.replyTarget;
pub const showsImage = view_note.showsImage;
pub const showsLink = view_note.showsLink;
pub const textParaAt = view_note.textParaAt;
pub const threadTime = view_note.threadTime;
pub const toggleExpanded = view_note.toggleExpanded;
pub const uncoverNote = view_note.uncoverNote;
pub const uncovered_cap = view_note.uncovered_cap;
pub const verb_slot_height = view_note.verb_slot_height;
pub const vgap = view_note.vgap;
pub const warningCovered = view_note.warningCovered;

// re-exports: view_chrome.zig
pub const accountHasName = view_chrome.accountHasName;
pub const accountName = view_chrome.accountName;
pub const avatarRadius = view_chrome.avatarRadius;
pub const avatarTint = view_chrome.avatarTint;
pub const identityInk = view_chrome.identityInk;
pub const menuRow = view_chrome.menuRow;
pub const menuSurfacePlaced = view_chrome.menuSurfacePlaced;
pub const menuSurfacePlacedDismissing = view_chrome.menuSurfacePlacedDismissing;
pub const noteContextItems = view_chrome.noteContextItems;
pub const npubShort = view_chrome.npubShort;
pub const offlineBanner = view_chrome.offlineBanner;
pub const offlineBannerText = view_chrome.offlineBannerText;
pub const outboxZone = view_chrome.outboxZone;
pub const pausedBannerText = view_chrome.pausedBannerText;
pub const pillButton = view_chrome.pillButton;
pub const poolIsHealthy = view_chrome.poolIsHealthy;
pub const poolIsHealthyOf = view_chrome.poolIsHealthyOf;
pub const relayAuthBanner = view_chrome.relayAuthBanner;
pub const relayBadgeText = view_chrome.relayBadgeText;
pub const relayZone = view_chrome.relayZone;
pub const roomVerbFill = view_chrome.roomVerbFill;
pub const roomVerbInk = view_chrome.roomVerbInk;
pub const shareBase = view_chrome.shareBase;
pub const signerIsHealthy = view_chrome.signerIsHealthy;
pub const signerStatus = view_chrome.signerStatus;
pub const signerZone = view_chrome.signerZone;
pub const statusChip = view_chrome.statusChip;
pub const updateBanner = view_chrome.updateBanner;

// re-exports: view_place.zig
pub const handlePlaceLogoFetched = view_place.handlePlaceLogoFetched;
pub const lowerScope = view_place.lowerScope;
pub const placeHeader = view_place.placeHeader;
pub const placeHomeHeight = view_place.placeHomeHeight;
pub const placeInfoCard = view_place.placeInfoCard;
pub const place_logo_fetch_key = view_place.place_logo_fetch_key;
pub const scanPlaceLogo = view_place.scanPlaceLogo;
pub const scopeHeader = view_place.scopeHeader;
pub const statusBar = view_place.statusBar;
pub const stripEmptyImages = view_place.stripEmptyImages;
pub const visibleLen = view_place.visibleLen;

// re-exports: view_rail.zig
pub const avatarImageId = view_rail.avatarImageId;
pub const backupNudge = view_rail.backupNudge;
pub const guestBanner = view_rail.guestBanner;
pub const meAvatar = view_rail.meAvatar;
pub const placeTileColors = view_rail.placeTileColors;
pub const placesRail = view_rail.placesRail;
pub const railView = view_rail.railView;
pub const rails_width = view_rail.rails_width;
pub const youAvatar = view_rail.youAvatar;

// re-exports: view_feed.zig
pub const feedView = view_feed.feedView;

// re-exports: view_profile.zig
pub const ProfileRows = view_profile.ProfileRows;
pub const bookmarks_level_key = view_profile.bookmarks_level_key;
pub const handleBannerFetched = view_profile.handleBannerFetched;
pub const profileFooter = view_profile.profileFooter;
pub const profileLevelKey = view_profile.profileLevelKey;
pub const profilePanel = view_profile.profilePanel;
pub const profileTab = view_profile.profileTab;
pub const profileTabFocused = view_profile.profileTabFocused;
pub const scanBannerFetch = view_profile.scanBannerFetch;
pub const threadLevelKey = view_profile.threadLevelKey;
pub const topicLevelKey = view_profile.topicLevelKey;

// re-exports: view_article.zig
pub const articleFor = view_article.articleFor;
pub const articlePanel = view_article.articlePanel;
pub const articleRowAt = view_article.articleRowAt;
pub const isArticleRoot = view_article.isArticleRoot;

// re-exports: view_thread.zig
pub const RowExtents = view_thread.RowExtents;
pub const ThreadRows = view_thread.ThreadRows;
pub const ancestorBodyLines = view_thread.ancestorBodyLines;
pub const ancestorRow = view_thread.ancestorRow;
pub const backControl = view_thread.backControl;
pub const backLabel = view_thread.backLabel;
pub const clampSpansToLines = view_thread.clampSpansToLines;
pub const ghostRow = view_thread.ghostRow;
pub const groupThreadBlocks = view_thread.groupThreadBlocks;
pub const listeningFooter = view_thread.listeningFooter;
pub const noteExtentEstimate = view_thread.noteExtentEstimate;
pub const noteRowEstimate = view_thread.noteRowEstimate;
pub const outsideGraphRow = view_thread.outsideGraphRow;
pub const placeholderKey = view_thread.placeholderKey;
pub const quoteBodyLines = view_thread.quoteBodyLines;
pub const recordProfileVisible = view_thread.recordProfileVisible;
pub const replyBlock = view_thread.replyBlock;
pub const rowExtentFromTable = view_thread.rowExtentFromTable;
pub const showMoreReplies = view_thread.showMoreReplies;
pub const threadIndentLevels = view_thread.threadIndentLevels;
pub const threadOccluder = view_thread.threadOccluder;
pub const threadPanel = view_thread.threadPanel;
pub const threadRepliesFromStore = view_thread.threadRepliesFromStore;
pub const visible_set_cap = view_thread.visible_set_cap;

// re-exports: view_compose.zig
pub const composeReach = view_compose.composeReach;
pub const composeSheet = view_compose.composeSheet;
pub const insertMention = view_compose.insertMention;
pub const mentionQuery = view_compose.mentionQuery;
pub const replyNotifyRow = view_compose.replyNotifyRow;

// re-exports: view_notifications.zig
pub const inbox_page = view_notifications.inbox_page;
pub const notificationRow = view_notifications.notificationRow;
pub const notificationsSheet = view_notifications.notificationsSheet;
pub const notifications_column_width = view_notifications.notifications_column_width;

// re-exports: view_search.zig
pub const searchBody = view_search.searchBody;
pub const search_sheet_width = view_search.search_sheet_width;

// re-exports: view_sheets.zig
pub const addressSheet = view_sheets.addressSheet;
pub const deleteConfirm = view_sheets.deleteConfirm;
pub const feedOptions = view_sheets.feedOptions;
pub const freshListConfirm = view_sheets.freshListConfirm;
pub const imageViewer = view_sheets.imageViewer;
pub const joinSheet = view_sheets.joinSheet;
pub const modalCard = view_sheets.modalCard;
pub const modalScrim = view_sheets.modalScrim;
pub const nameSheet = view_sheets.nameSheet;
pub const pendingText = view_sheets.pendingText;
pub const profileSheet = view_sheets.profileSheet;
pub const toastOverlay = view_sheets.toastOverlay;

// re-exports: view_settings.zig
pub const cycleRelay = view_settings.cycleRelay;
pub const forgetChangedRelaySlotStates = view_settings.forgetChangedRelaySlotStates;
pub const mayRemoveRelay = view_settings.mayRemoveRelay;
pub const relayShortName = view_settings.relayShortName;
pub const removeRelay = view_settings.removeRelay;
pub const settingsCard = view_settings.settingsCard;
pub const settingsLink = view_settings.settingsLink;
pub const settingsSheet = view_settings.settingsSheet;
pub const settings_scroll_end = view_settings.settings_scroll_end;
pub const snapshotRelayUrls = view_settings.snapshotRelayUrls;

test {
    _ = @import("tests.zig");
    _ = @import("blossom.zig");
}

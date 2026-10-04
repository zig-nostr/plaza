//! Outbox reads: which relays to ask about which authors, and the relay-list sweep that learns them.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const relay_table = @import("relay_table.zig");
const relay_conn = @import("relay_conn.zig");
const engagement = @import("engagement.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const activePubkey = main.activePubkey;
const buildRoutedFilters = main.buildRoutedFilters;
const discovered_watch_base = main.discovered_watch_base;
const engagementLock = main.engagementLock;
const engagementUnlock = main.engagementUnlock;
const followSet = main.followSet;
const followSnapshot = main.followSnapshot;
const indexer_chunk = main.indexer_chunk;
const indexer_relays = main.indexer_relays;
const isRelayUrl = main.isRelayUrl;
const lockLiveRelay = main.lockLiveRelay;
const lockRelayTable = main.lockRelayTable;
const max_feed_filters = main.max_feed_filters;
const max_follows = main.max_follows;
const max_relay_suggestions = main.max_relay_suggestions;
const max_relays = main.max_relays;
const one_shot_budget_ms = main.one_shot_budget_ms;
const plazaIngest = main.plazaIngest;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const relay_list_kind = main.relay_list_kind;
const releaseOneShot = main.releaseOneShot;
const unlockLiveRelay = main.unlockLiveRelay;
const unlockRelayTable = main.unlockRelayTable;
const watchOneShot = main.watchOneShot;

/// How many of one author's write relays count toward the ranking.
///
/// Jumble's number. An author advertising a dozen relays is not telling you
/// about a dozen places their notes reliably are; taking the first few keeps
/// one enthusiastic list from outvoting everyone else's.
pub const outbox_relays_per_author = 4;
/// How many relays the ranking considers before it stops.
///
/// 128 was a guess and it was too small: on a real account of 257 follows the
/// count hit it exactly and dropped 63 further relay references, silently,
/// which is how it was found. Coverage cannot choose a relay it never saw.
///
/// 384 clears the measured need with room. The cost is the author bitsets, one
/// bit per follow per candidate, so 384 x 2048 bits is 98 KB of static, and
/// `RouteCoverage.candidates_dropped` says out loud when even this is not
/// enough rather than quietly answering with less.
const relay_rank_candidates = 384;

/// A relay some of the reader's follows write to, and how many of them.
pub const RelayRank = struct {
    url: [96]u8 = [_]u8{0} ** 96,
    len: u8 = 0,
    writers: u16 = 0,

    fn urlSlice(self: *const RelayRank) []const u8 {
        return self.url[0..self.len];
    }
};

/// True when `a` should be offered before `b`: more of the reader's follows
/// write there, ties broken by URL so the list does not shuffle between runs
/// for no reason a reader could see.
fn rankBefore(a: RelayRank, b: RelayRank) bool {
    if (a.writers != b.writers) return a.writers > b.writers;
    return std.mem.order(u8, a.urlSlice(), b.urlSlice()) == .lt;
}

/// Folds one author's write relays into `table`, counting each relay once for
/// that author however many times they list it. Returns the new length.
/// The write relays of one relay list that count toward routing: the first few
/// DISTINCT ones, trimmed and sanity-checked. Returns how many landed in `out`.
///
/// One function, because the ranking and the routing have to agree exactly.
/// They did not: the ranking skipped a repeat before counting it against the
/// cap and the routing counted raw tags, so an author listing `[A, A, B, C, D]`
/// had D counted in the ranking and dropped in the routing, and D then got a
/// connection with nobody on it. Found by removing the empty-relay guard and
/// noticing that no test cared.
pub fn selectWriteRelays(urls: []const []const u8, out: *[outbox_relays_per_author][]const u8) usize {
    var n: usize = 0;
    for (urls) |raw| {
        if (n >= out.len) break;
        const url = std.mem.trim(u8, raw, " \t\r\n");
        if (url.len == 0 or url.len > 96) continue;
        if (!isRelayUrl(url)) continue;
        // A relay list naming the same relay twice is one person's opinion
        // twice, and it would quietly promote whatever a duplicate-happy list
        // mentions most.
        var dup = false;
        for (out[0..n]) |v| {
            if (relayUrlEql(v, url)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        out[n] = url;
        n += 1;
    }
    return n;
}

/// The `r` tags of a relay list, as raw values. Only where they WRITE: a relay
/// somebody merely reads from will never hold their notes, so it is not a route
/// to them.
pub fn writeTagUrls(ev: nostr.event.Event, out: [][]const u8) usize {
    var n: usize = 0;
    for (ev.tags) |tag| {
        if (n >= out.len) break;
        if (tag.len < 2) continue;
        if (!std.mem.eql(u8, tag[0], "r")) continue;
        if (tag.len >= 3 and std.mem.eql(u8, tag[2], "read")) continue;
        out[n] = tag[1];
        n += 1;
    }
    return n;
}

pub fn foldWriteRelays(table: []RelayRank, len_in: usize, urls: []const []const u8) usize {
    var len = len_in;
    var selected: [outbox_relays_per_author][]const u8 = undefined;
    const chosen = selectWriteRelays(urls, &selected);
    for (selected[0..chosen]) |url| {
        var seated = false;
        for (table[0..len]) |*e| {
            if (!relayUrlEql(e.urlSlice(), url)) continue;
            e.writers +|= 1;
            seated = true;
            break;
        }
        if (seated) continue;
        if (len >= table.len) continue;
        table[len] = .{ .len = @intCast(url.len), .writers = 1 };
        @memcpy(table[len].url[0..url.len], url);
        len += 1;
    }
    return len;
}

// -- Choosing which relays to connect to -------------------------------------
//
// Ranking by popularity answers "which relay should this reader consider
// adding", which is a question for a human. It does not answer "which four
// relays reach the most people", and taking the top four of a popularity list
// is not the same thing: the top four all carry the same crowd, and the person
// who publishes to one quiet relay is never reached however many popular ones
// are dialled.
//
// Measured on a real account: 215 of 257 follows have a relay list, naming more
// than 128 distinct relays between them. That is a long tail of relays with one
// or two writers each, and no top-N of it can cover everybody.
//
// So the two questions get two algorithms. Suggestions stay ranked by how many
// follows write there. Connections are chosen by marginal coverage: repeatedly
// take the relay that reaches the most people not yet reached enough times.
//
// Amethyst wrote this algorithm and never called it
// (RelayListRecommendationProcessor.kt:63, zero callers). Jumble approximates
// it with a greedy PRUNE instead, dropping a relay only when every pubkey on it
// is covered at least twice elsewhere, which is the same coverage-of-two idea
// from the other end. Neither of them has to fit a budget, because a browser
// tab can open sockets freely; Plaza holds one thread per socket, so the budget
// is the reason it has to choose at all.

/// How many chosen relays should carry each author, where possible. One is
/// enough to see somebody; two is what keeps one relay being down from hiding
/// them. Jumble's prune uses the same number for the same reason.
pub const route_coverage_target: u8 = 2;

const route_bitset_words = (max_follows + 63) / 64;
/// Which authors each candidate relay carries, one bit per author, indexed the
/// same as the caller's author slice.
var g_route_bits: [relay_rank_candidates][route_bitset_words]u64 = undefined;
/// How many chosen relays carry each author.
var g_route_cover: [max_follows]u8 = @splat(0);

fn bitSet(row: *[route_bitset_words]u64, i: usize) void {
    row[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
}
fn bitGet(row: *const [route_bitset_words]u64, i: usize) bool {
    return row[i >> 6] & (@as(u64, 1) << @intCast(i & 63)) != 0;
}

/// What the routing achieved, for tests and for saying so out loud.
pub const RouteCoverage = struct {
    /// Follows carried by at least one chosen relay.
    reached: usize = 0,
    /// Follows carried by at least `route_coverage_target` of them.
    doubly_reached: usize = 0,
    /// Follows no chosen relay carries. These ride the pool.
    residual: usize = 0,
    /// Candidate relays the table could not hold. Counted rather than dropped
    /// in silence: the cap was hit exactly on a real account, which is how it
    /// was found.
    candidates_dropped: usize = 0,
};
pub var g_route_coverage: RouteCoverage = .{};
/// Failed connections in a row before a routed relay is set aside. Three,
/// because a handshake also fails for a blip: the free relay in my own pool
/// failed one in the same run and was fine on the retry.
pub const routed_refusal_strikes: u6 = 3;
/// How long a set-aside relay stays set aside. It is a subscription, a block or
/// an outage, and all three end; none of them ends in a minute.
pub const routed_refusal_ms: i64 = 6 * 60 * 60 * 1000;
/// How many at once. Small on purpose: this is a list of relays that would
/// otherwise hold a routed slot, and there are only eight of those.
pub const routed_refusal_slots = 16;

const RefusedRelay = struct {
    url: [96]u8 = [_]u8{0} ** 96,
    url_len: u8 = 0,
    strikes: u6 = 0,
    /// When the last strike landed, monotonic ms, or -1 for never.
    at_ms: i64 = -1,
};
pub var g_refused: [routed_refusal_slots]RefusedRelay = @splat(.{});
var g_refused_lock = std.atomic.Value(bool).init(false);

pub fn lockRefused() void {
    while (g_refused_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockRefused() void {
    g_refused_lock.store(false, .release);
}

/// Whether a relay with this record should be passed over right now.
///
/// A pure function so the two clocks it has to survive are testable: no clock at
/// all (before `main` wires one, when nothing has been dialled either), and a
/// record older than the window.
pub fn relayIsRefused(strikes: u6, at_ms: i64, now_ms: ?i64) bool {
    if (strikes < routed_refusal_strikes) return false;
    if (at_ms < 0) return false;
    const now = now_ms orelse return true;
    return now -| at_ms < routed_refusal_ms;
}
/// Records one failed connection to a routed relay. Returns true when this is
/// the strike that sets it aside, so the caller can ask for a rethink.
pub fn noteRelayRefusal(url: []const u8) bool {
    return noteRelayRefusalAt(url, nowMillis() orelse return false);
}

pub fn noteRelayRefusalAt(url: []const u8, now: i64) bool {
    if (url.len == 0 or url.len > 96) return false;
    lockRefused();
    defer unlockRefused();

    for (&g_refused) |*e| {
        if (e.url_len == 0) continue;
        if (!relayUrlEql(e.url[0..e.url_len], url)) continue;
        const was = relayIsRefused(e.strikes, e.at_ms, now);
        // A record that has aged out starts its count again rather than
        // tripping on the first failure of the next attempt.
        if (e.at_ms >= 0 and now -| e.at_ms >= routed_refusal_ms) e.strikes = 0;
        e.strikes +|= 1;
        e.at_ms = now;
        return !was and relayIsRefused(e.strikes, e.at_ms, now);
    }

    // A free slot, or the stalest one. Evicting the stalest can only mean a
    // relay is retried sooner than the window says, never that one is set aside
    // for longer, so the failure mode is a wasted dial rather than a hidden
    // person.
    var pick: usize = 0;
    for (&g_refused, 0..) |*e, i| {
        if (e.url_len == 0) {
            pick = i;
            break;
        }
        if (e.at_ms < g_refused[pick].at_ms) pick = i;
    }
    const e = &g_refused[pick];
    @memcpy(e.url[0..url.len], url);
    e.url_len = @intCast(url.len);
    e.strikes = 1;
    e.at_ms = now;
    return relayIsRefused(e.strikes, e.at_ms, now);
}

/// Forgets a relay's failures, because it just held a connection open.
pub fn clearRelayRefusal(url: []const u8) void {
    lockRefused();
    defer unlockRefused();
    for (&g_refused) |*e| {
        if (e.url_len == 0) continue;
        if (!relayUrlEql(e.url[0..e.url_len], url)) continue;
        e.strikes = 0;
        e.at_ms = -1;
        return;
    }
}

/// Copies out the relays currently set aside, so the choice can skip them
/// without holding this lock while it runs.
pub fn refusedRelays(urls: *[routed_refusal_slots][96]u8, lens: *[routed_refusal_slots]u8) usize {
    const now = nowMillis();
    lockRefused();
    defer unlockRefused();
    var n: usize = 0;
    for (&g_refused) |*e| {
        if (e.url_len == 0) continue;
        if (!relayIsRefused(e.strikes, e.at_ms, now)) continue;
        @memcpy(urls[n][0..e.url_len], e.url[0..e.url_len]);
        lens[n] = e.url_len;
        n += 1;
    }
    return n;
}
/// How much better a challenger has to be before a relay already connected is
/// dropped for it, as a percentage of what the incumbent still reaches.
///
/// Coverage is computed from relay lists that arrive one at a time, so the
/// margin between two candidates moves all day. Without this the set flaps: one
/// person's kind:10002 lands, relay B passes relay A by a single author, and a
/// live socket is torn down and a new one handshaked to gain one. Twenty-five
/// per cent is the smallest margin that a single author cannot cross once a
/// relay carries more than four.
const route_evict_gain_percent: usize = 125;

/// Whether a challenger reaches enough more people to be worth taking a live
/// connection away for.
pub fn worthEvicting(challenger_gain: usize, incumbent_gain: usize) bool {
    // An incumbent that reaches nobody new is not defending anything.
    if (incumbent_gain == 0) return true;
    return challenger_gain * 100 >= incumbent_gain * route_evict_gain_percent;
}
/// The relays currently holding a routed connection, copied out so the choice
/// can prefer them without holding the discovered lock while it runs.
fn incumbentRoutes(urls: *[max_discovered_relays][96]u8, lens: *[max_discovered_relays]u8) usize {
    lockDiscovered();
    defer unlockDiscovered();
    var n: usize = 0;
    for (&g_discovered) |*d| {
        if (d.url_len == 0) continue;
        @memcpy(urls[n][0..d.url_len], d.url[0..d.url_len]);
        lens[n] = d.url_len;
        n += 1;
    }
    return n;
}

/// Picks up to `budget` relays by marginal coverage, skipping any the reader is
/// already connected to and counting their coverage as already paid for.
///
/// Returns how many were chosen, into `out` as indices into `table`.
fn chooseRoutedRelays(
    table: []const RelayRank,
    author_count: usize,
    pool_urls: *const [max_relays][96]u8,
    pool_lens: *const [max_relays]u8,
    pool_n: usize,
    incumbent_urls: *const [max_discovered_relays][96]u8,
    incumbent_lens: *const [max_discovered_relays]u8,
    incumbent_n: usize,
    refused_urls: *const [routed_refusal_slots][96]u8,
    refused_lens: *const [routed_refusal_slots]u8,
    refused_n: usize,
    budget: usize,
    out: []usize,
) usize {
    @memset(g_route_cover[0..author_count], 0);

    // The reader's own relays are already connected, so what they carry is
    // covered before anything is chosen. Without this the greedy spends its
    // whole budget re-reaching the crowd already on nos.lol.
    for (table, 0..) |e, ti| {
        var in_pool = false;
        for (0..pool_n) |pi| {
            if (pool_lens[pi] == 0) continue;
            if (relayUrlEql(pool_urls[pi][0..pool_lens[pi]], e.urlSlice())) {
                in_pool = true;
                break;
            }
        }
        if (!in_pool) continue;
        for (0..author_count) |ai| {
            if (bitGet(&g_route_bits[ti], ai)) g_route_cover[ai] +|= 1;
        }
    }

    var chosen: usize = 0;
    var taken: [relay_rank_candidates]bool = @splat(false);
    while (chosen < budget and chosen < out.len) {
        var best: ?usize = null;
        var best_gain: usize = 0;
        // The best of the relays already holding a connection, tracked
        // alongside so a live socket is not dropped for a marginal gain.
        var held: ?usize = null;
        var held_gain: usize = 0;
        for (table, 0..) |e, ti| {
            if (taken[ti]) continue;
            var in_pool = false;
            for (0..pool_n) |pi| {
                if (pool_lens[pi] == 0) continue;
                if (relayUrlEql(pool_urls[pi][0..pool_lens[pi]], e.urlSlice())) {
                    in_pool = true;
                    break;
                }
            }
            if (in_pool) continue;
            // Before the gain is even computed, and before the incumbent check
            // below, so a relay that will not talk to us can neither win a slot
            // nor defend one it already holds.
            var refused = false;
            for (0..refused_n) |ri| {
                if (refused_lens[ri] == 0) continue;
                if (relayUrlEql(refused_urls[ri][0..refused_lens[ri]], e.urlSlice())) {
                    refused = true;
                    break;
                }
            }
            if (refused) continue;
            var gain: usize = 0;
            for (0..author_count) |ai| {
                if (g_route_cover[ai] >= route_coverage_target) continue;
                if (bitGet(&g_route_bits[ti], ai)) gain += 1;
            }
            // Ties go to the relay more follows write to, then to the URL, so
            // the set does not reshuffle between runs for no visible reason.
            if (gain > best_gain or (gain == best_gain and gain > 0 and best != null and rankBefore(e, table[best.?]))) {
                best = ti;
                best_gain = gain;
            }
            var is_held = false;
            for (0..incumbent_n) |ii| {
                if (incumbent_lens[ii] == 0) continue;
                if (relayUrlEql(incumbent_urls[ii][0..incumbent_lens[ii]], e.urlSlice())) {
                    is_held = true;
                    break;
                }
            }
            if (!is_held) continue;
            if (gain > held_gain or (gain == held_gain and gain > 0 and held != null and rankBefore(e, table[held.?]))) {
                held = ti;
                held_gain = gain;
            }
        }
        // Keep the socket unless the challenger is clearly worth the handshake.
        if (held) |h| {
            if (held_gain > 0 and !worthEvicting(best_gain, held_gain)) {
                best = h;
                best_gain = held_gain;
            }
        }
        // Nothing left to reach. Stopping here rather than spending the budget
        // is the point: a fifth relay carrying only people already covered
        // twice is a thread and a socket for nothing.
        if (best == null or best_gain == 0) break;
        taken[best.?] = true;
        out[chosen] = best.?;
        chosen += 1;
        for (0..author_count) |ai| {
            if (bitGet(&g_route_bits[best.?], ai)) g_route_cover[ai] +|= 1;
        }
    }

    var cov: RouteCoverage = .{};
    for (0..author_count) |ai| {
        if (g_route_cover[ai] >= 1) cov.reached += 1;
        if (g_route_cover[ai] >= route_coverage_target) cov.doubly_reached += 1;
        if (g_route_cover[ai] == 0) cov.residual += 1;
    }
    cov.candidates_dropped = g_route_coverage.candidates_dropped;
    g_route_coverage = cov;
    return chosen;
}

/// Rebuilds the suggestions from every relay list the store holds for the
/// people this reader follows, ordered by how many of them write there.
///
/// One pass over one query. The relays already in the pool are dropped, because
/// a relay the reader is on is not a suggestion, and the top few of what is left
/// are what gets offered.
pub fn rankRelaySuggestions(store: *nostr.store.Store) void {
    var authors: [max_follows][32]u8 = undefined;
    var authors_len: usize = 0;
    for (followSet()) |pk| {
        if (authors_len >= authors.len) break;
        authors[authors_len] = pk;
        authors_len += 1;
    }
    if (authors_len == 0) return;

    const kinds = [_]u16{relay_list_kind};
    var result = store.query(std.heap.page_allocator, .{
        .authors = authors[0..authors_len],
        .kinds = &kinds,
        .limit = @intCast(authors_len),
    }) catch return;
    defer result.deinit();

    var table: [relay_rank_candidates]RelayRank = undefined;
    var len: usize = 0;
    var urls: [32][]const u8 = undefined;
    for (&g_route_bits) |*row| @memset(row, 0);
    g_route_coverage.candidates_dropped = 0;
    for (result.events) |ev| {
        // The reader's own list says where THEY write. It is not a suggestion
        // about anyone else, and counting it would have the reader voting for
        // their own relays in a ranking meant to tell them about others'.
        if (activePubkey()) |pk| {
            if (std.mem.eql(u8, &pk, &ev.pubkey)) continue;
        }
        const before = len;
        len = foldWriteRelays(&table, len, urls[0..writeTagUrls(ev, &urls)]);

        // Which author this event is, so the bitsets can be indexed the same
        // way the caller's author slice is.
        const ai = blk: {
            for (authors[0..authors_len], 0..) |a, i| {
                if (std.mem.eql(u8, &a, &ev.pubkey)) break :blk i;
            }
            break :blk null;
        };
        if (ai) |author_index| {
            var selected: [outbox_relays_per_author][]const u8 = undefined;
            const chosen = selectWriteRelays(urls[0..writeTagUrls(ev, &urls)], &selected);
            for (selected[0..chosen]) |url| {
                var found = false;
                for (table[0..len], 0..) |e, ti| {
                    if (!relayUrlEql(e.urlSlice(), url)) continue;
                    bitSet(&g_route_bits[ti], author_index);
                    found = true;
                    break;
                }
                // The table was full, so this relay is not a candidate at all.
                // Counted, because a cap that drops work in silence reads as a
                // complete answer, and this one was hit exactly on a real
                // account before anybody noticed it existed.
                if (!found and len == table.len) g_route_coverage.candidates_dropped += 1;
            }
        }
        _ = before;
    }
    if (len == 0) return;

    // Sort an ORDER, not the table.
    //
    // `g_route_bits` is indexed by table position, so sorting the table itself
    // silently re-points every bitset at a different relay: the routing then
    // reads one relay's authors and dials another. That is what this did on the
    // first attempt, and the symptom was the routed set choosing the relay with
    // two writers over the one with four.
    var order: [relay_rank_candidates]usize = undefined;
    for (0..len) |i| order[i] = i;
    const Ctx = struct {
        t: []const RelayRank,
        fn lt(self: @This(), a: usize, b: usize) bool {
            return rankBefore(self.t[a], self.t[b]);
        }
    };
    std.mem.sort(usize, order[0..len], Ctx{ .t = table[0..len] }, Ctx.lt);

    // The pool, copied out BEFORE the table lock is taken. `relaySnapshot` takes
    // that same lock and it is a plain spinlock with no owner tracking, so
    // reaching for it from inside is not a slow path, it is a hang: the thread
    // waits for a lock only it could release. Found by running the tests.
    var pool: [max_relays][96]u8 = undefined;
    var pool_len: [max_relays]u8 = @splat(0);
    var pool_n: usize = 0;
    for (0..relaySlots()) |i| {
        var pool_buf: [96]u8 = undefined;
        const pe = relaySnapshot(i, &pool_buf) orelse continue;
        if (pool_n >= pool.len) break;
        @memcpy(pool[pool_n][0..pe.url.len], pe.url);
        pool_len[pool_n] = @intCast(pe.url.len);
        pool_n += 1;
    }

    // Which relays already hold a routed connection, read before the table lock
    // for the same reason the pool is: `incumbentRoutes` takes the discovered
    // lock, and the rule here is table first, discovered second, never both at
    // once from a place that could be entered the other way round.
    var held_urls: [max_discovered_relays][96]u8 = undefined;
    var held_lens: [max_discovered_relays]u8 = @splat(0);
    const held_n = incumbentRoutes(&held_urls, &held_lens);

    // And the ones that would not have us, read here for the same reason.
    var refused_urls: [routed_refusal_slots][96]u8 = undefined;
    var refused_lens: [routed_refusal_slots]u8 = @splat(0);
    const refused_n = refusedRelays(&refused_urls, &refused_lens);

    lockRelayTable();
    defer unlockRelayTable();
    var kept: u8 = 0;
    for (order[0..len]) |oi| {
        const e = table[oi];
        if (kept >= max_relay_suggestions) break;
        // A relay the reader is already on is not news.
        var in_pool = false;
        for (0..pool_n) |i| {
            if (relayUrlEql(pool[i][0..pool_len[i]], e.urlSlice())) {
                in_pool = true;
                break;
            }
        }
        if (in_pool) continue;
        @memcpy(relay_table.g_suggested[kept][0..e.len], e.urlSlice());
        relay_table.g_suggested_len[kept] = e.len;
        kept += 1;
    }
    // Published last, so a reader cannot see a half-rewritten table: the count
    // is what bounds every read of it.
    relay_table.g_suggested_count.store(kept, .release);

    // The same relays, the first few of them, are the ones worth connecting to.
    // Filled from the same query, because it is the same question: who writes
    // where. This runs while the table lock is held, and takes the discovered
    // lock inside it, which is safe only because nothing on the discovered side
    // ever reaches back for the table lock. Nested locks are exactly how the
    // hang above happened, so the order is fixed here and stated: table first,
    // discovered second, never the reverse.
    // The routed set is chosen by COVERAGE, not by the popularity order above.
    // The suggestions answer "what should this reader consider adding", which
    // is a human question; connections answer "which relays reach the most
    // people I cannot otherwise see", and the top of a popularity list is the
    // wrong answer to that because the popular relays all carry the same crowd.
    var picked: [max_discovered_relays]usize = undefined;
    const picked_n = chooseRoutedRelays(
        table[0..len],
        authors_len,
        &pool,
        &pool_len,
        pool_n,
        &held_urls,
        &held_lens,
        held_n,
        &refused_urls,
        &refused_lens,
        refused_n,
        max_discovered_relays,
        &picked,
    );
    var routed_urls: [max_discovered_relays][96]u8 = undefined;
    var routed_lens: [max_discovered_relays]u8 = @splat(0);
    for (picked[0..picked_n], 0..) |ti, i| {
        const u = table[ti].urlSlice();
        @memcpy(routed_urls[i][0..u.len], u);
        routed_lens[i] = @intCast(u.len);
    }
    fillDiscovered(result.events, routed_urls[0..picked_n], routed_lens[0..picked_n], authors[0..authors_len], &pool, &pool_len, pool_n);
}

/// Gives each discovered slot a relay and the people who write there.
///
/// `urls` are already ranked and already known not to be in the reader's pool,
/// so this only has to find, for each of them, which authors named it.
/// Built here, compared with what is live, and only then swapped in. Static
/// rather than a local: four slots of five hundred pubkeys is sixty-odd
/// kilobytes and this runs on the render thread.
var g_discovered_next: [max_discovered_relays]DiscoveredRelay = @splat(.{});

/// Whether two slots ask the same question of the same relay.
///
/// Every author, not the first one. Amethyst shipped this comparison as a
/// `forEachIndexed` with a return inside it, which in Kotlin returns from the
/// lambda, so only `filters[0]` was ever compared and a change further down the
/// list was silently treated as no change at all.
pub fn sameRoute(url_a: []const u8, authors_a: []const [32]u8, url_b: []const u8, authors_b: []const [32]u8) bool {
    if (authors_a.len != authors_b.len) return false;
    if (!std.mem.eql(u8, url_a, url_b)) return false;
    for (authors_a, authors_b) |x, y| {
        if (!std.mem.eql(u8, &x, &y)) return false;
    }
    return true;
}
fn sameRoutes(a: *const DiscoveredRelay, b: *const DiscoveredRelay) bool {
    return sameRoute(
        a.url[0..a.url_len],
        a.authors[0..a.authors_len],
        b.url[0..b.url_len],
        b.authors[0..b.authors_len],
    );
}

fn fillDiscovered(
    events: []const nostr.event.Event,
    urls: []const [96]u8,
    lens: []const u8,
    authors: []const [32]u8,
    pool_urls: *const [max_relays][96]u8,
    pool_lens: *const [max_relays]u8,
    pool_n: usize,
) void {
    lockDiscovered();
    defer unlockDiscovered();

    for (&g_discovered_next) |*d| {
        d.url_len = 0;
        d.authors_len = 0;
    }

    const take = @min(@min(urls.len, g_discovered_next.len), lens.len);

    // Where each chosen relay goes: the seat it is already sitting in.
    //
    // The choice comes back in coverage order, and that order moves whenever
    // anybody's relay list does. Filling the slots in that order hands relay A's
    // socket to relay B and B's to A for no reason other than that they swapped
    // places in a ranking, and both connections are dropped and redialled to do
    // it. Keeping a relay in its own slot means a table that still contains it
    // costs nothing at all.
    var slot_of: [max_discovered_relays]?usize = @splat(null);
    var slot_taken: [max_discovered_relays]bool = @splat(false);
    for (0..take) |i| {
        const url = urls[i][0..lens[i]];
        for (0..g_discovered.len) |s| {
            if (slot_taken[s]) continue;
            const live = &g_discovered[s];
            if (live.url_len == 0) continue;
            if (!relayUrlEql(live.url[0..live.url_len], url)) continue;
            slot_of[i] = s;
            slot_taken[s] = true;
            break;
        }
    }
    for (0..take) |i| {
        if (slot_of[i] != null) continue;
        for (0..g_discovered.len) |s| {
            if (slot_taken[s]) continue;
            slot_of[i] = s;
            slot_taken[s] = true;
            break;
        }
    }

    for (0..take) |i| {
        const url = urls[i][0..lens[i]];
        const d = &g_discovered_next[slot_of[i] orelse continue];
        @memcpy(d.url[0..url.len], url);
        d.url_len = @intCast(url.len);

        for (events) |ev| {
            if (d.authors_len >= discovered_authors_cap) break;
            if (activePubkey()) |pk| {
                if (std.mem.eql(u8, &pk, &ev.pubkey)) continue;
            }
            // The SAME selection the ranking used, from the same function.
            // Two copies of this rule drifted once already.
            var raw: [32][]const u8 = undefined;
            var selected: [outbox_relays_per_author][]const u8 = undefined;
            const chosen = selectWriteRelays(raw[0..writeTagUrls(ev, &raw)], &selected);
            var writes_here = false;
            for (selected[0..chosen]) |candidate| {
                if (relayUrlEql(candidate, url)) {
                    writes_here = true;
                    break;
                }
            }
            if (!writes_here) continue;
            d.authors[d.authors_len] = ev.pubkey;
            d.authors_len += 1;
        }
        // A backstop. Both loops now select through `selectWriteRelays` over
        // the same query result, so a relay in the ranking should always have
        // at least one writer here. If that ever stops being true the symptom
        // is a connection asking about nobody, and this turns it into a missing
        // connection instead, which is the quieter of the two failures.
        if (d.authors_len == 0) d.url_len = 0;
    }

    // The pool's own slots and the residual, from the same events, while the
    // lock is held and `g_discovered_next` is final. Order matters: the residual
    // is "not covered by a ROUTED relay", so it has to be computed after they
    // are chosen.
    fillPoolRoutes(events, authors, pool_urls, pool_lens, pool_n);

    // Only the slots whose answer actually moved.
    //
    // The ranking reruns every time a relay list lands, and during a cold start
    // hundreds of them land. Bumping the generation each time would drop and
    // redial every discovered connection each time, so the pool would spend the
    // whole startup reconnecting and never finish asking anything. Seen exactly
    // that in a live run before this check: three connections, each redialled
    // inside two minutes, for a route table that had not changed.
    for (0..g_discovered.len) |i| {
        const src = &g_discovered_next[i];
        const dst = &g_discovered[i];
        if (sameRoutes(dst, src)) continue;
        dst.url_len = src.url_len;
        @memcpy(dst.url[0..src.url_len], src.url[0..src.url_len]);
        dst.authors_len = src.authors_len;
        @memcpy(dst.authors[0..src.authors_len], src.authors[0..src.authors_len]);
        // Last for this slot, so a thread reading the counter sees a slot that
        // is finished.
        _ = g_discovered_gen[i].fetchAdd(1, .monotonic);
    }
}

/// Set when a relay list that is not the reader's own reaches the store, so the
/// ranking is redone once rather than on every tick.
pub var g_relay_ranks_dirty = std.atomic.Value(bool).init(true);

// -- When the routing is allowed to be recomputed -----------------------------
//
// A cold start lands hundreds of relay lists in a few seconds, and each one is
// a reason to redo the ranking. Redoing it on each one is work thrown away by
// the next one, and every intermediate answer is a route table nobody should
// act on: the fifth list in changes the coverage that the tenth settles.
//
// Neither Jumble nor Amethyst needs this. Both recompute per event and pay a
// socket for the churn; Plaza pays a thread, and the render thread does the
// computing, so it waits for the flurry to stop first.

/// Quiet time after the last relay list before the routing is recomputed.
pub const route_settle_ms: i64 = 5_000;
/// Floor between two recomputes, however much arrives in between.
pub const route_recompute_min_ms: i64 = 10_000;
/// How long the settle window may hold a wanted recompute back. A steady
/// trickle of relay lists must not postpone the answer forever.
pub const route_settle_max_ms: i64 = 30_000;

/// Whether a wanted recompute may run now. All three arguments are ages in
/// milliseconds, and null means "has not happened yet".
pub fn routeRecomputeDue(pending_ms: ?i64, since_list_ms: ?i64, since_run_ms: ?i64) bool {
    const pending = pending_ms orelse return false;
    if (pending >= route_settle_max_ms) return true;
    if (since_run_ms) |t| {
        if (t < route_recompute_min_ms) return false;
    }
    if (since_list_ms) |t| {
        if (t < route_settle_ms) return false;
    }
    return true;
}
/// Monotonic milliseconds since the app woke, or null before `main` wires the
/// clock. Null and not zero: zero is a real reading, and a rate limit that
/// stops working at a particular clock value is not a rate limit.
pub fn nowMillis() ?i64 {
    const io = main.g_io orelse return null;
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// When the last relay list landed, when the routing last ran, and when it was
/// first wanted since then. All monotonic milliseconds, all -1 for "never".
pub var g_route_list_at = std.atomic.Value(i64).init(-1);
var g_route_ran_at: i64 = -1;
var g_route_wanted_at: i64 = -1;

fn ageMs(now_ms: i64, stamp: i64) ?i64 {
    if (stamp < 0) return null;
    return now_ms -| stamp;
}

/// Runs the ranking if one is wanted and the flurry has stopped. Called once a
/// tick from the render thread.
pub fn maybeRankRelaySuggestions(store: *nostr.store.Store) void {
    if (!g_relay_ranks_dirty.load(.acquire)) return;
    // No clock yet means no window to wait out. Better an early answer than a
    // routing that never runs.
    const now_ms = nowMillis() orelse {
        if (g_relay_ranks_dirty.swap(false, .acq_rel)) rankRelaySuggestions(store);
        return;
    };
    if (g_route_wanted_at < 0) g_route_wanted_at = now_ms;
    if (!routeRecomputeDue(
        ageMs(now_ms, g_route_wanted_at),
        ageMs(now_ms, g_route_list_at.load(.acquire)),
        ageMs(now_ms, g_route_ran_at),
    )) return;
    // Cleared BEFORE the query, so a list landing while this runs asks for
    // another pass rather than being folded in and forgotten.
    if (!g_relay_ranks_dirty.swap(false, .acq_rel)) return;
    g_route_wanted_at = -1;
    g_route_ran_at = now_ms;
    rankRelaySuggestions(store);
    // Right after the routing is rebuilt, because that is the moment the set of
    // people nobody can be asked about is known and correct. Off the render
    // thread and one at a time; the sweep marks who it asked, so this settling
    // to a no-op is what the marking is for.
    sweepRelayLists();
}
// -- Reading where your follows actually write -------------------------------
//
// The pool asks every relay in it about every person the reader follows. A
// follow who writes only to relays the reader is not on is therefore invisible:
// their notes never arrive, and nothing says so. No error, no empty state, no
// loading spinner. They simply are not there.
//
// The ranking above already works out where the follows write. This dials the
// top few of those that the reader is NOT already on, and asks each one only
// about the people who write there, which is the whole point: a small relay
// gets asked about its dozen writers rather than about two thousand strangers.
//
// A SEPARATE pool, and not a wider `g_relays`. `max_relays` is eight because
// the outbox records deliveries in a `u8` bitmap, one bit per slot; a ninth
// slot would silently stop being counted and notes would look undelivered
// forever. These connections never publish, so they need no bit and no slot.
//
// Notedeck, the closest architectural match to this app, does not route by
// author at all: it parses kind:10002 for the logged-in account only. So this
// is not a prerequisite for being a credible client, and it stays bounded: the
// reader's own pool remains the feed, and these are what it cannot see.
//
// Eight, matching the pool, for sixteen sockets in all. Four was the number
// picked before there was anything to measure it against. Measured since, on a
// real account of 257 follows: four routed connections reach 193 of them and
// leave 64 riding the pool, and eight reach 202 and leave 55, with 156 covered
// by two relays rather than 134. The eighth connection is still earning its
// thread, and the greedy stops on its own when one would not: it takes a relay
// only while one reaches somebody not yet covered twice, so a quiet account
// with a tidy follow list opens fewer than this and nothing is wasted.
pub const max_discovered_relays = 8;
/// How many authors one discovered relay is asked about. Beyond this the
/// question stops being "who writes here" and starts being another firehose.
pub const discovered_authors_cap = 512;

const DiscoveredRelay = struct {
    url: [96]u8 = [_]u8{0} ** 96,
    url_len: u8 = 0,
    authors: [discovered_authors_cap][32]u8 = undefined,
    authors_len: u16 = 0,
};

pub var g_discovered: [max_discovered_relays]DiscoveredRelay = @splat(.{});
var g_discovered_lock = std.atomic.Value(bool).init(false);
/// Bumped whenever a slot is rewritten, ONE COUNTER PER SLOT. A thread compares
/// its own slot's counter to the value it dialled under, which is how a slot
/// changing hands takes effect now rather than at the next reconnect.
///
/// Per slot and not one counter for the table, because a single counter makes
/// every routed connection the hostage of every other: one follow publishing a
/// new relay list moves one slot and drops all four sockets, and during a cold
/// start that happens over and over. The three other connections had nothing to
/// re-ask.
pub var g_discovered_gen: [max_discovered_relays]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0));

/// What one routed socket is connected to and asking about, so a thread that is
/// not blocked reading it can replace its question.
///
/// The owner of a socket cannot re-ask on its own. It spends its life inside
/// `receive`, which blocks until the relay says something, and a relay with
/// nothing new to say says nothing: driving a route change through the owner
/// means the change lands whenever the next note happens to arrive, which on a
/// quiet relay is never. Measured, by moving a route under a live connection
/// and watching it not notice for forty seconds.
///
/// So the keeper does it. It already holds a pointer to every live connection
/// and a clock, and `sendFrame` is write-locked, which is what makes a second
/// thread writing to a live socket safe at all.
const RoutedLive = struct {
    url: [96]u8 = [_]u8{0} ** 96,
    url_len: u8 = 0,
    /// The generation this socket's standing REQ was built from.
    gen: u32 = 0,
};
/// Guarded by the live-relay lock of `discovered_watch_base + i`, the same lock
/// that guards the pointer it describes.
var g_routed_live: [max_discovered_relays]RoutedLive = @splat(.{});

pub fn lockDiscovered() void {
    while (g_discovered_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockDiscovered() void {
    g_discovered_lock.store(false, .release);
}

pub fn discoveredCount() usize {
    lockDiscovered();
    defer unlockDiscovered();
    var n: usize = 0;
    for (&g_discovered) |*d| {
        if (d.url_len > 0) n += 1;
    }
    return n;
}

pub fn discoveredUrlCopy(index: usize, buf: *[96]u8) ?[]const u8 {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= g_discovered.len) return null;
    const d = &g_discovered[index];
    if (d.url_len == 0) return null;
    @memcpy(buf[0..d.url_len], d.url[0..d.url_len]);
    return buf[0..d.url_len];
}

pub fn discoveredAuthorCount(index: usize) usize {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= g_discovered.len) return 0;
    return g_discovered[index].authors_len;
}

/// Copies one slot's question for the thread about to ask it. Returns null when
/// the slot emptied or the table was rewritten under it.
pub fn discoveredSnapshot(index: usize, gen: u32, url: *[96]u8, authors: *[discovered_authors_cap][32]u8) ?struct { url_len: usize, authors_len: usize } {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= g_discovered.len) return null;
    if (g_discovered_gen[index].load(.acquire) != gen) return null;
    const d = &g_discovered[index];
    if (d.url_len == 0 or d.authors_len == 0) return null;
    @memcpy(url[0..d.url_len], d.url[0..d.url_len]);
    @memcpy(authors[0..d.authors_len], d.authors[0..d.authors_len]);
    return .{ .url_len = d.url_len, .authors_len = d.authors_len };
}

/// Records a relay a follow writes to, unless it is already in the pool or
/// already suggested. First come, first kept: the table is small on purpose,
/// because a wall of suggestions is not a suggestion.
fn noteRelaySuggestion(url: []const u8) void {
    if (url.len == 0 or url.len > 96) return;
    if (!isRelayUrl(url)) return;
    // Already in the pool is not a suggestion. Read through the snapshot, since
    // this runs on an ingest thread while the reader may be editing.
    for (0..relaySlots()) |i| {
        var pool_buf: [96]u8 = undefined;
        const e = relaySnapshot(i, &pool_buf) orelse continue;
        if (relayUrlEql(e.url, url)) return;
    }
    lockRelayTable();
    defer unlockRelayTable();
    const n = relay_table.g_suggested_count.load(.monotonic);
    for (0..n) |i| {
        if (relayUrlEql(relay_table.g_suggested[i][0..relay_table.g_suggested_len[i]], url)) return;
    }
    if (n >= max_relay_suggestions) return;
    @memcpy(relay_table.g_suggested[n][0..url.len], url);
    relay_table.g_suggested_len[n] = @intCast(url.len);
    relay_table.g_suggested_count.store(n + 1, .release);
}

/// Reads a suggestion into `buf`, which the caller owns. Copied under the lock
/// rather than returned as a slice, so an ingest thread cannot rewrite the row
/// a caller is still holding.
pub fn relaySuggestionCopy(index: usize, buf: *[96]u8) ?[]const u8 {
    lockRelayTable();
    defer unlockRelayTable();
    if (index >= relay_table.g_suggested_count.load(.monotonic)) return null;
    const len = relay_table.g_suggested_len[index];
    @memcpy(buf[0..len], relay_table.g_suggested[index][0..len]);
    return buf[0..len];
}

pub fn relaySuggestionCount() usize {
    return relay_table.g_suggested_count.load(.acquire);
}

/// Drops a suggestion once it has been taken, so the row does not linger under
/// a relay that is now in the list above it.
pub fn forgetRelaySuggestion(index: usize) void {
    lockRelayTable();
    defer unlockRelayTable();
    const n = relay_table.g_suggested_count.load(.monotonic);
    if (index >= n) return;
    for (index..n - 1) |i| {
        relay_table.g_suggested[i] = relay_table.g_suggested[i + 1];
        relay_table.g_suggested_len[i] = relay_table.g_suggested_len[i + 1];
    }
    relay_table.g_suggested_count.store(n - 1, .release);
}

/// Two relay URLs naming the same relay. Relays are addresses, not text: a
/// trailing slash and the scheme's case are noise, so `wss://Relay.io/` and
/// `wss://relay.io` are one relay and the list should not hold both.
pub fn relayUrlEql(a: []const u8, b: []const u8) bool {
    const ta = std.mem.trimEnd(u8, a, "/");
    const tb = std.mem.trimEnd(u8, b, "/");
    return std.ascii.eqlIgnoreCase(ta, tb);
}
/// Forgets that a slot ever carried anything. Called when the slot changes
/// hands: "held by 3 relays" must not count a relay that is no longer there.
pub fn forgetRelaySeen(relay_index: usize) void {
    if (relay_index >= 64) return;
    const bit = @as(u64, 1) << @intCast(relay_index);
    engagementLock();
    defer engagementUnlock();
    for (&engagement.g_engagement) |*e| e.relays_seen &= ~bit;
}

pub fn markRelaySeen(note_id: i64, relay_index: usize) void {
    if (relay_index >= 64) return;
    const bit = @as(u64, 1) << @intCast(relay_index);
    engagementLock();
    defer engagementUnlock();
    // Only a note the table ALREADY tracks. Creating a row here would spend the
    // 512-row budget on every note the pool delivers, crowding out the counts the
    // rows exist for; the engagement subscription creates the rows for the notes
    // on screen, which are the only ones whose spread can be read.
    for (&engagement.g_engagement) |*e| {
        if (e.used and e.note_id == note_id) {
            e.relays_seen |= bit;
            return;
        }
    }
}

/// How many relays have delivered `note_id`, or 0 when it has not been tracked
/// (a note read straight from the store on a cold start was delivered by nobody
/// this session, and the focal line says nothing rather than "seen on 0 relays").
pub fn relaysSeenFor(note_id: i64) usize {
    engagementLock();
    defer engagementUnlock();
    for (&engagement.g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return @popCount(e.relays_seen);
    }
    return 0;
}
/// Pubkeys already put to the indexers this run, so a follow with no relay list
/// anywhere is asked once rather than on every rebuild of the routing table.
pub var g_indexed = std.atomic.Value(u32).init(0);
pub var g_indexer_asked: [max_follows][32]u8 = undefined;
pub var g_indexer_asked_len: usize = 0;
var g_indexer_running = std.atomic.Value(bool).init(false);

/// The follows Plaza holds no relay list for and has not yet asked about.
///
/// Reads the store rather than the routing table: "no relay list" is a fact
/// about what is on disk, while a residual author may simply write somewhere
/// that did not make the cut, and asking an indexer about them would be asking
/// a question already answered.
pub fn collectUnrouted(out: [][32]u8) usize {
    const store = main.g_store orelse return 0;
    var n: usize = 0;
    for (followSet()) |pk| {
        if (n >= out.len) break;
        if (authorListed(g_indexer_asked[0..g_indexer_asked_len], pk)) continue;
        const kinds = [_]u16{relay_list_kind};
        var one: [1][32]u8 = .{pk};
        var result = store.query(std.heap.page_allocator, .{
            .authors = one[0..1],
            .kinds = &kinds,
            .limit = 1,
        }) catch continue;
        defer result.deinit();
        if (result.events.len > 0) continue;
        out[n] = pk;
        n += 1;
    }
    return n;
}

/// Asks the indexers about everyone the pool cannot place. One pass, off the
/// UI thread, on its own sockets.
pub fn sweepRelayLists() void {
    if (!relayFetchAllowed()) return;
    if (g_indexer_running.swap(true, .acq_rel)) return; // one sweep at a time
    const t = std.Thread.spawn(.{}, sweepRelayListsWorker, .{}) catch {
        g_indexer_running.store(false, .release);
        return;
    };
    t.detach();
}

fn sweepRelayListsWorker() void {
    defer g_indexer_running.store(false, .release);
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const wanted = gpa.alloc([32]u8, max_follows) catch return;
    defer gpa.free(wanted);
    const n = collectUnrouted(wanted);
    if (n == 0) return;

    // Marked as asked BEFORE the network, not after. A relay that never answers
    // must not leave these authors queued for the next rebuild to ask again:
    // the point of the set is one attempt per run, and an attempt that failed
    // is still an attempt. Amethyst's equivalent is an LRU that fails OPEN when
    // it evicts, resurrecting questions it had already given up on.
    for (wanted[0..n]) |pk| {
        if (g_indexer_asked_len >= g_indexer_asked.len) break;
        g_indexer_asked[g_indexer_asked_len] = pk;
        g_indexer_asked_len += 1;
    }

    for (indexer_relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        // The clock starts once the socket is up, which is what NDK gets wrong:
        // its budget races its own TCP handshake on a cold start and everything
        // that misses is written off as "this person has no relay list".
        const watched = watchOneShot(io, relay, one_shot_budget_ms);
        defer releaseOneShot(watched);

        var start: usize = 0;
        while (start < n) : (start += indexer_chunk) {
            const chunk = wanted[start..@min(start + indexer_chunk, n)];
            const kinds = [_]u16{relay_list_kind};
            // No `since` and no `until`: all four clients agree, and a relay
            // list edited while the app was closed is older than anything a
            // `since` would admit. `limit` is the chunk size because these are
            // replaceable, so a relay holds at most one per author.
            const filters = [_]nostr.filter.Filter{.{
                .authors = chunk,
                .kinds = &kinds,
                .limit = @intCast(chunk.len),
            }};
            relay.subscribe("plaza-ask-relaylists", &filters) catch break;
            while (true) {
                var msg = (relay.receive() catch break) orelse break;
                defer msg.deinit();
                switch (msg.value) {
                    .event => |e| {
                        _ = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch {};
                        _ = g_indexed.fetchAdd(1, .monotonic);
                    },
                    .eose => break,
                    // A CLOSED ends this relay's part, and no EOSE is coming after it.
                    .closed => break,
                    else => {},
                }
            }
        }
    }
    // Whatever arrived changes who can be routed to, so the table is rebuilt
    // rather than waiting for the next thing that happens to touch it.
    // The same flag an arriving relay list sets. A rebuild is wanted, not
    // forced: it runs on the render thread when the flurry has stopped, which
    // is what stops a burst of lists redialling the discovered pool repeatedly.
    if (g_indexed.load(.monotonic) > 0) g_relay_ranks_dirty.store(true, .release);
}
/// a throwaway connection keeps the ingest loops untouched, exactly like
/// publishing. `seq` tags the fetch so its completion is attributable.
/// Whether a relay fetch may start at all.
///
/// Two reasons to refuse, and they used to be one.
///
/// No store means nowhere to put what comes back. That check was also RELIED ON
/// to keep tests off the network, on the reasoning that a test has no store,
/// and `fetchThreadReplies` said so in a comment. It was true until v0.19.0,
/// when the topic view arrived: reading a topic is a store query, so its test
/// has to open one, and the moment it did the guard stopped firing. The
/// detached worker then dialled real relays from a unit test and kept ingesting
/// into an LMDB handle the test had already closed, which segfaults. It is a
/// race, so it passed far more often than it failed, and it failed on an
/// unrelated test whose only crime was running at the wrong moment.
///
/// So the test case is stated rather than inferred. A guard that checks one
/// thing and is trusted for another holds only until the two answers diverge,
/// and nothing announces the day they do.
///
/// The caller marks the fetch finished, so the UI never waits on a fetch that
/// was never allowed to start.
pub fn relayFetchAllowed() bool {
    if (comptime builtin.is_test) return false;
    return main.g_store != null;
}
/// Authors routed to each POOL slot: the follows who write to that relay.
pub var g_pool_routed: [max_relays]DiscoveredRelay = @splat(.{});
/// Everyone no chosen relay covers. Goes to every read-capable pool relay,
/// which is where they were all being asked before this.
var g_residual: [max_follows][32]u8 = undefined;
pub var g_residual_len: usize = 0;

/// Whether `pubkey` is in `list`.
fn authorListed(list: []const [32]u8, pubkey: [32]u8) bool {
    for (list) |a| {
        if (std.mem.eql(u8, &a, &pubkey)) return true;
    }
    return false;
}

/// Fills the pool's per-slot author lists and the residual, from the same query
/// result the routed table is built from. Called with the discovered lock held.
/// `pool_urls`/`pool_lens` are the reader's own read relays, ALREADY SNAPSHOTTED
/// by the caller. Not read from the relay table here, and that is not a style
/// choice: the caller holds the relay-table lock, `relaySnapshot` takes the same
/// one, and it is a plain spinlock with no owner tracking. Reaching for it from
/// in here is not a slow path, it is a thread waiting on a lock only it could
/// release. That exact mistake hung the test suite twice today, in this file,
/// once already inside this very call chain.
fn fillPoolRoutes(
    events: []const nostr.event.Event,
    authors: []const [32]u8,
    pool_urls: *const [max_relays][96]u8,
    pool_lens: *const [max_relays]u8,
    pool_n: usize,
) void {
    for (&g_pool_routed) |*p| {
        p.url_len = 0;
        p.authors_len = 0;
    }
    g_residual_len = 0;

    for (authors) |pubkey| {
        var placed = false;

        // Already going to a routed relay?
        for (&g_discovered_next) |*d| {
            if (d.url_len == 0) continue;
            if (authorListed(d.authors[0..d.authors_len], pubkey)) {
                placed = true;
                break;
            }
        }

        // Or writes to one of the reader's own relays. Checked even when a
        // routed relay already has them: a second copy of the question is the
        // redundancy that keeps one relay going down from hiding somebody.
        const ev = eventFor(events, pubkey);
        if (ev) |e| {
            var raw: [32][]const u8 = undefined;
            var selected: [outbox_relays_per_author][]const u8 = undefined;
            const chosen = selectWriteRelays(raw[0..writeTagUrls(e, &raw)], &selected);
            for (0..pool_n) |i| {
                if (pool_lens[i] == 0) continue;
                if (g_pool_routed[i].authors_len >= discovered_authors_cap) continue;
                for (selected[0..chosen]) |url| {
                    if (!relayUrlEql(url, pool_urls[i][0..pool_lens[i]])) continue;
                    const p = &g_pool_routed[i];
                    @memcpy(p.url[0..pool_lens[i]], pool_urls[i][0..pool_lens[i]]);
                    p.url_len = pool_lens[i];
                    p.authors[p.authors_len] = pubkey;
                    p.authors_len += 1;
                    placed = true;
                    break;
                }
            }
        }

        if (placed) continue;
        if (g_residual_len >= g_residual.len) continue;
        g_residual[g_residual_len] = pubkey;
        g_residual_len += 1;
    }
}

/// The stored relay list for `pubkey`, if the query returned one.
fn eventFor(events: []const nostr.event.Event, pubkey: [32]u8) ?nostr.event.Event {
    for (events) |e| {
        if (std.mem.eql(u8, &e.pubkey, &pubkey)) return e;
    }
    return null;
}

/// What pool slot `index` should ask about: the follows who write there, then
/// everyone nobody else is being asked about. Returns how many went into `out`.
pub fn poolAuthors(index: usize, out: *[max_follows + 1][32]u8) usize {
    lockDiscovered();
    defer unlockDiscovered();
    var n: usize = 0;
    if (index < g_pool_routed.len) {
        const p = &g_pool_routed[index];
        const take = @min(p.authors_len, out.len);
        @memcpy(out[0..take], p.authors[0..take]);
        n = take;
    }
    for (g_residual[0..g_residual_len]) |pk| {
        if (n >= out.len) break;
        out[n] = pk;
        n += 1;
    }
    return n;
}

/// What pool slot `index` asks about, with the fallback the dial path uses.
///
/// Nothing routed yet (the first dial happens before any relay list has been
/// read back) means ask about EVERYONE, which is what this did before routing
/// existed and is the only answer that cannot hide somebody. Separate from
/// `poolAuthors` so the fallback is a thing a test can reach; inside the relay
/// loop it needs a socket.
pub fn poolAuthorsOrAll(index: usize, out: *[max_follows + 1][32]u8) usize {
    const n = poolAuthors(index, out);
    if (n > 0) return n;
    return followSnapshot(@ptrCast(out));
}
/// Forgets which relays hold a routed connection.
///
/// Called from the pool resets, because the choice now PREFERS a relay it is
/// already connected to and a table left behind by the previous test is an
/// incumbent that would quietly win. Tests that pass only in the order they
/// happen to run are worse than no tests.
pub fn forgetDiscovered() void {
    lockDiscovered();
    defer unlockDiscovered();
    for (&g_discovered) |*d| {
        d.url_len = 0;
        d.authors_len = 0;
    }
    for (&g_discovered_next) |*d| {
        d.url_len = 0;
        d.authors_len = 0;
    }
}
/// The subscription id every routed connection asks under. One id, because a
/// REQ under an id the relay already holds is a REPLACEMENT rather than a
/// second subscription (NIP-01), and that is the whole mechanism: the question
/// changes without the socket closing.
pub const outbox_sub_id = "plaza-outbox";
pub fn setRoutedLive(index: usize, url: []const u8, gen: u32) void {
    if (index >= g_routed_live.len or url.len > 96) return;
    lockLiveRelay(discovered_watch_base + index);
    defer unlockLiveRelay(discovered_watch_base + index);
    const r = &g_routed_live[index];
    @memcpy(r.url[0..url.len], url);
    r.url_len = @intCast(url.len);
    r.gen = gen;
}

pub fn clearRoutedLive(index: usize) void {
    if (index >= g_routed_live.len) return;
    lockLiveRelay(discovered_watch_base + index);
    defer unlockLiveRelay(discovered_watch_base + index);
    g_routed_live[index].url_len = 0;
}

/// Whether routed slot `index` still names the relay this connection dialled.
pub fn routedSlotStillNames(index: usize, url: []const u8) bool {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= g_discovered.len) return false;
    const d = &g_discovered[index];
    if (d.url_len == 0) return false;
    return relayUrlEql(d.url[0..d.url_len], url);
}

/// What the keeper should do about a routed socket whose slot has moved.
pub const RouteFollowUp = enum {
    /// The socket is already asking the current question.
    leave_it,
    /// Same relay, different people: replace the standing REQ in place.
    re_ask,
    /// The slot names another relay, or none. Close it and let the owner redial.
    retire,
};

pub fn routeFollowUp(live_url: []const u8, live_gen: u32, slot_url: []const u8, slot_gen: u32) RouteFollowUp {
    if (live_url.len == 0) return .leave_it;
    if (live_gen == slot_gen) return .leave_it;
    if (slot_url.len == 0) return .retire;
    if (!relayUrlEql(live_url, slot_url)) return .retire;
    return .re_ask;
}
/// Brings every live routed socket up to date with its slot, from a thread that
/// is not blocked reading it. Called once per keeper tick.
pub fn followRouteChanges(io: std.Io) void {
    for (0..max_discovered_relays) |i| {
        const slot_gen = g_discovered_gen[i].load(.acquire);
        var slot_url: [96]u8 = undefined;
        var authors: [discovered_authors_cap][32]u8 = undefined;
        // Read before the live lock is taken: `discoveredSnapshot` takes the
        // discovered lock, and the keeper's other loop already holds a live
        // lock while it works. Two locks held at once is how the last hang
        // happened, so they are never held at once here.
        const snap = discoveredSnapshot(i, slot_gen, &slot_url, &authors);
        const slot_url_len = if (snap) |s| s.url_len else 0;

        const watch = discovered_watch_base + i;
        lockLiveRelay(watch);
        defer unlockLiveRelay(watch);
        const r = &g_routed_live[i];
        switch (routeFollowUp(r.url[0..r.url_len], r.gen, slot_url[0..slot_url_len], slot_gen)) {
            .leave_it => {},
            .re_ask => {
                const relay = relay_conn.g_relay_live[watch] orelse continue;
                var filter_buf: [max_feed_filters]nostr.filter.Filter = undefined;
                const filters = buildRoutedFilters(authors[0..snap.?.authors_len], &filter_buf);
                relay.subscribe(outbox_sub_id, filters) catch continue;
                r.gen = slot_gen;
            },
            .retire => {
                const relay = relay_conn.g_relay_live[watch] orelse continue;
                // Half-close, so the owner's blocked `receive` returns and it
                // redials through its own path. NOT deinit: the owner still
                // holds this and has to unwind.
                relay.shutdown(io);
                relay_conn.g_relay_live[watch] = null;
                r.url_len = 0;
            },
        }
    }
}

pub fn routeCoverageForTest() RouteCoverage {
    return g_route_coverage;
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
    for (&g_refused) |*e| {
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
pub fn discoveredGenerationForTest(index: usize) u32 {
    if (index >= g_discovered_gen.len) return 0;
    return g_discovered_gen[index].load(.acquire);
}
pub fn sweepRelayListsForTest() void {
    sweepRelayLists();
}
pub fn collectUnroutedForTest(out: [][32]u8) usize {
    return collectUnrouted(out);
}
pub fn resetIndexerAskedForTest() void {
    g_indexer_asked_len = 0;
    g_indexed.store(0, .monotonic);
}
pub fn markIndexerAskedForTest(pk: [32]u8) void {
    if (g_indexer_asked_len >= g_indexer_asked.len) return;
    g_indexer_asked[g_indexer_asked_len] = pk;
    g_indexer_asked_len += 1;
}
pub fn indexerAskedLenForTest() usize {
    return g_indexer_asked_len;
}

pub fn relayFetchAllowedForTest() bool {
    return relayFetchAllowed();
}
pub fn poolAuthorsForTest(index: usize, out: *[max_follows + 1][32]u8) usize {
    return poolAuthors(index, out);
}
pub fn poolAuthorsOrAllForTest(index: usize, out: *[max_follows + 1][32]u8) usize {
    return poolAuthorsOrAll(index, out);
}
pub fn discoveredAuthorsForTest(index: usize, out: *[discovered_authors_cap][32]u8) usize {
    lockDiscovered();
    defer unlockDiscovered();
    if (index >= g_discovered.len) return 0;
    const d = &g_discovered[index];
    @memcpy(out[0..d.authors_len], d.authors[0..d.authors_len]);
    return d.authors_len;
}
pub fn clearRoutesForTest() void {
    lockDiscovered();
    defer unlockDiscovered();
    for (&g_pool_routed) |*p| {
        p.url_len = 0;
        p.authors_len = 0;
    }
    g_residual_len = 0;
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
    return g_residual_len;
}

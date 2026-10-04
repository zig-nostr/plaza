//! Threads as data: NIP-10 and NIP-22 parents and roots, arrival order, ancestor chains, and graph splits.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Note = main.Note;
const ancestorBodyLines = main.ancestorBodyLines;
const comment_kind = main.comment_kind;
const hexLower = main.hexLower;
const inFollowGraph = main.inFollowGraph;
const noteFrom = main.noteFrom;
const nowSeconds = main.nowSeconds;
const thread_depth_max = main.thread_depth_max;
const thread_reply_cap = main.thread_reply_cap;
const wantQuote = main.wantQuote;

/// Arrival order inside a thread level: the build a reply first appeared in, so a
/// late arrival lands after what has already been read instead of jumping into the
/// middle of it. The redesign is explicit about this ("appended, never reordered"),
/// and a reply that arrives late is often OLDER than replies already on screen, so
/// created_at alone would move the ground under the reader.
///
/// One table PER LEVEL, keyed by that level's root: a thread stays mounted while
/// the reader walks into a sub-thread and back, and it has to come back in the
/// order they left it. A single shared table meant opening any reply reshuffled
/// the conversation underneath it.
pub const ArrivalTable = struct {
    const Entry = struct {
        used: bool = false,
        id: [32]u8 = [_]u8{0} ** 32,
        batch: u32 = 0,
    };
    /// The level's root, so a table found holding a different thread is discarded
    /// rather than trusted.
    root: [32]u8 = [_]u8{0} ** 32,
    entries: [thread_reply_cap]Entry = [_]Entry{.{}} ** thread_reply_cap,
    batch: u32 = 0,
    /// Whether this level's own fetch has settled. Everything collected before it
    /// does is ONE batch, in written order, however the relays interleave it;
    /// only what shows up afterwards is genuinely late.
    settled: bool = false,
};
/// One per mounted level: the back-stack plus the open thread.
var g_arrival: [thread_depth_max + 1]ArrivalTable = [_]ArrivalTable{.{}} ** (thread_depth_max + 1);
/// The arrival table for `level`, reset if it is holding a different thread.
pub fn arrivalTableFor(level: usize, root: [32]u8) *ArrivalTable {
    const table = &g_arrival[@min(level, g_arrival.len - 1)];
    if (!std.mem.eql(u8, &table.root, &root)) table.* = .{ .root = root };
    return table;
}

/// Stamps each note with the batch it first appeared in and puts the level in
/// reading order. One pass over the notes: an id the level has not shown before
/// opens the next batch (unless the level is still loading, when everything
/// belongs to the first), and every id after it in the same build joins it.
///
/// `settled` is whether this level's own fetch has finished. Until it has, the
/// relays are still streaming the thread's opening state, and treating each
/// 80ms slice of that stream as a batch would pin the conversation into
/// relay-answer order, which is precisely what this exists to prevent.
pub fn stampArrival(table: *ArrivalTable, notes: []Note, settled: bool) void {
    var opened = false;
    for (notes) |*note| {
        if (arrivalOf(table, note.event_id)) |batch| {
            note.arrival = batch;
            continue;
        }
        if (!opened) {
            if (table.settled) table.batch += 1;
            opened = true;
        }
        note.arrival = claimArrival(table, note.event_id, notes);
    }
    if (settled) table.settled = true;
    sortThreadNotes(notes);
}

/// The batch `id` was first seen in, or null when this level has not shown it.
fn arrivalOf(table: *const ArrivalTable, id: [32]u8) ?u32 {
    for (&table.entries) |*e| {
        if (e.used and std.mem.eql(u8, &e.id, &id)) return e.batch;
    }
    return null;
}

/// Records `id` at the current batch. The table holds exactly as many entries as
/// a level can show, so a full table means it is holding ids that have since left
/// the set (the fetch cap re-cuts as the store grows): those are swept, and the
/// claim retried. Failing that the id takes the current batch unrecorded, which
/// still reads in order for this build.
fn claimArrival(table: *ArrivalTable, id: [32]u8, live: []const Note) u32 {
    for (&table.entries) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .batch = table.batch };
            return e.batch;
        }
    }
    for (&table.entries) |*e| {
        var still_here = false;
        for (live) |*note| {
            if (std.mem.eql(u8, &note.event_id, &e.id)) {
                still_here = true;
                break;
            }
        }
        if (!still_here) e.* = .{};
    }
    for (&table.entries) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .batch = table.batch };
            return e.batch;
        }
    }
    return table.batch;
}

/// A thread level's reading order: the batch a reply arrived in, then when it was
/// written. ONE comparator, called by the open thread and by every level under
/// it, so a level reads the same both ways round.
/// Orders a thread's replies: arrival first, then chronological within a batch,
/// so a reply that showed up later sits after the ones already read even when it
/// was written earlier.
///
/// Sorts an array of INDICES and permutes once, rather than sorting the notes
/// themselves. Two reasons, and the second one is a hard constraint rather than
/// a preference.
///
/// A `Note` is kilobytes, because it carries the note's text inline. Sorting
/// them directly means the sort swaps whole notes around: ~100 log 100 moves of
/// a multi-kilobyte struct to order a list whose keys are two integers. Indices
/// are four bytes and the permutation touches each note once.
///
/// The constraint: `std.mem.sort` is a stable block sort, and its rotate step
/// calls `std.mem.reverse`, which asks `std.simd.suggestVectorLength` for a
/// vector width. That computes `ceilPowerOfTwo(u16, @bitSizeOf(T))`, so ANY
/// element type over 4096 bytes overflows a u16 and fails to compile, inside
/// the standard library, with no mention of the caller. That put a hard ceiling
/// of 4096 bytes on `Note` and therefore on how much of a note Plaza could hold,
/// which is not a limit anybody chose. Sorting `u32` keeps the stdlib on a small
/// type and the ceiling disappears.
pub fn sortThreadNotes(notes: []Note) void {
    if (notes.len < 2) return;
    var order: [thread_reply_cap]u32 = undefined;
    if (notes.len > order.len) return;
    for (0..notes.len) |i| order[i] = @intCast(i);

    const Ctx = struct {
        notes: []const Note,
        fn lt(self: @This(), a: u32, b: u32) bool {
            const x = &self.notes[a];
            const y = &self.notes[b];
            if (x.arrival != y.arrival) return x.arrival < y.arrival;
            return x.created_at < y.created_at;
        }
    };
    // The STABLE sort, so a batch that arrived together keeps the order it
    // arrived in. A thread loaded in one go stamps every reply with the same
    // arrival, and relays answer in whatever order they please, so without this
    // the conversation could reshuffle between rebuilds under the reader.
    //
    // Stability comes from the algorithm and not from a tiebreak in the
    // comparator. I wrote the tiebreak version first and could not make any
    // probe fail: the unstable sort preserves equal elements anyway at these
    // sizes, so the tiebreak was a second mechanism for a property already held,
    // and one that no test could show was doing anything.
    //
    // Sorting `u32` rather than `Note` is what makes this legal at all: see the
    // ceiling described above.
    std.mem.sort(u32, order[0..notes.len], Ctx{ .notes = notes }, Ctx.lt);

    // Permute in place by following each cycle, so this costs one move per note
    // and needs no second array of notes.
    var scratch: Note = undefined;
    var done = [_]bool{false} ** thread_reply_cap;
    for (0..notes.len) |start| {
        if (done[start] or order[start] == start) {
            done[start] = true;
            continue;
        }
        scratch = notes[start];
        var at = start;
        while (true) {
            const from = order[at];
            done[at] = true;
            if (from == start) {
                notes[at] = scratch;
                break;
            }
            notes[at] = notes[from];
            at = from;
        }
    }
}
/// The parent of a NIP-22 comment: the LAST lowercase `e`, falling back to the
/// uppercase `E`.
///
/// No markers, and no positional fallback, because NIP-22 has no marker
/// vocabulary at all. Field 4 of a NIP-22 `e` is the AUTHOR pubkey where NIP-10
/// puts a marker, so reading it as one is how a reader quietly starts mistaking
/// every comment for an unmarked positional reply.
///
/// A comment on a URL or a hashtag carries neither `e` nor `E`, only `I` or
/// `A`, and answers null: it has no event parent, and calling one of those a
/// reply to something would be inventing a tie.
pub fn nip22Parent(tags: []const nostr.event.Tag) ?[32]u8 {
    var lower: ?[32]u8 = null;
    var upper: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        if (std.mem.eql(u8, tag[0], "e")) lower = id;
        if (std.mem.eql(u8, tag[0], "E") and upper == null) upper = id;
    }
    return lower orelse upper;
}

/// The root of a NIP-22 comment: the uppercase `E`, read directly.
///
/// Never derived by climbing. Every writer copies the parent comment's
/// uppercase scope forward verbatim, so a reader that reconstructs it by
/// walking ancestors disagrees with every other client the moment one ancestor
/// is missing from the store. For a client that renders from a local store,
/// missing ancestors are the ordinary case rather than the exception.
pub fn nip22Root(tags: []const nostr.event.Tag) ?[32]u8 {
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "E")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        return id;
    }
    return null;
}

/// The parent of a reply of EITHER kind, and the root likewise.
///
/// These exist so no call site has to remember which vocabulary an event
/// speaks. A kind:1 reply and a kind:1111 comment answer the same question with
/// different tags, and mixing the two readers is how a thread ends up half
/// assembled: NIP-10 markers read off a NIP-22 tag find an author pubkey where
/// they expect "reply".
pub fn replyParent(kind: u16, tags: []const nostr.event.Tag) ?[32]u8 {
    return if (kind == comment_kind) nip22Parent(tags) else nip10Parent(tags);
}

pub fn replyRoot(kind: u16, tags: []const nostr.event.Tag) ?[32]u8 {
    return if (kind == comment_kind) nip22Root(tags) else nip10Root(tags);
}

/// The NIP-10 parent of a reply: the `e` tag marked `reply` wins; with only a
/// `root` marker the note answers the root directly; with no markers at all the
/// LAST `e` tag is the parent (the deprecated positional convention, still
/// common in the wild). `mention` tags never make a note a reply; a quote is
/// not an answer. Null for a note that answers nothing.
pub fn nip10Parent(tags: []const nostr.event.Tag) ?[32]u8 {
    var reply: ?[32]u8 = null;
    var root: ?[32]u8 = null;
    var last_plain: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (std.mem.eql(u8, marker, "reply")) {
            reply = id;
        } else if (std.mem.eql(u8, marker, "root")) {
            root = id;
        } else if (std.mem.eql(u8, marker, "mention")) {
            // A quoted note, not an ancestor.
        } else {
            last_plain = id;
        }
    }
    return reply orelse root orelse last_plain;
}

/// Orders a fetched reply set into conversation order (each reply directly
/// under the note it answers, siblings oldest-first) and stamps every note's
/// nesting depth (1 = a direct reply to the root). Expects `notes` already
/// sorted oldest-first, which is what makes sibling order chronological.
///
/// A reply whose parent is the root, or which answers nothing, sits at the top
/// level in its chronological place.
///
/// A reply whose parent IS named but is not in the set (past the fetch cap,
/// never seen, or gone from every relay) also sits there, because there is
/// nowhere better to put it, but it is marked `parent_missing` so the row can
/// say so. Drawing it as an ordinary first-level reply asserted that it answered
/// the opening note, which is a claim about the conversation that nothing
/// supports: the note says which event it answers and that event is simply not
/// here.
///
/// A parent cycle (malformed events) cannot loop: the visited set admits each
/// note once, and whatever a cycle strands is appended at the top level.
pub fn arrangeThread(notes: []Note, root_event_id: [32]u8) void {
    const n = notes.len;
    if (n < 2) {
        if (n == 1) notes[0].depth = 1;
        return;
    }
    std.debug.assert(n <= thread_reply_cap);
    // Each note's parent INDEX within the set, or `n` for "top level". The
    // scan is O(n^2) over 32-byte compares, which at the 100-reply cap is
    // trivia next to the store query that produced the set.
    var parent: [thread_reply_cap]u16 = undefined;
    for (notes[0..n], 0..) |*note, i| {
        parent[i] = @intCast(n);
        note.parent_missing = false;
        if (!note.has_reply_parent) continue;
        if (std.mem.eql(u8, &note.reply_parent, &root_event_id)) continue;
        var found = false;
        for (notes[0..n], 0..) |*cand, j| {
            if (i != j and std.mem.eql(u8, &cand.event_id, &note.reply_parent)) {
                parent[i] = @intCast(j);
                found = true;
                break;
            }
        }
        // Named a parent, and it is not here. Still top level, but no longer
        // pretending that is where it belongs.
        note.parent_missing = !found;
    }
    // The DFS emits a PERMUTATION (conversation order over current indices),
    // so ordering is one O(n) gather through the scratch below, never a sort,
    // which would move the ~1.5KB Note structs O(n log n) times for an order
    // the walk already knows.
    var visited = [_]bool{false} ** thread_reply_cap;
    var order: [thread_reply_cap]u16 = undefined;
    var count: usize = 0;
    const Dfs = struct {
        notes: []Note,
        parent: []const u16,
        visited: []bool,
        order: []u16,
        count: *usize,
        fn visit(self: *const @This(), i: usize, depth: u8) void {
            if (self.visited[i]) return;
            self.visited[i] = true;
            self.notes[i].depth = depth;
            self.order[self.count.*] = @intCast(i);
            self.count.* += 1;
            for (self.parent, 0..) |p, j| {
                if (p == i) self.visit(j, depth +| 1);
            }
        }
    };
    const dfs = Dfs{ .notes = notes, .parent = parent[0..n], .visited = visited[0..n], .order = order[0..n], .count = &count };
    for (0..n) |i| {
        if (parent[i] == n) dfs.visit(i, 1);
    }
    // A cycle's strands: no member ever reached the top level, so seat them
    // there, still oldest-first.
    for (0..n) |i| {
        if (!visited[i]) {
            notes[i].depth = 1;
            order[count] = @intCast(i);
            count += 1;
        }
    }
    for (order[0..n], 0..) |src, dst| g_arrange_scratch[dst] = notes[src];
    @memcpy(notes[0..n], g_arrange_scratch[0..n]);
}

// The gather scratch for `arrangeThread`'s permutation apply. File-scope (not
// stack: ~150KB of Note at the cap) and safe unsynchronized because every
// caller runs on the UI thread: refreshThreadNotes from `update`, and
// threadRepliesFromStore from the view build.
var g_arrange_scratch: [thread_reply_cap]Note = undefined;

/// The thread root the tags declare: the `e` tag marked `root`, or the FIRST
/// non-mention `e` tag in the positional form (NIP-10's deprecated scheme puts
/// the root first and the immediate parent last). Null when the note answers
/// nothing, which is what a root's own tags look like.
///
/// Used to name what a gap in the ancestor chain is: a missing id that IS this
/// root is the thread's opening note, and the ghost row says so.
pub fn nip10Root(tags: []const nostr.event.Tag) ?[32]u8 {
    var first_plain: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (std.mem.eql(u8, marker, "root")) return id;
        if (std.mem.eql(u8, marker, "mention") or std.mem.eql(u8, marker, "reply")) continue;
        if (first_plain == null) first_plain = id;
    }
    return first_plain;
}

/// The event ids a thread subscription should name: the note the reader
/// pressed, and the root of the conversation it belongs to when that is a
/// different note. Fills `out` and returns how many are in it.
///
/// Both, not just the root, and not just the note. The root is what the rest of
/// the conversation actually tags, and the pressed note is what keeps this
/// working when a root tag is missing, wrong, or points at something else: its
/// own direct children still match.
pub fn threadQueryIds(focal: [32]u8, kind: u16, tags: []const nostr.event.Tag, out: *[2][32]u8) usize {
    out[0] = focal;
    const root = replyRoot(kind, tags) orelse return 1;
    // A note that names itself as its own root is one id, not two.
    if (std.mem.eql(u8, &root, &focal)) return 1;
    out[1] = root;
    return 2;
}

/// Whether the tags carry a NON-mention `e` reference to `id`: a root, reply,
/// or positional ancestor pointer. A mention-marked tag is a quote, not an
/// ancestor tie.
/// Whether a reply of EITHER kind ties itself to `id`.
///
/// A comment's tie is its lowercase `e` or its uppercase `E`, and neither
/// carries a marker, so there is no quote to exclude: NIP-22 has no `mention`
/// vocabulary. A quoted event inside a comment is a `q` tag, which is not read
/// here and so cannot be mistaken for an ancestor tie.
pub fn replyReferences(kind: u16, tags: []const nostr.event.Tag, id: [32]u8) bool {
    if (kind != comment_kind) return nip10References(tags, id);
    for (tags) |tag| {
        if (tag.len < 2 or tag[1].len != 64) continue;
        if (!std.mem.eql(u8, tag[0], "e") and !std.mem.eql(u8, tag[0], "E")) continue;
        var tid: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&tid, tag[1]) catch continue;
        if (std.mem.eql(u8, &tid, &id)) return true;
    }
    return false;
}

pub fn nip10References(tags: []const nostr.event.Tag, id: [32]u8) bool {
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var tid: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&tid, tag[1]) catch continue;
        if (!std.mem.eql(u8, &tid, &id)) continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (!std.mem.eql(u8, marker, "mention")) return true;
    }
    return false;
}

// How many candidates one walk round asks the store for: a multiple of the
// display cap, so the events the gates reject (quotes, foreign repliers,
// cross-round duplicates) do not consume the window genuine replies needed.
// The store answers newest-first, so a round referenced by MORE events than
// this can still cut old ones; the pool just makes that take four hundred
// referers in one round rather than one hundred.
const thread_walk_limit = thread_reply_cap * 4;

/// Collects the ids of every store-resident reply in `root_event_id`'s thread:
/// a breadth-first walk of the `#e` graph out from the root. The walk is what
/// makes SUB-threads whole: a NIP-10 reply tags only the true thread root and
/// its direct parent, so a single `#e = sub-root` query returns just the
/// direct children of a mid-thread note while its deeper descendants (already
/// ingested by the top level's fetch) go unseen.
///
/// Membership is CONNECTIVITY, not co-mention: a candidate joins only when the
/// note it answers (`nip10Parent`) is the level root or already a member, or
/// when it carries a non-mention `e` reference to the level root itself, which
/// keeps a reply whose interior parent never reached the store visible as a
/// top-level row instead of vanishing. A mere `nip10Parent != null` would
/// admit a foreign thread's reply that only QUOTES ours, and then import that
/// thread's whole subtree through the next round's frontier.
///
/// The breadth-first order collects parents in an earlier round than their
/// children, so overflowing the display cap drops subtree tails rather than
/// interior parents. Within one round the store's newest-first `limit` can
/// still cut old referers (see `thread_walk_limit`).
pub fn collectThreadIds(store: *nostr.store.Store, root_event_id: [32]u8, out: *[thread_reply_cap][32]u8) usize {
    // Hex forms of the frontier ids, referenced by the query's tag filter:
    // slot 0 is the root, slot 1+i mirrors out[i].
    var hexes: [thread_reply_cap + 1][64]u8 = undefined;
    var values: [thread_reply_cap][]const u8 = undefined;
    hexLower(&hexes[0], root_event_id);
    var count: usize = 0;
    var frontier_start: usize = 0;
    var first_round = true;
    while (count < out.len) {
        var nvals: usize = 0;
        if (first_round) {
            values[0] = &hexes[0];
            nvals = 1;
        } else {
            for (frontier_start..count) |i| {
                hexLower(&hexes[1 + i], out[i]);
                values[nvals] = &hexes[1 + i];
                nvals += 1;
            }
        }
        if (nvals == 0) break;
        const round_start = count;
        // A tags-ONLY filter: with a kind in the filter the store's index
        // ladder prefers the kind index and streams every kind:1 ever stored,
        // post-filtering on the tag, which is the whole feed history, per round. The
        // tag index streams just the frontier's referers; the kind gate is
        // cheap and ours.
        const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = values[0..nvals] }};
        var result = store.query(std.heap.page_allocator, .{ .tags = &tag_filters, .limit = thread_walk_limit }) catch break;
        defer result.deinit();
        // Round-local fixpoint, admitting OLDEST first (the store answers
        // newest-first): a parent is older than its children, so oldest-first
        // usually connects everything in one pass, and overflowing the cap
        // keeps the conversation's beginning (the parents everything hangs
        // from) rather than its newest tail. Whatever stays unconnected
        // after the fixpoint does not belong to this thread.
        while (count < out.len) {
            var admitted = false;
            var idx: usize = result.events.len;
            while (idx > 0) {
                idx -= 1;
                const ev = result.events[idx];
                if (count >= out.len) break;
                // A comment is a reply, so it belongs in the thread it
                // answers. Excluding it here is what made a conversation show
                // silence rather than a gap: the events were in the store and
                // the walk stepped over them.
                if (ev.kind != 1 and ev.kind != comment_kind) continue;
                if (std.mem.eql(u8, &ev.id, &root_event_id)) continue;
                const parent = replyParent(ev.kind, ev.tags) orelse continue;
                var connected = std.mem.eql(u8, &parent, &root_event_id) or replyReferences(ev.kind, ev.tags, root_event_id);
                if (!connected) {
                    for (out[0..count]) |*member| {
                        if (std.mem.eql(u8, member, &parent)) {
                            connected = true;
                            break;
                        }
                    }
                }
                if (!connected) continue;
                var dup = false;
                for (out[0..count]) |*seen| {
                    if (std.mem.eql(u8, seen, &ev.id)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                out[count] = ev.id;
                count += 1;
                admitted = true;
            }
            if (!admitted) break;
        }
        // The next frontier is exactly this round's finds; none means the
        // closure is complete.
        if (count == round_start) break;
        frontier_start = round_start;
        first_round = false;
    }
    return count;
}

/// One ancestor level's collected reply ids, stamped with the store's event
/// count, so the per-frame render of an OCCLUDED level re-walks the `#e`
/// closure only when the store actually grew, not every frame. UI-thread
/// only, like the arrange scratch above.
const LevelReplies = struct {
    root: [32]u8 = [_]u8{0} ** 32,
    stamp: usize = std.math.maxInt(usize),
    ids: [thread_reply_cap][32]u8 = undefined,
    len: usize = 0,
};
pub var g_level_replies: [thread_depth_max]LevelReplies = [_]LevelReplies{.{}} ** thread_depth_max;

/// How far up the chain above the focal note is drawn. A thread can be
/// arbitrarily deep, and the walk costs a point read per step, so the chain
/// stops here and SAYS that it stopped (see `AncestorGap.capped`): clicking the
/// topmost ancestor focuses it, and its own chain continues from there.
pub const thread_ancestor_max = 8;

/// Why the chain above the focal note stops where it does.
pub const AncestorGap = enum {
    /// It does not: the chain reaches the thread's opening note.
    none,
    /// The next note up is not in the store yet. The subscription is out for it.
    missing,
    /// The chain is deeper than `thread_ancestor_max`, so the rest is above what
    /// is drawn.
    capped,
};

/// One ancestor level's chain above the focal note, stamped with the store's
/// event count so the walk (a point read per step) runs when the store grows
/// rather than every frame. UI-thread only, like the reply caches above.
const AncestorChain = struct {
    focal: [32]u8 = [_]u8{0} ** 32,
    stamp: usize = std.math.maxInt(usize),
    /// Oldest first, which is the order they are drawn in.
    ids: [thread_ancestor_max][32]u8 = undefined,
    /// How many body lines each of those notes draws, cached with the walk so an
    /// OCCLUDED level can price its rows without building a single Note. That is
    /// the only thing such a level needs from the chain, and reading eight events
    /// per level per frame to learn it was most of the cost the walk cache set
    /// out to remove.
    lines: [thread_ancestor_max]u8 = [_]u8{0} ** thread_ancestor_max,
    len: usize = 0,
    gap: AncestorGap = .none,
    /// Whether the id the chain stops below is the thread's declared root, which
    /// is the difference between "root note not here yet" and "the note this
    /// answers is not here yet".
    gap_is_root: bool = false,
};
/// One per mounted level: the back-stack plus the open thread.
pub var g_ancestor_chains: [thread_depth_max + 1]AncestorChain = [_]AncestorChain{.{}} ** (thread_depth_max + 1);

/// Walks from `focal` up its NIP-10 reply chain, collecting the ancestors that
/// are in the store (oldest first) and recording why the walk stopped. Cheap on
/// a repeat call: the result is cached until the store grows or the focal note
/// changes.
pub fn refreshAncestorChain(chain: *AncestorChain, store: *nostr.store.Store, focal: *const Note, stamp: usize) void {
    chain.* = .{ .focal = focal.event_id, .stamp = stamp };
    if (!focal.has_reply_parent) return;

    // The root the focal note itself declares, so a gap can be named. Read from
    // the store rather than carried on the Note: only this row needs it.
    var declared_root: ?[32]u8 = null;
    if (store.getEvent(std.heap.page_allocator, focal.event_id) catch null) |se| {
        var owned = se;
        defer owned.deinit();
        declared_root = replyRoot(owned.event.kind, owned.event.tags);
    }

    // Newest first while walking, reversed into the cache at the end.
    var up: [thread_ancestor_max][32]u8 = undefined;
    var up_lines: [thread_ancestor_max]u8 = undefined;
    var n: usize = 0;
    const now = nowSeconds();
    var want = focal.reply_parent;
    // A note that tags ITSELF as its parent would otherwise be walked as its own
    // ancestor and drawn twice in one list, under the same row key.
    if (std.mem.eql(u8, &want, &focal.event_id)) return;
    while (true) {
        if (n == thread_ancestor_max) {
            chain.gap = .capped;
            break;
        }
        var se = (store.getEvent(std.heap.page_allocator, want) catch null) orelse {
            chain.gap = .missing;
            // The ghost row says the relays are being asked for this, so ask
            // them: the thread's own subscription only covers what answers the
            // focal note, never what it answers.
            wantQuote(want);
            break;
        };
        defer se.deinit();
        up[n] = want;
        // Stamped here, where the event is already in hand.
        up_lines[n] = @intFromFloat(ancestorBodyLines(&noteFrom(se.event, now)));
        n += 1;
        if (declared_root == null) declared_root = replyRoot(se.event.kind, se.event.tags);
        const parent = nip10Parent(se.event.tags) orelse break;
        // A malformed cycle (a note tagging one of its own descendants, or its
        // own id) would walk forever, so a repeat ends the chain where it
        // repeats. It has NOT reached the thread's opening note, and the row
        // says so rather than claiming the chain is whole.
        if (std.mem.eql(u8, &parent, &focal.event_id)) {
            chain.gap = .missing;
            return finishChain(chain, up[0..n], up_lines[0..n], declared_root, parent);
        }
        for (up[0..n]) |seen| {
            if (std.mem.eql(u8, &seen, &parent)) {
                chain.gap = .missing;
                return finishChain(chain, up[0..n], up_lines[0..n], declared_root, parent);
            }
        }
        want = parent;
    }
    finishChain(chain, up[0..n], up_lines[0..n], declared_root, want);
}

/// Reverses the walk into drawing order and names the gap, if there is one.
fn finishChain(chain: *AncestorChain, up: []const [32]u8, up_lines: []const u8, declared_root: ?[32]u8, stopped_at: [32]u8) void {
    for (up, 0..) |id, i| {
        chain.ids[up.len - 1 - i] = id;
        chain.lines[up.len - 1 - i] = up_lines[i];
    }
    chain.len = up.len;
    chain.gap_is_root = chain.gap == .missing and declared_root != null and
        std.mem.eql(u8, &declared_root.?, &stopped_at);
}

/// One row of the chain above the focal note: an ancestor read from the store,
/// or the gap where the chain stops.
pub const Ancestor = struct {
    note: Note = .{},
    /// How many body lines this row draws. Carried on the row because an
    /// occluded level has no `note` to measure.
    lines: u8 = 0,
    /// `.none` for a real ancestor; anything else makes this row a ghost.
    ghost: AncestorGap = .none,
    /// For a ghost: whether what is missing is the thread's opening note.
    is_root: bool = false,
};
/// One top-level reply and what hangs off it. The redesign shows exactly one
/// level of nesting in place: a reply, the replies to THAT reply, and then a line
/// saying how much of the branch continues out of sight. Deeper than that is a
/// thread of its own, which is what pressing the line opens.
pub const ThreadBlock = struct {
    parent: *const Note,
    /// The parent's direct replies, contiguous in the arranged order.
    children: []const Note,
    /// Per child, how many of ITS descendants are not drawn. Parallel to
    /// `children`, so a branch says so under the reply it continues from.
    deeper: []const usize,
};
/// The two tiers of a thread's replies, in their original order.
pub const GraphSplit = struct { inside: []const ThreadBlock, outside: []const ThreadBlock };

/// How many REPLIES a run of blocks holds, which is what the line above them
/// counts. A block is one conversation: the reply that opened it, the replies
/// drawn under it, and whatever those collapse into.
pub fn heldReplies(blocks: []const ThreadBlock) usize {
    var held: usize = 0;
    for (blocks) |block| {
        held += 1 + block.children.len;
        for (block.deeper) |deeper| held += deeper;
    }
    return held;
}

pub fn splitByFollowGraph(ui: *AppUi, blocks: []const ThreadBlock, author: [32]u8) GraphSplit {
    if (blocks.len == 0) return .{ .inside = &.{}, .outside = &.{} };
    const inside = ui.arena.alloc(ThreadBlock, blocks.len) catch return .{ .inside = blocks, .outside = &.{} };
    const outside = ui.arena.alloc(ThreadBlock, blocks.len) catch return .{ .inside = blocks, .outside = &.{} };
    var ni: usize = 0;
    var no: usize = 0;
    for (blocks) |block| {
        // The conversation is placed by whoever opened it: a stranger's reply is
        // held below even when someone followed answers inside it.
        // Whoever wrote the note being read is inside their own thread whether
        // or not the reader follows them: otherwise opening a stranger's reply
        // would hold their own continuation of it behind a collapsed line.
        if (std.mem.eql(u8, &block.parent.pubkey, &author) or inFollowGraph(block.parent.pubkey)) {
            inside[ni] = block;
            ni += 1;
        } else {
            outside[no] = block;
            no += 1;
        }
    }
    return .{ .inside = inside[0..ni], .outside = outside[0..no] };
}

/// A fresh arrival table, for a test that drives the real stamping.
pub fn arrivalTableForTest() ArrivalTable {
    return .{};
}

pub fn stampArrivalForTest(table: *ArrivalTable, notes: []Note, settled: bool) void {
    stampArrival(table, notes, settled);
}
pub fn splitByFollowGraphForTest(ui: *AppUi, blocks: []const ThreadBlock, author: [32]u8) GraphSplit {
    return splitByFollowGraph(ui, blocks, author);
}

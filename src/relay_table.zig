//! The relay table: its slots, the bootstrap set, and the relays file.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const forgetChangedRelaySlotStates = main.forgetChangedRelaySlotStates;
const forgetOutboxAcks = main.forgetOutboxAcks;
const hexLower = main.hexLower;
const plazaDir = main.plazaDir;
const relayUrlEql = main.relayUrlEql;
const resetFeedEnd = main.resetFeedEnd;
const setRelayListStamp = main.setRelayListStamp;
const snapshotRelayUrls = main.snapshotRelayUrls;

// The relay pool this milestone dials, and how many recent notes to keep on
// screen. Each relay runs on its own thread and ingests into the one shared
// store, which dedupes by event id. NIP-65 outbox routing (reading each author
// from their own write relays) needs a follow list, so it arrives with a later
// milestone; here a fixed pool is the relay engine.
// ---------------------------------------------------------------------- the pool
//
// Which relays this app talks to, and in which direction.
//
// It was a comptime list, which made every per-relay table a fixed array
// indexed by position and every thread a permanent one. A reader cannot be
// asked to accept somebody else's five relays forever, so the pool is a TABLE
// now: fixed capacity, because a client with fifty relays is not a client but a
// crawler, and a live count that only ever grows toward that cap.
//
// Two rules make the change safe rather than sprawling. A relay's SLOT is
// stable for the life of the process once claimed, so every index held
// elsewhere (the status table, the RTT ring, the outbox's per-relay ack bits)
// stays valid; removing a relay marks its slot dormant rather than compacting
// the array. And a slot's thread outlives its relay: it notices the change and
// re-dials, which is the same path a dropped connection already takes.
pub const max_relays = 8;
// The outbox records one BIT per relay in a `u8`, and a shift amount is a `u3`,
// so nine relays would not be a tight fit: it would be an @intCast panic in a
// safe build and worse in a fast one. Widening the pool means widening that
// mask, its persisted form, and this line together.
comptime {
    if (max_relays > 8) @compileError("max_relays exceeds the outbox ack mask; widen OutboxEntry.acked with it");
}

/// One relay, and what the reader asked of it. NIP-65's markers: a relay may be
/// read-only, write-only, or both, and both is the default because that is what
/// an `r` tag with no marker means.
pub const RelayEntry = struct {
    used: bool = false,
    url_buf: [96]u8 = [_]u8{0} ** 96,
    url_len: u8 = 0,
    read: bool = true,
    write: bool = true,

    pub fn url(self: *const RelayEntry) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

/// The pool the app was born with, used until the reader's own list is read
/// from their kind:10002 or from disk. Not a default to be proud of, just a
/// starting point that works on the first launch.
pub const bootstrap_relays = [_][]const u8{
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://relay.snort.social",
};

/// Relays asked one question only: where does this person publish?
///
/// The outbox bootstrap. To route to somebody's write relays you must first
/// hold their kind:10002, and you cannot ask their write relays for it, because
/// finding them is the thing you are trying to do. Plaza only ever learned a
/// relay list from a relay it was already reading, so a followed account whose
/// list lives anywhere else was never routed to and simply never appeared. No
/// error, no empty state, which is the exact failure the outbox model exists to
/// fix and the easiest one to leave behind while fixing it.
///
/// The set is READ FROM FOUR SHIPPING CLIENTS rather than picked. nos.lol is in
/// three of them (Jumble, Amethyst desktop, NDK), purplepag.es in two (Amethyst
/// mobile, NDK), primal in two (Jumble, Amethyst desktop). kindpag.es is
/// Amethyst mobile alone and is here because it is the only one of the four
/// built for indexing rather than a general relay that happens to keep
/// replaceables; Amethyst's own desktop source carries a comment saying its
/// purpose-built list is the better one and adopting it is a separate ticket.
///
/// These are NOT pool relays. They are never published in the reader's
/// kind:10002, never routed to for notes, and never counted in the eight, which
/// is Jumble's `filterOutBigRelays` discipline rather than Notedeck's, where
/// the bootstrap set gets spliced into the user's own advertised relays the
/// first time they edit their list.
pub const indexer_relays = [_][]const u8{
    "wss://purplepag.es",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://user.kindpag.es",
};
/// Authors per REQ. Amethyst desktop chunks at exactly this and sets its limit
/// to the chunk size; Amethyst ANDROID puts the whole follow list in one filter
/// and a 2000-entry `authors` array is past what most relays accept, so they
/// truncate or CLOSE without saying which. Chunked at the wire, because in this
/// codebase the frame writer IS the wire and nothing merges behind it.
pub const indexer_chunk = 100;

pub var g_relays = [_]RelayEntry{.{}} ** max_relays;
/// How many slots have ever been claimed. It never shrinks, because a slot's
/// index is a promise to everything that recorded one.
pub var g_relay_count = std.atomic.Value(u8).init(0);

/// NIP-65's kind. A reader's relay list is a replaceable event: the newest one
/// they signed IS their list, which is why an edit here publishes.
pub const relay_list_kind: u16 = 10002;

/// Relays this reader's follows publish to, learned from their own kind:10002.
/// Offered under the add field, because the relays the people you read write to
/// are the relays that will actually carry their notes to you.
pub const max_relay_suggestions = 6;
pub var g_suggested = [_][96]u8{[_]u8{0} ** 96} ** max_relay_suggestions;
pub var g_suggested_len = [_]u8{0} ** max_relay_suggestions;
pub var g_suggested_count = std.atomic.Value(u8).init(0);
/// Guards the relay table and the suggestions beside it. Ingest threads dial
/// out of one and write the other, the UI thread edits both, and every critical
/// section is a short scan or a fixed copy with no IO in it, so a spinlock is
/// the right weight (and `std.Io.Mutex` would drag an `io` through threads that
/// deliberately never share one).
var g_suggested_lock = std.atomic.Value(bool).init(false);

pub fn lockRelayTable() void {
    while (g_suggested_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockRelayTable() void {
    g_suggested_lock.store(false, .release);
}
/// Where the reader's relay list lives on disk, for a guest and as the fallback
/// when no kind:10002 has been read yet. One URL per line with an optional
/// `read` or `write` marker, which is NIP-65's own vocabulary written plainly:
/// no marker means both, which is what an unmarked `r` tag means.
const relays_file = "relays";

/// Reads the reader's list, or seeds the one the app was born with. Called
/// before the ingest threads start, so the first dial goes where they asked.
pub fn loadRelays(io: std.Io, environ: *const std.process.Environ.Map) void {
    var dir = plazaDir(io, environ) catch {
        seedBootstrapRelays();
        return;
    };
    defer dir.close(io);
    var buf: [relays_file_cap]u8 = undefined;
    const raw = dir.readFile(io, relays_file, &buf) catch {
        seedBootstrapRelays();
        return;
    };
    applyRelaysFile(raw);
}

/// The most the file can be. Worst case is the owner line, the stamp line, and
/// every slot at its longest URL with a marker.
const relays_file_cap = max_relays * 128 + 96;

/// Reads the file's TEXT into the pool. Split from the io so the format has a
/// test: the stamp line is what stops this account's own newer list from being
/// refused across a restart, and a format nothing round-trips is a format that
/// silently stops carrying it.
pub fn applyRelaysFile(raw: []const u8) void {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    var added: usize = 0;
    var owner: ?[32]u8 = null;
    var stamp: i64 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const first = parts.next() orelse continue;
        // `owner <hex>`: whose list this is. A file with no owner line is one
        // this app wrote before it recorded that, or a guest's, and belongs to
        // nobody: it seeds the pool but never refuses an incoming kind:10002.
        if (std.mem.eql(u8, first, "owner")) {
            const hex = parts.next() orelse continue;
            var pk: [32]u8 = undefined;
            if (hex.len == 64) {
                if (std.fmt.hexToBytes(&pk, hex)) |_| owner = pk else |_| {}
            }
            continue;
        }
        // `stamp <created_at>`: when the list in this file was signed. A file
        // written before this line existed has none, which reads as 0, which
        // means the first kind:10002 to arrive wins. That is the right way to
        // be wrong: the alternative is a pool nothing can ever correct.
        if (std.mem.eql(u8, first, "stamp")) {
            const digits = parts.next() orelse continue;
            stamp = std.fmt.parseInt(i64, digits, 10) catch continue;
            continue;
        }
        if (!isRelayUrl(first)) continue;
        const marker = parts.next();
        const read = marker == null or std.mem.eql(u8, marker.?, "read");
        const write = marker == null or std.mem.eql(u8, marker.?, "write");
        if (addRelay(first, read, write) != null) added += 1;
    }
    // A file that exists but holds nothing usable would leave the app with no
    // way to reach anyone, which is worse than ignoring it.
    if (added == 0) {
        seedBootstrapRelays();
        return;
    }
    // A saved list is its OWNER's. Logging out writes the bootstrap pool to this
    // same file, so "a file exists" says nothing about whose relays are in it,
    // and reading it as the signed-in account's would let five default relays be
    // published over a real NIP-65 list.
    main.g_relay_owner = owner;
    main.g_relays_are_mine = owner != null;
    setRelayListStamp(stamp);
}

/// Writes the list back in the same plain form.
pub fn saveRelays() void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var buf: [relays_file_cap]u8 = undefined;
    const text = formatRelaysFile(&buf) orelse return;
    dir.writeFile(io, .{ .sub_path = relays_file, .data = text, .flags = .{} }) catch {};
}

/// The file's TEXT, from the pool. Split from the io for the same reason
/// `applyRelaysFile` is.
pub fn formatRelaysFile(buf: []u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    // Whose list this is, first. Without it a file written while signed out (the
    // bootstrap pool) reads back as the next account's own list.
    if (main.g_relay_owner) |owner| {
        var hex: [64]u8 = undefined;
        hexLower(&hex, owner);
        w.print("owner {s}\n", .{hex[0..]}) catch return null;
    }
    // And WHEN it was signed, so a launch can tell this account's own newer list
    // from an older one a slow relay is still replaying.
    if (main.g_relay_list_stamp != 0) {
        w.print("stamp {d}\n", .{main.g_relay_list_stamp}) catch return null;
    }
    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse continue;
        const marker: []const u8 = if (e.read and e.write) "" else if (e.read) " read" else " write";
        w.print("{s}{s}\n", .{ e.url(), marker }) catch return null;
    }
    return w.buffered();
}

/// Whether a string is a relay address this app will dial. Deliberately narrow:
/// this is a URL the reader typed, and everything else in the app trusts the
/// pool to be relays.
pub fn isRelayUrl(url: []const u8) bool {
    // `wss://` only. A relay this app can reach is on the public internet (the
    // host check below rules out anything else), and over `ws://` every filter
    // the reader sends and every note they read travels in the clear to anyone
    // on the path. A follow's published list DOES carry plain `ws://` relays,
    // which is exactly why this is checked here rather than assumed.
    if (!std.mem.startsWith(u8, url, "wss://")) return false;
    const rest = url["wss://".len..];
    if (rest.len == 0 or rest.len > 80) return false;
    // No whitespace and no control byte anywhere. This string is written to the
    // relays file one relay per line and sent in the handshake's request line,
    // so a newline or a BEL in it is not a typo, it is a different file or a
    // different request.
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    // And the same reading of the address the dialler will give it, so a port
    // that is not a number is refused here rather than listed, counted, and
    // retried forever.
    _ = nostr.relay.parseUrl(url) catch return false;
    // A host, at least: something before the first slash, with a dot in it.
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];
    if (host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, host, '@') != null) return false;
    return std.mem.indexOfScalar(u8, host, '.') != null;
}

/// The URL in slot `i`, or a placeholder when the slot is empty. For messages
/// about a slot, where a missing relay is still worth naming.
pub fn relayUrlAt(i: usize) []const u8 {
    const e = relayAt(i) orelse return "(removed)";
    return e.url();
}

/// How many relays the reader actually has, which is what every count they are
/// shown is out of. A dormant slot is not a relay.
pub fn relayCount() usize {
    var n: usize = 0;
    for (0..relaySlots()) |i| {
        if (relayAt(i) != null) n += 1;
    }
    return n;
}

/// How many of them take writes, which is the denominator an outbox
/// acknowledgement is out of: a note is not owed to a relay never asked to hold
/// it.
pub fn writeRelayCount() usize {
    var n: usize = 0;
    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse continue;
        if (e.write) n += 1;
    }
    return n;
}

/// Relays this reader has taken OUT of the pool since this account signed in.
///
/// A publish splices the pool onto the kind:10002 they already published, and
/// the test that carries a relay forward is "the pool has no seat for it": that
/// is what protects the relays past the pool's capacity, and a relay the reader
/// just removed looks identical. Without this ledger every removal would be
/// undone by the very splice that protects everything else.
///
/// A SESSION ledger on purpose. It exists to shape the next publish, and that
/// publish rewrites the stored list, after which there is nothing left to
/// carry. Overflowing it means one removal does not take and the relay comes
/// back on the next publish, which is the harmless direction to fail in.
const relay_removed_cap = max_relays * 2;
var g_relay_removed: [relay_removed_cap][96]u8 = [_][96]u8{[_]u8{0} ** 96} ** relay_removed_cap;
var g_relay_removed_len: [relay_removed_cap]u8 = [_]u8{0} ** relay_removed_cap;
var g_relay_removed_n: usize = 0;

pub fn noteRelayRemoved(url: []const u8) void {
    if (url.len == 0 or url.len > 96) return;
    if (relayWasRemoved(url)) return;
    if (g_relay_removed_n >= relay_removed_cap) return;
    @memcpy(g_relay_removed[g_relay_removed_n][0..url.len], url);
    g_relay_removed_len[g_relay_removed_n] = @intCast(url.len);
    g_relay_removed_n += 1;
}

pub fn relayWasRemoved(url: []const u8) bool {
    for (0..g_relay_removed_n) |i| {
        if (relayUrlEql(g_relay_removed[i][0..g_relay_removed_len[i]], url)) return true;
    }
    return false;
}

/// Forgets every removal. Called when the pool stops being the one those
/// removals were about: a sign-out, or a list adopted from their own kind:10002.
pub fn forgetRelayRemovals() void {
    g_relay_removed_n = 0;
}

/// Whether the pool has a seat holding `url` right now.
pub fn poolHoldsRelay(url: []const u8) bool {
    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse continue;
        if (relayUrlEql(e.url(), url)) return true;
    }
    return false;
}

/// Puts the pool back to the one the app was born with, and forgets what was
/// recorded against the seats that change hands. A seat still holding the same
/// relay keeps its row, because the socket behind it never went anywhere: see
/// `forgetChangedRelaySlotStates` for why clearing it would not go stale, it
/// would simply stay wrong. Used on sign-out, where the list that is
/// leaving belonged to the account that is leaving.
pub fn resetRelaysToBootstrap() void {
    var before: [max_relays][96]u8 = undefined;
    var lens: [max_relays]u8 = undefined;
    snapshotRelayUrls(&before, &lens);
    lockRelayTable();
    g_relays = [_]RelayEntry{.{}} ** max_relays;
    main.g_staged_created_at = 0;
    unlockRelayTable();
    g_relay_count.store(0, .release);
    main.g_relays_are_mine = false;
    main.g_relay_owner = null;
    // The stamp goes with the owner. Left behind, the bootstrap pool the next
    // account inherits would claim to be as new as the list the previous one
    // published, and refuse theirs.
    setRelayListStamp(0);
    main.g_staged_ready.store(false, .release);
    g_suggested_count.store(0, .release);
    main.g_relay_list_dirty = false;
    forgetRelayRemovals();
    // Seeded FIRST, so the comparison below is against the pool that is actually
    // in place rather than the momentary empty table.
    seedBootstrapRelays();
    forgetChangedRelaySlotStates(&before, &lens);
    forgetOutboxAcks();
    saveRelays();
}
pub const RelayUse = struct { read: bool, write: bool };
/// A relay, copied out of the table so a background thread can hold it.
pub const RelayDial = struct { url: []const u8, read: bool, write: bool };

/// Reads slot `i` into `buf`, which the caller owns, under the table lock.
///
/// This is the ONLY way a thread other than the UI thread may look at a relay.
/// `relayAt` hands back a pointer into `g_relays`, and `RelayEntry.url()` slices
/// it: the length is taken now and the bytes are read later, so a reader that
/// holds one across a dial can end up with a length from one relay and bytes
/// from the next. Copying under the lock makes the address the caller dials the
/// address that was in the slot when it looked.
pub fn relaySnapshot(i: usize, buf: *[96]u8) ?RelayDial {
    lockRelayTable();
    defer unlockRelayTable();
    if (i >= g_relays.len) return null;
    const e = &g_relays[i];
    if (!e.used or e.url_len == 0) return null;
    const len = e.url_len;
    @memcpy(buf[0..len], e.url_buf[0..len]);
    return .{ .url = buf[0..len], .read = e.read, .write = e.write };
}

/// The relay in slot `i`, or null when that slot is empty or dormant.
pub fn relayAt(i: usize) ?*const RelayEntry {
    if (i >= g_relays.len) return null;
    const e = &g_relays[i];
    return if (e.used) e else null;
}

/// How many slots to walk. Everything that iterates the pool uses this rather
/// than a length, because a dormant slot in the middle is normal.
pub fn relaySlots() usize {
    return @min(g_relay_count.load(.monotonic), g_relays.len);
}

/// Fills the pool from the bootstrap list, for a first run with nothing saved.
pub fn seedBootstrapRelays() void {
    for (bootstrap_relays) |url| _ = addRelay(url, true, true);
}

/// Claims a slot for `url`, or returns the slot it already occupies. Returns
/// null when the pool is full, which the caller surfaces rather than hides.
pub fn addRelay(url: []const u8, read: bool, write: bool) ?usize {
    // A relay nobody has asked yet may hold a decade of history the feed has
    // already decided does not exist.
    resetFeedEnd();
    if (url.len == 0 or url.len > 96) return null;
    for (0..relaySlots()) |i| {
        if (g_relays[i].used and relayUrlEql(g_relays[i].url(), url)) return i;
    }
    // A dormant slot first, so removing and re-adding does not consume the pool.
    for (0..g_relays.len) |i| {
        if (g_relays[i].used) continue;
        lockRelayTable();
        g_relays[i] = .{ .used = true, .read = read, .write = write };
        @memcpy(g_relays[i].url_buf[0..url.len], url);
        g_relays[i].url_len = @intCast(url.len);
        unlockRelayTable();
        if (i >= relaySlots()) g_relay_count.store(@intCast(i + 1), .release);
        return i;
    }
    return null;
}

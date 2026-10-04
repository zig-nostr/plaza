//! Relay hints: which relays a note was seen on, and the addresses that carry them.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Note = main.Note;
const hexAlloc = main.hexAlloc;
const idPrefix = main.idPrefix;
const isRelayUrl = main.isRelayUrl;
const outbox_relays_per_author = main.outbox_relays_per_author;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const relayUrlEql = main.relayUrlEql;
const relay_list_kind = main.relay_list_kind;
const selectWriteRelays = main.selectWriteRelays;
const writeTagUrls = main.writeTagUrls;

/// How many relays go into an address Plaza hands out. Jumble's number
/// (`getNoteBech32Id` slices to two): each hint a reader follows is a socket.
pub const hint_cap = 2;
/// How many delivering relays are read back for one note.
const seen_read_cap = 8;

/// A bounded, de-duplicated list of relay URLs, each already fit to publish.
pub fn UrlList(comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap][96]u8 = undefined,
        len: [cap]u8 = @splat(0),
        count: usize = 0,

        /// Adds `url_in` when a stranger could dial it and the list does not
        /// already hold it. Stored without a trailing slash, which is how every
        /// client writes a relay into a tag. True when it was added.
        pub fn add(self: *Self, url_in: []const u8) bool {
            if (self.count >= cap) return false;
            const url = std.mem.trimEnd(u8, std.mem.trim(u8, url_in, " \t\r\n"), "/");
            if (!isHintableRelay(url)) return false;
            if (self.has(url)) return false;
            @memcpy(self.buf[self.count][0..url.len], url);
            self.len[self.count] = @intCast(url.len);
            self.count += 1;
            return true;
        }

        fn has(self: *const Self, url: []const u8) bool {
            for (0..self.count) |i| {
                if (relayUrlEql(self.at(i), url)) return true;
            }
            return false;
        }

        pub fn at(self: *const Self, i: usize) []const u8 {
            return self.buf[i][0..self.len[i]];
        }
    };
}

pub const HintList = UrlList(hint_cap);

/// Whether a relay URL can be written into something other people read.
///
/// `isRelayUrl` already refuses `ws://`, a host with no dot and a login in front
/// of the host. What it lets through, and this refuses, is an address only the
/// publisher can reach, and a URL with a query or a fragment: a relay address
/// that carries one is usually carrying an access token, and a hint would hand
/// that token to every reader.
pub fn isHintableRelay(url: []const u8) bool {
    if (!isRelayUrl(url)) return false;
    if (std.mem.indexOfAny(u8, url, "?#") != null) return false;
    const rest = url["wss://".len..];
    const host_end = std.mem.indexOfAny(u8, rest, "/:") orelse rest.len;
    return !isPrivateHost(rest[0..host_end]);
}

fn isPrivateHost(host_in: []const u8) bool {
    // A bracketed literal is IPv6, which has no business in a relay hint.
    if (host_in.len == 0 or host_in[0] == '[') return true;
    // `relay.local.` is `relay.local`. The trailing dot only marks the name as
    // absolute, and left on it would carry any name past the suffix check.
    const host = std.mem.trimEnd(u8, host_in, ".");
    if (host.len == 0) return true;
    // `.onion` and `.i2p` resolve only inside Tor or I2P, so a reader without
    // one cannot dial them, and the name says which network the publisher uses.
    const private_suffixes = [_][]const u8{ ".localhost", ".local", ".internal", ".lan", ".home.arpa", ".onion", ".i2p" };
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    for (private_suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(host, suffix)) return true;
    }
    // An address, not a name: no top-level domain is all digits, so a host whose
    // last label is digits is an IP literal. Only the plain dotted quad is read.
    // The short and hex forms (`127.1`, `0x7f.0.0.1`) dial loopback through
    // most resolvers, and are refused rather than parsed.
    const last = host[(if (std.mem.lastIndexOfScalar(u8, host, '.')) |d| d + 1 else 0)..];
    for (last) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    var octets: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (n == 4 or part.len == 0 or part.len > 3) return true;
        octets[n] = std.fmt.parseInt(u8, part, 10) catch return true;
    }
    if (n != 4) return true;
    // Some ranges are nobody's: this host, private networks, shared address
    // space, link-local, and multicast and reserved from 224 up.
    return switch (octets[0]) {
        0, 10, 127 => true,
        100 => octets[1] >= 64 and octets[1] <= 127,
        169 => octets[1] == 254,
        172 => octets[1] >= 16 and octets[1] <= 31,
        192 => octets[1] == 168,
        224...255 => true,
        else => false,
    };
}

/// Kinds worth remembering a delivering relay for: the ones a reader can reply
/// to, quote, repost or react to. Profiles, lists, reactions and zaps are most
/// of what a relay sends and none of it is ever the target of a hint, so
/// recording them would only push the notes out of the table.
fn hintWorthyKind(kind: u16) bool {
    return switch (kind) {
        0, 3, 5, 7, 9735 => false,
        10000...29999 => false,
        else => true,
    };
}

/// Which relays delivered which note, remembered for the length of the session.
///
/// Direct-mapped on the id's low bits and checked against the whole prefix, so a
/// collision costs the older note its answer (falling back to the author's
/// relays) and never gives a note another note's relay. One word of relay
/// bits per note, indexed into a small table of the distinct URLs seen, because
/// a URL per note would cost ninety-six bytes for something the table repeats
/// eight times over.
///
/// Not the engagement table's `relays_seen`, which is keyed to the pool's slots
/// and only exists for notes already on screen. The relays that carry most of a
/// feed are the routed ones, which are not in the pool at all.
const seen_on_slots = 1 << 13;
const seen_url_cap = 64;
const SeenOn = struct { prefix: u64 = 0, mask: u64 = 0 };
pub var g_seen_on = [_]SeenOn{.{}} ** seen_on_slots;
var g_seen_url = [_][96]u8{[_]u8{0} ** 96} ** seen_url_cap;
var g_seen_url_len = [_]u8{0} ** seen_url_cap;
pub var g_seen_url_n: usize = 0;
var g_seen_on_lock = std.atomic.Value(bool).init(false);

pub fn seenOnLock() void {
    while (g_seen_on_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn seenOnUnlock() void {
    g_seen_on_lock.store(false, .release);
}

/// Notes that `url` delivered `ev`. Called from each ingest thread as an event
/// lands, after it has been verified.
pub fn recordSeenOn(ev: nostr.event.Event, url: []const u8) void {
    if (!hintWorthyKind(ev.kind)) return;
    recordSeenOnId(ev.id, url);
}

pub fn recordSeenOnId(id: [32]u8, url_in: []const u8) void {
    const prefix = idPrefix(id);
    // Zero marks an empty slot, so the one-in-2^64 all-zero prefix just is not
    // remembered, which is the engagement dedup's convention too.
    if (prefix == 0) return;
    const url = std.mem.trimEnd(u8, url_in, "/");
    seenOnLock();
    defer seenOnUnlock();
    var idx: ?usize = null;
    for (0..g_seen_url_n) |i| {
        if (relayUrlEql(g_seen_url[i][0..g_seen_url_len[i]], url)) {
            idx = i;
            break;
        }
    }
    if (idx == null) {
        // Checked only for a relay not in the table, so for one already met the
        // hot path is the short scan above. A relay the rule refuses is never
        // added and is checked again on its next event, which is a few compares.
        var probe: UrlList(1) = .{};
        if (!probe.add(url)) return;
        if (g_seen_url_n == seen_url_cap) {
            // More distinct relays than the table holds in one session. Start
            // over rather than refuse every new one: what is forgotten falls
            // back to the author's relays, and what is current is still true.
            for (&g_seen_on) |*e| e.* = .{};
            g_seen_url_n = 0;
        }
        const i = g_seen_url_n;
        @memcpy(g_seen_url[i][0..probe.len[0]], probe.at(0));
        g_seen_url_len[i] = probe.len[0];
        g_seen_url_n += 1;
        idx = i;
    }
    const bit = @as(u64, 1) << @intCast(idx.?);
    const slot = &g_seen_on[@intCast(prefix & (seen_on_slots - 1))];
    if (slot.prefix == prefix) {
        slot.mask |= bit;
    } else {
        slot.* = .{ .prefix = prefix, .mask = bit };
    }
}

/// The relays that delivered `id`, in the order they were first met.
fn seenOnFor(id: [32]u8, out: *UrlList(seen_read_cap)) void {
    const prefix = idPrefix(id);
    if (prefix == 0) return;
    seenOnLock();
    defer seenOnUnlock();
    const slot = g_seen_on[@intCast(prefix & (seen_on_slots - 1))];
    if (slot.prefix != prefix) return;
    for (0..g_seen_url_n) |i| {
        if (slot.mask & (@as(u64, 1) << @intCast(i)) == 0) continue;
        _ = out.add(g_seen_url[i][0..g_seen_url_len[i]]);
    }
}

/// The first few write relays `author` lists in their kind:10002, by the same
/// selection the outbox routes with. Empty when the list is not in the store.
fn authorWriteRelays(author: [32]u8, out: *UrlList(outbox_relays_per_author)) void {
    const store = main.g_store orelse return;
    const kinds = [_]u16{relay_list_kind};
    const authors = [_][32]u8{author};
    var result = store.query(std.heap.page_allocator, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return;
    defer result.deinit();
    if (result.events.len == 0) return;
    var raw: [32][]const u8 = undefined;
    var selected: [outbox_relays_per_author][]const u8 = undefined;
    const chosen = selectWriteRelays(raw[0..writeTagUrls(result.events[0], &raw)], &selected);
    for (selected[0..chosen]) |url| _ = out.add(url);
}

/// The three rules above, in order, into `out`.
fn orderHints(seen: *const UrlList(seen_read_cap), writes: *const UrlList(outbox_relays_per_author), out: anytype) void {
    for (0..seen.count) |i| {
        if (writes.has(seen.at(i))) _ = out.add(seen.at(i));
    }
    for (0..seen.count) |i| _ = out.add(seen.at(i));
    for (0..writes.count) |i| _ = out.add(writes.at(i));
}

/// The relays to name for the note `id` by `author`, best first. Empty when
/// nothing is known, which callers write as an empty hint.
pub fn hintsFor(id: [32]u8, author: ?[32]u8, out: *HintList) void {
    var seen: UrlList(seen_read_cap) = .{};
    seenOnFor(id, &seen);
    var writes: UrlList(outbox_relays_per_author) = .{};
    if (author) |pk| authorWriteRelays(pk, &writes);
    orderHints(&seen, &writes, out);
}

/// Where to look for a PERSON: the first relay they list as a write relay.
///
/// Not the relay a note of theirs happened to arrive on. That says where one
/// note was, and a `p` tag is about the account; Amethyst fills the repost's
/// `p` slot from the author's home relay for the same reason.
fn profileHint(pubkey: [32]u8) UrlList(1) {
    var writes: UrlList(outbox_relays_per_author) = .{};
    authorWriteRelays(pubkey, &writes);
    var out: UrlList(1) = .{};
    if (writes.count > 0) _ = out.add(writes.at(0));
    return out;
}

/// `["p", pubkey]`, or `["p", pubkey, relay]` when the account's own relay list
/// says where they publish. Process-lifetime, like every tag the sign paths hold.
pub fn pTagFor(gpa: std.mem.Allocator, pubkey: [32]u8) ?nostr.event.Tag {
    const hex = hexAlloc(gpa, pubkey) orelse return null;
    const hint = profileHint(pubkey);
    if (hint.count == 0) return gpa.dupe([]const u8, &.{ "p", hex }) catch null;
    const relay = gpa.dupe(u8, hint.at(0)) catch return null;
    return gpa.dupe([]const u8, &.{ "p", hex, relay }) catch null;
}

/// The relay for slot 3 of an `e` or `q` tag: the best of `hints`, or the empty
/// string, which keeps the slots after it where a reader expects them.
pub fn hintOrEmpty(gpa: std.mem.Allocator, hints: *const HintList) ?[]const u8 {
    if (hints.count == 0) return "";
    return gpa.dupe(u8, hints.at(0)) catch null;
}

pub const note_address_cap = 640;

/// The `nevent1` for a note, naming up to `relays_wanted` of the relays it can
/// be found on. With nothing known it is the bare address it always was.
pub fn noteAddress(out: *[note_address_cap]u8, note: *const Note, relays_wanted: usize) ?[]const u8 {
    var hints: HintList = .{};
    hintsFor(note.event_id, note.pubkey, &hints);
    var named: [hint_cap][]const u8 = undefined;
    const n = @min(relays_wanted, hints.count);
    for (0..n) |i| named[i] = hints.at(i);
    // Bech32 grows a list and then copies it out, so a fixed buffer is spent
    // several times over by a short result.
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const addr = nostr.nip19.encodeNevent(fba.allocator(), note.event_id, named[0..n], note.pubkey, note.kind) catch return null;
    if (addr.len > out.len) return null;
    @memcpy(out[0..addr.len], addr);
    return out[0..addr.len];
}

/// The `nprofile1` for the signed-in account, naming the relays they publish to,
/// or their `npub1` when they have none worth naming.
///
/// The relays are the pool's write relays: Plaza sends a note to exactly those,
/// so they are where this account's notes are, whether or not a kind:10002 has
/// been published yet.
pub fn profileAddress(out: *[note_address_cap]u8, pubkey: [32]u8) ?[]const u8 {
    var named: HintList = .{};
    for (0..relaySlots()) |i| {
        var url_buf: [96]u8 = undefined;
        const dial = relaySnapshot(i, &url_buf) orelse continue;
        if (!dial.write) continue;
        _ = named.add(dial.url);
    }
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var slices: [hint_cap][]const u8 = undefined;
    for (0..named.count) |i| slices[i] = named.at(i);
    const addr = if (named.count == 0)
        nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch return null
    else
        nostr.nip19.encodeNprofile(fba.allocator(), pubkey, slices[0..named.count]) catch return null;
    if (addr.len > out.len) return null;
    @memcpy(out[0..addr.len], addr);
    return out[0..addr.len];
}

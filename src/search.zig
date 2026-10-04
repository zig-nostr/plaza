//! Finding a person by name.
//!
//! Two sources answer, and they are kept apart on purpose. The first is every
//! profile already on this machine, matched here in memory with the network off.
//! The second is a NIP-50 search relay, which is a different kind of answer: the
//! relay decides what a term means, relays differ in whether they take one at
//! all, and a result from one is a claim about a person, not a fact Plaza held.
//! Nothing in this file touches the store, the profile cache or a socket, so the
//! rules that decide who comes first can be asserted without any of them.

const std = @import("std");
const nostr = @import("nostr");

/// The relays a name is put to. NIP-50 is optional, so a general relay answers a
/// search REQ with a notice or with every profile it has; these are ones that
/// index kind:0 and take the `search` field.
///
/// The first two are Jumble's own search relays (`SEARCHABLE_RELAY_URLS` in
/// src/constants.ts:144) and the third is one of Amethyst's (`DefaultSearchRelayList`
/// in AmethystDefaults.kt:59, `Constants.ditto`). Each was asked for a kind:0
/// search and answered with profiles. The rest of Amethyst's list did not
/// answer that request when it was tried, so it is not carried over.
pub const default_relays = [_][]const u8{
    "wss://search.nos.today",
    "wss://search.nostrarchives.com",
    "wss://relay.ditto.pub",
};

/// How many search relays there can ever be, which is what a status table holds.
pub const relays_max = 8;

/// The subscription id a search REQ carries.
pub const sub_id = "plaza-find";

/// What one relay may send back for one term. Amethyst asks for 1000
/// (`searchPeopleByName`, SearchPeopleByName.kt:38-41); a list this app shows a
/// screenful of has no use for that many, and the relay ranks by its own idea of
/// relevance so the first few are the ones it stands behind.
pub const relay_limit: u32 = 30;

/// Longest term that goes to a relay. A name is short; this only stops a pasted
/// paragraph from being sent to three strangers.
pub const term_max = 64;

/// How well a term matches a field, best first.
pub const Quality = enum(u8) {
    /// The whole field.
    exact = 0,
    /// The start of the field.
    prefix = 1,
    /// The start of a word inside it: `jack` in `Jack Dorsey`'s second name,
    /// or the domain half of a NIP-05 address.
    word = 2,
    /// Anywhere else.
    within = 3,
};

/// Whose profile it is, from the reader's side. The order is the ranking.
pub const Tier = enum(u8) {
    /// Somebody the reader follows.
    follows = 0,
    /// Somebody whose contact list names the reader.
    follows_me = 1,
    /// Everyone else Plaza has a profile for.
    seen = 2,
};

/// ASCII-folded position of `needle` in `hay`. Only ASCII is folded, which is
/// what the mention picker does too; a name in another script matches as typed.
pub fn indexOfFold(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    // The first byte is compared before the rest, so most positions cost one
    // comparison and not a call.
    const first = std.ascii.toLower(needle[0]);
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.toLower(hay[i]) != first) continue;
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isBoundary(c: u8) bool {
    return !std.ascii.isAlphanumeric(c) and c < 0x80;
}

/// How `needle` matches `field`, or null when it does not occur in it.
pub fn quality(field: []const u8, needle: []const u8) ?Quality {
    if (needle.len == 0 or field.len == 0) return null;
    if (field.len == needle.len and std.ascii.eqlIgnoreCase(field, needle)) return .exact;
    var best: ?Quality = null;
    var from: usize = 0;
    while (indexOfFold(field[from..], needle)) |rel| {
        const at = from + rel;
        const q: Quality = if (at == 0) .prefix else if (isBoundary(field[at - 1])) .word else .within;
        if (best == null or @intFromEnum(q) < @intFromEnum(best.?)) best = q;
        if (best.? == .prefix) break;
        from = at + 1;
    }
    return best;
}

/// The best quality across a person's name, username and NIP-05 identifier.
pub fn bestQuality(needle: []const u8, fields: []const []const u8) ?Quality {
    var best: ?Quality = null;
    for (fields) |field| {
        const q = quality(field, needle) orelse continue;
        if (best == null or @intFromEnum(q) < @intFromEnum(best.?)) best = q;
    }
    return best;
}

/// One person in the index. The three strings live back to back in the index's
/// `text`, in the order name, username, NIP-05.
pub const Entry = struct {
    pubkey: [32]u8,
    tier: Tier,
    created_at: i64,
    text_off: u32,
    name_len: u16,
    user_len: u16,
    nip05_len: u16,
};

/// A match: which entry, and what put it where it is.
pub const Hit = struct {
    entry: u32,
    tier: Tier,
    quality: Quality,
    /// The display name's length, so `jack` finds `Jack` before `Jack of all trades`.
    name_len: u16,
    created_at: i64,

    /// Whether `a` belongs above `b`: follows, then followers, then everyone,
    /// and inside a tier the closer match, the shorter name, the newer profile.
    fn before(_: void, a: Hit, b: Hit) bool {
        if (a.tier != b.tier) return @intFromEnum(a.tier) < @intFromEnum(b.tier);
        if (a.quality != b.quality) return @intFromEnum(a.quality) < @intFromEnum(b.quality);
        if (a.name_len != b.name_len) return a.name_len < b.name_len;
        if (a.created_at != b.created_at) return a.created_at > b.created_at;
        return a.entry < b.entry;
    }
};

/// Every profile that has something to match on, as one flat buffer. Built once
/// and read for every keystroke, so a query is a pass over contiguous memory and
/// not a parse of every kind:0 on disk.
pub const Index = struct {
    entries: []Entry = &.{},
    text: []u8 = &.{},

    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.text);
        self.* = .{};
    }

    pub fn fields(self: *const Index, e: Entry) [3][]const u8 {
        const off: usize = e.text_off;
        const name = self.text[off .. off + e.name_len];
        const user = self.text[off + e.name_len .. off + e.name_len + e.user_len];
        const nip05 = self.text[off + e.name_len + e.user_len .. off + e.name_len + e.user_len + e.nip05_len];
        return .{ name, user, nip05 };
    }

    /// The best `out.len` people matching `needle`, best first, and how many
    /// there are. Keeps a sorted prefix as it goes rather than collecting every
    /// match and sorting, because a single letter matches most of the index.
    pub fn find(self: *const Index, needle: []const u8, out: []Hit) usize {
        if (needle.len == 0 or out.len == 0) return 0;
        var n: usize = 0;
        for (self.entries, 0..) |e, i| {
            const f = self.fields(e);
            const q = bestQuality(needle, &f) orelse continue;
            const hit: Hit = .{
                .entry = @intCast(i),
                .tier = e.tier,
                .quality = q,
                .name_len = e.name_len,
                .created_at = e.created_at,
            };
            if (n == out.len and !Hit.before({}, hit, out[n - 1])) continue;
            // Insertion into the sorted prefix; the worst falls off the end.
            var at = if (n < out.len) n else out.len - 1;
            while (at > 0 and Hit.before({}, hit, out[at - 1])) : (at -= 1) out[at] = out[at - 1];
            out[at] = hit;
            if (n < out.len) n += 1;
        }
        return n;
    }
};

/// Collects entries for an `Index`.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Builder) void {
        self.entries.deinit(self.gpa);
        self.text.deinit(self.gpa);
    }

    /// Adds a person. A profile with no name, username or address has nothing to
    /// be found by and is left out.
    pub fn add(self: *Builder, pubkey: [32]u8, tier: Tier, created_at: i64, name: []const u8, username: []const u8, nip05: []const u8) !void {
        if (name.len == 0 and username.len == 0 and nip05.len == 0) return;
        const cap = std.math.maxInt(u16);
        const nm = name[0..@min(name.len, cap)];
        const us = username[0..@min(username.len, cap)];
        const nip = nip05[0..@min(nip05.len, cap)];
        const off = self.text.items.len;
        if (off + nm.len + us.len + nip.len > std.math.maxInt(u32)) return;
        try self.text.appendSlice(self.gpa, nm);
        try self.text.appendSlice(self.gpa, us);
        try self.text.appendSlice(self.gpa, nip);
        try self.entries.append(self.gpa, .{
            .pubkey = pubkey,
            .tier = tier,
            .created_at = created_at,
            .text_off = @intCast(off),
            .name_len = @intCast(nm.len),
            .user_len = @intCast(us.len),
            .nip05_len = @intCast(nip.len),
        });
    }

    /// Hands the collected entries over as an `Index` and empties the builder.
    pub fn finish(self: *Builder) !Index {
        const entries = try self.entries.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(entries);
        const text = try self.text.toOwnedSlice(self.gpa);
        return .{ .entries = entries, .text = text };
    }
};

/// The term as it is sent: trimmed, one line, runs of whitespace folded to one
/// space, and no longer than `term_max` bytes (cut on a character boundary).
/// Null when nothing is left.
pub fn cleanTerm(out: *[term_max]u8, raw: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    // A leading `@` is how a handle is written, and no profile has it in its name.
    while (text.len > 0 and text[0] == '@') text = text[1..];
    var n: usize = 0;
    var last_space = false;
    for (text) |c| {
        const space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (space and last_space) continue;
        last_space = space;
        if (n == out.len) {
            // The next byte does not fit. If it continues a character, the
            // character is cut, so the whole of it goes.
            if ((c & 0xc0) == 0x80) {
                while (n > 0 and (out[n - 1] & 0xc0) == 0x80) n -= 1;
                if (n > 0) n -= 1;
            }
            break;
        }
        out[n] = if (space) ' ' else c;
        n += 1;
    }
    const trimmed = std.mem.trim(u8, out[0..n], " ");
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// `["REQ","plaza-find",{"kinds":[0],"search":"<term>","limit":30}]`, the NIP-50
/// request for profiles. Caller frees.
pub fn requestText(gpa: std.mem.Allocator, term: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "[\"REQ\",\"{s}\",{{\"kinds\":[0],\"search\":{f},\"limit\":{d}}}]",
        .{ sub_id, std.json.fmt(term, .{}), relay_limit },
    );
}

/// Sends `text` to `relay` as one websocket text frame.
///
/// `nostr.filter.Filter` has no `search` field yet, so `Relay.subscribe` cannot
/// say what NIP-50 needs it to say. This does the one thing `subscribe` does
/// after it has encoded a request, with the library's own framing and the
/// connection's own write lock, so it is the same bytes on the wire. It goes
/// when the library can carry the field.
pub fn sendText(relay: *nostr.relay.Relay, text: []const u8) !void {
    var mask: [4]u8 = undefined;
    relay.io.randomSecure(&mask) catch return error.RandomFailed;
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(relay.gpa);
    try nostr.websocket.appendClientFrame(&frame, relay.gpa, .text, text, mask);
    // Uncancelable for the library's reason: half a frame is a broken stream.
    relay.conn.write_lock.lockUncancelable(relay.io);
    defer relay.conn.write_lock.unlock(relay.io);
    try relay.conn.stream.writeAll(frame.items);
}

/// Where one search relay stands for the term on screen.
pub const RelayState = enum(u8) {
    /// Not asked: the term has not settled yet, or there is no term.
    idle = 0,
    /// Asked, and nothing back yet.
    asking = 1,
    /// Finished, with a count (zero is an answer: it looked and found no one).
    answered = 2,
    /// The connection did not open or dropped before it answered.
    unreachable_ = 3,
    /// Connected and declined: a CLOSED or a NOTICE in place of results, which
    /// is how a relay without NIP-50 (or one that wants a login) answers.
    declined = 4,
    /// Not asked on purpose: relays are paused.
    paused = 5,
    /// Connected and asked, and never answered before the time allowed ran out.
    silent = 6,
};

/// The kinds of message a search relay sends back, as far as a search cares.
pub const Reply = enum { event, eose, closed, notice, auth, other };

/// Where a search stands after `reply`, with `found` people already in hand:
/// the state it ends on, or null to keep reading.
///
/// An AUTH challenge is not an answer. NIP-42 lets a relay send one at any time,
/// and many send it on connect whether or not the request needs it; one that
/// does need it says so by closing the subscription with `auth-required:`, which
/// lands here as a CLOSED. A NOTICE with nothing found yet is how a relay without
/// NIP-50 refuses; after results have started it is about something else.
pub fn settle(reply: Reply, found: u16) ?RelayState {
    return switch (reply) {
        .event, .auth, .other => null,
        .eose => .answered,
        .closed => if (found > 0) .answered else .declined,
        .notice => if (found == 0) .declined else null,
    };
}

/// A relay's state and result count in one word, so a worker can publish both
/// with a single store and the reader can never see one half of an update. The
/// term generation rides along so a late answer for an old term is ignored.
pub const Status = struct {
    gen: u32,
    state: RelayState,
    count: u16,

    pub fn pack(self: Status) u64 {
        return (@as(u64, self.gen) << 32) | (@as(u64, @intFromEnum(self.state)) << 16) | self.count;
    }

    pub fn unpack(word: u64) Status {
        return .{
            .gen = @intCast(word >> 32),
            .state = std.enums.fromInt(RelayState, @as(u8, @truncate(word >> 16))) orelse .idle,
            .count = @truncate(word),
        };
    }
};

/// What a relay row says, in the reader's words.
pub fn describe(buf: []u8, state: RelayState, count: u16) []const u8 {
    return switch (state) {
        .idle => "not asked yet",
        .asking => "searching",
        .answered => if (count == 0) "found no one" else std.fmt.bufPrint(buf, "{d} {s}", .{ count, if (count == 1) "person" else "people" }) catch "answered",
        .unreachable_ => "could not connect",
        .declined => "does not take searches",
        .paused => "paused",
        .silent => "did not answer",
    };
}

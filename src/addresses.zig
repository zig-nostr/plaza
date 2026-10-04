//! Addressable events: the naddr table, and the fetches that find an article by its address.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const quote_cache = @import("quote_cache.zig");
const article = @import("article.zig");
const view_thread = @import("view_thread.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Model = main.Model;
const RelayHints = main.RelayHints;
const Standing = main.Standing;
const askPool = main.askPool;
const copyBounded = main.copyBounded;
const enterEvent = main.enterEvent;
const indexer_relays = main.indexer_relays;
const isPrivateAddress = main.isPrivateAddress;
const isSafeRelayUrl = main.isSafeRelayUrl;
const noteFrom = main.noteFrom;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const one_shot_sub_prefix = main.one_shot_sub_prefix;
const outbox_relays_per_author = main.outbox_relays_per_author;
const place_relay_cap = main.place_relay_cap;
const plazaIngest = main.plazaIngest;
const plazaIngestFrom = main.plazaIngestFrom;
const poolHasRelay = main.poolHasRelay;
const quote_cache_cap = main.quote_cache_cap;
const relayFetchAllowed = main.relayFetchAllowed;
const relayUrlEql = main.relayUrlEql;
const relay_list_kind = main.relay_list_kind;
const releaseOneShot = main.releaseOneShot;
const selectWriteRelays = main.selectWriteRelays;
const setToast = main.setToast;
const standingNow = main.standingNow;
const swapThreadRoot = main.swapThreadRoot;
const watchOneShot = main.watchOneShot;

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

/// Whether a kind is one an address may name and still open as an article: the
/// published kind, and its draft, which opens as a refusal rather than a page.
fn isArticleKind(kind: u32) bool {
    return kind == article.kind or kind == article.draft_kind;
}

/// The longest `d` tag an address may carry here. A slug is a few words; past
/// this the address is treated as one Plaza cannot hold rather than cut short,
/// because a cut identifier names a different event.
const address_ident_cap = 128;

/// A decoded `naddr` for an article, owned by value so it can ride into a
/// thread and out of the arena the decode was made in.
pub const Address = struct {
    kind: u16,
    pubkey: [32]u8,
    ident_buf: [address_ident_cap]u8 = @splat(0),
    ident_len: u8 = 0,

    pub fn make(kind: u32, pubkey: [32]u8, identifier: []const u8) ?Address {
        if (!isArticleKind(kind)) return null;
        if (identifier.len > address_ident_cap) return null;
        var a = Address{ .kind = @intCast(kind), .pubkey = pubkey };
        @memcpy(a.ident_buf[0..identifier.len], identifier);
        a.ident_len = @intCast(identifier.len);
        return a;
    }

    fn ident(self: *const Address) []const u8 {
        return self.ident_buf[0..self.ident_len];
    }

    /// A 32-byte stand-in for the event id, so a quote card keyed by id can be
    /// keyed by coordinate without a second cache beside it. A hash of the
    /// coordinate, so it cannot collide with a real id in practice.
    pub fn key(self: *const Address) [32]u8 {
        var buf: [16 + 64 + address_ident_cap]u8 = undefined;
        const hex = std.fmt.bytesToHex(self.pubkey, .lower);
        const text = std.fmt.bufPrint(&buf, "{d}:{s}:{s}", .{ self.kind, &hex, self.ident() }) catch unreachable;
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &out, .{});
        return out;
    }
};

/// The filter that asks for an address, with the arrays it points into, so a
/// caller keeps one value alive for as long as the filter is used.
///
/// An empty identifier sends no `d` constraint, as Jumble does
/// (src/services/client.service.ts:989-991): some relays refuse an empty tag
/// value, and every copy returned is checked against the identifier here anyway.
pub const AddressQuery = struct {
    authors: [1][32]u8,
    kinds: [1]u16,
    values: [1][]const u8,
    tags: [1]nostr.filter.TagFilter,
    has_tag: bool,

    /// In place, because the filter's slices point into this value: moving it
    /// afterwards would leave them pointing at the old copy.
    fn init(self: *AddressQuery, addr: *const Address) void {
        self.authors = .{addr.pubkey};
        self.kinds = .{addr.kind};
        self.values = .{addr.ident()};
        self.tags = .{.{ .letter = 'd', .values = &self.values }};
        self.has_tag = addr.ident_len > 0;
    }

    fn filter(self: *const AddressQuery, limit: u32) nostr.filter.Filter {
        return .{
            .authors = &self.authors,
            .kinds = &self.kinds,
            .tags = if (self.has_tag) &self.tags else null,
            .limit = limit,
        };
    }
};

/// The first `d` tag of an event, or empty when it has none.
fn dTagOf(ev: nostr.event.Event) []const u8 {
    for (ev.tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "d")) return tag[1];
    }
    return "";
}

/// The id of the newest stored copy of `addr`: the latest `created_at`, and the
/// lower id on a tie (NIP-01). The store keeps one copy per coordinate already,
/// so this is the second guard rather than the first.
pub fn newestAddressId(store: *nostr.store.Store, addr: *const Address) ?[32]u8 {
    var q: AddressQuery = undefined;
    q.init(addr);
    var result = store.query(std.heap.page_allocator, q.filter(32)) catch return null;
    defer result.deinit();
    var best: ?nostr.event.Event = null;
    for (result.events) |ev| {
        if (ev.kind != addr.kind or !std.mem.eql(u8, dTagOf(ev), addr.ident())) continue;
        if (best) |b| {
            if (ev.created_at < b.created_at) continue;
            if (ev.created_at == b.created_at and std.mem.order(u8, &ev.id, &b.id) != .lt) continue;
        }
        best = ev;
    }
    return if (best) |b| b.id else null;
}
/// The addresses notes on screen have named, by their stand-in key.
///
/// Kept out of the quote cache on purpose: `findQuoteRef` runs while a quote is
/// being filled, and creating a cache entry there can evict the very entry being
/// filled. Registering here touches nothing else, and the cache entry is made
/// later by the ordinary `wantQuote`, which finds the address by its key.
pub const AddressSlot = struct {
    used: bool = false,
    key: [32]u8 = @splat(0),
    addr: Address = .{ .kind = 0, .pubkey = @splat(0) },
    /// Where the address said the event lives. The first address to name any
    /// keeps them, the same rule `wantQuoteHinted` follows.
    hints: RelayHints = .{},
    /// Whether the author's own relays have been asked on this entry's behalf.
    /// Once: it dials relays the reader does not otherwise talk to.
    outbox_asked: bool = false,
    last_used: u64 = 0,
};
pub const address_table_cap = quote_cache_cap * 2;
pub var g_addresses = [_]AddressSlot{.{}} ** address_table_cap;
pub var g_address_clock: u64 = 0;

/// Records an address a note named and returns its stand-in key.
pub fn registerAddress(addr: Address, hints: []const []const u8) [32]u8 {
    const k = addr.key();
    g_address_clock += 1;
    for (&g_addresses) |*s| {
        if (s.used and std.mem.eql(u8, &s.key, &k)) {
            s.last_used = g_address_clock;
            if (s.hints.isEmpty()) s.hints.fill(hints);
            return k;
        }
    }
    // Never a slot a quote card is keyed by. The card holds only the stand-in
    // key, which cannot be turned back into the address, so evicting its slot
    // left a card asking the relays for an id that does not exist and a press
    // that opened nothing. The table is twice the quote cache, so there is
    // always a slot no card holds.
    var victim: ?*AddressSlot = null;
    for (&g_addresses) |*s| {
        if (!s.used) {
            victim = s;
            break;
        }
        if (quoteKeyed(s.key)) continue;
        if (victim == null or s.last_used < victim.?.last_used) victim = s;
    }
    const v = victim orelse &g_addresses[0];
    v.* = .{ .used = true, .key = k, .addr = addr, .last_used = g_address_clock };
    v.hints.fill(hints);
    return k;
}

/// Whether a quote cache entry is keyed by `key`.
fn quoteKeyed(key: [32]u8) bool {
    for (&quote_cache.g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &key)) return true;
    }
    return false;
}

pub fn addressFor(key: [32]u8) ?*AddressSlot {
    for (&g_addresses) |*s| {
        if (s.used and std.mem.eql(u8, &s.key, &key)) return s;
    }
    return null;
}
/// The most hinted relays an address dials.
const address_hint_dials = 3;

/// Relays already dialled for an address by hint, so the author's write relays
/// do not open a second socket to the same host.
const DialedHints = struct {
    buf: [address_hint_dials][place_relay_cap]u8 = @splat(@splat(0)),
    len: [address_hint_dials]u8 = @splat(0),
    n: u8 = 0,

    fn has(self: *const DialedHints, url: []const u8) bool {
        for (0..self.n) |i| {
            if (relayUrlEql(self.buf[i][0..self.len[i]], url)) return true;
        }
        return false;
    }
};

/// Asks for the newest copy of an address everywhere it might be: the pool,
/// then the relays the address named, then the author's own write relays.
///
/// The pool is asked for the author's relay list in the same message, so the
/// third leg usually has it by the time it looks. Everything that comes back
/// goes to the store, which keeps the newest, and nobody waits on this: the
/// caller watches the store.
fn askAddress(addr: Address, hints: []const []const u8) void {
    _ = askAddressesOnPool(one_shot_sub_prefix ++ "address", &.{addr});
    dialAddress(addr, hints);
}

/// The most addresses one pool message carries. A REQ under an id a relay
/// already holds replaces it (NIP-01), so the quote cards due in a round go out
/// as ONE message with a filter each; asked one message at a time under one id,
/// each would cancel the one before it. Four, because a relay may refuse a REQ
/// with many filters, and each address is one filter here plus a share of one.
pub const address_pool_batch = 4;

/// Fills `out` with the filters that ask for `addrs`: one per address, and one
/// for their authors' relay lists. `queries` and `authors` hold what the filters
/// point into, so they must outlive the filters. Returns how many were written.
pub fn addressPoolFilters(
    addrs: []const Address,
    queries: *[address_pool_batch]AddressQuery,
    authors: *[address_pool_batch][32]u8,
    out: *[address_pool_batch + 1]nostr.filter.Filter,
) usize {
    const n: usize = @min(addrs.len, address_pool_batch);
    var authors_n: usize = 0;
    for (addrs[0..n], 0..) |*a, i| {
        queries[i].init(a);
        out[i] = queries[i].filter(8);
        var seen = false;
        for (authors[0..authors_n]) |had| {
            if (std.mem.eql(u8, &had, &a.pubkey)) seen = true;
        }
        if (seen) continue;
        authors[authors_n] = a.pubkey;
        authors_n += 1;
    }
    if (n == 0) return 0;
    const list_kinds = struct {
        const k = [_]u16{relay_list_kind};
    };
    out[n] = .{ .authors = authors[0..authors_n], .kinds = &list_kinds.k, .limit = @intCast(authors_n) };
    return n + 1;
}
/// Asks the pool for `addrs`, at most `address_pool_batch` of them, in one
/// message under `sub_id`.
pub fn askAddressesOnPool(sub_id: []const u8, addrs: []const Address) usize {
    var queries: [address_pool_batch]AddressQuery = undefined;
    var authors: [address_pool_batch][32]u8 = undefined;
    var filters: [address_pool_batch + 1]nostr.filter.Filter = undefined;
    const n = addressPoolFilters(addrs, &queries, &authors, &filters);
    if (n == 0) return 0;
    return askPool(sub_id, filters[0..n]);
}

/// Whether a relay that a STRANGER named may be dialled for an address: one of
/// the address's own hints, or one from its author's relay list.
///
/// `isSafeRelayUrl` keeps the string sane; this keeps the destination public.
/// Both lists come off the wire, and dialling is unattended (a quote card does
/// it because a note scrolled into view), so without it a note could make every
/// reader's machine knock on its own loopback, its LAN, or a name only its
/// resolver would ever see. The same lines `previewableUrl` draws for a link,
/// and an onion address besides: without Tor, asking for one only hands the
/// name to the resolver.
pub fn isPublicRelayUrl(url: []const u8) bool {
    if (!isSafeRelayUrl(url)) return false;
    const rest = url["wss://".len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.indexOfScalar(u8, host, '@') != null) return false;
    // A bracketed IPv6 literal is never a public relay's name.
    if (host.len == 0 or host[0] == '[') return false;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    host = std.mem.trimEnd(u8, host, ".");
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    }
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    if (dot == 0 or dot + 1 >= host.len) return false;
    const suffixes = [_][]const u8{ ".local", ".internal", ".localhost", ".onion", ".lan", ".home.arpa" };
    for (suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(host, suffix)) return false;
    }
    // A name ends in letters. A last label with a digit in it is an address, in
    // one of the forms a resolver reads loosely (`127.1`, `0x7f.1`), so only the
    // plain four-number form is taken, and only outside the private ranges.
    for (host[dot + 1 ..]) |c| {
        if (std.ascii.isDigit(c)) return isPrivateAddress(host) == false and isDottedQuad(host);
    }
    return true;
}

/// Four decimal numbers, each 0 to 255, and nothing else.
fn isDottedQuad(host: []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        const v = std.fmt.parseInt(u16, part, 10) catch return false;
        if (v > 255) return false;
        n += 1;
    }
    return n == 4;
}

/// Dials the relays an address named, and then its author's write relays, on
/// throwaway sockets. Only relays `isPublicRelayUrl` accepts.
pub fn dialAddress(addr: Address, hints: []const []const u8) void {
    if (!relayFetchAllowed()) return;
    var dialled = DialedHints{};
    for (hints) |h| {
        if (dialled.n >= address_hint_dials) break;
        if (!isPublicRelayUrl(h)) continue;
        if (dialled.has(h)) continue;
        const len = copyBounded(&dialled.buf[dialled.n], h);
        dialled.len[dialled.n] = @intCast(len);
        dialled.n += 1;
        if (!relayFetchAllowed()) break;
        const t = std.Thread.spawn(.{}, askAddressAt, .{ dialled.buf[dialled.n - 1], len, addr }) catch continue;
        t.detach();
    }
    const t = std.Thread.spawn(.{}, askAddressOutbox, .{ addr, dialled }) catch return;
    t.detach();
}

/// Sends the address query down one open connection and ingests what comes
/// back, until the relay says it has nothing more. `url` is the relay's, so an
/// article that arrives remembers where it can be found, like any other note.
fn askAddressOn(gpa: std.mem.Allocator, relay: *nostr.relay.Relay, url: []const u8, signer: nostr.keys.Signer, addr: *const Address) void {
    var q: AddressQuery = undefined;
    q.init(addr);
    const filters = [_]nostr.filter.Filter{q.filter(8)};
    relay.subscribe(one_shot_sub_prefix ++ "address", &filters) catch return;
    var seen: usize = 0;
    while (seen < 64) : (seen += 1) {
        var msg = (relay.receive() catch break) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| _ = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch {},
            .eose, .closed => break,
            else => {},
        }
    }
}

/// One relay an address named, on a throwaway socket, like `askPlaceAt` and for
/// the same reason: the pool holds the reader's relays, and a hint names one
/// that by definition is not among them.
fn askAddressAt(url_buf: [place_relay_cap]u8, url_len: usize, addr: Address) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var relay = nostr.relay.dial(gpa, io, url_buf[0..url_len]) catch return;
    defer relay.deinit();
    // Not run unwatched, for `askQuoteAt`'s reason: the pool is asked for the
    // same address, so a socket with no deadline buys nothing and can park this
    // thread for good.
    const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
    defer releaseOneShot(watched);
    askAddressOn(gpa, relay, url_buf[0..url_len], signer, &addr);
}

/// The relays an author writes to, from the relay list the store holds, copied
/// out of the parse. Empty when the store has no list for them.
pub fn storedWriteRelays(
    gpa: std.mem.Allocator,
    pubkey: [32]u8,
    urls: *[outbox_relays_per_author][96]u8,
    lens: *[outbox_relays_per_author]u8,
) usize {
    const store = main.g_store orelse return 0;
    const authors = [_][32]u8{pubkey};
    const kinds = [_]u16{relay_list_kind};
    var result = store.query(gpa, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return 0;
    defer result.deinit();
    if (result.events.len == 0) return 0;
    var parsed = nostr.nip65.parseRelayList(gpa, result.events[0]) catch return 0;
    defer parsed.deinit();
    var raw: [16][]const u8 = undefined;
    var raw_n: usize = 0;
    for (parsed.list.entries) |entry| {
        if (!entry.write or raw_n == raw.len) continue;
        raw[raw_n] = entry.url;
        raw_n += 1;
    }
    var chosen: [outbox_relays_per_author][]const u8 = undefined;
    const n = selectWriteRelays(raw[0..raw_n], &chosen);
    for (chosen[0..n], 0..) |url, i| {
        @memcpy(urls[i][0..url.len], url);
        lens[i] = @intCast(url.len);
    }
    return n;
}
/// Asks the indexers for one author's relay list, stopping at the first that
/// has it. For an author the pool has never been asked about: an address from a
/// stranger is exactly the case where the list is not on this machine.
fn fetchRelayListFromIndexers(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, pubkey: [32]u8) void {
    const authors = [_][32]u8{pubkey};
    const kinds = [_]u16{relay_list_kind};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    for (indexer_relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
        defer releaseOneShot(watched);
        relay.subscribe(one_shot_sub_prefix ++ "address-relays", &filters) catch continue;
        var got = false;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    _ = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch {};
                    got = true;
                },
                .eose, .closed => break,
                else => {},
            }
        }
        if (got) return;
    }
}

/// The last leg of `dialAddress`: the author's own write relays, which is where
/// an article they published most likely is.
fn askAddressOutbox(addr: Address, skip: DialedHints) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var urls: [outbox_relays_per_author][96]u8 = undefined;
    var lens: [outbox_relays_per_author]u8 = undefined;
    var n = storedWriteRelays(gpa, addr.pubkey, &urls, &lens);
    if (n == 0) {
        fetchRelayListFromIndexers(gpa, io, signer, addr.pubkey);
        n = storedWriteRelays(gpa, addr.pubkey, &urls, &lens);
    }
    for (0..n) |i| {
        const url = urls[i][0..lens[i]];
        // Already asked: the pool holds it, or the address named it.
        if (poolHasRelay(url) or skip.has(url)) continue;
        // A stranger's relay list, so the same gate as the address's own hints.
        if (!isPublicRelayUrl(url)) continue;
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
        defer releaseOneShot(watched);
        askAddressOn(gpa, relay, url, signer, &addr);
    }
}

/// The article the reader asked for by address, while it is being fetched, and
/// afterwards while a newer copy may still arrive.
///
/// The same parts the note fetch has (`g_event_want`): what was asked for, a
/// tick that applies it when it lands, and a bounded give-up. The one addition
/// is the second phase. A replaceable event held locally is last session's, and
/// the author may have edited it since, so once a copy is on screen the window
/// stays open for a newer one and swaps it in.
pub var g_address_want: ?struct {
    addr: Address,
    /// Ticks the window has been open, so it can give up.
    waited: u16 = 0,
    /// Where the reader was standing, so a walk away closes the window.
    from: Standing,
    /// Set once a copy is on screen: its id and when it was written.
    shown: bool = false,
    shown_id: [32]u8 = @splat(0),
    shown_at: i64 = 0,
} = null;

/// Whether the head of the article in front (its title and byline) was on
/// screen in the last frame drawn: `articlePanel` marks the root visible only
/// while row 0 is in the window.
fn articleHeadOnScreen(model: *const Model) bool {
    const set = &view_thread.g_level_visible[@min(model.thread_stack_len, view_thread.g_level_visible.len - 1)];
    for (set.notes[0..set.note_count]) |id| {
        if (id == model.thread_root.id) return true;
    }
    return false;
}

/// How many ticks an address fetch may go unanswered. The tick is a second.
const address_fetch_ticks = 15;

/// Opens the article an address names: the newest copy in the store at once if
/// there is one, and the relays asked either way so a newer copy can follow.
pub fn openAddressedArticle(model: *Model, addr: Address, hints: []const []const u8) void {
    if (main.g_store) |store| {
        if (newestAddressId(store, &addr)) |id| {
            if (store.getEvent(std.heap.page_allocator, id) catch null) |found| {
                var se = found;
                defer se.deinit();
                const created_at = se.event.created_at;
                enterEvent(model, se.event);
                // A draft opens nothing and says so, and there is nothing to
                // wait for: a refusal does not get better with a newer copy.
                if (se.event.kind == article.draft_kind) return;
                g_address_want = .{
                    .addr = addr,
                    .from = standingNow(model),
                    .shown = true,
                    .shown_id = id,
                    .shown_at = created_at,
                };
                askAddress(addr, hints);
                return;
            }
        }
    }
    // Not held. Say so, ask, and WAIT for it: asking alone leaves nobody
    // standing at the door when it arrives (see `openEvent`).
    askAddress(addr, hints);
    g_address_want = .{ .addr = addr, .from = standingNow(model) };
    setToast(model, "Fetching that article");
}

/// One tick of the address fetch, beside `refreshEventFetch`.
pub fn refreshAddressFetch(model: *Model) void {
    const want = g_address_want orelse return;
    // Gone somewhere else since asking. Closed rather than dragging the reader
    // back, the same rule the note fetch follows.
    if (!want.from.eql(standingNow(model))) {
        g_address_want = null;
        return;
    }
    const store = main.g_store orelse return;
    const newest = newestAddressId(store, &want.addr);

    if (!want.shown) {
        if (newest) |id| {
            if (store.getEvent(std.heap.page_allocator, id) catch null) |found| {
                var se = found;
                defer se.deinit();
                const waited = want.waited;
                const created_at = se.event.created_at;
                const draft = se.event.kind == article.draft_kind;
                // Closed BEFORE the navigation, for the reason `refreshEventFetch`
                // gives: `enterEvent` moves the reader, and an open window would
                // read its own arrival as a walk away.
                g_address_want = null;
                enterEvent(model, se.event);
                if (!draft) {
                    g_address_want = .{
                        .addr = want.addr,
                        .waited = waited,
                        .from = standingNow(model),
                        .shown = true,
                        .shown_id = id,
                        .shown_at = created_at,
                    };
                }
                return;
            }
        }
    } else if (newest) |id| {
        if (!std.mem.eql(u8, &id, &want.shown_id)) {
            if (store.getEvent(std.heap.page_allocator, id) catch null) |found| {
                var se = found;
                defer se.deinit();
                // Only while the reader is still at the top of it. The level is
                // keyed by the root, so a swap opens the new copy at its first
                // line, and pulling somebody halfway down an article back up to
                // its title is worse than letting them finish the copy they have.
                if (se.event.created_at > want.shown_at and articleHeadOnScreen(model)) {
                    swapThreadRoot(model, noteFrom(se.event, nowSeconds()));
                    g_address_want.?.shown_id = id;
                    g_address_want.?.shown_at = se.event.created_at;
                    g_address_want.?.from = standingNow(model);
                }
            }
        }
    }

    g_address_want.?.waited +|= 1;
    if (g_address_want.?.waited > address_fetch_ticks) {
        g_address_want = null;
        if (!want.shown) setToast(model, "That article did not turn up.");
    }
}

pub fn newestAddressIdForTest(store: *nostr.store.Store, kind: u16, pubkey: [32]u8, identifier: []const u8) ?[32]u8 {
    const addr = Address.make(kind, pubkey, identifier) orelse return null;
    return newestAddressId(store, &addr);
}

/// Empties the table. For tests, which share the process globals.
pub fn resetAddressesForTest() void {
    g_addresses = [_]AddressSlot{.{}} ** address_table_cap;
    g_address_clock = 0;
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
    return g_address_want != null;
}

pub fn forgetAddressFetchForTest() void {
    g_address_want = null;
}
/// Whether an address's relays have been dialled (or claimed for dialling).
pub fn addressDialledForTest(key: [32]u8) bool {
    const slot = addressFor(key) orelse return false;
    return slot.outbox_asked;
}

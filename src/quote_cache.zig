//! Quoted notes: the cache and the fetches that fill it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const profile_cache = @import("profile_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Address = main.Address;
const AddressSlot = main.AddressSlot;
const Note = main.Note;
const RelayHints = main.RelayHints;
const addressFor = main.addressFor;
const address_pool_batch = main.address_pool_batch;
const askAddressesOnPool = main.askAddressesOnPool;
const askPool = main.askPool;
const classifyMedia = main.classifyMedia;
const contentWarningOf = main.contentWarningOf;
const copyBounded = main.copyBounded;
const dialAddress = main.dialAddress;
const feedKeyOf = main.feedKeyOf;
const findQuoteRef = main.findQuoteRef;
const firstImageUrl = main.firstImageUrl;
const imetaFor = main.imetaFor;
const isPublicRelayUrl = main.isPublicRelayUrl;
const kindRender = main.kindRender;
const networkAllowed = main.networkAllowed;
const newestAddressId = main.newestAddressId;
const note_content_cap = main.note_content_cap;
const one_shot_budget_ms = main.one_shot_budget_ms;
const one_shot_sub_prefix = main.one_shot_sub_prefix;
const place_relay_cap = main.place_relay_cap;
const plazaIngestFrom = main.plazaIngestFrom;
const relayFetchAllowed = main.relayFetchAllowed;
const releaseOneShot = main.releaseOneShot;
const renderContent = main.renderContent;
const titleOf = main.titleOf;
const urlHost = main.urlHost;
const utf8SafeLen = main.utf8SafeLen;
const wantProfile = main.wantProfile;
const warningCovered = main.warningCovered;
const warning_reason_bytes = main.warning_reason_bytes;
const watchOneShot = main.watchOneShot;

// ------------------------------------------------------------------ quotes
//
// A note can quote another event (NIP-27 `nostr:nevent`/`note`). The quoted
// event's id is decoded once at parse time (Note.quote); this cache holds the
// resolved quoted note (author + a truncated body) keyed by that id, filled from
// the store as it grows and fetched from the pool when absent, mirroring the
// profile cache. The render side reads it to draw an embedded quote card.
pub const quote_cache_cap = 64;
/// After this many tries with no answer, a quote stops being asked for EVERY
/// round and starts backing off. It never stops being asked for.
///
/// It used to stop for good. Three unanswered tries and the entry was marked
/// missing, and nothing re-armed it: not a later round, not a reconnect, not the
/// reader opening the thread again. Three tries is nothing, and they can all
/// land while the pool is still dialling, so a note sitting on the reader's own
/// relays could be written off in the first seconds of the session and read
/// "not on your relays yet" for the rest of it. That is what happened to the
/// ancestor above a thread that every other client showed.
const quote_backoff_after = 3;
/// The longest a quote waits between tries, in profile-timer rounds (2s each),
/// so a note nobody has is asked for about once a minute rather than never or
/// constantly.
const quote_backoff_max_rounds: u32 = 30;
const quote_fetch_batch = 16;
/// Enough of a quoted note to fill the four lines 11f gives it (about 75
/// characters a line at the quote's register), so the clamp decides where the
/// text ends rather than the cache. 64 entries, so the whole table is ~20 KiB.
const quote_text_cap = 320;
/// The longest picture address a quote keeps: a feed picture's, so the two
/// surfaces agree about which addresses are pictures at all.
const quote_image_url_cap = 192;
/// Where a cached quote is in its life: asked for, in flight, in hand, or asked
/// for enough times that no relay has it.
pub const QuoteState = enum { idle, fetching, loaded, missing };

pub const QuoteEntry = struct {
    used: bool = false,
    id: [32]u8 = [_]u8{0} ** 32,
    state: QuoteState = .idle,
    attempts: u8 = 0,
    /// The round this entry may be asked for again. Zero means "now".
    next_round: u64 = 0,
    requested: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    /// The kind of the event this entry holds.
    ///
    /// The card is reached without anybody asking for it: a note quoting a
    /// long-form article rendered the article's raw markdown into the snippet,
    /// and a note quoting an event whose content is empty by design drew a card
    /// with a name and nothing under it, which reads as a fault rather than as
    /// a thing the card cannot draw.
    kind: u16 = 0,
    created_at: i64 = 0,
    text_buf: [quote_text_cap]u8 = [_]u8{0} ** quote_text_cap,
    text_len: u16 = 0,
    /// The names generation `text_buf` was rendered at.
    ///
    /// The snippet has mentions in it, and a mention is baked into text as
    /// `@Name` (or as an abbreviated npub when no name is known yet). The feed's
    /// note bodies re-parse when a display name lands, because the generation
    /// moving invalidates every card; this cache had no such stamp, so a snippet
    /// rendered before its mentioned author's kind:0 arrived kept the npub for
    /// as long as the entry lived. That is the raw `@npub1sg6plzp…uf63m` in a
    /// reply context line while the same person's name shows correctly two rows
    /// down.
    names_generation: u64 = 0,
    /// The HOST of the picture the quoted note carries, when it carries one.
    ///
    /// The URL itself is deliberately cut out of `text_buf` (a raw image URL is
    /// not something to read), and nothing recorded that it had ever been there:
    /// a quoted note whose whole content is one picture came out of this cache
    /// with an empty body and drew a card with a name, a time and nothing else,
    /// which reads as a rendering fault rather than as a picture.
    ///
    /// Still what the card says when it is not drawing the picture itself:
    /// previews off, a URL too long to keep, or a file the note declares is not
    /// an image.
    image_host_buf: [48]u8 = [_]u8{0} ** 48,
    image_host_len: u8 = 0,
    /// The quoted note's author asked for it to be covered (NIP-36), and why.
    /// The words stay in `text_buf` so uncovering is instant, and nothing reads
    /// them while `quoteCovered` is true: a quote card, a reply context line and
    /// a quoting pill are three more places a note's words are drawn.
    warned: bool = false,
    warning_buf: [warning_reason_bytes]u8 = [_]u8{0} ** warning_reason_bytes,
    warning_len: u8 = 0,
    /// Where that picture is, when the card may fetch and draw it. Empty when
    /// the note says the file is not an image or the address is longer than a
    /// feed picture's (`NoteImage` leaves those in the body as links too).
    ///
    /// The picture is not held here. It lives in a media slot under
    /// `quoteMediaKey`, the same table and the same pool of registry ids a feed
    /// picture uses, so the card claims one only while it is on screen and the
    /// pool takes it back the way it takes back a row's.
    image_url_buf: [quote_image_url_cap]u8 = [_]u8{0} ** quote_image_url_cap,
    image_url_len: u8 = 0,
    /// Height over width and blurhash from the quoted note's own `imeta`, so the
    /// card reserves the right box and shows the right colours before a byte has
    /// arrived. Zero and empty when the note says nothing.
    image_aspect: f32 = 0,
    image_blur_buf: [40]u8 = [_]u8{0} ** 40,
    image_blur_len: u8 = 0,
    /// What the quoted note itself quotes, if anything. Depth stops here (11g):
    /// one hop is a pill saying where it goes, never a third nested body. The
    /// reference is decoded from the event's own content at fill time, because
    /// the stored text is rendered and clamped and can drop the token entirely.
    quote_of: [32]u8 = [_]u8{0} ** 32,
    has_quote_of: bool = false,
    /// Where the address that named this event said it lives.
    ///
    /// Without these the fetch only ever asks relays the reader already reads,
    /// and `quotingPillLabel` then settles on "Quotes a note no relay has",
    /// which is true about this reader's relays and false about the note.
    hints: RelayHints = .{},
    last_used: u64 = 0,

    pub fn imageUrl(self: *const QuoteEntry) []const u8 {
        return self.image_url_buf[0..self.image_url_len];
    }
    pub fn imageBlurhash(self: *const QuoteEntry) []const u8 {
        return self.image_blur_buf[0..self.image_blur_len];
    }
};
pub var g_quotes = [_]QuoteEntry{.{}} ** quote_cache_cap;
pub var g_quote_clock: u64 = 0;
/// Ticks once per profile-timer round (2s). The backoff is counted in these.
pub var g_quote_round: u64 = 0;
/// The pool as the last tick saw it, so a change in it can be noticed.
pub var g_last_live_relays: usize = std.math.maxInt(usize);
pub var g_last_relay_count: usize = std.math.maxInt(usize);
/// Records that a quoted event `id` needs resolving, deduping and (when full)
/// evicting the least-recently-drawn entry that is not mid-fetch.
pub fn wantQuote(id: [32]u8) void {
    wantQuoteHinted(id, &.{});
}

/// Wants a quoted event, and remembers where the address that named it said it
/// lives, so the fetch can reach past the reader's own relays.
///
/// An entry that already has hints keeps them. The first address to name a
/// relay is no worse than the second, and overwriting would clear `tried` and
/// dial the same speculative socket again every time the note is re-parsed.
pub fn wantQuoteHinted(id: [32]u8, hints: []const []const u8) void {
    for (&g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) {
            if (q.hints.isEmpty()) q.hints.fill(hints);
            return;
        }
    }
    for (&g_quotes) |*q| {
        if (!q.used) {
            q.* = .{ .used = true, .id = id };
            q.hints.fill(hints);
            return;
        }
    }
    var victim: ?*QuoteEntry = null;
    for (&g_quotes) |*q| {
        if (q.state == .fetching) continue;
        if (victim == null or q.last_used < victim.?.last_used) victim = q;
    }
    // Every slot mid-fetch: still record the newcomer over the overall LRU. The
    // evicted entry's fetch merely ingests into the store, so nothing is lost by
    // dropping its slot, and the new quote is never silently forgotten.
    if (victim == null) {
        for (&g_quotes) |*q| {
            if (victim == null or q.last_used < victim.?.last_used) victim = q;
        }
    }
    if (victim) |v| {
        v.* = .{ .used = true, .id = id };
        v.hints.fill(hints);
    }
}

/// The cache entry for a quoted event `id` (marking it drawn this frame so the
/// LRU keeps it), or null when it is not cached.
pub fn quoteFor(id: [32]u8) ?*QuoteEntry {
    for (&g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) {
            g_quote_clock += 1;
            q.last_used = g_quote_clock;
            return q;
        }
    }
    return null;
}

/// Whether a cached quote is covered right now. Keyed by the quoted event's own
/// id, which is the id a feed row of that same note carries, so uncovering a note
/// anywhere uncovers it everywhere it is drawn: it is one note.
pub fn quoteCovered(q: *const QuoteEntry) bool {
    return warningCovered(q.warned, feedKeyOf(q.id));
}

/// The words a quote may show, none while it is covered.
pub fn quoteShownText(q: *const QuoteEntry) []const u8 {
    if (quoteCovered(q)) return "";
    return q.text_buf[0..q.text_len];
}

/// Fills any unresolved quote from the store (it grew, so the fetch may have
/// landed): copies the quoted author and a truncated body, and asks for the
/// author's name. Gives up (marks missing) once every relay has been tried.
pub fn refreshQuotes(store: *nostr.store.Store) void {
    // The nested references this pass finds, asked for once it is over (see the
    // note where they are collected).
    var nested: [quote_cache_cap][32]u8 = undefined;
    var nested_count: usize = 0;
    for (&g_quotes) |*q| {
        // `.missing` is looked at again: it is what the row SAYS while the
        // backoff keeps asking, and a copy that lands afterwards has to be able
        // to replace it.
        if (!q.used) continue;
        // A loaded entry is re-rendered ONLY when a name has landed since it was
        // baked, which is the one thing that can change what its text should
        // say. Otherwise this stays what it was: a pass over the unresolved.
        if (q.state == .loaded and q.names_generation == profile_cache.g_names_generation) continue;
        // An address resolves to whichever copy is newest right now, an id to
        // itself.
        const target = if (addressFor(q.id)) |slot|
            (newestAddressId(store, &slot.addr) orelse q.id)
        else
            q.id;
        var se = (store.getEvent(std.heap.page_allocator, target) catch continue) orelse {
            // `.missing` is what the ROW says, not a decision to stop looking:
            // the card reads "not on your relays yet", which is true, and the
            // backoff keeps asking in case it stops being true.
            if (q.attempts >= quote_backoff_after) q.state = .missing;
            continue;
        };
        defer se.deinit();
        q.pubkey = se.event.pubkey;
        q.kind = se.event.kind;
        q.created_at = se.event.created_at;
        q.warned = false;
        q.warning_len = 0;
        if (contentWarningOf(se.event)) |reason| {
            q.warned = true;
            @memcpy(q.warning_buf[0..reason.len], reason);
            q.warning_len = @intCast(reason.len);
        }
        var tmp: [note_content_cap]u8 = undefined;
        const omit = firstImageUrl(se.event.content) orelse "";
        // What the card needs to draw the picture itself, from the same
        // places a feed row reads them: the note's `imeta` for its shape and
        // colours, `classifyMedia` for whether the file is a picture at all,
        // and the same length ceiling a feed picture has.
        const meta = imetaFor(se.event.tags, omit);
        q.image_url_len = 0;
        q.image_aspect = 0;
        q.image_blur_len = 0;
        if (omit.len > 0 and omit.len <= q.image_url_buf.len and classifyMedia(omit, meta.mime) == .image) {
            @memcpy(q.image_url_buf[0..omit.len], omit);
            q.image_url_len = @intCast(omit.len);
            q.image_aspect = meta.aspect();
            const b = @min(meta.blurhash.len, q.image_blur_buf.len);
            @memcpy(q.image_blur_buf[0..b], meta.blurhash[0..b]);
            q.image_blur_len = @intCast(b);
        }
        const host = urlHost(omit);
        const host_len = @min(host.len, q.image_host_buf.len);
        @memcpy(q.image_host_buf[0..host_len], host[0..host_len]);
        q.image_host_len = @intCast(host_len);
        // The same decision `noteFrom` makes, made here too, because this cache
        // fills the card and `noteFrom` fills every other surface and the two
        // must not disagree about one event.
        switch (kindRender(se.event.kind)) {
            .note, .media => {
                const wrote = renderContent(&tmp, se.event.content, omit);
                const keep = utf8SafeLen(tmp[0..wrote], q.text_buf.len);
                @memcpy(q.text_buf[0..keep], tmp[0..keep]);
                q.text_len = @intCast(keep);
            },
            .article => {
                if (titleOf(se.event)) |title| {
                    const keep = @min(title.len, q.text_buf.len);
                    @memcpy(q.text_buf[0..keep], title[0..keep]);
                    q.text_len = @intCast(keep);
                }
            },
            // Nothing to bake. The card draws the chip instead, which says
            // what this is rather than showing a slab of something nobody can
            // read as a sentence.
            .unsupported => q.text_len = 0,
        }
        // Decoded from the ORIGINAL content, not the stored text: the stored
        // text is rendered and capped, so the token can be gone from it.
        var probe = Note{};
        const probe_len = @min(se.event.content.len, probe.content_buf.len);
        @memcpy(probe.content_buf[0..probe_len], se.event.content[0..probe_len]);
        probe.content_len = @intCast(probe_len);
        findQuoteRef(&probe);
        q.has_quote_of = probe.quote.kind == .event;
        if (q.has_quote_of) {
            q.quote_of = probe.quote.id;
            // Asked for AFTER this pass, never during it: `wantQuote` writes over
            // whichever slot it evicts, and the entry being filled here is the
            // one it picks first (it is `.idle` and has never been drawn, so its
            // clock is the minimum). Evicting it mid-fill left the nested id
            // cached as loaded with a zero author and an empty body, permanently,
            // because a loaded entry is never retried.
            if (nested_count < nested.len) {
                nested[nested_count] = q.quote_of;
                nested_count += 1;
            }
        }
        q.state = .loaded;
        q.names_generation = profile_cache.g_names_generation;
        wantProfile(q.pubkey);
    }
    for (nested[0..nested_count]) |id| wantQuote(id);
}

/// Lets the still-unresolved quotes be asked for again on the next round.
pub fn rearmWantedQuotes() void {
    for (&g_quotes) |*q| {
        if (q.used and q.state != .loaded) q.requested = false;
    }
}

/// How long a quote waits before the next try: every round until it has been
/// asked `quote_backoff_after` times, then doubling to a ceiling.
pub fn quoteBackoffRounds(attempts: u8) u64 {
    if (attempts < quote_backoff_after) return 1;
    const over = attempts - quote_backoff_after;
    const shift: u6 = @intCast(@min(over, 5));
    return @min(@as(u64, 1) << shift, quote_backoff_max_rounds);
}
pub fn requeueMissingQuotes() void {
    for (&g_quotes) |*q| {
        if (!q.used or q.state == .loaded) continue;
        q.next_round = 0;
        q.requested = false;
    }
}

/// Asks the pool for any quoted events not yet in the store, one batch on a
/// throwaway connection, bounded like the mention fetch.
pub fn requestWantedQuotes() void {
    var batch: [quote_fetch_batch][32]u8 = undefined;
    var n: usize = 0;
    // The addresses due this round. They share the backoff below with the ids,
    // but are asked by coordinate rather than batched by id.
    var due: [address_pool_batch]*AddressSlot = undefined;
    var due_n: usize = 0;
    for (&g_quotes) |*q| {
        if (!q.used or q.state == .loaded) continue;
        if (q.requested or q.next_round > g_quote_round) continue;
        if (n + due_n == batch.len) break;
        if (addressFor(q.id)) |slot| {
            // One pool message per round carries the addresses; the rest stay
            // due and go in the next.
            if (due_n == due.len) continue;
            due[due_n] = slot;
            due_n += 1;
        } else {
            batch[n] = q.id;
            n += 1;
        }
        q.requested = true;
        if (q.attempts < std.math.maxInt(u8)) q.attempts += 1;
        q.next_round = g_quote_round + quoteBackoffRounds(q.attempts);
        // `.fetching` only while it has never been found: an entry already
        // reported missing keeps saying so on the card while the retry is out,
        // rather than flickering back to a skeleton every time it is retried.
        if (q.state != .missing) q.state = .fetching;
        // Asked often enough with nothing back: say so now. Left to the store
        // growing, a quiet store keeps the skeleton up for as long as it stays
        // quiet, and a card that is neither found nor missing is a spinner.
        if (q.attempts >= quote_backoff_after) q.state = .missing;
    }
    // The addresses whose relays are dialled this round. Once per address: the
    // pool is asked on every round of the backoff, but a speculative socket is
    // not. And only a few per round, like `quote_hint_dials_per_pass`: each
    // costs a socket per hint plus a sweep of the author's relays, and a feed of
    // cards would otherwise open them all at once. The rest dial on a later
    // round they are due in.
    var dial: [address_dials_per_round]*AddressSlot = undefined;
    var dial_n: usize = 0;
    var addrs: [address_pool_batch]Address = undefined;
    for (due[0..due_n], 0..) |slot, i| {
        addrs[i] = slot.addr;
        if (slot.outbox_asked or dial_n == dial.len) continue;
        slot.outbox_asked = true;
        dial[dial_n] = slot;
        dial_n += 1;
    }
    if (!networkAllowed()) return;
    // The pool ask is skipped when nothing is due, but the hints are not: a
    // quote whose hints arrived while its own backoff was still counting down
    // would otherwise wait for the backoff before its relay was ever asked.
    if (n > 0) askQuotes(batch, n);
    if (due_n > 0) _ = askAddressesOnPool(one_shot_sub_prefix ++ "addresses", addrs[0..due_n]);
    for (dial[0..dial_n]) |slot| {
        var hints: [RelayHints.cap][]const u8 = undefined;
        for (0..slot.hints.count) |i| hints[i] = slot.hints.at(@intCast(i));
        dialAddress(slot.addr, hints[0..slot.hints.count]);
    }
    askQuoteHints();
}

/// The most addresses whose relays are dialled in one round of quote asks.
pub const address_dials_per_round = 2;
/// Fetches the quoted events in `batch` by id and ingests them, then closes.
/// The next store-growth tick flips them to `.loaded` via `refreshQuotes`.
/// Asks the pool for these quoted events, on the sockets it already holds.
///
/// Same shape as `askProfiles`, and for the same reason: the quote cache is
/// filled from the store, so a thread holding a socket open until EOSE was
/// waiting for something it did not read.
fn askQuotes(batch: [quote_fetch_batch][32]u8, len: usize) void {
    const filters = [_]nostr.filter.Filter{.{ .ids = batch[0..len], .limit = @intCast(len) }};
    _ = askPool(one_shot_sub_prefix ++ "quotes", &filters);
}

/// The most hinted relays dialled in one pass.
///
/// A feed of quoted notes could otherwise open a socket for every one of them
/// at once, and these are relays this reader does not talk to. Four at a time,
/// with the rest left for the next pass, keeps the speculative half of the
/// fetch smaller than the pool it is supplementing.
pub const quote_hint_dials_per_pass = 4;

/// Dials the relays an address named, for quotes whose hints are still untried.
fn askQuoteHints() void {
    // Gated HERE and not only in the caller. A function that opens sockets
    // deciding it is safe because of what its one caller checked is the same
    // coincidence this gate exists to remove: the day it gains a second caller,
    // nothing says so.
    if (!relayFetchAllowed()) return;
    var spawned: usize = 0;
    for (&g_quotes) |*q| {
        if (!q.used or q.state == .loaded) continue;
        if (q.hints.tried or q.hints.isEmpty()) continue;
        // An address dials its own hints, with the author's relays, in `dialAddress`.
        if (addressFor(q.id) != null) continue;
        // Whole entry or none: a partly dialled entry that got marked tried
        // would silently drop its second hint for good.
        if (spawned + q.hints.count > quote_hint_dials_per_pass) break;
        q.hints.tried = true;
        for (0..q.hints.count) |i| {
            // `fill` already refused these; checked again where the socket is
            // opened, for the reason the gate above gives.
            if (!isPublicRelayUrl(q.hints.at(@intCast(i)))) continue;
            var url_buf: [place_relay_cap]u8 = undefined;
            const len = copyBounded(&url_buf, q.hints.at(@intCast(i)));
            const t = std.Thread.spawn(.{}, askQuoteAt, .{ url_buf, len, q.id }) catch continue;
            t.detach();
            spawned += 1;
        }
    }
}

/// Asks ONE relay an address named for one event, ingests what comes back, and
/// closes.
///
/// A throwaway socket, like `askPlaceAt`, and for the same reason: the pool
/// holds the reader's own relays, and a hint names one that by definition is
/// not among them, so there is no connection to reuse.
///
/// What it finds goes to the STORE and not back to the caller. `refreshQuotes`
/// reads the store on the next tick and flips the entry to `.loaded`, so this
/// thread hands nobody anything and nobody waits on it.
fn askQuoteAt(url_buf: [place_relay_cap]u8, url_len: usize, id: [32]u8) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var relay = nostr.relay.dial(gpa, io, url_buf[0..url_len]) catch return;
    defer relay.deinit();
    // A full keeper table means this one does NOT run, which is the opposite of
    // what the profile and place fetches do when they cannot get a slot. Those
    // are the only ask for what they want, so an unwatched read beats no read.
    // This is not: the pool is already being asked for the same event on its
    // own backoff, so an unbounded speculative socket buys nothing.
    const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
    defer releaseOneShot(watched);

    const ids = [_][32]u8{id};
    const filters = [_]nostr.filter.Filter{.{ .ids = &ids, .limit = 1 }};
    relay.subscribe(one_shot_sub_prefix ++ "quote-hint", &filters) catch return;
    while (true) {
        var msg = (relay.receive() catch break) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| _ = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url_buf[0..url_len]) catch {},
            .eose => break,
            // A CLOSED ends this relay's part, and no EOSE is coming after it.
            .closed => break,
            else => {},
        }
    }
}
/// Whether the note captured an event quote (for tests).
pub fn noteHasEventQuote(note: *const Note) bool {
    return note.quote.kind == .event;
}

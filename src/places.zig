//! Places: the place document, the open place and its feed, and the places the reader keeps.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const feed_state = @import("feed_state.zig");
const quote_cache = @import("quote_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const isAuthRequired = main.isAuthRequired;
const handlePlazaLink = main.handlePlazaLink;
const isPublicMediaUrl = main.isPublicMediaUrl;
const takePendingLink = main.takePendingLink;
const nowSeconds = main.nowSeconds;
const pending_link_stale_s = main.pending_link_stale_s;
const Effects = main.Effects;
const Model = main.Model;
const askPool = main.askPool;
const invalidateFeed = main.invalidateFeed;
const isPublicRelayUrl = main.isPublicRelayUrl;
const one_shot_budget_ms = main.one_shot_budget_ms;
const one_shot_sub_prefix = main.one_shot_sub_prefix;
const plazaDir = main.plazaDir;
const plazaIngest = main.plazaIngest;
const plazaIngestFrom = main.plazaIngestFrom;
const relayFetchAllowed = main.relayFetchAllowed;
const releaseOneShot = main.releaseOneShot;
const resetFeedEnd = main.resetFeedEnd;
const saveSettings = main.saveSettings;
const secret_file_permissions = main.secret_file_permissions;
const setToast = main.setToast;
const wantProfile = main.wantProfile;
const watchOneShot = main.watchOneShot;

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

/// How much of each field a place may carry. Small on purpose: this is chrome,
/// not content, and a place that wants to say more than this wants to be a note.
const place_name_cap = 64;
const place_home_cap = 2048;
const place_feed_name_cap = 48;
pub const place_relay_cap = 96;
/// How much of a `baseShareURL` is kept. A gateway prefix, not a page.
const place_share_cap = 96;

/// How many kinds one feed may name. Hallway's own Livestreams feed carries two
/// (`[1, 30311]`), and a place that wants more than eight in a single feed is
/// asking for a subscription no relay wants to serve.
const place_feed_kinds_cap = 8;
/// How many "open this in that app" handlers a place may carry, and how long
/// one may be. Hallway's Monero instance ships one; four is room for a place
/// that handles notes, articles and streams differently without becoming a menu
/// nobody can read.
const place_handlers_cap = 4;
/// How long one of a place's own room lines may be. A sentence, not an essay:
/// this is drawn centred in an empty room.
const place_room_line_cap = 96;
const place_handler_name_cap = 24;
pub const place_handler_url_cap = 120;

/// How many feeds a place may carry. Hallway's OWN default document ships five
/// ("Basically Global", "Kinda Trending", "Livestreams", and two more), so one
/// was not a simplification of the format, it was four fifths of a community
/// thrown away at the parser.
const place_feeds_cap = 5;
/// How many ids are remembered per place. A screenful and then some; the point
/// is that the room is not empty on arrival, not that it is complete.
const place_seed_cap = 60;

/// How many relays a place may name for reading or writing. Hallway's own
/// documents name two; a place asking for more than four is asking the reader
/// to open sockets they did not choose.
pub const place_relays_cap = 4;
/// How many people one feed may name. Hallway's Monero instance names twenty in
/// a single feed, so this is not a shape that stays small on its own.
const place_feed_pubkeys_cap = 24;

/// One of a place's `clientHandlers`: the web app this community reads a kind
/// in, e.g. kind 1 in Nosmero.
///
/// Plaza already had the one-URL version of this idea in `baseShareURL`. This is
/// the same promise per kind, so a community that reads its notes somewhere
/// specific can say so.
const PlaceHandler = struct {
    kind: u16 = 0,
    name_buf: [place_handler_name_cap]u8 = @splat(0),
    name_len: u8 = 0,
    /// The pattern with `{e}` still in it. Substituted at the press, not here,
    /// because what goes in is the id of whichever note was pressed.
    url_buf: [place_handler_url_cap]u8 = @splat(0),
    url_len: u8 = 0,

    pub fn name(self: *const PlaceHandler) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn pattern(self: *const PlaceHandler) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

const PlaceFeed = struct {
    name_buf: [place_feed_name_cap]u8 = @splat(0),
    name_len: u8 = 0,
    relay_buf: [place_relay_cap]u8 = @splat(0),
    relay_len: u8 = 0,
    /// Who this feed is about, when it is about people rather than a relay.
    ///
    /// Hallway's "People" feed names twenty pubkeys and NO relay, and a feed
    /// with no relay used to be dropped at the parser: the room simply did not
    /// appear, with nothing said. A feed like this asks the PLACE's own read
    /// relays, which is what `read_relays` below is for.
    pubkeys: [place_feed_pubkeys_cap][32]u8 = undefined,
    pubkeys_len: u8 = 0,
    /// What this feed asks the relay for. Empty means Hallway said nothing,
    /// which is notes: the fallback lives at the subscription rather than here
    /// so an empty list stays distinguishable from a stated `[1]`.
    kinds_buf: [place_feed_kinds_cap]u16 = @splat(0),
    kinds_len: u8 = 0,

    pub fn name(self: *const PlaceFeed) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn relay(self: *const PlaceFeed) []const u8 {
        return self.relay_buf[0..self.relay_len];
    }
    pub fn kinds(self: *const PlaceFeed) []const u16 {
        return self.kinds_buf[0..self.kinds_len];
    }
    pub fn people(self: *const PlaceFeed) []const [32]u8 {
        return self.pubkeys[0..self.pubkeys_len];
    }
};

pub const Place = struct {
    name_buf: [place_name_cap]u8 = @splat(0),
    name_len: u8 = 0,
    home_buf: [place_home_cap]u8 = @splat(0),
    home_len: u16 = 0,
    feeds: [place_feeds_cap]PlaceFeed = @splat(.{}),
    feeds_len: u8 = 0,
    /// The last notes seen here, so returning shows the room rather than an
    /// empty screen while a stranger's relay is dialled. Bounded and cheap:
    /// these are ids, and the notes themselves are already in the store.
    seen: [place_seed_cap][32]u8 = undefined,
    seen_len: u16 = 0,
    /// Who published it and under what `d`, so the applied place can be named,
    /// re-fetched, and told apart from another place with the same title.
    author: [32]u8 = @splat(0),
    ident_buf: [64]u8 = @splat(0),
    ident_len: u8 = 0,
    /// Hallway's `defaultPrimaryColor`, resolved at parse time so no view has
    /// to hold a string. Null when the place names no colour OR names one this
    /// version does not know, and those are deliberately the same state: both
    /// mean "leave Plaza's own accent alone", which is the safe answer for a
    /// field a stranger fills in.
    color: ?theme.PlaceColor = null,
    /// Hallway's `avatarStyleDefault`. Only "square" changes anything; "circle"
    /// and an absent key are both the shape the app already draws.
    square_avatars: bool = false,
    /// Hallway's `baseShareURL`: the web gateway this community shares notes
    /// through. Empty when the place names none or names one that did not pass
    /// `isSafeShareUrl`, and both mean the same thing: njump, the app's own.
    share_buf: [place_share_cap]u8 = @splat(0),
    share_len: u8 = 0,
    /// Which feed the ids in `seen` came from.
    ///
    /// They are not the place's notes, they are that FEED's notes, and with one
    /// feed per place nothing could tell the difference. With several, seeding
    /// blind means switching to "Outernational" paints "The Dance"'s notes
    /// under its name until the relay answers, and the next save writes that
    /// mixture down. Which is the same "you are looking at the wrong room" bug
    /// the rebuild flag exists to prevent, in miniature.
    seen_feed: u8 = 0,
    /// The relays this community reads from and writes to, from Hallway's
    /// `readRepliesFrom` and `publishTargets`.
    ///
    /// Plaza had relays and had places and never joined them, which cost two
    /// things at once. A feed naming people and no relay had nothing to ask, so
    /// it was dropped and the room never appeared. And a note written inside a
    /// place walked the READER's write slots, so it went everywhere except the
    /// community it was written in.
    read_relays: [place_relays_cap][place_relay_cap]u8 = @splat(@splat(0)),
    read_relay_lens: [place_relays_cap]u8 = @splat(0),
    read_relays_len: u8 = 0,
    write_relays: [place_relays_cap][place_relay_cap]u8 = @splat(@splat(0)),
    write_relay_lens: [place_relays_cap]u8 = @splat(0),
    write_relays_len: u8 = 0,
    /// Whether those relays are the ONLY ones.
    ///
    /// Read from `readRepliesFromExclusive` and `publishTargetsExclusive`. The
    /// permissive reading is the one implemented: false means "these as well as
    /// mine", true means "only these". That is what the names say, and I have
    /// not read Hallway's own code to confirm it, so the default when the key is
    /// absent is the additive one, which cannot take a reader's relays away.
    read_exclusive: bool = false,
    write_exclusive: bool = false,
    /// Where this community reads each kind, from `clientHandlers`.
    handlers: [place_handlers_cap]PlaceHandler = @splat(.{}),
    handlers_len: u8 = 0,
    /// The community's own mark, from `logoUrl`.
    logo_buf: [place_handler_url_cap]u8 = @splat(0),
    logo_len: u8 = 0,
    /// The three lines a room says about itself, when the place rewrites them.
    ///
    /// From Hallway's `translations`, which is a map of its OWN English strings
    /// to replacements. Plaza's wording is different, so nothing matches by
    /// accident: the three keys below are picked deliberately as the ones that
    /// mean the same thing in a room, and the mapping is a judgement written
    /// down here rather than a lookup that happens to hit.
    ///
    /// Scoped to the room ON PURPOSE. Supporting the whole map would mean
    /// routing every literal in this file through a lookup, and a place
    /// rewriting the app's own vocabulary is the same overreach as a place
    /// collapsing the reader's rail. A community may name what its own room
    /// says while it is empty, connecting or unreachable. It may not rename
    /// Settings.
    empty_line_buf: [place_room_line_cap]u8 = @splat(0),
    empty_line_len: u8 = 0,
    loading_line_buf: [place_room_line_cap]u8 = @splat(0),
    loading_line_len: u8 = 0,
    lost_line_buf: [place_room_line_cap]u8 = @splat(0),
    lost_line_len: u8 = 0,
    /// The `created_at` of the event this was read from, so a newer copy of a
    /// REPLACEABLE document can tell itself apart from the one on screen. Zero
    /// for a place that did not come from an event (a test, a restored line),
    /// which any real event beats.
    applied_at: i64 = 0,

    pub fn name(self: *const Place) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn home(self: *const Place) []const u8 {
        return self.home_buf[0..self.home_len];
    }
    pub fn ident(self: *const Place) []const u8 {
        return self.ident_buf[0..self.ident_len];
    }
    pub fn share(self: *const Place) []const u8 {
        return self.share_buf[0..self.share_len];
    }
    pub fn readRelay(self: *const Place, i: usize) []const u8 {
        return self.read_relays[i][0..self.read_relay_lens[i]];
    }
    pub fn writeRelay(self: *const Place, i: usize) []const u8 {
        return self.write_relays[i][0..self.write_relay_lens[i]];
    }
    /// The handler this place names for `kind`, if it names one.
    pub fn logo(self: *const Place) []const u8 {
        return self.logo_buf[0..self.logo_len];
    }
    pub fn emptyLine(self: *const Place) []const u8 {
        return self.empty_line_buf[0..self.empty_line_len];
    }
    pub fn loadingLine(self: *const Place) []const u8 {
        return self.loading_line_buf[0..self.loading_line_len];
    }
    pub fn lostLine(self: *const Place) []const u8 {
        return self.lost_line_buf[0..self.lost_line_len];
    }
    pub fn handlerFor(self: *const Place, kind: u16) ?*const PlaceHandler {
        for (self.handlers[0..self.handlers_len]) |*h| {
            if (h.kind == kind) return h;
        }
        return null;
    }
};

/// The kind a place is published under. NIP-78 is application-specific data
/// keyed by a `d` tag, which is exactly what this is: one publisher can keep
/// several places apart, and editing one replaces it rather than adding a
/// second.
pub const place_kind: u16 = 30078;
/// Reads a place out of an event's content. Null when it is not one.
///
/// THE FIELD NAMES ARE HALLWAY'S, EXACTLY. fiatjaf's deployer ships its whole
/// configuration as one flat JSON object, `window.hallway.universe`, embedded in
/// every site it deploys: 41 keys, camelCase. Matching it means a place published
/// once means the same thing in both clients, which is worth more than a format
/// of our own. I guessed at `name`/`home`/`feeds` first and every one was wrong.
///
/// This version reads five of the 41, and they are the five that carry a
/// community's CHARACTER rather than its plumbing: `appName`, `homeMarkdown`,
/// `defaultPrimaryColor`, `avatarStyleDefault`, and the first entry of
/// `hardcodedFeeds` (now including its `kinds`).
///
/// The other 36 are ignored HERE and not forgotten: unknown fields are skipped
/// rather than refused, so a place carrying the full object already applies the
/// parts this version understands and picks up the rest as later versions learn
/// them. Most of them will never be learnt, and that is the correct outcome
/// rather than a backlog: `imgproxyUrl`, `genericCorsProxy`, `linkPreviewService`,
/// the four search-relay lists, the Blossom servers and the pomegranate
/// endpoints are answers to problems a BROWSER has. A native client with its own
/// store, its own image pipeline and its own relay pool does not have them.
pub fn parsePlace(gpa: std.mem.Allocator, content: []const u8) ?Place {
    @setRuntimeSafety(true); // A stranger's JSON, sized into fixed buffers.
    const Wire = struct {
        appName: []const u8 = "",
        homeMarkdown: []const u8 = "",
        /// One of Hallway's eighteen NAMES (see `theme.place_colors`), not a
        /// hex. An unknown one resolves to null and changes nothing.
        defaultPrimaryColor: []const u8 = "",
        /// "circle" or "square". Anything else is the app's own shape.
        avatarStyleDefault: []const u8 = "",
        /// The community's web gateway, e.g. "https://njump.me/". Checked
        /// before it is kept: this one sends the READER somewhere.
        baseShareURL: []const u8 = "",
        /// The community's own relays. `readRepliesFrom` is what its feeds ask;
        /// `publishTargets` is where a note written here belongs.
        readRepliesFrom: []const []const u8 = &.{},
        publishTargets: []const []const u8 = &.{},
        /// Whether those are the only ones. See `Place.read_exclusive`.
        readRepliesFromExclusive: bool = false,
        publishTargetsExclusive: bool = false,
        /// `{"byKind": {"1": [{"name": .., "urlPattern": ..}]}}`. Taken as a
        /// raw value because the keys are kind NUMBERS written as strings, so
        /// there is no struct to parse it into; it is walked below.
        clientHandlers: std.json.Value = .null,
        /// The community's own mark. Absolute https only: a relative path is
        /// relative to a website this app has never heard of, and there is
        /// nothing to resolve it against.
        logoUrl: []const u8 = "",
        /// Hallway's own English mapped to replacements. Taken raw: the keys
        /// are sentences, so there is no struct for it either.
        translations: std.json.Value = .null,
        hardcodedFeeds: []const struct {
            /// Optional in Hallway's own data: one feed on the site I read
            /// carries only `relays`, so a feed with no name falls back to its
            /// relay's host rather than drawing blank.
            name: []const u8 = "",
            /// A URL in Hallway's own data (its Livestreams feed points at a
            /// Blossom PNG), not an emoji. Parsed so the shape is honest and
            /// deliberately not stored: the canvas registers sixteen images at
            /// a time and they are all spent on faces, which is the same budget
            /// argument that makes the rail draw letters. See `placeRow`.
            icon: []const u8 = "",
            /// An ARRAY, and a feed can name several. v1 reads the first one it
            /// will dial and says so; reading all of them is v3's job.
            relays: []const []const u8 = &.{},
            pubkeys: []const []const u8 = &.{},
            /// What the feed is FOR. Hallway's own Livestreams feed is
            /// `[1, 30311]`, and a room that asked a relay for notes when the
            /// community publishes streams showed an empty room forever.
            kinds: []const u16 = &.{},
        } = &.{},
    };
    var parsed = std.json.parseFromSlice(Wire, gpa, content, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const w = parsed.value;

    var m = Place{};
    m.name_len = @intCast(copyBounded(&m.name_buf, w.appName));
    m.home_len = @intCast(copyBounded(&m.home_buf, w.homeMarkdown));
    // Resolved HERE, once, rather than carried as a string and looked up per
    // frame: a name a stranger wrote is checked at the boundary like every other
    // field, and what the views hold afterwards is a colour or nothing.
    m.color = theme.placeColor(w.defaultPrimaryColor);
    m.square_avatars = std.mem.eql(u8, w.avatarStyleDefault, "square");
    if (isSafeShareUrl(w.baseShareURL)) m.share_len = @intCast(copyBounded(&m.share_buf, w.baseShareURL));
    for (w.hardcodedFeeds) |f| {
        if (m.feeds_len == m.feeds.len) break;
        // The first relay of this feed that is safe to dial. A feed whose relays
        // are all refused is skipped, and the rest of the place still applies.
        // Public as well as well formed: a room opens its feed the moment the
        // reader walks in, so a place naming a loopback or LAN relay would have
        // every visitor's machine knocking on its own network.
        var chosen: []const u8 = "";
        for (f.relays) |r| {
            if (isPublicRelayUrl(r)) {
                chosen = r;
                break;
            }
        }

        var out = PlaceFeed{};
        // People, when it names any. A feed may be about a relay or about a
        // set of people, and Hallway's own Monero instance ships one of each.
        for (f.pubkeys) |hex| {
            if (out.pubkeys_len == out.pubkeys.len) break;
            if (hex.len != 64) continue;
            var pk: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&pk, hex) catch continue;
            out.pubkeys[out.pubkeys_len] = pk;
            out.pubkeys_len += 1;
        }
        // A feed with neither a relay to dial nor a person to ask about is not
        // a feed. One with people and no relay asks the PLACE's relays, which
        // is why it is no longer dropped here.
        if (chosen.len == 0 and out.pubkeys_len == 0) continue;

        if (chosen.len > 0) out.relay_len = @intCast(copyBounded(&out.relay_buf, chosen));
        const label = if (f.name.len > 0) f.name else if (chosen.len > 0) relayHost(chosen) else "People";
        out.name_len = @intCast(copyBounded(&out.name_buf, label));
        // Bounded like every other field a stranger fills. A feed naming more
        // kinds than fit keeps the first few rather than being refused: a place
        // is chrome, and half a subscription still opens the room.
        for (f.kinds) |k| {
            if (out.kinds_len == out.kinds_buf.len) break;
            out.kinds_buf[out.kinds_len] = k;
            out.kinds_len += 1;
        }
        m.feeds[m.feeds_len] = out;
        m.feeds_len += 1;
    }

    // The community's own relays, checked like every other address a stranger
    // fills in: `isPublicRelayUrl` is what stops a place pointing the reader's
    // socket at something that is not a relay, or at their own network.
    for (w.readRepliesFrom) |r| {
        if (m.read_relays_len == place_relays_cap) break;
        if (!isPublicRelayUrl(r)) continue;
        m.read_relay_lens[m.read_relays_len] = @intCast(copyBounded(&m.read_relays[m.read_relays_len], r));
        m.read_relays_len += 1;
    }
    for (w.publishTargets) |r| {
        if (m.write_relays_len == place_relays_cap) break;
        if (!isPublicRelayUrl(r)) continue;
        m.write_relay_lens[m.write_relays_len] = @intCast(copyBounded(&m.write_relays[m.write_relays_len], r));
        m.write_relays_len += 1;
    }
    // Only meaningful when there is a list to be exclusive about. A place
    // claiming "only mine" and naming none would otherwise silence the reader.
    m.read_exclusive = w.readRepliesFromExclusive and m.read_relays_len > 0;
    m.write_exclusive = w.publishTargetsExclusive and m.write_relays_len > 0;

    // Where this community reads each kind. Walked by hand because the keys are
    // kind numbers written as strings, which is an object no struct describes.
    if (w.clientHandlers == .object) {
        if (w.clientHandlers.object.get("byKind")) |by_kind| {
            if (by_kind == .object) {
                var it = by_kind.object.iterator();
                while (it.next()) |entry| {
                    if (m.handlers_len == place_handlers_cap) break;
                    const kind = std.fmt.parseInt(u16, entry.key_ptr.*, 10) catch continue;
                    if (entry.value_ptr.* != .array) continue;
                    // The first one this app will open. A place may list
                    // several and the reader is offered one row, so a handler
                    // that fails the gate is skipped rather than ending the
                    // list: the next may be fine.
                    for (entry.value_ptr.array.items) |item| {
                        if (item != .object) continue;
                        const url_v = item.object.get("urlPattern") orelse continue;
                        if (url_v != .string) continue;
                        if (!isSafeHandlerUrl(url_v.string)) continue;
                        var h = PlaceHandler{ .kind = kind };
                        h.url_len = @intCast(copyBounded(&h.url_buf, url_v.string));
                        const name_v = item.object.get("name");
                        const label = if (name_v) |n| (if (n == .string) n.string else "") else "";
                        // Named by its host when it names itself nothing: a row
                        // reading "Open in" and then nothing is worse than one
                        // naming the site it will open.
                        h.name_len = @intCast(copyBounded(&h.name_buf, if (label.len > 0) label else shareHost(url_v.string)));
                        m.handlers[m.handlers_len] = h;
                        m.handlers_len += 1;
                        break;
                    }
                }
            }
        }
    }

    // The community's mark. `isSafeShareUrl` is the right gate: this is an
    // address the app will FETCH, and a logo has no business carrying a query.
    // A relative path is refused rather than guessed at, since the document
    // says nothing about which website it came from.
    if (isSafeShareUrl(w.logoUrl) and isPublicMediaUrl(w.logoUrl)) m.logo_len = @intCast(copyBounded(&m.logo_buf, w.logoUrl));

    // The three lines a room says about itself.
    //
    // Hallway's keys, chosen for what they MEAN rather than matched by text:
    // Plaza's own wording is different, so nothing here lines up by accident
    // and each of these three is a decision.
    if (w.translations == .object) {
        const t = w.translations.object;
        // "Empty list." is what Hallway calls a list with nothing in it, which
        // is this app's "Nothing here yet."
        if (t.get("Empty list.")) |v| {
            if (v == .string) m.empty_line_len = @intCast(copyBounded(&m.empty_line_buf, v.string));
        }
        // "Loading" for the wait. Hallway also ships "Loading..." and
        // "loading..." as separate keys; the bare one is the label, the others
        // are the same word mid-sentence, so the label is what a room uses.
        if (t.get("Loading")) |v| {
            if (v == .string) m.loading_line_len = @intCast(copyBounded(&m.loading_line_buf, v.string));
        }
        // "Lost in the void" is Hallway's not-found, which in a room is the
        // relay this place lives on not answering.
        if (t.get("Lost in the void")) |v| {
            if (v == .string) m.lost_line_len = @intCast(copyBounded(&m.lost_line_buf, v.string));
        }
    }

    // A place with nothing to say is not a place. This is what stops any random
    // kind:30078 (the kind is shared by every app that stores settings) from
    // being applied as one.
    if (m.name_len == 0 and m.home_len == 0 and m.feeds_len == 0) return null;
    return m;
}

/// A relay URL without its scheme or trailing slash, for naming a feed that did
/// not name itself.
pub fn relayHost(url: []const u8) []const u8 {
    var h = url;
    if (std.mem.startsWith(u8, h, "wss://")) h = h["wss://".len..];
    return std.mem.trimEnd(u8, h, "/");
}

/// Copies as much of `src` as fits, on a UTF-8 boundary, and returns the length.
pub fn copyBounded(dst: []u8, src: []const u8) usize {
    var n = @min(src.len, dst.len);
    // Same boundary rule as the reply snippet: a field cut mid-character draws
    // a replacement glyph, which is worse than a shorter field.
    if (n < src.len) {
        while (n > 0 and (src[n] & 0xc0) == 0x80) n -= 1;
    }
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Whether a relay URL from a place is one this app will dial.
///
/// The sharpest field in the document: it decides where the app connects. Plain
/// `wss://` only, no control bytes, no spaces, and short enough to hold. A place
/// cannot point Plaza at `ws://` in the clear, and cannot smuggle a newline into
/// a frame.
pub fn isSafeRelayUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "wss://")) return false;
    if (url.len <= "wss://".len or url.len > place_relay_cap) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// The relays an address said its subject lives on, copied and bounded.
///
/// Copied rather than referenced: the decode's arena is gone long before the
/// fetch runs. Bounded at two because each hint that gets used costs a
/// throwaway socket to a relay this reader does not otherwise talk to, and an
/// `nevent` can name as many as its author felt like.
///
/// Every hint is gated through `isPublicRelayUrl` on the way IN, so nothing
/// downstream has to remember to check a string that came off the wire. Public
/// and not only well formed: these are dialled with nobody pressing anything (a
/// quote card asks as its note scrolls into view), so a note naming a loopback
/// or a LAN relay would send every reader's machine knocking on its own network.
/// Gated here rather than at the dial alone, too, so such a hint never takes one
/// of the two slots from a relay that could answer.
pub const RelayHints = struct {
    pub const cap = 2;

    buf: [cap][place_relay_cap]u8 = @splat(@splat(0)),
    len: [cap]u8 = @splat(0),
    count: u8 = 0,
    /// Dialled at most once. A hint that did not answer is not retried on every
    /// round: it is one author's claim about where something lives, the pool is
    /// still being asked on its own backoff, and retrying speculative sockets
    /// forever is how a quiet cache turns into a connection storm.
    tried: bool = false,

    pub fn fill(self: *RelayHints, hints: []const []const u8) void {
        self.count = 0;
        self.tried = false;
        for (hints) |h| {
            if (self.count >= cap) break;
            if (!isPublicRelayUrl(h)) continue;
            // Never a duplicate: two mentions of the same relay would spend two
            // of the two slots on one socket.
            var seen = false;
            for (0..self.count) |i| {
                if (std.mem.eql(u8, self.at(@intCast(i)), h)) seen = true;
            }
            if (seen) continue;
            self.len[self.count] = @intCast(copyBounded(&self.buf[self.count], h));
            self.count += 1;
        }
    }

    pub fn at(self: *const RelayHints, i: u8) []const u8 {
        return self.buf[i][0..self.len[i]];
    }

    pub fn isEmpty(self: *const RelayHints) bool {
        return self.count == 0;
    }
};

/// Whether a place's `baseShareURL` is safe to hand a browser.
///
/// This one is sharper than it looks, and sharper than the relay check beside
/// it. A relay URL only decides who the app TALKS to; this decides where the
/// READER is sent, and a community that set it to a convincing copy of njump
/// would be a phishing page one press from a note. So: https only (a share link
/// is a web page, and cleartext for one is a downgrade nobody asked for), no
/// credentials in the authority (`user:pass@evil` reading as a familiar host is
/// the oldest trick there is), no query or fragment to smuggle a redirect
/// through, and nothing but printable ASCII.
///
/// The remaining risk is not closed by parsing, so it is closed by SAYING it:
/// the menu row names the host it will open (see `noteContextItems`), which
/// turns "Open on the web" into "Open on njump.me" or "Open on unknown.example"
/// before the press rather than after.
pub fn isSafeShareUrl(url: []const u8) bool {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return false;
    if (url.len <= scheme.len or url.len > place_share_cap) return false;
    for (url) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        if (c == '?' or c == '#' or c == '\\') return false;
    }
    const rest = url[scheme.len..];
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return false;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    return true;
}

/// Whether a place's `clientHandlers` pattern is one this app will open.
///
/// A SEPARATE gate from `isSafeShareUrl`, deliberately. That one refuses `?`
/// and `#` outright, because a share base has no business carrying a query and
/// one that does is usually carrying a redirect. A handler pattern is the case
/// where a query IS the mechanism: `https://nosmero.com/?thread={e}`. So the
/// query is allowed and everything else is tightened instead.
///
/// Exactly one `{e}`, which is what makes this a pattern rather than a fixed
/// address. What replaces it is an event id, and the caller writes it as hex,
/// so nothing a stranger typed reaches the URL.
pub fn isSafeHandlerUrl(url: []const u8) bool {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return false;
    if (url.len <= scheme.len or url.len > place_handler_url_cap) return false;
    for (url) |c| {
        // Printable ASCII only, and no backslash: everything else is either a
        // control character or a way of writing a host that does not read as
        // one.
        if (c <= 0x20 or c >= 0x7f) return false;
        if (c == '\\') return false;
    }
    const rest = url[scheme.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return false;
    // No credentials, and no placeholder in the HOST: `{e}` belongs in the path
    // or the query, and one in the authority would let a note id choose which
    // server this opens.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (std.mem.indexOfScalar(u8, authority, '{') != null) return false;
    // Exactly one placeholder. None is a fixed link that ignores the note;
    // several is an ambiguity not worth resolving.
    var seen: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, url, i, "{e}")) |at| : (i = at + 3) seen += 1;
    return seen == 1;
}

/// The host a share URL will open, for saying so on the row that opens it.
pub fn shareHost(url: []const u8) []const u8 {
    var h = url;
    if (std.mem.startsWith(u8, h, "https://")) h = h["https://".len..];
    const end = std.mem.indexOfScalar(u8, h, '/') orelse h.len;
    return h[0..end];
}
/// Which of the place's feeds is open. Reset on arrival rather than persisted:
/// a room's feed choice is a reading position, not a setting, and the honest
/// default is the one its host listed first.
pub var g_place_feed: u8 = 0;

/// The feed being read, or null when the place has none.
pub fn currentPlaceFeed(m: *const Place) ?*const PlaceFeed {
    if (m.feeds_len == 0) return null;
    const i = @min(g_place_feed, m.feeds_len - 1);
    return &m.feeds[i];
}
/// The place you are in right now. Null is your own Plaza.
///
/// Three states, and only two of them are stored. VISITING is this being set
/// while `g_place_kept` is false: you followed a link, you are in the place,
/// you can read it and post to it, and closing the app forgets it. ENTERED is
/// the same thing with the place also in the list below, which is the only
/// thing entering does. LEFT is out of the list; the link still works.
///
/// Nothing is gated on entering. Whether a post lands is between the reader and
/// the place's relays: if they refuse the write, that is theirs to say, not a
/// wall this app invents.
pub var g_place: ?Place = null;
pub var g_place_kept: bool = false;

/// What the place's relay has told us about, newest first.
///
/// A ROOM, per the decision: while you are in a place you see IT, not your own
/// feed with a header on top. Nothing in the store records which relay an event
/// arrived on, so the connection keeps its own list of ids and the rebuild reads
/// exactly those. That also makes leaving instant: drop the list.
pub const place_feed_cap = 200;
pub var g_place_ids: [place_feed_cap][32]u8 = undefined;
pub var g_place_ids_len: usize = 0;
var g_place_ids_lock = std.atomic.Value(bool).init(false);
/// Bumped by the relay thread so the UI knows there is something new to read,
/// the same shape the arrival buffer uses.
pub var g_place_rev = std.atomic.Value(u32).init(0);
/// Which place the live connection belongs to, so a thread whose place has been
/// left stops writing into the list the next one is filling.
pub var g_place_gen = std.atomic.Value(u32).init(0);

pub fn lockPlaceIds() void {
    while (g_place_ids_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockPlaceIds() void {
    g_place_ids_lock.store(false, .release);
}

/// Seeds the place's list from what was remembered last time.
///
/// The rest of this app is local-first and a place was not: entering one showed
/// "Connecting to the relay pool" and nothing else until a stranger's relay
/// answered, which on a slow one is a long time to look at an empty room. The
/// notes are already in the store from last visit; the only thing missing was
/// knowing WHICH of them belong to this place, since nothing records the relay
/// an event arrived on. So the ids are remembered with the place.
pub fn seedPlaceFeed(ids: []const [32]u8) void {
    lockPlaceIds();
    defer unlockPlaceIds();
    g_place_ids_len = @min(ids.len, g_place_ids.len);
    @memcpy(g_place_ids[0..g_place_ids_len], ids[0..g_place_ids_len]);
    _ = g_place_rev.fetchAdd(1, .monotonic);
}

/// A snapshot of the current place's ids, for writing down.
fn placeIdsSnapshot(out: [][32]u8) usize {
    lockPlaceIds();
    defer unlockPlaceIds();
    const n = @min(g_place_ids_len, out.len);
    @memcpy(out[0..n], g_place_ids[0..n]);
    return n;
}

/// What the place's own socket is doing.
///
/// Its own state, because the status bar counts the POOL and a place's relay is
/// deliberately not in it. So a place that is slow, or refusing, or simply not
/// there looked exactly like a connected one while the bar cheerfully reported
/// 5/5 relays. That is the reader being told the wrong thing about the only
/// connection they are actually waiting on.
///
/// `no_feed` is a place with nothing to dial: no feed at all, or a feed that
/// names no relay and a place that names none either. It is not a wait, and
/// reading it as one left "Connecting to this place" up for good.
///
/// `refused` is a relay that answered and closed the feed: most often a relay
/// that wants to know who the reader is (NIP-42) before it shows anything. The
/// socket was up, so it used to read as `connected` with an empty room, which
/// says the place is quiet when it is shut.
pub const PlaceLink = enum(u8) { idle, connecting, connected, unreachable_relay, no_feed, refused };
var g_place_link = std.atomic.Value(u8).init(@intFromEnum(PlaceLink.idle));

pub fn placeLink() PlaceLink {
    return @enumFromInt(g_place_link.load(.monotonic));
}
pub fn setPlaceLink(state: PlaceLink) void {
    g_place_link.store(@intFromEnum(state), .monotonic);
}

/// What the room says when its relay closed the feed, written by the worker
/// before it sets `refused` and read by the view after it sees that.
var g_place_refusal_buf: [200]u8 = undefined;

var g_place_refusal_len = std.atomic.Value(u8).init(0);

pub fn placeRefusalLine() []const u8 {
    return g_place_refusal_buf[0..g_place_refusal_len.load(.acquire)];
}

/// Records why the place's relay closed its feed, in words for the room. Only
/// for the worker that still owns the room, like every other write here.
fn notePlaceRefusal(gen: u32, reason: []const u8) void {
    if (g_place_gen.load(.monotonic) != gen) return;
    var line: []const u8 = undefined;
    if (isAuthRequired(reason)) {
        line = "This place's relay wants to know who you are before it shows anything.";
        @memcpy(g_place_refusal_buf[0..line.len], line);
    } else {
        // A stranger's words on screen: control bytes become spaces, and the
        // length is capped on a character boundary.
        const lead = "This place's relay closed its feed";
        var n: usize = lead.len;
        @memcpy(g_place_refusal_buf[0..n], lead);
        const said = std.mem.trim(u8, reason, " \t\r\n");
        if (said.len == 0) {
            const tail = " without saying why.";
            @memcpy(g_place_refusal_buf[n..][0..tail.len], tail);
            n += tail.len;
        } else {
            const mid = ": ";
            @memcpy(g_place_refusal_buf[n..][0..mid.len], mid);
            n += mid.len;
            var take = @min(said.len, g_place_refusal_buf.len - n);
            while (take > 0 and take < said.len and (said[take] & 0xC0) == 0x80) take -= 1;
            for (said[0..take]) |c| {
                g_place_refusal_buf[n] = if (c < 0x20 or c == 0x7f) ' ' else c;
                n += 1;
            }
        }
        line = g_place_refusal_buf[0..n];
    }
    g_place_refusal_len.store(@intCast(line.len), .release);
    setPlaceLink(.refused);
}

pub fn clearPlaceFeed() void {
    // Walking into a room, out of one, or between two replaces the feed's
    // question outright, and the end of history is an ANSWER about a question.
    // A place's feed is capped, so scrolling to the bottom of one latched the
    // end, and the latch is for the life of the process: going Home afterwards
    // left the reader's own feed unable to ask for anything older, silently,
    // for as long as the app stayed open. Changing the follow set and the relay
    // pool already say this; the rooms did not.
    resetFeedEnd();
    _ = g_place_gen.fetchAdd(1, .monotonic);
    setPlaceLink(.idle);
    lockPlaceIds();
    defer unlockPlaceIds();
    g_place_ids_len = 0;
    _ = g_place_rev.fetchAdd(1, .monotonic);
}

pub fn placeFeedCount() usize {
    lockPlaceIds();
    defer unlockPlaceIds();
    return g_place_ids_len;
}

/// Opens the place's relay and keeps reading it.
///
/// Its own socket, outside the eight. Entering a place must never cost the
/// reader one of their own relays, and this connection never publishes and is
/// never written into their kind:10002, which is the same discipline the
/// indexer set and the discovered pool already follow.
pub fn startPlaceFeed(m: *const Place) void {
    clearPlaceFeed();
    // What was here last time, on screen before anything is dialled, and BEFORE
    // the check below: the ids are already known whether or not there is a
    // relay to go and ask. Seeding after that early return meant a place whose
    // feed could not be dialled showed nothing, having remembered everything.
    // Only when they belong to the feed being opened. A miss is not a failure:
    // the room fills from the relay a moment later, which is what it does on a
    // first visit anyway.
    if (m.seen_len > 0 and m.seen_feed == g_place_feed) seedPlaceFeed(m.seen[0..m.seen_len]);
    const feed = currentPlaceFeed(m) orelse {
        setPlaceLink(.no_feed);
        return;
    };
    const gen = g_place_gen.load(.monotonic);
    var url_buf: [place_relay_cap]u8 = undefined;
    // A feed about people names no relay of its own, so it asks the PLACE's,
    // which is the whole reason a place carries them. Falling back to the
    // reader's own pool would ask the wrong relays a question about a community
    // they have never heard of.
    const url = if (feed.relay().len > 0)
        feed.relay()
    else if (m.read_relays_len > 0)
        m.readRelay(0)
    else
        "";
    if (url.len == 0) {
        setPlaceLink(.no_feed);
        return;
    }
    const len = copyBounded(&url_buf, url);
    // Here and not at the top of this function: everything above is local, and
    // the tests that drive `.place_feed` are about the seeding and the feed
    // list, which must keep running. This is the line that opens a socket.
    if (!relayFetchAllowed()) return;
    // Here, on the thread that just bumped the generation, and not first thing
    // in the worker. The worker's write was unguarded, so a reader who clicked
    // through a room with a feed into one with none had the first room's
    // thread wake up late and paint "connecting" over the second room's
    // `no_feed`, where nothing would ever clear it.
    setPlaceLink(.connecting);
    // BY VALUE, like the url: the worker outlives this frame's borrow of the
    // place, and the reader may have walked out of it by the time the socket
    // opens.
    const t = std.Thread.spawn(.{}, placeFeedWorker, .{ url_buf, len, feed.kinds_buf, feed.kinds_len, gen, feed.pubkeys, feed.pubkeys_len }) catch return;
    t.detach();
}

/// What a feed that named no kinds asks for. Hallway leaves `kinds` off every
/// feed but one, and every one of those is notes.
const place_feed_default_kinds = [_]u16{1};

pub fn placeFeedWorker(url_buf: [place_relay_cap]u8, url_len: usize, kinds_buf: [place_feed_kinds_cap]u16, kinds_len: u8, gen: u32, authors: [place_feed_pubkeys_cap][32]u8, authors_len: u8) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var relay = nostr.relay.dial(gpa, io, url_buf[0..url_len]) catch {
        // Only if this thread still owns the place. A dial that fails after the
        // reader has already walked out must not paint the next room's header.
        if (g_place_gen.load(.monotonic) == gen) setPlaceLink(.unreachable_relay);
        return;
    };
    defer relay.deinit();
    if (g_place_gen.load(.monotonic) == gen) setPlaceLink(.connected);

    // What the PLACE said it is, not what this app assumed it would be. A
    // community publishing streams or wikis used to get a subscription for
    // kind 1 and an empty room that never filled, which reads as a broken relay
    // rather than as a client that was not listening.
    const kinds: []const u16 = if (kinds_len > 0) kinds_buf[0..kinds_len] else &place_feed_default_kinds;
    // A feed about PEOPLE asks for those people; one about a relay asks that
    // relay for everything of the kinds it names. Both by value, like the url:
    // this thread outlives the frame that borrowed the place.
    const filters = if (authors_len > 0) [_]nostr.filter.Filter{.{
        .authors = authors[0..authors_len],
        .kinds = kinds,
        .limit = place_feed_cap,
    }} else [_]nostr.filter.Filter{.{ .kinds = kinds, .limit = place_feed_cap }};
    relay.subscribe("plaza-place", &filters) catch return;

    while (g_place_gen.load(.monotonic) == gen) {
        var msg = (relay.receive() catch break) orelse break;
        defer msg.deinit();
        switch (placeFeedStep(gpa, signer, url_buf[0..url_len], gen, msg.value)) {
            .more => {},
            .left => break,
            .done => return,
        }
    }
    // The loop only ends when the socket died or the reader left. The first is
    // worth saying out loud; the second already reset this.
    if (g_place_gen.load(.monotonic) == gen) setPlaceLink(.unreachable_relay);
}

/// What one message from the place's relay does to the room.
const PlaceFeedStep = enum { more, left, done };

fn placeFeedStep(gpa: std.mem.Allocator, signer: nostr.keys.Signer, url: []const u8, gen: u32, value: nostr.message.RelayMessage) PlaceFeedStep {
    switch (value) {
        .event => |e| {
            _ = plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, url) catch return .more;
            // The reader left, or moved: this thread's list is not the one
            // being shown any more, so it stops rather than writing into it.
            if (g_place_gen.load(.monotonic) != gen) return .left;
            wantProfile(e.event.pubkey);
            lockPlaceIds();
            defer unlockPlaceIds();
            if (g_place_ids_len < g_place_ids.len) {
                g_place_ids[g_place_ids_len] = e.event.id;
                g_place_ids_len += 1;
                _ = g_place_rev.fetchAdd(1, .monotonic);
            }
            return .more;
        },
        // The relay ended the feed, and nothing more will come down it.
        // Said in the room, rather than left as a connected socket over an
        // empty list. Answering a NIP-42 challenge here is not done: this
        // socket is a visitor's, and signing in to a stranger's relay is the
        // reader's call, not a side effect of walking in.
        .closed => |c| {
            if (!std.mem.eql(u8, c.subscription_id, "plaza-place")) return .more;
            notePlaceRefusal(gen, c.message);
            return .done;
        },
        // NOT closed at EOSE: a place is somewhere you sit, so the socket
        // stays open and new notes arrive while the reader is looking.
        else => return .more,
    }
}

/// Whether the places rail is out. One boolean, persisted, and that is the
/// whole of the second rail's state.
///
/// The design called for a SECTION here, one of Home / Search / Notifications /
/// Messages / Places, with the second rail's contents a pure function of it.
/// Driving the built version is what argued against it: with only Places
/// carrying a second rail, making Home a section that has none meant pressing
/// Home hid the list of places, so coming back from your own feed to a room
/// cost two presses. That is the opposite of switching between them with ease,
/// which is the whole point of the rail.
///
/// So the Places icon is a toggle for the switcher, exactly as it was asked
/// for, and Home is a content destination that leaves the rail alone. The
/// section comes back when a second one actually needs a second rail (Messages
/// and its conversations, most likely), and it can be designed then against two
/// real cases instead of one imagined one.
///
/// Off by default: a reader with no places should never be given a column that
/// only says it is empty. Entering a place turns it on, and it stays on.
pub var g_rail_open: bool = false;

/// What the place's Info card is doing.
///
/// A card and not a banner. The host's own text used to sit inline above the
/// feed on every visit, which is a wall of somebody else's markdown in front of
/// the thing it is selling. So the whole of what a place says about itself
/// lives behind one control, and the first-visit presentation is its own
/// design problem rather than "the banner, again".
///
/// Leave lives in here too. It is the one destructive verb in a place, it was
/// sitting in the header a few pixels from Enter, and one press did it. Now it
/// takes two, and the second one is behind a card that says what leaving does.
pub const PlaceInfo = enum(u8) { closed, open, leaving };
pub var g_place_info: PlaceInfo = .closed;

pub fn placeInfo() PlaceInfo {
    return g_place_info;
}
pub fn railOpen() bool {
    return g_rail_open;
}

/// The Places icon, and `Cmd+Option+S`.
pub fn togglePlacesRail() void {
    g_rail_open = !g_rail_open;
    saveSettings();
}

/// Navigation reveals the switcher: entering a place, walking the list, or
/// bouncing back into a room all put the rail where the eye is going to look.
/// Opening one FROM the rail does not go through this, so folding it and then
/// pressing a seat cannot make it spring back open.
pub fn showPlacesRail() void {
    g_rail_open = true;
}
/// Everything about where the leaving account had been.
///
/// Which communities somebody belongs to is sensitive, which is the whole
/// reason this list is a file on their own disk rather than an event on a
/// relay. That is also what made it outlive a logout: a relay-backed list goes
/// when the key does, and a file does not go until something deletes it. So the
/// next account to sign in on this Mac inherited the last one's rail, fully
/// populated, opened straight into whichever place they had been reading, with
/// the notes each one had been holding.
///
/// The file AND the memory AND the pointer in settings, because all three
/// outlive the account in different ways: the file across launches, the memory
/// across this session, and `place=` would send the next launch back into a
/// room that is no longer in any list.
pub fn forgetPlaces() void {
    // Stops the place's socket first: its worker writes into the id list, and
    // the generation bump is what tells it to stop.
    clearPlaceFeed();
    g_place = null;
    g_place_feed = 0;
    g_place_kept = false;
    g_visited = null;
    g_place_last = 0;
    g_places = @splat(.{});
    g_places_len = 0;
    g_place_info = .closed;
    g_rail_open = false;
    g_boot_place_set = false;
    if (main.g_io) |io| if (main.g_environ) |environ| {
        if (plazaDir(io, environ)) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            dir.deleteFile(io, places_file) catch {};
        } else |_| {}
    };
    saveSettings();
    // The feed was the place's a moment ago and is the next reader's now.
    invalidateFeed();
}
/// The places kept across restarts. Small on purpose for v1.
const max_places = 8;
pub var g_places: [max_places]Place = @splat(.{});
pub var g_places_len: usize = 0;
/// What we are fetching, while we fetch it.
pub var g_place_want: ?struct {
    pubkey: [32]u8,
    ident_buf: [64]u8,
    ident_len: u8,
    /// Ticks the fetch has been outstanding, so it can give up and say so.
    waited: u16 = 0,
    /// Whether a copy has already been shown. The window stays open past the
    /// first one (see `refreshPlaceFetch`), and this is what tells "still
    /// looking" apart from "showing one, watching for a newer".
    applied: bool = false,
} = null;

/// Whether the place on screen is the one this fetch is for.
///
/// Identity is host plus `d`, the same pair the rail, the file and
/// `placeIndexOf` use to tell two places apart, because a title is not an
/// identity and two communities may share one.
pub fn samePlace(want: @TypeOf(g_place_want.?)) bool {
    const cur = if (g_place) |*c| c else return false;
    return std.mem.eql(u8, &cur.author, &want.pubkey) and
        std.mem.eql(u8, cur.ident(), want.ident_buf[0..want.ident_len]);
}
/// Hands the open room to an arriving document, when it is the same room.
///
/// An UPGRADE keeps the room: the notes on screen belong to this place
/// whichever version of the document describes it, and a fresh parse has an
/// empty `seen`, so re-seeding from it would blank a room mid-read. A document
/// for a DIFFERENT place is not an upgrade and gets none of it. It arrives with
/// an empty room and a fresh subscription, which is what walking into a
/// different room means.
pub fn adoptOpenRoom(want: @TypeOf(g_place_want.?), m: *Place) struct { upgrade: bool, refeed: bool } {
    if (!samePlace(want)) return .{ .upgrade = false, .refeed = true };
    const cur = &g_place.?;
    m.seen = cur.seen;
    m.seen_len = cur.seen_len;
    // The feed being READ, not the first one: an edit that adds a feed above
    // the one you are in must not silently move you.
    if (m.feeds_len > 0 and g_place_feed >= m.feeds_len) g_place_feed = m.feeds_len - 1;
    const old_feed = currentPlaceFeed(cur);
    const new_feed = currentPlaceFeed(m);
    const old_relay = if (old_feed) |f| f.relay() else "";
    const new_relay = if (new_feed) |f| f.relay() else "";
    const old_kinds = if (old_feed) |f| f.kinds() else &[_]u16{};
    const new_kinds = if (new_feed) |f| f.kinds() else &[_]u16{};
    // Only what the SUBSCRIPTION is made of. An edit that changes a name, a
    // colour or the home text must not drop a working socket and empty the
    // room to say so.
    return .{
        .upgrade = true,
        .refeed = !std.mem.eql(u8, old_relay, new_relay) or !std.mem.eql(u16, old_kinds, new_kinds),
    };
}
pub fn activePlace() ?*const Place {
    return if (g_place) |*m| m else null;
}

/// The open place's colour, for `theme.place_color_fn`.
///
/// Reads `g_place` on every call rather than caching, which is the whole reason
/// the theme is handed a function instead of a colour: there is no copy here
/// that can fall out of date when the reader walks into the next room.
fn activePlaceColor() ?theme.PlaceColor {
    const m = g_place orelse return null;
    return m.color;
}

/// Hands the theme its window onto the app. Called from `boot`, and by the
/// suite for the tests that assert what a place does to the tokens.
pub fn installThemeHooks() void {
    theme.place_color_fn = &activePlaceColor;
}
pub fn placeIsKept() bool {
    return g_place_kept;
}
pub fn keptPlaceCount() usize {
    return g_places_len;
}

/// Whether a place with this author and identifier is already in the list.
pub fn placeIndexOf(author: [32]u8, ident: []const u8) ?usize {
    for (g_places[0..g_places_len], 0..) |*p, i| {
        if (std.mem.eql(u8, &p.author, &author) and std.mem.eql(u8, p.ident(), ident)) return i;
    }
    return null;
}

/// Which entry of the list is open, when the open place is one of them. Null
/// while visiting, because a visit is deliberately not in the list.
pub fn activePlaceIndex() ?usize {
    const m = g_place orelse return null;
    return placeIndexOf(m.author, m.ident());
}

/// The last place opened from the rail, so `Cmd+Option+Right` has somewhere to
/// bounce back to. An index rather than an address because it is a convenience:
/// leaving a place shifts the ones after it, and the read below clamps, so the
/// worst a stale value does is bounce into a neighbour.
pub var g_place_last: usize = 0;

/// Opens a place already in the list.
///
/// The room being left is written down FIRST. Switching places is precisely
/// when its ids stop being reachable: `rememberPlaceIds` reads the live list,
/// and the next `startPlaceFeed` clears it.
pub fn openKeptPlace(i: usize) void {
    if (i >= g_places_len) return;
    g_place_info = .closed;
    partWithOpenPlace();
    g_place_last = i;
    g_place = g_places[i];
    g_place_feed = 0;
    g_place_kept = true;
    startPlaceFeed(&g_place.?);
    // The feed is about to mean something entirely different, and the
    // incremental path cannot express that: it merges arrivals into the list
    // already on screen.
    feed_state.g_feed_rebuild_all.store(true, .release);
    saveSettings();
}

/// The place being visited, held for this session only.
///
/// A visit is transient by design, and Home closing the room turned that into a
/// trap: peek at your own feed for a second and the room is gone, with nothing
/// on the rail to get back to it because a visit is deliberately not in the
/// list. This is the seat it keeps until the app quits, which is exactly as
/// long as a visit was ever promised to last.
pub var g_visited: ?Place = null;

/// What the rail's "Visiting" row stands for: the place open right now if it is
/// a visit, otherwise the last one visited this session.
pub fn visitingPlace() ?*const Place {
    if (g_place) |*m| {
        if (!g_place_kept) return m;
    }
    return if (g_visited) |*m| m else null;
}

/// Back into the visit that Home closed.
pub fn resumeVisit() void {
    // Read BEFORE parting with the room on screen, because parting with an
    // unkept one WRITES this seat: taking the target afterwards would resume
    // the room just left, forever.
    const target = g_visited orelse return;
    partWithOpenPlace();
    // The card belongs to the room it was opened on. Left up, an armed "Leave
    // this place?" points at whichever room arrives under it.
    g_place_info = .closed;
    g_place = target;
    g_place_feed = 0;
    g_place_kept = false;
    showPlacesRail();
    startPlaceFeed(&g_place.?);
    feed_state.g_feed_rebuild_all.store(true, .release);
    saveSettings();
}

/// Everything leaving the room on screen owes it, wherever the reader is going.
///
/// A kept place is written down; an unkept one is a VISIT, and a visit is not in
/// the list, so the rail's seat is the only way back to it. Only Home used to do
/// this pair, and every other way out did half of it: stepping onto a rail row
/// or following a link out of a visit dropped that visit on the floor. There was
/// nothing on the rail naming it and no list holding it, so it was simply gone,
/// which is the trap the seat exists to prevent.
fn partWithOpenPlace() void {
    if (g_place == null) return;
    if (g_place_kept) savePlaces() else g_visited = g_place;
}

/// Back to your own feed, without leaving the place.
///
/// Home and Leave were the same button for as long as there was no rail, and
/// they are not the same verb: this closes the room, and the place stays in the
/// list with its ids intact, one press away.
pub fn goToOwnPlaza() void {
    if (g_place == null) return;
    g_place_info = .closed;
    partWithOpenPlace();
    g_place = null;
    g_place_feed = 0;
    g_place_kept = false;
    clearPlaceFeed();
    feed_state.g_feed_rebuild_all.store(true, .release);
    saveSettings();
}

/// `Cmd+Option+Right`: out of the room, and back into the one you were in.
///
/// This one earns a key more here than it does in the clients it is borrowed
/// from. A place is a ROOM, so being in one hides your own feed entirely, and
/// the way out has to be as cheap as the way in.
pub fn bouncePlace() void {
    if (g_place != null) {
        goToOwnPlaza();
        return;
    }
    if (g_places_len == 0) return;
    showPlacesRail();
    openKeptPlace(@min(g_place_last, g_places_len - 1));
}

/// `Cmd+Option+Up` / `Down`: the place before or after the open one, wrapping.
///
/// Discord and Slack both spend this pair on walking the community list, which
/// is what our places are even though they sit on the second rail rather than
/// the first. Matching the muscle memory is worth more than matching the rail.
pub fn stepPlace(delta: i8) void {
    if (g_places_len == 0) return;
    const n: isize = @intCast(g_places_len);
    const next: usize = if (activePlaceIndex()) |c|
        @intCast(@mod(@as(isize, @intCast(c)) + delta, n))
    else if (delta > 0) 0 else g_places_len - 1;
    showPlacesRail();
    openKeptPlace(next);
}
/// The place that was open when the app last quit.
///
/// Reopening used to land in the most recently ENTERED place no matter what,
/// because entering was the only way to be in one. With a rail there is a way
/// out that is not leaving, so "the last one entered" and "the one I was
/// looking at" came apart, and restoring the wrong one reads as the app
/// ignoring you.
var g_boot_place_author: [32]u8 = @splat(0);
var g_boot_place_ident_buf: [64]u8 = @splat(0);
var g_boot_place_ident_len: u8 = 0;
pub var g_boot_place_set: bool = false;

/// `<64 hex>:<d>`, or empty for your own Plaza. Written by author and `d`
/// rather than by position, so leaving a place cannot silently reopen whichever
/// one slid into its index.
pub fn activePlaceLine(buf: []u8) []const u8 {
    const m = g_place orelse return "";
    if (!g_place_kept) return "";
    const hex = std.fmt.bytesToHex(m.author, .lower);
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ &hex, m.ident() }) catch "";
}

pub fn applyActivePlaceLine(value: []const u8) void {
    g_boot_place_set = false;
    if (value.len < 65 or value[64] != ':') return;
    _ = std.fmt.hexToBytes(&g_boot_place_author, value[0..64]) catch return;
    g_boot_place_ident_len = @intCast(copyBounded(&g_boot_place_ident_buf, value[65..]));
    g_boot_place_set = true;
}

/// Land back where you were: the place that was open at quit, or your own
/// Plaza if that is what was open.
///
/// Its own function so a test can drive the decision boot makes rather than a
/// helper beside it. Restoring the most recently ENTERED place unconditionally
/// was right while entering was the only way to be in one, and became wrong the
/// moment Home stopped meaning "leave"; a probe that put that line back left
/// the suite green, because nothing exercised this.
pub fn restoreOpenPlace() void {
    const i = bootPlaceIndex() orelse return;
    openKeptPlace(i);
}
/// Where boot should land, when what was open is still in the list.
pub fn bootPlaceIndex() ?usize {
    if (!g_boot_place_set) return null;
    return placeIndexOf(g_boot_place_author, g_boot_place_ident_buf[0..g_boot_place_ident_len]);
}
/// Asks for a place event: the pool, plus the relays the address itself named.
///
/// The hints matter more here than anywhere else in the app. A place is
/// published by whoever runs a community, on that community's relay, and the
/// reader has by definition not joined it yet: that is the thing the link is
/// for. Asking only the reader's own relays would fail for exactly the case
/// this feature exists to serve.
pub fn askPlace(fx: *Effects, hints: []const []const u8) void {
    _ = fx;
    const want = g_place_want orelse return;
    const ident = want.ident_buf[0..want.ident_len];

    const authors = [_][32]u8{want.pubkey};
    const kinds = [_]u16{place_kind};
    const values = [_][]const u8{ident};
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'd', .values = &values }};
    const filters = [_]nostr.filter.Filter{.{
        .authors = &authors,
        .kinds = &kinds,
        .tags = &tags,
        .limit = 1,
    }};
    _ = askPool(one_shot_sub_prefix ++ "place", &filters);

    // And the hinted relays, which the pool does not hold. One throwaway socket
    // each, bounded, the same shape every other one-shot in this app uses.
    var chosen: [place_hint_dials][]const u8 = undefined;
    for (chosen[0..placeHintsToAsk(hints, &chosen)]) |h| {
        var url_buf: [place_relay_cap]u8 = undefined;
        const len = copyBounded(&url_buf, h);
        if (!relayFetchAllowed()) break;
        const t = std.Thread.spawn(.{}, askPlaceAt, .{ url_buf, len, want.pubkey, want.ident_buf, want.ident_len }) catch continue;
        t.detach();
    }
}

/// The most hinted relays one place link dials.
const place_hint_dials = 3;

/// Which of a place link's hints get a socket: the first few on the public
/// internet. The link came from a stranger, so the same gate as every other
/// hint, or a link in a note could point the reader's machine at its own
/// loopback or LAN.
fn placeHintsToAsk(hints: []const []const u8, out: *[place_hint_dials][]const u8) usize {
    var n: usize = 0;
    for (hints) |h| {
        if (n == out.len) break;
        if (!isPublicRelayUrl(h)) continue;
        out[n] = h;
        n += 1;
    }
    return n;
}

pub fn placeHintsToAskForTest(hints: []const []const u8, out: *[place_hint_dials][]const u8) usize {
    return placeHintsToAsk(hints, out);
}
pub const placeHintDialsForTest = place_hint_dials;

fn askPlaceAt(url_buf: [place_relay_cap]u8, url_len: usize, pubkey: [32]u8, ident_buf: [64]u8, ident_len: u8) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var relay = nostr.relay.dial(gpa, io, url_buf[0..url_len]) catch return;
    defer relay.deinit();
    const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
    defer releaseOneShot(watched);

    const authors = [_][32]u8{pubkey};
    const kinds = [_]u16{place_kind};
    const values = [_][]const u8{ident_buf[0..ident_len]};
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'd', .values = &values }};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .tags = &tags, .limit = 1 }};
    relay.subscribe(one_shot_sub_prefix ++ "place", &filters) catch return;
    while (true) {
        var msg = (relay.receive() catch break) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| _ = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch {},
            .eose => break,
            // A CLOSED ends this relay's part, and no EOSE is coming after it.
            .closed => break,
            else => {},
        }
    }
}

/// What one look for the place being waited on came to.
const PlaceFetch = enum {
    /// Nothing to say yet: still looking, or nothing is being waited on.
    waiting,
    /// A copy was found and the reader is in the room.
    arrived,
    /// The window ran out with nothing found.
    missed,
    /// Something was found under that address and it does not describe a place.
    not_a_place,
};

pub const place_looking_toast = "Looking for that place";

/// One tick of the place fetch, and what the reader is told when it ends
/// without a place. Silence was the answer to both, so a pasted address that
/// named nothing looked exactly like one that was still loading.
pub fn refreshPlaceFetch(model: *Model) void {
    switch (placeFetchStep()) {
        .waiting => {},
        // The room is on screen, so "looking" is out of date.
        .arrived => if (std.mem.eql(u8, model.toast_text(), place_looking_toast)) {
            model.toast_until = 0;
        },
        .missed => setToast(model, "That place did not turn up."),
        .not_a_place => setToast(model, "That address does not describe a place."),
    }
}

/// Looks for the place being waited on, once the store has grown. Called from
/// the tick, which is where every other "did it arrive yet" check in this app
/// lives.
pub fn placeFetchStep() PlaceFetch {
    const want = g_place_want orelse return .waiting;
    // Shown once and the reader has since walked out. The window closes rather
    // than dragging them back into a room they left on the next tick.
    //
    // Walking out is not only going home. Reading this as `g_place == null` left
    // the window open when the reader stepped SIDEWAYS into another room, and
    // the next tick then re-applied the linked place over the one they had just
    // picked: for the fifteen ticks this window lasts, clicking a row on the
    // rail did not stick. That is the very thing the line above says it
    // prevents, and it is the same "some room" for "this room" slip that
    // `adoptOpenRoom` was carrying.
    if (want.applied and !samePlace(want)) {
        g_place_want = null;
        return .waiting;
    }
    const store = main.g_store orelse return .waiting;
    const gpa = std.heap.page_allocator;

    const authors = [_][32]u8{want.pubkey};
    const kinds = [_]u16{place_kind};
    const values = [_][]const u8{want.ident_buf[0..want.ident_len]};
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'd', .values = &values }};
    var result = store.query(gpa, .{ .authors = &authors, .kinds = &kinds, .tags = &tags, .limit = 1 }) catch return .waiting;
    defer result.deinit();

    if (result.events.len == 0) {
        // Give up eventually rather than spinning on a store read forever. A
        // place nobody can find is a fact worth showing, not a spinner.
        g_place_want.?.waited +|= 1;
        if (g_place_want.?.waited > place_fetch_ticks) {
            g_place_want = null;
            return if (want.applied) .waiting else .missed;
        }
        return .waiting;
    }
    const ev = result.events[0];
    // Already showing this copy, or a newer one.
    //
    // The window deliberately stays OPEN past the first hit, and that is the
    // whole of this fix. A place is a REPLACEABLE event, and the copy sitting
    // in the local store when a link is followed is LAST SESSION'S: it is read
    // on the first tick, applied instantly, and the host's current document,
    // still in flight from their relay, used to arrive a moment later, get
    // ingested, and never reach the room. A community that had edited its
    // place since your last visit showed you the old one until you quit.
    // Only against the place already on screen. `g_place` can be a DIFFERENT
    // place: following a link out of one room and into another leaves the old
    // one open until this lands, and then every comparison here is between two
    // unrelated documents. Comparing their timestamps is comparing nothing, and
    // the room the reader asked for lost whenever the room they were standing
    // in happened to have been edited more recently.
    if (samePlace(want)) {
        if (g_place.?.applied_at >= ev.created_at) {
            g_place_want.?.waited +|= 1;
            if (g_place_want.?.waited > place_fetch_ticks) g_place_want = null;
            return .waiting;
        }
    }
    var m = parsePlace(gpa, ev.content) orelse {
        // It exists and is not a place. Stop asking, and say so, unless a copy
        // that WAS a place is already on screen: then this is a later edition
        // that did not parse, the room stays as it is, and telling a reader
        // standing in it that the address is not a place would be wrong.
        g_place_want = null;
        return if (want.applied) .waiting else .not_a_place;
    };
    m.author = want.pubkey;
    m.ident_len = want.ident_len;
    m.ident_buf = want.ident_buf;
    m.applied_at = ev.created_at;

    // An UPGRADE keeps the room. The notes on screen belong to this place
    // whichever version of the document describes it, and a fresh parse has an
    // empty `seen`, so re-seeding from it would blank a room mid-read.
    //
    // The SAME place, not merely SOME place. This read `g_place != null`, which
    // is true of a reader who is standing in one room and following a link into
    // a different one: the arrival was then treated as a new edition of the
    // room they were leaving. It kept that room's socket, skipped its welcome,
    // held its feed index, and handed the incoming place the OTHER place's
    // remembered ids two lines below. Those ids are saved, so the wrong room's
    // notes came back on every later visit and the two places could not be told
    // apart from the rail.
    const adopted = adoptOpenRoom(want, &m);
    const upgrade = adopted.upgrade;
    const refeed = adopted.refeed;
    // Straight in, visiting. No sheet: the destination of following a link is
    // the place, not a question about it.
    //
    // A DIFFERENT place, so the room on screen is being left, with everything
    // that owes: an unkept one takes the rail's seat, and the info card closes
    // because it belongs to the room it was opened on. An armed "Leave this
    // place?" left standing here retargets whatever arrives under it, and the
    // press that follows takes the wrong room off the rail with the ids it
    // remembered. The card reopens two lines below when this is a first visit.
    if (!upgrade) {
        partWithOpenPlace();
        g_place_info = .closed;
    }
    g_place = m;
    // ARRIVAL only. On an upgrade the reader is already somewhere in this
    // place's feeds, and resetting would move them off whatever they are
    // reading because the host edited a colour. The clamp above is what keeps
    // the index honest when an edit shortens the list.
    if (!upgrade) g_place_feed = 0;
    g_place_kept = placeIndexOf(m.author, m.ident()) != null;
    g_place_want.?.applied = true;
    // The host's own words, without a press, in the surface built to hold them.
    //
    // They lived behind the Info button, which nobody presses on the way in.
    // Putting them over the feed instead was worse in a way that took running it
    // to see: there is no way to READ a welcome that the only available verb
    // (Enter) dismisses. So the room opens with the card already up: the whole
    // text, scrollable, with Enter and Close both in reach. Closing it leaves
    // you in the room. That is also what keeps the older decision this
    // nearly broke: the markdown never sits over the feed.
    //
    // Only on ARRIVAL, and only for a visit. Coming back to a place from the
    // rail is not a first impression, and a card in the way every time you
    // switch rooms is the banner problem again wearing a different hat.
    if (!upgrade and !g_place_kept and m.home_len > 0) g_place_info = .open;
    if (!upgrade or refeed) startPlaceFeed(&g_place.?);
    // The feed is about to mean something entirely different, and the
    // incremental path cannot express that: it merges arrivals into the list
    // already on screen. Without this the reader enters a place and keeps
    // looking at their own follows, which is exactly what was reported.
    feed_state.g_feed_rebuild_all.store(true, .release);
    // Which room is open is written down on every other way into one, and was
    // not on this one. A reader who opened a room from the rail and then
    // followed a link into another quit with the file still naming the first,
    // and the next launch opened it. There is no quit hook: this file is only
    // ever written as it changes.
    saveSettings();

    // And the window runs out on its own, so a copy landing after this one is
    // still picked up, and the watching stops when the fetch would have.
    g_place_want.?.waited +|= 1;
    if (g_place_want.?.waited > place_fetch_ticks) g_place_want = null;
    return .arrived;
}

/// How many ticks a place fetch may go unanswered. The tick is a second, and a
/// relay that has not answered in fifteen is one that does not have it.
const place_fetch_ticks = 15;
/// Where the places you have entered are written.
///
/// A local file for v1, and that is a privacy decision as much as a simplicity
/// one: a list of the communities somebody belongs to is sensitive, and a file
/// on their own disk exposes nothing at all. The encrypted `kind:30078` version
/// that syncs across devices is v2, and it has two hazards already written down
/// in the notes: it is replaceable, so it must be read back before it is
/// written, and NIP-44 decrypt is a signer capability a remote bunker may not
/// offer.
///
/// Written in Hallway's own shape, one document per line, so the file is the
/// documents and not a private encoding of them.
const places_file = "places";

/// How long one place's line can get, and therefore how much of the file is
/// read back.
///
/// Sized to what a line can ACTUALLY hold rather than to what it usually does,
/// because the failure mode is not truncation: `loadPlaces` gives up on a read
/// it cannot fit and every kept place vanishes at launch without a word. The
/// home text is counted at twice its cap because it is JSON-escaped on the way
/// out (a document of newlines doubles), and the feeds and the share base are
/// counted because this used to know about neither.
/// Every field the writer can emit is counted here, and a field added to
/// `writePlaceDocument` without a term added here shortens this silently. That
/// is what makes it dangerous rather than merely wrong: the reader does not
/// truncate the overflow, it abandons the whole file, so the cost of missing a
/// term is the reader's entire list of places disappearing at launch. The
/// people feed alone (twenty-four keys of sixty-six characters) is larger than
/// everything this used to count.
const place_line_cap = place_home_cap * 2 +
    place_feeds_cap * (place_feed_name_cap + place_relay_cap + place_feed_kinds_cap * 8 +
        place_feed_pubkeys_cap * 70 + 64) +
    place_handlers_cap * (place_handler_name_cap + place_handler_url_cap + 32) +
    place_relays_cap * 2 * (place_relay_cap + 4) +
    place_share_cap + place_handler_url_cap + place_seed_cap * 70 + 2048;

/// Copies what the live place has seen back onto its entry in the list, so the
/// file records the room as it was left.
/// How often the room being read is written down. This is a convenience for
/// the next launch, not a transaction, so it is coarse on purpose.
const place_flush_s: i64 = 5;
pub var g_place_flushed_at: i64 = 0;
pub var g_place_flushed_rev: u32 = 0;

/// Writes the ids down while the reader is still in the place.
///
/// Without this the file only ever held what existed at the moment Enter was
/// pressed, which is nothing: the notes arrive afterwards. So the place was
/// remembered and its contents never were, and the next launch opened an empty
/// room having saved the ids of nothing.
pub fn flushPlaceIds(now_s: i64) void {
    if (g_place == null or !g_place_kept) return;
    const rev = g_place_rev.load(.monotonic);
    if (rev == g_place_flushed_rev) return;
    if (now_s - g_place_flushed_at < place_flush_s) return;
    g_place_flushed_at = now_s;
    g_place_flushed_rev = rev;
    savePlaces();
}

pub fn rememberPlaceIds() void {
    const m = g_place orelse return;
    const i = placeIndexOf(m.author, m.ident()) orelse return;
    var snapshot: [place_seed_cap][32]u8 = undefined;
    const n = placeIdsSnapshot(&snapshot);
    // An empty live list is not news, and writing it down destroys something.
    //
    // Saving runs on a timer and on every way out of a room, so with more than
    // one feed the old unconditional write had a wipe in it: switch to a feed
    // that has not answered yet, leave, and the place forgot the room it was
    // going to open with next launch. One remembered room per place is the
    // design; erasing it because a different feed is still dialling is not.
    if (n == 0) return;
    @memcpy(g_places[i].seen[0..n], snapshot[0..n]);
    g_places[i].seen_len = @intCast(n);
    g_places[i].seen_feed = g_place_feed;
}

pub fn savePlaces() void {
    rememberPlaceIds();
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    if (g_places_len == 0) {
        dir.deleteFile(io, places_file) catch {};
        return;
    }
    const gpa = std.heap.page_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (g_places[0..g_places_len]) |*m| {
        writePlaceDocument(gpa, &out, m) catch return;
    }
    dir.writeFile(io, .{
        .sub_path = places_file,
        .data = out.items,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// One place as one line of Hallway's own shape.
///
/// Split out of `savePlaces` so the round trip is testable without a
/// filesystem: what this writes has to come back through `parsePlace` meaning
/// the same thing, and that is a property of the STRING, not of the disk.
pub fn writePlaceDocument(gpa: std.mem.Allocator, out: *std.ArrayList(u8), m: *const Place) !void {
    try out.print(gpa,
        \\{{"appName":{f},"homeMarkdown":{f},"defaultPrimaryColor":{f},"avatarStyleDefault":{f},"baseShareURL":{f},"hardcodedFeeds":[
    , .{
        std.json.fmt(m.name(), .{}),
        std.json.fmt(m.home(), .{}),
        // The NAME, not the colour it resolved to. This file is Hallway's
        // document and stays readable as one; a hex here would be a private
        // encoding of a field that has eighteen public values. An empty string
        // round-trips to "no colour stated", which is the same thing the parser
        // does with a name it does not know.
        std.json.fmt(if (m.color) |c| c.name else "", .{}),
        std.json.fmt(if (m.square_avatars) "square" else "", .{}),
        std.json.fmt(m.share(), .{}),
    });
    // EVERY feed, in order. Writing only the first was invisible until a place
    // carried more than one: the file is what a restart reads, so a room that
    // had four feeds came back with one and no way to say what happened to the
    // rest. The kinds go by hand for the same reason the ids below do: an array
    // of numbers has no struct formatter here.
    for (m.feeds[0..m.feeds_len], 0..) |*f, fi| {
        if (fi > 0) try out.append(gpa, ',');
        // An empty relay list, not a list holding an empty string. A feed about
        // people names no relay, and `[""]` says it names one that is nothing:
        // the parser throws it away either way, but the file is Hallway's
        // document and should stay one somebody else could read.
        try out.print(gpa, "{{\"name\":{f},\"relays\":[", .{std.json.fmt(f.name(), .{})});
        if (f.relay().len > 0) try out.print(gpa, "{f}", .{std.json.fmt(f.relay(), .{})});
        try out.appendSlice(gpa, "],\"kinds\":[");
        for (f.kinds(), 0..) |k, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "{d}", .{k});
        }
        // And who the feed is about. Dropping these turned a feed about people
        // back into a feed about nothing on the next save, which is the same
        // "came back with less than it had" the kinds above exist to prevent.
        try out.appendSlice(gpa, "],\"pubkeys\":[");
        for (f.people(), 0..) |pk, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "{f}", .{std.json.fmt(&std.fmt.bytesToHex(pk, .lower), .{})});
        }
        try out.appendSlice(gpa, "]}");
    }
    try out.appendSlice(gpa, "]");

    // Everything else this app reads out of a place. Written back because this
    // file is what a restart reads: a field the parser understands and the
    // writer forgets is a field that works once and is gone by morning. That is
    // exactly what happened to the logo, the community's relays, its handlers
    // and its own words for a room.
    try out.print(gpa, ",\"logoUrl\":{f}", .{std.json.fmt(m.logo(), .{})});
    try out.appendSlice(gpa, ",\"readRepliesFrom\":[");
    for (0..m.read_relays_len) |i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "{f}", .{std.json.fmt(m.readRelay(i), .{})});
    }
    try out.appendSlice(gpa, "],\"publishTargets\":[");
    for (0..m.write_relays_len) |i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "{f}", .{std.json.fmt(m.writeRelay(i), .{})});
    }
    try out.print(gpa, "],\"readRepliesFromExclusive\":{s},\"publishTargetsExclusive\":{s}", .{
        if (m.read_exclusive) "true" else "false",
        if (m.write_exclusive) "true" else "false",
    });

    // Back in Hallway's own shape, keyed by kind, so this file stays a document
    // that client could read rather than a private encoding of one.
    try out.appendSlice(gpa, ",\"clientHandlers\":{\"byKind\":{");
    for (m.handlers[0..m.handlers_len], 0..) |*h, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "\"{d}\":[{{\"name\":{f},\"urlPattern\":{f}}}]", .{
            h.kind,
            std.json.fmt(h.name(), .{}),
            std.json.fmt(h.pattern(), .{}),
        });
    }
    try out.appendSlice(gpa, "}}");

    // The three room lines, under the Hallway keys they were read from.
    try out.print(gpa, ",\"translations\":{{\"Empty list.\":{f},\"Loading\":{f},\"Lost in the void\":{f}}}", .{
        std.json.fmt(m.emptyLine(), .{}),
        std.json.fmt(m.loadingLine(), .{}),
        std.json.fmt(m.lostLine(), .{}),
    });

    try out.print(gpa,
        \\,"host":{f},"d":{f}
    , .{
        std.json.fmt(&std.fmt.bytesToHex(m.author, .lower), .{}),
        std.json.fmt(m.ident(), .{}),
    });
    // The ids, so returning here is instant. Written last and by hand rather
    // than through the struct formatter, because they are ours and not part of
    // Hallway's document.
    try out.print(gpa, ",\"seenFeed\":{d},\"seen\":[", .{m.seen_feed});
    for (m.seen[0..m.seen_len], 0..) |id, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "\"{s}\"", .{&std.fmt.bytesToHex(id, .lower)});
    }
    try out.appendSlice(gpa, "]}");
    try out.append(gpa, '\n');
}
pub fn loadPlaces(io: std.Io, environ: *const std.process.Environ.Map) void {
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, places_file, gpa, std.Io.Limit.limited(place_line_cap * max_places)) catch return;
    defer gpa.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (g_places_len == g_places.len) break;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var m = parsePlace(gpa, line) orelse continue;
        // `host` and `d` are ours, not Hallway's, so they are read here rather
        // than in the shared parser: they are how a place is told apart from
        // another with the same title, and how it is re-fetched later.
        const Extra = struct { host: []const u8 = "", d: []const u8 = "", seenFeed: u8 = 0, seen: []const []const u8 = &.{} };
        if (std.json.parseFromSlice(Extra, gpa, line, .{ .ignore_unknown_fields = true })) |ex| {
            defer ex.deinit();
            if (ex.value.host.len == 64) {
                _ = std.fmt.hexToBytes(&m.author, ex.value.host) catch {};
            }
            m.ident_len = @intCast(copyBounded(&m.ident_buf, ex.value.d));
            m.seen_feed = ex.value.seenFeed;
            for (ex.value.seen) |hex| {
                if (m.seen_len == m.seen.len) break;
                if (hex.len != 64) continue;
                var id: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&id, hex) catch continue;
                m.seen[m.seen_len] = id;
                m.seen_len += 1;
            }
        } else |_| {}
        g_places[g_places_len] = m;
        g_places_len += 1;
    }
}

/// So a test builds an address for the kind Plaza actually looks for, rather
/// than repeating the number and agreeing with it by coincidence.
pub const place_kind_for_test = place_kind;
/// The relays a quote's fetch would dial, empty when it is not cached.
pub fn quoteHintsForTest(id: [32]u8) RelayHints {
    for (&quote_cache.g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) return q.hints;
    }
    return .{};
}
pub fn placeFeedIndexForTest() u8 {
    return g_place_feed;
}

pub fn setPlaceInfoForTest(state: PlaceInfo) void {
    g_place_info = state;
}

pub fn togglePlacesRailForTest() void {
    togglePlacesRail();
}
pub fn setRailForTest(open: bool) void {
    g_rail_open = open;
}

pub fn forgetPlacesForTest() void {
    forgetPlaces();
}

/// The predicate above, for the test: the arrival path it guards needs a store,
/// a relay and a link, and the decision it makes does not.
pub fn samePlaceForTest(pubkey: [32]u8, ident: []const u8) bool {
    var w: @TypeOf(g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
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
    var w: @TypeOf(g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    w.ident_len = @intCast(copyBounded(&w.ident_buf, ident));
    _ = adoptOpenRoom(w, &m);
    return m.seen_len;
}

/// Drives the REAL entry path. It spawns a worker that dials and fails without
/// a relay, which is harmless: the seeding this asserts happens before it.
pub fn startPlaceFeedForTest(i: usize) void {
    startPlaceFeed(&g_places[i]);
}

/// Arms the fetch a `plaza://` link arms, without the link or the sockets.
pub fn armPlaceFetchForTest(pubkey: [32]u8, ident: []const u8) void {
    var want: @TypeOf(g_place_want.?) = .{ .pubkey = pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    want.ident_len = @intCast(copyBounded(&want.ident_buf, ident));
    g_place_want = want;
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
    if (g_place_want) |*w| w.applied = true;
}

/// Whether the window is still watching. Closed is what walking away must
/// produce: an open window re-applies its place over the room on screen.
pub fn placeFetchArmedForTest() bool {
    return g_place_want != null;
}

pub fn forgetPlaceFetchForTest() void {
    g_place_want = null;
}
pub fn savePlacesForTest() void {
    savePlaces();
}

pub fn setPlaceLinkForTest(state: PlaceLink) void {
    setPlaceLink(state);
}

/// One message through the feed worker's own step, for the room it belongs to
/// or, `stale`, for one already left. Returns the step's name.
pub fn placeFeedStepForTest(stale: bool, value: nostr.message.RelayMessage) []const u8 {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const gen = g_place_gen.load(.monotonic) -% @as(u32, if (stale) 1 else 0);
    return @tagName(placeFeedStep(std.heap.page_allocator, signer, "wss://place.example", gen, value));
}

/// Runs a feed worker that belongs to a room already left, against a url that
/// fails before any socket is opened.
pub fn runStalePlaceFeedWorkerForTest() void {
    var url_buf: [place_relay_cap]u8 = undefined;
    const url = "http://not-a-relay";
    @memcpy(url_buf[0..url.len], url);
    const stale = g_place_gen.load(.monotonic) -% 1;
    placeFeedWorker(url_buf, url.len, undefined, 0, stale, undefined, 0);
}

/// Arrives in a place that has a named feed, which is the ordinary case.
pub fn visitPlaceWithFeedForTest(author: [32]u8, ident: []const u8, name: []const u8, feed: []const u8) void {
    visitPlaceForTest(author, ident, name);
    if (g_place) |*m| {
        m.feeds[0].name_len = @intCast(copyBounded(&m.feeds[0].name_buf, feed));
        m.feeds[0].relay_len = @intCast(copyBounded(&m.feeds[0].relay_buf, "wss://example.test"));
        m.feeds_len = 1;
    }
}

pub fn flushPlaceIdsForTest(now_s: i64) void {
    flushPlaceIds(now_s);
}
pub fn setPlaceHomeForTest(text: []const u8) void {
    if (g_place) |*m| m.home_len = @intCast(copyBounded(&m.home_buf, text));
}
pub fn setKeptPlaceSeenLenForTest(i: usize, n: u16) void {
    g_places[i].seen_len = n;
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
    return g_places[i].seen_len;
}
pub fn seedFromKeptPlaceForTest(i: usize) void {
    seedPlaceFeed(g_places[i].seen[0..g_places[i].seen_len]);
}

pub fn resetPlacesForTest() void {
    // The feed ids too, or one test's room leaks into the next one's.
    clearPlaceFeed();
    g_rail_open = false;
    g_place_info = .closed;
    g_place_flushed_at = 0;
    g_place_flushed_rev = 0;
    g_place = null;
    g_place_feed = 0;
    g_place_kept = false;
    g_visited = null;
    g_place_last = 0;
    g_places = @splat(.{});
    g_places_len = 0;
}

/// Arrives in a place the way a link does: in it, kept only if it already was.
pub fn visitPlaceForTest(author: [32]u8, ident: []const u8, name: []const u8) void {
    var m = Place{};
    m.author = author;
    m.ident_len = @intCast(copyBounded(&m.ident_buf, ident));
    m.name_len = @intCast(copyBounded(&m.name_buf, name));
    g_place = m;
    g_place_feed = 0;
    g_place_kept = placeIndexOf(m.author, m.ident()) != null;
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
    g_place = m;
    g_place_feed = 0;
    g_place_kept = placeIndexOf(m.author, m.ident()) != null;
    return true;
}

pub fn clearActivePlaceForTest() void {
    g_place = null;
    g_place_feed = 0;
    g_place_kept = false;
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

/// A link that came in while the Edit profile sheet was up, and when it came.
///
/// It used to stay wherever it had arrived. On disk it carried its own stamp,
/// but the macOS slot carries none, so a link clicked at the start of a long
/// edit opened a room whenever the sheet finally closed, however much later
/// that was; and a link that went stale on disk in the meantime was dropped
/// with nothing to show for it. Taking it off its source at once and stamping
/// it here gives every link the same rule.
var g_held_link_buf: [2048]u8 = undefined;
var g_held_link_len: usize = 0;
var g_held_link_at: i64 = 0;

pub fn drainPendingLink(model: *Model, fx: *Effects) void {
    var link_buf: [2048]u8 = undefined;
    // Not while the Edit profile sheet is up. Following the link leaves
    // Settings, which hides the sheet and what was typed in it, so the link is
    // held until the sheet closes. A newer one replaces it: if two arrive, the
    // later is the one the reader meant.
    if (model.stage == .settings and model.editing_profile) {
        if (takePendingLink(&link_buf)) |link| {
            g_held_link_len = copyBounded(&g_held_link_buf, link);
            g_held_link_at = nowSeconds();
        }
        return;
    }
    if (takePendingLink(&link_buf)) |link| {
        g_held_link_len = 0;
        handlePlazaLink(model, fx, link);
        return;
    }
    if (g_held_link_len == 0) return;
    const n = g_held_link_len;
    g_held_link_len = 0;
    // Only while it is still something the reader just asked for. A room
    // opening minutes after the click, on its own, is worse than none.
    if (nowSeconds() - g_held_link_at > pending_link_stale_s) return;
    @memcpy(link_buf[0..n], g_held_link_buf[0..n]);
    handlePlazaLink(model, fx, link_buf[0..n]);
}

pub fn drainPendingLinkForTest(model: *Model, fx: *Effects) void {
    drainPendingLink(model, fx);
}

/// Moves the held link's stamp back, as if the sheet had stayed up that long.
pub fn ageHeldLinkForTest(seconds: i64) void {
    g_held_link_at -= seconds;
}
pub const place_looking_toast_for_test = place_looking_toast;
/// Gives the open place one write relay of its own, the way a parsed document
/// would. The routing tests are about WHEN the relay list is read, not about
/// parsing it.
pub fn setPlaceWriteRelayForTest(url: []const u8) void {
    if (g_place == null) return;
    const m = &g_place.?;
    m.write_relay_lens[0] = @intCast(copyBounded(&m.write_relays[0], url));
    m.write_relays_len = 1;
}
/// The document one place writes, for the round-trip test.
pub fn writePlaceDocumentForTest(gpa: std.mem.Allocator, out: *std.ArrayList(u8), m: *const Place) !void {
    return writePlaceDocument(gpa, out, m);
}

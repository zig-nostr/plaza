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
const view_app = @import("view_app.zig");

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
pub var g_last_count: usize = std.math.maxInt(usize);
/// The same, for whichever level is open. Separate from `g_last_count` because
/// the feed consumes that one, and a level opened after a feed rebuild would
/// otherwise see an unchanged count and never fill.
var g_last_level_count: usize = std.math.maxInt(usize);

/// Whether a secret key is sitting in THIS process.
///
/// A constant false, and that is the assertion rather than a stub: there is no
/// longer a variable in this program that can hold one. The test that reads
/// this is what keeps that true, by failing the day somebody adds one back.
pub fn holdsKeyInProcessForTest() bool {
    return false;
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
pub var g_view_build: u64 = 0;

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
                .refused => placeRefusalLine(),
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
        // A profile's rows live in the same buffer, and so do a hashtag page's
        // and the bookmark list's, so they resolve the same way. Without this
        // every press on one of those rows (open, like, expand a picture) is a
        // silent no-op, which is worse than an inert control because it looks
        // live.
        if (self.viewing_thread != 0 or self.viewing_profile != null) {
            if (self.thread_root.id == note_id) return &self.thread_root;
        }
        if (self.levelOpen()) {
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

    pub fn rebuildNotes(self: *Model, store: *nostr.store.Store, now_s: i64) void {
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

/// The refresh the tick runs when the store moved.
pub fn refreshProfileNotesForTest(model: *Model) void {
    model.refreshProfileNotes(nowSeconds());
}

// The names generation the current cards were parsed under (see
// `g_names_generation`).
pub var g_notes_names_generation: u64 = 0;

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

/// Delivers one decrypt answer for slot zero the way the runtime would, so a
/// test can drive a keyholder that refuses.
pub fn deliverPrivateHalfForTest(status: u16, body: []const u8) void {
    deliverPrivateHalfKeyedForTest(privateHalfAskKeyForTest(0), status, body);
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

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) {
                const now = nowSeconds();
                // A `plaza://` link somebody clicked, drained once per tick.
                // Polling rather than an effect because the Apple Event lands
                // on the main thread outside the SDK's event loop entirely,
                // so there is nothing to subscribe to.
                drainPendingLink(model, fx);
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
                // A refused reply with no room left to go back into.
                flushRefusedReplyClip(fx);
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
            if (postWaitsForPicture()) return;
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
        .profile_save => saveProfile(model, fx),
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
            // Not over the Edit profile sheet. The field would replace the
            // sheet on screen, and opening anything it found leaves Settings
            // with the sheet still up but no longer drawn, its edits stranded
            // where only the next Settings visit (which starts it over) goes.
            // The sheet is modal, so the shortcut waits for it like every
            // other press does.
            if (model.stage == .settings and model.editing_profile) return;
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
            // The level stays as it is. The composer draws over any of them,
            // and clearing the thread from under it left the stack, a reply
            // held under its pause and the way back to Notifications all
            // pointing at a level that was no longer open.
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
pub fn sayBookmarkWrite(model: *Model, outcome: BookmarkWrite, adding: bool) void {
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
pub fn sayMuteWrite(model: *Model, outcome: MuteWrite, muting: bool) void {
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

/// Puts `text` on the clipboard. A test build records it instead, because the
/// effect queue behind `fx` does not exist there and the text is the thing worth
/// checking: what Plaza hands another client.
pub fn writeClipboardText(fx: *Effects, key: u64, text: []const u8) void {
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

pub fn activePubkeyForTest() ?[32]u8 {
    return activePubkey();
}

/// Lends the app an io for the one place a test reaches for it (minting the
/// ephemeral client key). For tests.
pub fn setIoForTest(io: ?std.Io) void {
    g_io = io;
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

/// The clock a token's expiry is checked against.
pub fn nowSecondsForTest() i64 {
    return nowSeconds();
}

pub const BlossomEdit = enum { none, invalid, busy, unread, full, failed };

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

// re-exports: tuning.zig
pub const copy_refused_reply_key = tuning.copy_refused_reply_key;
pub const ancestor_row_chrome_for_test = tuning.ancestor_row_chrome_for_test;
pub const compose_capacity_for_test = tuning.compose_capacity_for_test;
pub const compose_editor_width_for_test = tuning.compose_editor_width_for_test;
pub const engagementWatchCapForTest = tuning.engagementWatchCapForTest;
pub const feed_prefetch_rows_for_test = tuning.feed_prefetch_rows_for_test;
pub const ghost_row_extent_for_test = tuning.ghost_row_extent_for_test;
pub const gif_target_px_for_test = tuning.gif_target_px_for_test;
pub const link_card_height_bare_for_test = tuning.link_card_height_bare_for_test;
pub const link_card_height_for_test = tuning.link_card_height_for_test;
pub const listening_row_extent_for_test = tuning.listening_row_extent_for_test;
pub const loadOlderForTest = tuning.loadOlderForTest;
pub const maxImageBytesForTest = tuning.maxImageBytesForTest;
pub const maxImageDownloadBytesForTest = tuning.maxImageDownloadBytesForTest;
pub const maxMediaImagesForTest = tuning.maxMediaImagesForTest;
pub const media_target_px_for_test = tuning.media_target_px_for_test;
pub const noteContentCapForTest = tuning.noteContentCapForTest;
pub const note_content_cap_for_test = tuning.note_content_cap_for_test;
pub const outside_row_extent_for_test = tuning.outside_row_extent_for_test;
pub const picture_column_width_for_test = tuning.picture_column_width_for_test;
pub const plaza_version_for_test = tuning.plaza_version_for_test;
pub const quote_picture_width_for_test = tuning.quote_picture_width_for_test;
pub const reply_editor_height_for_test = tuning.reply_editor_height_for_test;
pub const settings_column_width_for_test = tuning.settings_column_width_for_test;
pub const settings_content_width_for_test = tuning.settings_content_width_for_test;
pub const show_more_extent_for_test = tuning.show_more_extent_for_test;
pub const starterPackLenForTest = tuning.starterPackLenForTest;
pub const thread_inset_for_test = tuning.thread_inset_for_test;
pub const updateNewsForTest = tuning.updateNewsForTest;
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
pub const engagementKindsForTest = hiding.engagementKindsForTest;
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
pub const settingsWritesForTest = prefs.settingsWritesForTest;
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
pub const resetUpdateStateForTest = updates.resetUpdateStateForTest;
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
pub const captureArgvLinkForTest = links.captureArgvLinkForTest;
pub const takePendingLinkForTest = links.takePendingLinkForTest;
pub const takeWrittenLinkForTest = links.takeWrittenLinkForTest;
pub const writePendingLinkForTest = links.writePendingLinkForTest;
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
pub const placeFeedStepForTest = places.placeFeedStepForTest;
pub const placeRefusalLine = places.placeRefusalLine;
pub const drainPendingLinkForTest = places.drainPendingLinkForTest;
pub const forgetPlaceFetchForTest = places.forgetPlaceFetchForTest;
pub const drainPendingLink = places.drainPendingLink;
pub const activePlaceIndexForTest = places.activePlaceIndexForTest;
pub const applyActivePlaceLineForTest = places.applyActivePlaceLineForTest;
pub const armPlaceFetchForTest = places.armPlaceFetchForTest;
pub const arrivalInheritsRoomForTest = places.arrivalInheritsRoomForTest;
pub const bootPlaceIndexForTest = places.bootPlaceIndexForTest;
pub const bouncePlaceForTest = places.bouncePlaceForTest;
pub const clearActivePlaceForTest = places.clearActivePlaceForTest;
pub const clearPlaceFeedForTest = places.clearPlaceFeedForTest;
pub const flushPlaceIdsForTest = places.flushPlaceIdsForTest;
pub const forgetPlacesForTest = places.forgetPlacesForTest;
pub const goToOwnPlazaForTest = places.goToOwnPlazaForTest;
pub const keptPlaceSeenLenForTest = places.keptPlaceSeenLenForTest;
pub const markPlaceFetchAppliedForTest = places.markPlaceFetchAppliedForTest;
pub const openKeptPlaceForTest = places.openKeptPlaceForTest;
pub const placeFeedIndexForTest = places.placeFeedIndexForTest;
pub const placeFetchArmedForTest = places.placeFetchArmedForTest;
pub const place_kind_for_test = places.place_kind_for_test;
pub const place_looking_toast_for_test = places.place_looking_toast_for_test;
pub const quoteHintsForTest = places.quoteHintsForTest;
pub const refreshPlaceFetchForTest = places.refreshPlaceFetchForTest;
pub const refreshPlaceFetchNoticeForTest = places.refreshPlaceFetchNoticeForTest;
pub const rememberPlaceIdsForTest = places.rememberPlaceIdsForTest;
pub const resetPlacesForTest = places.resetPlacesForTest;
pub const restoreOpenPlaceForTest = places.restoreOpenPlaceForTest;
pub const resumeVisitForTest = places.resumeVisitForTest;
pub const runStalePlaceFeedWorkerForTest = places.runStalePlaceFeedWorkerForTest;
pub const samePlaceForTest = places.samePlaceForTest;
pub const savePlacesForTest = places.savePlacesForTest;
pub const seedFromKeptPlaceForTest = places.seedFromKeptPlaceForTest;
pub const seedPlaceFeedForTest = places.seedPlaceFeedForTest;
pub const setKeptPlaceSeenLenForTest = places.setKeptPlaceSeenLenForTest;
pub const setPlaceHomeForTest = places.setPlaceHomeForTest;
pub const setPlaceInfoForTest = places.setPlaceInfoForTest;
pub const setPlaceLinkForTest = places.setPlaceLinkForTest;
pub const setPlaceWriteRelayForTest = places.setPlaceWriteRelayForTest;
pub const setRailForTest = places.setRailForTest;
pub const startPlaceFeedForTest = places.startPlaceFeedForTest;
pub const stepPlaceForTest = places.stepPlaceForTest;
pub const togglePlacesRailForTest = places.togglePlacesRailForTest;
pub const visitParsedPlaceForTest = places.visitParsedPlaceForTest;
pub const visitPlaceForTest = places.visitPlaceForTest;
pub const visitPlaceWithFeedForTest = places.visitPlaceWithFeedForTest;
pub const visitingPlaceForTest = places.visitingPlaceForTest;
pub const writePlaceDocumentForTest = places.writePlaceDocumentForTest;
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
pub const addRelayForTest = relay_table.addRelayForTest;
pub const applyRelaysFileForTest = relay_table.applyRelaysFileForTest;
pub const bootstrap_relay_count_for_test = relay_table.bootstrap_relay_count_for_test;
pub const clearRelaysForTest = relay_table.clearRelaysForTest;
pub const forgetRelayRemovalsForTest = relay_table.forgetRelayRemovalsForTest;
pub const formatRelaysFileForTest = relay_table.formatRelaysFileForTest;
pub const indexerChunkForTest = relay_table.indexerChunkForTest;
pub const indexerRelaysForTest = relay_table.indexerRelaysForTest;
pub const maxRelaysForTest = relay_table.maxRelaysForTest;
pub const max_relays_for_test = relay_table.max_relays_for_test;
pub const noteRelayRemovedForTest = relay_table.noteRelayRemovedForTest;
pub const relayReadWriteForTest = relay_table.relayReadWriteForTest;
pub const resetRelaysForTest = relay_table.resetRelaysForTest;
pub const resetRelaysToBootstrapForTest = relay_table.resetRelaysToBootstrapForTest;
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
pub const adoptRelayListForTest = relay_list.adoptRelayListForTest;
pub const canWriteRelayListForTest = relay_list.canWriteRelayListForTest;
pub const clearRelayListPublishForTest = relay_list.clearRelayListPublishForTest;
pub const flushRelayListForTest = relay_list.flushRelayListForTest;
pub const ingestRelayListForTest = relay_list.ingestRelayListForTest;
pub const isReaderNoteForTest = relay_list.isReaderNoteForTest;
pub const markRelaysMineForTest = relay_list.markRelaysMineForTest;
pub const publishRelayListForTest = relay_list.publishRelayListForTest;
pub const relayIsMineForTest = relay_list.relayIsMineForTest;
pub const relayListDueForTest = relay_list.relayListDueForTest;
pub const relayListEditedForTest = relay_list.relayListEditedForTest;
pub const relayListIsOwnedForTest = relay_list.relayListIsOwnedForTest;
pub const relayListPendingForTest = relay_list.relayListPendingForTest;
pub const relayListStampForTest = relay_list.relayListStampForTest;
pub const relayOwnerForTest = relay_list.relayOwnerForTest;
pub const setRelayListStampForTest = relay_list.setRelayListStampForTest;
pub const stageOwnRelayListForTest = relay_list.stageOwnRelayListForTest;
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
pub const RelayRankForTest = routing.RelayRankForTest;
pub const clearRelayRefusalForTest = routing.clearRelayRefusalForTest;
pub const clearRoutesForTest = routing.clearRoutesForTest;
pub const collectUnroutedForTest = routing.collectUnroutedForTest;
pub const discoveredAuthorsCapForTest = routing.discoveredAuthorsCapForTest;
pub const discoveredAuthorsForTest = routing.discoveredAuthorsForTest;
pub const discoveredGenerationForTest = routing.discoveredGenerationForTest;
pub const foldWriteRelaysForTest = routing.foldWriteRelaysForTest;
pub const forgetDiscoveredForTest = routing.forgetDiscoveredForTest;
pub const forgetRefusedRelaysForTest = routing.forgetRefusedRelaysForTest;
pub const indexerAskedLenForTest = routing.indexerAskedLenForTest;
pub const markIndexerAskedForTest = routing.markIndexerAskedForTest;
pub const maxDiscoveredRelaysForTest = routing.maxDiscoveredRelaysForTest;
pub const noteRelayRefusalAtForTest = routing.noteRelayRefusalAtForTest;
pub const outboxRelaysPerAuthorForTest = routing.outboxRelaysPerAuthorForTest;
pub const outboxSubIdForTest = routing.outboxSubIdForTest;
pub const poolAuthorsForTest = routing.poolAuthorsForTest;
pub const poolAuthorsOrAllForTest = routing.poolAuthorsOrAllForTest;
pub const rankRelaySuggestionsForTest = routing.rankRelaySuggestionsForTest;
pub const refusedRelayCountForTest = routing.refusedRelayCountForTest;
pub const relayFetchAllowedForTest = routing.relayFetchAllowedForTest;
pub const relayIsRefusedForTest = routing.relayIsRefusedForTest;
pub const relayRankUrlForTest = routing.relayRankUrlForTest;
pub const relayRankWritersForTest = routing.relayRankWritersForTest;
pub const resetIndexerAskedForTest = routing.resetIndexerAskedForTest;
pub const residualCountForTest = routing.residualCountForTest;
pub const routeCoverageForTest = routing.routeCoverageForTest;
pub const routeCoverageTargetForTest = routing.routeCoverageTargetForTest;
pub const routeFollowUpForTest = routing.routeFollowUpForTest;
pub const routeRecomputeDueForTest = routing.routeRecomputeDueForTest;
pub const routeRecomputeMinMsForTest = routing.routeRecomputeMinMsForTest;
pub const routeSettleMaxMsForTest = routing.routeSettleMaxMsForTest;
pub const routeSettleMsForTest = routing.routeSettleMsForTest;
pub const routedRefusalMsForTest = routing.routedRefusalMsForTest;
pub const routedRefusalStrikesForTest = routing.routedRefusalStrikesForTest;
pub const sameRouteForTest = routing.sameRouteForTest;
pub const sweepRelayListsForTest = routing.sweepRelayListsForTest;
pub const worthEvictingForTest = routing.worthEvictingForTest;
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
pub const askPoolForTest = relay_conn.askPoolForTest;
pub const askableSlotsForTest = relay_conn.askableSlotsForTest;
pub const bunkerWatchSlotForTest = relay_conn.bunkerWatchSlotForTest;
pub const clearOneShotsForTest = relay_conn.clearOneShotsForTest;
pub const clearRelayRttForTest = relay_conn.clearRelayRttForTest;
pub const discoveredWatchBaseForTest = relay_conn.discoveredWatchBaseForTest;
pub const expiredOneShotsForTest = relay_conn.expiredOneShotsForTest;
pub const isFeedSubForTest = relay_conn.isFeedSubForTest;
pub const isOneShotSubForTest = relay_conn.isOneShotSubForTest;
pub const markOneShotCutForTest = relay_conn.markOneShotCutForTest;
pub const oneShotBudgetMsForTest = relay_conn.oneShotBudgetMsForTest;
pub const oneShotSlotsForTest = relay_conn.oneShotSlotsForTest;
pub const oneShotSubPrefixForTest = relay_conn.oneShotSubPrefixForTest;
pub const outboxWokeForTest = relay_conn.outboxWokeForTest;
pub const recordRelayRttForTest = relay_conn.recordRelayRttForTest;
pub const relayStatusConnectedForTest = relay_conn.relayStatusConnectedForTest;
pub const relayStatusQuietForTest = relay_conn.relayStatusQuietForTest;
pub const relayWatchSlotsForTest = relay_conn.relayWatchSlotsForTest;
pub const resetOutboxWokeForTest = relay_conn.resetOutboxWokeForTest;
pub const seatOneShotForTest = relay_conn.seatOneShotForTest;
pub const setRelayQuietForTest = relay_conn.setRelayQuietForTest;
pub const setRelayStatusForTest = relay_conn.setRelayStatusForTest;
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
pub const ownRecordCreatedAtForTest = store_glue.ownRecordCreatedAtForTest;
pub const ownRecordReadsForTest = store_glue.ownRecordReadsForTest;
pub const plazaIngestForTest = store_glue.plazaIngestForTest;
pub const plazaIngestFromForTest = store_glue.plazaIngestFromForTest;
pub const plazaIngestVerifiedForTest = store_glue.plazaIngestVerifiedForTest;
pub const resetOwnRecordReadsForTest = store_glue.resetOwnRecordReadsForTest;
pub const ownListBackups = store_glue.ownListBackups;
pub const ownRecordCreatedAt = store_glue.ownRecordCreatedAt;
pub const ownRecordExists = store_glue.ownRecordExists;
pub const plazaIngest = store_glue.plazaIngest;
pub const plazaIngestFrom = store_glue.plazaIngestFrom;

// re-exports: feed_state.zig
pub const feedKeyForTest = feed_state.feedKeyForTest;
pub const feedSinceForTest = feed_state.feedSinceForTest;
pub const invalidateFeedForTest = feed_state.invalidateFeedForTest;
pub const noteFeedArrivalForTest = feed_state.noteFeedArrivalForTest;
pub const overflowFeedArrivalsForTest = feed_state.overflowFeedArrivalsForTest;
pub const profileParsesForTest = feed_state.profileParsesForTest;
pub const reconcileForTest = feed_state.reconcileForTest;
pub const reserveFeedForTest = feed_state.reserveFeedForTest;
pub const resetFeedChangeDetectionForTest = feed_state.resetFeedChangeDetectionForTest;
pub const setFeedNewestForTest = feed_state.setFeedNewestForTest;
pub const setIdentityForTest = feed_state.setIdentityForTest;
pub const setStoreForTest = feed_state.setStoreForTest;
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
pub const arrivalTableForTest = thread_model.arrivalTableForTest;
pub const splitByFollowGraphForTest = thread_model.splitByFollowGraphForTest;
pub const stampArrivalForTest = thread_model.stampArrivalForTest;
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
pub const commentEventForTest = note_build.commentEventForTest;
pub const comment_kind = note_build.comment_kind;
pub const copyDisplayText = note_build.copyDisplayText;
pub const copyDisplayTextForTest = note_build.copyDisplayTextForTest;
pub const findQuoteRef = note_build.findQuoteRef;
pub const findQuoteRefForTest = note_build.findQuoteRefForTest;
pub const firstImageUrl = note_build.firstImageUrl;
pub const foldMathAlnum = note_build.foldMathAlnum;
pub const foldMathAlnumForTest = note_build.foldMathAlnumForTest;
pub const generic_repost_kind = note_build.generic_repost_kind;
pub const imetaAspect = note_build.imetaAspect;
pub const imetaFor = note_build.imetaFor;
pub const invisibleForDisplay = note_build.invisibleForDisplay;
pub const invisibleForDisplayForTest = note_build.invisibleForDisplayForTest;
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
pub const titleInto = note_build.titleInto;
pub const titleOf = note_build.titleOf;
pub const urlHost = note_build.urlHost;
pub const utf8SafeLen = note_build.utf8SafeLen;

// re-exports: profile_cache.zig
pub const agePlaceLogoForTest = profile_cache.agePlaceLogoForTest;
pub const avatarFallbackStateForTest = profile_cache.avatarFallbackStateForTest;
pub const avatarPartialCountForTest = profile_cache.avatarPartialCountForTest;
pub const buildRoutedFiltersForTest = profile_cache.buildRoutedFiltersForTest;
pub const deliverAvatarResponseForTest = profile_cache.deliverAvatarResponseForTest;
pub const fillProfileTextForTest = profile_cache.fillProfileTextForTest;
pub const forgetWantedProfilesForTest = profile_cache.forgetWantedProfilesForTest;
pub const imageClockForTest = profile_cache.imageClockForTest;
pub const isProfileWantedForTest = profile_cache.isProfileWantedForTest;
pub const markAvatarWantedForTest = profile_cache.markAvatarWantedForTest;
pub const markPlaceLogoSeenForTest = profile_cache.markPlaceLogoSeenForTest;
pub const profileHintCountForTest = profile_cache.profileHintCountForTest;
pub const profileWantedForTest = profile_cache.profileWantedForTest;
pub const refreshProfilesForTest = profile_cache.refreshProfilesForTest;
pub const resetProfilesForTest = profile_cache.resetProfilesForTest;
pub const resetWantedProfilesForTest = profile_cache.resetWantedProfilesForTest;
pub const setProfileAvatarForTest = profile_cache.setProfileAvatarForTest;
pub const setProfileNameForTest = profile_cache.setProfileNameForTest;
pub const setProfileNip05ForTest = profile_cache.setProfileNip05ForTest;
pub const setProfilePictureForTest = profile_cache.setProfilePictureForTest;
pub const wantProfileForTest = profile_cache.wantProfileForTest;
pub const wantProfilesAheadForTest = profile_cache.wantProfilesAheadForTest;
pub const wantedProfileCountForTest = profile_cache.wantedProfileCountForTest;
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
pub const verifiedNip05ForTest = person_card.verifiedNip05ForTest;
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
pub const addressDialsPerRoundForTest = quote_cache.addressDialsPerRoundForTest;
pub const advanceQuoteRoundForTest = quote_cache.advanceQuoteRoundForTest;
pub const dropQuoteForTest = quote_cache.dropQuoteForTest;
pub const fillQuoteForTest = quote_cache.fillQuoteForTest;
pub const quoteBackoffRoundsForTest = quote_cache.quoteBackoffRoundsForTest;
pub const quoteForTest = quote_cache.quoteForTest;
pub const quoteHintCountForTest = quote_cache.quoteHintCountForTest;
pub const quoteTextForTest = quote_cache.quoteTextForTest;
pub const rearmWantedQuotesForTest = quote_cache.rearmWantedQuotesForTest;
pub const refreshQuotesForTest = quote_cache.refreshQuotesForTest;
pub const requestWantedQuotesForTest = quote_cache.requestWantedQuotesForTest;
pub const requeueMissingQuotesForTest = quote_cache.requeueMissingQuotesForTest;
pub const resetQuotesForTest = quote_cache.resetQuotesForTest;
pub const seedQuoteForTest = quote_cache.seedQuoteForTest;
pub const wantQuoteForTest = quote_cache.wantQuoteForTest;
pub const wantQuoteHintedForTest = quote_cache.wantQuoteHintedForTest;
pub const warnQuoteForTest = quote_cache.warnQuoteForTest;
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
pub const addressDialledForTest = addresses.addressDialledForTest;
pub const addressFetchArmedForTest = addresses.addressFetchArmedForTest;
pub const addressForTest = addresses.addressForTest;
pub const addressKeyForTest = addresses.addressKeyForTest;
pub const addressPoolBatchForTest = addresses.addressPoolBatchForTest;
pub const addressPoolFiltersForTest = addresses.addressPoolFiltersForTest;
pub const addressRegisteredForTest = addresses.addressRegisteredForTest;
pub const forgetAddressFetchForTest = addresses.forgetAddressFetchForTest;
pub const newestAddressIdForTest = addresses.newestAddressIdForTest;
pub const openAddressedArticleForTest = addresses.openAddressedArticleForTest;
pub const refreshAddressFetchForTest = addresses.refreshAddressFetchForTest;
pub const resetAddressesForTest = addresses.resetAddressesForTest;
pub const storedWriteRelaysForTest = addresses.storedWriteRelaysForTest;
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
pub const clearLinkPreviewsForTest = link_preview.clearLinkPreviewsForTest;
pub const linkRequestedForTest = link_preview.linkRequestedForTest;
pub const scanLinkFetchesForTest = link_preview.scanLinkFetchesForTest;
pub const seedLinkForTest = link_preview.seedLinkForTest;
pub const setLinkPreviewForTest = link_preview.setLinkPreviewForTest;
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
pub const hintsForTest = relay_hints.hintsForTest;
pub const isHintableRelayForTest = relay_hints.isHintableRelayForTest;
pub const noteAddressForTest = relay_hints.noteAddressForTest;
pub const note_address_cap_for_test = relay_hints.note_address_cap_for_test;
pub const profileAddressForTest = relay_hints.profileAddressForTest;
pub const recordSeenOnForTest = relay_hints.recordSeenOnForTest;
pub const resetSeenOnForTest = relay_hints.resetSeenOnForTest;
pub const seenUrlCountForTest = relay_hints.seenUrlCountForTest;
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
pub const countEngagementForTest = engagement.countEngagementForTest;
pub const isLikedForTest = engagement.isLikedForTest;
pub const likeReactionIdForTest = engagement.likeReactionIdForTest;
pub const rememberLikeForTest = engagement.rememberLikeForTest;
pub const repostedByMeForTest = engagement.repostedByMeForTest;
pub const resetEngagementForTest = engagement.resetEngagementForTest;
pub const resetLikesForTest = engagement.resetLikesForTest;
pub const setZapMsatForTest = engagement.setZapMsatForTest;
pub const zap_msat_ceiling_for_test = engagement.zap_msat_ceiling_for_test;
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
pub const bakeBodyForTest = inbox.bakeBodyForTest;
pub const collapseEventRefsForTest = inbox.collapseEventRefsForTest;
pub const forgetInboxBodyStampForTest = inbox.forgetInboxBodyStampForTest;
pub const inboxAddForTest = inbox.inboxAddForTest;
pub const inboxLenForTest = inbox.inboxLenForTest;
pub const inboxVerbForTest = inbox.inboxVerbForTest;
pub const loadInboxForTest = inbox.loadInboxForTest;
pub const resetInboxForTest = inbox.resetInboxForTest;
pub const resolveInboxBodiesForTest = inbox.resolveInboxBodiesForTest;
pub const saveInboxForTest = inbox.saveInboxForTest;
pub const seedInboxUnreadForTest = inbox.seedInboxUnreadForTest;
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
pub const avatarUrlForTest = image_cache.avatarUrlForTest;
pub const feedImageUrlForTest = image_cache.feedImageUrlForTest;
pub const mediaUrlForTest = image_cache.mediaUrlForTest;
pub const pictureWarmedForTest = image_cache.pictureWarmedForTest;
pub const stbCanDecodeForTest = image_cache.stbCanDecodeForTest;
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
pub const acquireImageIdForTest = image_pool.acquireImageIdForTest;
pub const assignAvatarSlotsForTest = image_pool.assignAvatarSlotsForTest;
pub const beginImagePassForTest = image_pool.beginImagePassForTest;
pub const chooseImageIdForTest = image_pool.chooseImageIdForTest;
pub const imageIdOwnerNameForTest = image_pool.imageIdOwnerNameForTest;
pub const imageIdTakeableForTest = image_pool.imageIdTakeableForTest;
pub const placeLogoUntouchableForTest = image_pool.placeLogoUntouchableForTest;
pub const resetWarmForTest = image_pool.resetWarmForTest;
pub const touchMediaClockForTest = image_pool.touchMediaClockForTest;
pub const warmAheadForTest = image_pool.warmAheadForTest;
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
pub const appendAvatarSliceForTest = feed_media.appendAvatarSliceForTest;
pub const appendMediaSliceForTest = feed_media.appendMediaSliceForTest;
pub const claimMediaSlotForTest = feed_media.claimMediaSlotForTest;
pub const deliverMediaResponseForTest = feed_media.deliverMediaResponseForTest;
pub const hostOfForTest = feed_media.hostOfForTest;
pub const markMediaFailedForTest = feed_media.markMediaFailedForTest;
pub const markMediaLoadedForTest = feed_media.markMediaLoadedForTest;
pub const mediaAttemptsForTest = feed_media.mediaAttemptsForTest;
pub const mediaFallbackStateForTest = feed_media.mediaFallbackStateForTest;
pub const mediaIdleForTest = feed_media.mediaIdleForTest;
pub const mediaKeyForTest = feed_media.mediaKeyForTest;
pub const mediaPartialCountForTest = feed_media.mediaPartialCountForTest;
pub const mediaPartialForTest = feed_media.mediaPartialForTest;
pub const mediaSlotNoteIdsForTest = feed_media.mediaSlotNoteIdsForTest;
pub const mediaSlotStateForTest = feed_media.mediaSlotStateForTest;
pub const mediaSlotWantedForTest = feed_media.mediaSlotWantedForTest;
pub const proxyRefusedCountForTest = feed_media.proxyRefusedCountForTest;
pub const quoteMediaKeyForTest = feed_media.quoteMediaKeyForTest;
pub const rangeHeaderForTest = feed_media.rangeHeaderForTest;
pub const resetMediaForTest = feed_media.resetMediaForTest;
pub const scanMediaFetchesForTest = feed_media.scanMediaFetchesForTest;
pub const setMediaSlotHostForTest = feed_media.setMediaSlotHostForTest;
pub const setVisibleRangeForTest = feed_media.setVisibleRangeForTest;
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
pub const confirmStartFreshForTest = own_lists.confirmStartFreshForTest;
pub const contactsConfirmedAbsentForTest = own_lists.contactsConfirmedAbsentForTest;
pub const forgetOwnListMemoForTest = own_lists.forgetOwnListMemoForTest;
pub const haveOwnContactListForTest = own_lists.haveOwnContactListForTest;
pub const identityMintedForTest = own_lists.identityMintedForTest;
pub const needsFreshConsentForTest = own_lists.needsFreshConsentForTest;
pub const noHistoryKnownForTest = own_lists.noHistoryKnownForTest;
pub const noListToastsForTest = own_lists.noListToastsForTest;
pub const noteContactsAnsweredByForTest = own_lists.noteContactsAnsweredByForTest;
pub const noteContactsAnsweredFromForTest = own_lists.noteContactsAnsweredFromForTest;
pub const noteOwnOutboxForTest = own_lists.noteOwnOutboxForTest;
pub const ownListsWaitedForTest = own_lists.ownListsWaitedForTest;
pub const ownRelaysAllFinishedForTest = own_lists.ownRelaysAllFinishedForTest;
pub const retryOwnListsReadForTest = own_lists.retryOwnListsReadForTest;
pub const setIdentityMintedForTest = own_lists.setIdentityMintedForTest;
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
pub const applyUndoForTest = follows.applyUndoForTest;
pub const armUndoForTest = follows.armUndoForTest;
pub const armUnlikeUndoForTest = follows.armUnlikeUndoForTest;
pub const clearPendingFollowBaseForTest = follows.clearPendingFollowBaseForTest;
pub const countPeopleForTest = follows.countPeopleForTest;
pub const followSetForTest = follows.followSetForTest;
pub const followsFromTagsForTest = follows.followsFromTagsForTest;
pub const forgetFollowsForTest = follows.forgetFollowsForTest;
pub const ingestContactListForTest = follows.ingestContactListForTest;
pub const loadFollowsFromStoreForTest = follows.loadFollowsFromStoreForTest;
pub const pendingFollowCountForTest = follows.pendingFollowCountForTest;
pub const setFollowsForTest = follows.setFollowsForTest;
pub const setHomeScopeForTest = follows.setHomeScopeForTest;
pub const setPendingFollowBaseForTest = follows.setPendingFollowBaseForTest;
pub const shrinkAllowedForTest = follows.shrinkAllowedForTest;
pub const writeFollowForTest = follows.writeFollowForTest;
pub const FollowWrite = follows.FollowWrite;
pub const HomeScope = follows.HomeScope;
pub const PendingUndo = follows.PendingUndo;
pub const applyUndo = follows.applyUndo;
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
pub const forgetMutesForTest = mutes.forgetMutesForTest;
pub const ingestMuteListForTest = mutes.ingestMuteListForTest;
pub const loadMutesFromStoreForTest = mutes.loadMutesFromStoreForTest;
pub const privateMutesForTest = mutes.privateMutesForTest;
pub const sayMuteWriteForTest = mutes.sayMuteWriteForTest;
pub const setMutesForTest = mutes.setMutesForTest;
pub const writeMuteForTest = mutes.writeMuteForTest;
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
pub const parkSealAnswerForTest = bookmarks.parkSealAnswerForTest;
pub const lastSealPlaintextForTest = bookmarks.lastSealPlaintextForTest;
pub const finishPrivateBookmarkForTest = bookmarks.finishPrivateBookmarkForTest;
pub const forgetBookmarksForTest = bookmarks.forgetBookmarksForTest;
pub const lastSealedForTest = bookmarks.lastSealedForTest;
pub const loadBookmarksFromStoreForTest = bookmarks.loadBookmarksFromStoreForTest;
pub const sayBookmarkWriteForTest = bookmarks.sayBookmarkWriteForTest;
pub const sealPrivateBookmarkForTest = bookmarks.sealPrivateBookmarkForTest;
pub const writeBookmarkForTest = bookmarks.writeBookmarkForTest;
pub const writePrivateBookmarkForTest = bookmarks.writePrivateBookmarkForTest;
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
pub const privateHalfPlainCapForTest = private_lists.privateHalfPlainCapForTest;
pub const parkSealAnswer = private_lists.parkSealAnswer;
pub const deliverPrivateSealForTest = private_lists.deliverPrivateSealForTest;
pub const privateSealKeyForTest = private_lists.privateSealKeyForTest;
pub const privateSealActiveForTest = private_lists.privateSealActiveForTest;
pub const forgetPrivateSealForTest = private_lists.forgetPrivateSealForTest;
pub const forgetPrivateSeal = private_lists.forgetPrivateSeal;
pub const privateSealKey = private_lists.privateSealKey;
pub const answerPrivateHalfForTest = private_lists.answerPrivateHalfForTest;
pub const askPrivateHalfForTest = private_lists.askPrivateHalfForTest;
pub const claimPrivateHalfPendingForTest = private_lists.claimPrivateHalfPendingForTest;
pub const deliverPrivateHalfKeyedForTest = private_lists.deliverPrivateHalfKeyedForTest;
pub const endRemoteHalfAskForTest = private_lists.endRemoteHalfAskForTest;
pub const failRemoteHalfForTest = private_lists.failRemoteHalfForTest;
pub const forgetPrivateHalvesForTest = private_lists.forgetPrivateHalvesForTest;
pub const markIdleHalvesAskedForTest = private_lists.markIdleHalvesAskedForTest;
pub const openPrivateHalfForTest = private_lists.openPrivateHalfForTest;
pub const parkRemoteHalfAnswerForCiphertextForTest = private_lists.parkRemoteHalfAnswerForCiphertextForTest;
pub const parkRemoteHalfAnswerForTest = private_lists.parkRemoteHalfAnswerForTest;
pub const privateHalfAskKeyForTest = private_lists.privateHalfAskKeyForTest;
pub const privateHalfGateNameForTest = private_lists.privateHalfGateNameForTest;
pub const privateHalfIsReadableForTest = private_lists.privateHalfIsReadableForTest;
pub const privateHalfRetryAtForTest = private_lists.privateHalfRetryAtForTest;
pub const privateHalfRetryDelayForTest = private_lists.privateHalfRetryDelayForTest;
pub const privateHalfStateForTest = private_lists.privateHalfStateForTest;
pub const rearmPrivateHalvesForTest = private_lists.rearmPrivateHalvesForTest;
pub const slotIdForTest = private_lists.slotIdForTest;
pub const timeoutRemoteHalfForTest = private_lists.timeoutRemoteHalfForTest;
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
pub const lastPublishedRouteExclusiveForTest = keyholder.lastPublishedRouteExclusiveForTest;
pub const lastPublishedRouteRelaysForTest = keyholder.lastPublishedRouteRelaysForTest;
pub const requestHelperSignRoutedForTest = keyholder.requestHelperSignRoutedForTest;
pub const answerHelperSignForTest = keyholder.answerHelperSignForTest;
pub const ceremonyCanTakeKeyForTest = keyholder.ceremonyCanTakeKeyForTest;
pub const ceremonyOwesNameForTest = keyholder.ceremonyOwesNameForTest;
pub const clearIdentityForTest = keyholder.clearIdentityForTest;
pub const clearLastPublishedForTest = keyholder.clearLastPublishedForTest;
pub const clearLastPublishedTagsForTest = keyholder.clearLastPublishedTagsForTest;
pub const clearLoggedOutLatchForTest = keyholder.clearLoggedOutLatchForTest;
pub const deliverHelperPubkeyForTest = keyholder.deliverHelperPubkeyForTest;
pub const deliverHelperSignedForTest = keyholder.deliverHelperSignedForTest;
pub const exeDirForTest = keyholder.exeDirForTest;
pub const expireHelperSignForTest = keyholder.expireHelperSignForTest;
pub const forgetLastPublishedForTest = keyholder.forgetLastPublishedForTest;
pub const handleHelperPubkeyForTest = keyholder.handleHelperPubkeyForTest;
pub const handleHelperSignedForTest = keyholder.handleHelperSignedForTest;
pub const handleNotaryExitedForTest = keyholder.handleNotaryExitedForTest;
pub const helperPortForTest = keyholder.helperPortForTest;
pub const helperReachableForTest = keyholder.helperReachableForTest;
pub const helperSecretForTest = keyholder.helperSecretForTest;
pub const helperSetupMayFireForTest = keyholder.helperSetupMayFireForTest;
pub const helperSetupPendingForTest = keyholder.helperSetupPendingForTest;
pub const helperSetupQueuedForTest = keyholder.helperSetupQueuedForTest;
pub const helperSignNoticeForTest = keyholder.helperSignNoticeForTest;
pub const helperSignPendingForTest = keyholder.helperSignPendingForTest;
pub const helperSignRestorableForTest = keyholder.helperSignRestorableForTest;
pub const helperSignTimeoutMillisForTest = keyholder.helperSignTimeoutMillisForTest;
pub const helperSignTimeoutSecondsForTest = keyholder.helperSignTimeoutSecondsForTest;
pub const helperStateForTest = keyholder.helperStateForTest;
pub const helperTokenForTest = keyholder.helperTokenForTest;
pub const holdHelperSignForTest = keyholder.holdHelperSignForTest;
pub const lastPublishedForTest = keyholder.lastPublishedForTest;
pub const lastPublishedTagsForTest = keyholder.lastPublishedTagsForTest;
pub const loggedOutForTest = keyholder.loggedOutForTest;
pub const loggedOutPubkeyForTest = keyholder.loggedOutPubkeyForTest;
pub const mintHelperSecretForTest = keyholder.mintHelperSecretForTest;
pub const releaseHelperSignForTest = keyholder.releaseHelperSignForTest;
pub const requestHelperSignForTest = keyholder.requestHelperSignForTest;
pub const resolveSiblingForTest = keyholder.resolveSiblingForTest;
pub const restoreHelperForTest = keyholder.restoreHelperForTest;
pub const scanHelperSignForTest = keyholder.scanHelperSignForTest;
pub const setCeremonyForTest = keyholder.setCeremonyForTest;
pub const setHelperPortForTest = keyholder.setHelperPortForTest;
pub const setHelperReadyForTest = keyholder.setHelperReadyForTest;
pub const setHelperUnreachableForTest = keyholder.setHelperUnreachableForTest;
pub const setKeyholderMissingForTest = keyholder.setKeyholderMissingForTest;
pub const setNotaryWindowFoundForTest = keyholder.setNotaryWindowFoundForTest;
pub const setRemoteStateForTest = keyholder.setRemoteStateForTest;
pub const setSignerKindForTest = keyholder.setSignerKindForTest;
pub const setSignerKindHelperForTest = keyholder.setSignerKindHelperForTest;
pub const setSignerKindLocalForTest = keyholder.setSignerKindLocalForTest;
pub const signerKindNameForTest = keyholder.signerKindNameForTest;
pub const signerReadyForTest = keyholder.signerReadyForTest;
pub const silenceTestSignerForTest = keyholder.silenceTestSignerForTest;
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
pub const signLandedForTest = remote_signer.signLandedForTest;
pub const takeAnsweredForTest = remote_signer.takeAnsweredForTest;
pub const pendingSignIdForKindForTest = remote_signer.pendingSignIdForKindForTest;
pub const listWriteInFlight = remote_signer.listWriteInFlight;
pub const plausibleSealForTest = remote_signer.plausibleSealForTest;
pub const nip44CiphertextLenForTest = remote_signer.nip44CiphertextLenForTest;
pub const max_private_cipher_len = remote_signer.max_private_cipher_len;
pub const plausibleSeal = remote_signer.plausibleSeal;
pub const max_private_plain_len = remote_signer.max_private_plain_len;
pub const remoteClientSecretLingersForTest = remote_signer.remoteClientSecretLingersForTest;
pub const wipeRemoteSecrets = remote_signer.wipeRemoteSecrets;
pub const remoteClientSecretForTest = remote_signer.remoteClientSecretForTest;
pub const pendingSignIdForTest = remote_signer.pendingSignIdForTest;
pub const RemoteMethodForTest = remote_signer.RemoteMethodForTest;
pub const answerBunkerConnectForTest = remote_signer.answerBunkerConnectForTest;
pub const beginBunkerConnectForTest = remote_signer.beginBunkerConnectForTest;
pub const bumpRemoteGenerationForTest = remote_signer.bumpRemoteGenerationForTest;
pub const clearPendingForTest = remote_signer.clearPendingForTest;
pub const connectWentQuietForTest = remote_signer.connectWentQuietForTest;
pub const deliverNip46ResponseForTest = remote_signer.deliverNip46ResponseForTest;
pub const driveBunkerConnectForTest = remote_signer.driveBunkerConnectForTest;
pub const failPendingByContentForTest = remote_signer.failPendingByContentForTest;
pub const failPendingForTest = remote_signer.failPendingForTest;
pub const halfInboxHoldsForTest = remote_signer.halfInboxHoldsForTest;
pub const pendingConnectIdForTest = remote_signer.pendingConnectIdForTest;
pub const registerPendingForTest = remote_signer.registerPendingForTest;
pub const registerRemoteHalfAskForTest = remote_signer.registerRemoteHalfAskForTest;
pub const remoteDecryptMethodNameForTest = remote_signer.remoteDecryptMethodNameForTest;
pub const remoteGenerationForTest = remote_signer.remoteGenerationForTest;
pub const remoteSecretHeldForTest = remote_signer.remoteSecretHeldForTest;
pub const remoteSignNoticeForTest = remote_signer.remoteSignNoticeForTest;
pub const resetBunkerConnectForTest = remote_signer.resetBunkerConnectForTest;
pub const scanPendingRemoteForTest = remote_signer.scanPendingRemoteForTest;
pub const setRemotePubkeyForTest = remote_signer.setRemotePubkeyForTest;
pub const takePendingContentForTest = remote_signer.takePendingContentForTest;
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
pub const refusedReplyClipForTest = drafts.refusedReplyClipForTest;
pub const flushRefusedReplyClip = drafts.flushRefusedReplyClip;
pub const putBackRefusedReply = drafts.putBackRefusedReply;
pub const draftWarningForModelForTest = drafts.draftWarningForModelForTest;
pub const keptReplyDraftForTest = drafts.keptReplyDraftForTest;
pub const loadDraftIntoForTest = drafts.loadDraftIntoForTest;
pub const writeDraftForTest = drafts.writeDraftForTest;
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
pub const performLogoutForTest = session.performLogoutForTest;
pub const legacyKeyOnDisk = session.legacyKeyOnDisk;
pub const performLogout = session.performLogout;
pub const persistSession = session.persistSession;
pub const plazaDir = session.plazaDir;
pub const restoreSession = session.restoreSession;

// re-exports: own_profile.zig
pub const askVerdictForTest = own_profile.askVerdictForTest;
pub const forgetOwnProfileAnswerForTest = own_profile.forgetOwnProfileAnswerForTest;
pub const forgetOwnRecordAnswersForTest = own_profile.forgetOwnRecordAnswersForTest;
pub const mergeNameJsonForTest = own_profile.mergeNameJsonForTest;
pub const mergeProfileJsonForTest = own_profile.mergeProfileJsonForTest;
pub const noteOwnContactsAnsweredForTest = own_profile.noteOwnContactsAnsweredForTest;
pub const ownProfileAnsweredForTest = own_profile.ownProfileAnsweredForTest;
pub const ownRecordContentForTest = own_profile.ownRecordContentForTest;
pub const ownRecordTagsJoinedForTest = own_profile.ownRecordTagsJoinedForTest;
pub const publishNameForTest = own_profile.publishNameForTest;
pub const recordOwnProfileAnswerForTest = own_profile.recordOwnProfileAnswerForTest;
pub const replayPendingForTest = own_profile.replayPendingForTest;
pub const seedProfileFieldsForTest = own_profile.seedProfileFieldsForTest;
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
pub const pickRefusedForTest = uploads.pickRefusedForTest;
pub const postWaitsForTest = uploads.postWaitsForTest;
pub const pickRefusedFor = uploads.pickRefusedFor;
pub const composerPictureUnfinished = uploads.composerPictureUnfinished;
pub const postWaitsForPicture = uploads.postWaitsForPicture;
pub const setProfileUploadUnsavedForTest = uploads.setProfileUploadUnsavedForTest;
pub const ageUploadTokenForTest = uploads.ageUploadTokenForTest;
pub const appendPictureToDraftForTest = uploads.appendPictureToDraftForTest;
pub const driveUploadForTest = uploads.driveUploadForTest;
pub const dropUploadForTest = uploads.dropUploadForTest;
pub const forgetUploadedForTest = uploads.forgetUploadedForTest;
pub const parkUploadSignForTest = uploads.parkUploadSignForTest;
pub const rememberUploadedForTest = uploads.rememberUploadedForTest;
pub const setPickPathForTest = uploads.setPickPathForTest;
pub const tokenNamesFileForTest = uploads.tokenNamesFileForTest;
pub const uploadCancelForTest = uploads.uploadCancelForTest;
pub const uploadGoForTest = uploads.uploadGoForTest;
pub const uploadMessageForTest = uploads.uploadMessageForTest;
pub const uploadPickForTest = uploads.uploadPickForTest;
pub const uploadRetryForTest = uploads.uploadRetryForTest;
pub const uploadSentBytesForTest = uploads.uploadSentBytesForTest;
pub const uploadStateForTest = uploads.uploadStateForTest;
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
pub const blossomOwnListForTest = media_servers.blossomOwnListForTest;
pub const blossomProbeWantedForTest = media_servers.blossomProbeWantedForTest;
pub const blossomServersForTest = media_servers.blossomServersForTest;
pub const forgetBlossomForTest = media_servers.forgetBlossomForTest;
pub const loadBlossomFromStoreForTest = media_servers.loadBlossomFromStoreForTest;
pub const markBlossomProbeCleanForTest = media_servers.markBlossomProbeCleanForTest;
pub const probeReplyAnswersForTest = media_servers.probeReplyAnswersForTest;
pub const setBlossomServersForTest = media_servers.setBlossomServersForTest;
pub const writeBlossomServersForTest = media_servers.writeBlossomServersForTest;
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
pub const uploadButtonsForTest = view_upload.uploadButtonsForTest;
pub const uploadStrip = view_upload.uploadStrip;

// re-exports: compose.zig
pub const signAndPublishWithUndoForTest = compose.signAndPublishWithUndoForTest;
pub const contentTagsForTest = compose.contentTagsForTest;
pub const countOutboxRoundForTest = compose.countOutboxRoundForTest;
pub const deletableTargetKindForTest = compose.deletableTargetKindForTest;
pub const drivePendingIntentForTest = compose.drivePendingIntentForTest;
pub const dupeTagsForTest = compose.dupeTagsForTest;
pub const heldRouteRelaysForTest = compose.heldRouteRelaysForTest;
pub const holdPostForTest = compose.holdPostForTest;
pub const holdReplyForTest = compose.holdReplyForTest;
pub const ingestAndPublishForTest = compose.ingestAndPublishForTest;
pub const markOutboxRoundForTest = compose.markOutboxRoundForTest;
pub const markRepostedByMeForTest = compose.markRepostedByMeForTest;
pub const notifiedByForTest = compose.notifiedByForTest;
pub const postDelayForTest = compose.postDelayForTest;
pub const postHeldForTest = compose.postHeldForTest;
pub const replyHeldForTest = compose.replyHeldForTest;
pub const setPostDelayForTest = compose.setPostDelayForTest;
pub const signAndPublishForTest = compose.signAndPublishForTest;
pub const submitPostForTest = compose.submitPostForTest;
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
pub const clearOutboxOwnerForTest = outbox.clearOutboxOwnerForTest;
pub const collectOutboxDueForTest = outbox.collectOutboxDueForTest;
pub const enqueueOutboxForTest = outbox.enqueueOutboxForTest;
pub const forgetOutboxAcksForTest = outbox.forgetOutboxAcksForTest;
pub const loadOutboxForTest = outbox.loadOutboxForTest;
pub const outboxAuthorAtForTest = outbox.outboxAuthorAtForTest;
pub const outboxHasRoomForTest = outbox.outboxHasRoomForTest;
pub const outboxOwnerForTest = outbox.outboxOwnerForTest;
pub const outboxRetryDelayForTest = outbox.outboxRetryDelayForTest;
pub const outboxRoundsForTest = outbox.outboxRoundsForTest;
pub const outboxStateForTest = outbox.outboxStateForTest;
pub const outboxUsedSlotsForTest = outbox.outboxUsedSlotsForTest;
pub const outbox_cap_for_test = outbox.outbox_cap_for_test;
pub const outbox_sent_linger_for_test = outbox.outbox_sent_linger_for_test;
pub const poolHasRelayForTest = outbox.poolHasRelayForTest;
pub const recordOutboxAckForTest = outbox.recordOutboxAckForTest;
pub const resetOutboxForTest = outbox.resetOutboxForTest;
pub const rounds_before_stuck_for_test = outbox.rounds_before_stuck_for_test;
pub const routeForOpenPlaceRelaysForTest = outbox.routeForOpenPlaceRelaysForTest;
pub const saveOutboxForTest = outbox.saveOutboxForTest;
pub const sweepOutboxForTest = outbox.sweepOutboxForTest;
pub const syncOutboxOwnerForTest = outbox.syncOutboxOwnerForTest;
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
pub const handleNip05FoundForTest = people_search.handleNip05FoundForTest;
pub const nip05AskKeyForTest = people_search.nip05AskKeyForTest;
pub const nip05AskedForTest = people_search.nip05AskedForTest;
pub const searchAcceptForTest = people_search.searchAcceptForTest;
pub const searchArrivedForTest = people_search.searchArrivedForTest;
pub const searchAskedForTest = people_search.searchAskedForTest;
pub const searchGenForTest = people_search.searchGenForTest;
pub const searchIndexLenForTest = people_search.searchIndexLenForTest;
pub const searchIndexRefreshForTest = people_search.searchIndexRefreshForTest;
pub const searchRelayCountForTest = people_search.searchRelayCountForTest;
pub const searchRelayUrlForTest = people_search.searchRelayUrlForTest;
pub const searchResetForTest = people_search.searchResetForTest;
pub const searchRowCountForTest = people_search.searchRowCountForTest;
pub const searchRowLocalForTest = people_search.searchRowLocalForTest;
pub const searchRowPubkeyForTest = people_search.searchRowPubkeyForTest;
pub const searchRowRelaysForTest = people_search.searchRowRelaysForTest;
pub const searchSetStatusForTest = people_search.searchSetStatusForTest;
pub const searchTickForTest = people_search.searchTickForTest;
pub const search_inbox_cap_for_test = people_search.search_inbox_cap_for_test;
pub const search_scan_page_for_test = people_search.search_scan_page_for_test;
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
pub const loadAtProfileBottomForTest = profile_notes.loadAtProfileBottomForTest;
pub const loadOlderProfileForTest = profile_notes.loadOlderProfileForTest;
pub const noteProfileReachForTest = profile_notes.noteProfileReachForTest;
pub const profileEndReachedForTest = profile_notes.profileEndReachedForTest;
pub const profileOlderAskForTest = profile_notes.profileOlderAskForTest;
pub const profileReachForTest = profile_notes.profileReachForTest;
pub const profileRoundEndedForTest = profile_notes.profileRoundEndedForTest;
pub const profileTargetsForTest = profile_notes.profileTargetsForTest;
pub const resetProfileEndForTest = profile_notes.resetProfileEndForTest;
pub const roundReachForTest = profile_notes.roundReachForTest;
pub const setProfileEndForTest = profile_notes.setProfileEndForTest;
pub const writeRelaysOfForTest = profile_notes.writeRelaysOfForTest;
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
pub const forgetStaleReturn = navigation.forgetStaleReturn;
pub const closeThreadForTest = navigation.closeThreadForTest;
pub const enterProfileForTest = navigation.enterProfileForTest;
pub const enterThreadForTest = navigation.enterThreadForTest;
pub const eventFetchArmedForTest = navigation.eventFetchArmedForTest;
pub const feedEndLatchesForTest = navigation.feedEndLatchesForTest;
pub const finishLevelFetchForTest = navigation.finishLevelFetchForTest;
pub const forgetEventFetchForTest = navigation.forgetEventFetchForTest;
pub const goHomeForTest = navigation.goHomeForTest;
pub const markThreadFetchDoneForTest = navigation.markThreadFetchDoneForTest;
pub const openBookmarksForTest = navigation.openBookmarksForTest;
pub const openEventForTest = navigation.openEventForTest;
pub const openTopicForTest = navigation.openTopicForTest;
pub const refreshEventFetchForTest = navigation.refreshEventFetchForTest;
pub const resetFeedEndForTest = navigation.resetFeedEndForTest;
pub const setFeedEndForTest = navigation.setFeedEndForTest;
pub const setFirstProfileFetchOutForTest = navigation.setFirstProfileFetchOutForTest;
pub const topicReqForTest = navigation.topicReqForTest;
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
pub const isAuthRequired = relay_auth.isAuthRequired;
pub const AuthReactionForTest = relay_auth.AuthReactionForTest;
pub const AuthSessionForTest = relay_auth.AuthSessionForTest;
pub const answerHelperAuthForTest = relay_auth.answerHelperAuthForTest;
pub const applyAuthFileForTest = relay_auth.applyAuthFileForTest;
pub const authAnswerForTest = relay_auth.authAnswerForTest;
pub const authBadgeTextForTest = relay_auth.authBadgeTextForTest;
pub const authChoiceForTest = relay_auth.authChoiceForTest;
pub const authChoiceOfForTest = relay_auth.authChoiceOfForTest;
pub const authCycleForTest = relay_auth.authCycleForTest;
pub const authDeliverSignedForTest = relay_auth.authDeliverSignedForTest;
pub const authFileForTest = relay_auth.authFileForTest;
pub const authHelperBusyForTest = relay_auth.authHelperBusyForTest;
pub const authHelperFreeForTest = relay_auth.authHelperFreeForTest;
pub const authPhaseNameForTest = relay_auth.authPhaseNameForTest;
pub const authPollForTest = relay_auth.authPollForTest;
pub const authReactForTest = relay_auth.authReactForTest;
pub const authRowNoteForTest = relay_auth.authRowNoteForTest;
pub const authSlotResetForTest = relay_auth.authSlotResetForTest;
pub const authSweepForTest = relay_auth.authSweepForTest;
pub const auth_gate_wait_ms_for_test = relay_auth.auth_gate_wait_ms_for_test;
pub const driveRelayAuthForTest = relay_auth.driveRelayAuthForTest;
pub const resetRelayAuthForTest = relay_auth.resetRelayAuthForTest;
pub const setAuthChoiceForTest = relay_auth.setAuthChoiceForTest;
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
pub const feedWatchGenerationForTest = ingest.feedWatchGenerationForTest;
pub const mergeFeedWatchForTest = ingest.mergeFeedWatchForTest;
pub const publishFeedWatchForTest = ingest.publishFeedWatchForTest;
pub const rememberFeedIdForTest = ingest.rememberFeedIdForTest;
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
pub const askForMediaForTest = view_note.askForMediaForTest;
pub const asked_cap = view_note.asked_cap;
pub const avatarDisc = view_note.avatarDisc;
pub const buildReplyContextForTest = view_note.buildReplyContextForTest;
pub const collapsedLen = view_note.collapsedLen;
pub const collectText = view_note.collectText;
pub const contentSpans = view_note.contentSpans;
pub const contentSpansIn = view_note.contentSpansIn;
pub const elide = view_note.elide;
pub const engagementRow = view_note.engagementRow;
pub const engagementRowAt = view_note.engagementRowAt;
pub const firstLineOf = view_note.firstLineOf;
pub const firstLineOfForTest = view_note.firstLineOfForTest;
pub const forgetAskedMediaForTest = view_note.forgetAskedMediaForTest;
pub const forgetUncoveredForTest = view_note.forgetUncoveredForTest;
pub const formatCount = view_note.formatCount;
pub const hgap = view_note.hgap;
pub const identityBlock = view_note.identityBlock;
pub const identityBlockForTest = view_note.identityBlockForTest;
pub const isExpanded = view_note.isExpanded;
pub const isMediaAsked = view_note.isMediaAsked;
pub const isUncovered = view_note.isUncovered;
pub const liveRelayCount = view_note.liveRelayCount;
pub const liveRelayCountForTest = view_note.liveRelayCountForTest;
pub const noteAvatar = view_note.noteAvatar;
pub const noteBody = view_note.noteBody;
pub const noteBodyAt = view_note.noteBodyAt;
pub const noteCard = view_note.noteCard;
pub const noteCovered = view_note.noteCovered;
pub const noteIsLong = view_note.noteIsLong;
pub const noteSpans = view_note.noteSpans;
pub const oneLine = view_note.oneLine;
pub const oneLineForTest = view_note.oneLineForTest;
pub const pluralize = view_note.pluralize;
pub const pressRow = view_note.pressRow;
pub const profile_band_name_max = view_note.profile_band_name_max;
pub const profile_handle_max = view_note.profile_handle_max;
pub const profile_name_max = view_note.profile_name_max;
pub const quotePictureAspect = view_note.quotePictureAspect;
pub const quotePictureBox = view_note.quotePictureBox;
pub const quoteShowsPicture = view_note.quoteShowsPicture;
pub const quotingPillLabel = view_note.quotingPillLabel;
pub const quotingPillLabelForTest = view_note.quotingPillLabelForTest;
pub const replyContext = view_note.replyContext;
pub const replyTarget = view_note.replyTarget;
pub const showsImage = view_note.showsImage;
pub const showsLink = view_note.showsLink;
pub const textParaAt = view_note.textParaAt;
pub const threadTime = view_note.threadTime;
pub const toggleExpanded = view_note.toggleExpanded;
pub const toggleExpandedForTest = view_note.toggleExpandedForTest;
pub const uncoverNote = view_note.uncoverNote;
pub const uncoverNoteForTest = view_note.uncoverNoteForTest;
pub const uncovered_cap = view_note.uncovered_cap;
pub const verb_slot_height = view_note.verb_slot_height;
pub const vgap = view_note.vgap;
pub const warningCovered = view_note.warningCovered;

// re-exports: view_chrome.zig
pub const accountHasName = view_chrome.accountHasName;
pub const accountName = view_chrome.accountName;
pub const auth_verb_inset = view_chrome.auth_verb_inset;
pub const avatarRadius = view_chrome.avatarRadius;
pub const avatarRadiusForTest = view_chrome.avatarRadiusForTest;
pub const avatarTint = view_chrome.avatarTint;
pub const identityInk = view_chrome.identityInk;
pub const identityInkForTest = view_chrome.identityInkForTest;
pub const menuRow = view_chrome.menuRow;
pub const menuSurfacePlaced = view_chrome.menuSurfacePlaced;
pub const menuSurfacePlacedDismissing = view_chrome.menuSurfacePlacedDismissing;
pub const noteContextItems = view_chrome.noteContextItems;
pub const npubShort = view_chrome.npubShort;
pub const npubShortForTest = view_chrome.npubShortForTest;
pub const offlineBanner = view_chrome.offlineBanner;
pub const offlineBannerText = view_chrome.offlineBannerText;
pub const offlineBannerTextForTest = view_chrome.offlineBannerTextForTest;
pub const outboxZone = view_chrome.outboxZone;
pub const pausedBannerText = view_chrome.pausedBannerText;
pub const pausedBannerTextForTest = view_chrome.pausedBannerTextForTest;
pub const pillButton = view_chrome.pillButton;
pub const poolIsHealthy = view_chrome.poolIsHealthy;
pub const poolIsHealthyForTest = view_chrome.poolIsHealthyForTest;
pub const poolIsHealthyOf = view_chrome.poolIsHealthyOf;
pub const poolIsHealthyOfForTest = view_chrome.poolIsHealthyOfForTest;
pub const relayAuthBanner = view_chrome.relayAuthBanner;
pub const relayBadgeText = view_chrome.relayBadgeText;
pub const relayBadgeTextForTest = view_chrome.relayBadgeTextForTest;
pub const relayZone = view_chrome.relayZone;
pub const roomVerbFill = view_chrome.roomVerbFill;
pub const roomVerbFillForTest = view_chrome.roomVerbFillForTest;
pub const roomVerbInk = view_chrome.roomVerbInk;
pub const shareBase = view_chrome.shareBase;
pub const signerIsHealthy = view_chrome.signerIsHealthy;
pub const signerStatus = view_chrome.signerStatus;
pub const signerStatusLabelForTest = view_chrome.signerStatusLabelForTest;
pub const signerZone = view_chrome.signerZone;
pub const statusChip = view_chrome.statusChip;
pub const updateBanner = view_chrome.updateBanner;

// re-exports: view_place.zig
pub const deliverPlaceLogoBodyForTest = view_place.deliverPlaceLogoBodyForTest;
pub const lowerScopeForTest = view_place.lowerScopeForTest;
pub const placeHomeHeightForTest = view_place.placeHomeHeightForTest;
pub const placeLogoShownForTest = view_place.placeLogoShownForTest;
pub const placeLogoStateNameForTest = view_place.placeLogoStateNameForTest;
pub const scanPlaceLogoForTest = view_place.scanPlaceLogoForTest;
pub const setPlaceLogoAskedForTest = view_place.setPlaceLogoAskedForTest;
pub const setPlaceLogoIdForTest = view_place.setPlaceLogoIdForTest;
pub const setPlaceLogoLoadedForTest = view_place.setPlaceLogoLoadedForTest;
pub const stripEmptyImagesForTest = view_place.stripEmptyImagesForTest;
pub const visibleLenForTest = view_place.visibleLenForTest;
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
pub const avatarImageIdForTest = view_rail.avatarImageIdForTest;
pub const placeTileColorsForTest = view_rail.placeTileColorsForTest;
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
pub const profileFooterForTest = view_profile.profileFooterForTest;
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
pub const articleRowCountForTest = view_article.articleRowCountForTest;
pub const articleRowForTest = view_article.articleRowForTest;
pub const forgetArticleForTest = view_article.forgetArticleForTest;
pub const articleFor = view_article.articleFor;
pub const articlePanel = view_article.articlePanel;
pub const articleRowAt = view_article.articleRowAt;
pub const isArticleRoot = view_article.isArticleRoot;

// re-exports: view_thread.zig
pub const ancestorBodyLinesForTest = view_thread.ancestorBodyLinesForTest;
pub const ancestorRowForTest = view_thread.ancestorRowForTest;
pub const extentTableLenForTest = view_thread.extentTableLenForTest;
pub const ghostRowForTest = view_thread.ghostRowForTest;
pub const listeningFooterForTest = view_thread.listeningFooterForTest;
pub const noteRowEstimateForTest = view_thread.noteRowEstimateForTest;
pub const outsideGraphRowForTest = view_thread.outsideGraphRowForTest;
pub const profileExtentTableForTest = view_thread.profileExtentTableForTest;
pub const quoteBodyLinesForTest = view_thread.quoteBodyLinesForTest;
pub const recordVisibleAuthorsForTest = view_thread.recordVisibleAuthorsForTest;
pub const recordVisibleNotesForTest = view_thread.recordVisibleNotesForTest;
pub const replyBlockForTest = view_thread.replyBlockForTest;
pub const rowExtentFromTableForTest = view_thread.rowExtentFromTableForTest;
pub const showMoreRepliesForTest = view_thread.showMoreRepliesForTest;
pub const threadExtentTableForTest = view_thread.threadExtentTableForTest;
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
pub const composeReachForTest = view_compose.composeReachForTest;
pub const insertMentionForTest = view_compose.insertMentionForTest;
pub const composeReach = view_compose.composeReach;
pub const composeSheet = view_compose.composeSheet;
pub const insertMention = view_compose.insertMention;
pub const mentionQuery = view_compose.mentionQuery;
pub const replyNotifyRow = view_compose.replyNotifyRow;

// re-exports: view_notifications.zig
pub const notificationRowForTest = view_notifications.notificationRowForTest;
pub const notifications_column_width_for_test = view_notifications.notifications_column_width_for_test;
pub const inbox_page = view_notifications.inbox_page;
pub const notificationRow = view_notifications.notificationRow;
pub const notificationsSheet = view_notifications.notificationsSheet;
pub const notifications_column_width = view_notifications.notifications_column_width;

// re-exports: view_search.zig
pub const searchBody = view_search.searchBody;
pub const search_ring_room = view_search.search_ring_room;
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
pub const profile_fields_height = view_sheets.profile_fields_height;
pub const toastOverlay = view_sheets.toastOverlay;

// re-exports: view_settings.zig
pub const cycleRelayForTest = view_settings.cycleRelayForTest;
pub const removeRelayForTest = view_settings.removeRelayForTest;
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

// re-exports: view_app.zig
pub const appView = view_app.appView;

test {
    _ = @import("tests.zig");
    _ = @import("blossom.zig");
}

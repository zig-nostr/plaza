//! Pictures in the feed: slots, ranged fetches, GIFs, and proxy refusals.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const prefs = @import("prefs.zig");
const profile_cache = @import("profile_cache.zig");
const quote_cache = @import("quote_cache.zig");
const view_thread = @import("view_thread.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const lookupProfile = main.lookupProfile;
const Effects = main.Effects;
const Model = main.Model;
const Note = main.Note;
const QuoteEntry = main.QuoteEntry;
const acquireImageId = main.acquireImageId;
const animation_interval_ms = main.animation_interval_ms;
const cacheName = main.cacheName;
const collapsedLen = main.collapsedLen;
const decodeAndRegister = main.decodeAndRegister;
const feedImageUrlDirect = main.feedImageUrlDirect;
const feedKeyOf = main.feedKeyOf;
const isExpanded = main.isExpanded;
const isGifUrl = main.isGifUrl;
const isMediaAsked = main.isMediaAsked;
const max_gif_frames = main.max_gif_frames;
const max_gif_total_bytes = main.max_gif_total_bytes;
const max_image_bytes = main.max_image_bytes;
const max_image_download_bytes = main.max_image_download_bytes;
const max_media_images = main.max_media_images;
const max_note_images = main.max_note_images;
const max_playing_gifs = main.max_playing_gifs;
const max_registered_image_bytes = main.max_registered_image_bytes;
const mediaCacheDir = main.mediaCacheDir;
const media_fetch_key_base = main.media_fetch_key_base;
const media_target_px = main.media_target_px;
const noteCovered = main.noteCovered;
const noteIsLong = main.noteIsLong;
const note_collapse_chars = main.note_collapse_chars;
const quoteCovered = main.quoteCovered;
const stbi_image_free = main.stbi_image_free;
const stbi_load_gif_from_memory = main.stbi_load_gif_from_memory;
const storeCachedImage = main.storeCachedImage;
const visible_set_cap = main.visible_set_cap;

pub const MediaSlot = struct {
    used: bool = false,
    note_id: i64 = 0,
    image_id: u64 = 0,
    state: enum { idle, fetching, loaded, failed } = .idle,
    /// Fetches for this slot's URL that came back unusable for a reason worth
    /// retrying. Reset when the slot is handed to a different note, because
    /// `claimMediaSlot` rebuilds the whole struct.
    attempts: u8 = 0,
    /// Tick counter at the last time this note was still wanted, for eviction.
    last_used: u64 = 0,
    /// The registered pixel size, so the card can lay the picture out at its
    /// own aspect rather than stretching it.
    width: usize = 0,
    height: usize = 0,
    /// The resolved URL this image is fetched from, which is also its cache key.
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,
    /// The host the picture actually lives on, which is NOT the host of
    /// `url_buf` while the proxy is in the way. Kept because a refusal is a
    /// fact about this host and has to be written down under it, and the
    /// response handler has nothing else to learn it from.
    host_buf: [96]u8 = [_]u8{0} ** 96,
    host_len: u8 = 0,
    /// Ask this picture's own host next time, skipping the proxy.
    ///
    /// Set when a proxied fetch came back unusable, so the retry goes to the
    /// source. The public proxy refuses whole TLDs by policy and answers 400 for
    /// hosts that serve the same file directly without complaint, and from here
    /// that is indistinguishable from any other refusal: what is observable is
    /// that the proxy would not produce the picture.
    ///
    /// One flag rather than a counter, because it is one alternative: proxy,
    /// then source, then give up. Reset with the rest of the slot when it is
    /// handed to a different note.
    direct: bool = false,
    /// A picture too big for one response body, assembled out of Range slices.
    down: Download = .{},
    /// Every frame of an animated GIF, decoded once and owned by stb (freed on
    /// eviction). Null for a still picture.
    frames: ?[*]u8 = null,
    frame_count: u16 = 0,
    frame_index: u16 = 0,
    /// Milliseconds this GIF holds each frame, and how much of that has elapsed.
    frame_delay_ms: u32 = 100,
    elapsed_ms: u32 = 0,

    pub fn url(self: *const MediaSlot) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    fn host(self: *const MediaSlot) []const u8 {
        return self.host_buf[0..self.host_len];
    }
    fn animated(self: *const MediaSlot) bool {
        return self.frames != null and self.frame_count > 1;
    }
    /// Releases the decoded frames, if any. Called before a slot is reused.
    pub fn releaseFrames(self: *MediaSlot) void {
        if (self.frames) |px| stbi_image_free(px);
        self.frames = null;
        self.frame_count = 0;
        self.frame_index = 0;
    }
};

pub var g_media = [_]MediaSlot{.{}} ** max_media_images;

// The rows the windowed list last put on screen. Written by the view (which is
// where the runtime resolves the window) and read by the fetch pass in
// `update`, so the image budget follows the reader exactly.
pub var g_visible_first: usize = 0;
pub var g_visible_last: usize = 0;

// What shape each note's picture turned out to be, remembered per note id and
// OUTLIVING both the media slot and the note itself. A slot is evicted as soon
// as the note scrolls out of the window; without this the card would forget how
// tall its picture was, shrink, and shift the feed under the reader, then shift
// it back on the way up. Notes whose `imeta` declared a size never need it.
const aspect_memory_cap = 128;
const AspectEntry = struct { note_id: i64 = 0, aspect: f32 = 0 };
var g_aspects = [_]AspectEntry{.{}} ** aspect_memory_cap;
var g_aspect_next: usize = 0;

/// Records the shape of `note_id`'s picture.
pub fn rememberAspect(note_id: i64, width: usize, height: usize) void {
    if (width == 0 or height == 0) return;
    const aspect = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width));
    for (&g_aspects) |*entry| {
        if (entry.note_id == note_id) {
            entry.aspect = aspect;
            return;
        }
    }
    g_aspects[g_aspect_next] = .{ .note_id = note_id, .aspect = aspect };
    g_aspect_next = (g_aspect_next + 1) % aspect_memory_cap;
}

/// The remembered shape of `note_id`'s picture, if it has been seen.
pub fn recalledAspect(note_id: i64) ?f32 {
    for (&g_aspects) |entry| {
        if (entry.note_id == note_id and entry.aspect > 0) return entry.aspect;
    }
    return null;
}
/// The slot holding `note_id`'s image, if any.
/// The media-slot key for one picture of a note.
///
/// Picture ZERO keeps the note's own id, deliberately: every slot already on
/// disk was cached under it, and every path that still speaks in note ids keeps
/// working unchanged. Only the second and later pictures need a key of their
/// own.
///
/// A derived key colliding with some other note's id would show that note's
/// picture here. Note ids are already 63 bits taken from an event id, so this is
/// the same order of unlikely as two notes colliding outright, which the feed
/// has always lived with.
pub fn mediaKey(note_id: i64, index: usize) i64 {
    if (index == 0) return note_id;
    const mixed = @as(u64, @bitCast(note_id)) ^ (0x9E37_79B9_7F4A_7C15 *% @as(u64, index));
    return @bitCast(mixed & 0x7FFF_FFFF_FFFF_FFFF);
}
pub fn mediaSlotFor(note_id: i64) ?*MediaSlot {
    for (&g_media) |*m| {
        if (m.used and m.note_id == note_id) return m;
    }
    return null;
}

/// The slot for `note_id`, claiming a free one or evicting the least recently
/// wanted. Never evicts a slot whose note is still on screen (touched this
/// pass), and never one with a fetch in flight: when more pictures are visible
/// than there are slots, the extras hold their reserved space rather than
/// stealing each other's slot back and forth, which decoded images on the UI
/// thread every pass and made a tall window feel heavy.
/// Whether this note's picture was asked for and could not be had.
pub fn mediaFailed(note_id: i64) bool {
    const m = mediaSlotFor(note_id) orelse return false;
    return m.state == .failed;
}
/// The slot's position in `g_media`, which is its identity for everything
/// outside the registry: its fetch key is derived from it, so an arriving
/// response finds the slot that asked even after the registry id it holds has
/// been lent to somebody else.
pub fn mediaSlotIndex(m: *const MediaSlot) usize {
    return (@intFromPtr(m) - @intFromPtr(&g_media[0])) / @sizeOf(MediaSlot);
}

pub fn claimMediaSlot(fx: *Effects, note_id: i64) ?*MediaSlot {
    if (mediaSlotFor(note_id)) |m| return m;
    for (&g_media) |*m| {
        if (!m.used) {
            // A slot with no registry id yet. It gets one when there is a
            // picture to put in it, from the same pool as everything else.
            m.* = .{ .used = true, .note_id = note_id };
            return m;
        }
    }
    var victim: ?*MediaSlot = null;
    for (&g_media) |*m| {
        if (m.state == .fetching) continue;
        if (m.last_used == profile_cache.g_image_clock) continue; // still wanted on screen
        if (victim == null or m.last_used < victim.?.last_used) victim = m;
    }
    const v = victim orelse return null;
    const id = v.image_id;
    // Free the registry slot and any decoded frames before reusing the slot.
    if (id != 0) _ = fx.unregisterImage(id);
    v.releaseFrames();
    // Not a second cleanup: every way a fetch can end already drops its slices,
    // and a slot still assembling one is `.fetching`, which is never a victim.
    // This says so out loud, so a terminal path that forgets fails here in a
    // test rather than quietly handing the next note half of somebody else's
    // picture.
    std.debug.assert(v.down.buf == null);
    // The id it was holding comes with it: the picture that was in it has just
    // been unregistered, so the slot is empty and nobody else can be lent it
    // between here and the next registration.
    v.* = .{ .used = true, .note_id = note_id, .image_id = id };
    return v;
}

/// Decodes every frame of an animated GIF into `slot` and registers the first,
/// so the shared animation timer can cycle it. Returns false for a still image
/// (including a single-frame GIF), leaving the normal still path to handle it.
fn loadAnimatedGif(fx: *Effects, slot: *MediaSlot, bytes: []const u8) bool {
    if (bytes.len < 3 or !std.mem.eql(u8, bytes[0..3], "GIF")) return false;

    var delays: ?[*]c_int = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var count: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_gif_from_memory(bytes.ptr, @intCast(bytes.len), &delays, &w, &h, &count, &comp, 4) orelse return false;
    if (count <= 1 or w <= 0 or h <= 0) {
        stbi_image_free(pixels);
        return false;
    }

    const frame_w: usize = @intCast(w);
    const frame_h: usize = @intCast(h);
    const frame_bytes = frame_w * frame_h * 4;
    const frames: usize = @intCast(count);
    // stb decodes every frame up front, so a long or large GIF is the real
    // memory hazard rather than the per-frame cost. Refuse the extremes and let
    // the caller fall back to a still first frame.
    if (frame_bytes > max_registered_image_bytes or frames > max_gif_frames or frame_bytes * frames > max_gif_total_bytes) {
        stbi_image_free(pixels);
        return false;
    }

    fx.registerImage(slot.image_id, frame_w, frame_h, pixels[0..frame_bytes]) catch {
        stbi_image_free(pixels);
        return false;
    };

    slot.releaseFrames();
    slot.frames = pixels;
    slot.frame_count = @intCast(frames);
    slot.frame_index = 0;
    slot.elapsed_ms = 0;
    // GIF delays are centiseconds x10; anything implausibly fast gets the
    // browsers' customary floor.
    slot.frame_delay_ms = if (delays) |d| (if (d[0] >= 20) @intCast(d[0]) else 100) else 100;
    slot.width = frame_w;
    slot.height = frame_h;
    slot.state = .loaded;
    rememberAspect(slot.note_id, frame_w, frame_h);
    return true;
}

/// Registers a feed picture from the on-disk cache, animating it if it is a GIF.
/// Returns whether the slot is now loaded.
fn loadCachedMedia(fx: *Effects, slot: *MediaSlot, gif: bool) bool {
    const io = main.g_io orelse return false;
    const environ = main.g_environ orelse return false;
    var dir = mediaCacheDir(io, environ) catch return false;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_download_bytes)) catch return false;
    defer gpa.free(bytes);

    if (gif and loadAnimatedGif(fx, slot, bytes)) return true;
    if (decodeAndRegister(fx, slot.image_id, bytes, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        return true;
    }
    return false;
}

/// Advances the animated pictures currently in view, one shared timer for all of
/// them (a timer each would exhaust the 16-slot timer table). Only a couple play
/// at once: the rest hold their first frame until they scroll into that budget.
pub fn advanceAnimations(fx: *Effects, model: *const Model) void {
    const window = model.visibleRange();
    var playing: usize = 0;
    for (&g_media) |*slot| {
        if (!slot.used or !slot.animated() or slot.state != .loaded) continue;
        // In view? The note has to still be one of the ones on screen.
        var visible = false;
        var index = window.first;
        while (index <= window.last and index < model.notes_len) : (index += 1) {
            if (model.notes[index].id == slot.note_id) {
                visible = true;
                break;
            }
        }
        if (!visible) continue;
        if (playing >= max_playing_gifs) break;
        playing += 1;

        slot.elapsed_ms += animation_interval_ms;
        if (slot.elapsed_ms < slot.frame_delay_ms) continue;
        slot.elapsed_ms = 0;
        slot.frame_index = (slot.frame_index + 1) % slot.frame_count;

        const frames = slot.frames orelse continue;
        const frame_bytes = slot.width * slot.height * 4;
        const offset = @as(usize, slot.frame_index) * frame_bytes;
        // Re-registering the same id swaps the pixels everywhere it is drawn.
        fx.registerImage(slot.image_id, slot.width, slot.height, frames[offset..][0..frame_bytes]) catch {};
    }
}

/// Loads the pictures for the notes around the viewport: the cached ones
/// straight from disk, the rest over the network a few per tick. Notes outside
/// the window keep their slot only until something on screen needs it. While a
/// thread is open the feed under it is hidden, so the budget goes to the thread's
/// pictures instead (the feed's reload from the disk cache when it returns).
pub fn scanMediaFetches(fx: *Effects, model: *const Model) void {
    const per_tick = 6;
    var fired: usize = 0;
    // No tick of its own: `beginImagePass` advances the one clock every image
    // pass marks against. A second bump here would put every picture a tick
    // ahead of every face, so the allocator would read faces as permanently
    // older and evict them first, forever.

    if (model.levelOpen()) {
        // A level occludes the feed, so the picture budget goes to the level,
        // and only to the rows ON SCREEN in it. Marking every note in the level
        // wanted meant the first six pictures held all six slots and nothing
        // else could ever be lent one: the claim pass refuses to evict anything
        // wanted this pass, and everything was. Every other picture in a long
        // thread stayed an empty box for as long as the thread was open.
        //
        // Mark, then fetch, as the feed does: marking first means the claim pass
        // can only evict what has scrolled away, never a picture needed later in
        // this same pass.
        const set = &view_thread.g_level_visible[@min(view_thread.g_visible_level, view_thread.g_level_visible.len - 1)];
        // Each id resolved once: `noteById` walks the whole feed before the
        // level's own rows, and both loops below need the note.
        var shown: [visible_set_cap]?*const Note = undefined;
        for (set.notes[0..set.note_count], 0..) |id, i| {
            markMediaWanted(id);
            shown[i] = model.noteById(id);
            if (shown[i]) |note| markQuoteMediaWanted(note, levelNoteFolds(model, note));
        }
        for (shown[0..set.note_count]) |maybe| {
            const note = maybe orelse continue;
            fireQuoteMedia(fx, note, levelNoteFolds(model, note), &fired, per_tick);
            fireMedia(fx, note, &fired, per_tick);
        }
        return;
    }

    const window = model.visibleRange();

    // First mark every slot whose note is on screen as wanted, so the claim
    // pass below can only ever evict pictures that have scrolled away. Without
    // this, a viewport showing more pictures than there are slots would evict
    // a slot needed later in this very pass, endlessly.
    var touch = window.first;
    while (touch <= window.last and touch < model.notes_len) : (touch += 1) {
        markMediaWanted(model.notes[touch].id);
        markQuoteMediaWanted(&model.notes[touch], true);
    }

    var index = window.first;
    while (index <= window.last and index < model.notes_len) : (index += 1) {
        fireQuoteMedia(fx, &model.notes[index], true, &fired, per_tick);
        fireMedia(fx, &model.notes[index], &fired, per_tick);
    }
}

/// The media-slot key for the picture a quote card shows: the quoted event's
/// own feed key, picture zero.
///
/// The same key the quoted note's row would use if it were in the feed, on
/// purpose. Where the reader has both on screen they share one slot and one
/// registry id, and the picture is downloaded, decoded and held once.
pub fn quoteMediaKey(quoted: [32]u8) i64 {
    return mediaKey(feedKeyOf(quoted), 0);
}

/// Whether `note` draws its quote card at all right now. A collapsed long note
/// shows the card only when the fold reaches past it, so a card behind the fold
/// is not on screen and must not cost a fetch or a slot. The row's height
/// estimate asks the same question, so the two agree.
///
/// `collapsible` is what the body builder is told: a thread's focal note is
/// drawn whole whatever its length.
pub fn quoteCardShown(note: *const Note, collapsible: bool) bool {
    if (note.quote.kind != .event) return false;
    const collapsed = collapsible and noteIsLong(note) and !isExpanded(note.id);
    if (!collapsed) return true;
    const quote_end = @as(usize, note.quote.off) + @as(usize, note.quote.len);
    return quote_end <= collapsedLen(note.content(), note_collapse_chars);
}

/// A quote whose entry is in hand and carries a picture the card may load.
/// Looks without touching the cache's recency: this runs for every row in the
/// window, drawn or not, and must not make the cache think they all were.
fn quotePictureFor(note: *const Note, collapsible: bool) ?*const QuoteEntry {
    if (!quoteCardShown(note, collapsible)) return null;
    // A covered note (NIP-36) draws its cover and no quote card, so the picture
    // of the note it quotes is no more on screen than its own pictures are, and
    // fetching it would tell the host what the reader chose not to look at.
    if (noteCovered(note)) return null;
    for (&quote_cache.g_quotes) |*q| {
        if (!q.used or !std.mem.eql(u8, &q.id, &note.quote.id)) continue;
        // A covered quote (NIP-36) fetches nothing until it is shown.
        if (q.state != .loaded or q.image_url_len == 0 or quoteCovered(q)) return null;
        return q;
    }
    return null;
}

/// Marks the slot a quote card holds as wanted this pass, so the claim pass
/// cannot evict a picture that is still on screen.
fn markQuoteMediaWanted(note: *const Note, collapsible: bool) void {
    const q = quotePictureFor(note, collapsible) orelse return;
    if (mediaSlotFor(quoteMediaKey(q.id))) |m| m.last_used = profile_cache.g_image_clock;
}

/// Loads the picture of the quote card `note` draws, if it draws one.
///
/// Previews off means no fetch and no cache read, with no per-note "load" to
/// ask for: the card names the picture and where it is from, and the press that
/// was always there opens the note, where asking is offered.
fn fireQuoteMedia(fx: *Effects, note: *const Note, collapsible: bool, fired: *usize, per_tick: usize) void {
    if (!prefs.g_media_previews) return;
    const q = quotePictureFor(note, collapsible) orelse return;
    fireMediaSlot(fx, quoteMediaKey(q.id), q.imageUrl(), fired, per_tick);
}

/// Whether a note in the open level folds its body: all of them do except the
/// thread's focal note, which `focalBody` draws whole.
fn levelNoteFolds(model: *const Model, note: *const Note) bool {
    return !(model.viewing_thread != 0 and note.id == model.thread_root.id);
}

/// Marks the picture slot for `note_id` wanted this pass (if it has one), so the
/// claim pass does not evict a picture still on screen.
fn markMediaWanted(note_id: i64) void {
    // Every picture of the note, not just the first: a gallery's later cells are
    // as much on screen as its first, and leaving them unmarked let the claim
    // pass evict one to feed another in the same row.
    var i: usize = 0;
    while (i < max_note_images) : (i += 1) {
        if (mediaSlotFor(mediaKey(note_id, i))) |m| m.last_used = profile_cache.g_image_clock;
    }
}

/// Loads one note's picture: claims a slot, serves it from the disk cache, or
/// fetches it over the network (up to `per_tick` fetches a pass). A note with no
/// picture, or one whose slot is already loading or done, is a no-op.
fn fireMedia(fx: *Effects, note: *const Note, fired: *usize, per_tick: usize) void {
    // Every picture the note carries, in reading order, so the first one is the
    // first to get a slot when there are not enough to go round. The ones that
    // miss out draw their blurhash, which costs no slot at all.
    var i: usize = 0;
    while (i < note.imageCount()) : (i += 1) fireMediaAt(fx, note, i, fired, per_tick);
}

fn fireMediaAt(fx: *Effects, note: *const Note, index: usize, fired: *usize, per_tick: usize) void {
    const link = note.imageAt(index).url();
    if (link.len == 0) return;
    // A covered note's pictures are not asked for. Fetching them and then hiding
    // them would defeat the cover: the host would learn the reader's address
    // either way, and a metered connection pays for bytes nobody sees.
    if (noteCovered(note)) return;
    // With previews off, nothing leaves the machine until the reader asks for
    // this note's pictures. That is the point of the setting: not bandwidth, but
    // that reading a feed should not tell every host in it that you did.
    if (!prefs.g_media_previews and !isMediaAsked(note.id)) return;
    fireMediaSlot(fx, mediaKey(note.id, index), link, fired, per_tick);
}

/// Loads the picture at `link` into the media slot filed under `key`: claims
/// the slot and a registry id, serves it from the disk cache, or fetches it.
///
/// The one body behind both a feed picture and a quote card's, so the two
/// cannot disagree about slots, ids, the cache, the proxy or the retry rules.
/// The callers decide WHETHER to load (previews, being on screen); this decides
/// how.
fn fireMediaSlot(fx: *Effects, key: i64, link: []const u8, fired: *usize, per_tick: usize) void {
    const slot = claimMediaSlot(fx, key) orelse return;
    slot.last_used = profile_cache.g_image_clock;
    if (slot.state != .idle) return;
    // A slot is a place to put a picture; an id is the registry capacity to
    // hold one, and there are fewer of those. Take one now, marked on screen
    // first so this cannot evict a sibling picture in the same note. Nothing
    // free means the reader sees this cell as a blurhash for a frame and the
    // next pass tries again, which is what the shared pool is for: the id it
    // needs is whichever face or picture has been off screen longest, not one
    // reserved for pictures and idle.
    if (slot.image_id == 0) {
        slot.image_id = acquireImageId(fx) orelse return;
    }

    var url_buf: [1024]u8 = undefined;
    const gif = isGifUrl(link);
    const url = feedImageUrlDirect(&url_buf, link, slot.direct);
    const n = @min(url.len, slot.url_buf.len);
    @memcpy(slot.url_buf[0..n], url[0..n]);
    slot.url_len = @intCast(n);
    const host = hostOf(link);
    const hn = @min(host.len, slot.host_buf.len);
    @memcpy(slot.host_buf[0..hn], host[0..hn]);
    slot.host_len = @intCast(hn);

    // Local-first: a picture we already have appears with the note, with no
    // network round-trip at all.
    if (loadCachedMedia(fx, slot, gif)) return;
    if (fired.* >= per_tick) return;
    slot.state = .fetching;
    slot.down.release();
    fetchMediaSlice(fx, slot, 0);
    fired.* += 1;
}

/// Asks `slot`'s host for the `max_image_bytes` of the picture that start at
/// `offset`.
///
/// Every request is a Range request, including the first, so one code path
/// covers a thumbnail and a full-frame photo alike: a picture smaller than one
/// slice comes back whole on the first answer and costs no extra round trip.
/// A host that does not do ranges answers 200 with the whole body instead of
/// 206 with a slice, which is a difference the caller can see, so ignoring the
/// header can never be mistaken for a complete picture.
fn fetchMediaSlice(fx: *Effects, slot: *MediaSlot, offset: usize) void {
    fetchSlice(fx, media_fetch_key_base + mediaSlotIndex(slot), slot.url(), offset, Effects.responseMsg(.media_fetched));
}

/// One slice of one image, whoever wants it.
pub fn fetchSlice(fx: *Effects, key: u64, url: []const u8, offset: usize, on_response: anytype) void {
    var range_buf: [64]u8 = undefined;
    const range = rangeHeader(&range_buf, offset) orelse return;
    fx.fetch(.{
        .key = key,
        .url = url,
        // `identity` is not politeness, it is what makes the arithmetic true.
        // The HTTP client asks for gzip by default, and a range together with a
        // content encoding means the slice boundaries are in ENCODED bytes
        // while what arrives is decoded ones: "a short slice is the last slice"
        // would then be measuring the wrong thing, and the picture would
        // assemble out of the wrong pieces and still decode. Pictures are
        // already compressed, so asking for none costs nothing.
        .headers = &.{
            .{ .name = "range", .value = range },
            .{ .name = "accept-encoding", .value = "identity" },
        },
        .on_response = on_response,
    });
}

/// The value of a `Range` header asking for the slice that starts at `offset`.
///
/// Inclusive at both ends, which is what the header means: the window is
/// `max_image_bytes` wide, so the last byte asked for is one before the next
/// offset. An off-by-one here would either drop a byte between slices (a
/// corrupt picture that still decodes, which is the worst outcome) or overlap
/// them (a picture longer than the file).
pub fn rangeHeader(buf: []u8, offset: usize) ?[]const u8 {
    return std.fmt.bufPrint(buf, "bytes={d}-{d}", .{ offset, offset + max_image_bytes - 1 }) catch null;
}

/// A slice that came back SHORT is the last one: the host had nothing more to
/// give from that offset. A full slice means there is probably more, so the
/// caller asks again from the new end.
pub const SliceOutcome = enum { complete, want_more };

/// One picture arriving in Range slices.
///
/// Every image Plaza draws goes through this: a face, a feed picture and a
/// profile banner are the same problem, because a response body carries at most
/// `max_image_bytes` and none of the three is reliably under it. It was written
/// for feed pictures first and the other two were left on one request, which
/// meant a full-size profile picture fetched from its own host drew initials
/// for exactly the same reason a photo drew a blank cell.
pub const Download = struct {
    buf: ?[]u8 = null,
    len: usize = 0,

    /// Appends one delivered slice. `null` means this picture cannot be
    /// assembled (no memory, or past the ceiling) and the fetch is over.
    pub fn append(self: *Download, body: []const u8) ?SliceOutcome {
        if (self.buf == null) {
            // The first slice arrives before there is anywhere to put it, and
            // it is the only one that can be the whole picture: a short first
            // slice decodes straight from the response with nothing allocated.
            if (body.len < max_image_bytes) return .complete;
            self.buf = std.heap.page_allocator.alloc(u8, max_image_download_bytes) catch return null;
        }
        const buf = self.buf.?;
        const filled = self.len + body.len;
        // The buffer IS the ceiling, and there is deliberately no second check
        // saying the same thing: a host that answers a full slice every time
        // has to run out of room, and one bound that the append cannot cross is
        // easier to trust than two that can drift apart.
        if (filled > buf.len) return null;
        @memcpy(buf[self.len..filled], body);
        self.len = filled;
        return if (body.len < max_image_bytes) .complete else .want_more;
    }

    /// What has been assembled, or null when nothing was: a picture that fit in
    /// one slice decodes from the response body instead.
    pub fn bytes(self: *const Download) ?[]const u8 {
        const buf = self.buf orelse return null;
        return buf[0..self.len];
    }

    /// Drops a half-assembled picture. Called wherever a fetch ends, however it
    /// ends: bytes that outlive their fetch are bytes nobody will ever decode.
    pub fn release(self: *Download) void {
        if (self.buf) |buf| std.heap.page_allocator.free(buf);
        self.buf = null;
        self.len = 0;
    }
};

/// What a fetch that produced no usable image says about trying again.
pub const ImageFailure = enum { retry, give_up };

/// Classifies a picture or avatar fetch that did not produce an image.
///
/// The question is not what the status code was, it is WHAT FAILED. A body that
/// arrived whole, with a 200, and is simply too large for the decoder, or was
/// truncated, or is empty, is a fact about that picture: it will be exactly as
/// large the next time, and every time after that. A timeout, a 5xx or a rate
/// limit is the network or the host having a moment, and those recover.
///
/// Reading only the status conflated the two, in opposite directions on the two
/// paths. The feed asked whether the STATUS was final, and an oversized picture
/// comes back 200, so the slot went back to idle and the same picture was
/// downloaded again on the next tick and again on every scroll event, for as
/// long as the note stayed on screen. The avatar path asked nothing at all, so a
/// single 503 or one dropped connection blanked that face for the rest of the
/// session, on every screen.
pub fn classifyImageFailure(outcome: native_sdk.EffectFetchOutcome, status: u16) ImageFailure {
    // Never reached a host, or the request was cut short on the way.
    if (outcome != .ok) return .retry;
    // The host answered, and the answer was not an image and will not become
    // one: too large to decode, cut off, or empty.
    if (status == 200) return .give_up;
    // The two 4xx that are about timing rather than about the resource.
    if (status == 408 or status == 429) return .retry;
    // Any other 4xx is the host saying no, and it will say no again.
    if (status >= 400 and status < 500) return .give_up;
    // 5xx, and anything unexpected: the host is having a moment.
    return .retry;
}

/// The hosts this proxy has refused, so the refusal outlives one picture.
///
/// A slot is not a place to keep this. The proxy's refusal is a fact about the
/// HOST, and it was being remembered on an evictable media slot: the fallback
/// sets the slot idle, an idle slot is exactly what `claimMediaSlot` evicts,
/// and the flag went with it. Scroll a `.pub` picture off screen and back and
/// it asked the proxy again, was refused again, and was evicted again, so it
/// could loop without ever once reaching the host that would have served it.
///
/// A face never had that problem, because its flag lives on the profile, which
/// is keyed by pubkey and outlives any amount of scrolling. That is the whole
/// of why faces on those hosts came back and pictures did not.
///
/// By host rather than by URL, because that is the granularity the refusal has:
/// wsrv.nl blocks whole TLDs by policy, so one refused picture is enough to
/// know about every other picture on that host, and the rest never spend the
/// wasted round trip at all.
const proxy_refused_hosts_cap = 16;
var g_proxy_refused: [proxy_refused_hosts_cap][96]u8 = undefined;
var g_proxy_refused_len: [proxy_refused_hosts_cap]u8 = [_]u8{0} ** proxy_refused_hosts_cap;
pub var g_proxy_refused_count: usize = 0;

/// The host part of `url`, empty if it does not look like one.
pub fn hostOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[scheme + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    // Userinfo and a port are not part of what the proxy refused.
    const after_at = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
    if (std.mem.indexOfScalar(u8, after_at, ']') != null) return after_at; // an IPv6 literal, taken whole
    return if (std.mem.indexOfScalar(u8, after_at, ':')) |i| after_at[0..i] else after_at;
}

/// Whether the proxy has already refused this URL's host.
pub fn proxyRefusesHost(url: []const u8) bool {
    const host = hostOf(url);
    if (host.len == 0) return false;
    for (0..g_proxy_refused_count) |i| {
        if (std.ascii.eqlIgnoreCase(g_proxy_refused[i][0..g_proxy_refused_len[i]], host)) return true;
    }
    return false;
}

/// Writes down that the proxy refused this URL's host.
///
/// Full is full: sixteen refused hosts in one session is far past the point
/// where the reader has noticed, and dropping the seventeenth costs one wasted
/// round trip per picture on it rather than anything a reader could see.
pub fn rememberProxyRefusal(url: []const u8) void {
    rememberHostRefusal(hostOf(url));
}

/// The same, for a caller that already has the host rather than a URL.
pub fn rememberHostRefusal(host: []const u8) void {
    if (host.len == 0 or host.len > g_proxy_refused[0].len) return;
    for (0..g_proxy_refused_count) |i| {
        if (std.ascii.eqlIgnoreCase(g_proxy_refused[i][0..g_proxy_refused_len[i]], host)) return;
    }
    if (g_proxy_refused_count >= proxy_refused_hosts_cap) return;
    const i = g_proxy_refused_count;
    @memcpy(g_proxy_refused[i][0..host.len], host);
    g_proxy_refused_len[i] = @intCast(host.len);
    g_proxy_refused_count += 1;
}

/// Forgets every refusal. A different proxy gets to answer for itself rather
/// than inheriting the last one's policy, which is the same rule the per-face
/// flag already follows.
pub fn forgetProxyRefusals() void {
    g_proxy_refused_count = 0;
}
/// Whether this answer is the proxy refusing the HOST, rather than telling us
/// something about the picture.
///
/// The three statuses a proxy uses to decline on policy. wsrv.nl answers 400
/// with `{"message":"Domain or TLD blocked by policy"}` for Blossom hosts that
/// serve the same file directly; 403 is the same refusal by another name, and
/// 451 is one made for it by somebody else.
///
/// Deliberately NOT 404, which is the source missing and will be missing
/// directly too, and not a 200 that produced no usable image, which is our own
/// size limit and is only worse without the proxy shrinking it first.
pub fn proxyRefusedHost(outcome: native_sdk.EffectFetchOutcome, status: u16) bool {
    if (outcome != .ok) return false;
    return status == 400 or status == 403 or status == 451;
}

/// How many times a picture or avatar may come back unusable for a reason worth
/// retrying before Plaza stops asking.
///
/// A backstop, not the mechanism. `classifyImageFailure` is what should decide,
/// and this is here so that no future mistake in it can produce an unbounded
/// download loop again: getting that wrong cost 240 KiB a second, per picture,
/// for as long as the reader looked at it.
pub const max_image_attempts = 4;

/// Handles a feed-image fetch response, mirroring the avatar path.
pub fn handleMediaFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < media_fetch_key_base) return;
    const index = response.key - media_fetch_key_base;
    if (index >= g_media.len) return;
    const slot = &g_media[@intCast(index)];
    if (!slot.used) return;

    if (response.outcome == .rejected) {
        slot.down.release();
        slot.state = .idle;
        return;
    }
    // A 206 is a slice of a picture that does not fit in one body. Take it, and
    // ask for the next unless the host just told us there is no next.
    if (response.outcome == .ok and response.status == 206 and !response.truncated and response.body.len > 0) {
        const outcome = slot.down.append(response.body) orelse {
            // Too big to assemble, or no memory to assemble it in. Both are
            // facts about this picture rather than about the network, so this
            // is finished rather than retried.
            slot.down.release();
            slot.state = .failed;
            return;
        };
        if (outcome == .want_more) {
            fetchMediaSlice(fx, slot, slot.down.len);
            return;
        }
        // Whole. The bytes are in the slice buffer unless this was a single
        // short first slice, which never allocated one.
        const whole = slot.down.bytes() orelse response.body;
        finishMedia(fx, slot, whole);
        slot.down.release();
        return;
    }
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        // Whatever was assembled so far is bytes nobody will decode now.
        slot.down.release();
        // A host that said NO is different from a host that did not answer, and
        // a picture that is simply too big is different again: it will be the
        // same size next time, so asking again is a download with a known
        // answer. Only something that can change goes back to idle.
        // One more try, at the source, before this is a failure at all.
        //
        // Only for the answers that are about the PROXY rather than about the
        // picture. The public one refuses whole TLDs by policy and answers 400
        // for Blossom hosts that hand over the same file without complaint, so
        // those say "not through here" and the host has not been asked yet.
        //
        // Narrow on purpose. A 404 through the proxy is the SOURCE missing,
        // and a body too large to decode is our own limit on the response,
        // which a direct fetch only makes worse because the proxy was the thing
        // shrinking it. Falling back on either is a second download with a known
        // answer, and two tests said so before this comment existed.
        //
        // Once per slot, and only while the proxy is what was used, so it can
        // never loop and never fires for a fetch that was already direct. The
        // attempt counter is untouched: this is a different question, not
        // another go at the same one.
        if (prefs.g_media_direct_fallback and prefs.g_media_proxy_on and !slot.direct and
            proxyRefusedHost(response.outcome, response.status))
        {
            // Under the HOST, because this slot is not a place to keep it: the
            // line below sets the slot idle, an idle slot is exactly what
            // eviction takes, and the flag went with it. A picture scrolled off
            // and back asked the proxy again, was refused again, and was
            // evicted again, so it could loop without ever once reaching the
            // host that would have served it.
            rememberHostRefusal(slot.host());
            slot.direct = true;
            slot.state = .idle;
            return;
        }
        slot.state = switch (classifyImageFailure(response.outcome, response.status)) {
            .give_up => .failed,
            .retry => blk: {
                slot.attempts +|= 1;
                break :blk if (slot.attempts >= max_image_attempts) .failed else .idle;
            },
        };
        return;
    }
    slot.down.release();
    finishMedia(fx, slot, response.body);
}

/// Decodes a complete picture into `slot` and remembers it.
fn finishMedia(fx: *Effects, slot: *MediaSlot, bytes: []const u8) void {
    // Whatever it took to get here, this URL answers, so the count of tries
    // worth making starts again.
    slot.attempts = 0;
    // An animated GIF keeps all its frames; anything else (including a GIF with
    // only one frame) takes the still path.
    if (loadAnimatedGif(fx, slot, bytes)) {
        storeCachedImage(slot.url(), bytes);
        return;
    }
    if (decodeAndRegister(fx, slot.image_id, bytes, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        // Keep it for next launch: the feed should come back with its pictures.
        storeCachedImage(slot.url(), bytes);
    } else {
        slot.state = .failed;
    }
}

/// Lets everything that failed to load try again, after the media proxy changed.
pub fn retryFailedImages() void {
    for (&profile_cache.g_profiles) |*p| {
        if (p.used and p.avatar_state == .failed) {
            p.avatar_state = .idle;
            p.avatar_attempts = 0;
            // A new proxy gets to answer for itself, so the face goes back
            // through it rather than staying pinned to its own host.
            p.avatar_direct = false;
        }
    }
    for (&g_media) |*m| {
        if (m.used and m.state == .failed) {
            m.state = .idle;
            m.attempts = 0;
        }
    }
}

/// The address warming asks for, so a test can hold it against the one the row
/// will look up. They are built in two places and must not drift.
pub fn setVisibleRangeForTest(first: usize, last: usize) void {
    g_visible_first = first;
    g_visible_last = last;
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
/// How many picture slots are currently held, and by which notes.
pub fn mediaSlotNoteIdsForTest(out: []i64) usize {
    var n: usize = 0;
    for (&g_media) |*m| {
        if (!m.used or n == out.len) continue;
        out[n] = m.note_id;
        n += 1;
    }
    return n;
}
pub fn resetMediaForTest() void {
    for (&g_media) |*m| m.down.release();
    g_media = [_]MediaSlot{.{}} ** max_media_images;
    profile_cache.g_image_clock = 0;
}

/// How many slots are holding a half-assembled picture. Zero at rest: a slice
/// buffer belongs to one fetch and dies with it.
pub fn mediaPartialCountForTest() usize {
    var n: usize = 0;
    for (&g_media) |*m| {
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
/// Feeds one delivered slice to a profile's face, exactly as a 206 does.
pub fn appendAvatarSliceForTest(pubkey: [32]u8, body: []const u8) ?SliceOutcome {
    const p = lookupProfile(pubkey) orelse return null;
    return p.down.append(body);
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
pub fn proxyRefusedCountForTest() usize {
    return g_proxy_refused_count;
}

pub fn hostOfForTest(url: []const u8) []const u8 {
    return hostOf(url);
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

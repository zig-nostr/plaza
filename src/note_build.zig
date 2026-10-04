//! From event to Note: kinds, titles, imeta, media classification, and content rendering.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const article = @import("article.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Address = main.Address;
const MentionList = main.MentionList;
const Note = main.Note;
const clientOf = main.clientOf;
const clipToChars = main.clipToChars;
const contentWarningOf = main.contentWarningOf;
const firstLinkUrl = main.firstLinkUrl;
const lookupProfile = main.lookupProfile;
const max_note_images = main.max_note_images;
const noteIdOf = main.noteIdOf;
const registerAddress = main.registerAddress;
const replyParent = main.replyParent;
const wantProfile = main.wantProfile;
const wantProfileHinted = main.wantProfileHinted;
const wantQuote = main.wantQuote;
const wantQuoteHinted = main.wantQuoteHinted;

/// Builds a `Note` view-model from a stored event.
pub fn noteFrom(ev: nostr.event.Event, now_s: i64) Note {
    var note = Note{
        .created_at = ev.created_at,
        .pubkey = ev.pubkey,
        .id = noteIdOf(ev),
        .event_id = ev.id,
        .kind = ev.kind,
    };

    // Avatar initials fallback: the first pubkey byte as two hex digits, stable
    // and distinct per author, shown until an avatar image loads.
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[ev.pubkey[0] >> 4], hexdigits[ev.pubkey[0] & 0x0f] };

    setAuthor(&note, ev.pubkey);

    if (clientOf(ev)) |name| {
        const n = @min(name.len, note.client_buf.len);
        @memcpy(note.client_buf[0..n], name[0..n]);
        note.client_len = @intCast(n);
    }

    // The author's own request to have this covered. Read here, with the tags in
    // hand, for the same reason the client name is: the tags are gone by the time
    // anything draws.
    if (contentWarningOf(ev)) |reason| {
        note.warned = true;
        @memcpy(note.warning_buf[0..reason.len], reason);
        note.warning_len = @intCast(reason.len);
    }

    // Image links become pictures, so lift them out of the text and omit them
    // from the rendered content rather than showing bare URLs beside a gallery.
    //
    // The URLs are borrowed from the EVENT while it is still in hand, and the
    // omit list below borrows them again; the note keeps its own copies. A URL
    // too long for the buffer is left in the text, which is the honest fallback:
    // it is still a link the reader can open.
    //
    // Not for an article: its pictures are inside the markdown, to be drawn where
    // the author put them, and lifting the first four out of a long read would
    // hang them under its title as though they were its cover.
    var found: [max_note_images][]const u8 = undefined;
    const found_len = if (kindRender(ev.kind) == .article) 0 else collectImageUrls(ev.content, &found);
    var omit: [max_note_images][]const u8 = undefined;
    var omit_len: usize = 0;
    for (found[0..found_len]) |url| {
        if (url.len > note.images[0].url_buf.len) continue;
        const meta = imetaFor(ev.tags, url);
        // The note gets to overrule its own file names. `collectImageUrls` knows
        // only the extension, so a video a host serves as `thumb.jpg` arrives
        // here looking like a picture; declaring `m video/mp4` is the author
        // saying otherwise, and handing it to the image decoder would spend a
        // registry slot and a download on bytes that will never decode.
        //
        // Only ever to REJECT. A declared `image/` on a URL the extension does
        // not recognise is not taken as permission to fetch it: that decides to
        // download something on a stranger's say-so, and it is a separate
        // question from this one.
        if (classifyMedia(url, meta.mime) != .image) continue;
        note.images[note.images_len].set(url, meta);
        omit[omit_len] = url;
        omit_len += 1;
        note.images_len += 1;
    }

    // What text this note shows, decided by its kind rather than by assuming
    // every event keeps its words in `content`.
    //
    // Only the body is decided here. What a card DRAWS around the body, the
    // chip naming a kind nothing can render, belongs where the card is built,
    // because the body buffer has no way to say "there is nothing to say".
    switch (kindRender(ev.kind)) {
        // Content: `nostr:` mentions rewritten to @name (or a short @npub),
        // copied whole-codepoint so a split multi-byte sequence never reaches
        // the shaper.
        .note, .media => {
            note.content_len = @intCast(renderContentInto(&note.content_buf, ev.content, omit[0..omit_len], &note.mentions));
        },
        // An article's content is markdown, and a card is not where anybody
        // asked to read markdown. The `title` tag is the one line of it that
        // belongs in a row. Without a title there is nothing honest to show,
        // so the card falls to the unsupported chip rather than to the body.
        .article => {
            if (titleInto(&note.content_buf, ev)) |len| note.content_len = @intCast(len);
            // The `image` tag is the article's cover, and the one picture the
            // note carries, so the reader draws it through the same path every
            // other picture takes (its slot, its disk cache, its placeholder).
            const meta = article.metaOf(ev);
            if (article.isWebUrl(meta.image) and meta.image.len <= note.images[0].url_buf.len) {
                note.images[0].set(meta.image, imetaFor(ev.tags, meta.image));
                // A cover with no declared shape is held to a wide one, so the
                // head does not reserve a portrait-sized box for a banner.
                if (note.images[0].aspect <= 0) note.images[0].aspect = article.cover_aspect;
                note.images_len = 1;
            }
        },
        // Left empty on purpose. Rendering the content of a kind nothing knows
        // how to draw is exactly the bug: a kind:1063's content is empty by
        // design and an article's was markdown, and both were painted as though
        // they were somebody's words.
        .unsupported => {},
    }

    // The first plain link, for the preview card. Read from the ORIGINAL content:
    // the rendered copy has mentions rewritten and may be capped.
    if (firstLinkUrl(ev.content, note.imageUrl(), ev.tags)) |link| {
        if (link.len <= note.link_url_buf.len) {
            @memcpy(note.link_url_buf[0..link.len], link);
            note.link_url_len = @intCast(link.len);
            // What it points at, decided once here with the note's own `imeta`
            // in hand. The tags are gone by the time anything draws.
            note.link_is_video = classifyMedia(link, imetaFor(ev.tags, link).mime) == .video;
        }
    }

    // The first quoted event (nevent/note), decoded once into a byte span the
    // body splits on, and queued for resolving.
    findQuoteRef(&note);
    if (note.quote.kind == .event) wantQuote(note.quote.id);

    // Which note this one answers, for thread nesting AND for the line the feed
    // draws above a reply. Queued into the same cache a quote uses: a reply
    // parent is the same problem, an event referenced by id that may or may not
    // be on the reader's relays, and it already has the fetching, the backoff
    // and the eviction.
    if (replyParent(ev.kind, ev.tags)) |parent_id| {
        note.reply_parent = parent_id;
        note.has_reply_parent = true;
        wantQuote(parent_id);
    }

    note.setTime(now_s);
    return note;
}

/// NIP-22's comment kind: a reply that is not a kind:1.
///
/// Worth reading even though the raw volume is small. Ditto and Coracle publish
/// every reply as one of these whatever the parent is, and every client that
/// writes them at all writes one when the PARENT is already one, so a single
/// comment converts the whole branch beneath it. A client that cannot read them
/// does not lose an event, it loses a subtree, and it shows silence rather than
/// a gap.
pub const comment_kind: u16 = 1111;

/// NIP-18 reposts. 6 wraps a kind 1; 16 wraps anything else and carries a `k`
/// tag saying what.
pub const repost_kind: u16 = 6;
pub const generic_repost_kind: u16 = 16;

pub fn isRepostKind(kind: u16) bool {
    return kind == repost_kind or kind == generic_repost_kind;
}

/// What a repost points at: the LAST `e` tag.
///
/// The last rather than the first, which is what Amethyst reads
/// (`RepostEvent.boostedEventId()` is `tags.lastNotNullOfOrNull(ETag::parseId)`)
/// and what the dedup key below has to agree with. A repost normally carries
/// exactly one, so the two answers differ only for a malformed event, and
/// differing from the rest of the network about a malformed event is how one
/// client shows a row nobody else does.
pub fn repostTargetId(tags: []const nostr.event.Tag) ?[32]u8 {
    var last: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or tag[1].len != 64) continue;
        if (!std.mem.eql(u8, tag[0], "e")) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        last = id;
    }
    return last;
}

/// How an event of a given kind gets drawn.
///
/// Nothing branched on kind before this. `noteFrom` built a note out of any
/// event and every surface drew its `content` as a note body, which the feed
/// and the thread got away with because they filter to kind 1 upstream. The
/// quote card and `openEvent` do not filter, so a long-form article arrived as
/// a slab of raw markdown and an event whose content is empty by design arrived
/// as a card with a name, a time and nothing under it.
///
/// ONE function, so a quote card, a thread and `open_event` cannot disagree
/// about the same event. Jumble does exactly this: an allowlist in front of the
/// render chain, and everything outside it gets a card naming the kind and a
/// way to open it somewhere that can draw it
/// (`src/components/NoteContent/index.tsx:52`). Amethyst and Coracle instead
/// fall through to drawing unknown content as a text note, which is the
/// behaviour being fixed here, and they get away with it because their feeds
/// are allow-listed too.
pub const KindRender = enum {
    /// Its content is the thing to read. Kind 1 and NIP-22 comments.
    note,
    /// Its content is markdown nobody asked to read in a card, so the `title`
    /// tag stands in for it there. Opened by id it is read in full, in the
    /// reader `articlePanel` draws.
    article,
    /// The media is the point and the content is a caption, which is already
    /// what `noteFrom` does with any note carrying a picture or a video.
    media,
    /// Plaza cannot draw this. Saying so, with the kind number, beats a blank
    /// card: a reader who knows what it is can open it somewhere that can.
    unsupported,
};

pub fn kindRender(kind: u16) KindRender {
    return switch (kind) {
        1, comment_kind => .note,
        // NIP-23 long form, and its unpublished draft.
        30023, 30024 => .article,
        // NIP-68 picture, and the NIP-71 video kinds.
        20, 21, 22 => .media,
        else => .unsupported,
    };
}

/// An event's `title` tag, trimmed, or null when it is empty or carries a
/// control character. The control-character check is `clientOf`'s: both read
/// one short tag off a stranger's event and put it in a fixed row. How much of
/// it a card shows is `titleInto`'s business.
pub fn titleOf(ev: nostr.event.Event) ?[]const u8 {
    for (ev.tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "title")) continue;
        const title = std.mem.trim(u8, tag[1], " \t\r\n");
        if (title.len == 0) return null;
        for (title) |c| {
            if (c < 0x20 or c == 0x7f) return null;
        }
        return title;
    }
    return null;
}

/// The title as a card shows it, copied into `out`: whole when it fits the
/// card's budget, and otherwise cut at the last word that fits with an
/// ellipsis after it. A title stopped mid-word with nothing to say so ("what it
/// costs to bui") reads as the whole title, misspelt.
pub fn titleInto(out: []u8, ev: nostr.event.Event) ?usize {
    const title = titleOf(ev) orelse return null;
    const ellipsis = "\u{2026}";
    const clipped = clipToChars(title, article_title_chars, @min(article_title_bytes, out.len));
    if (clipped.len == title.len) {
        @memcpy(out[0..clipped.len], clipped);
        return clipped.len;
    }
    var cut = clipToChars(title, article_title_chars - 1, @min(article_title_bytes, out.len) - ellipsis.len);
    // Back to a word boundary, unless that would throw away most of it: a
    // title that is one enormous word keeps what fits.
    if (std.mem.lastIndexOfScalar(u8, cut, ' ')) |space| {
        if (space >= cut.len / 2) cut = cut[0..space];
    }
    cut = std.mem.trimEnd(u8, cut, " ,;:-");
    @memcpy(out[0..cut.len], cut);
    @memcpy(out[cut.len..][0..ellipsis.len], ellipsis);
    return cut.len + ellipsis.len;
}

/// A title is one line in a card, so it is capped like every other such string
/// here rather than allowed to fill the body buffer.
const article_title_chars: usize = 96;
const article_title_bytes: usize = 200;

/// Records the FIRST `nostr:nevent`/`note`/`naddr` reference in `note`'s
/// rendered content as a decoded event id plus the byte span of its raw token,
/// so the body can split around it and draw an embedded quote card. A second
/// reference, an `naddr` that is not an article, or an undecodable token is left
/// as plain text (`.none`).
///
/// An `naddr` has no id, so its card is keyed by the address's stand-in key (see
/// `Address.key`). Jumble embeds all three the same way
/// (src/lib/content-parser.ts:62, src/components/Embedded/EmbeddedNote.tsx:11).
pub fn findQuoteRef(note: *Note) void {
    @setRuntimeSafety(true); // Byte spans of a token inside the note's own content.
    const text = note.content();
    var scratch: [16 * 1024]u8 = undefined;
    var i: usize = 0;
    var found_addr: ?Address = null;
    while (i < text.len) : (i += 1) {
        // The token starts at a `nostr:` prefix, or a bare `nevent1`/`note1`, but
        // only at a word boundary, so one embedded in a URL (`…/nostr:nevent…`)
        // or a longer token is left alone rather than split into a spurious card.
        var body_start = i;
        if (std.mem.startsWith(u8, text[i..], "nostr:")) {
            if (!refPrecededByBoundary(text, i)) continue;
            body_start = i + "nostr:".len;
        } else if (std.mem.startsWith(u8, text[i..], "nevent1") or std.mem.startsWith(u8, text[i..], "note1") or std.mem.startsWith(u8, text[i..], "naddr1")) {
            if (!refPrecededByBoundary(text, i)) continue;
        } else continue;

        const rest = text[body_start..];
        if (!std.mem.startsWith(u8, rest, "nevent1") and !std.mem.startsWith(u8, rest, "note1") and !std.mem.startsWith(u8, rest, "naddr1")) continue;
        var j: usize = 0;
        while (j < rest.len and isBech32Char(rest[j])) j += 1;
        const token = rest[0..j];

        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const arena = fba.allocator();
        const id: ?[32]u8 = if (std.mem.startsWith(u8, token, "nevent1")) blk: {
            const ptr = nostr.nip19.decodeNevent(arena, token) catch break :blk null;
            // The relays the address named, recorded here because here is where
            // they were being decoded and dropped. `Note.quote` deliberately
            // does not carry them: it is a field on every note in the feed
            // array, and this is two URLs that belong to one cache entry.
            if (ptr.relays.len > 0) wantQuoteHinted(ptr.id, ptr.relays);
            break :blk ptr.id;
        } else if (std.mem.startsWith(u8, token, "naddr1")) blk: {
            const ptr = nostr.nip19.decodeNaddr(arena, token) catch break :blk null;
            // Only the kinds with a screen. Any other address stays the text it
            // was, as it always has.
            const addr = Address.make(ptr.kind, ptr.pubkey, ptr.identifier) orelse break :blk null;
            found_addr = addr;
            break :blk registerAddress(addr, ptr.relays);
        } else (nostr.nip19.decodeNote(arena, token) catch null);

        if (id) |event_id| {
            note.quote = .{ .kind = .event, .id = event_id, .off = @intCast(i), .len = @intCast((body_start - i) + j), .addr = found_addr };
            return;
        }
    }
}

/// A byte count as a reader reads it: `240 KB`, `1.4 MB`. Decimal units, because
/// that is what the file's own host quotes and what the note author copied.
pub fn byteSize(arena: std.mem.Allocator, bytes: u32) []const u8 {
    if (bytes < 1000) return std.fmt.allocPrint(arena, "{d} B", .{bytes}) catch "";
    if (bytes < 1_000_000) return std.fmt.allocPrint(arena, "{d} KB", .{bytes / 1000}) catch "";
    const mb = @as(f32, @floatFromInt(bytes)) / 1_000_000.0;
    return std.fmt.allocPrint(arena, "{d:.1} MB", .{mb}) catch "";
}

/// What a note's NIP-92 `imeta` tag says about `url`: its pixel dimensions, its
/// alt text and its blurhash. One walk, because the picture's chrome wants all
/// three and the tag is one place.
pub const Imeta = struct {
    width: u16 = 0,
    height: u16 = 0,
    /// A slice of the EVENT's memory, so it lives as long as the event does. The
    /// caller copies what it wants to keep.
    alt: []const u8 = "",
    blurhash: []const u8 = "",
    /// The file's size in bytes, as the note claims it. The only source there is:
    /// the SDK's fetch response carries no headers, so there is no Content-Length
    /// to read, and with previews off nothing is fetched at all.
    size: u32 = 0,
    /// The `m` field: what the note says this file's type is, lowercase, from
    /// NIP-94 by way of NIP-92. A slice of the EVENT's memory, like `alt`.
    ///
    /// It is what tells a video named `.jpg` from a picture. See `classifyMedia`
    /// for why a type nobody recognises is treated as nothing said.
    mime: []const u8 = "",

    /// Height over width, or 0 when the tag says nothing. Knowing the shape
    /// before the bytes arrive is what lets a row reserve exactly the right
    /// space, so nothing shifts when the picture lands.
    pub fn aspect(self: Imeta) f32 {
        if (self.width == 0 or self.height == 0) return 0;
        return @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(self.width));
    }
};

pub fn imetaFor(tags: []const nostr.event.Tag, url: []const u8) Imeta {
    @setRuntimeSafety(true); // Reads fields out of a tag the note's author wrote.
    for (tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "imeta")) continue;
        var matches_url = false;
        var found: Imeta = .{};
        for (tag[1..]) |field| {
            if (std.mem.startsWith(u8, field, "url ")) {
                matches_url = std.mem.eql(u8, std.mem.trim(u8, field[4..], " "), url);
            } else if (std.mem.startsWith(u8, field, "dim ")) {
                const dim = std.mem.trim(u8, field[4..], " ");
                const x = std.mem.indexOfScalar(u8, dim, 'x') orelse continue;
                // Written as floats by some clients, so parse wide and narrow.
                const w = std.fmt.parseFloat(f32, dim[0..x]) catch continue;
                const h = std.fmt.parseFloat(f32, dim[x + 1 ..]) catch continue;
                if (w > 0 and h > 0 and w < 65536 and h < 65536) {
                    found.width = @intFromFloat(w);
                    found.height = @intFromFloat(h);
                }
            } else if (std.mem.startsWith(u8, field, "alt ")) {
                found.alt = std.mem.trim(u8, field[4..], " ");
            } else if (std.mem.startsWith(u8, field, "size ")) {
                found.size = std.fmt.parseInt(u32, std.mem.trim(u8, field[5..], " "), 10) catch 0;
            } else if (std.mem.startsWith(u8, field, "blurhash ")) {
                found.blurhash = std.mem.trim(u8, field["blurhash ".len..], " ");
            } else if (std.mem.startsWith(u8, field, "m ")) {
                found.mime = std.mem.trim(u8, field[2..], " ");
            }
        }
        if (matches_url) return found;
    }
    return .{};
}

/// The aspect (height over width) the note's own NIP-92 `imeta` tag declares for
/// `url`, or 0 when it says nothing. An `imeta` tag reads
/// `["imeta", "url https://…", "dim 882x302", …]`; dimensions are sometimes
/// written as floats, so both forms parse.
pub fn imetaAspect(tags: []const nostr.event.Tag, url: []const u8) f32 {
    for (tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "imeta")) continue;
        var matches_url = false;
        var aspect: f32 = 0;
        for (tag[1..]) |field| {
            if (std.mem.startsWith(u8, field, "url ")) {
                matches_url = std.mem.eql(u8, std.mem.trim(u8, field[4..], " "), url);
            } else if (std.mem.startsWith(u8, field, "dim ")) {
                const dim = std.mem.trim(u8, field[4..], " ");
                const x = std.mem.indexOfScalar(u8, dim, 'x') orelse continue;
                const w = std.fmt.parseFloat(f32, dim[0..x]) catch continue;
                const h = std.fmt.parseFloat(f32, dim[x + 1 ..]) catch continue;
                if (w > 0 and h > 0) aspect = h / w;
            }
        }
        if (matches_url and aspect > 0) return aspect;
    }
    return 0;
}

/// What a URL points at, once the note has had its say about it.
pub const MediaKind = enum { image, video, other };

const image_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
/// What Amethyst carries, minus the audio half. See `classifyMedia`.
const video_exts = [_][]const u8{ ".mp4", ".webm", ".mov", ".m4v", ".avi", ".mkv", ".mpg", ".mpeg", ".m3u8" };

/// The end of the path: the first `?` or the first `#`, whichever comes first.
///
/// Both, not just the query. `…/clip.mp4#t=30` is a real address that names a
/// start time, and stopping only at `?` reads its extension as `.mp4#t=30` and
/// decides it is not a video.
fn urlPathEnd(url: []const u8) usize {
    return std.mem.indexOfAny(u8, url, "?#") orelse url.len;
}

/// Whether the path ends in one of `exts`.
///
/// The dot has to be a real extension dot: after the last `/`, so a host like
/// `cdn.mp4.example/watch` is not a video, and present at all, so a path that
/// merely ends in the letters is not either.
fn hasExtensionIn(url: []const u8, exts: []const []const u8) bool {
    const path = url[0..urlPathEnd(url)];
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (slash != null and dot < slash.?) return false;
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

/// What a URL points at, given what the note's `imeta` said its type was.
///
/// Amethyst's rule, which is three tiers rather than two, and the third is the
/// one worth keeping: a mime we RECOGNISE wins over the extension in both
/// directions, a mime we do NOT recognise is treated as no declaration at all
/// and the extension decides, and only then is it neither. Collapsing the first
/// two into `startsWith("video/") or looksLikeVideo(url)` is exactly what their
/// regression test says they replaced, because it made a video named `.jpg`
/// render as a picture.
///
/// `m` comes from NIP-94 by way of NIP-92, which says an `imeta` MAY carry any
/// NIP-94 field and delegates the vocabulary; NIP-94 defines `m` as a lowercase
/// MIME type.
///
/// AUDIO IS NOT VIDEO HERE, and that is a deliberate difference from Amethyst.
/// They fold the two together because they have one player for both. Plaza has
/// neither, so calling an `.mp3` a video would put a video card on a sound file.
/// It stays an ordinary link until there is something true to say about it.
pub fn classifyMedia(url: []const u8, mime: []const u8) MediaKind {
    if (std.ascii.startsWithIgnoreCase(mime, "image/")) return .image;
    if (std.ascii.startsWithIgnoreCase(mime, "video/")) return .video;
    // Anything else declared, including `audio/` and a mime that is nonsense,
    // falls through to the extension rather than vetoing it.
    if (hasExtensionIn(url, &image_exts)) return .image;
    if (hasExtensionIn(url, &video_exts)) return .video;
    return .other;
}

/// Whether a URL names an image file. By extension, which is what Nostr media
/// hosts serve; a link without one is an ordinary link.
pub fn looksLikeImageUrl(url: []const u8) bool {
    return hasExtensionIn(url, &image_exts);
}

/// The first image URL in `content`, or null. Recognised by extension, which is
/// what Nostr media hosts serve; a link without one stays ordinary text.
/// A URL's host, as a reader says it: no scheme, no `www.`, no path. One
/// spelling, because two of them drift and then two places disagree about what
/// the same address is called.
pub fn urlHost(url: []const u8) []const u8 {
    var rest = url;
    inline for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, rest, scheme)) rest = rest[scheme.len..];
    }
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest["www.".len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    return rest;
}

pub fn firstImageUrl(content: []const u8) ?[]const u8 {
    @setRuntimeSafety(true); // Same walk as firstLinkUrl, matching an extension at the end of a run.
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] != 'h') continue;
        if (!std.mem.startsWith(u8, content[i..], "http://") and !std.mem.startsWith(u8, content[i..], "https://")) continue;
        // The URL runs to the first whitespace.
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        const url = content[i..j];
        // Ignore a trailing bare query string when matching the extension.
        const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..path_end];
        for (exts) |ext| {
            if (std.ascii.endsWithIgnoreCase(path, ext)) return url;
        }
        i = j;
    }
    return null;
}

/// Every image URL in `content`, in the order written, up to `out.len`.
///
/// The same walk as `firstImageUrl`, which it now backs: a note carrying three
/// pictures is ordinary, and taking only the first left the other two sitting in
/// the body as raw links beside a gallery that had room for them.
pub fn collectImageUrls(content: []const u8, out: [][]const u8) usize {
    @setRuntimeSafety(true); // Walks a stranger's content and indexes `out` as it goes.
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
    var found: usize = 0;
    var i: usize = 0;
    while (i < content.len and found < out.len) : (i += 1) {
        if (content[i] != 'h') continue;
        if (!std.mem.startsWith(u8, content[i..], "http://") and !std.mem.startsWith(u8, content[i..], "https://")) continue;
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        const url = content[i..j];
        const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..path_end];
        for (exts) |ext| {
            if (std.ascii.endsWithIgnoreCase(path, ext)) {
                out[found] = url;
                found += 1;
                break;
            }
        }
        i = j;
    }
    return found;
}

/// Copies note content into `dst`, rewriting NIP-27 `nostr:npub…`/`nostr:nprofile…`
/// mentions into a readable `@name` (from the profile cache) or a short `@npub`,
/// and dropping every URL in `omit` (the ones drawn as pictures) wherever they
/// appear.
/// Plain text is copied one whole codepoint at a time and stops at `dst`'s
/// capacity, so the buffer never ends mid-sequence. Returns the byte length.
pub fn renderContent(dst: []u8, src: []const u8, omit: []const u8) usize {
    const one = [_][]const u8{omit};
    return renderContentInto(dst, src, if (omit.len == 0) &.{} else &one, null);
}
pub fn renderContentInto(dst: []u8, src: []const u8, omit: []const []const u8, mentions: ?*MentionList) usize {
    @setRuntimeSafety(true); // Copies a stranger's content into a fixed buffer, offset by offset.
    // Mention decoding needs an allocator for bech32 scratch; a stack buffer
    // covers it without touching the heap for every note parsed. A pathological
    // mention that will not fit simply stays as its raw token.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const arena = fba.allocator();

    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        // Every picture's URL comes out, not just the first. Longest match wins,
        // so one URL that is a prefix of another cannot leave the tail of the
        // longer one stranded in the text.
        var skipped: usize = 0;
        for (omit) |gone| {
            if (gone.len > skipped and std.mem.startsWith(u8, src[i..], gone)) skipped = gone.len;
        }
        if (skipped > 0) {
            i += skipped;
            continue;
        }
        if (parseMentionAt(arena, src, i)) |m| {
            var label_buf: [80]u8 = undefined;
            const label = mentionLabel(m.pubkey, &label_buf);
            // Before the copy, so a label that does not fit is not recorded as
            // one that did: the break below leaves the buffer ending where the
            // last whole thing ended.
            if (out + label.len > dst.len) break;
            if (mentions) |list| list.record(out, label.len, m.pubkey);
            @memcpy(dst[out..][0..label.len], label);
            out += label.len;
            i = m.end;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        const take = @min(seq_len, src.len - i);
        // Emoji pass through as themselves; the invisible codepoints between
        // them do not, because a renderer that paints a block for what it
        // cannot find paints one for a variation selector too.
        //
        // Display only. `dst` is the note's render buffer; the event this came
        // from is signed and is not touched, and nothing composed goes through
        // here.
        const wrote = writeDisplaySeq(dst[out..], src[i..][0..take]) orelse break;
        out += wrote;
        i += take;
    }
    // Lifting a URL out can leave whitespace stranded at either edge.
    const trimmed = std.mem.trim(u8, dst[0..out], " \t\r\n");
    if (trimmed.len != out) {
        if (mentions) |list| list.rebase(@intFromPtr(trimmed.ptr) - @intFromPtr(dst.ptr), trimmed.len);
        std.mem.copyForwards(u8, dst[0..trimmed.len], trimmed);
        return trimmed.len;
    }
    return out;
}

/// Codepoints that are INVISIBLE by definition and must never reach a renderer
/// that draws a block for what it cannot find.
///
/// A variation selector is the one that shows: "\u{2620}\u{FE0F}" is a skull
/// followed by U+FE0F, which asks for the colour presentation and inks nothing
/// at all. The skull is in the emoji face and draws; the selector is in no
/// face, so it came out as a solid rectangle sitting next to it. Joiners, the
/// bidi marks and the skin tone modifiers are the same story: meaningful to
/// text, never ink of their own.
///
/// macOS is unaffected. CoreText reads these as the presentation and joining
/// instructions they are, so dropping them there would turn a colour emoji into
/// a monochrome one and split families into their parts.
pub fn invisibleForDisplay(cp: u21) bool {
    return switch (cp) {
        0x200B...0x200F => true, // zero-width space, joiners, bidi marks
        0x202A...0x202E => true, // bidi embedding and overrides
        0x2060...0x2064 => true, // word joiner and the invisible operators
        0xFE00...0xFE0F => true, // variation selectors
        0x20E3 => true, // combining enclosing keycap
        0x1F3FB...0x1F3FF => true, // skin tone modifiers
        else => false,
    };
}

/// The ASCII letter or digit a Mathematical Alphanumeric codepoint is a styled
/// copy of, or null for anything outside that block.
///
/// U+1D400 to U+1D7FF is where the "fancy text" generators live: 𝐁𝐨𝐛, 𝕊𝕒𝕥,
/// 𝓐𝓵𝓲, 𝕾𝖊𝖗. Unicode put thirteen complete styled alphabets and five styled
/// digit runs there for MATHEMATICS, where the style carries meaning (a bold R
/// and a double-struck R are different objects), and social display names have
/// used it as a font picker ever since.
///
/// It is 996 codepoints and NOTHING Plaza ships covers one of them, so off
/// macOS a name written this way had no glyph anywhere and the renderer filled
/// a solid rectangle per word. That is the whole of what a reader saw: two
/// blocks where a name should be. This was reported against a real account
/// whose `display_name` is 𝕾𝖊𝖗 𝕾𝖑𝖊𝖊𝖕𝖞, Mathematical Bold Fraktur, ten
/// codepoints, none of them drawable.
///
/// A font would not fix it either, or not cheaply: covering the block properly
/// means carrying thirteen more alphabets for a decorative effect. Folding is
/// the better trade. The characters ARE the Latin letters, styled, so folding
/// gives the reader the name back rather than a substitute, and it costs
/// nothing to download.
///
/// Pure arithmetic over the runs. Each alphabet is 52 codepoints, A to Z then
/// a to z; each digit run is 10. The block has holes where the character
/// already existed in Letterlike Symbols (italic h is U+210E, not U+1D455), and
/// mapping a hole is harmless because an unassigned codepoint cannot appear in
/// real text.
///
/// The Greek runs (U+1D6A8 to U+1D7CB) are deliberately NOT folded. They would
/// need a u21 result and a re-encode, the bundled Noto face already draws base
/// Greek so the payoff is a rarer name still, and this is a bug fix rather than
/// a Unicode project.
pub fn foldMathAlnum(cp: u21) ?u8 {
    const alphabets = [_]u21{
        0x1D400, // bold
        0x1D434, // italic
        0x1D468, // bold italic
        0x1D49C, // script
        0x1D4D0, // bold script
        0x1D504, // fraktur
        0x1D538, // double-struck
        0x1D56C, // bold fraktur
        0x1D5A0, // sans-serif
        0x1D5D4, // sans-serif bold
        0x1D608, // sans-serif italic
        0x1D63C, // sans-serif bold italic
        0x1D670, // monospace
    };
    for (alphabets) |start| {
        if (cp >= start and cp < start + 52) {
            const offset: u8 = @intCast(cp - start);
            return if (offset < 26) 'A' + offset else 'a' + (offset - 26);
        }
    }
    const digits = [_]u21{ 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6 };
    for (digits) |start| {
        if (cp >= start and cp < start + 10) return '0' + @as(u8, @intCast(cp - start));
    }
    return null;
}

/// Writes one UTF-8 sequence into `dst`. Null when it would not fit, zero when
/// the sequence is invisible and is dropped.
///
/// The emoji themselves pass through untouched: the renderer reaches the
/// registered colour face for them (see `theme.emoji_ttf`). Only the invisible
/// codepoints are filtered, because a renderer that draws a block for what it
/// cannot find would draw one for them.
fn writeDisplaySeq(dst: []u8, seq: []const u8) ?usize {
    if (comptime builtin.os.tag != .macos) {
        if (std.unicode.utf8Decode(seq)) |cp| {
            if (invisibleForDisplay(cp)) return 0;
        } else |_| {}
    }
    if (seq.len > dst.len) return null;
    @memcpy(dst[0..seq.len], seq);
    return seq.len;
}

/// Copies text this app DRAWS into a fixed buffer, emoji and all.
///
/// A display name is not note content and never went through
/// `renderContentInto`, so an emoji in somebody's name stayed as a codepoint no
/// face off macOS can draw, and painted as a solid block. "Dr. The Daniel" with
/// a raised hand after it is what this was found on.
///
/// Display buffers ONLY. The profile editor seeds itself from the raw JSON
/// rather than from this cache, so nothing dropped here is ever published back
/// into somebody's profile.
pub fn copyDisplayText(dst: []u8, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        const take = @min(seq_len, src.len - i);
        // Folded here rather than in `writeDisplaySeq`, which note bodies also
        // go through. A fold changes the byte count, and `renderContentInto`
        // records mention offsets into the buffer it is filling, so moving text
        // under them would point every mention at the wrong span. Display names
        // carry no offsets, so they are the safe place for it, and they are
        // where the bug was reported.
        if (comptime builtin.os.tag != .macos) {
            if (std.unicode.utf8Decode(src[i..][0..take])) |cp| {
                if (foldMathAlnum(cp)) |ascii| {
                    if (out >= dst.len) break;
                    dst[out] = ascii;
                    out += 1;
                    i += take;
                    continue;
                }
            } else |_| {}
        }
        const wrote = writeDisplaySeq(dst[out..], src[i..][0..take]) orelse break;
        out += wrote;
        i += take;
    }
    return out;
}
/// A parsed `nostr:` mention at `src[i]`: the byte just past its token, and the
/// referenced pubkey. Null when `src[i]` is not the start of one.
pub fn parseMentionAt(arena: std.mem.Allocator, src: []const u8, i: usize) ?struct { end: usize, pubkey: [32]u8 } {
    @setRuntimeSafety(true); // Walks a bech32 run whose length the note chose.
    const prefix = "nostr:";
    var body_start = i;
    if (std.mem.startsWith(u8, src[i..], prefix)) {
        // The same boundary guard the bare form below has always had. Without
        // it a contrived `https://example.com/nostr:npub1…` parses as a
        // mention, and now that the composer turns mentions into `p` tags that
        // is a notification sent to a real stranger on the strength of a path
        // segment in somebody else's link.
        if (!refPrecededByBoundary(src, i)) return null;
        body_start = i + prefix.len;
    } else {
        // A bare npub/nprofile counts too (plenty of clients write them without
        // the scheme), but only at a word boundary, so one inside a URL or a
        // longer token is left alone.
        const bare = std.mem.startsWith(u8, src[i..], "npub1") or std.mem.startsWith(u8, src[i..], "nprofile1");
        if (!bare) return null;
        if (i > 0 and (isBech32Char(src[i - 1]) or src[i - 1] == '/' or src[i - 1] == ':')) return null;
    }
    const rest = src[body_start..];
    var j: usize = 0;
    while (j < rest.len and isBech32Char(rest[j])) j += 1;
    if (j == 0) return null;
    const token = rest[0..j];
    const end = body_start + j;

    if (std.mem.startsWith(u8, token, "npub1")) {
        const pk = nostr.nip19.decodeNpub(arena, token) catch return null;
        return .{ .end = end, .pubkey = pk };
    }
    if (std.mem.startsWith(u8, token, "nprofile1")) {
        const pp = nostr.nip19.decodeNprofile(arena, token) catch return null;
        // Same as the quote side: decoded here, and thrown away here until now.
        if (pp.relays.len > 0) wantProfileHinted(pp.pubkey, pp.relays);
        return .{ .end = end, .pubkey = pp.pubkey };
    }
    return null;
}

/// Writes `@` + the cached display name (or a short npub) for `pubkey` into
/// `buf`, returning the written slice. `buf` should be at least 80 bytes.
fn mentionLabel(pubkey: [32]u8, buf: []u8) []const u8 {
    @setRuntimeSafety(true); // Writes a display name of somebody else's choosing into a fixed buffer.
    buf[0] = '@';
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) {
            const n = @min(p.name_len, buf.len - 1);
            @memcpy(buf[1..][0..n], p.name_buf[0..n]);
            return buf[0 .. 1 + n];
        }
    }
    // No name for this one: ask for it, so the next rebuild can show it.
    wantProfile(pubkey);
    const npub = abbreviateNpub(buf[1..], pubkey);
    return buf[0 .. 1 + npub.len];
}

/// Whether `c` is a bech32 data character (lowercase letter or digit), the run
/// that follows a `nostr:` prefix.
pub fn isBech32Char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// Whether `c` continues a hashtag word: letters, digits, underscore, or any
/// byte of a multi-byte UTF-8 sequence.
///
/// The `>= 0x80` arm is what makes `#café` and `#日本` whole words rather than
/// wreckage. Every continuation and lead byte of a UTF-8 sequence is >= 0x80 and
/// every ASCII byte is below it, so a run that ends on a byte < 0x80 always ends
/// on a codepoint boundary: the predicate cannot cut a character in half. The
/// ASCII-only version returned "caf" for the first of those and nothing at all
/// for the second, and both of those went out as tags once the composer started
/// emitting them.
///
/// It over-accepts emoji and non-ASCII punctuation as word characters. That is
/// the same trade every client here makes, and it fails toward a slightly long
/// tag rather than a truncated one.
pub fn isHashtagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Whether an event reference (`nostr:nevent1…`/`note1…`/`naddr1…`, or a bare one
/// at a word boundary) begins at `text[i]`, so a run can be accent-styled. Only
/// at a word boundary, so a `nostr:` or bare token embedded in a URL is skipped.
pub fn isEventRefStart(text: []const u8, i: usize) bool {
    if (!refPrecededByBoundary(text, i)) return false;
    var s = text[i..];
    if (std.mem.startsWith(u8, s, "nostr:")) s = s["nostr:".len..];
    return std.mem.startsWith(u8, s, "nevent1") or std.mem.startsWith(u8, s, "note1") or std.mem.startsWith(u8, s, "naddr1");
}

/// Whether `text[i]` sits at a word boundary for a nostr reference: the start, or
/// after a character that could not be part of a URL or bech32 run. Keeps a
/// `nostr:nevent…`/bare token embedded in a URL from being matched.
pub fn refPrecededByBoundary(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const c = text[i - 1];
    return !(std.ascii.isAlphanumeric(c) or c == '/' or c == ':' or c == '.' or c == '-' or c == '_' or c == '@');
}

pub fn setAuthor(note: *Note, pubkey: [32]u8) void {
    const s = abbreviateNpub(&note.author_buf, pubkey);
    note.author_len = @intCast(s.len);
}

/// Writes an abbreviated npub (`npub1p9x8h…7k2q`), the canonical Nostr
/// identifier, for `pubkey` into `out`, returning the written slice; falls back
/// to a short hex prefix if bech32 encoding fails. The result always lives in
/// `out` (never the scratch buffer), so the caller can hold it safely. `out`
/// should be at least 20 bytes for the abbreviated form. bech32's encoder grows
/// an ArrayList and hands back an owned slice, so on a fixed buffer the
/// intermediate reallocations accumulate well past the ~63-char result; 1 KiB of
/// scratch covers that churn without touching the heap.
pub fn abbreviateNpub(out: []u8, pubkey: [32]u8) []const u8 {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch {
        const hexdigits = "0123456789abcdef";
        var n: usize = 0;
        while (n < 16 and n + 1 < out.len) : (n += 2) {
            out[n] = hexdigits[pubkey[n / 2] >> 4];
            out[n + 1] = hexdigits[pubkey[n / 2] & 0x0f];
        }
        return out[0..n];
    };
    if (npub.len > 18) {
        if (std.fmt.bufPrint(out, "{s}…{s}", .{ npub[0..12], npub[npub.len - 5 ..] })) |s| return s else |_| {}
    }
    const n = @min(npub.len, out.len);
    @memcpy(out[0..n], npub[0..n]);
    return out[0..n];
}

/// The largest prefix of `s` no longer than `max` that ends on a UTF-8
/// codepoint boundary (never mid-sequence).
pub fn utf8SafeLen(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Builds a Note over `content` and runs the quote-reference scan, so a test can
/// assert what `findQuoteRef` captured (id/off/len) without a live event.
pub fn findQuoteRefForTest(content: []const u8) Note {
    var note = Note{};
    const n = @min(content.len, note.content_buf.len);
    @memcpy(note.content_buf[0..n], content[0..n]);
    note.content_len = @intCast(n);
    findQuoteRef(&note);
    return note;
}
/// A NIP-22 comment, for the inbox tests: same shape as the kind:1 builder
/// there, with the kind that makes the other vocabulary apply.
pub fn commentEventForTest(author: u8, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{author} ** 32,
        .pubkey = [_]u8{author} ** 32,
        .created_at = 100,
        .kind = comment_kind,
        .tags = tags,
        .content = "a comment",
        .sig = [_]u8{0} ** 64,
    };
}
pub fn invisibleForDisplayForTest(cp: u21) bool {
    return invisibleForDisplay(cp);
}

pub fn copyDisplayTextForTest(dst: []u8, src: []const u8) usize {
    return copyDisplayText(dst, src);
}

pub fn foldMathAlnumForTest(cp: u21) ?u8 {
    return foldMathAlnum(cp);
}

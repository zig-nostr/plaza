//! Link previews: the cache, the fetch, and reading a page's metadata.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const prefs = @import("prefs.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const Model = main.Model;
const Note = main.Note;
const cacheName = main.cacheName;
const classifyMedia = main.classifyMedia;
const imetaFor = main.imetaFor;
const isDefaultPort = main.isDefaultPort;
const isPublicHostName = main.isPublicHostName;
const link_fetch_key_base = main.link_fetch_key_base;
const mediaProxy = main.mediaProxy;
const noteCovered = main.noteCovered;
const utf8SafeLen = main.utf8SafeLen;

/// A link preview: what a page says about itself, for the card 11o draws under a
/// note that links out. Small and fixed, like every other cache here.
const link_title_cap = 96;
const link_desc_cap = 140;
const link_domain_cap = 48;
const link_cache_cap = 32;
/// How many previews may be in flight at once. The SDK has 16 effect slots for
/// everything the app does, so previews take a small, fixed share and wait their
/// turn rather than starving avatars and pictures.
const max_link_fetches = 2;
const max_link_attempts = 2;
/// How far down a thread the link scan reaches. The thread list has no visible
/// range of its own to consult, so it takes the first screenful and stops.
const thread_link_scan_cap: usize = 12;

const LinkPreview = struct {
    used: bool = false,
    /// The URL as written in the note, which is both the key and what a press
    /// opens.
    url_buf: [300]u8 = [_]u8{0} ** 300,
    url_len: u16 = 0,
    state: enum { idle, fetching, loaded, missing } = .idle,
    attempts: u8 = 0,
    requested: bool = false,
    title_buf: [link_title_cap]u8 = [_]u8{0} ** link_title_cap,
    title_len: u8 = 0,
    desc_buf: [link_desc_cap]u8 = [_]u8{0} ** link_desc_cap,
    desc_len: u8 = 0,
    domain_buf: [link_domain_cap]u8 = [_]u8{0} ** link_domain_cap,
    domain_len: u8 = 0,
    last_used: u64 = 0,

    pub fn url(self: *const LinkPreview) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    pub fn title(self: *const LinkPreview) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn description(self: *const LinkPreview) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    pub fn domain(self: *const LinkPreview) []const u8 {
        return self.domain_buf[0..self.domain_len];
    }
};
pub var g_links = [_]LinkPreview{.{}} ** link_cache_cap;
var g_link_clock: u64 = 0;

/// The host of a URL, without its `www.`: what the card shows above the title,
/// and what a reader actually checks before pressing.
///
/// The userinfo is CUT, at the last `@`, which is the whole point: a browser
/// does the same, because `https://wirth.ch@evil.tld/` is the oldest phishing
/// shape there is and a card that showed `wirth.ch@evil.tld` would be lending
/// its credibility to whoever wrote the note.
pub fn urlDomain(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    // The port is not part of the name a reader recognises.
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority, ']') == null) authority = authority[0..colon];
    }
    if (std.mem.startsWith(u8, authority, "www.")) authority = authority["www.".len..];
    return authority;
}

/// Whether a link named in a note may be fetched to preview it.
///
/// This is the one place in the app that reaches out to an address a STRANGER
/// chose, unattended, simply because a note scrolled into view. So it is narrow
/// on purpose:
///
///   - https only. Plaintext would put the reader's IP and the exact URL on the
///     wire for anyone on the path, to fetch something nobody asked for.
///   - No userinfo. `std.http.Client` turns it into an `authorization` header,
///     so `http://admin:admin@10.0.0.1/` would have Plaza posting credentials
///     to a host of the note author's choosing.
///   - No private, loopback or link-local address, and no name without a dot.
///     A note must not be able to make every reader's machine probe their own
///     network. Notary's approval API listens on 127.0.0.1 in this very session.
///   - The default port only, so a note cannot aim the reader at a service.
///
/// It cannot stop a redirect INTO one of those (the runtime follows up to
/// three), which is worth knowing and is why the fetch stays unauthenticated and
/// its body is only ever read for two meta tags.
/// Whether to ask a link what it says about itself.
///
/// The video half is the point. `previewableUrl` looks only at the AUTHORITY,
/// so it says yes to any https host, video file or not, and a video link was
/// therefore fetched as a web page to look for `og:` tags it could never have.
/// The runtime truncates a response at 256 KiB, so that was up to a quarter of
/// a megabyte of somebody's video downloaded per video in the feed, to learn
/// nothing and then mark the preview missing.
///
/// Pure over the two inputs because the fetch cannot run under test at all, the
/// same reason `updateCheckDue` is pure.
pub fn shouldPreviewLink(is_video: bool, url: []const u8) bool {
    if (is_video) return false;
    return previewableUrl(url);
}

pub fn previewableUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    if (url.len > 300) return false;
    const rest = url["https://".len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return false;
    // Userinfo, in any form.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, host, ']') == null) {
            // A port at all means a service, not a site.
            if (colon + 1 < host.len) return false;
            host = host[0..colon];
        } else {
            return false; // a bracketed IPv6 literal is never a site to preview
        }
    }
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    }
    // A bare name (`localhost`, a machine on the LAN) is not a public site.
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    if (dot == 0 or dot + 1 >= host.len) return false;
    if (std.ascii.endsWithIgnoreCase(host, ".local") or
        std.ascii.endsWithIgnoreCase(host, ".internal") or
        std.ascii.endsWithIgnoreCase(host, ".localhost")) return false;
    return !isPrivateAddress(host);
}

/// Whether a picture URL may be fetched: `http` or `https`, and a host on the
/// public internet by the lines `previewableUrl` draws for a link (no userinfo,
/// no port but the scheme's own, no bare or `.local`-style name, no private or
/// loopback address), plus the loose numeric spellings a resolver accepts for
/// one (`127.1`, `0x7f.1`, `010.0.0.1`), which only the plain four-number form
/// is taken past. `isPublicHostName` holds the host rule.
///
/// Every picture is fetched with nobody pressing anything: a note, a profile, an
/// article or a place names it and it loads as it scrolls into view. Without
/// this a stranger could have every reader's machine request a URL on its own
/// loopback or LAN, and an extension check is no obstacle (`/admin#.png`).
/// A picture that fails it is not drawn.
pub fn isPublicMediaUrl(url: []const u8) bool {
    const scheme: []const u8 = if (std.mem.startsWith(u8, url, "https://"))
        "https"
    else if (std.mem.startsWith(u8, url, "http://"))
        "http"
    else
        return false;
    const rest = url[scheme.len + "://".len ..];
    if (url.len > 2048) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (authority.len == 0) return false;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (authority[0] == '[') return false;
    var host = authority;
    // A port, only the scheme's own: any other is a different service on the
    // host, which a picture has no reason to name.
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (!isDefaultPort(scheme, authority[colon + 1 ..])) return false;
        host = authority[0..colon];
    }
    return isPublicHostName(std.mem.trimEnd(u8, host, "."));
}

/// Whether `url` is a request to the reader's own media proxy, which is theirs
/// to point anywhere, their own network included.
fn isProxiedUrl(url: []const u8) bool {
    const proxy = mediaProxy();
    if (!prefs.g_media_proxy_on or proxy.len == 0) return false;
    if (!std.mem.startsWith(u8, url, proxy)) return false;
    if (std.mem.endsWith(u8, proxy, "/")) return true;
    return url.len > proxy.len and (url[proxy.len] == '/' or url[proxy.len] == '?');
}

/// The last check before a picture is requested: through the reader's proxy, or
/// straight from a public host. Upstream every picture URL is already gated when
/// it is read, so this only catches a path that forgot.
pub fn mediaFetchAllowed(url: []const u8) bool {
    return isProxiedUrl(url) or isPublicMediaUrl(url);
}

pub fn mediaFetchAllowedForTest(url: []const u8) bool {
    return mediaFetchAllowed(url);
}

/// Whether a host is a literal address inside a range that belongs to the
/// reader's own machine or network.
pub fn isPrivateAddress(host: []const u8) bool {
    var parts: [4]u16 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (n == 4) return false;
        parts[n] = std.fmt.parseInt(u16, part, 10) catch return false;
        if (parts[n] > 255) return false;
        n += 1;
    }
    if (n != 4) return false; // not an IPv4 literal at all
    return switch (parts[0]) {
        0, 10, 127 => true,
        169 => parts[1] == 254, // link-local
        172 => parts[1] >= 16 and parts[1] <= 31,
        192 => parts[1] == 168,
        100 => parts[1] >= 64 and parts[1] <= 127, // carrier-grade NAT
        else => false,
    };
}

/// The first plain link in a note's content: the one the card previews. An image
/// URL is not one (it is drawn as the picture), and neither is anything inside a
/// `nostr:` token.
/// `tags` so the note's own `imeta` decides what a URL is, the same way the
/// image collection does. Without it the two disagree: a video the host serves
/// as `thumb.jpg` is rejected as an image by one and skipped as an image by
/// the other, and lands in no bucket at all.
pub fn firstLinkUrl(content: []const u8, image_url: []const u8, tags: []const nostr.event.Tag) ?[]const u8 {
    @setRuntimeSafety(true); // Scans a stranger's content for a URL run.
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (!std.mem.startsWith(u8, content[i..], "https://") and !std.mem.startsWith(u8, content[i..], "http://")) continue;
        if (i > 0 and !std.ascii.isWhitespace(content[i - 1])) continue;
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        // A trailing sentence mark is punctuation, not part of the address.
        var end = j;
        while (end > i and (content[end - 1] == '.' or content[end - 1] == ',' or content[end - 1] == ')')) end -= 1;
        const candidate = content[i..end];
        if (candidate.len > 300) {
            i = j;
            continue;
        }
        if (image_url.len > 0 and std.mem.eql(u8, candidate, image_url)) {
            i = j;
            continue;
        }
        if (classifyMedia(candidate, imetaFor(tags, candidate).mime) == .image) {
            i = j;
            continue;
        }
        return candidate;
    }
    return null;
}

/// The cache entry for `url`, claimed if it is not already there. Evicts the
/// least recently drawn entry that is not mid-fetch, like the other caches.
pub fn wantLink(url: []const u8) ?*LinkPreview {
    if (url.len == 0 or url.len > 300) return null;
    for (&g_links) |*l| {
        if (l.used and std.mem.eql(u8, l.url(), url)) return l;
    }
    var victim: ?*LinkPreview = null;
    for (&g_links) |*l| {
        if (!l.used) {
            victim = l;
            break;
        }
        if (l.state == .fetching) continue;
        // Nor one already wanted in THIS pass: a screen with more links than
        // slots would otherwise evict an entry it needs a moment later, reset
        // its state and its attempt count, and re-fetch the same pages from the
        // same strangers' servers on every tick, forever. The media scan learned
        // this the same way.
        if (l.last_used == g_link_clock) continue;
        if (victim == null or l.last_used < victim.?.last_used) victim = l;
    }
    // Nothing free and nothing spare: this link simply goes unpreviewed rather
    // than taking a slot off something on screen.
    const slot = victim orelse return null;
    slot.* = .{ .used = true };
    @memcpy(slot.url_buf[0..url.len], url);
    slot.url_len = @intCast(url.len);
    const host = urlDomain(url);
    const host_len = @min(host.len, slot.domain_buf.len);
    @memcpy(slot.domain_buf[0..host_len], host[0..host_len]);
    slot.domain_len = @intCast(host_len);
    return slot;
}
pub fn linkFor(url: []const u8) ?*LinkPreview {
    for (&g_links) |*l| {
        if (l.used and std.mem.eql(u8, l.url(), url)) return l;
    }
    return null;
}

/// Asks for the pages the reader can actually see. Gated by the previews
/// setting, like pictures: with it off, no page learns it was linked to.
pub fn scanLinkFetches(fx: *Effects, model: *const Model) void {
    if (!prefs.g_media_previews) return;
    g_link_clock += 1;
    var fired: usize = 0;
    if (model.viewing_profile != null) {
        // A person's page occludes the feed. Without this branch the hidden
        // feed keeps reaching out to hosts nobody is looking at, and the page
        // that IS being read gets no link cards at all.
        const shown = @min(model.thread_notes_len, thread_link_scan_cap);
        for (model.thread_notes[0..shown]) |*note| fireLink(fx, note, &fired);
        return;
    }
    if (model.viewing_thread != 0) {
        // The note being read, and the first screenful under it. Walking the
        // whole conversation would reach out to every host linked anywhere in
        // it, including replies the reader never scrolls to.
        fireLink(fx, &model.thread_root, &fired);
        const shown = @min(model.thread_notes_len, thread_link_scan_cap);
        for (model.thread_notes[0..shown]) |*note| fireLink(fx, note, &fired);
        return;
    }
    const range = model.visibleRange();
    var i = range.first;
    while (i <= range.last and i < model.notes_len) : (i += 1) fireLink(fx, &model.notes[i], &fired);
}

fn fireLink(fx: *Effects, note: *const Note, fired: *usize) void {
    if (!note.hasLink()) return;
    // A covered note links nowhere until it is uncovered: the page behind the
    // link would learn it was read, and its title is a second way to see the note.
    if (noteCovered(note)) return;
    if (!shouldPreviewLink(note.link_is_video, note.linkUrl())) return;
    const slot = wantLink(note.linkUrl()) orelse return;
    // Stamped first, so the eviction guard above counts this entry as wanted in
    // this pass whatever happens next.
    slot.last_used = g_link_clock;
    if (slot.state != .idle) return;
    if (slot.attempts >= max_link_attempts) {
        slot.state = .missing;
        return;
    }
    if (loadCachedLink(slot)) return;
    if (fired.* >= max_link_fetches) return;
    fired.* += 1;
    slot.state = .fetching;
    slot.attempts += 1;
    const index = (@intFromPtr(slot) - @intFromPtr(&g_links[0])) / @sizeOf(LinkPreview);
    fx.fetch(.{
        .key = link_fetch_key_base + index,
        .url = slot.url(),
        .on_response = Effects.responseMsg(.link_fetched),
    });
}

/// Files what a page said about itself. The body is TRUNCATED at 256 KiB by the
/// runtime and that is fine here, unlike an image: `og:` tags live in the head,
/// so a cut tail costs nothing. Every other handler in this app rejects a
/// truncated body, correctly, because half a picture is garbage.
pub fn handleLinkFetched(response: native_sdk.EffectResponse) void {
    const index = response.key - link_fetch_key_base;
    if (index >= g_links.len) return;
    const slot = &g_links[index];
    if (!slot.used or slot.state != .fetching) return;
    if (response.outcome == .rejected) {
        // Every effect slot was busy. Not a failure of the page: try again.
        slot.state = .idle;
        slot.attempts -|= 1;
        return;
    }
    if (response.outcome != .ok or response.status < 200 or response.status >= 300) {
        slot.state = if (slot.attempts >= max_link_attempts) .missing else .idle;
        return;
    }
    const meta = parsePageMeta(response.body);
    storeLinkMeta(slot, .{ .title = meta.heading(), .description = meta.description });
    slot.state = if (slot.title_len == 0) .missing else .loaded;
    if (slot.state == .loaded) cacheLink(slot);
}

/// Copies what the page said into the entry's own buffers: the response body is
/// recycled the moment this returns.
pub fn storeLinkMeta(slot: *LinkPreview, meta: PageMeta) void {
    const title = std.mem.trim(u8, meta.title, " \t\r\n");
    const desc = std.mem.trim(u8, meta.description, " \t\r\n");
    const t = @min(utf8SafeLen(title, slot.title_buf.len), slot.title_buf.len);
    @memcpy(slot.title_buf[0..t], title[0..t]);
    slot.title_len = @intCast(t);
    const d = @min(utf8SafeLen(desc, slot.desc_buf.len), slot.desc_buf.len);
    @memcpy(slot.desc_buf[0..d], desc[0..d]);
    slot.desc_len = @intCast(d);
}

/// `$HOME/.plaza/links/<sha256 of the url>`, holding the three lines the card
/// draws. A preview is worth keeping: the page rarely changes, and a feed
/// re-read from disk should not re-ask the whole web what it said.
fn linkCacheDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza/links", .{home});
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

fn loadCachedLink(slot: *LinkPreview) bool {
    const io = main.g_io orelse return false;
    const environ = main.g_environ orelse return false;
    var dir = linkCacheDir(io, environ) catch return false;
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(1024)) catch return false;
    defer gpa.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const title = lines.next() orelse return false;
    const desc = lines.next() orelse "";
    if (title.len == 0) return false;
    storeLinkMeta(slot, .{ .title = title, .description = desc });
    slot.state = .loaded;
    return true;
}

fn cacheLink(slot: *const LinkPreview) void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = linkCacheDir(io, environ) catch return;
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    var buf: [link_title_cap + link_desc_cap + 4]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "{s}\n{s}\n", .{ slot.title(), slot.description() }) catch return;
    dir.writeFile(io, .{ .sub_path = name, .data = data }) catch return;
}

/// What a page says about itself, read out of its head. Open Graph first, then
/// the plain HTML fallbacks, which is the order every other reader uses.
pub const PageMeta = struct {
    /// The `<title>` tag, kept separately so an Open Graph title can take
    /// precedence without erasing it when it turns out to be empty.
    title: []const u8 = "",
    og_title: []const u8 = "",
    description: []const u8 = "",

    /// What the card shows: the page's chosen title, else the document's.
    pub fn heading(self: PageMeta) []const u8 {
        return if (self.og_title.len > 0) self.og_title else self.title;
    }
};

/// Pulls `og:title`/`og:description` (falling back to `<title>` and
/// `meta name="description"`) out of `html`.
///
/// A deliberately small parser: it walks tags, and inside a `meta` tag it reads
/// the attributes it knows. It does NOT try to be an HTML parser, because it does
/// not have to be: the body arrives capped at 256 KiB, which is where the head
/// lives, and anything it cannot make sense of simply leaves the card without
/// that line rather than guessing.
pub fn parsePageMeta(html: []const u8) PageMeta {
    @setRuntimeSafety(true); // A fetched page's head, up to 256 KiB of it, and every offset below is read out of it.
    var out: PageMeta = .{};
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] != '<') continue;
        const rest = html[i + 1 ..];
        if (std.ascii.startsWithIgnoreCase(rest, "title>")) {
            const start = i + 1 + "title>".len;
            const end = std.mem.indexOfPos(u8, html, start, "<") orelse html.len;
            if (out.title.len == 0) out.title = std.mem.trim(u8, html[start..end], " \t\r\n");
            i = end;
            continue;
        }
        if (!std.ascii.startsWithIgnoreCase(rest, "meta")) continue;
        const tag_end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const tag = html[i..tag_end];
        const key = metaAttr(tag, "property") orelse metaAttr(tag, "name") orelse {
            i = tag_end;
            continue;
        };
        const content = metaAttr(tag, "content") orelse {
            i = tag_end;
            continue;
        };
        // An EMPTY value is not an answer: a template that renders
        // `content=""` when its Open Graph field is unset must not wipe the
        // page's own title. And the FIRST one wins, so a stray tag in the body
        // cannot override the head.
        if (content.len == 0) {
            i = tag_end;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "og:title")) {
            if (out.og_title.len == 0) out.og_title = content;
        } else if (std.ascii.eqlIgnoreCase(key, "og:description")) {
            if (out.description.len == 0) out.description = content;
        } else if (std.ascii.eqlIgnoreCase(key, "description") and out.description.len == 0) {
            out.description = content;
        }
        i = tag_end;
    }
    return out;
}

/// One attribute's value out of a tag, single or double quoted.
fn metaAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    @setRuntimeSafety(true); // Quote positions inside a tag the page wrote.
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(tag, i, name)) |at| {
        i = at + name.len;
        // A whole attribute name, not a suffix of another one.
        if (at > 0 and (std.ascii.isAlphanumeric(tag[at - 1]) or tag[at - 1] == '-' or tag[at - 1] == ':')) continue;
        var j = i;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '=')) j += 1;
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote != '"' and quote != '\'') continue;
        j += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, j, quote) orelse return null;
        return tag[j..end];
    }
    return null;
}

/// Files a preview as if a page had answered, for a test that renders the card.
pub fn seedLinkForTest(url: []const u8, title: []const u8, desc: []const u8) void {
    const slot = wantLink(url) orelse return;
    storeLinkMeta(slot, .{ .title = title, .description = desc });
    slot.state = .loaded;
}
pub fn setLinkPreviewForTest(url: []const u8, domain: []const u8, title: []const u8, description: []const u8) void {
    for (&g_links) |*l| {
        if (l.used) continue;
        l.* = .{ .used = true, .state = .loaded };
        const u = @min(url.len, l.url_buf.len);
        @memcpy(l.url_buf[0..u], url[0..u]);
        l.url_len = @intCast(u);
        const d = @min(domain.len, l.domain_buf.len);
        @memcpy(l.domain_buf[0..d], domain[0..d]);
        l.domain_len = @intCast(d);
        const t = @min(title.len, l.title_buf.len);
        @memcpy(l.title_buf[0..t], title[0..t]);
        l.title_len = @intCast(t);
        const c = @min(description.len, l.desc_buf.len);
        @memcpy(l.desc_buf[0..c], description[0..c]);
        l.desc_len = @intCast(c);
        return;
    }
}

pub fn clearLinkPreviewsForTest() void {
    for (&g_links) |*l| l.* = .{};
}
pub fn scanLinkFetchesForTest(fx: *Effects, model: *const Model) void {
    scanLinkFetches(fx, model);
}

/// Whether the page behind `url` has been asked for (or is being).
pub fn linkRequestedForTest(url: []const u8) bool {
    const l = linkFor(url) orelse return false;
    return l.state == .fetching or l.attempts > 0;
}

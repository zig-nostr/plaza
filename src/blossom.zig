//! Putting a picture on a Blossom media server.
//!
//! Blossom is not a NIP. An upload is `PUT /upload` (BUD-02) with the picture's
//! bytes as the body and `Authorization: Nostr <base64 event>` (BUD-11) naming
//! the file, where the event is a kind:24242 signed by the uploader with a
//! `t upload` tag, the file's sha256 in an `x` tag and an `expiration`. The
//! server answers with a blob descriptor whose `url` is where the picture now
//! lives. Servers come from the uploader's own kind:10063 list (BUD-03).
//!
//! This file is the protocol half and has no idea what a note or a profile is:
//! what a server URL may look like, the shape of the signed token, reading the
//! descriptor back, preparing the file (type, metadata stripped, sha256,
//! dimensions, blurhash) and the HTTP exchange itself. Plaza has no HTTP client
//! of its own and the SDK's fetch effect caps a request body at 64 KiB, so the
//! exchange runs on a worker thread through `std.http.Client`, the way the relay
//! connections run on theirs. Signing is not here: the event goes out through
//! whichever signer the reader has, and only the finished header comes back in.

const std = @import("std");

const Io = std.Io;

/// BUD-11's authorization event.
pub const auth_kind: u16 = 24242;

/// The signed token's `content`. A human-readable line for the server's log; it
/// deliberately says nothing about the file, which the server has anyway.
pub const auth_content = "Uploading media file";

/// How long a token stays valid. An hour, which is what Amethyst signs
/// (Amethyst's BlossomAuthorizationEvent.kt). One token is shared by every server an
/// upload tries, so it has to outlast a slow first attempt.
pub const auth_lifetime_s: i64 = 3600;

/// The largest picture Plaza will read into memory and send. Photos from a
/// phone are a tenth of this; a file past it is a video or a mistake.
pub const max_picture_bytes: usize = 32 * 1024 * 1024;

/// How many servers one upload will try, in order.
pub const max_servers = 4;

/// The longest server address kept. A bare origin, so this is generous.
pub const max_server_len = 96;

/// Where a picture goes when its owner has not published a server list. Both are
/// in Jumble's recommended list (constants.ts) and in Amethyst's defaults
/// (ServerName.kt), the only two that appear in both, and both answered a
/// bare request on 2026-10-04.
pub const default_servers = [_][]const u8{
    "https://blossom.primal.net",
    "https://blossom.band",
};

// ------------------------------------------------------------------ servers

/// A server address in the one spelling the rest of this file works with: scheme
/// and host (and port), lowercase, no trailing slash, no path.
///
/// `https` for anything on the internet, and a host with a dot in it, which is
/// the rule the relay list uses for the same reason: this is text the reader
/// typed or a list they published, and everything downstream trusts it. `http`
/// is accepted only for a loopback literal, where the bytes never leave the
/// machine (a Blossom server run locally is a real thing people do).
///
/// Written into `out`, so the answer is a slice of it.
pub fn normalizeServer(out: []u8, raw: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0 or s.len > out.len) return null;
    const secure = std.ascii.startsWithIgnoreCase(s, "https://");
    const plain = std.ascii.startsWithIgnoreCase(s, "http://");
    if (!secure and !plain) return null;
    const authority = s[if (secure) "https://".len else "http://".len..];
    if (authority.len == 0) return null;
    for (authority) |c| {
        // No path, query, fragment or userinfo, and nothing that is not a
        // visible ASCII character. A host with any of those in it is a
        // different request from the one the reader thinks they approved.
        if (c <= 0x20 or c >= 0x7f) return null;
        if (c == '/' or c == '?' or c == '#' or c == '@' or c == '\\') return null;
    }
    const host_end = hostEnd(authority);
    const host = authority[0..host_end];
    if (host.len == 0) return null;
    if (host_end < authority.len) {
        const port = authority[host_end + 1 ..];
        if (authority[host_end] != ':' or port.len == 0 or port.len > 5) return null;
        const n = std.fmt.parseInt(u16, port, 10) catch return null;
        if (n == 0) return null;
    }
    if (secure) {
        if (std.mem.indexOfScalar(u8, host, '.') == null) return null;
    } else if (!isLoopbackHost(host)) {
        return null;
    }
    const lowered = std.ascii.lowerString(out[0..s.len], s);
    return lowered;
}

/// Where the host ends in `authority`: before a `:port`, or after the closing
/// bracket of an IPv6 literal.
fn hostEnd(authority: []const u8) usize {
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority.len;
        return close + 1;
    }
    return std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "[::1]");
}

/// A server as a reader says it: no scheme.
pub fn serverLabel(server: []const u8) []const u8 {
    if (std.mem.startsWith(u8, server, "https://")) return server["https://".len..];
    if (std.mem.startsWith(u8, server, "http://")) return server["http://".len..];
    return server;
}

/// The servers a kind:10063's tags name, in order, normalized and without
/// repeats. Anything that is not a usable address is skipped rather than
/// repaired: it is somebody's record and Plaza only reads it here.
pub fn serversFromTags(tags: []const []const []const u8, out: *[max_servers][max_server_len]u8, lens: *[max_servers]u8) usize {
    var n: usize = 0;
    for (tags) |tag| {
        if (n == max_servers) break;
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "server")) continue;
        var buf: [max_server_len]u8 = undefined;
        const url = normalizeServer(&buf, tag[1]) orelse continue;
        var dup = false;
        for (0..n) |i| {
            if (std.mem.eql(u8, out[i][0..lens[i]], url)) dup = true;
        }
        if (dup) continue;
        @memcpy(out[n][0..url.len], url);
        lens[n] = @intCast(url.len);
        n += 1;
    }
    return n;
}

// ------------------------------------------------------------ authorization

/// The tags of the kind:24242 token for uploading a file with this sha256.
/// `t upload` says what it authorises, `x` which file, `expiration` how long
/// (BUD-11), and `size` the byte count, which Amethyst adds
/// (BlossomAuthorizationEvent.kt). Allocated from `gpa` and meant to live
/// as long as the process, like every other tag set handed to a signer.
pub fn authTags(gpa: std.mem.Allocator, sha256_hex: []const u8, size: usize, expiration: i64) ![]const []const []const u8 {
    const out = try gpa.alloc([]const []const u8, 4);
    out[0] = try gpa.dupe([]const u8, &.{ "t", "upload" });
    out[1] = try gpa.dupe([]const u8, &.{ "expiration", try std.fmt.allocPrint(gpa, "{d}", .{expiration}) });
    out[2] = try gpa.dupe([]const u8, &.{ "size", try std.fmt.allocPrint(gpa, "{d}", .{size}) });
    out[3] = try gpa.dupe([]const u8, &.{ "x", try gpa.dupe(u8, sha256_hex) });
    return out;
}

/// The `Authorization` header value for a signed token: `Nostr ` and the
/// event's JSON in standard base64 WITH padding.
///
/// BUD-11 says unpadded URL-safe base64. Servers do not: khatru-based ones
/// decode with a strict standard decoder and reject both, which is why Amethyst
/// ships standard and says so (BlossomAuthorizationEvent.kt), and Jumble's
/// SDK sends `btoa(JSON)`. Interop wins over the draft.
pub fn authorizationHeader(gpa: std.mem.Allocator, event_json: []const u8) ![]u8 {
    const prefix = "Nostr ";
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, prefix.len + enc.calcSize(event_json.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], event_json);
    return out;
}

// --------------------------------------------------------------- descriptor

/// What a server says it stored (BUD-02's blob descriptor), reduced to what a
/// note needs and held in fixed buffers so it can cross a thread by value.
pub const Descriptor = struct {
    url_buf: [512]u8 = undefined,
    url_len: u16 = 0,
    /// The sha256 the server reports, lowercase hex, when it reported one that
    /// is well formed.
    sha_buf: [64]u8 = undefined,
    has_sha: bool = false,

    pub fn url(self: *const Descriptor) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn sha256(self: *const Descriptor) ?[]const u8 {
        return if (self.has_sha) self.sha_buf[0..] else null;
    }
};

pub const DescriptorError = error{ NotJson, NoUrl, BadUrl };

/// Reads a server's reply to an upload. The `url` is the only field that has to
/// be there, and it has to be an address a note can carry: `https`, or `http`
/// when the server itself was a loopback one, with no whitespace or control
/// characters in it. `ext` is appended to a URL whose last path segment has no
/// extension, which BUD-01 allows on every blob URL and which Plaza needs to
/// recognise the link as a picture.
pub fn parseDescriptor(body: []const u8, allow_http: bool, ext: []const u8) DescriptorError!Descriptor {
    var arena_buf: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const Wire = struct { url: ?[]const u8 = null, sha256: ?[]const u8 = null };
    const parsed = std.json.parseFromSliceLeaky(Wire, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch return error.NotJson;
    const raw = parsed.url orelse return error.NoUrl;
    if (raw.len == 0 or raw.len > 480) return error.BadUrl;
    const https = std.mem.startsWith(u8, raw, "https://");
    const http = std.mem.startsWith(u8, raw, "http://");
    if (!https and !(http and allow_http)) return error.BadUrl;
    for (raw) |c| {
        if (c <= 0x20 or c >= 0x7f) return error.BadUrl;
    }
    var d: Descriptor = .{};
    var n = raw.len;
    @memcpy(d.url_buf[0..n], raw);
    if (ext.len > 0 and !lastSegmentHasExtension(raw)) {
        // Before any query: the extension belongs to the path.
        const cut = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
        if (cut == raw.len) {
            const suffix = std.fmt.bufPrint(d.url_buf[n..], ".{s}", .{ext}) catch return error.BadUrl;
            n += suffix.len;
        }
    }
    d.url_len = @intCast(n);
    if (parsed.sha256) |sha| {
        if (isHex64(sha)) {
            _ = std.ascii.lowerString(&d.sha_buf, sha);
            d.has_sha = true;
        }
    }
    return d;
}

fn lastSegmentHasExtension(url: []const u8) bool {
    const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..path_end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    // A URL that is only a host has no segment at all.
    if (slash < "https://".len - 1) return false;
    return std.mem.indexOfScalar(u8, path[slash + 1 ..], '.') != null;
}

pub fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------- image

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,

    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }

    pub fn ext(self: Format) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .gif => "gif",
            .webp => "webp",
        };
    }
};

/// What a file is, from its first bytes. The name and the extension are what a
/// person typed; the bytes are what a server and a decoder will meet.
pub fn sniff(b: []const u8) ?Format {
    if (b.len >= 8 and std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (b.len >= 3 and b[0] == 0xff and b[1] == 0xd8 and b[2] == 0xff) return .jpeg;
    if (b.len >= 6 and (std.mem.eql(u8, b[0..6], "GIF87a") or std.mem.eql(u8, b[0..6], "GIF89a"))) return .gif;
    if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return .webp;
    return null;
}

pub const Size = struct { w: u32, h: u32 };

/// The picture's pixel size as its header states it, without decoding.
pub fn dimensions(fmt: Format, b: []const u8) ?Size {
    const s: ?Size = switch (fmt) {
        .png => pngSize(b),
        .jpeg => jpegSize(b),
        .gif => gifSize(b),
        .webp => webpSize(b),
    };
    const size = s orelse return null;
    if (size.w == 0 or size.h == 0) return null;
    return size;
}

fn pngSize(b: []const u8) ?Size {
    if (b.len < 24 or !std.mem.eql(u8, b[12..16], "IHDR")) return null;
    return .{ .w = std.mem.readInt(u32, b[16..20], .big), .h = std.mem.readInt(u32, b[20..24], .big) };
}

fn gifSize(b: []const u8) ?Size {
    if (b.len < 10) return null;
    return .{ .w = std.mem.readInt(u16, b[6..8], .little), .h = std.mem.readInt(u16, b[8..10], .little) };
}

fn jpegSize(b: []const u8) ?Size {
    var pos: usize = 2;
    while (pos + 4 <= b.len) {
        if (b[pos] != 0xff) return null;
        const marker = b[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        // Standalone markers carry no length.
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd8)) {
            pos += 2;
            continue;
        }
        const seg_len = std.mem.readInt(u16, b[pos + 2 ..][0..2], .big);
        if (seg_len < 2) return null;
        const is_sof = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (is_sof) {
            if (pos + 9 > b.len) return null;
            return .{
                .h = std.mem.readInt(u16, b[pos + 5 ..][0..2], .big),
                .w = std.mem.readInt(u16, b[pos + 7 ..][0..2], .big),
            };
        }
        if (marker == 0xda) return null;
        pos += 2 + seg_len;
    }
    return null;
}

fn webpSize(b: []const u8) ?Size {
    if (b.len < 30) return null;
    const tag = b[12..16];
    if (std.mem.eql(u8, tag, "VP8X")) {
        const w = 1 + @as(u32, b[24]) + (@as(u32, b[25]) << 8) + (@as(u32, b[26]) << 16);
        const h = 1 + @as(u32, b[27]) + (@as(u32, b[28]) << 8) + (@as(u32, b[29]) << 16);
        return .{ .w = w, .h = h };
    }
    if (std.mem.eql(u8, tag, "VP8L")) {
        if (b[20] != 0x2f) return null;
        const bits = std.mem.readInt(u32, b[21..25], .little);
        return .{ .w = (bits & 0x3fff) + 1, .h = ((bits >> 14) & 0x3fff) + 1 };
    }
    if (std.mem.eql(u8, tag, "VP8 ")) {
        if (!std.mem.eql(u8, b[23..26], "\x9d\x01\x2a")) return null;
        return .{
            .w = std.mem.readInt(u16, b[26..28], .little) & 0x3fff,
            .h = std.mem.readInt(u16, b[28..30], .little) & 0x3fff,
        };
    }
    return null;
}

// ---------------------------------------------------- metadata that is removed
//
// A phone photo carries where it was taken, what took it and when. Putting that
// on a public server under the reader's key is a thing they would have to know
// to prevent, so the upload removes it first. Same bytes-level approach as
// Jumble (strip-image-metadata.ts): drop the segments or chunks that
// hold it and leave every pixel as it was. Jumble also re-inserts a minimal
// block holding only the EXIF Orientation tag, since without it a photo taken
// sideways displays sideways; that is done here for JPEG, where it matters.
// PNG and WebP orientation is rare enough to drop with the rest.

const Stripped = struct {
    bytes: []u8,
    /// EXIF orientation 1..8 when the file carried one, else 0.
    orientation: u8,
};

/// Copies `src[ranges]` end to end. Owns what it returns.
fn assemble(gpa: std.mem.Allocator, src: []const u8, ranges: []const [2]usize) ![]u8 {
    var total: usize = 0;
    for (ranges) |r| total += r[1] - r[0];
    const out = try gpa.alloc(u8, total);
    var at: usize = 0;
    for (ranges) |r| {
        @memcpy(out[at..][0 .. r[1] - r[0]], src[r[0]..r[1]]);
        at += r[1] - r[0];
    }
    return out;
}

/// The Orientation tag out of a TIFF block (what follows `Exif\0\0` in a JPEG),
/// or 0.
fn tiffOrientation(tiff: []const u8) u8 {
    if (tiff.len < 8) return 0;
    const endian: std.builtin.Endian = if (tiff[0] == 'I' and tiff[1] == 'I') .little else if (tiff[0] == 'M' and tiff[1] == 'M') .big else return 0;
    if (std.mem.readInt(u16, tiff[2..4], endian) != 0x002a) return 0;
    const ifd: usize = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd + 2 > tiff.len) return 0;
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
    var pos = ifd + 2;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pos + 12 > tiff.len) return 0;
        if (std.mem.readInt(u16, tiff[pos..][0..2], endian) == 0x0112) {
            const v = std.mem.readInt(u16, tiff[pos + 8 ..][0..2], endian);
            return if (v >= 1 and v <= 8) @intCast(v) else 0;
        }
        pos += 12;
    }
    return 0;
}

/// An APP1 segment carrying only the Orientation tag, big-endian, 36 bytes.
fn orientationSegment(orientation: u8) [36]u8 {
    var seg: [36]u8 = @splat(0);
    seg[0] = 0xff;
    seg[1] = 0xe1;
    std.mem.writeInt(u16, seg[2..4], 34, .big);
    @memcpy(seg[4..10], "Exif\x00\x00");
    // The TIFF block: byte order, magic, IFD0 at 8, one entry, Orientation
    // (0x0112) as a SHORT, count 1, the value left-justified, no next IFD.
    seg[10] = 'M';
    seg[11] = 'M';
    std.mem.writeInt(u16, seg[12..14], 0x002a, .big);
    std.mem.writeInt(u32, seg[14..18], 8, .big);
    std.mem.writeInt(u16, seg[18..20], 1, .big);
    std.mem.writeInt(u16, seg[20..22], 0x0112, .big);
    std.mem.writeInt(u16, seg[22..24], 3, .big);
    std.mem.writeInt(u32, seg[24..28], 1, .big);
    std.mem.writeInt(u16, seg[28..30], orientation, .big);
    return seg;
}

/// A list of byte ranges to keep, merging neighbours.
const Ranges = struct {
    list: std.ArrayList([2]usize) = .empty,

    fn add(self: *Ranges, gpa: std.mem.Allocator, start: usize, end: usize) !void {
        if (self.list.items.len > 0 and self.list.items[self.list.items.len - 1][1] == start) {
            self.list.items[self.list.items.len - 1][1] = end;
            return;
        }
        try self.list.append(gpa, .{ start, end });
    }
};

/// APP1 (Exif and XMP), APP13 (Photoshop and IPTC) and COM are dropped. APP0,
/// the ICC profile in APP2 and the rest stay, so colour is untouched.
fn stripJpeg(gpa: std.mem.Allocator, b: []const u8) !?Stripped {
    if (b.len < 4 or b[0] != 0xff or b[1] != 0xd8) return null;
    var keep: Ranges = .{};
    defer keep.list.deinit(gpa);
    try keep.add(gpa, 0, 2);
    var orientation: u8 = 0;
    var pos: usize = 2;
    while (pos + 1 < b.len) {
        if (b[pos] != 0xff) return null;
        if (b[pos + 1] == 0xff) {
            pos += 1;
            continue;
        }
        const marker = b[pos + 1];
        // Start of scan: the entropy-coded data is kept verbatim, up to the end
        // of image marker that closes it. What a phone appends after that is
        // not part of this picture: a second picture with its own EXIF (MPF),
        // a vendor trailer, or a motion photo's video. Without an end marker the
        // file is kept to its last byte, as it was.
        if (marker == 0xda) {
            try keep.add(gpa, pos, jpegImageEnd(b, pos) orelse b.len);
            break;
        }
        if (pos + 4 > b.len) return null;
        const seg_len: usize = std.mem.readInt(u16, b[pos + 2 ..][0..2], .big);
        const seg_end = pos + 2 + seg_len;
        if (seg_len < 2 or seg_end > b.len) return null;
        if (marker == 0xe1 and seg_end - (pos + 4) >= 6 and std.mem.eql(u8, b[pos + 4 ..][0..6], "Exif\x00\x00")) {
            const found = tiffOrientation(b[pos + 10 .. seg_end]);
            if (found != 0) orientation = found;
        }
        const drop = marker == 0xe1 or marker == 0xed or marker == 0xfe;
        if (!drop) try keep.add(gpa, pos, seg_end);
        pos = seg_end;
    }
    const body = try assemble(gpa, b, keep.list.items);
    if (orientation <= 1) return .{ .bytes = body, .orientation = orientation };
    defer gpa.free(body);
    const seg = orientationSegment(orientation);
    const out = try gpa.alloc(u8, body.len + seg.len);
    @memcpy(out[0..2], body[0..2]);
    @memcpy(out[2..][0..seg.len], &seg);
    @memcpy(out[2 + seg.len ..], body[2..]);
    return .{ .bytes = out, .orientation = orientation };
}

/// Where a JPEG's image ends: just past the end of image marker, found by walking
/// from the first start of scan. Entropy-coded data escapes every 0xff it holds
/// (as ff 00) and restart markers carry no length, so the first marker in it that
/// is neither is a real one: the end, or a segment between the scans of a
/// progressive picture, which is stepped over by its length. Null when the file
/// stops first.
fn jpegImageEnd(b: []const u8, first_scan: usize) ?usize {
    var pos = first_scan;
    while (pos + 4 <= b.len) {
        const seg_len: usize = std.mem.readInt(u16, b[pos + 2 ..][0..2], .big);
        if (seg_len < 2) return null;
        var i = pos + 2 + seg_len;
        while (true) {
            if (i + 1 >= b.len) return null;
            if (b[i] != 0xff) {
                i += 1;
                continue;
            }
            const m = b[i + 1];
            if (m == 0xff) {
                i += 1;
                continue;
            }
            if (m == 0x00 or (m >= 0xd0 and m <= 0xd7)) {
                i += 2;
                continue;
            }
            if (m == 0xd9) return i + 2;
            break;
        }
        pos = i;
    }
    return null;
}

/// eXIf, tEXt, iTXt, zTXt and tIME are dropped. Colour, gamma and structure stay.
fn stripPng(gpa: std.mem.Allocator, b: []const u8) !?Stripped {
    if (b.len < 8 or !std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n")) return null;
    var keep: Ranges = .{};
    defer keep.list.deinit(gpa);
    try keep.add(gpa, 0, 8);
    var pos: usize = 8;
    var saw_end = false;
    while (pos + 12 <= b.len) {
        const data_len: usize = std.mem.readInt(u32, b[pos..][0..4], .big);
        const kind = b[pos + 4 ..][0..4];
        if (data_len > b.len) return null;
        const chunk_end = pos + 12 + data_len;
        if (chunk_end > b.len) return null;
        const drop = std.mem.eql(u8, kind, "eXIf") or std.mem.eql(u8, kind, "tEXt") or
            std.mem.eql(u8, kind, "iTXt") or std.mem.eql(u8, kind, "zTXt") or std.mem.eql(u8, kind, "tIME");
        if (!drop) try keep.add(gpa, pos, chunk_end);
        pos = chunk_end;
        if (std.mem.eql(u8, kind, "IEND")) {
            saw_end = true;
            break;
        }
    }
    if (!saw_end) return null;
    return .{ .bytes = try assemble(gpa, b, keep.list.items), .orientation = 0 };
}

/// EXIF and XMP chunks are dropped, the RIFF size is rewritten to match, and the
/// feature bits in a VP8X header that announced them are cleared.
fn stripWebp(gpa: std.mem.Allocator, b: []const u8) !?Stripped {
    if (b.len < 12 or !std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..12], "WEBP")) return null;
    var keep: Ranges = .{};
    defer keep.list.deinit(gpa);
    try keep.add(gpa, 0, 12);
    var pos: usize = 12;
    while (pos + 8 <= b.len) {
        const size: usize = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
        if (pos + 8 + size > b.len) return null;
        // Chunks are padded to an even size, and the pad can be missing at the end.
        const chunk_end = @min(pos + 8 + size + (size & 1), b.len);
        const kind = b[pos..][0..4];
        if (!(std.mem.eql(u8, kind, "EXIF") or std.mem.eql(u8, kind, "XMP "))) try keep.add(gpa, pos, chunk_end);
        pos = chunk_end;
    }
    const out = try assemble(gpa, b, keep.list.items);
    if (out.len >= 8) std.mem.writeInt(u32, out[4..8], @intCast(out.len - 8), .little);
    // VP8X is always the first chunk. EXIF is feature bit 0x08, XMP 0x04.
    if (out.len >= 21 and std.mem.eql(u8, out[12..16], "VP8X")) out[20] &= ~@as(u8, 0x0c);
    return .{ .bytes = out, .orientation = 0 };
}

/// The EXIF orientation a JPEG carries, read without copying anything.
fn jpegOrientation(b: []const u8) u8 {
    var pos: usize = 2;
    while (pos + 4 <= b.len and b[pos] == 0xff) {
        const marker = b[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        if (marker == 0xda) return 0;
        const seg_len: usize = std.mem.readInt(u16, b[pos + 2 ..][0..2], .big);
        const seg_end = pos + 2 + seg_len;
        if (seg_len < 2 or seg_end > b.len) return 0;
        if (marker == 0xe1 and seg_end - (pos + 4) >= 6 and std.mem.eql(u8, b[pos + 4 ..][0..6], "Exif\x00\x00")) {
            const o = tiffOrientation(b[pos + 10 .. seg_end]);
            if (o != 0) return o;
        }
        pos = seg_end;
    }
    return 0;
}

// ---------------------------------------------------------------- blurhash

const base83 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";

/// The longest hash this file writes: 1 size, 1 maximum, 4 DC and two characters
/// for each of the other 11 components of a 4x3 grid.
pub const max_blurhash_len = 28;

fn srgbToLinear(v: u8) f32 {
    const x = @as(f32, @floatFromInt(v)) / 255.0;
    if (x <= 0.04045) return x / 12.92;
    return std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) u32 {
    const x = std.math.clamp(v, 0.0, 1.0);
    if (x <= 0.0031308) return @intFromFloat(x * 12.92 * 255.0 + 0.5);
    return @intFromFloat((1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055) * 255.0 + 0.5);
}

fn signPow(v: f32, e: f32) f32 {
    const m = std.math.pow(f32, @abs(v), e);
    return if (v < 0) -m else m;
}

fn putBase83(out: []u8, at: *usize, value: u32, digits: usize) void {
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        var div: u32 = 1;
        var k: usize = 0;
        while (k < digits - 1 - i) : (k += 1) div *= 83;
        out[at.* + i] = base83[(value / div) % 83];
    }
    at.* += digits;
}

/// A BlurHash (https://blurhash.de) of RGBA pixels, `cx` by `cy` components.
/// The encoder is the reference algorithm; the picture is first reduced to a grid
/// of at most 32 by 32 by averaging in linear light, because the hash can hold
/// nothing finer than a few cells and the reference walks every pixel for each of
/// its twelve components.
pub fn blurhash(out: *[max_blurhash_len]u8, rgba: []const u8, w: u32, h: u32, cx: u32, cy: u32) ?[]const u8 {
    if (w == 0 or h == 0 or rgba.len < @as(usize, w) * h * 4) return null;
    if (cx < 1 or cx > 4 or cy < 1 or cy > 3) return null;
    const gw: u32 = @min(w, 32);
    const gh: u32 = @min(h, 32);
    var grid: [32 * 32][3]f32 = undefined;
    var gy: u32 = 0;
    while (gy < gh) : (gy += 1) {
        const y0: u32 = @intCast(@as(u64, gy) * h / gh);
        const y1: u32 = @max(y0 + 1, @as(u32, @intCast(@as(u64, gy + 1) * h / gh)));
        var gx: u32 = 0;
        while (gx < gw) : (gx += 1) {
            const x0: u32 = @intCast(@as(u64, gx) * w / gw);
            const x1: u32 = @max(x0 + 1, @as(u32, @intCast(@as(u64, gx + 1) * w / gw)));
            var sum = [3]f32{ 0, 0, 0 };
            var count: f32 = 0;
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const px = (@as(usize, y) * w + x) * 4;
                    sum[0] += srgbToLinear(rgba[px]);
                    sum[1] += srgbToLinear(rgba[px + 1]);
                    sum[2] += srgbToLinear(rgba[px + 2]);
                    count += 1;
                }
            }
            grid[gy * gw + gx] = .{ sum[0] / count, sum[1] / count, sum[2] / count };
        }
    }

    var factors: [12][3]f32 = undefined;
    var j: u32 = 0;
    while (j < cy) : (j += 1) {
        var i: u32 = 0;
        while (i < cx) : (i += 1) {
            const norm: f32 = if (i == 0 and j == 0) 1 else 2;
            var acc = [3]f32{ 0, 0, 0 };
            var y: u32 = 0;
            while (y < gh) : (y += 1) {
                var x: u32 = 0;
                while (x < gw) : (x += 1) {
                    const basis = norm *
                        @cos(std.math.pi * @as(f32, @floatFromInt(i)) * (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(gw))) *
                        @cos(std.math.pi * @as(f32, @floatFromInt(j)) * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(gh)));
                    const g = grid[y * gw + x];
                    acc[0] += basis * g[0];
                    acc[1] += basis * g[1];
                    acc[2] += basis * g[2];
                }
            }
            const scale = 1.0 / @as(f32, @floatFromInt(gw * gh));
            factors[j * cx + i] = .{ acc[0] * scale, acc[1] * scale, acc[2] * scale };
        }
    }

    var at: usize = 0;
    putBase83(out, &at, (cx - 1) + (cy - 1) * 9, 1);
    const ac_count = cx * cy - 1;
    var max_value: f32 = 1;
    if (ac_count > 0) {
        var actual: f32 = 0;
        for (factors[1 .. 1 + ac_count]) |f| {
            actual = @max(actual, @max(@abs(f[0]), @max(@abs(f[1]), @abs(f[2]))));
        }
        const quantised: u32 = @intFromFloat(std.math.clamp(@floor(actual * 166 - 0.5), 0, 82));
        max_value = (@as(f32, @floatFromInt(quantised)) + 1) / 166;
        putBase83(out, &at, quantised, 1);
    } else {
        putBase83(out, &at, 0, 1);
    }
    const dc = factors[0];
    putBase83(out, &at, (linearToSrgb(dc[0]) << 16) + (linearToSrgb(dc[1]) << 8) + linearToSrgb(dc[2]), 4);
    for (factors[1 .. 1 + ac_count]) |f| {
        const q = struct {
            fn one(v: f32, m: f32) u32 {
                return @intFromFloat(std.math.clamp(@floor(signPow(v / m, 0.5) * 9 + 9.5), 0, 18));
            }
        };
        putBase83(out, &at, q.one(f[0], max_value) * 19 * 19 + q.one(f[1], max_value) * 19 + q.one(f[2], max_value), 2);
    }
    return out[0..at];
}

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

/// Past this many pixels the picture is not decoded for its blurhash: a 100
/// megapixel file is 400 MB of RGBA for a hash a few characters long.
const max_blurhash_pixels: u64 = 50_000_000;

/// The BlurHash of an encoded PNG, JPEG or GIF, or null when it cannot be made
/// (a format the bundled decoder does not read, a file too large to decode for
/// this, a decode failure). Always optional: a note is just as valid without it.
pub fn blurhashOf(out: *[max_blurhash_len]u8, fmt: Format, b: []const u8, size: Size) ?[]const u8 {
    if (fmt == .webp) return null;
    if (@as(u64, size.w) * size.h > max_blurhash_pixels) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = stbi_load_from_memory(b.ptr, @intCast(b.len), &w, &h, &comp, 4) orelse return null;
    defer stbi_image_free(px);
    if (w <= 0 or h <= 0) return null;
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    const wide = uw >= uh;
    return blurhash(out, px[0 .. @as(usize, uw) * uh * 4], uw, uh, if (wide) 4 else 3, if (wide) 3 else 4);
}

// ---------------------------------------------------------------- the file

/// A picture ready to send.
pub const Prepared = struct {
    /// What goes over the wire: the file with its metadata removed. Owned.
    bytes: []u8,
    format: Format,
    /// Lowercase hex sha256 of `bytes`.
    sha256: [64]u8,
    /// As displayed, with an EXIF rotation applied. Zero when the header could
    /// not be read.
    width: u32,
    height: u32,
    blurhash_buf: [max_blurhash_len]u8 = undefined,
    blurhash_len: u8 = 0,
    /// Whether anything was taken out.
    stripped: bool,

    pub fn blurhashText(self: *const Prepared) []const u8 {
        return self.blurhash_buf[0..self.blurhash_len];
    }

    pub fn deinit(self: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.bytes = &.{};
    }
};

pub const PrepareError = error{ NotAPicture, TooLarge, Damaged, OutOfMemory };

/// Reads a file's bytes into the form that is sent. Takes ownership of `file`
/// and frees it. A file that is not a PNG, JPEG, GIF or WebP is refused by what
/// its bytes are, whatever it is called.
pub fn prepare(gpa: std.mem.Allocator, file: []u8) PrepareError!Prepared {
    var owned: []u8 = file;
    errdefer gpa.free(owned);
    if (file.len > max_picture_bytes) return error.TooLarge;
    const fmt = sniff(file) orelse return error.NotAPicture;

    var orientation: u8 = 0;
    var changed = false;
    if (fmt != .gif) {
        const stripped = switch (fmt) {
            .jpeg => try stripJpeg(gpa, file),
            .png => try stripPng(gpa, file),
            else => try stripWebp(gpa, file),
        } orelse return error.Damaged;
        orientation = stripped.orientation;
        if (std.mem.eql(u8, stripped.bytes, file)) {
            // Nothing was in it: the original is sent as it came.
            gpa.free(stripped.bytes);
        } else {
            gpa.free(file);
            owned = stripped.bytes;
            changed = true;
        }
    }
    const bytes = owned;

    var out: Prepared = .{
        .bytes = bytes,
        .format = fmt,
        .sha256 = undefined,
        .width = 0,
        .height = 0,
        .stripped = changed,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    out.sha256 = std.fmt.bytesToHex(digest, .lower);

    if (orientation == 0 and fmt == .jpeg) orientation = jpegOrientation(bytes);
    if (dimensions(fmt, bytes)) |size| {
        const turned = orientation >= 5 and orientation <= 8;
        out.width = if (turned) size.h else size.w;
        out.height = if (turned) size.w else size.h;
        // The decoder does not apply EXIF, so a rotated photo's cells would be
        // laid out on the wrong axes. A hash that is wrong is worse than none.
        if (orientation <= 1) {
            var buf: [max_blurhash_len]u8 = undefined;
            if (blurhashOf(&buf, fmt, bytes, size)) |hash| {
                @memcpy(out.blurhash_buf[0..hash.len], hash);
                out.blurhash_len = @intCast(hash.len);
            }
        }
    }
    return out;
}

// -------------------------------------------------------------------- imeta

/// The fields of the NIP-92 `imeta` tag for an uploaded picture, as the strings
/// the tag carries: `url`, `m`, `x`, `size`, `dim`, `blurhash` and `alt`. Fields
/// that are not known are left out rather than written empty. Allocated from
/// `gpa` and meant to live as long as the process.
pub fn imetaTag(gpa: std.mem.Allocator, url: []const u8, mime: []const u8, sha256_hex: []const u8, size: usize, width: u32, height: u32, hash: []const u8, alt: []const u8) ![]const []const u8 {
    var fields = std.ArrayList([]const u8).empty;
    try fields.append(gpa, "imeta");
    try fields.append(gpa, try std.fmt.allocPrint(gpa, "url {s}", .{url}));
    if (mime.len > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "m {s}", .{mime}));
    if (sha256_hex.len > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "x {s}", .{sha256_hex}));
    if (size > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "size {d}", .{size}));
    if (width > 0 and height > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "dim {d}x{d}", .{ width, height }));
    if (hash.len > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "blurhash {s}", .{hash}));
    if (alt.len > 0) try fields.append(gpa, try std.fmt.allocPrint(gpa, "alt {s}", .{alt}));
    return fields.toOwnedSlice(gpa);
}

// -------------------------------------------------------------------- http

/// What the sending thread shares with whoever is watching it. The watcher reads
/// `sent`, `server`, and the idle clock; it writes `cancel`.
pub const Progress = struct {
    /// Bytes of the body handed to the connection for the server being tried.
    sent: std.atomic.Value(usize) = .init(0),
    total: usize = 0,
    /// Which of the servers is being tried, from zero.
    server: std.atomic.Value(u8) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    /// When something last moved, in the worker's own clock.
    last_ms: std.atomic.Value(i64) = .init(0),
};

pub const Fail = struct {
    buf: [160]u8 = undefined,
    len: u8 = 0,

    pub fn text(self: *const Fail) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Fail, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..self.buf.len];
        self.len = @intCast(s.len);
    }
};

pub const Outcome = union(enum) {
    ok: Ok,
    failed: Fail,
    cancelled,

    pub const Ok = struct {
        descriptor: Descriptor,
        /// Index into the list the upload was given.
        server: u8,
    };
};

/// What `attempt` found, before it is worded for a person.
const Attempt = union(enum) {
    ok: Descriptor,
    /// The server answered and said no.
    refused: struct { status: u16, reason: [120]u8, reason_len: u8 },
    /// The answer was not a blob descriptor.
    unreadable,
    /// The connection failed or dropped.
    network,
    cancelled,
};

pub const Request = struct {
    servers: []const []const u8,
    bytes: []const u8,
    mime: []const u8,
    ext: []const u8,
    sha256_hex: []const u8,
    /// The whole `Authorization` header value.
    authorization: []const u8,
    /// How long a server may go without any progress before it is given up on.
    idle_ms: i64 = 45_000,
};

/// Sends the picture to each server in turn until one accepts it. Blocks the
/// calling thread, which is meant to be a worker's own.
pub fn upload(io: Io, req: Request, progress: *Progress) Outcome {
    var last: Fail = .{};
    last.set("No media server is set up to take it.", .{});
    for (req.servers, 0..) |server, index| {
        if (progress.cancel.load(.acquire)) return .cancelled;
        progress.server.store(@intCast(index), .release);
        progress.sent.store(0, .release);
        const result = attemptBounded(io, server, req, progress);
        switch (result) {
            .ok => |d| return .{ .ok = .{ .descriptor = d, .server = @intCast(index) } },
            .cancelled => return .cancelled,
            .refused => |r| {
                const reason = std.mem.trim(u8, r.reason[0..r.reason_len], " \t\r\n");
                if (reason.len > 0) {
                    last.set("{s} said no: {s}", .{ serverLabel(server), reason });
                } else {
                    last.set("{s} said no: {s} ({d})", .{ serverLabel(server), statusWords(r.status), r.status });
                }
            },
            .unreadable => last.set("{s} accepted it but its answer made no sense, so the address is unknown.", .{serverLabel(server)}),
            .network => last.set("Could not reach {s}.", .{serverLabel(server)}),
        }
    }
    return .{ .failed = last };
}

/// A few statuses in words, for a server that gave no reason of its own. The
/// same short list Jumble keeps (media-upload.service.ts), and a class
/// word for the rest.
pub fn statusWords(status: u16) []const u8 {
    return switch (status) {
        400 => "bad request",
        401 => "not authorised",
        402 => "payment required",
        403 => "forbidden",
        413 => "file is too large",
        415 => "file type not accepted",
        429 => "too many requests",
        else => if (status >= 500) "server error" else "upload rejected",
    };
}

const Arrival = union(enum) {
    done: Attempt,
    watch: WatchEnd,
};

const WatchEnd = enum { idle, cancelled, stopped };

/// One server, bounded: the exchange runs as a concurrent task beside a watcher
/// that ends it when the user cancels or the connection goes quiet. Without the
/// watcher a server that accepts the connection and never answers would hold the
/// worker, and its picture, for the life of the process.
fn attemptBounded(io: Io, server: []const u8, req: Request, progress: *Progress) Attempt {
    progress.last_ms.store(Io.Timestamp.now(io, .awake).toMilliseconds(), .release);
    var buf: [2]Arrival = undefined;
    var sel = Io.Select(Arrival).init(io, &buf);
    sel.concurrent(.done, attemptOnce, .{ io, server, req, progress }) catch return .network;
    sel.concurrent(.watch, watch, .{ io, req.idle_ms, progress }) catch {
        // Without a watcher the exchange is only as bounded as the socket is.
        // Better than not sending, and the cancel flag still ends it between
        // writes.
    };
    var result: Attempt = .cancelled;
    var finished = false;
    if (sel.await()) |first| {
        switch (first) {
            .done => |a| {
                result = a;
                finished = true;
            },
            .watch => |why| {
                result = switch (why) {
                    .idle => .network,
                    .cancelled, .stopped => .cancelled,
                };
            },
        }
    } else |_| {}
    // Whatever is still running is told to stop, and joined. A result that lands
    // in the same instant is kept: the picture is already on the server.
    while (sel.cancel()) |late| switch (late) {
        .done => |a| if (!finished) {
            switch (a) {
                .ok => result = a,
                else => {},
            }
        },
        .watch => {},
    };
    return result;
}

fn watch(io: Io, idle_ms: i64, progress: *Progress) WatchEnd {
    while (true) {
        Io.sleep(io, .fromMilliseconds(200), .awake) catch return .stopped;
        if (progress.cancel.load(.acquire)) return .cancelled;
        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        if (now - progress.last_ms.load(.acquire) > idle_ms) return .idle;
    }
}

fn touch(io: Io, progress: *Progress) void {
    progress.last_ms.store(Io.Timestamp.now(io, .awake).toMilliseconds(), .release);
}

/// The exchange with one server: a BUD-06 preflight to find out whether it would
/// take the file before the file is sent, then the upload itself. The preflight
/// is Jumble's (media-upload.service.ts): a server that does not
/// implement it (404, 405, 501) is not a server that refused.
fn attemptOnce(io: Io, server: []const u8, req: Request, progress: *Progress) Attempt {
    const gpa = std.heap.page_allocator;
    var url_buf: [max_server_len + 8]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/upload", .{server}) catch return .network;
    const uri = std.Uri.parse(url) catch return .network;

    var len_buf: [20]u8 = undefined;
    const len_text = std.fmt.bufPrint(&len_buf, "{d}", .{req.bytes.len}) catch return .network;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Preflight.
    {
        const headers = [_]std.http.Header{
            .{ .name = "X-SHA-256", .value = req.sha256_hex },
            .{ .name = "X-Content-Length", .value = len_text },
            .{ .name = "X-Content-Type", .value = req.mime },
        };
        var request = client.request(.HEAD, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .authorization = .{ .override = req.authorization } },
            .extra_headers = &headers,
        }) catch return .network;
        defer request.deinit();
        request.sendBodiless() catch return .network;
        touch(io, progress);
        var redirect: [1024]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return .network;
        touch(io, progress);
        const code = @intFromEnum(response.head.status);
        const unsupported = code == 404 or code == 405 or code == 501;
        if (code >= 400 and !unsupported) return refusal(code, response.head);
        if (code >= 300 and code < 400) return refusal(code, response.head);
    }

    // The upload.
    const headers = [_]std.http.Header{
        .{ .name = "X-SHA-256", .value = req.sha256_hex },
    };
    var request = client.request(.PUT, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = req.authorization },
            .content_type = .{ .override = req.mime },
        },
        .extra_headers = &headers,
    }) catch return .network;
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = req.bytes.len };
    var body = request.sendBodyUnflushed(&.{}) catch return .network;
    const chunk: usize = 16 * 1024;
    var at: usize = 0;
    while (at < req.bytes.len) {
        if (progress.cancel.load(.acquire)) return .cancelled;
        const end = @min(at + chunk, req.bytes.len);
        body.writer.writeAll(req.bytes[at..end]) catch return .network;
        at = end;
        progress.sent.store(at, .release);
        touch(io, progress);
    }
    body.end() catch return .network;
    request.connection.?.flush() catch return .network;
    touch(io, progress);

    var redirect: [1024]u8 = undefined;
    var response = request.receiveHead(&redirect) catch return .network;
    touch(io, progress);
    const code = @intFromEnum(response.head.status);
    if (code < 200 or code >= 300) return refusal(code, response.head);

    var transfer: [1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const window: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len) catch return .network,
        .deflate, .gzip => gpa.alloc(u8, std.compress.flate.max_window_len) catch return .network,
        .compress => return .unreadable,
    };
    defer if (window.len > 0) gpa.free(window);
    const reader = response.readerDecompressing(&transfer, &decompress, window);
    var body_buf: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&body_buf);
    _ = reader.streamRemaining(&sink) catch |err| switch (err) {
        // A descriptor larger than this is not a descriptor.
        error.WriteFailed => return .unreadable,
        error.ReadFailed => return .network,
    };
    const allow_http = std.mem.startsWith(u8, server, "http://");
    const descriptor = parseDescriptor(sink.buffered(), allow_http, req.ext) catch return .unreadable;
    return .{ .ok = descriptor };
}

fn refusal(status: u16, head: std.http.Client.Response.Head) Attempt {
    var out: Attempt = .{ .refused = .{ .status = status, .reason = undefined, .reason_len = 0 } };
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "x-reason")) continue;
        var n: usize = 0;
        for (h.value) |c| {
            if (n == out.refused.reason.len) break;
            // A header is a stranger's text and ends up on screen.
            if (c < 0x20 or c >= 0x7f) continue;
            out.refused.reason[n] = c;
            n += 1;
        }
        out.refused.reason_len = @intCast(n);
        break;
    }
    return out;
}

// ------------------------------------------------------------------- tests

test "normalizeServer keeps an origin and nothing else" {
    var buf: [max_server_len]u8 = undefined;
    try std.testing.expectEqualStrings("https://blossom.primal.net", normalizeServer(&buf, "https://blossom.primal.net/").?);
    try std.testing.expectEqualStrings("https://blossom.band", normalizeServer(&buf, "  HTTPS://Blossom.Band//  ").?);
    try std.testing.expectEqualStrings("https://cdn.example.com:8443", normalizeServer(&buf, "https://cdn.example.com:8443").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", normalizeServer(&buf, "http://127.0.0.1:9000/").?);
    try std.testing.expectEqualStrings("http://[::1]:9000", normalizeServer(&buf, "http://[::1]:9000").?);
    // No path: the address is where the server is, and a path would be a
    // different request from the one the reader approved.
    try std.testing.expect(normalizeServer(&buf, "https://cdn.example.com/media") == null);
    try std.testing.expect(normalizeServer(&buf, "https://cdn.example.com?x=1") == null);
    try std.testing.expect(normalizeServer(&buf, "https://user@cdn.example.com") == null);
    try std.testing.expect(normalizeServer(&buf, "https://localhost") == null);
    try std.testing.expect(normalizeServer(&buf, "https://") == null);
    try std.testing.expect(normalizeServer(&buf, "ftp://cdn.example.com") == null);
    try std.testing.expect(normalizeServer(&buf, "cdn.example.com") == null);
    try std.testing.expect(normalizeServer(&buf, "https://cdn.example.com:99999") == null);
    // Plain http reaches only this machine.
    try std.testing.expect(normalizeServer(&buf, "http://cdn.example.com") == null);
    try std.testing.expect(normalizeServer(&buf, "http://localhost:9000") == null);
    try std.testing.expect(normalizeServer(&buf, "http://192.168.1.4:9000") == null);
}

test "a server list is read in order, without repeats or the unusable" {
    const tags = [_][]const []const u8{
        &.{ "server", "https://one.example/" },
        &.{ "relay", "wss://not.a.server" },
        &.{ "server", "not a url" },
        &.{ "server", "https://ONE.example" },
        &.{ "server", "https://two.example" },
        &.{"server"},
    };
    var urls: [max_servers][max_server_len]u8 = undefined;
    var lens: [max_servers]u8 = undefined;
    const n = serversFromTags(&tags, &urls, &lens);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("https://one.example", urls[0][0..lens[0]]);
    try std.testing.expectEqualStrings("https://two.example", urls[1][0..lens[1]]);
}

test "the token names the file, the purpose and an expiry" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const sha = "ab" ** 32;
    const tags = try authTags(arena.allocator(), sha, 1234, 1_700_003_600);
    try std.testing.expectEqual(@as(usize, 4), tags.len);
    try std.testing.expectEqualStrings("t", tags[0][0]);
    try std.testing.expectEqualStrings("upload", tags[0][1]);
    try std.testing.expectEqualStrings("expiration", tags[1][0]);
    try std.testing.expectEqualStrings("1700003600", tags[1][1]);
    try std.testing.expectEqualStrings("size", tags[2][0]);
    try std.testing.expectEqualStrings("1234", tags[2][1]);
    try std.testing.expectEqualStrings("x", tags[3][0]);
    try std.testing.expectEqualStrings(sha, tags[3][1]);
}

test "the header is standard padded base64 of the event" {
    const gpa = std.testing.allocator;
    // One byte short of a multiple of three, so padding shows.
    const header = try authorizationHeader(gpa, "{\"a\":1}");
    defer gpa.free(header);
    try std.testing.expectEqualStrings("Nostr eyJhIjoxfQ==", header);
    const url_safe = try authorizationHeader(gpa, "\xfb\xff\xfe");
    defer gpa.free(url_safe);
    try std.testing.expectEqualStrings("Nostr +//+", url_safe);
}

test "a descriptor yields its url, gains an extension, and refuses a bad address" {
    const sha = "0123456789abcdef" ** 4;
    const body = "{\"url\":\"https://cdn.example/" ++ sha ++ "\",\"sha256\":\"" ++ sha ++ "\",\"size\":9,\"type\":\"image/png\",\"uploaded\":1}";
    const d = try parseDescriptor(body, false, "png");
    try std.testing.expectEqualStrings("https://cdn.example/" ++ sha ++ ".png", d.url());
    try std.testing.expectEqualStrings(sha, d.sha256().?);
    // Already has one: left alone.
    const named = try parseDescriptor("{\"url\":\"https://cdn.example/a.webp\"}", false, "png");
    try std.testing.expectEqualStrings("https://cdn.example/a.webp", named.url());
    try std.testing.expect(named.sha256() == null);
    try std.testing.expectError(error.NoUrl, parseDescriptor("{\"sha256\":\"x\"}", false, "png"));
    try std.testing.expectError(error.NotJson, parseDescriptor("<html>", false, "png"));
    try std.testing.expectError(error.BadUrl, parseDescriptor("{\"url\":\"javascript:alert(1)\"}", false, "png"));
    try std.testing.expectError(error.BadUrl, parseDescriptor("{\"url\":\"http://cdn.example/a.png\"}", false, "png"));
    try std.testing.expectError(error.BadUrl, parseDescriptor("{\"url\":\"https://cdn.example/a b.png\"}", false, "png"));
    // Plain http is a loopback server talking about itself.
    const local = try parseDescriptor("{\"url\":\"http://127.0.0.1:9/a.png\"}", true, "png");
    try std.testing.expectEqualStrings("http://127.0.0.1:9/a.png", local.url());
    // A malformed hash is ignored, not trusted.
    const odd = try parseDescriptor("{\"url\":\"https://cdn.example/a.png\",\"sha256\":\"nope\"}", false, "png");
    try std.testing.expect(odd.sha256() == null);
}

test "files are told apart by their bytes" {
    try std.testing.expectEqual(Format.png, sniff("\x89PNG\r\n\x1a\nrest").?);
    try std.testing.expectEqual(Format.jpeg, sniff("\xff\xd8\xff\xe0rest").?);
    try std.testing.expectEqual(Format.gif, sniff("GIF89arest").?);
    try std.testing.expectEqual(Format.webp, sniff("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expect(sniff("%PDF-1.7") == null);
    try std.testing.expect(sniff("") == null);
    try std.testing.expect(sniff("<svg xmlns=") == null);
}

pub fn testPng(gpa: std.mem.Allocator, w: u32, h: u32, extra: []const u8) ![]u8 {
    // A real, decodable PNG: one scanline per row of filter 0 and zero bytes,
    // stored (not compressed) in a zlib stream.
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(gpa);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        try raw.append(gpa, 0);
        try raw.appendNTimes(gpa, 0, w * 3);
    }
    var z = std.ArrayList(u8).empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    try z.appendSlice(gpa, &.{ @intCast(raw.items.len & 0xff), @intCast(raw.items.len >> 8), @intCast(~raw.items.len & 0xff), @intCast((~raw.items.len >> 8) & 0xff) });
    try z.appendSlice(gpa, raw.items);
    var adler_a: u32 = 1;
    var adler_b: u32 = 0;
    for (raw.items) |byte| {
        adler_a = (adler_a + byte) % 65521;
        adler_b = (adler_b + adler_a) % 65521;
    }
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, (adler_b << 16) | adler_a, .big);
    try z.appendSlice(gpa, &tail);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    @memcpy(ihdr[8..13], &[_]u8{ 8, 2, 0, 0, 0 });
    try pngChunk(gpa, &out, "IHDR", &ihdr);
    try out.appendSlice(gpa, extra);
    try pngChunk(gpa, &out, "IDAT", z.items);
    try pngChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn pngChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

test "a png loses its text and time chunks and keeps its pixels and size" {
    const gpa = std.testing.allocator;
    var extra = std.ArrayList(u8).empty;
    defer extra.deinit(gpa);
    try pngChunk(gpa, &extra, "tEXt", "Comment\x00taken at 12.34N 56.78E");
    try pngChunk(gpa, &extra, "tIME", "\x07\xea\x0a\x04\x0c\x00\x00");
    const file = try testPng(gpa, 5, 3, extra.items);
    const before = file.len;
    var prepared = try prepare(gpa, file);
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared.bytes.len < before);
    try std.testing.expect(prepared.stripped);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "tEXt") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "12.34N") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "tIME") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "IDAT") != null);
    try std.testing.expectEqual(Format.png, prepared.format);
    try std.testing.expectEqual(@as(u32, 5), prepared.width);
    try std.testing.expectEqual(@as(u32, 3), prepared.height);
    // The hash is of what is sent, not of what was read.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&hex, &prepared.sha256);
    // Black, 4x3 cells: the hash every encoder gives a black picture.
    try std.testing.expectEqualStrings("L00000fQfQfQfQfQfQfQfQfQfQfQ", prepared.blurhashText());
}

test "a clean png is sent as it is" {
    const gpa = std.testing.allocator;
    const file = try testPng(gpa, 2, 2, "");
    const copy = try gpa.dupe(u8, file);
    defer gpa.free(copy);
    var prepared = try prepare(gpa, file);
    defer prepared.deinit(gpa);
    try std.testing.expect(!prepared.stripped);
    try std.testing.expectEqualSlices(u8, copy, prepared.bytes);
}

fn testJpeg(gpa: std.mem.Allocator, with_gps: bool, orientation: u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0xff, 0xd8 });
    // JFIF
    try out.appendSlice(gpa, &.{ 0xff, 0xe0, 0x00, 0x10 });
    try out.appendSlice(gpa, "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");
    if (with_gps) {
        // An Exif block with Orientation and a marker string standing in for GPS.
        var exif = std.ArrayList(u8).empty;
        defer exif.deinit(gpa);
        try exif.appendSlice(gpa, "Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01");
        try exif.appendSlice(gpa, &.{ 0x00, orientation, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
        try exif.appendSlice(gpa, "GPS-LAT-12.34");
        try out.appendSlice(gpa, &.{ 0xff, 0xe1 });
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(exif.items.len + 2), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, exif.items);
        // A comment too.
        try out.appendSlice(gpa, &.{ 0xff, 0xfe, 0x00, 0x08 });
        try out.appendSlice(gpa, "secret");
    }
    // SOF0: 8 bit, 40 high, 60 wide, one component.
    try out.appendSlice(gpa, &.{ 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x28, 0x00, 0x3c, 0x01, 0x01, 0x11, 0x00 });
    // SOS and some scan bytes. Not a decodable picture, which is fine: the strip
    // and the header read never decode.
    try out.appendSlice(gpa, &.{ 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0xaa, 0xbb, 0xff, 0xd9 });
    return out.toOwnedSlice(gpa);
}

test "a jpeg loses its location and comment but keeps its rotation" {
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testJpeg(gpa, true, 6));
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared.stripped);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "GPS-LAT") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "JFIF") != null);
    // Orientation 6 means the stored 60x40 is shown as 40x60, and the hash of
    // the sent file still reads it back.
    try std.testing.expectEqual(@as(u32, 40), prepared.width);
    try std.testing.expectEqual(@as(u32, 60), prepared.height);
    try std.testing.expectEqual(@as(u8, 6), jpegOrientation(prepared.bytes));
    // And a rotated picture carries no blurhash rather than a wrong one.
    try std.testing.expectEqual(@as(u8, 0), prepared.blurhash_len);
}

test "what a phone appends after a jpeg's image is not sent" {
    const gpa = std.testing.allocator;
    var f = std.ArrayList(u8).empty;
    defer f.deinit(gpa);
    const plain = try testJpeg(gpa, false, 1);
    defer gpa.free(plain);
    // Up to the first scan's data, then a scan that holds an escaped ff, a
    // restart marker, a second scan behind a table whose bytes happen to spell
    // the end marker, and only then the end.
    const sos = std.mem.indexOf(u8, plain, "\xff\xda").?;
    try f.appendSlice(gpa, plain[0..sos]);
    try f.appendSlice(gpa, &.{ 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00 });
    try f.appendSlice(gpa, &.{ 0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56 });
    try f.appendSlice(gpa, &.{ 0xff, 0xc4, 0x00, 0x06, 0xff, 0xd9, 0xff, 0xd9 });
    try f.appendSlice(gpa, &.{ 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0x78 });
    try f.appendSlice(gpa, &.{ 0xff, 0xd9 });
    const image_len = f.items.len;
    // A second picture with its own EXIF, the way MPF stores one, and a trailer.
    try f.appendSlice(gpa, &.{ 0xff, 0xd8, 0xff, 0xe1, 0x00, 0x10 });
    try f.appendSlice(gpa, "Exif\x00\x00GPS-LAT-");
    try f.appendSlice(gpa, &.{ 0xff, 0xd9 });
    try f.appendSlice(gpa, "SEFT motion photo video");
    const whole = try gpa.dupe(u8, f.items);
    var prepared = try prepare(gpa, whole);
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared.stripped);
    try std.testing.expectEqualSlices(u8, f.items[0..image_len], prepared.bytes);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "GPS-LAT") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "SEFT") == null);
}

test "an upright jpeg with nothing to strip is not rewritten" {
    const gpa = std.testing.allocator;
    const file = try testJpeg(gpa, false, 1);
    const copy = try gpa.dupe(u8, file);
    defer gpa.free(copy);
    var prepared = try prepare(gpa, file);
    defer prepared.deinit(gpa);
    try std.testing.expect(!prepared.stripped);
    try std.testing.expectEqualSlices(u8, copy, prepared.bytes);
    try std.testing.expectEqual(@as(u32, 60), prepared.width);
    try std.testing.expectEqual(@as(u32, 40), prepared.height);
}

test "webp drops exif and xmp chunks and fixes the sizes it wrote" {
    const gpa = std.testing.allocator;
    var f = std.ArrayList(u8).empty;
    defer f.deinit(gpa);
    // RIFF header patched at the end.
    try f.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBP");
    // VP8X: flags with EXIF (0x08) and XMP (0x04), canvas 100x50.
    try f.appendSlice(gpa, "VP8X\x0a\x00\x00\x00\x0c\x00\x00\x00\x63\x00\x00\x31\x00\x00");
    try f.appendSlice(gpa, "EXIF\x04\x00\x00\x00gps!");
    try f.appendSlice(gpa, "XMP \x04\x00\x00\x00xmp!");
    try f.appendSlice(gpa, "VP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00");
    std.mem.writeInt(u32, f.items[4..8], @intCast(f.items.len - 8), .little);
    var prepared = try prepare(gpa, try f.toOwnedSlice(gpa));
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared.stripped);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "gps!") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "xmp!") == null);
    try std.testing.expectEqual(@as(u32, @intCast(prepared.bytes.len - 8)), std.mem.readInt(u32, prepared.bytes[4..8], .little));
    try std.testing.expectEqual(@as(u8, 0), prepared.bytes[20] & 0x0c);
    try std.testing.expectEqual(@as(u32, 100), prepared.width);
    try std.testing.expectEqual(@as(u32, 50), prepared.height);
}

test "what is not a picture is refused by its bytes, and a damaged one is not sent" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAPicture, prepare(gpa, try gpa.dupe(u8, "%PDF-1.7 not a picture at all")));
    try std.testing.expectError(error.NotAPicture, prepare(gpa, try gpa.dupe(u8, "")));
    // A JPEG whose segment table runs off the end.
    try std.testing.expectError(error.Damaged, prepare(gpa, try gpa.dupe(u8, "\xff\xd8\xff\xe1\x7f\xffExif")));
    // A PNG with no end.
    var png = std.ArrayList(u8).empty;
    defer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    try pngChunk(gpa, &png, "IHDR", &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 });
    try std.testing.expectError(error.Damaged, prepare(gpa, try gpa.dupe(u8, png.items)));
}

test "a black picture hashes the way every other encoder hashes it, and a color survives the round trip" {
    var out: [max_blurhash_len]u8 = undefined;
    const black = [_]u8{ 0, 0, 0, 255 } ** 16;
    try std.testing.expectEqualStrings("L00000fQfQfQfQfQfQfQfQfQfQfQ", blurhash(&out, &black, 4, 4, 4, 3).?);
    // One component: the size flag, a zero maximum and four characters of
    // colour, here the colour of the whole picture. 0x336699 = 3369369.
    const blue = [_]u8{ 0x33, 0x66, 0x99, 255 } ** 16;
    const one = blurhash(&out, &blue, 4, 4, 1, 1).?;
    try std.testing.expectEqual(@as(usize, 6), one.len);
    try std.testing.expectEqual(@as(u8, '0'), one[0]);
    try std.testing.expectEqual(@as(u8, '0'), one[1]);
    var value: u32 = 0;
    for (one[2..6]) |c| value = value * 83 + @as(u32, @intCast(std.mem.indexOfScalar(u8, base83, c).?));
    try std.testing.expectEqual(@as(u32, 0x336699), value);
}

test "an imeta tag carries what the uploader knows and leaves out what it does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const full = try imetaTag(arena.allocator(), "https://cdn.example/a.png", "image/png", "ab" ** 32, 1234, 800, 600, "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "A red door");
    try std.testing.expectEqual(@as(usize, 8), full.len);
    try std.testing.expectEqualStrings("imeta", full[0]);
    try std.testing.expectEqualStrings("url https://cdn.example/a.png", full[1]);
    try std.testing.expectEqualStrings("m image/png", full[2]);
    try std.testing.expectEqualStrings("x " ++ "ab" ** 32, full[3]);
    try std.testing.expectEqualStrings("size 1234", full[4]);
    try std.testing.expectEqualStrings("dim 800x600", full[5]);
    try std.testing.expectEqualStrings("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj", full[6]);
    try std.testing.expectEqualStrings("alt A red door", full[7]);
    const bare = try imetaTag(arena.allocator(), "https://cdn.example/a.png", "image/png", "", 0, 0, 0, "", "");
    try std.testing.expectEqual(@as(usize, 3), bare.len);
}

// ------------------------------------------------------- a server for tests

/// A Blossom server on loopback, for the tests that send to something real. It
/// reads each request properly, remembers what it was given, and answers the way
/// its mode says.
pub const TestServer = struct {
    server: Io.net.Server,
    mode: Mode,
    connections: usize,
    task: Io.Future(void),
    heads: std.atomic.Value(usize) = .init(0),
    puts: std.atomic.Value(usize) = .init(0),
    body_len: std.atomic.Value(usize) = .init(0),
    body_matches_header: std.atomic.Value(bool) = .init(false),
    auth_ok: std.atomic.Value(bool) = .init(false),
    type_ok: std.atomic.Value(bool) = .init(false),
    /// Whether the last body held a PNG text chunk, which a clean upload never does.
    body_has_text: std.atomic.Value(bool) = .init(false),

    pub const Mode = enum {
        /// HEAD 200, PUT 200 with a descriptor.
        accept,
        /// HEAD 413 with a reason. A PUT is never expected.
        refuse_head,
        /// HEAD 405 (no preflight here), PUT 200.
        no_preflight,
        /// HEAD 200, PUT 402 with no reason.
        refuse_put,
        /// HEAD 200, PUT 200 with something that is not a descriptor.
        garbage,
        /// Accepts the connection and never answers.
        silent,
    };

    pub fn start(io: Io, mode: Mode, connections: usize) !*TestServer {
        const self = try std.heap.page_allocator.create(TestServer);
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.* = .{ .server = try address.listen(io, .{ .reuse_address = true }), .mode = mode, .connections = connections, .task = undefined };
        self.task = try io.concurrent(serve, .{ self, io });
        return self;
    }

    pub fn stop(self: *TestServer, io: Io) void {
        self.task.cancel(io);
        self.server.deinit(io);
        std.heap.page_allocator.destroy(self);
    }

    pub fn url(self: *const TestServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.server.socket.address.ip4.port}) catch unreachable;
    }

    fn serve(self: *TestServer, io: Io) void {
        for (0..self.connections) |_| {
            const conn = self.server.accept(io) catch return;
            defer conn.close(io);
            self.handle(io, conn) catch {};
        }
    }

    fn handle(self: *TestServer, io: Io, conn: Io.net.Stream) !void {
        const gpa = std.heap.page_allocator;
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var w = conn.writer(io, &wbuf);
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(gpa);
        while (std.mem.indexOf(u8, req.items, "\r\n\r\n") == null) {
            try r.interface.fillMore();
            const got = r.interface.buffered();
            try req.appendSlice(gpa, got);
            r.interface.toss(got.len);
        }
        if (self.mode == .silent) {
            while (true) try io.sleep(.fromMilliseconds(1000), .awake);
        }
        const head_end = std.mem.indexOf(u8, req.items, "\r\n\r\n").? + 4;
        const head = req.items[0..head_end];
        const is_head = std.mem.startsWith(u8, head, "HEAD ");
        const is_put = std.mem.startsWith(u8, head, "PUT /upload ");
        const auth = headerValue(head, "authorization");
        const sha = headerValue(head, "x-sha-256");
        const ctype = headerValue(head, "content-type");
        if (is_head) {
            _ = self.heads.fetchAdd(1, .monotonic);
            switch (self.mode) {
                .refuse_head => try w.interface.writeAll("HTTP/1.1 413 Content Too Large\r\nX-Reason: too big for this server\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
                .no_preflight => try w.interface.writeAll("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
                else => try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
            }
            try w.interface.flush();
            return;
        }
        if (!is_put) return;
        const want: usize = std.fmt.parseInt(usize, headerValue(head, "content-length") orelse "0", 10) catch 0;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.appendSlice(gpa, req.items[head_end..]);
        while (body.items.len < want) {
            try r.interface.fillMore();
            const got = r.interface.buffered();
            try body.appendSlice(gpa, got);
            r.interface.toss(got.len);
        }
        _ = self.puts.fetchAdd(1, .monotonic);
        self.body_len.store(body.items.len, .release);
        self.body_has_text.store(std.mem.indexOf(u8, body.items, "tEXt") != null, .release);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body.items, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        self.body_matches_header.store(sha != null and std.mem.eql(u8, sha.?, &hex), .release);
        self.auth_ok.store(auth != null and std.mem.startsWith(u8, auth.?, "Nostr "), .release);
        self.type_ok.store(ctype != null and std.mem.eql(u8, ctype.?, "image/png"), .release);
        switch (self.mode) {
            .refuse_put => try w.interface.writeAll("HTTP/1.1 402 Payment Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
            .garbage => try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"),
            else => {
                var json_buf: [512]u8 = undefined;
                var base: [64]u8 = undefined;
                const json = try std.fmt.bufPrint(&json_buf, "{{\"url\":\"{s}/{s}\",\"sha256\":\"{s}\",\"size\":{d},\"type\":\"image/png\",\"uploaded\":1}}", .{ self.url(&base), hex, hex, body.items.len });
                try w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json.len, json });
            },
        }
        try w.interface.flush();
    }
};

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn testRequest(servers: []const []const u8, prepared: *const Prepared, idle_ms: i64) Request {
    return .{
        .servers = servers,
        .bytes = prepared.bytes,
        .mime = prepared.format.mime(),
        .ext = prepared.format.ext(),
        .sha256_hex = &prepared.sha256,
        .authorization = "Nostr e30=",
        .idle_ms = idle_ms,
    };
}

test "a picture reaches a server whole, with its hash, type and token, and the address comes back" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 40, 30, ""));
    defer prepared.deinit(gpa);
    const srv = try TestServer.start(io, .accept, 2);
    defer srv.stop(io);
    var url_buf: [64]u8 = undefined;
    const servers = [_][]const u8{srv.url(&url_buf)};
    var progress: Progress = .{ .total = prepared.bytes.len };
    const out = upload(io, testRequest(&servers, &prepared, 5000), &progress);
    try std.testing.expect(out == .ok);
    try std.testing.expectEqual(@as(u8, 0), out.ok.server);
    try std.testing.expectEqual(@as(usize, 1), srv.heads.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), srv.puts.load(.acquire));
    try std.testing.expectEqual(prepared.bytes.len, srv.body_len.load(.acquire));
    try std.testing.expect(srv.body_matches_header.load(.acquire));
    try std.testing.expect(srv.auth_ok.load(.acquire));
    try std.testing.expect(srv.type_ok.load(.acquire));
    try std.testing.expectEqual(prepared.bytes.len, progress.sent.load(.acquire));
    const d = out.ok.descriptor;
    try std.testing.expect(std.mem.startsWith(u8, d.url(), "http://127.0.0.1:"));
    try std.testing.expect(std.mem.endsWith(u8, d.url(), ".png"));
    try std.testing.expectEqualStrings(&prepared.sha256, d.sha256().?);
}

test "a server that says no before the file is sent never receives it, and the reason is shown" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 8, 8, ""));
    defer prepared.deinit(gpa);
    const srv = try TestServer.start(io, .refuse_head, 1);
    defer srv.stop(io);
    var url_buf: [64]u8 = undefined;
    const servers = [_][]const u8{srv.url(&url_buf)};
    var progress: Progress = .{};
    const out = upload(io, testRequest(&servers, &prepared, 5000), &progress);
    try std.testing.expect(out == .failed);
    try std.testing.expect(std.mem.indexOf(u8, out.failed.text(), "too big for this server") != null);
    try std.testing.expect(std.mem.startsWith(u8, out.failed.text(), "127.0.0.1:"));
    try std.testing.expectEqual(@as(usize, 0), srv.puts.load(.acquire));
}

test "the next server is tried when the first refuses, and one without a preflight is not a refusal" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 8, 8, ""));
    defer prepared.deinit(gpa);
    const bad = try TestServer.start(io, .refuse_head, 1);
    defer bad.stop(io);
    const good = try TestServer.start(io, .no_preflight, 2);
    defer good.stop(io);
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const servers = [_][]const u8{ bad.url(&a), good.url(&b) };
    var progress: Progress = .{};
    const out = upload(io, testRequest(&servers, &prepared, 5000), &progress);
    try std.testing.expect(out == .ok);
    try std.testing.expectEqual(@as(u8, 1), out.ok.server);
    try std.testing.expectEqual(@as(usize, 0), bad.puts.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), good.puts.load(.acquire));
}

test "a refusal with no reason is put in words, and an answer that is not a descriptor is reported as that" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 8, 8, ""));
    defer prepared.deinit(gpa);
    {
        const srv = try TestServer.start(io, .refuse_put, 2);
        defer srv.stop(io);
        var a: [64]u8 = undefined;
        const servers = [_][]const u8{srv.url(&a)};
        var progress: Progress = .{};
        const out = upload(io, testRequest(&servers, &prepared, 5000), &progress);
        try std.testing.expect(out == .failed);
        try std.testing.expect(std.mem.indexOf(u8, out.failed.text(), "payment required (402)") != null);
    }
    {
        const srv = try TestServer.start(io, .garbage, 2);
        defer srv.stop(io);
        var a: [64]u8 = undefined;
        const servers = [_][]const u8{srv.url(&a)};
        var progress: Progress = .{};
        const out = upload(io, testRequest(&servers, &prepared, 5000), &progress);
        try std.testing.expect(out == .failed);
        try std.testing.expect(std.mem.indexOf(u8, out.failed.text(), "made no sense") != null);
    }
}

test "a server that goes quiet is given up on, and a port with nothing there fails" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 8, 8, ""));
    defer prepared.deinit(gpa);
    {
        const srv = try TestServer.start(io, .silent, 1);
        defer srv.stop(io);
        var a: [64]u8 = undefined;
        const servers = [_][]const u8{srv.url(&a)};
        var progress: Progress = .{};
        const started = Io.Timestamp.now(io, .awake).toMilliseconds();
        const out = upload(io, testRequest(&servers, &prepared, 400), &progress);
        const took = Io.Timestamp.now(io, .awake).toMilliseconds() - started;
        try std.testing.expect(out == .failed);
        try std.testing.expect(std.mem.indexOf(u8, out.failed.text(), "Could not reach") != null);
        // Bounded by the idle limit, not by the server.
        try std.testing.expect(took < 4000);
    }
    {
        // Bound, noted and closed again, so nothing is listening there.
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var closed = try address.listen(io, .{ .reuse_address = true });
        const port = closed.socket.address.ip4.port;
        closed.deinit(io);
        var a: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&a, "http://127.0.0.1:{d}", .{port});
        const servers = [_][]const u8{url};
        var progress: Progress = .{};
        const out = upload(io, testRequest(&servers, &prepared, 2000), &progress);
        try std.testing.expect(out == .failed);
    }
}

test "cancelling stops an upload that is waiting on a server" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var prepared = try prepare(gpa, try testPng(gpa, 8, 8, ""));
    defer prepared.deinit(gpa);
    const srv = try TestServer.start(io, .silent, 1);
    defer srv.stop(io);
    var a: [64]u8 = undefined;
    const servers = [_][]const u8{srv.url(&a)};
    var progress: Progress = .{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(p: *Progress) void {
            Io.sleep(std.testing.io, .fromMilliseconds(300), .awake) catch {};
            p.cancel.store(true, .release);
        }
    }.run, .{&progress});
    defer thread.join();
    const started = Io.Timestamp.now(io, .awake).toMilliseconds();
    const out = upload(io, testRequest(&servers, &prepared, 30_000), &progress);
    const took = Io.Timestamp.now(io, .awake).toMilliseconds() - started;
    try std.testing.expect(out == .cancelled);
    try std.testing.expect(took < 5000);
}

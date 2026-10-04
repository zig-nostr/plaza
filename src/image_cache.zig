//! Image URLs, decoding and resizing, and the image cache on disk.

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
const warmedAlready = main.warmedAlready;
const Effects = main.Effects;
const avatar_target_px = main.avatar_target_px;
const gif_target_px = main.gif_target_px;
const max_image_download_bytes = main.max_image_download_bytes;
const mediaProxy = main.mediaProxy;
const media_target_px = main.media_target_px;
const proxyRefusesHost = main.proxyRefusesHost;
const secret_file_permissions = main.secret_file_permissions;

/// Whether the host serves its own resized variants via `?w=`, letting us skip
/// the proxy hop entirely. nostr.build's Blossom hosts do; most others ignore it.
fn hostSupportsWidthParam(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "://blossom.nostr.build/") != null or
        std.mem.indexOf(u8, src, "://blossom.band/") != null or
        std.mem.indexOf(u8, src, ".blossom.band/") != null;
}

/// How an image is fitted when resized.
pub const MediaFit = enum {
    /// Square, cropped to fill: avatars.
    square,
    /// Scaled down to fit inside a square box, aspect preserved: feed images.
    /// Bounding both edges is what keeps a tall image inside the pixel budget.
    inside,
    /// Like `inside`, but every frame is kept and the result stays a GIF, so it
    /// can still animate. Asked for smaller, since the whole animation has to
    /// arrive inside the fetch cap.
    animation,
};

/// Whether `src` points at a GIF, which is fetched keeping its frames.
pub fn isGifUrl(src: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, src, '?') orelse src.len;
    return std.ascii.endsWithIgnoreCase(src[0..path_end], ".gif");
}

/// Builds the URL to fetch `src` at roughly `width` pixels, writing into `out`
/// and returning the slice to request. Falls back to `src` itself whenever no
/// resizing route applies or the URL would not fit.
pub fn mediaUrl(out: []u8, src: []const u8, width: u32, fit: MediaFit) []const u8 {
    // A host that resizes for us: cheapest path, no third party involved.
    if (hostSupportsWidthParam(src) and std.mem.indexOfScalar(u8, src, '?') == null) {
        return std.fmt.bufPrint(out, "{s}?w={d}", .{ src, width }) catch src;
    }
    const proxy = mediaProxy();
    if (!prefs.g_media_proxy_on or proxy.len == 0) return src;

    var encoded_buf: [768]u8 = undefined;
    const encoded = percentEncode(&encoded_buf, src) orelse return src;
    const sep: []const u8 = if (std.mem.endsWith(u8, proxy, "/")) "" else "/";
    return switch (fit) {
        .square => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=cover&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        .inside => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        // `n=-1` keeps every frame; the output stays a GIF because that is the
        // animated format the vendored decoder can read frame by frame.
        .animation => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&n=-1&output=gif", .{ proxy, sep, encoded, width, width }) catch src,
    };
}

/// Percent-encodes `src` into `out` (everything outside the unreserved set), so
/// a source URL survives as one query parameter. Null if it would not fit.
fn percentEncode(out: []u8, src: []const u8) ?[]const u8 {
    const hexdigits = "0123456789ABCDEF";
    var n: usize = 0;
    for (src) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            if (n + 1 > out.len) return null;
            out[n] = c;
            n += 1;
        } else {
            if (n + 3 > out.len) return null;
            out[n] = '%';
            out[n + 1] = hexdigits[c >> 4];
            out[n + 2] = hexdigits[c & 0x0f];
            n += 3;
        }
    }
    return out[0..n];
}
pub extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
pub extern fn stbi_load_gif_from_memory(buffer: [*]const u8, len: c_int, delays: *?[*]c_int, x: *c_int, y: *c_int, z: *c_int, comp: ?*c_int, req_comp: c_int) ?[*]u8;
pub extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbir_resize_uint8_linear(input_pixels: [*]const u8, input_w: c_int, input_h: c_int, input_stride_in_bytes: c_int, output_pixels: [*]u8, output_w: c_int, output_h: c_int, output_stride_in_bytes: c_int, pixel_layout: c_int) ?[*]u8;

/// `STBIR_RGBA`: four channels, alpha not premultiplied, which is what both stb
/// hands back and the registry wants.
const stbir_rgba: c_int = 4;

// The image cache: every image Plaza fetches is written to `$HOME/.plaza/media`
// under a hash of the URL it was fetched from (which encodes the requested
// size), and read back before the network is touched. This is what makes
// avatars and pictures local-first like the notes themselves: on every launch
// after the first they are on screen with the feed, not seconds later.

/// The cache file name for `url`: its SHA-256, hex encoded.
pub fn cacheName(out: *[64]u8, url: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hexdigits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0x0f];
    }
    return out[0..];
}

/// Opens (creating if needed) `$HOME/.plaza/media`.
pub fn mediaCacheDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza/media", .{home});
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Registers `url`'s image from the on-disk cache, if it is there. Reading a
/// handful of small files is fast enough to do inline, and it is what lets the
/// first painted frame already carry avatars.
pub fn loadCachedImage(fx: *Effects, id: u64, url: []const u8, max_dim: u32) ?DecodedSize {
    const io = main.g_io orelse return null;
    const environ = main.g_environ orelse return null;
    var dir = mediaCacheDir(io, environ) catch return null;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_download_bytes)) catch return null;
    defer gpa.free(bytes);
    return decodeAndRegister(fx, id, bytes, max_dim);
}

/// Writes a freshly fetched image into the cache. Best-effort: a failure here
/// only costs a re-download next launch.
/// The address a feed picture is fetched from, wherever it is fetched from.
///
/// ONE builder, because the disk cache is keyed by this string and two callers
/// derive it: the row that has a slot, and the warm pass that does not. Ask for
/// a different size, or forget the GIF branch, and the warmed bytes land under a
/// name nothing looks up: the download happens twice and the row still waits. A
/// test could compare two spellings; sharing the function means there are not
/// two to compare.
pub fn feedImageUrl(buf: []u8, src: []const u8) []const u8 {
    return feedImageUrlDirect(buf, src, false);
}

/// A face's URL, with `direct` skipping the proxy and asking the host itself.
///
/// The proxy refuses some hosts by policy rather than by picture: wsrv.nl
/// answers 400 for a `.pub` domain, which is where Ditto's Blossom server
/// lives, so those faces never arrive at all without this. The picture is
/// still resized by us afterwards, the same as a feed image fetched direct.
pub fn avatarUrl(buf: []u8, src: []const u8, direct: bool) []const u8 {
    if (direct or proxyRefusesHost(src)) return src;
    return mediaUrl(buf, src, avatar_target_px, .square);
}

/// The same, with `direct` skipping the proxy and asking the host itself.
///
/// The picture is still resized afterwards, by us: `decodeAndRegister` scales
/// anything over the registry's budget. What a direct fetch costs is the bytes
/// on the way in, since the proxy would have shrunk them first.
pub fn feedImageUrlDirect(buf: []u8, src: []const u8, direct: bool) []const u8 {
    if (direct or proxyRefusesHost(src)) return src;
    return if (isGifUrl(src))
        mediaUrl(buf, src, gif_target_px, .animation)
    else
        mediaUrl(buf, src, media_target_px, .inside);
}
/// Whether the disk cache already holds this URL's bytes. Cheaper than loading
/// them: warming only needs to know whether to ask the network, and decoding is
/// the expensive half.
pub fn cachedImageExists(url: []const u8) bool {
    const io = main.g_io orelse return false;
    const environ = main.g_environ orelse return false;
    var dir = mediaCacheDir(io, environ) catch return false;
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    var file = dir.openFile(io, name, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn storeCachedImage(url: []const u8, bytes: []const u8) void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = mediaCacheDir(io, environ) catch return;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    dir.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// The pixel size an image ended up registered at, so the view can lay it out
/// at its real aspect instead of stretching it into whatever box it is given.
const DecodedSize = struct { width: usize, height: usize };

/// The largest single dimension worth decoding. Its only real job is to make the
/// area check below safe to compute: squared it is 2^28, nowhere near overflowing
/// a usize, so `w * h` cannot wrap before anybody looks at it.
const image_max_dim = 16384;

/// And the area, which is the number that actually costs memory: four bytes a
/// pixel, so this is a 160 MB decode at the limit. A photograph does not reach
/// it; a file built to make an app allocate does.
const image_max_pixels = 40 * 1024 * 1024;

/// Whether a decoded image's own declared size is one to go on with.
pub fn imageSizeUsable(width: usize, height: usize) bool {
    if (width == 0 or height == 0) return false;
    // Both dimensions FIRST, so the multiply that follows cannot wrap. Checking
    // the area alone would be the check computing the very number it exists to
    // decide is safe.
    if (width > image_max_dim or height > image_max_dim) return false;
    return width * height <= image_max_pixels;
}

/// Decodes `bytes` and registers the pixels under `id`, downscaling so the long
/// edge is at most `max_dim`. Returns the registered size, or null on failure.
pub fn decodeAndRegister(fx: *Effects, id: u64, bytes: []const u8, max_dim: u32) ?DecodedSize {
    @setRuntimeSafety(true); // Pixel dimensions a stranger's file declares, multiplied into a buffer size.
    // Fast path: let the platform decode and register directly, but only when
    // what it produces is close to what this caller asked for.
    //
    // SDK 0.9.2 taught the platform decoder to downsample (thumbnail-at-index
    // against a pixel budget), so this stopped failing on real photos and
    // started succeeding on nearly all of them. That is the fix I asked for and
    // it is worth taking. The catch is that it fits the REGISTRY BUDGET, not
    // `max_dim`: it hands back roughly 512x512 whatever the caller wanted. For
    // feed media (480) and a banner (512) that is the right answer. For an
    // avatar drawn at 40pt and asked for at 128 it is four times the pixels on
    // each edge, so sixteen times the texture bytes, for every face on screen.
    //
    // So the small consumers TRY the vendored decoder first, which honours
    // `max_dim` exactly. They do not skip the platform: that broke every face in
    // the app. stb is compiled for JPEG, PNG and GIF only, and the image proxy
    // hands back WEBP, which is 327 of the 400 files in my own media cache. A
    // gate that sent avatars straight to stb sent them to a decoder that cannot
    // read the format they arrive in, so they all fell back to initials.
    //
    // Hence: platform first when the size it picks is the size we want, stb in
    // the middle because it honours `max_dim`, and platform LAST as the format
    // fallback. Every image gets a decoder that can read it, and only the ones
    // stb can read pay for the smaller texture.
    if (max_dim >= media_target_px) {
        if (fx.registerImageBytes(id, bytes)) |registered| {
            return .{ .width = registered.width, .height = registered.height };
        } else |_| {}
    }

    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse {
        // A format stb was not built for, which in practice means WEBP. The
        // platform decoder reads it, so ask even though it will come back
        // larger than `max_dim`: a face at the wrong size beats no face.
        if (max_dim < media_target_px) {
            if (fx.registerImageBytes(id, bytes)) |registered| {
                return .{ .width = registered.width, .height = registered.height };
            } else |_| {}
        }
        return null;
    };
    defer stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    const src_w: usize = @intCast(w);
    const src_h: usize = @intCast(h);
    // What the C decoder handed back, checked before anything multiplies it.
    //
    // Every line below turns these two numbers into a buffer size, and they came
    // out of a file somebody linked in a note. stb caps a single dimension at
    // 2^24, which is a product of 2^48 pixels, so "it decoded" is not the same as
    // "this is a size to allocate". The safety check above would catch the
    // overflow itself, but catching it means the app stops; refusing the picture
    // means the app carries on without it, which is the right answer for one
    // oversized image in a feed.
    if (!imageSizeUsable(src_w, src_h)) return null;
    const longest = @max(src_w, src_h);
    if (longest <= max_dim) {
        // The platform refused it for some other reason; the decoded pixels
        // still fit, so register them as they are.
        fx.registerImage(id, src_w, src_h, pixels[0 .. src_w * src_h * 4]) catch return null;
        return .{ .width = src_w, .height = src_h };
    }

    const scale = @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(longest));
    const dst_w: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_w)) * scale)));
    const dst_h: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_h)) * scale)));

    const gpa = std.heap.page_allocator;
    const out = gpa.alloc(u8, dst_w * dst_h * 4) catch return null;
    defer gpa.free(out);
    if (stbir_resize_uint8_linear(pixels, w, h, 0, out.ptr, @intCast(dst_w), @intCast(dst_h), 0, stbir_rgba) == null) return null;
    fx.registerImage(id, dst_w, dst_h, out) catch return null;
    return .{ .width = dst_w, .height = dst_h };
}

/// Whether the vendored decoder can read `bytes` at all. Test seam: what makes
/// the platform fallback in `decodeAndRegister` load-bearing is precisely which
/// formats stb was NOT built for.
pub fn stbCanDecodeForTest(bytes: []const u8) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return false;
    stbi_image_free(px);
    return true;
}

pub fn avatarUrlForTest(buf: []u8, src: []const u8, direct: bool) []const u8 {
    return avatarUrl(buf, src, direct);
}

pub fn feedImageUrlForTest(buf: []u8, src: []const u8) []const u8 {
    return feedImageUrl(buf, src);
}
pub fn mediaUrlForTest(buf: []u8, src: []const u8, px: u32, fit: MediaFit) []const u8 {
    return mediaUrl(buf, src, px, fit);
}
/// Whether warming has asked for this picture address, the way `warmPicture`
/// builds it.
pub fn pictureWarmedForTest(src: []const u8) bool {
    var url_buf: [1024]u8 = undefined;
    return warmedAlready(feedImageUrl(&url_buf, src));
}

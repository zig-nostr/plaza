//! Tests of image_cache.zig. Image URLs, decoding and resizing, and the image cache on disk.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig

test "media URLs route through the proxy, the host, or neither" {
    const saved = main.mediaProxy();
    var saved_buf: [200]u8 = undefined;
    @memcpy(saved_buf[0..saved.len], saved);
    const saved_len = saved.len;
    defer main.setMediaProxy(saved_buf[0..saved_len]);

    var buf: [1024]u8 = undefined;

    // With a proxy configured, the source is percent-encoded into it.
    main.setMediaProxy("https://wsrv.nl/");
    const proxied = main.mediaUrl(&buf, "https://host.example/a b.jpg", 512, .inside);
    try testing.expect(std.mem.startsWith(u8, proxied, "https://wsrv.nl/?url="));
    try testing.expect(std.mem.indexOf(u8, proxied, "https%3A%2F%2Fhost.example%2Fa%20b.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, proxied, "w=512") != null);

    // Avatars ask for a square crop at their own size.
    const square = main.mediaUrl(&buf, "https://host.example/a.jpg", 128, .square);
    try testing.expect(std.mem.indexOf(u8, square, "fit=cover") != null);
    try testing.expect(std.mem.indexOf(u8, square, "h=128") != null);

    // A host that resizes for itself still goes through the proxy while the
    // proxy is on: it is the proxy that keeps the reader's address private.
    const via_proxy = main.mediaUrl(&buf, "https://blossom.nostr.build/abc.jpg", 512, .inside);
    try testing.expect(std.mem.startsWith(u8, via_proxy, "https://wsrv.nl/?url="));

    // No proxy configured: load the original, untouched.
    main.setMediaProxy("");
    const direct = main.mediaUrl(&buf, "https://host.example/a.jpg", 512, .inside);
    try testing.expectEqualStrings("https://host.example/a.jpg", direct);
}

test "the proxy is never skipped, and the width shortcut reads the host, not the string" {
    const saved = main.mediaProxy();
    var saved_buf: [200]u8 = undefined;
    @memcpy(saved_buf[0..saved.len], saved);
    const saved_len = saved.len;
    defer main.setMediaProxy(saved_buf[0..saved_len]);
    const was_on = main.mediaProxyOn();
    defer main.setMediaProxyOn(was_on);

    var buf: [1024]u8 = undefined;
    main.setMediaProxy("https://wsrv.nl/");
    main.setMediaProxyOn(true);
    // Proxy on: everything goes through it. A path that merely contains a
    // resizing host's name, and the resizing hosts themselves (one of them is
    // a default upload server), alike.
    for ([_][]const u8{
        "https://tracker.example/x.blossom.band/p.png",
        "https://blossom.band/abc.jpg",
        "https://npub1x.blossom.band/abc.jpg",
        "https://blossom.nostr.build/abc.jpg",
    }) |src| {
        const url = main.mediaUrl(&buf, src, 512, .inside);
        if (!std.mem.startsWith(u8, url, "https://wsrv.nl/?url=")) {
            std.debug.print("\nfetched without the proxy: {s}\n", .{url});
            return error.ProxySkipped;
        }
    }

    // Proxy off: the shortcut, for the real hosts only.
    main.setMediaProxyOn(false);
    try testing.expectEqualStrings("https://blossom.band/abc.jpg?w=512", main.mediaUrl(&buf, "https://blossom.band/abc.jpg", 512, .inside));
    try testing.expectEqualStrings("https://npub1x.blossom.band/abc.jpg?w=512", main.mediaUrl(&buf, "https://npub1x.blossom.band/abc.jpg", 512, .inside));
    for ([_][]const u8{
        "https://tracker.example/x.blossom.band/p.png",
        "https://evilblossom.band/a.jpg",
        "https://blossom.band.evil.example/a.jpg",
        "https://blossom.band@evil.example/a.jpg",
        "http://blossom.band/a.jpg",
    }) |src| {
        try testing.expectEqualStrings(src, main.mediaUrl(&buf, src, 512, .inside));
    }
}

test "turning off the direct fallback stops every direct fetch at once" {
    const saved = main.mediaProxy();
    var saved_buf: [200]u8 = undefined;
    @memcpy(saved_buf[0..saved.len], saved);
    const saved_len = saved.len;
    defer main.setMediaProxy(saved_buf[0..saved_len]);
    const was_on = main.mediaProxyOn();
    defer main.setMediaProxyOn(was_on);
    const fallback_was = main.mediaDirectFallback();
    defer main.setMediaDirectFallback(fallback_was);
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    main.setMediaProxy("https://wsrv.nl/");
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);
    var buf: [1024]u8 = undefined;
    const src = "https://blocked.example/a.png";

    // Allowed: the proxy refused the host, so its pictures load from it.
    main.rememberHostRefusalForTest("blocked.example");
    try testing.expectEqualStrings(src, main.avatarUrlForTest(&buf, src, false));
    try testing.expectEqualStrings(src, main.feedImageUrlDirectForTest(&buf, src, false));
    const p = main.upsertProfile([_]u8{0x76} ** 32).?;
    p.avatar_direct = true;

    // Turned off: the remembered host, a picture already marked direct and a
    // face already marked direct all go back through the proxy.
    main.setMediaDirectFallback(false);
    try testing.expectEqual(@as(usize, 0), main.proxyRefusedCountForTest());
    try testing.expect(!p.avatar_direct);
    main.rememberHostRefusalForTest("blocked.example");
    try testing.expect(std.mem.startsWith(u8, main.avatarUrlForTest(&buf, src, true), "https://wsrv.nl/?url="));
    try testing.expect(std.mem.startsWith(u8, main.feedImageUrlDirectForTest(&buf, src, true), "https://wsrv.nl/?url="));
}
test "gif sources are recognised so their frames are kept" {
    try testing.expect(main.isGifUrl("https://x.com/a.gif"));
    try testing.expect(main.isGifUrl("https://x.com/a.GIF?v=1"));
    try testing.expect(!main.isGifUrl("https://x.com/a.jpg"));
}
test "a warmed picture is asked for at the address the row will look up" {
    // The disk cache is keyed by the URL, and two callers want one: the row that
    // holds a slot, and the warm pass that does not. Ask for a different size, or
    // forget the GIF branch, and the warmed bytes land under a name nothing looks
    // up, so the download happens twice and the row still waits.
    //
    // They share one builder, so there are not two spellings to drift. What is
    // worth pinning is that the builder still tells a GIF from a still: the sizes
    // differ, so getting that wrong would reintroduce the same miss.
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const gif = main.feedImageUrlForTest(&a, "https://example.com/a.gif");
    const still = main.feedImageUrlForTest(&b, "https://example.com/a.jpg");
    try testing.expect(gif.len > 0 and still.len > 0);
    try testing.expect(!std.mem.eql(u8, gif, still));
    // And a query string does not hide the extension from it.
    var c: [1024]u8 = undefined;
    const gif_q = main.feedImageUrlForTest(&c, "https://example.com/a.gif?w=1");
    try testing.expect(std.mem.indexOf(u8, gif_q, "a.gif") != null);
}
test "a decoded image is refused by size before anything multiplies it" {
    // Ordinary pictures, including a large photograph.
    try testing.expect(main.imageSizeUsable(1, 1));
    try testing.expect(main.imageSizeUsable(4032, 3024));
    try testing.expect(main.imageSizeUsable(8000, 4000));

    // Nothing to decode.
    try testing.expect(!main.imageSizeUsable(0, 100));
    try testing.expect(!main.imageSizeUsable(100, 0));

    // A single dimension past the cap, which is what keeps the area check from
    // being computed on numbers that could wrap.
    try testing.expect(!main.imageSizeUsable(20000, 4));
    try testing.expect(!main.imageSizeUsable(4, 20000));

    // Both dimensions plausible on their own, and their product is not: this is
    // the shape a file built to make an app allocate takes, and it is the one a
    // per-dimension limit alone lets through.
    try testing.expect(!main.imageSizeUsable(16000, 16000));

    // The largest thing stb itself will hand back. Reached only through the
    // dimension check, which is the point: the area check never runs on it.
    try testing.expect(!main.imageSizeUsable(1 << 24, 1 << 24));
}
test "the vendored decoder cannot read WEBP, which is why avatars need the platform" {
    // This is the fact the avatar path rests on, and it is worth a test because
    // getting it wrong broke every face in the app.
    //
    // src/stb_impl.c builds stb for JPEG, PNG and GIF only. The image proxy
    // hands back WEBP: 327 of the 400 files in my own media cache. So a decode
    // path that sends small images to stb ALONE sends them to a decoder that
    // cannot read the format they arrive in, and every avatar falls back to
    // initials. `decodeAndRegister` therefore keeps the platform decoder as a
    // format fallback for the small consumers, even though it returns a larger
    // image than they asked for.
    //
    // A bare RIFF/WEBP signature is enough: stb refusing it proves no WEBP
    // decoder is compiled in. If somebody later enables one, or vendors
    // libwebp, this goes red and the fallback can be revisited on purpose
    // rather than deleted by accident.
    const webp_signature = "RIFF\x24\x00\x00\x00WEBPVP8 ";
    try testing.expect(!main.stbCanDecodeForTest(webp_signature));

    // The formats it IS built for still decode, so the assertion above is about
    // WEBP and not about the buffer being short.
    const png_1x1 = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0aIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\x0d\x0a\x2d\xb4\x00\x00\x00\x00IEND\xaeB\x60\x82";
    try testing.expect(main.stbCanDecodeForTest(png_1x1));
}

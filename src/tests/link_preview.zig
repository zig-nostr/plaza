//! Tests of link_preview.zig. Link previews: the cache, the fetch, and reading a page's metadata.

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
const frameOfTextContaining = harness.frameOfTextContaining;

test "a page's own words come out of its head" {
    // Open Graph first, then the plain fallbacks, which is the order every other
    // reader uses. The parser is deliberately small: the body arrives capped at
    // 256 KiB, which is where the head lives, and what it cannot make sense of
    // leaves the card without that line rather than guessing.
    const og =
        "<html><head><title>Fallback</title>" ++
        "<meta property=\"og:title\" content=\"The real title\">" ++
        "<meta property=\"og:description\" content=\"What it says about itself.\">" ++
        "</head><body>ignored</body></html>";
    const meta = main.parsePageMeta(og);
    try testing.expectEqualStrings("The real title", meta.heading());
    try testing.expectEqualStrings("What it says about itself.", meta.description);

    // No Open Graph: the title tag and the description meta stand in.
    const plain = "<html><head><title>Just a title</title><meta name='description' content='Plain words.'></head></html>";
    const fallback = main.parsePageMeta(plain);
    try testing.expectEqualStrings("Just a title", fallback.heading());
    try testing.expectEqualStrings("Plain words.", fallback.description);

    // Nothing to say, and nothing invented.
    const bare = main.parsePageMeta("<html><body>no head at all</body></html>");
    try testing.expectEqual(@as(usize, 0), bare.heading().len);
    try testing.expectEqual(@as(usize, 0), bare.description.len);

    // An attribute whose name merely ENDS with one we want is not that one.
    const tricky = "<meta data-og:title=\"nope\" property=\"og:title\" content=\"yes\">";
    try testing.expectEqualStrings("yes", main.parsePageMeta(tricky).heading());

    // An empty Open Graph title is not an answer: the page's own title stands.
    const empty_og = "<html><head><title>Real title</title><meta property='og:title' content=''></head></html>";
    try testing.expectEqualStrings("Real title", main.parsePageMeta(empty_og).heading());
}

test "the domain a card shows is the host, without its www" {
    try testing.expectEqualStrings("example.com", main.urlDomain("https://www.example.com/a/b?c=d"));
    try testing.expectEqualStrings("news.ycombinator.com", main.urlDomain("https://news.ycombinator.com/item?id=1"));
    try testing.expectEqualStrings("example.com", main.urlDomain("http://example.com"));
}

test "the link a card previews is the first plain one" {
    // The picture's own URL is not a link to preview, and neither is any other
    // image: those are drawn, not summarised.
    const image = "https://host.example/a.jpg";
    const content = "look " ++ image ++ " and read https://example.com/post, then " ++ "https://other.example/b.png";
    const link = main.firstLinkUrl(content, image, &.{}) orelse return error.NoLink;
    // The trailing comma is punctuation, not part of the address.
    try testing.expectEqualStrings("https://example.com/post", link);

    // A note with nothing but its picture has no link to preview.
    try testing.expect(main.firstLinkUrl("here " ++ image, image, &.{}) == null);
}
test "a link is only previewed when it is safe to ask" {
    // This is the one place the app reaches out to an address a STRANGER chose,
    // unattended, because a note scrolled into view. Every rejection here is a
    // thing a note must not be able to make every reader's machine do.
    try testing.expect(main.previewableUrl("https://example.com/post"));
    try testing.expect(main.previewableUrl("https://news.ycombinator.com/item?id=1"));

    // Plaintext puts the reader's IP and the exact URL on the wire.
    try testing.expect(!main.previewableUrl("http://example.com/"));
    // Userinfo becomes an authorization header on a host of the author's choice.
    try testing.expect(!main.previewableUrl("https://admin:admin@example.com/"));
    try testing.expect(!main.previewableUrl("https://wirth.ch@evil.tld/x"));
    // The reader's own machine and their own network.
    try testing.expect(!main.previewableUrl("https://127.0.0.1/x"));
    try testing.expect(!main.previewableUrl("https://10.1.2.3/x"));
    try testing.expect(!main.previewableUrl("https://192.168.1.1/admin"));
    try testing.expect(!main.previewableUrl("https://172.16.0.1/"));
    try testing.expect(!main.previewableUrl("https://169.254.169.254/latest/meta-data/"));
    try testing.expect(!main.previewableUrl("https://100.64.0.1/"));
    try testing.expect(!main.previewableUrl("https://[::1]/"));
    // A service, not a site.
    try testing.expect(!main.previewableUrl("https://example.com:8787/approve"));
    // Names that are not public sites.
    try testing.expect(!main.previewableUrl("https://localhost/"));
    try testing.expect(!main.previewableUrl("https://printer.local/"));
    try testing.expect(!main.previewableUrl("https://vault.internal/"));
    // A public address that merely starts with a private-looking octet is fine.
    try testing.expect(main.previewableUrl("https://172.32.0.1/"));
}

test "the domain on a card is the host, not what precedes an at sign" {
    // The oldest phishing shape there is. A card showing `wirth.ch@evil.tld`
    // would be lending its credibility to whoever wrote the note.
    try testing.expectEqualStrings("evil.tld", main.urlDomain("https://wirth.ch@evil.tld/x"));
    try testing.expectEqualStrings("evil.tld", main.urlDomain("https://a@b@evil.tld/x"));
    // The port is not part of the name a reader recognises.
    try testing.expectEqualStrings("example.com", main.urlDomain("https://example.com:8443/x"));
    try testing.expectEqualStrings("example.com", main.urlDomain("https://www.example.com/a"));
}
test "a link preview stays inside the card, however long the page's description" {
    // The card is a fixed width and its text column used `grow = 1`. `grow`
    // hands out SPARE space and never takes any back, so a child whose natural
    // size already exceeds the row has nothing to grow into and keeps that
    // natural size. A page title and description with `wrap = false` are as wide
    // as the sentence, so the row overflowed the card, the card overflowed the
    // column, and the description ran off the right edge of the WINDOW.
    //
    // The ellipsis did not save it, because an ellipsis needs a box to be too
    // small for, and the leaf was never given one.
    //
    // Measuring the painted geometry, not the options: the bug was invisible in
    // the widget tree, where every node claimed to be an ellipsised single line.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    const url = "https://github.com/zig-nostr/notary/pull/35";
    main.setLinkPreviewForTest(
        url,
        "github.com",
        "Notary is Notary by sepehr-safari, Pull Request #35, zig-nostr/notary",
        "A native remote signer (NIP-46 bunker) for Nostr. Your key stays on a machine you control; every signing request is approved by you, and nothing else ever holds it.",
    );

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest(url);
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);

    // The card, found by ITS OWN semantics rather than by widget kind: the feed
    // is full of list items and the first one is not this. Getting that wrong is
    // how the first version of this test passed with the bug still in place.
    const card = frameOfSemantics(p, "Open link") orelse return error.NoLinkCard;
    const right = card.x + card.width;

    // The two lines that overflowed, found by their content.
    const title = frameOfTextContaining(p, "Pull Request #35") orelse return error.NoTitle;
    const desc = frameOfTextContaining(p, "native remote signer") orelse return error.NoDescription;

    for ([_]struct { name: []const u8, f: native_sdk.geometry.RectF }{
        .{ .name = "title", .f = title },
        .{ .name = "description", .f = desc },
    }) |row| {
        if (row.f.x + row.f.width > right + 0.5) {
            std.debug.print(
                "\nthe {s} runs to {d:.0}; the card ends at {d:.0}\n",
                .{ row.name, row.f.x + row.f.width, right },
            );
        }
        try testing.expect(row.f.x + row.f.width <= right + 0.5);
    }

    // Whether the CARD itself can exceed the window is a separate question from
    // whether its text can exceed the card, and only the second was reported.
}

/// The frame of the first laid-out node carrying this accessibility label.
fn frameOfSemantics(p: painted.Painted, label: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |n| {
        if (std.mem.eql(u8, n.widget.semantics.label, label)) return n.widget.frame;
    }
    return null;
}
test "a link preview's description is cut with an ellipsis, not by the card edge" {
    // The title elides through the engine and the description does not: the
    // engine's ellipsis works on a plain text node and not on a paragraph built
    // from spans, so this one is shortened in Zig. Both are asserted, because
    // the reason they differ is an engine detail that could change.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    const url = "https://coldcard-hack-tracker.example/x";
    main.setLinkPreviewForTest(
        url,
        "coldcard-hack-tracker.example",
        "Coldcard Hack Tracker and a title that carries on well past the room the card has for it",
        "Coldcard Hack Tracker, live monitoring of Bitcoin held from seed entropy sweeps since July 2026, and then some more words after that",
    );

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest(url);
    model.notes_len = 1;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);
    const card = frameOfSemantics(p, "Open link") orelse return error.NoLinkCard;
    const right = card.x + card.width;

    var found = false;
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, "live monitoring") == null) continue;
        found = true;
        // It says so, rather than simply stopping.
        if (std.mem.indexOf(u8, n.widget.text, "\u{2026}") == null) {
            std.debug.print("\nthe description was not cut: \"{s}\"\n", .{n.widget.text});
            return error.NoEllipsis;
        }
        // And it stops inside the card, which is the part a reader sees.
        if (n.widget.frame.x + n.widget.frame.width > right + 0.5) {
            std.debug.print(
                "\nthe description runs to {d:.0}; the card ends at {d:.0}\n",
                .{ n.widget.frame.x + n.widget.frame.width, right },
            );
            return error.DescriptionOverflowsCard;
        }
    }
    if (!found) return error.NoDescription;
}
test "a video is not fetched as a web page" {
    // The waste this closes: `previewableUrl` looks only at the authority, so
    // it says yes to a video file exactly as it does to an article. The runtime
    // truncates at 256 KiB, so every video in the feed cost up to a quarter of
    // a megabyte downloaded to look for `og:` tags it could never have.
    //
    // Both halves asserted: that the old gate really would have said yes, and
    // that knowing it is a video is what stops it. Asserting only the second
    // would pass even if the first had quietly started refusing videos anyway.
    try testing.expect(main.previewableUrl("https://cdn.example/clip.mp4"));
    try testing.expect(!main.shouldPreviewLink(true, "https://cdn.example/clip.mp4"));

    // An ordinary page is still previewed.
    try testing.expect(main.shouldPreviewLink(false, "https://example.com/post"));
    // And the authority rules still apply to something that is not a video.
    try testing.expect(!main.shouldPreviewLink(false, "http://example.com/post"));
    try testing.expect(!main.shouldPreviewLink(false, "https://localhost/post"));
}

test "a picture URL on the reader's own network is not one this app fetches" {
    for ([_][]const u8{
        "https://image.example.com/a.jpg",
        "http://image.example.com/a.jpg",
        "https://93.184.216.34/a.png",
    }) |url| try testing.expect(main.isPublicMediaUrl(url));
    for ([_][]const u8{
        "http://127.0.0.1/a.png",
        "http://127.1/a.png",
        "http://0x7f.1/a.png",
        "http://192.168.1.1/admin#.png",
        "http://10.0.0.7/a.png",
        "http://169.254.169.254/latest#.jpg",
        "http://localhost/a.png",
        "http://nas.local/a.png",
        "http://router.lan/a.png",
        "https://image.example.com:8443/a.png",
        "https://user@image.example.com/a.png",
        "http://[::1]/a.png",
        "ftp://image.example.com/a.png",
    }) |url| {
        if (main.isPublicMediaUrl(url)) {
            std.debug.print("\naccepted a private picture: {s}\n", .{url});
            return error.PrivatePictureAccepted;
        }
    }
    // The last check before any request: a direct fetch from a private host is
    // refused whatever path built it.
    try testing.expect(!main.mediaFetchAllowedForTest("http://127.0.0.1:9/shot.png"));
    try testing.expect(main.mediaFetchAllowedForTest("https://image.example.com/b.png"));
}

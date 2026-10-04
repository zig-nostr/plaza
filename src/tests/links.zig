//! Tests of links.zig. Links in and out: plaza:// links handed to the app, and external URLs opened in the browser.

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

test "only plain http(s) links are handed to the opener" {
    try testing.expect(main.isSafeExternalUrl("https://example.com/a"));
    try testing.expect(main.isSafeExternalUrl("http://example.com"));
    // Anything that is not a plain web URL, or that could be read as a flag or
    // carry control bytes, is refused.
    try testing.expect(!main.isSafeExternalUrl("file:///etc/passwd"));
    try testing.expect(!main.isSafeExternalUrl("-a/Applications/Calculator.app"));
    try testing.expect(!main.isSafeExternalUrl("nostr:npub1abc"));
    try testing.expect(!main.isSafeExternalUrl("https://example.com/a b"));
    try testing.expect(!main.isSafeExternalUrl("https://example.com/a\nb"));
    try testing.expect(!main.isSafeExternalUrl(""));
}
test "a plaza:// link names what to fetch and nothing else" {
    // A link can arrive from a note, a DM, anywhere. It carries an address, not
    // a place, so the worst a hostile one can do is point Plaza at an event that
    // is not a place (refused by the parser) or one that is (shown before it
    // applies).
    const ok = main.parsePlazaLink("plaza://place/naddr1qqxnzd3cxqmrzv3exgmr2wfeqgs9n") orelse
        return error.NoLink;
    try testing.expectEqualStrings("naddr1qqxnzd3cxqmrzv3exgmr2wfeqgs9n", ok);

    // A trailing slash, query or fragment is a link shortener's, not the address.
    const trimmed = main.parsePlazaLink("plaza://place/naddr1abc?utm_source=x") orelse
        return error.NoLink;
    try testing.expectEqualStrings("naddr1abc", trimmed);

    const refused = [_][]const u8{
        "plaza://place/", // nothing to fetch
        "plaza://place/nevent1abc", // not an address
        "plaza://place/NADDR1ABC", // bech32 is lowercase
        "plaza://place/naddr1 abc", // a space is not bech32
        "plaza://something/naddr1abc", // an action this version does not know
        // The old spelling. It was `plaza://mode/` while the feature was named
        // after fiatjaf's proposal, and nothing outside this machine ever held
        // one, so it is refused rather than carried: two spellings for one verb
        // is the drift the vocabulary rules exist to stop.
        "plaza://mode/naddr1abc",
        "plaza://naddr1abc", // no action at all
        "https://evil.example/naddr1abc", // not our scheme
        "plaza://place/naddr1abc/../../etc", // path games
    };
    for (refused) |link| {
        if (main.parsePlazaLink(link) != null) {
            std.debug.print("accepted a link it should refuse: {s}\n", .{link});
            return error.BadLinkAccepted;
        }
    }
}
test "a link followed while Plaza is open reaches the window that is already there" {
    // Following a plaza:// link from a browser starts a NEW process every time,
    // running or not. On a second launch GTK hands the launch to the window
    // already open and that process exits, so a link it read in its own argv
    // dies with it and the reader watches Plaza come to the front and do
    // nothing. Our code runs before the toolkit's, so the link goes to a file
    // and whichever process owns the window picks it up.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);

    var buf: [2048]u8 = undefined;
    // Nothing written: nothing to open.
    try testing.expect(main.takeWrittenLinkForTest(io, &dir, &buf, 1000) == null);

    main.writePendingLinkForTest(io, &dir, "plaza://place/naddr1handoff", 1000);
    const got = main.takeWrittenLinkForTest(io, &dir, &buf, 1002) orelse
        return error.TheHandoffLostTheLink;
    try testing.expectEqualStrings("plaza://place/naddr1handoff", got);

    // ONCE: the tick reads this every second, so a link that stayed would
    // reopen its room forever.
    if (main.takeWrittenLinkForTest(io, &dir, &buf, 1003) != null) {
        return error.TheHandoffKeptTheLink;
    }

    // And a link left by a crash is not one the reader just clicked.
    main.writePendingLinkForTest(io, &dir, "plaza://place/naddr1stale", 1000);
    if (main.takeWrittenLinkForTest(io, &dir, &buf, 1000 + 600) != null) {
        return error.AStaleLinkOpenedARoom;
    }
    // Taken off disk even so, or it would be retried every second forever.
    if (main.takeWrittenLinkForTest(io, &dir, &buf, 1001) != null) {
        return error.TheStaleLinkWasLeftBehind;
    }
}
test "every link the app will open is one the toolkit's policy permits" {
    // Both gates, checked against each other. Plaza refuses a URL with
    // `isSafeExternalUrl`, then the toolkit refuses it again against the
    // navigation policy, and NOTHING reports the second refusal: `hostSend`
    // is fire-and-forget and the error is swallowed. A policy that denies
    // everything therefore looks exactly like a link that does nothing.
    //
    // That shipped. The policy said `"https://*"`, which reads like a
    // scheme-wide wildcard and is not one: the toolkit's validator wants a
    // host AND a path slash after the scheme, so the pattern was discarded as
    // malformed and every link in the app was silently denied, on every
    // platform. It went unnoticed because the previous implementation spawned
    // `/usr/bin/open` and never consulted the policy at all.
    const allows = native_sdk.security.allowsExternalUrl;

    // Real links from real notes. Anything the first gate passes, the second
    // must pass too, or the reader clicks and nothing happens.
    for ([_][]const u8{
        "https://github.com/damus-io/notedeck",
        "http://example.com",
        "https://npub1lrnvvs6z78s9yjqxxr38uyqkmn34lsaxznnqgd877j4z2qej3j5s09qnw5.blossom.band/e4170a9023d80ba82b8a520bed88606ab6f12c196973772a61635f7141dae8ee.jpg",
        "https://zignostr.com",
        "https://a.b",
    }) |url| {
        if (!main.isSafeExternalUrl(url)) return error.TheFirstGateRefusedARealLink;
        if (!allows(main.external_link_policy, url)) return error.TheToolkitWouldDenyALinkThisAppAccepts;
    }

    // And the action is the one that reaches a browser at all. `.deny` is the
    // default, and defaulting here is the same silent failure by another route.
    try testing.expect(main.external_link_policy.action == .open_system_browser);
}

test "a link on the command line is delivered once" {
    // On macOS a plaza:// link arrives as an Apple Event. Nowhere else: the
    // desktop entry's %u puts it in argv, and the toolkit's Linux host drops
    // argv before any app code runs, so reading it ourselves at startup is the
    // whole of cold start there. A place has no other door, so without this a
    // Linux reader cannot enter one at all.
    var buf: [2048]u8 = undefined;
    // Nothing pending: the tick polls this every second and must not invent one.
    try testing.expect(main.takePendingLinkForTest(&buf) == null);

    main.captureArgvLinkForTest("plaza://place/naddr1abc");
    const got = main.takePendingLinkForTest(&buf) orelse return error.TheLinkWasDropped;
    try testing.expectEqualStrings("plaza://place/naddr1abc", got);

    // ONCE. A link that stayed would reopen its place on every tick, forever.
    if (main.takePendingLinkForTest(&buf) != null) return error.TheLinkCameBackASecondTime;
}

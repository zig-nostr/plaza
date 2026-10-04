//! Tests of prefs.zig. Reader settings: media previews, the client tag, the media proxy, and the settings file.

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
const buildTree = harness.buildTree;
const countByLabel = harness.countByLabel;
const findAnyText = harness.findAnyText;
const findAnyTextContaining = harness.findAnyTextContaining;
const findByLabel = harness.findByLabel;
const pressMsgByLabel = harness.pressMsgByLabel;
const quotePictureModel = harness.quotePictureModel;
const threadNote = harness.threadNote;
const warnedEvent = harness.warnedEvent;

test "with previews off a picture is one chip, and asking for it loads that one" {
    // The setting is not about bandwidth. Reading a feed should not tell every
    // host in it that you did, so nothing leaves the machine until the reader
    // asks for a particular picture.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const url = "https://host.example/a.jpg";
    const img = model.notes[0].setImageForTest(0, url);
    img.w = 1600;
    img.h = 900;
    img.bytes = 240_000;
    model.notes_len = 1;

    main.setMediaPreviews(false);
    defer main.setMediaPreviews(true);

    const off = try painted.Painted.render(arena, &model);
    try testing.expect(off.frameOf("Load this image") != null);
    // No reserved box: the row is priced for the chip, not for a picture that is
    // not coming.
    try testing.expect(off.frameOf("Attached image, press to enlarge") == null);
    const chip_priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);

    // Asked for: the box comes back, and so does its price.
    main.askForMediaForTest(model.notes[0].id);
    defer main.forgetAskedMediaForTest();
    const on = try painted.Painted.render(arena, &model);
    try testing.expect(on.frameOf("Attached image, press to enlarge") != null);
    const box_priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    try testing.expect(box_priced > chip_priced + 100);
}
test "the client-tag switch is wired, and flipping it sticks" {
    // The automation harness cannot drive a `.checkbox`: its snapshot advertises
    // `actions=[focus,toggle]` and `widget-action ... toggle` reports "delivered"
    // while nothing moves. That is true of the media-previews checkbox this one
    // sits beside, so it is the harness, not this switch. It does mean the switch
    // cannot be proven by driving the real app, which is exactly the case where a
    // control quietly turns out to be wired to nothing. So it is proven here
    // instead: the widget carries a toggle handler, and the message behind it
    // changes what gets published.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setClientTag(false);
    defer main.setClientTag(false);

    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    const box = findByLabel(tree.root, "Say notes were written in Plaza") orelse return error.SwitchMissing;
    var wired = false;
    for (tree.handlers) |h| {
        if (h.id == box.id and h.event == .toggle) wired = true;
    }
    try testing.expect(wired);

    // And the message behind it does what the label says.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.clientTag());
    main.update(&model, .client_tag_toggle, &fx);
    try testing.expect(main.clientTag());

    // Which is visible in what a note would carry.
    const base = [_]nostr.event.Tag{&.{ "e", "ab" ** 32 }};
    const out = main.withClientTag(testing.allocator, 1, &base);
    defer {
        testing.allocator.free(out[out.len - 1]);
        testing.allocator.free(out);
    }
    try testing.expectEqual(@as(usize, 2), out.len);

    main.update(&model, .client_tag_toggle, &fx);
    try testing.expect(!main.clientTag());
}
test "a covered quote card neither draws nor fetches its picture until it is shown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);
    main.setMediaProxyOn(false);
    main.setMediaPreviews(true);
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);
    defer main.setShowSensitive(false);

    const quoted_id = [_]u8{0x5f} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    main.warnQuoteForTest(quoted_id, "spoilers");
    const key = main.quoteMediaKeyForTest(quoted_id);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();

    // Covered: no slot, no picture box, and the row is priced for the chip.
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) == null);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Picture in the quoted note") == null);
        try testing.expect(findAnyText(p.tree.root, "Picture from 127.0.0.1:9") == null);
        const rows = p.framesOf("Open thread");
        if (rows.len < 1) return error.NoRow;
        const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
        try testing.expect(@abs(rows[0].height - priced) <= 0.5 * main.body_line_height);
    }

    // Shown: the same card claims its picture.
    main.setShowSensitive(true);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    const held = main.mediaSlotStateForTest(key) orelse return error.NoSlotClaimed;
    try testing.expect(held.image_id != 0);
}

/// The drawn height of the first feed row and what the estimate charges for it.
fn quoteRowHeights(arena: std.mem.Allocator, model: *main.Model) !struct { drawn: f32, priced: f32 } {
    const p = try painted.Painted.render(arena, model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    return .{ .drawn = rows[0].height, .priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome) };
}

test "a quote's picture is priced at exactly the box it draws, before and after its shape is known" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    // No `dim`: the shape is a guess until the picture has been decoded once.
    const quoted_id = [_]u8{0x65} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0);
    const key = main.quoteMediaKeyForTest(quoted_id);

    // The same row with the chip instead of the box is the baseline: whatever
    // slack the rest of the row's estimate has cancels out, and what is left is
    // the box against its price, which has to match to the pixel.
    main.setMediaPreviews(false);
    const chip = try quoteRowHeights(arena, &model);

    main.setMediaPreviews(true);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);

    const guessed = try quoteRowHeights(arena, &model);
    try testing.expectApproxEqAbs(guessed.priced - chip.priced, guessed.drawn - chip.drawn, 1.0);

    // Decoded at 2:1. The box takes the measured shape, and the estimate moves
    // with it rather than staying at the guess.
    try testing.expect(main.markMediaLoadedForTest(&fx, key, 800, 400) != null);
    const measured = try quoteRowHeights(arena, &model);
    try testing.expectApproxEqAbs(measured.priced - chip.priced, measured.drawn - chip.drawn, 1.0);
    const moved = main.quotePictureBox(0).height - main.quotePictureBox(0.5).height;
    try testing.expectApproxEqAbs(moved, guessed.priced - measured.priced, 0.01);

    // Evicted, the slot is gone but the shape is remembered, so the card does
    // not fall back to the guess and shift the feed on the way back up.
    main.resetMediaForTest();
    const recalled = try quoteRowHeights(arena, &model);
    try testing.expectApproxEqAbs(measured.priced, recalled.priced, 0.01);
    try testing.expectApproxEqAbs(measured.drawn, recalled.drawn, 1.0);
}
test "a picture missing at the proxy is missing at the host too" {
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
    }
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_011;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    // A 404 is the source, not the proxy. Going direct would be a second
    // download with an answer already known.
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 404, "");
    try testing.expect(!main.mediaFallbackStateForTest(note_id).?.direct);
}
test "a face whose host the proxy refuses is asked for directly" {
    // wsrv.nl answers 400 for a .pub domain, which is where Ditto's Blossom
    // server lives, so these faces never arrived at all: the fallback existed
    // only on the feed's pictures and the avatar path went straight to giving
    // up. Same for the banner beside it.
    const src = "https://blossom.ditto.pub/94582539b065a7a561c3d6ded50c5edec85fccca9882095a4e7c81b05d12fd51.jpeg";

    // Pin the proxy state this asserts about, and put it back: these are
    // globals and the suite shares them.
    const saved = main.mediaProxy();
    var saved_buf: [200]u8 = undefined;
    @memcpy(saved_buf[0..saved.len], saved);
    const saved_len = saved.len;
    const saved_on = main.mediaProxyOn();
    defer {
        main.setMediaProxy(saved_buf[0..saved_len]);
        main.setMediaProxyOn(saved_on);
    }
    main.setMediaProxyOn(true);
    main.setMediaProxy("https://wsrv.nl/");

    var proxied_buf: [1024]u8 = undefined;
    const proxied = main.avatarUrlForTest(&proxied_buf, src, false);
    try testing.expect(std.mem.indexOf(u8, proxied, "wsrv.nl") != null);
    try testing.expect(!std.mem.eql(u8, proxied, src));

    // Direct is the source itself, untouched: no proxy, no resize parameters.
    var direct_buf: [1024]u8 = undefined;
    const direct = main.avatarUrlForTest(&direct_buf, src, true);
    try testing.expectEqualStrings(src, direct);
}
test "a 404 is the picture missing, so it is not retried against the host" {
    defer main.resetProfilesForTest();
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
    }
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    var fx: main.EffectsForTest = undefined;
    const pk = [_]u8{0x3c} ** 32;
    main.setProfileAvatarForTest(pk, 1, .fetching);

    // Missing at the proxy means missing at the host too, so going direct is a
    // second download with a known answer.
    main.deliverAvatarResponseForTest(&fx, pk, .ok, 404, "");
    try testing.expect(!main.avatarFallbackStateForTest(pk).?.direct);
}

test "the proxy toggle decides whether a URL is rewritten at all" {
    const original = "https://blossom.ditto.pub/abc.jpeg";
    var buf: [1024]u8 = undefined;

    // The proxy URL too: a test process never loads the settings file, so this
    // starts empty, and an empty proxy means "use the original" whatever the
    // switch says.
    main.setMediaProxy("https://wsrv.nl/");
    main.setMediaProxyOn(true);
    defer main.setMediaProxyOn(true);
    const proxied = main.feedImageUrlForTest(&buf, original);
    try testing.expect(std.mem.indexOf(u8, proxied, "wsrv.nl") != null);

    // Off, the picture's own URL is used untouched, which is what somebody
    // reaches for when a proxy is refusing their images.
    main.setMediaProxyOn(false);
    var buf2: [1024]u8 = undefined;
    try testing.expectEqualStrings(original, main.feedImageUrlForTest(&buf2, original));
}
test "a covered note shows who wrote it and why, and nothing it says or points at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);
    // Previews off so a press that uncovers a picture asks for nothing: a test
    // cannot construct a usable effect table.
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(false);
    defer main.setMediaPreviews(previews_were);

    var model = main.initialModel();
    model.stage = .ready;
    const first_tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const second_tags = [_]nostr.event.Tag{&.{"content-warning"}};
    model.notes[0] = main.noteFrom(warnedEvent(0xC2, "FIRSTSECRET https://example.com/a.jpg", &first_tags), 1_800_000_100);
    model.notes[1] = main.noteFrom(warnedEvent(0xC3, "SECONDSECRET", &second_tags), 1_800_000_100);
    model.notes[2] = main.noteFrom(warnedEvent(0xC4, "PLAINWORDS", &.{}), 1_800_000_100);
    model.notes_len = 3;

    const before = try buildTree(arena, &model);
    // The words are not in the tree at all, so they cannot be read, copied from
    // the accessibility tree or drawn by a later change that forgets to check.
    try testing.expect(!findAnyTextContaining(before.root, "FIRSTSECRET"));
    try testing.expect(!findAnyTextContaining(before.root, "SECONDSECRET"));
    try testing.expect(findAnyTextContaining(before.root, "PLAINWORDS"));
    // The reason, when there is one, and the plain notice when there is not.
    try testing.expect(findAnyTextContaining(before.root, "Content warning: spoilers"));
    try testing.expect(findAnyText(before.root, "Content warning") != null);
    try testing.expectEqual(@as(usize, 2), countByLabel(before.root, "Show this note"));
    // And no picture: not drawn, and not offered as one to load either.
    try testing.expectEqual(@as(usize, 0), countByLabel(before.root, "Attached image, press to enlarge"));
    try testing.expectEqual(@as(usize, 0), countByLabel(before.root, "Load this image"));

    // Pressing uncovers THAT note and no other.
    const msg = pressMsgByLabel(before, "Show this note") orelse return error.NothingToPress;
    switch (msg) {
        .uncover_note => |key| try testing.expectEqual(model.notes[0].id, key),
        else => return error.WrongPress,
    }
    var fx: main.EffectsForTest = undefined;
    main.update(&model, msg, &fx);

    const after = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(after.root, "FIRSTSECRET"));
    try testing.expect(!findAnyTextContaining(after.root, "SECONDSECRET"));
    try testing.expectEqual(@as(usize, 1), countByLabel(after.root, "Show this note"));
    // The picture is now offered, which means it was not before.
    try testing.expectEqual(@as(usize, 1), countByLabel(after.root, "Load this image"));
}

test "the setting for readers who would rather see everything is off, and does what it says" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    // The default, before anything has touched it.
    try testing.expect(!main.showSensitive());
    defer main.setShowSensitive(false);

    var model = main.initialModel();
    model.stage = .ready;
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    model.notes[0] = main.noteFrom(warnedEvent(0xC5, "OPENLYSHOWN", &tags), 1_800_000_100);
    model.notes_len = 1;

    try testing.expect(main.noteCovered(&model.notes[0]));
    main.setShowSensitive(true);
    try testing.expect(!main.noteCovered(&model.notes[0]));
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(tree.root, "OPENLYSHOWN"));
    try testing.expectEqual(@as(usize, 0), countByLabel(tree.root, "Show this note"));
}
/// How many fetches a fake effect table has recorded.
fn recordedFetches(fx: *main.EffectsForTest) usize {
    return fx.pendingFetchCount();
}

test "a covered note's pictures are not fetched, and are once it is uncovered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.resetWarmForTest();
    defer main.resetWarmForTest();
    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);
    // Previews ON, which is the case that matters: the note is covered and
    // nothing else is stopping the request. The proxy is off so the address a
    // fetch would go to is the note's own.
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(true);
    defer main.setMediaPreviews(previews_were);
    const proxy_was = main.mediaProxyOn();
    main.setMediaProxyOn(false);
    defer main.setMediaProxyOn(proxy_was);

    // A real effect table in its fake mode: requests are recorded, never sent.
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    const picture = "https://example.com/private.jpg";
    const page = "https://example.org/article";
    var model = main.initialModel();
    model.stage = .ready;
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "nudity" }};
    model.notes[0] = main.noteFrom(warnedEvent(0xC8, picture ++ " " ++ page, &tags), 1_800_000_100);
    model.notes_len = 1;
    try testing.expect(model.notes[0].hasImage());
    try testing.expect(model.notes[0].hasLink());
    _ = try painted.Painted.render(arena, &model);

    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    main.scanLinkFetchesForTest(&fx, &model);
    // No slot was ever claimed for it, so nothing was requested.
    try testing.expect(main.mediaSlotWantedForTest(model.notes[0].id) == null);
    try testing.expect(!main.linkRequestedForTest(page));
    try testing.expectEqual(@as(usize, 0), recordedFetches(&fx));

    // The positive control: the same note, uncovered, is asked for. Without it
    // the assertions above would pass for a note that could never be fetched.
    main.uncoverNoteForTest(model.notes[0].id);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    main.scanLinkFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotWantedForTest(model.notes[0].id) != null);
    try testing.expect(main.linkRequestedForTest(page));
    try testing.expect(recordedFetches(&fx) >= 2);
}

test "warming ahead skips a covered note and fetches the same note once uncovered" {
    main.resetWarmForTest();
    defer main.resetWarmForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(true);
    defer main.setMediaPreviews(previews_were);
    const proxy_was = main.mediaProxyOn();
    main.setMediaProxyOn(false);
    defer main.setMediaProxyOn(proxy_was);
    defer main.setVisibleRangeForTest(0, 0);

    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    // Twenty plain rows, with the note under test just below the screen, inside
    // the band that is warmed.
    var model = main.initialModel();
    model.stage = .ready;
    for (0..20) |i| {
        model.notes[i] = main.noteFrom(warnedEvent(@intCast(0x40 + i), "plain", &.{}), 1_800_000_100);
        model.notes[i].id = @intCast(500 + i);
    }
    model.notes_len = 20;
    main.setVisibleRangeForTest(0, 2);
    const at = model.visibleRange().last + 1;
    try testing.expect(at <= model.prefetchRange().last);
    const picture = "https://example.com/below.jpg";
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "graphic" }};
    model.notes[at] = main.noteFrom(warnedEvent(0xE0, picture, &tags), 1_800_000_100);
    model.notes[at].id = 900;
    try testing.expect(model.notes[at].hasImage());

    main.warmAheadForTest(&fx, &model);
    try testing.expect(!main.pictureWarmedForTest(picture));
    try testing.expectEqual(@as(usize, 0), recordedFetches(&fx));

    main.uncoverNoteForTest(model.notes[at].id);
    main.warmAheadForTest(&fx, &model);
    try testing.expect(main.pictureWarmedForTest(picture));
    try testing.expectEqual(@as(usize, 1), recordedFetches(&fx));
}

test "a covered row is priced as the chip it draws" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    main.setShowSensitive(false);
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(true);
    defer main.setMediaPreviews(previews_were);

    var model = main.initialModel();
    model.stage = .ready;
    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const long = "a long note that would run to several lines if it were drawn, " ** 6 ++ " https://example.com/tall.jpg";
    model.notes[0] = main.noteFrom(warnedEvent(0xC9, long, &tags), 1_800_000_100);
    model.notes_len = 1;

    const covered_price = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const p = try painted.Painted.render(arena, &model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    // The same standing slack every estimate here carries: characters against a
    // column width where the engine measures glyphs.
    if (@abs(rows[0].height - covered_price) > 1.5 * main.body_line_height) {
        std.debug.print("\ncovered row draws {d}, priced {d}\n", .{ rows[0].height, covered_price });
        return error.CoveredRowMispriced;
    }

    // And it is a real saving over the note it covers.
    main.setShowSensitive(true);
    defer main.setShowSensitive(false);
    const open_price = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    try testing.expect(open_price > covered_price + 3 * main.body_line_height);
}
test "settings offers the switch and says what it does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setShowSensitive(false);
    defer main.setShowSensitive(false);
    var model = main.initialModel();
    model.stage = .ready;
    model.stage = .settings;
    const tree = try buildTree(arena, &model);
    const switch_label = "Show sensitive notes without a warning";
    try testing.expect(findByLabel(tree.root, switch_label) != null);
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .sensitive_toggle, &fx);
    try testing.expect(main.showSensitive());
    main.update(&model, .sensitive_toggle, &fx);
    try testing.expect(!main.showSensitive());
}
test "the media proxy refuses what is not an address, and says why" {
    const before = try testing.allocator.dupe(u8, main.mediaProxy());
    defer testing.allocator.free(before);
    defer main.setMediaProxy(before);

    try testing.expect(!main.isMediaProxyUrl("not a url"));
    try testing.expect(!main.isMediaProxyUrl("wsrv.nl"));
    try testing.expect(!main.isMediaProxyUrl("ftp://wsrv.nl/"));
    try testing.expect(!main.isMediaProxyUrl("https://"));
    try testing.expect(!main.isMediaProxyUrl("https:///path"));
    try testing.expect(!main.isMediaProxyUrl("https://wsrv.nl/\x07"));
    try testing.expect(!main.isMediaProxyUrl("https://user@wsrv.nl/"));
    try testing.expect(main.isMediaProxyUrl("https://wsrv.nl/"));
    try testing.expect(main.isMediaProxyUrl("http://192.168.1.5:8080/img"));

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.setMediaProxy("https://wsrv.nl/");
    model.proxy_buffer.set("not a url");
    main.update(&model, .proxy_save, &fx);
    // Nothing was saved, the old proxy still answers, and the field says why.
    try testing.expect(!model.proxy_saved);
    try testing.expect(model.proxy_invalid);
    try testing.expectEqualStrings("https://wsrv.nl/", main.mediaProxy());
    try testing.expect(std.mem.indexOf(u8, model.proxy_status(), "Not saved") != null);
    try testing.expect(!std.mem.eql(u8, model.proxy_status(), "Saved."));

    // Typing again is the reader answering, so the complaint goes.
    model.proxy_buffer.set("https://proxy.example.org/");
    main.update(&model, .proxy_save, &fx);
    try testing.expect(model.proxy_saved and !model.proxy_invalid);
    try testing.expectEqualStrings("https://proxy.example.org/", main.mediaProxy());
    try testing.expectEqualStrings("Saved.", model.proxy_status());

    // Empty stays a choice: load originals.
    model.proxy_buffer.set("");
    main.update(&model, .proxy_save, &fx);
    try testing.expect(model.proxy_saved and !model.proxy_invalid);
    try testing.expectEqual(@as(usize, 0), main.mediaProxy().len);
}

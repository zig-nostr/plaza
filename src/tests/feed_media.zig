//! Tests of feed_media.zig. Pictures in the feed: slots, ranged fetches, GIFs, and proxy refusals.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig
const buildTree = harness.buildTree;
const countNoteRows = harness.countNoteRows;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const pressMsgByLabel = harness.pressMsgByLabel;
const quotePictureModel = harness.quotePictureModel;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

test "the feed builds only the rows the window asked for" {
    main.resetProfilesForTest();
    main.resetMediaForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{41} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note in a long feed");

    // A feed far longer than any viewport.
    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    for (0..200) |i| {
        model.notes[i] = main.noteFrom(ev, 1_800_000_000);
        // Distinct ids so the list can key its rows.
        model.notes[i].id = @intCast(i + 1);
    }
    model.notes_len = 200;

    const tree = try buildTree(arena, &model);

    // Windowed: the built rows are a small fraction of the 200 notes, which is
    // the whole point (the cost follows the viewport, not the feed length).
    const built = countNoteRows(tree.root);
    try testing.expect(built > 0);
    try testing.expect(built < 60);

    // And the range the view reported back is inside the feed.
    const visible = model.visibleRange();
    try testing.expect(visible.last < model.notes_len);
}

test "a picture reserves the same space loaded or not" {
    main.resetProfilesForTest();
    main.resetMediaForTest();
    defer main.resetMediaForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{21} ** 32);

    // A note whose imeta declares a tall picture: the height is known before a
    // single byte is downloaded, which is what stops the feed shifting.
    const url = "https://host.example/tall.jpg";
    const tags = [_]nostr.event.Tag{
        &.{ "imeta", "url " ++ url, "dim 400x800" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &tags, "look " ++ url, null);
    const note = main.noteFrom(ev, 1_800_000_000);

    try testing.expect(note.hasImage());
    // The box is the reading column, so a 2:1 picture would be twice that tall;
    // the aspect is capped instead, and the cap is what it draws at. Capping the
    // ASPECT rather than the pixels is what keeps the reservation exact: the
    // height is stated, not clamped after the fact.
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * 1.25, main.pictureHeight(&note), 0.5);
    // Nothing is loaded, yet the reserved height is already the final one.
    try testing.expectEqual(@as(u64, 0), note.media_id());

    // A landscape picture takes exactly the height its declared shape implies.
    const wide_url = "https://host.example/wide.jpg";
    const wide_tags = [_]nostr.event.Tag{&.{ "imeta", "url " ++ wide_url, "dim 1600x900" }};
    const wide_ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &wide_tags, "look " ++ wide_url, null);
    const wide = main.noteFrom(wide_ev, 1_800_000_000);
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * (900.0 / 1600.0), main.pictureHeight(&wide), 0.5);
}
test "a slot wanted on screen is never evicted for another visible picture" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();

    // Fill every slot and mark them all wanted at the current clock, which is
    // what the touch pass does for pictures on screen.
    const clock = main.touchMediaClockForTest();
    var fx: main.EffectsForTest = undefined;
    const cap = main.maxMediaImagesForTest();
    var i: i64 = 1;
    while (i <= @as(i64, @intCast(cap))) : (i += 1) {
        const slot = main.claimMediaSlotForTest(&fx, i) orelse return error.NoSlot;
        slot.last_used = clock;
    }
    // One more visible picture must get NOTHING rather than steal a wanted
    // slot: stealing is the thrash that decoded images every pass.
    try testing.expect(main.claimMediaSlotForTest(&fx, @intCast(cap + 1)) == null);
}
test "the rows just off screen are warmed, and the ones on it are left alone" {
    // Fetching was gated on holding one of the nine avatar ids or six picture
    // ids, and those are lent only to rows already on screen. So every row
    // arrived cold: blank, then a request, then a face a moment later, again and
    // again for as long as the reader kept scrolling.
    //
    // Nothing about downloading an image needs a registry slot. Only showing it
    // does. This pins the band that gets fetched anyway.
    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    model.notes_len = 200;
    for (0..200) |i| model.notes[i].id = @intCast(i + 1);

    main.setVisibleRangeForTest(80, 90);
    const seen = model.visibleRange();
    const warm = model.prefetchRange();
    try testing.expectEqual(@as(usize, 80), seen.first);
    try testing.expectEqual(@as(usize, 90), seen.last);
    // A band either side, because scrolling back up is as common as scrolling
    // down and a cache that only looks forward makes the way back feel broken.
    try testing.expect(warm.first < seen.first);
    try testing.expect(warm.last > seen.last);
    try testing.expectEqual(seen.first - main.feed_prefetch_rows_for_test, warm.first);
    try testing.expectEqual(seen.last + main.feed_prefetch_rows_for_test, warm.last);

    // At the top of the feed it does not run off the front, and at the bottom it
    // stops at the last row rather than warming notes that do not exist.
    main.setVisibleRangeForTest(0, 5);
    const top = model.prefetchRange();
    try testing.expectEqual(@as(usize, 0), top.first);
    main.setVisibleRangeForTest(195, 199);
    const bottom = model.prefetchRange();
    try testing.expectEqual(@as(usize, 199), bottom.last);
}
pub const quote_picture_url = "http://127.0.0.1:9/shot.png";
test "a quote card loads and draws the picture in the note it quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaPreviews(true);
    // The proxy off, so the address that goes out is the one in the note: this
    // test reaches a closed loopback port and nothing else.
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    const quoted_id = [_]u8{0x5e} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    const key = main.quoteMediaKeyForTest(quoted_id);

    // Nothing is held until a pass runs.
    try testing.expect(main.mediaSlotStateForTest(key) == null);

    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);

    // The card went through the feed's own pipeline: a media slot, a registry
    // id from the shared pool, and a fetch for the note's address.
    const held = main.mediaSlotStateForTest(key) orelse return error.NoSlotClaimed;
    try testing.expectEqualStrings("fetching", held.state);
    try testing.expect(held.image_id != 0);
    try testing.expectEqualStrings(quote_picture_url, held.url);
    try testing.expectEqualStrings("media", main.imageIdOwnerNameForTest(held.image_id));
    try testing.expectEqual(@as(?bool, true), main.mediaSlotWantedForTest(key));

    // While it loads the card shows the picture's own colours in the box it
    // will fill, not the chip that names it.
    const box = main.quotePictureBox(0.5);
    const priced_loading = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findAnyText(p.tree.root, "Picture from 127.0.0.1:9") == null);
        try testing.expect(p.frameOf("Picture in the quoted note") == null);
        const rows = p.framesOf("Open thread");
        if (rows.len < 1) return error.NoRow;
        try testing.expect(@abs(rows[0].height - priced_loading) <= 1.5 * main.body_line_height);
    }

    // Arrived: the picture, in the same box, so the row does not move.
    try testing.expect(main.markMediaLoadedForTest(&fx, key, 800, 400) != null);
    {
        const p = try painted.Painted.render(arena, &model);
        const frame = p.frameOf("Picture in the quoted note") orelse return error.PictureNotDrawn;
        try testing.expectApproxEqAbs(box.width, frame.width, 1.0);
        try testing.expectApproxEqAbs(box.height, frame.height, 1.0);
        const rows = p.framesOf("Open thread");
        if (rows.len < 1) return error.NoRow;
        const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
        try testing.expectApproxEqAbs(priced_loading, priced, 0.001);
        if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
            std.debug.print("\nrow with a quoted picture draws {d}, priced {d}\n", .{ rows[0].height, priced });
            return error.PictureNotPriced;
        }
    }
}

test "a quote card's picture follows the previews setting and what is on screen" {
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

    const quoted_id = [_]u8{0x5f} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    const key = main.quoteMediaKeyForTest(quoted_id);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();

    // Previews off: nothing leaves the machine and no id is spent. The card
    // names the picture and where it is from, as it did before, and the row is
    // priced for that chip rather than for a box that is not drawn.
    main.setMediaPreviews(false);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) == null);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findAnyText(p.tree.root, "Picture from 127.0.0.1:9") != null);
        try testing.expect(p.frameOf("Picture in the quoted note") == null);
        const rows = p.framesOf("Open thread");
        if (rows.len < 1) return error.NoRow;
        const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
        try testing.expect(@abs(rows[0].height - priced) <= 0.5 * main.body_line_height);
    }

    // Previews on, but the row is nowhere near the window: no fetch for a card
    // nobody is looking at.
    main.setMediaPreviews(true);
    var far = main.initialModel();
    far.stage = .ready;
    const far_row = main.maxMediaImagesForTest() + 3;
    for (0..far_row + 1) |i| {
        far.notes[i] = threadNote(@intCast(0x10 + i), 100, 0);
        far.notes[i].id = @intCast(100 + i);
    }
    far.notes[far_row].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    far.notes_len = far_row + 1;
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &far);
    try testing.expect(main.mediaSlotStateForTest(key) == null);

    // A quote still resolving has no address to load yet. (Every model shares
    // the one feed buffer, so the row is made again after the far one.)
    model = try quotePictureModel(quoted_id, 0.5);
    main.beginImagePassForTest();
    main.quoteForTest(quoted_id).?.state = .fetching;
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) == null);
    main.quoteForTest(quoted_id).?.state = .loaded;

    // On screen and loaded: the slot is claimed.
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    const held = main.mediaSlotStateForTest(key) orelse return error.NoSlotClaimed;
    try testing.expect(held.image_id != 0);
}
test "a quote card behind a note's fold costs nothing until it is unfolded" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaPreviews(true);
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    const quoted_id = [_]u8{0x63} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    // A long body with the card at its far end: a collapsed note draws only the
    // fold, so the card is not on screen.
    const note = &model.notes[0];
    @memset(note.content_buf[0..600], 'a');
    note.content_len = 600;
    note.quote = .{ .kind = .event, .id = quoted_id, .off = 580, .len = 0 };
    note.id = 8_001;
    const key = main.quoteMediaKeyForTest(quoted_id);

    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) == null);

    // Unfolded, the card is drawn and the picture is wanted.
    main.toggleExpandedForTest(note.id);
    defer main.toggleExpandedForTest(note.id);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) != null);
}

test "an earlier row cannot take the picture a quote card further down is showing" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaPreviews(true);
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    const quoted_id = [_]u8{0x64} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    const key = main.quoteMediaKeyForTest(quoted_id);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();

    // Every media slot is held: the quote's, loaded, and eleven others the
    // reader has scrolled past. The quote's is the oldest of the lot.
    const held_id = main.markMediaLoadedForTest(&fx, key, 800, 400) orelse return error.NoId;
    for (0..main.maxMediaImagesForTest() - 1) |i| _ = main.claimMediaSlotForTest(&fx, @intCast(1000 + i));
    main.beginImagePassForTest();
    main.beginImagePassForTest();

    // Now a row ABOVE the quote card wants a picture of its own. It is served
    // first, and the pool must take a slot from the ones scrolled past, not the
    // one the card below it is drawing in this very pass.
    model.notes[1] = model.notes[0];
    model.notes[0] = threadNote(0xA2, 100, 0);
    model.notes[0].id = 50;
    _ = model.notes[0].setImageForTest(0, "http://127.0.0.1:9/above.png");
    model.notes[1].id = 51;
    model.notes_len = 2;
    main.scanMediaFetchesForTest(&fx, &model);

    const kept = main.mediaSlotStateForTest(key) orelse return error.PictureTakenFromTheCard;
    try testing.expectEqualStrings("loaded", kept.state);
    try testing.expectEqual(held_id, kept.image_id);
    try testing.expect(main.mediaSlotStateForTest(50) != null);
}

test "a quote card gives its picture back when it scrolls away" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaPreviews(true);
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    const quoted_id = [_]u8{0x60} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    const key = main.quoteMediaKeyForTest(quoted_id);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();

    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    const id = (main.markMediaLoadedForTest(&fx, key, 800, 400)).?;

    // On screen this pass: the pool may not take it.
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(!main.imageIdTakeableForTest(id));

    // The next pass the row is gone: the pool may take it, exactly as it takes
    // a feed row's, and the id is not reserved for quote cards.
    main.beginImagePassForTest();
    model.notes_len = 0;
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.imageIdTakeableForTest(id));
    try testing.expectEqual(@as(?bool, false), main.mediaSlotWantedForTest(key));
}

test "a thread draws the picture of a quote in a reply on screen, and only those" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    const previews_were = main.mediaPreviews();
    const proxy_was = main.mediaProxyOn();
    main.setMediaPreviews(true);
    main.setMediaProxyOn(false);
    defer main.setMediaPreviews(previews_were);
    defer main.setMediaProxyOn(proxy_was);

    const on_screen = [_]u8{0x61} ** 32;
    const below = [_]u8{0x62} ** 32;
    defer main.dropQuoteForTest(on_screen);
    defer main.dropQuoteForTest(below);
    _ = try quotePictureModel(on_screen, 0.5);
    _ = try quotePictureModel(below, 0.5);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;
    for (0..2) |i| {
        model.thread_notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i].id = @intCast(900 + i);
        model.thread_notes[i].pubkey = [_]u8{0x55} ** 32;
        model.thread_notes[i].event_id = [_]u8{@intCast(i + 1)} ** 32;
        model.thread_notes[i].quote = .{ .kind = .event, .id = if (i == 0) on_screen else below, .off = 0, .len = 0 };
    }
    model.thread_notes_len = 2;

    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();
    main.recordVisibleNotesForTest(&[_]i64{900});
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(main.quoteMediaKeyForTest(on_screen)) != null);
    try testing.expect(main.mediaSlotStateForTest(main.quoteMediaKeyForTest(below)) == null);
}
test "picture slots follow the reader down a long thread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same fault as the faces, and the one that shows: a level marked EVERY
    // picture it held as wanted, and the claim pass refuses to evict anything
    // wanted, so the first six took the six slots and every other picture in the
    // thread stayed an empty box for as long as the thread was open.
    //
    // What decides that is which ids the pass marks. A picture still marked is
    // one the allocator may not reclaim; a picture no longer marked is one the
    // rows now on screen can take. So that is what this asks about.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    // Previews OFF, so the pass marks and claims without reaching the network:
    // a test cannot construct a usable effect table, and `fireMedia` returns
    // before it needs one.
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(false);
    defer main.setMediaPreviews(previews_were);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;

    const count = 30;
    for (0..count) |i| {
        model.thread_notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i].id = @intCast(900 + i);
        model.thread_notes[i].pubkey = [_]u8{0x55} ** 32;
        model.thread_notes[i].event_id = [_]u8{@intCast(i + 1)} ** 32;
        const url = "https://example.com/a.jpg";
        _ = model.thread_notes[i].setImageForTest(0, url);
    }
    model.thread_notes_len = count;
    _ = try painted.Painted.render(arena, &model);

    var fx: main.EffectsForTest = undefined;

    // Give the notes at the TOP of the thread the slots, as a reader arriving
    // there would.
    const top = [_]i64{ 900, 901, 902 };
    for (top) |id| _ = main.claimMediaSlotForTest(&fx, id);
    for (top) |id| try testing.expect(main.mediaSlotWantedForTest(id) != null);

    // Now the reader is at the BOTTOM. The pass runs over what is on screen.
    const bottom = [_]i64{ 925, 926, 927 };
    main.recordVisibleNotesForTest(&bottom);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);

    // The pictures that scrolled away are no longer claimed as wanted, which is
    // exactly what lets the ones now on screen be lent a slot. Before this fix
    // every picture in the thread was marked on every pass and none of them
    // could ever be reclaimed.
    for (top) |id| {
        const wanted = main.mediaSlotWantedForTest(id) orelse continue;
        if (wanted) {
            std.debug.print("picture {d} scrolled away and is still holding its slot\n", .{id});
            return error.PicturesStuckAtTheTop;
        }
    }
}
test "a picture that will not load says so instead of waiting forever" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The view asked only whether the picture was LOADED, so every state that is
    // not loaded drew the same striped waiting frame. A 404 waits in it forever.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 4242;
    model.notes[0].pubkey = [_]u8{0x2b} ** 32;
    const url = "https://haven.example.com/gone.jpg";
    _ = model.notes[0].setImageForTest(0, url);
    model.notes_len = 1;

    // Still coming: no failure said, because none has happened.
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findAnyText(p.tree.root, "This picture would not load") == null);
    }

    // The host answered 404.
    var fx: main.EffectsForTest = undefined;
    const slot = main.claimMediaSlotForTest(&fx, 4242) orelse return error.NoSlot;
    main.markMediaFailedForTest(slot);
    try testing.expect(main.mediaFailed(4242));

    const p = try painted.Painted.render(arena, &model);
    if (findAnyText(p.tree.root, "This picture would not load") == null) {
        std.debug.print("a picture that answered 404 is still drawn as loading\n", .{});
        return error.StillWaiting;
    }
    // And it names where it was, and offers the one thing that might still work.
    try testing.expect(findAnyTextContainingText(p.tree.root, "haven.example.com") != null);
    const msg = pressMsgByLabel(p.tree, "This picture could not be loaded, press to open the original") orelse
        return error.NoWayToOpenIt;
    switch (msg) {
        .open_url => {},
        else => return error.WrongMessage,
    }
}
test "a host having a moment is not the same as a host saying no" {
    // A 404 is an answer and the box says so. A timeout, a rate limit or a 5xx
    // is the network having a moment, and marking a good picture permanently
    // broken over one of those is the quote fetch's old mistake in a place the
    // reader can see.
    for ([_]u16{ 404, 410, 403, 400 }) |final| {
        try testing.expectEqual(main.ImageFailure.give_up, main.classifyImageFailure(.ok, final));
    }
    for ([_]u16{ 408, 429, 500, 502, 503 }) |transient| {
        try testing.expectEqual(main.ImageFailure.retry, main.classifyImageFailure(.ok, transient));
    }
    // No answer at all is the network, whatever status field came with it.
    for ([_]native_sdk.EffectFetchOutcome{ .connect_failed, .tls_failed, .protocol_failed, .timed_out }) |outcome| {
        try testing.expectEqual(main.ImageFailure.retry, main.classifyImageFailure(outcome, 0));
    }
}

test "a picture too big to decode is not downloaded again forever" {
    // This is the one the status code cannot answer. An oversized or truncated
    // body comes back 200: the host did nothing wrong and will send exactly the
    // same bytes next time. Reading only the status put the slot back to idle,
    // and the scan that refills idle slots runs on the one-second tick AND on
    // every scroll event, so one picture too large for the decoder was
    // re-downloaded for as long as the reader looked at it.
    try testing.expectEqual(main.ImageFailure.give_up, main.classifyImageFailure(.ok, 200));

    // Driven through the real handler, because the classification is only half
    // of it: the slot has to end up somewhere the refill scan will not pick up.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_001;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    // A 200 carrying more than the decoder will take.
    const too_big = try arena.alloc(u8, 250_000);
    @memset(too_big, 0);
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 200, too_big);
    if (!main.mediaFailed(note_id)) {
        std.debug.print("an oversized picture went back to idle, so it will be fetched again\n", .{});
        return error.WouldRefetchForever;
    }
}

test "a picture the network lost is retried, but not without end" {
    // The mirror of the case above, and the one the avatar path used to get
    // wrong in the other direction: a 503 is the host having a moment, so the
    // picture is worth asking for again. Bounded, so that no future mistake in
    // the classification can turn "worth asking again" into a download loop.
    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_002;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    main.deliverMediaResponseForTest(&fx, note_id, .ok, 503, "");
    try testing.expect(main.mediaIdleForTest(note_id));
    try testing.expectEqual(@as(u8, 1), main.mediaAttemptsForTest(note_id).?);

    main.deliverMediaResponseForTest(&fx, note_id, .connect_failed, 0, "");
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 429, "");
    try testing.expect(main.mediaIdleForTest(note_id));

    // The fourth is where it stops.
    main.deliverMediaResponseForTest(&fx, note_id, .timed_out, 0, "");
    try testing.expect(main.mediaFailed(note_id));
}

test "a picture the proxy refuses by host is asked of the host itself" {
    // The avatar path has had this since the day it shipped and the PICTURE
    // path has only ever had the predicate tested, never the wiring. Same
    // refusal, same host, and a photograph is the half a reader actually
    // notices: wsrv.nl answers 400 for a `.pub` domain, which is where Ditto's
    // Blossom server lives, and the same file comes back fine from the host.
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
    }
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_010;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    main.deliverMediaResponseForTest(&fx, note_id, .ok, 400, "");
    const after = main.mediaFallbackStateForTest(note_id).?;
    try testing.expect(after.direct);
    try testing.expect(after.idle);
    // Not a failed attempt: this is a different question, not another go at
    // the same one.
    try testing.expectEqual(@as(u8, 0), main.mediaAttemptsForTest(note_id).?);

    // Once. A refusal from the HOST is a real failure with nowhere left to
    // ask, so it must not loop.
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 400, "");
    try testing.expect(!main.mediaFallbackStateForTest(note_id).?.idle);
}

test "a refused host is remembered past the slot that discovered it" {
    // The bug a reader saw as "pictures on that host still do not load, even
    // though faces on it do".
    //
    // The refusal was remembered on the media SLOT. The fallback sets the slot
    // idle so it will be asked again, and an idle slot is exactly what
    // `claimMediaSlot` evicts, so the flag went out with it: scroll the picture
    // off screen and back and it asked the proxy again, was refused again, and
    // was evicted again. It could loop forever without ever once reaching the
    // host that would have served it.
    //
    // A face never had this problem, because its flag lives on the profile,
    // which is keyed by pubkey and outlives any amount of scrolling. That is
    // the whole of why one came back and the other did not.
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
        main.forgetProxyRefusals();
    }
    main.forgetProxyRefusals();
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    const src = "https://blossom.ditto.pub/deadbeef.jpg";
    var buf: [1024]u8 = undefined;

    // Before anything is known, the picture goes through the proxy. A test
    // process never loads the settings file, so the proxy is set here.
    main.setMediaProxy("https://wsrv.nl/");
    main.forgetProxyRefusals();
    try testing.expect(!std.mem.eql(u8, main.feedImageUrlForTest(&buf, src), src));

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_020;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;
    main.setMediaSlotHostForTest(note_id, "blossom.ditto.pub");
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 400, "");
    try testing.expect(main.mediaFallbackStateForTest(note_id).?.direct);

    // The refusal now outlives the slot. This is the assertion the old code
    // could not make: it is about the HOST, not about one picture.
    try testing.expect(main.proxyRefusesHost(src));
    try testing.expectEqualStrings(src, main.feedImageUrlForTest(&buf, src));

    // Including a DIFFERENT picture on the same host, which never has to spend
    // the round trip that discovers the refusal.
    try testing.expectEqualStrings(
        "https://blossom.ditto.pub/other.png",
        main.feedImageUrlForTest(&buf, "https://blossom.ditto.pub/other.png"),
    );

    // And not a picture somewhere else.
    const elsewhere = "https://i.nostr.build/abc.jpg";
    try testing.expect(!main.proxyRefusesHost(elsewhere));

    // A different proxy answers for itself rather than inheriting this one's
    // policy.
    main.setMediaProxy("https://images.example.test/");
    try testing.expect(!main.proxyRefusesHost(src));
}

test "a host is read out of a URL the way the refusal is filed" {
    try testing.expectEqualStrings("blossom.ditto.pub", main.hostOfForTest("https://blossom.ditto.pub/a.jpg"));
    // A port is not part of what the proxy refused.
    try testing.expectEqualStrings("example.test", main.hostOfForTest("https://example.test:8443/a.jpg"));
    // Userinfo is not the host, and taking it as one would file the refusal
    // under a string an author chose.
    try testing.expectEqualStrings("example.test", main.hostOfForTest("https://user@example.test/a.jpg"));
    try testing.expectEqualStrings("example.test", main.hostOfForTest("https://example.test"));
    try testing.expectEqualStrings("", main.hostOfForTest("not a url"));
}
test "the proxy is only bypassed when it refused the host, not the picture" {
    // 400 with "Domain or TLD blocked by policy" is what wsrv.nl answers for a
    // Blossom host that serves the same file directly. 403 and 451 are the same
    // refusal by other names.
    try testing.expect(main.proxyRefusedHost(.ok, 400));
    try testing.expect(main.proxyRefusedHost(.ok, 403));
    try testing.expect(main.proxyRefusedHost(.ok, 451));

    // NOT a 404: the source is missing and will be missing directly too, so a
    // fallback is a second download with a known answer.
    try testing.expect(!main.proxyRefusedHost(.ok, 404));

    // NOT a 200 that produced no usable image. That is our own size limit, and
    // going direct only makes it worse, because the proxy was the thing
    // shrinking the picture. Two existing tests caught this when the fallback
    // fired on every failure.
    try testing.expect(!main.proxyRefusedHost(.ok, 200));

    // And nothing that never reached a host: a retry, not a refusal.
    try testing.expect(!main.proxyRefusedHost(.ok, 500));
    try testing.expect(!main.proxyRefusedHost(.ok, 429));
}
test "each picture of a note gets its own media slot" {
    // They shared one key before, so a gallery's cells fought over a single slot
    // and only ever one of them could be loaded.
    const note_id: i64 = 0x0123_4567;
    const first = main.mediaKeyForTest(note_id, 0);
    try testing.expectEqual(note_id, first);

    var seen: [main.max_note_images]i64 = undefined;
    for (0..main.max_note_images) |i| {
        seen[i] = main.mediaKeyForTest(note_id, i);
        try testing.expect(seen[i] >= 0);
        for (seen[0..i]) |earlier| try testing.expect(earlier != seen[i]);
    }
}
test "a picture bigger than one response body is assembled from its slices" {
    // The bug this exists for: every photo in a Nostr feed is 300 KB to 2 MB,
    // and one response body carries at most 240 KiB, so before this the whole
    // class of pictures simply never appeared.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 78_001;
    main.resetMediaForTest();
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    const slice = main.maxImageBytesForTest();
    const first = try arena.alloc(u8, slice);
    @memset(first, 0xAA);
    const second = try arena.alloc(u8, slice);
    @memset(second, 0xBB);
    const last = try arena.alloc(u8, 131_761); // short: the host had no more
    @memset(last, 0xCC);

    // A full slice always means "ask again": the host gave exactly what was
    // asked for, so there is no way to tell from the length alone that the
    // picture ended there.
    try testing.expectEqual(main.SliceOutcome.want_more, main.appendMediaSliceForTest(note_id, first).?);
    try testing.expectEqual(main.SliceOutcome.want_more, main.appendMediaSliceForTest(note_id, second).?);
    try testing.expectEqual(main.SliceOutcome.complete, main.appendMediaSliceForTest(note_id, last).?);

    // Byte-identical, in order. A gap or an overlap between slices would still
    // decode into a picture, just the wrong one, so length alone is not enough.
    const whole = main.mediaPartialForTest(note_id) orelse return error.NothingAssembled;
    try testing.expectEqual(slice * 2 + last.len, whole.len);
    try testing.expect(std.mem.allEqual(u8, whole[0..slice], 0xAA));
    try testing.expect(std.mem.allEqual(u8, whole[slice .. slice * 2], 0xBB));
    try testing.expect(std.mem.allEqual(u8, whole[slice * 2 ..], 0xCC));
    main.resetMediaForTest();
}

test "a picture that fits in one slice is whole without allocating anything" {
    // The common case, and the one that must not get slower: a thumbnail comes
    // back short on the first answer and decodes straight from the response.
    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 78_002;
    main.resetMediaForTest();
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    try testing.expectEqual(main.SliceOutcome.complete, main.appendMediaSliceForTest(note_id, "small").?);
    try testing.expect(main.mediaPartialForTest(note_id) == null);
    main.resetMediaForTest();
}

test "the ranges asked for tile the file, with no gap and no overlap" {
    var buf: [64]u8 = undefined;
    const slice = main.maxImageBytesForTest();
    try testing.expectEqualStrings("bytes=0-245759", main.rangeHeaderForTest(&buf, 0).?);
    // The second request starts at the byte after the first window's last, which
    // is exactly the length assembled so far.
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("bytes=245760-491519", main.rangeHeaderForTest(&buf2, slice).?);
}

test "a picture past the ceiling is refused rather than assembled forever" {
    // The bytes are a stranger's, held whole in memory before they decode, so
    // something has to say when to stop. A host that answers a full slice every
    // time would otherwise be a download with no end.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 78_003;
    main.resetMediaForTest();
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    const slice = main.maxImageBytesForTest();
    const full = try arena.alloc(u8, slice);
    @memset(full, 0xDD);

    var sent: usize = 0;
    while (sent < main.maxImageDownloadBytesForTest()) : (sent += slice) {
        if (main.appendMediaSliceForTest(note_id, full)) |outcome| {
            try testing.expectEqual(main.SliceOutcome.want_more, outcome);
        } else {
            main.resetMediaForTest();
            return; // refused, which is the point
        }
    }
    std.debug.print("assembled past the ceiling without refusing\n", .{});
    return error.NoCeiling;
}

test "a slice buffer never outlives the fetch that was filling it" {
    // A half-assembled picture is bytes nobody will decode. Every way a fetch
    // can end has to drop it, or a feed of failing hosts leaks megabytes.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 78_004;
    main.resetMediaForTest();
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    const full = try arena.alloc(u8, main.maxImageBytesForTest());
    @memset(full, 0xEE);
    _ = main.appendMediaSliceForTest(note_id, full);
    try testing.expect(main.mediaPartialForTest(note_id) != null);

    // The host stops answering partway through.
    main.deliverMediaResponseForTest(&fx, note_id, .timed_out, 0, "");
    try testing.expect(main.mediaPartialForTest(note_id) == null);
    main.resetMediaForTest();
}

test "a screen of picture-heavy notes gets more slots than the old fixed share" {
    // The reported bug, as a number. Two notes, four pictures and three, is what
    // a Nostr feed actually looks like, and the reserved share of six meant the
    // seventh cell could never hold a picture however idle the rest of the
    // registry was. Seven has to be reachable now.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var fx: main.EffectsForTest = undefined;
    main.beginImagePassForTest();

    var lent: usize = 0;
    var seen = [_]bool{false} ** (main.image_registry_slots + 1);
    for (0..7) |i| {
        const slot = main.claimMediaSlotForTest(&fx, @intCast(80_100 + i)) orelse continue;
        const id = main.acquireImageIdForTest(&fx) orelse continue;
        slot.image_id = id;
        slot.last_used = main.imageClockForTest();
        // Never the same id twice: two pictures sharing one would draw the same
        // pixels, which is worse than one of them missing.
        if (seen[@intCast(id)]) {
            std.debug.print("registry id {d} lent twice\n", .{id});
            return error.DuplicateImageId;
        }
        seen[@intCast(id)] = true;
        lent += 1;
    }
    if (lent < 7) {
        std.debug.print("only {d} of 7 pictures on screen could hold pixels\n", .{lent});
        return error.StillCappedAtTheOldShare;
    }
}

test "a covered note does not fetch the picture of the note it quotes" {
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

    // The quoted note carries no warning. The note quoting it does, so the row
    // draws its cover and no card, and the quoted picture is not on screen.
    const quoted_id = [_]u8{0x60} ** 32;
    defer main.dropQuoteForTest(quoted_id);
    var model = try quotePictureModel(quoted_id, 0.5);
    model.notes[0].warned = true;
    const key = main.quoteMediaKeyForTest(quoted_id);
    var fx = main.EffectsForTest.init(testing.allocator);
    defer fx.deinit();

    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    try testing.expect(main.mediaSlotStateForTest(key) == null);

    // Shown: the card is drawn, and its picture is claimed like any other.
    main.setShowSensitive(true);
    main.beginImagePassForTest();
    main.scanMediaFetchesForTest(&fx, &model);
    const held = main.mediaSlotStateForTest(key) orelse return error.NoSlotClaimed;
    try testing.expect(held.image_id != 0);
}

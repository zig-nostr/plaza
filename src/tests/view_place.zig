//! Tests of view_place.zig. A place's header, home, info card, logo, and the scope bar.

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

test "a short welcome does not reserve a tall empty card" {
    // The card used to reserve a fixed 380 points whatever the host wrote, so a
    // two-line welcome sat above three hundred points of nothing with the Close
    // button stranded at the bottom of an empty box.
    const short = "## Welcome!\n\nTwo lines, that is all.";
    const tall = main.placeHomeHeightForTest(short);
    try testing.expect(tall > 0);
    try testing.expect(tall < 140);

    // And a long one is still capped, so a host cannot push the buttons off the
    // screen with an essay.
    var long_buf: [2000]u8 = undefined;
    @memset(&long_buf, 'x');
    try testing.expectEqual(@as(f32, 380), main.placeHomeHeightForTest(&long_buf));
}

test "measuring a markdown line counts what is drawn, not what is written" {
    // This is what made the first estimate useless. One paragraph of the Monero
    // welcome carries a link whose address is two hundred characters that are
    // never drawn, so the line measured four times longer than it reads.
    const link = "See [the client](/nevent1qvzqqqqqqypzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053va) here";
    try testing.expectEqual(@as(usize, "See the client here".len), main.visibleLenForTest(link));

    // Heading markers are syntax, not text.
    try testing.expectEqual(@as(usize, "Welcome!".len), main.visibleLenForTest("## Welcome!"));
    // Plain text is itself.
    try testing.expectEqual(@as(usize, 5), main.visibleLenForTest("hello"));
}

test "walking into a room with no logo does not leave the last room's mark behind" {
    // Reported: entered Monero Hallway, then opened the BASSPISTOL link, and
    // Monero's logo was sitting on BASSPISTOL's Info card.
    //
    // The identity check sat BELOW the "this place ships no logo" early return,
    // so a room with nothing of its own never reached the line that drops the
    // last room's mark. Walking OUT to your own feed cleared it, which is why
    // only room-to-room could show it.
    var fx = main.inertEffectsForTest();
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    defer main.setPlaceLogoIdForTest(0);

    // A slot nothing else in this process holds: these tests share the pool.
    var slot: u64 = 0;
    var i: u64 = 1;
    while (i <= 16) : (i += 1) {
        if (std.mem.eql(u8, main.imageIdOwnerNameForTest(i), "free")) {
            slot = i;
            break;
        }
    }
    if (slot == 0) return error.NoFreeSlot;

    // Standing in a room whose mark is loaded and on screen.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa1} ** 32, "moneroh");
    try testing.expect(main.placeLogoShownForTest());

    // Straight into a different room, one that ships no logo at all.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());

    // And one host running two rooms: the host alone is not a place, so the
    // second room does not inherit the first one's mark either.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa3} ** 32, "room-one");
    try testing.expect(main.placeLogoShownForTest());
    main.visitPlaceForTest([_]u8{0xa3} ** 32, "room-two", "Second Room");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());
}

test "an image with no alt text leaves nothing behind" {
    // The renderer draws an image as its ALT text, which is right for a client
    // that spends its image budget on faces. `![](url)` has no alt, so the
    // renderer does not take it as an image at all and the reader gets a
    // literal `![]` and the raw URL as a link. Seen in fiatjaf's Monero
    // welcome, which is written exactly that way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const src =
        "Welcome!\n\n![](https://example.test/sticker.png)\n\nRead on.";
    const out = main.stripEmptyImagesForTest(arena_state.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, out, "![]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.test") == null);
    // And the host's actual words are untouched.
    try testing.expect(std.mem.indexOf(u8, out, "Welcome!") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read on.") != null);

    // An image that DOES name itself is left alone: the renderer draws that alt
    // text, which is the whole point of the format.
    const kept = "see ![a sticker](https://example.test/s.png) here";
    try testing.expectEqualStrings(kept, main.stripEmptyImagesForTest(arena_state.allocator(), kept));

    // And syntax that is not an image is not touched either.
    const unclosed = "![](broken";
    try testing.expectEqualStrings(unclosed, main.stripEmptyImagesForTest(arena_state.allocator(), unclosed));
}
test "a logo body that arrives after you walk out is not painted on the new room" {
    // The fetch is keyed by a constant, so the answer carries no clue which room
    // asked. Taking `activePlace()` at delivery meant a body fetched for room A
    // and landing after a walk into room B was decoded into B's slot AND cached
    // under B's logo URL, so the wrong mark came back on every later visit and
    // every later launch. `handleBannerFetched` has carried this guard for
    // faces all along.
    var fx = main.inertEffectsForTest();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // Asked for by Monero, delivered while standing in BASSPISTOL.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.setPlaceLogoAskedForTest([_]u8{0xa1} ** 32, "moneroh");
    main.deliverPlaceLogoBodyForTest(&fx, "a body that is not this room's");

    // Dropped, and left idle so this room's own mark is still asked for. Not
    // `failed`: nothing about THIS room's logo has been tried yet.
    try testing.expectEqualStrings("idle", main.placeLogoStateNameForTest());
    try testing.expect(!main.placeLogoShownForTest());
}

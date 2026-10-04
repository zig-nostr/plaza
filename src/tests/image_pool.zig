//! Tests of image_pool.zig. The app's image registry slots, prewarming, and avatar fetches.

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

test "the place's logo is not a slot the pool can hand to a face" {
    // Reported: the logo appeared, then turned into somebody's avatar as the
    // feed loaded behind it. Image ids come from a shared pool, and a slot this
    // app holds but the pool does not KNOW about reads as free, so the next face
    // to arrive was handed the id the Info card was drawing.
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

    main.setPlaceLogoIdForTest(slot);
    defer main.setPlaceLogoIdForTest(0);

    // The pool has to name it. "free" here is the whole bug: a slot this app
    // holds and the pool calls free is one it will hand to the next face.
    try testing.expectEqualStrings("place_logo", main.imageIdOwnerNameForTest(slot));

    // On screen this pass: untouchable, like a banner or a face being looked at.
    main.markPlaceLogoSeenForTest();
    try testing.expect(main.placeLogoUntouchableForTest());

    // A later pass with the place gone: the slot goes back rather than being
    // held forever.
    main.agePlaceLogoForTest();
    try testing.expect(!main.placeLogoUntouchableForTest());
}
test "a face and a picture draw from the same pool, oldest off screen first" {
    // The point of one allocator. A profile page wants a banner and many faces
    // and no pictures; a feed of photo notes wants the opposite. Under reserved
    // shares each screen left the other kind's capacity idle, so what decides is
    // time off screen, not what kind of image it is.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    // Every id held by a face that is on screen right now.
    main.beginImagePassForTest();
    for (0..main.image_registry_slots) |i| {
        const pk = [_]u8{@intCast(i + 1)} ** 32;
        main.setProfileAvatarForTest(pk, @intCast(i + 1), .loaded);
        main.markAvatarWantedForTest(pk);
    }

    // Nothing may be taken while every holder is visible: the caller shows
    // initials this frame rather than evicting something the reader can see.
    if (main.chooseImageIdForTest()) |id| {
        std.debug.print("id {d} was offered while its holder was on screen\n", .{id});
        return error.WouldEvictSomethingVisible;
    }

    // Now give them DIFFERENT ages: each pass marks one more face, so the one
    // marked earliest and never again has been off screen longest.
    for (0..main.image_registry_slots) |i| {
        main.beginImagePassForTest();
        // Everyone from `i` onward is still being read; everyone before has
        // scrolled away, and how long ago is what separates them.
        for (i..main.image_registry_slots) |j| {
            main.markAvatarWantedForTest([_]u8{@intCast(j + 1)} ** 32);
        }
    }

    // The reader scrolls to a note with pictures. The oldest face is the one a
    // picture gets: which one is decided by time off screen, not by kind.
    main.beginImagePassForTest();
    const offered = main.chooseImageIdForTest() orelse return error.NoSlotForPicture;
    if (offered != 1) {
        std.debug.print("offered id {d}, but id 1 has been off screen longest\n", .{offered});
        return error.TookTheWrongOne;
    }

    // And the face the reader IS looking at is never the one taken.
    main.beginImagePassForTest();
    main.markAvatarWantedForTest([_]u8{1} ** 32);
    const next = main.chooseImageIdForTest() orelse return error.NoSlotForPicture;
    if (next == 1) {
        std.debug.print("took the face that is on screen instead of one that is not\n", .{});
        return error.EvictedTheVisibleFace;
    }
}

//! Tests of view_compose.zig. The compose sheet and the mention picker.

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

test "the picker knows when a mention is being typed" {
    // The last `@word` is the one being written; an `@name` earlier in the note
    // is already said, and an `@` inside a word is an address, not a mention.
    try testing.expectEqualStrings("wir", main.mentionQuery("hello @wir").?);
    try testing.expectEqualStrings("", main.mentionQuery("hello @").?);
    // Finished: a space means the reader has moved on.
    try testing.expect(main.mentionQuery("hello @wirth and then") == null);
    // Mid-word, so not a mention being composed.
    try testing.expect(main.mentionQuery("mail me at me@example.com") == null);
    try testing.expect(main.mentionQuery("nothing here") == null);
    // The LAST run wins, not the first.
    try testing.expectEqualStrings("ed", main.mentionQuery("@wirth said @ed").?);
}
test "an insert that will not fit is refused, not truncated" {
    // The draft buffer truncates in silence, and half a bech32 reference is one
    // no client can resolve, published without a word of warning.
    var model = main.initialModel();
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    long[499] = '@';
    model.draft_buffer = @TypeOf(model.draft_buffer).init(&long);
    const before = model.draft();

    main.insertMentionForTest(&model, [_]u8{0x7a} ** 32);
    // Unchanged: it did not fit, so it did not happen.
    try testing.expectEqualStrings(before, model.draft());

    // With room, it lands whole and ends in a resolvable reference.
    model.draft_buffer = @TypeOf(model.draft_buffer).init("thanks @gi");
    main.insertMentionForTest(&model, [_]u8{0x7a} ** 32);
    try testing.expect(std.mem.indexOf(u8, model.draft(), "nostr:npub1") != null);
    try testing.expect(model.draft().len > 60);
}

//! Tests of drafts.zig. Drafts: the note being written, kept across a restart, and the replies parked per thread.

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

test "a draft saved to disk keeps its content warning, and loses it with the draft" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var model = main.initialModel();
    model.draft_buffer.set("half a thought");
    model.warn_on = true;
    model.warn_buffer.set("politics");
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));

    // A fresh launch: the composer and the warning come back together.
    var next = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &next);
    try testing.expectEqualStrings("half a thought", next.draft());
    try testing.expect(next.warn_on);
    try testing.expectEqualStrings("politics", next.warn_draft());

    // A warning with no reason is still a warning.
    model.warn_buffer.clear();
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    var bare = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &bare);
    try testing.expect(bare.warn_on);
    try testing.expectEqual(@as(usize, 0), bare.warn_draft().len);

    // The warning switched off removes the file, so it cannot come back over a
    // draft that no longer wants it.
    model.warn_on = false;
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    var plain = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &plain);
    try testing.expectEqualStrings("half a thought", plain.draft());
    try testing.expect(!plain.warn_on);

    // And deleting the draft deletes the warning with it.
    model.warn_on = true;
    model.warn_buffer.set("politics");
    main.writeDraftForTest(io, &tmp.dir, model.draft(), main.draftWarningForModelForTest(&model));
    main.writeDraftForTest(io, &tmp.dir, "", null);
    var gone = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &gone);
    try testing.expect(gone.draft_empty());
    try testing.expect(!gone.warn_on);
    main.writeDraftForTest(io, &tmp.dir, "a new draft", null);
    var fresh = main.initialModel();
    main.loadDraftIntoForTest(io, &tmp.dir, &fresh);
    try testing.expect(!fresh.warn_on);
}

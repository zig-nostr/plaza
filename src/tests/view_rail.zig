//! Tests of view_rail.zig. The primary rail and the places rail.

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

test "the window is square where the reading happens" {
    // A feed is a column of rows. The wide-and-short default spent its extra
    // width on margin while showing four notes at a time.
    //
    // The square is the READING AREA, not the window. It was the same thing
    // until the second rail existed; now the window carries 238pt of chrome
    // down its left side, and asserting the window itself would either shrink
    // the room by that much or quietly stop meaning anything.
    try testing.expectEqual(main.window_width - main.rails_width, main.window_height);
}

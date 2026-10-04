//! Tests of view_media.zig. Pictures, galleries, blurhash placeholders, and link and video cards.

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
const threadNote = harness.threadNote;

test "a blurhash decodes to the picture's own colours" {
    // The reference hash from the format's own README, which encodes a warm
    // photograph. Decoding is what lets a picture that has not arrived show its
    // palette instead of a grey box.
    const blur = main.decodeBlurhash("LEHV6nWB2yk8pyo0adR*.7kCMdnj");
    try testing.expect(blur.ok);
    // Every cell is opaque and inside the gamut.
    for (blur.cells) |c| {
        try testing.expect(c.a > 0.99);
        try testing.expect(c.r >= 0 and c.r <= 1);
    }
    // The corners differ: a hash that decoded to one flat colour would be a
    // decoder that dropped its AC components.
    const first = blur.cells[0];
    const last = blur.cells[blur.cells.len - 1];
    try testing.expect(@abs(first.r - last.r) + @abs(first.g - last.g) + @abs(first.b - last.b) > 0.02);

    // Rubbish in, nothing out: a malformed hash draws stripes, never a guess.
    try testing.expect(!main.decodeBlurhash("").ok);
    try testing.expect(!main.decodeBlurhash("not a hash").ok);
    try testing.expect(!main.decodeBlurhash("LEHV6nWB2yk8pyo0adR*.7kCMdn").ok);
}

test "a picture with a blurhash shows its colours before its bytes" {
    // The placeholder is flat cells, not an image: all sixteen image slots are
    // spent on faces and photographs, and a placeholder must never evict the
    // thing it stands in for.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const url = "https://host.example/a.jpg";
    const img = model.notes[0].setImageForTest(0, url);
    img.aspect = 0.5;
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    @memcpy(img.blur_buf[0..hash.len], hash);
    img.blur_len = @intCast(hash.len);
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    const box = p.frameOf("Attached image, press to enlarge") orelse return error.NoBox;
    // The box paints a colour from the hash, not the striped fallback.
    const blur = main.decodeBlurhash(hash);
    const sample = p.fillAt(box.x + box.width / 2, box.y + box.height / 2) orelse return error.NothingPainted;
    var matched = false;
    for (blur.cells) |c| {
        if (@abs(c.r - sample.r) < 0.01 and @abs(c.g - sample.g) < 0.01 and @abs(c.b - sample.b) < 0.01) matched = true;
    }
    if (!matched) {
        std.debug.print("\npainted {any}, not a blurhash cell\n", .{sample});
        return error.NotTheBlurhash;
    }
}

test "the pressable box is the picture, not the space around it" {
    // A portrait taller than the aspect cap is drawn contained at the reserved
    // height. If the box stayed column-wide, the bare window either side of it
    // would be inside the border and pressable, and pressing it would open the
    // viewer for a picture the reader was not pointing at.
    var note = threadNote(0xA1, 100, 0);
    const url = "https://host.example/tall.jpg";
    const img = note.setImageForTest(0, url);
    img.aspect = 2.0;

    const height = main.pictureHeight(&note);
    const width = main.pictureWidth(&note);
    // Reserved at the cap, drawn at its own shape.
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * 1.25, height, 0.5);
    try testing.expectApproxEqAbs(height / 2.0, width, 0.5);

    // A landscape picture fills the column.
    img.aspect = 0.5625;
    try testing.expectApproxEqAbs(main.picture_column_width_for_test, main.pictureWidth(&note), 0.5);
}

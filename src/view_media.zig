//! Pictures, galleries, blurhash placeholders, and link and video cards.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const prefs = @import("prefs.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Msg = main.Msg;
const Note = main.Note;
const byteSize = main.byteSize;
const cover_notice_height = main.cover_notice_height;
const elide = main.elide;
const hgap = main.hgap;
const isMediaAsked = main.isMediaAsked;
const linkFor = main.linkFor;
const max_note_images = main.max_note_images;
const mediaFailed = main.mediaFailed;
const mediaKey = main.mediaKey;
const meta_scale = main.meta_scale;
const mono_chip_scale = main.mono_chip_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const picture_ask_height = main.picture_ask_height;
const picture_chip_height = main.picture_chip_height;
const picture_chip_inset = main.picture_chip_inset;
const picture_column_width = main.picture_column_width;
const picture_default_aspect = main.picture_default_aspect;
const picture_max_aspect = main.picture_max_aspect;
const picture_radius = main.picture_radius;
const picture_stripe_cap = main.picture_stripe_cap;
const pressRow = main.pressRow;
const recalledAspect = main.recalledAspect;
const urlHost = main.urlHost;
const vgap = main.vgap;

/// The height a note's picture occupies, whether or not it has loaded. Taken
/// from the note's declared `imeta` shape, else the shape it turned out to be
/// last time it was decoded, else a gentle default. Clamped so one very tall
/// image cannot take over the feed.
pub fn pictureHeight(note: *const Note) f32 {
    // The picture spans the reading column, which is what 11o draws, and takes
    // exactly the height the note's own `imeta` implies at that width. It was
    // based on a 300px box and clamped at 320px, so a tall picture was reserved
    // at a height it never drew and the row shifted when the bytes arrived, which
    // is the whole thing a declared shape exists to prevent.
    //
    // The cap is on the ASPECT, not the pixels: a very tall picture is contained
    // rather than allowed to take over the feed, and contained at a height the
    // estimate can state exactly.
    return picture_column_width * @min(pictureAspect(note), picture_max_aspect);
}

/// The shape to draw at: what the note declares, else what this picture measured
/// when it was last decoded (remembered past its slot, so an evicted picture does
/// not shrink and shift the feed), else a landscape guess.
fn pictureAspect(note: *const Note) f32 {
    if (note.imageAt(0).aspect > 0) return note.imageAt(0).aspect;
    return recalledAspect(note.id) orelse picture_default_aspect;
}

/// A note's picture: the image once registered, or a placeholder holding the
/// exact same space while it loads. Drawn with `contain` at its own aspect, so
/// it is never stretched and stays undistorted as the window resizes. Pressing
/// it opens the viewer.
pub fn notePicture(ui: *AppUi, note: *const Note) AppUi.Node {
    const height = pictureHeight(note);
    const image_id = note.media_id();
    // Previews off and this one not asked for: a quiet line saying what is there
    // and what pressing it costs, not a box of reserved space for a picture that
    // is not coming.
    if (!prefs.g_media_previews and !isMediaAsked(note.id) and image_id == 0) return pictureAskChip(ui, note);
    // Asked for and not had. The striped box below means "still coming", and it
    // meant that for a 404 too: the view only asked whether the picture was
    // LOADED, so every state that is not loaded drew the same waiting frame and
    // a picture that was never going to arrive waited forever.
    if (image_id == 0 and mediaFailed(note.id)) return pictureFailedBox(ui, note, height);
    if (image_id == 0) {
        // The same box the picture will fill, striped: reserved space, not an
        // empty frame, and not a skeleton either, which reads as a row of text
        // still loading rather than as a photograph.
        return pictureBox(ui, note, height, pictureBlur(ui, note, height));
    }
    var picture = ui.image(.{ .image = image_id, .grow = 1 });
    // `ui.image` leaves the fit at `stretch`, which distorts the picture into
    // whatever box it is given (and worse as the window resizes).
    picture.widget.image_fit = .contain;
    // The picture sits in a pressable row rather than carrying the press
    // itself: an image is a leaf, and the hit target belongs on a container.
    // `quiet_hover` keeps it from washing over on hover like a list row, and the
    // box is sized to the drawn picture so only the picture itself is pressable,
    // not the empty width beside a narrow one.
    //
    // The link role is what puts the pointing hand over it: the engine follows
    // the native convention, where the hand marks a link and ordinary controls
    // keep the arrow, so this is the one role that advertises "clickable".
    return pictureBox(ui, note, height, picture);
}

/// Gap between gallery cells, and the height a multi-picture row draws at.
///
/// One height for every cell, because a row of pictures at their own aspects is
/// a ragged edge, and the point of a gallery is that it reads as one object.
/// Each picture is drawn `cover` inside its cell, which is the crop every other
/// client uses here: `contain` would letterbox portrait shots into slivers.
const gallery_gap: f32 = 4;
const gallery_height: f32 = 190;

/// A note's pictures. One fills the column at its own shape, as it always has;
/// several become a row of equal cells.
pub fn noteGallery(ui: *AppUi, note: *const Note) AppUi.Node {
    const count = note.imageCount();
    if (count <= 1) return notePicture(ui, note);

    // Previews off: one chip for the whole set rather than one per picture,
    // because the reader is deciding about the note, not about picture three.
    if (!prefs.g_media_previews and !isMediaAsked(note.id)) return pictureAskChip(ui, note);

    const cells = @min(count, max_note_images);
    const width = (picture_column_width - gallery_gap * @as(f32, @floatFromInt(cells - 1))) / @as(f32, @floatFromInt(cells));

    var kids: [max_note_images * 2 - 1]AppUi.Node = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < cells) : (i += 1) {
        if (i > 0) {
            kids[n] = hgap(ui, gallery_gap);
            n += 1;
        }
        kids[n] = galleryCell(ui, note, i, width);
        n += 1;
    }
    return ui.row(.{ .gap = 0, .cross = .start }, .{kids[0..n]});
}

/// One cell of a gallery: the picture once it has a slot, its blurhash while it
/// does not, and a plain box when it will not come.
///
/// The blurhash matters more here than for a single picture. There are sixteen
/// registration slots in the whole app and a gallery wants several at once, so
/// the later cells of a busy screen routinely have none. A blurhash is drawn as
/// flat colour cells rather than a registered image, so it costs nothing and the
/// row still reads as photographs.
fn galleryCell(ui: *AppUi, note: *const Note, index: usize, width: f32) AppUi.Node {
    const p = theme.palette;
    const image_id = note.mediaIdAt(index);
    const failed = image_id == 0 and mediaFailed(mediaKey(note.id, index));

    const inner: AppUi.Node = if (image_id != 0) blk: {
        var picture = ui.image(.{ .image = image_id, .grow = 1 });
        // `cover`, not `contain`: every cell is the same height, so a portrait
        // shot letterboxed into one would be a sliver in a band of background.
        picture.widget.image_fit = .cover;
        break :blk picture;
    } else if (failed)
        ui.el(.panel, .{ .grow = 1, .style = .{ .background = p.surface_inset } }, .{})
    else
        blurGrid(ui, note.imageAt(index).blurhash(), gallery_height);

    return ui.el(.list_item, .{
        .width = width,
        .height = gallery_height,
        .padding = 0,
        .on_press = Msg{ .expand_image_at = .{ .note = note.id, .index = @intCast(index) } },
        .style = .{ .radius = 10, .background = p.surface_inset, .quiet_hover = true },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{inner});
}

/// A quoted note on its way: the SHAPE of the card that will replace it.
///
/// It used to be one 34px bar, which says "something is loading" and nothing
/// about what. A quote card is a face, a name and a line or two of somebody
/// else's words, so the wait looks like that: a disc, a short bar where the
/// name goes, and two body lines, the second one short the way a last line is.
/// Same height as the bar it replaces, so nothing about the row's pricing moves.
pub fn quoteSkeleton(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0, .cross = .start }, .{
        ui.el(.skeleton, .{ .width = 18, .height = 18, .style = .{ .radius = 999, .background = p.surface_inset } }, .{}),
        hgap(ui, 8),
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            ui.el(.skeleton, .{ .width = 96, .height = 8, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
            vgap(ui, 7),
            ui.el(.skeleton, .{ .height = 7, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
            vgap(ui, 5),
            ui.el(.skeleton, .{ .width = 148, .height = 7, .style = .{ .radius = 4, .background = p.surface_inset } }, .{}),
        }),
    });
}

/// A picture that could not be had, in the space it would have taken.
///
/// The same box at the same height, because the row is priced for it and a
/// picture failing must not make the feed jump. What is IN it is different: the
/// picture glyph, a plain sentence, and the host it came from, because "this
/// one host is not answering" is the useful half and it is often the whole
/// story. Pressing opens the original, which is the one thing left that might
/// work, rather than an expanded view of nothing.
fn pictureFailedBox(ui: *AppUi, note: *const Note, height: f32) AppUi.Node {
    const p = theme.palette;
    const host = urlHost(note.imageUrl());
    return pressRow(ui, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true, .background = p.surface_inset, .radius = picture_radius, .border = p.border_hairline, .stroke_width = 1 },
        .on_press = Msg{ .open_url = note.imageUrl() },
        .semantics = .{ .role = .link, .label = "This picture could not be loaded, press to open the original", .focusable = true },
    }, .{
        ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 0 }, .{
            ui.appIcon(.{ .width = 18, .height = 18, .style = .{ .foreground = p.text_dim } }, "image"),
            vgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = "This picture would not load", .scale = mono_hint_scale }},
            ),
            if (host.len > 0) vgap(ui, 4) else ui.spacer(0),
            if (host.len > 0)
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = ui.fmt("{s} · press to open it", .{host}), .monospace = true, .scale = mono_meta_scale }},
                )
            else
                ui.spacer(0),
        }),
    });
}

/// The picture's frame: the reading column at the declared height, with the
/// radius and hairline 11o gives it, whatever is inside it, and the chips laid
/// over the corners. A `data_row` lays children out horizontally, so the chips
/// ride a stack: there is no way to place a child at a point.
fn pictureBox(ui: *AppUi, note: *const Note, height: f32, content: AppUi.Node) AppUi.Node {
    return pressRow(ui, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true, .radius = picture_radius, .border = theme.palette.border_hairline, .stroke_width = 1 },
        .on_press = Msg{ .expand_image = note.id },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{
        ui.stack(.{ .grow = 1 }, .{
            content,
            pictureChips(ui, note),
        }),
    });
}

/// What a picture is while previews are off: one quiet chip naming it and its
/// weight, which loads that one when pressed. The weight is the note's own claim
/// and may be missing, in which case the chip does not invent one.
fn pictureAskChip(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const bytes = note.imageAt(0).bytes;
    const many = note.imageCount() > 1;
    const label = if (many and bytes > 0)
        ui.fmt("{d} images · from {s} · load", .{ note.imageCount(), byteSize(ui.arena, bytes) })
    else if (many)
        ui.fmt("{d} images · load", .{note.imageCount()})
    else if (bytes > 0)
        ui.fmt("image · {s} · load", .{byteSize(ui.arena, bytes)})
    else
        "image · load";
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = picture_ask_height,
            .cross = .center,
            .on_press = Msg{ .load_image = note.id },
            .style = .{ .background = p.surface_inset, .border = p.border_chip, .radius = 6, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Load this image", .focusable = true },
        }, .{
            hgap(ui, 9),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 9),
        }),
        ui.spacer(1),
    });
}

/// What a note is while its author's content warning is up: one quiet chip
/// where the words and the pictures would be, saying so, giving the reason when
/// there is one, and uncovering THIS note when pressed.
///
/// The same chip the ask-for-a-picture line wears (inset ground, hairline,
/// mono-register text), because it is the same kind of thing: a control that
/// stands in for content the reader has not yet agreed to see. It hugs its text
/// rather than spanning the column, which also means it needs no width from the
/// caller and reads the same in a feed row, a reply and a quote card.
///
/// The warning triangle is the one warm mark in it. Nothing else here is
/// coloured, so a covered note reads as covered from across the window without
/// the reason having to be legible.
///
/// The notice is one line so a covered row's height stays known and the feed
/// keeps its rhythm. It also never wraps, so the reason shown is cut hard (see
/// `coverReasonShown`) to keep the chip inside the narrowest column it can be
/// drawn in: a nested reply, an ancestor row, a quote card.
pub fn coverNotice(ui: *AppUi, reason: []const u8, key: i64) AppUi.Node {
    const p = theme.palette;
    const shown = coverReasonShown(ui, reason);
    const label = if (shown.len > 0)
        ui.fmt("Content warning: {s}", .{shown})
    else
        "Content warning";
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = cover_notice_height,
            .cross = .center,
            .on_press = Msg{ .uncover_note = key },
            .style = .{ .background = p.surface_inset, .border = p.border_chip, .radius = 6, .stroke_width = 1, .quiet_hover = true },
            .semantics = .{ .role = .button, .label = "Show this note", .focusable = true },
        }, .{
            hgap(ui, 9),
            ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.status_warning } }, "alert"),
            hgap(ui, 8),
            ui.paragraph(
                .{ .wrap = false, .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 10),
            ui.paragraph(
                .{ .wrap = false, .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = "Show", .weight = .medium, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 9),
        }),
        ui.spacer(1),
    });
}

/// How much of a reason the chip shows, in width units: a narrow character is
/// one and a wide one (CJK, emoji) is two, because the chip hugs its text and
/// never wraps, so the cap is on how wide the line gets and not on how many
/// codepoints it holds.
const cover_reason_units = 24;

/// `reason` cut to `cover_reason_units`, with an ellipsis where it was cut. The
/// full reason is still in the note; the chip is a label, not the place to read it.
pub fn coverReasonShown(ui: *AppUi, reason: []const u8) []const u8 {
    var i: usize = 0;
    var units: usize = 0;
    while (i < reason.len) {
        const len = std.unicode.utf8ByteSequenceLength(reason[i]) catch break;
        if (i + len > reason.len) break;
        const cp = std.unicode.utf8Decode(reason[i .. i + len]) catch break;
        const w: usize = if (cp >= 0x2E80) 2 else 1;
        if (units + w > cover_reason_units) {
            return ui.fmt("{s}\u{2026}", .{std.mem.trimEnd(u8, reason[0..i], " ")});
        }
        units += w;
        i += len;
    }
    return reason[0..i];
}

/// A decoded blurhash: the low-frequency colour of a picture, which is all a
/// blurhash carries. Drawn as a grid of flat cells rather than an image, because
/// every one of the runtime's sixteen image slots is already spent on faces and
/// photographs, and a placeholder must not evict the thing it is standing in for.
pub const Blur = struct {
    /// Row-major, `cells_x * cells_y` colours.
    cells: [blur_cells_x * blur_cells_y]canvas.Color = undefined,
    ok: bool = false,
};

/// Deliberately coarse. Every cell is a widget node, and a view past 1024 nodes
/// is REFUSED WHOLE, not degraded: six loading pictures at 8x6 came to 797 nodes
/// on their own, and a wider window mounting nine rows crossed the ceiling and
/// blanked the feed. A blurhash carries only low frequencies, so 4x3 shows what
/// it has for 19 nodes instead of 55.
const blur_cells_x = 4;
const blur_cells_y = 3;

/// blurhash's own alphabet.
fn base83(c: u8) ?f32 {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";
    const i = std.mem.indexOfScalar(u8, alphabet, c) orelse return null;
    return @floatFromInt(i);
}

fn base83Value(hash: []const u8, from: usize, len: usize) ?f32 {
    @setRuntimeSafety(true); // Slices the hash at offsets its own header implied.
    if (from + len > hash.len) return null;
    var value: f32 = 0;
    for (hash[from .. from + len]) |c| {
        const digit = base83(c) orelse return null;
        value = value * 83 + digit;
    }
    return value;
}

/// sRGB companding, the two halves of it the format needs.
fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// Decodes a blurhash into a small grid of colours. The format is a handful of
/// cosine components; sampling them at each cell's centre is the same sum the
/// reference decoder runs per pixel, at the resolution the eye gets from a
/// placeholder anyway.
pub fn decodeBlurhash(hash: []const u8) Blur {
    @setRuntimeSafety(true); // Component counts decoded out of the hash index a fixed array.
    var out: Blur = .{};
    if (hash.len < 6) return out;
    const size_flag = base83Value(hash, 0, 1) orelse return out;
    const comp_x: usize = @intFromFloat(@mod(size_flag, 9) + 1);
    const comp_y: usize = @intFromFloat(@floor(size_flag / 9) + 1);
    if (hash.len != 4 + 2 * comp_x * comp_y) return out;

    const quant_max = base83Value(hash, 1, 1) orelse return out;
    const max_ac = (quant_max + 1) / 166.0;

    // The DC term is the average colour, straight sRGB bytes.
    const dc = base83Value(hash, 2, 4) orelse return out;
    const dc_int: u32 = @intFromFloat(dc);
    var colours: [9 * 9][3]f32 = undefined;
    colours[0] = .{
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 16) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 8) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(dc_int & 255)) / 255.0),
    };

    var i: usize = 1;
    while (i < comp_x * comp_y) : (i += 1) {
        const ac = base83Value(hash, 4 + i * 2, 2) orelse return out;
        const ac_int: u32 = @intFromFloat(ac);
        colours[i] = .{
            signPow((@as(f32, @floatFromInt(ac_int / (19 * 19))) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt((ac_int / 19) % 19)) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt(ac_int % 19)) - 9) / 9, 2.0) * max_ac,
        };
    }

    for (0..blur_cells_y) |cy| {
        for (0..blur_cells_x) |cx| {
            // The centre of the cell, in the 0..1 the basis is defined over.
            const x = (@as(f32, @floatFromInt(cx)) + 0.5) / @as(f32, @floatFromInt(blur_cells_x));
            const y = (@as(f32, @floatFromInt(cy)) + 0.5) / @as(f32, @floatFromInt(blur_cells_y));
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            for (0..comp_y) |j| {
                for (0..comp_x) |k| {
                    const basis = @cos(std.math.pi * x * @as(f32, @floatFromInt(k))) *
                        @cos(std.math.pi * y * @as(f32, @floatFromInt(j)));
                    const c = colours[j * comp_x + k];
                    r += c[0] * basis;
                    g += c[1] * basis;
                    b += c[2] * basis;
                }
            }
            out.cells[cy * blur_cells_x + cx] = canvas.Color.rgba8(
                @intFromFloat(linearToSrgb(r) * 255 + 0.5),
                @intFromFloat(linearToSrgb(g) * 255 + 0.5),
                @intFromFloat(linearToSrgb(b) * 255 + 0.5),
                255,
            );
        }
    }
    out.ok = true;
    return out;
}

fn signPow(value: f32, exp: f32) f32 {
    const magnitude = std.math.pow(f32, @abs(value), exp);
    return if (value < 0) -magnitude else magnitude;
}

/// What a picture that has not arrived looks like: its own colours when the note
/// carries a blurhash, stripes when it does not.
fn pictureBlur(ui: *AppUi, note: *const Note, height: f32) AppUi.Node {
    return blurGrid(ui, note.imageBlurhash(), height);
}

/// The same, for a picture that is not the note's first: a gallery cell knows
/// its own hash and has no business asking the note for it.
pub fn blurGrid(ui: *AppUi, hash: []const u8, height: f32) AppUi.Node {
    if (hash.len == 0) return pictureStripes(ui, height);
    const blur = decodeBlurhash(hash);
    if (!blur.ok) return pictureStripes(ui, height);

    // Flat cells, not an image: the runtime has sixteen image slots and they are
    // all spent on faces and photographs, so a placeholder must not evict the
    // thing it stands in for. A blurhash carries only low frequencies anyway,
    // which is what a grid of them shows.
    const rows = ui.arena.alloc(AppUi.Node, blur_cells_y) catch return pictureStripes(ui, height);
    for (rows, 0..) |*row, y| {
        const cells = ui.arena.alloc(AppUi.Node, blur_cells_x) catch return pictureStripes(ui, height);
        for (cells, 0..) |*cell, x| {
            cell.* = ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = blur.cells[y * blur_cells_x + x], .radius = 0, .stroke_width = 0 },
            }, .{});
        }
        row.* = ui.row(.{ .grow = 1, .gap = 0 }, .{cells});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{rows});
}

/// The fill under a picture that has not arrived. The shot draws 45 degree
/// stripes; the canvas has no gradients at the widget level and no rotation, so
/// they run flat, which keeps what the stripes are FOR (this is a photograph
/// arriving, not a paragraph) without pretending to an angle.
fn pictureStripes(ui: *AppUi, height: f32) AppUi.Node {
    const p = theme.palette;
    // The band count is capped, so the BANDS grow instead: a stated height that
    // stopped at the cap left the bottom of a tall box as bare window inside its
    // own border.
    const count: usize = @min(@max(1, @as(usize, @intFromFloat(@ceil(height / 14)))), picture_stripe_cap);
    const bands = ui.arena.alloc(AppUi.Node, count) catch return ui.spacer(0);
    for (bands, 0..) |*b, i| {
        b.* = ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{ .background = if (i % 2 == 0) p.surface_stripe_a else p.surface_stripe_b, .radius = 0, .stroke_width = 0 },
        }, .{});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{bands});
}

/// 11o's link preview: what the page on the other end says it is. One per note,
/// under the body, and the URL stays in the text as well, because the card is a
/// courtesy and the address is the fact.
///
/// The tile is a letter, never a favicon: a favicon would want one of the
/// sixteen image slots the whole runtime has, and those belong to faces and
/// photographs.
/// How wide the text beside a link preview's tile may be.
///
/// Spelled out from the parts rather than left to `grow`, because the row's
/// other children are all fixed: the gap before the tile, the tile, the gap
/// after it, and the gap at the end. What is left is what the title and the
/// description have to live inside, and a test measures the result rather than
/// trusting this arithmetic.
const link_card_tile_size: f32 = 30;
const link_card_text_width: f32 = picture_column_width - 12 - link_card_tile_size - 10 - 12;
/// And how many characters of description fit that width at its scale. A length
/// rather than a width because the engine will not elide this one: see the call.
const link_desc_max: usize = 78;

/// A video the note carries, said plainly.
///
/// Recognition only. Plaza draws no frame and plays nothing yet: the toolkit
/// has the whole transport for it and Plaza calls none of it, and deciding who
/// owns the one player in a scrolling column is the other half of this. What
/// this fixes is that a video used to be indistinguishable from a web page, so
/// it got a page's card and a page's fetch.
///
/// The host, because that is who you are about to hand a request to, and the
/// note's own `alt` when it wrote one.
pub fn videoCard(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const url = note.linkUrl();
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 3),
        ui.el(.list_item, .{
            .width = picture_column_width,
            .padding = 0.01,
            .on_press = Msg{ .open_url = url },
            .style = .{ .background = p.surface_link_card, .border = p.border_chip_alt, .radius = 10, .stroke_width = 1 },
            .semantics = .{ .role = .link, .label = "Open video", .focusable = true },
        }, .{
            hgap(ui, 12),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 10),
                ui.el(.panel, .{
                    .width = 30,
                    .height = 30,
                    .padding = 0.01,
                    .style = .{ .background = p.surface_link_tile, .radius = 7, .stroke_width = 0 },
                }, .{
                    ui.column(.{ .width = 30, .height = 30, .main = .center, .cross = .center }, .{
                        ui.icon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_secondary } }, "play"),
                    }),
                }),
                vgap(ui, 10),
            }),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 10),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_body } },
                    &.{.{ .text = "Video", .weight = .medium, .scale = meta_scale }},
                ),
                vgap(ui, 2),
                ui.paragraph(
                    .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
                    &.{.{ .text = urlHost(url), .monospace = true, .scale = mono_meta_scale }},
                ),
                vgap(ui, 10),
            }),
            hgap(ui, 12),
        }),
    });
}

pub fn linkCard(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const url = note.linkUrl();
    const entry = linkFor(url);
    // Nothing to show until the page has answered. No skeleton: a card that
    // might never come is worse than a link that reads as a link.
    if (entry == null or entry.?.state != .loaded) return ui.spacer(0);
    const link = entry.?;
    const initial = std.ascii.toUpper(if (link.domain().len > 0) link.domain()[0] else '?');

    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 3),
        ui.el(.list_item, .{
            .width = picture_column_width,
            .padding = 0.01,
            // The URL slice lives in the note, which lives in the model, and the
            // opener copies it before it runs.
            .on_press = Msg{ .open_url = url },
            .style = .{ .background = p.surface_link_card, .border = p.border_chip_alt, .radius = 10, .stroke_width = 1 },
            .semantics = .{ .role = .link, .label = "Open link", .focusable = true },
        }, .{
            hgap(ui, 12),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 10),
                ui.el(.panel, .{
                    .width = 30,
                    .height = 30,
                    .padding = 0.01,
                    .style = .{ .background = p.surface_link_tile, .radius = 7, .stroke_width = 0 },
                }, .{
                    ui.column(.{ .width = 30, .height = 30, .main = .center, .cross = .center }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = ui.fmt("{c}", .{initial}), .monospace = true, .weight = .medium, .scale = meta_scale }},
                        ),
                    }),
                }),
            }),
            hgap(ui, 10),
            // A STATED width, not `grow`. `grow` hands out SPARE space and never
            // takes any back, so a child whose natural size already exceeds the
            // row has nothing to grow into and is simply left at its natural
            // size. A page title and description with `wrap = false` are as wide
            // as the sentence, which for a link preview is far wider than the
            // card, so the row overflowed the card, the card overflowed the
            // column, and the description ran off the right of the window. The
            // ellipsis never fired because ellipsis needs a box to be too small
            // FOR, and the leaf was never given one.
            ui.column(.{ .width = link_card_text_width, .gap = 0 }, .{
                vgap(ui, 10),
                ui.paragraph(
                    .{ .width = link_card_text_width, .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = link.domain(), .monospace = true, .scale = mono_chip_scale }},
                ),
                vgap(ui, 2),
                // The width is on THESE, not only on the column around them.
                // That is what the first attempt got wrong: it stated the
                // width one level up and asserted the geometry against the
                // card, which passed, while a title still ran to the window's
                // right edge and was cut off there with no ellipsis. A text
                // leaf with no wrap measures as one line at its natural width
                // whatever its ancestors say, so `.overflow = .ellipsis` had
                // nothing to elide against. Safe to state here because nothing
                // sits beside these in the column: a definite width on a leaf
                // with a neighbour would push the neighbour away instead.
                ui.text(.{
                    .width = link_card_text_width,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .size = .sm,
                    .style = .{ .foreground = p.text_link_title },
                }, link.title()),
                if (link.description().len == 0) ui.spacer(0) else vgap(ui, 2),
                // Shortened here rather than left to `.overflow`, unlike the
                // title directly above it. The engine's ellipsis works on a
                // plain `ui.text` and not on a paragraph built from SPANS: the
                // title came back correctly elided while this line, with the
                // same width and the same overflow setting, ran flat off the
                // end of the card. The span is kept because it carries the
                // smaller scale a description wants.
                if (link.description().len == 0) ui.spacer(0) else ui.paragraph(.{
                    .width = link_card_text_width,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .style = .{ .foreground = p.text_muted },
                }, &.{.{ .text = elide(ui, link.description(), link_desc_max), .scale = mono_row_scale }}),
                vgap(ui, 10),
            }),
            hgap(ui, 12),
        }),
    });
}

/// The two chips 11o lays over a picture: its declared size at the top right and
/// its alt text at the bottom left. Both read at rest, because hover cannot
/// restyle or reveal a child.
fn pictureChips(ui: *AppUi, note: *const Note) AppUi.Node {
    const dims = note.imageChipLabel(ui.arena);
    const alt = note.image_has_alt;
    if (dims.len == 0 and !alt) return ui.spacer(0);
    return ui.column(.{ .grow = 1, .gap = 0 }, .{
        ui.row(.{ .grow = 1, .main = .end, .cross = .start, .gap = 0 }, .{
            if (dims.len == 0) ui.spacer(0) else pictureChip(ui, dims, false),
            hgap(ui, picture_chip_inset),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, picture_chip_inset),
            if (!alt) ui.spacer(0) else pictureChip(ui, "ALT", true),
            ui.spacer(1),
        }),
        vgap(ui, picture_chip_inset),
    });
}

/// One chip over a picture: mono, small, on a scrim dark enough to read against
/// any photograph.
fn pictureChip(ui: *AppUi, label: []const u8, emphatic: bool) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, picture_chip_inset),
        ui.el(.panel, .{
            .padding = 0.01,
            .height = picture_chip_height,
            .style = .{ .background = p.scrim_chip, .border = p.border_chip_alt, .radius = 5, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 7),
                // A scaled span, because the 10px mono register has no size enum
                // rung. No stated width: 11o draws both of these as pills hugging
                // their text, and a fixed one made "ALT" a 194px bar across the
                // bottom of every described picture. Both labels are bounded by
                // construction, the longest being `1600×900 · 240 KB`.
                ui.paragraph(.{
                    .wrap = false,
                    .style = .{ .foreground = if (emphatic) p.text_secondary else p.text_muted_alt },
                }, &.{.{
                    .text = label,
                    .monospace = true,
                    .weight = if (emphatic) .medium else .regular,
                    .scale = mono_chip_scale,
                }}),
                hgap(ui, 7),
            }),
        }),
    });
}

/// How wide the drawn picture is: its own shape at the reserved height, never
/// wider than the card. `contain` centres a narrow picture in its box, so
/// matching the box to the picture is what keeps the press on the picture.
pub fn pictureWidth(note: *const Note) f32 {
    // The TRUE aspect, not the capped one: a picture taller than the cap is
    // drawn `contain`ed at the reserved height, so its drawn width is what the
    // shape says, and the box must be that or the gutters either side are bare
    // window inside the border, and pressable.
    const aspect = pictureAspect(note);
    if (aspect <= 0) return picture_column_width;
    // The box IS the picture: a portrait photo drawn `contain`ed inside a
    // column-wide box would leave bare window either side, inside the border,
    // and all of it pressable. Matching the box to what is drawn keeps the press
    // on the picture and the chips on its corners.
    return @min(picture_column_width, pictureHeight(note) / aspect);
}

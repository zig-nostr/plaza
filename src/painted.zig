//! What the renderer actually PAINTS, so a test can ask which colour covers a
//! place rather than which widget sits there.
//!
//! This exists because four separate features of the M10 redesign shipped
//! invisible, and every one of them looked perfect in the widget tree:
//!
//!   - span weights degraded to the base face, so "bold" drew regular;
//!   - a link span is underlined whether or not the span asks for it;
//!   - the rail's tiles never painted their fill, so the compose tile the design
//!     makes the single bright surface in the window was a grey pencil on bare
//!     window for as long as the rail existed;
//!   - the guest banner never painted its own background either.
//!
//! The last two share a root cause worth stating loudly: the renderer draws
//! NOTHING for the layout kinds (`stack`, `row`, `column` and friends), so a
//! background on one of those is silently discarded. A widget-tree assertion
//! cannot see any of this. A screenshot can, but only by launching the app and
//! sampling pixels by hand, which is slow, needs a live window, and never runs in
//! CI.
//!
//! So: lay the real view out, emit the real display list, and read the colours
//! back. `fillAt` answers with the last fill covering a point, which is how the
//! painter's algorithm resolves it on screen, and is exactly the pixel sample a
//! screenshot would give at that coordinate.
//!
//! What this does NOT cover: text rendering (glyph coverage, the measured widths
//! that verify a real weight) and anything the platform draws above the canvas.
//! Those still need the harness. This covers surfaces, which is where the
//! silent-failure history is.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const main = @import("main.zig");
const theme = @import("theme.zig");

/// The display list for one build of the real view, plus the layout it came from.
pub const Painted = struct {
    commands: []const canvas.CanvasCommand,
    layout: canvas.WidgetLayoutTree,

    /// Builds, lays out and renders `model` at the app's own window size. The
    /// arena owns everything returned.
    pub fn render(arena: std.mem.Allocator, model: *const main.Model) !Painted {
        return renderAt(arena, model, main.window_width, main.window_height);
    }

    pub fn renderAt(arena: std.mem.Allocator, model: *const main.Model, w: f32, h: f32) !Painted {
        // The app's own icons, so a glyph resolves here as it does live.
        main.registerIcons();

        var ui = main.AppUi.init(arena);
        const node = main.appView(&ui, model);
        if (ui.failed) return error.ViewBuild;
        const tree = try ui.finalize(node);

        // The SAME tokens the running app resolves, so a colour asserted here is
        // the colour the window shows, not a house default.
        const tokens = theme.tokens(main.Model)(model);

        const nodes = try arena.alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, w, h), tokens, nodes);

        const commands = try arena.alloc(canvas.CanvasCommand, native_sdk.runtime.max_canvas_commands_per_view);
        var builder = canvas.Builder.init(commands);
        try canvas.emitWidgetLayout(&builder, layout, tokens);

        return .{ .commands = commands[0..builder.len], .layout = layout };
    }

    /// The same, for ONE piece of the view rather than the whole window: the
    /// caller builds a node and it is laid out in a `w` by `h` box. For a row
    /// whose correctness is about how it fills the space it is given (a rail that
    /// grows to the row's height, say), which is awkward to reach through a whole
    /// app view because it needs a live store behind it.
    pub fn renderPiece(
        arena: std.mem.Allocator,
        model: *const main.Model,
        build: *const fn (*main.AppUi) main.AppUi.Node,
        w: f32,
        h: f32,
    ) !Painted {
        main.registerIcons();

        var ui = main.AppUi.init(arena);
        const node = build(&ui);
        if (ui.failed) return error.ViewBuild;
        const tree = try ui.finalize(node);
        const tokens = theme.tokens(main.Model)(model);

        const nodes = try arena.alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, w, h), tokens, nodes);

        const commands = try arena.alloc(canvas.CanvasCommand, native_sdk.runtime.max_canvas_commands_per_view);
        var builder = canvas.Builder.init(commands);
        try canvas.emitWidgetLayout(&builder, layout, tokens);

        return .{ .commands = commands[0..builder.len], .layout = layout };
    }

    /// The colour covering (`x`, `y`), or null where nothing paints. The LAST
    /// covering fill wins, which is how the painter's algorithm resolves overlap
    /// on screen, so this is the same answer sampling that pixel would give.
    /// Gradients are reported by their first stop.
    pub fn fillAt(self: Painted, x: f32, y: f32) ?canvas.Color {
        var found: ?canvas.Color = null;
        for (self.commands) |command| {
            const hit = switch (command) {
                .fill_rect => |v| if (contains(v.rect, x, y)) fillColor(v.fill) else null,
                .fill_rounded_rect => |v| if (contains(v.rect, x, y)) fillColor(v.fill) else null,
                else => null,
            };
            if (hit) |color| found = color;
        }
        return found;
    }

    /// Whether a fill of exactly `color` covers (`x`, `y`) at any depth, even if
    /// something else paints over it. Use for a surface a later fill legitimately
    /// covers in part; prefer `fillAt` when the question is what the eye sees.
    pub fn hasFillAt(self: Painted, x: f32, y: f32, color: canvas.Color) bool {
        for (self.commands) |command| {
            const hit = switch (command) {
                .fill_rect => |v| if (contains(v.rect, x, y)) fillColor(v.fill) else null,
                .fill_rounded_rect => |v| if (contains(v.rect, x, y)) fillColor(v.fill) else null,
                else => null,
            };
            if (hit) |c| {
                if (sameColor(c, color)) return true;
            }
        }
        return false;
    }

    /// Whether a stroke of `color` runs through (`x`, `y`). The hairline a panel
    /// draws by default is a stroke, which is how a borrowed border is caught.
    pub fn hasStrokeAt(self: Painted, x: f32, y: f32, color: canvas.Color) bool {
        for (self.commands) |command| {
            switch (command) {
                .stroke_rect => |v| {
                    // A zero-width stroke paints nothing, so it is not a line
                    // however much the command list mentions it. (Suppressing a
                    // panel's default hairline emits exactly such a command.)
                    if (v.stroke.width <= 0) continue;
                    // A stroke is drawn ON the rect's edge, so widen by its width
                    // before asking whether the point is on the line.
                    const w = v.stroke.width;
                    if (contains(inflate(v.rect, w), x, y) and !contains(deflate(v.rect, w), x, y)) {
                        if (sameColor(fillColor(v.stroke.fill), color)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// The frame of the first widget the layout labels `label`, for tests that
    /// want to sample a control's centre without hardcoding a coordinate.
    pub fn frameOf(self: Painted, label: []const u8) ?geometry.RectF {
        for (self.layout.nodes) |node| {
            const name = node.widget.semantics.label;
            if (name.len != 0 and std.mem.eql(u8, name, label)) return node.widget.frame;
        }
        return null;
    }

    /// The colour at the centre of the widget labelled `label`.
    pub fn fillAtCenterOf(self: Painted, label: []const u8) ?canvas.Color {
        const frame = self.frameOf(label) orelse return null;
        return self.fillAt(frame.x + frame.width / 2, frame.y + frame.height / 2);
    }
};

fn contains(rect: geometry.RectF, x: f32, y: f32) bool {
    const r = rect.normalized();
    return x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height;
}

fn inflate(rect: geometry.RectF, by: f32) geometry.RectF {
    const r = rect.normalized();
    return geometry.RectF.init(r.x - by, r.y - by, r.width + 2 * by, r.height + 2 * by);
}

fn deflate(rect: geometry.RectF, by: f32) geometry.RectF {
    const r = rect.normalized();
    return geometry.RectF.init(r.x + by, r.y + by, @max(0, r.width - 2 * by), @max(0, r.height - 2 * by));
}

fn fillColor(fill: canvas.Fill) canvas.Color {
    return switch (fill) {
        .color => |c| c,
        .linear_gradient => |g| if (g.stops.len > 0) g.stops[0].color else canvas.Color.rgba8(0, 0, 0, 0),
    };
}

/// Channel equality, on the 8-bit values a designer names. The channels are
/// floats, and every colour on both sides of a comparison here comes from an
/// 8-bit literal, so rounding to bytes compares what the palette actually states
/// and tolerates nothing a reader would call a different colour.
pub fn sameColor(a: canvas.Color, b: canvas.Color) bool {
    return byte(a.r) == byte(b.r) and byte(a.g) == byte(b.g) and byte(a.b) == byte(b.b) and byte(a.a) == byte(b.a);
}

fn byte(channel: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255));
}

/// `#rrggbb` for a message, since a float triple tells a reader nothing.
fn hex6(color: canvas.Color, out: *[7]u8) []const u8 {
    return std.fmt.bufPrint(out, "#{x:0>2}{x:0>2}{x:0>2}", .{ byte(color.r), byte(color.g), byte(color.b) }) catch "#??????";
}

/// `expected` was not what covers (`x`, `y`): reports both colours, since "no
/// fill at all" and "the wrong fill" have very different causes (a background on
/// a layout kind versus a token pointed at the wrong hex).
pub fn expectFillAt(p: Painted, x: f32, y: f32, expected: canvas.Color) !void {
    var want: [7]u8 = undefined;
    var got: [7]u8 = undefined;
    const actual = p.fillAt(x, y);
    if (actual) |c| {
        if (sameColor(c, expected)) return;
        std.debug.print("\n  painted at ({d}, {d}): expected {s}, found {s}\n", .{ x, y, hex6(expected, &want), hex6(c, &got) });
        return error.WrongFill;
    }
    std.debug.print(
        "\n  painted at ({d}, {d}): expected {s}, found NOTHING PAINTED." ++
            " Either a background was stated on a layout kind (row, column, stack), which the" ++
            " renderer discards, or nothing is meant to paint there and the window shows through.\n",
        .{ x, y, hex6(expected, &want) },
    );
    return error.NothingPainted;
}

/// Nothing paints at (`x`, `y`), so the surface below shows through. The window's
/// own background is one such place: the host clears it, not the canvas.
pub fn expectNothingPaintedAt(p: Painted, x: f32, y: f32) !void {
    if (p.fillAt(x, y)) |c| {
        var got: [7]u8 = undefined;
        std.debug.print("\n  painted at ({d}, {d}): expected nothing, found {s}\n", .{ x, y, hex6(c, &got) });
        return error.UnexpectedFill;
    }
}

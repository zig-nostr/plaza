//! The reading side of a NIP-23 long-form article: what a kind:30023 says about
//! itself, and how its markdown body is cut into rows a virtual list can price
//! and mount one screenful at a time.
//!
//! Pure on purpose. Nothing here touches the model, the store or the view, so
//! every decision about an article (which tag wins, what counts as a draft, where
//! the body is split) is a function a test can call with a string.

const std = @import("std");
const nostr = @import("nostr");

/// NIP-23's published article, and its unpublished draft.
pub const kind: u16 = 30023;
pub const draft_kind: u16 = 30024;

/// Hashtags kept for the footer. An article with more than this is a keyword
/// list, and the first few say what it is about.
pub const max_tags = 6;
pub const tag_bytes = 32;

/// What the reader shows above the body. Every slice borrows from the event it
/// was read from, so it is only good while that event is.
pub const Meta = struct {
    title: []const u8 = "",
    summary: []const u8 = "",
    image: []const u8 = "",
    /// When the author says it was published, else when the event was made.
    published_at: i64 = 0,
    tags: [max_tags][]const u8 = [_][]const u8{""} ** max_tags,
    tag_count: usize = 0,
};

fn firstTag(tags: []const nostr.event.Tag, name: []const u8) ?[]const u8 {
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], name)) continue;
        return tag[1];
    }
    return null;
}

/// Reads the article tags off an event.
///
/// `published_at` is taken only when it is a plain integer no later than the
/// event itself: an article cannot have been published after the event that
/// carries it was made, and a future date is how a post pins itself to the top
/// of a list sorted by it. Amethyst drops it in the same case
/// (`LongFormContentEvent.publishedAt`).
pub fn metaOf(ev: nostr.event.Event) Meta {
    var meta = Meta{ .published_at = ev.created_at };
    if (firstTag(ev.tags, "title")) |t| meta.title = std.mem.trim(u8, t, " \t\r\n");
    if (firstTag(ev.tags, "summary")) |s| meta.summary = std.mem.trim(u8, s, " \t\r\n");
    if (firstTag(ev.tags, "image")) |i| meta.image = std.mem.trim(u8, i, " \t\r\n");
    if (firstTag(ev.tags, "published_at")) |p| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, p, " "), 10)) |at| {
            if (at > 0 and at <= ev.created_at) meta.published_at = at;
        } else |_| {}
    }
    for (ev.tags) |tag| {
        if (meta.tag_count >= max_tags) break;
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "t")) continue;
        const t = std.mem.trim(u8, tag[1], " \t\r\n#");
        if (t.len == 0 or t.len > tag_bytes) continue;
        var seen = false;
        for (meta.tags[0..meta.tag_count]) |had| {
            if (std.ascii.eqlIgnoreCase(had, t)) seen = true;
        }
        if (seen) continue;
        meta.tags[meta.tag_count] = t;
        meta.tag_count += 1;
    }
    return meta;
}

/// Height over width of a cover that does not say how big it is: 16 to 9, which
/// is the shape Amethyst gives every cover (`LongForm.kt` `COVER_ASPECT_RATIO`).
pub const cover_aspect: f32 = 9.0 / 16.0;

/// A cover picture is drawn from whatever URL the author put in the tag, so it
/// has to look like a web address before anything is fetched from it.
pub fn isWebUrl(s: []const u8) bool {
    if (s.len < 9) return false;
    if (!std.mem.startsWith(u8, s, "https://") and !std.mem.startsWith(u8, s, "http://")) return false;
    for (s) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Cuts `s` to at most `max` bytes without splitting a code point.
pub fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Copies `s` for display: clipped to `max` bytes on a code point, with control
/// bytes turned into spaces (newlines too, unless `keep_newlines`). A title and a
/// summary come off a stranger's event and land in a fixed-width column.
pub fn cleanLine(allocator: std.mem.Allocator, s: []const u8, max: usize, keep_newlines: bool) std.mem.Allocator.Error![]u8 {
    const clipped = clipUtf8(s, max);
    const out = try allocator.dupe(u8, clipped);
    for (out) |*c| {
        if (c.* == '\n' and keep_newlines) continue;
        if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
    }
    return out;
}

/// Minutes to read `content`, at 225 words a minute and never less than one:
/// Amethyst's count (`LongForm.kt` `estimateReadingMinutes`, whitespace-split
/// words rounded up).
pub fn readingMinutes(content: []const u8) u32 {
    var words: usize = 0;
    var in_word = false;
    for (content) |c| {
        const space = c == ' ' or c == '\n' or c == '\t' or c == '\r';
        if (!space and !in_word) words += 1;
        in_word = !space;
    }
    const minutes = (words + 224) / 225;
    return @intCast(@max(minutes, 1));
}

/// One row of the body: a byte range of the markdown, and a guess at how tall it
/// draws so the list can place rows it has not mounted yet.
pub const Chunk = struct {
    start: u32,
    end: u32,
    height: f32,
    /// The row begins inside a fenced block that an earlier row opened, so it is
    /// drawn with the fence put back in front of it (see `row_hard_bytes`).
    in_fence: bool = false,
};

/// The most body rows one article gets. Four hundred rows of a few kilobytes is
/// a megabyte of text, past the size any relay keeps an event at; an article
/// that still outruns it is cut and says so.
pub const max_chunks = 400;

/// How much markdown goes into one row before the next paragraph break closes
/// it. Small enough that a row is a handful of blocks (the toolkit builds every
/// widget in a row it mounts, and a screenful is a few rows), big enough that a
/// long article is hundreds of rows rather than thousands.
pub const chunk_target_bytes = 2400;

/// How many blocks one row may carry before the next block starts a new row,
/// with every list item and table row counted as one more.
///
/// The toolkit's Markdown view stops at 64 blocks in a document and drops the
/// rest without a word, so a row of short paragraphs (a poem, a list of quotes
/// set apart by blank lines) that fitted in the byte target could still lose its
/// second half. Items and table rows count because they are widgets too, and the
/// rows on screen share one budget of them.
pub const max_row_weight = 32;

/// The longest a row may get, whatever it is in the middle of. Past this a row
/// is cut at the next line, or inside the line when one line is longer.
///
/// Everything else here cuts only where cutting is invisible, which leaves a
/// fence that never closes, a details block that never closes or a single
/// enormous line free to make one row of the whole article. The toolkit then
/// keeps only the first 8 KiB of a paragraph and the first 64 blocks, and every
/// row mounted shares one text budget with the rest of the window. A cut inside
/// a fenced block is drawn with the fence opened again (`Chunk.in_fence`), so a
/// long listing reads as one; any other cut here is in text no reader wrote by
/// hand.
pub const row_hard_bytes = 8000;

/// Sizes the height guess is made from: the body's line height and how many
/// characters fit a line of the reading column at Plaza's body size.
const line_height: f32 = 21.5;
const chars_per_line: f32 = 70;
const block_gap: f32 = 12;
const code_line_height: f32 = 19;
const code_padding: f32 = 24;
const heading_scales = [_]f32{ 2.0, 1.5, 1.25 };

pub const Chunked = struct {
    len: usize,
    /// The body ran past `max_chunks` and the rest was left out.
    truncated: bool,
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// What a line is, as far as where a row may end. The tests the toolkit's own
/// parser makes (`markdown.zig`: a fence is any line that starts with three
/// backticks once trimmed, a details block a line that starts `<details`), so a
/// cut lands where the renderer also sees a boundary.
const LineKind = enum { none, blank, paragraph, heading, rule, fence, details_open, details_close, quote, list, table };

fn isListLine(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') return true;
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    return i > 0 and i + 1 < t.len and t[i] == '.' and t[i + 1] == ' ';
}

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const marker = t[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: usize = 0;
    for (t) |c| {
        if (c == marker) {
            count += 1;
        } else if (c != ' ') return false;
    }
    return count >= 3;
}

fn headingLevel(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= line.len or line[n] != ' ') return 0;
    return @min(n, heading_scales.len);
}

fn kindOf(line: []const u8, t: []const u8) LineKind {
    if (t.len == 0) return .blank;
    if (std.mem.startsWith(u8, t, "```")) return .fence;
    if (headingLevel(t) > 0) return .heading;
    if (isRule(t)) return .rule;
    if (t[0] == '>') return .quote;
    if (isListLine(line)) return .list;
    if (std.ascii.startsWithIgnoreCase(t, "</details>")) return .details_close;
    if (std.ascii.startsWithIgnoreCase(t, "<details")) return .details_open;
    if (t[0] == '|') return .table;
    return .paragraph;
}

/// Whether a line of `kind` after a line of `prev` is the first line of a new
/// block. Over-counting is harmless (a row ends a little early); under-counting
/// is what drops text, so anything unsure counts.
fn startsBlock(line_kind: LineKind, prev: LineKind) bool {
    return switch (line_kind) {
        .blank, .none => false,
        .paragraph => prev != .paragraph,
        .quote, .list, .table => prev != line_kind,
        else => true,
    };
}

fn linesFor(chars: usize, per_line: f32) f32 {
    const c: f32 = @floatFromInt(@max(chars, 1));
    return @ceil(c / per_line);
}

/// Splits `content` into rows, each drawn by the Markdown view on its own.
///
/// A row closes at the first blank line after it reaches `chunk_target_bytes`,
/// or before the first block that would take it past `max_row_weight`, and only
/// where the cut is invisible: never inside a fenced block (its blank lines are
/// part of the code) and never inside a `<details>` block (its summary and its
/// body must stay together). Between the items of a list is fine: the toolkit
/// prints the number the author wrote rather than counting, and a blank line
/// already ends a list there. `row_hard_bytes` bounds whatever is left.
pub fn chunk(content: []const u8, out: []Chunk) Chunked {
    var len: usize = 0;
    var row_start: usize = 0;
    var row_height: f32 = 0;
    var row_weight: usize = 0;
    var row_in_fence = false;
    var pending_gap = false;
    var fence = false;
    var details: i32 = 0;
    var prev: LineKind = .none;

    var pos: usize = 0;
    while (pos < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const next = if (nl < content.len) nl + 1 else content.len;

        if (next - row_start > row_hard_bytes) {
            // At the start of this line when the row already holds something,
            // else inside the line, on a code point, since the line alone is
            // too long.
            var cut = pos;
            var height = row_height + block_gap;
            if (pos == row_start) {
                const piece = clipUtf8(content[row_start..], row_hard_bytes).len;
                cut = row_start + (if (piece > 0) piece else row_hard_bytes);
                height = linesFor(cut - row_start, chars_per_line) * (if (fence) code_line_height else line_height) + block_gap;
            }
            if (len >= out.len) return .{ .len = len, .truncated = true };
            out[len] = .{ .start = @intCast(row_start), .end = @intCast(cut), .height = height, .in_fence = row_in_fence };
            len += 1;
            row_start = cut;
            row_height = 0;
            row_weight = 0;
            row_in_fence = fence;
            pending_gap = false;
            pos = cut;
            continue;
        }

        const line = content[pos..nl];
        const t = trimLine(line);

        if (fence) {
            // Inside code: every line is a code line, and a fence line ends it.
            if (std.mem.startsWith(u8, t, "```")) {
                fence = false;
                row_height += code_padding;
            } else row_height += code_line_height;
            prev = .fence;
            pos = next;
            continue;
        }

        const what = kindOf(line, t);
        if (what == .blank) {
            pending_gap = true;
            if (details <= 0 and next - row_start >= chunk_target_bytes) {
                if (len >= out.len) return .{ .len = len, .truncated = true };
                out[len] = .{ .start = @intCast(row_start), .end = @intCast(pos), .height = row_height + block_gap, .in_fence = row_in_fence };
                len += 1;
                row_start = next;
                row_height = 0;
                row_weight = 0;
                row_in_fence = false;
                pending_gap = false;
            }
            prev = .blank;
            pos = next;
            continue;
        }

        const starts = startsBlock(what, prev);
        // Full: the next block opens a new row. And a list long enough to fill
        // one on its own is cut before an item, since nothing joins the items
        // of a row to the one above it.
        const full = starts and row_weight >= max_row_weight;
        const long_list = what == .list and line[0] != ' ' and row_weight >= max_row_weight * 2;
        if ((full or long_list) and details <= 0 and pos > row_start) {
            if (len >= out.len) return .{ .len = len, .truncated = true };
            out[len] = .{ .start = @intCast(row_start), .end = @intCast(pos), .height = row_height + block_gap, .in_fence = row_in_fence };
            len += 1;
            row_start = pos;
            row_height = 0;
            row_weight = 0;
            row_in_fence = false;
            pending_gap = false;
        }
        if (starts or what == .list or what == .table) row_weight += 1;

        if (what == .details_open) details += 1;
        if (what == .details_close) details -= 1;

        if (pending_gap and row_height > 0) row_height += block_gap;
        pending_gap = false;

        switch (what) {
            .fence => {
                fence = true;
                row_height += code_padding / 2;
            },
            .heading => {
                const scale = heading_scales[headingLevel(t) - 1];
                row_height += linesFor(t.len, chars_per_line / scale) * line_height * scale;
            },
            .list => row_height += linesFor(t.len, chars_per_line - 6) * line_height + 4,
            // Consecutive lines are one paragraph; the wrap is priced per line,
            // which is a little high and errs toward a taller guess.
            else => row_height += linesFor(t.len, chars_per_line) * line_height,
        }
        prev = what;
        pos = next;
    }

    if (row_start < content.len and trimLine(content[row_start..]).len > 0) {
        if (len >= out.len) return .{ .len = len, .truncated = true };
        out[len] = .{ .start = @intCast(row_start), .end = @intCast(content.len), .height = row_height + block_gap, .in_fence = row_in_fence };
        len += 1;
    }
    return .{ .len = len, .truncated = false };
}

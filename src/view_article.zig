//! The article reader: a long-form note's header, body and footer.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const article = @import("article.zig");
const view_thread = @import("view_thread.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const absoluteNoteTime = main.absoluteNoteTime;
const avatar_size = main.avatar_size;
const avatar_to_text_gap = main.avatar_to_text_gap;
const backControl = main.backControl;
const backLabel = main.backLabel;
const coverNotice = main.coverNotice;
const cover_notice_height = main.cover_notice_height;
const hgap = main.hgap;
const identityBlock = main.identityBlock;
const join_sub_scale = main.join_sub_scale;
const mono_hint_scale = main.mono_hint_scale;
const noteAvatar = main.noteAvatar;
const noteCovered = main.noteCovered;
const notePicture = main.notePicture;
const pictureHeight = main.pictureHeight;
const picture_column_width = main.picture_column_width;
const placeholderKey = main.placeholderKey;
const rowExtentFromTable = main.rowExtentFromTable;
const topicLinkFor = main.topicLinkFor;
const vgap = main.vgap;
const window_height = main.window_height;

// ------------------------------------------------------------- the article reader
//
// A kind:30023 opened by id is a level of its own, drawn as a reader rather than
// as a thread. It is the same level in every other way (the back-stack, the
// scroll offset kept per level, the avatar and picture passes), so the only fork
// is in `feedView`, which asks `isArticleRoot` of the level's root.
//
// The body is not baked into the `Note`: that struct carries a few kilobytes of
// text because it is copied on every rebuild, and an article is tens of
// kilobytes. It is read from the store when the level is first drawn and kept
// here, cut into rows (see `article.chunk`) so that only the rows near the
// viewport are built, the way the feed and the thread are.

/// The reading column. The width a note's picture takes, so a cover lines up
/// with the text beneath it and the column is a comfortable line length with
/// real margin either side of it in the 620 point row.
const article_text_width: f32 = picture_column_width;
const article_title_scale: f32 = 25.0 / 14.5;
const article_summary_scale: f32 = 16.0 / 14.5;
const article_foot_pad: f32 = 56;

/// One article, loaded for reading. Owns its text; replaced when another opens.
const ArticleView = struct {
    arena: std.heap.ArenaAllocator,
    event_id: [32]u8,
    title: []const u8 = "",
    summary: []const u8 = "",
    body: []const u8 = "",
    tags: [article.max_tags][]const u8 = [_][]const u8{""} ** article.max_tags,
    tag_count: usize = 0,
    published_at: i64 = 0,
    minutes: u32 = 1,
    chunks: [article.max_chunks]article.Chunk = undefined,
    chunk_count: usize = 0,
    truncated: bool = false,

    /// Rows in the list: the head, each piece of the body, and the foot.
    pub fn rowCount(self: *const ArticleView) usize {
        return self.chunk_count + 2;
    }
};

/// The cap on the body Plaza will read. Relays refuse events well under this, so
/// it bounds the copy rather than the article.
const article_body_cap = 1 << 20;

/// The article on screen. UI-thread only. Only the front level draws a body, so
/// one is enough: walking back to an article underneath reads it again, which is
/// one store lookup.
pub var g_article: ?*ArticleView = null;

/// The article behind `event_id`, read from the store the first time it is asked
/// for. Null when this machine does not hold it, or holds something that is not
/// a published article.
pub fn articleFor(event_id: [32]u8) ?*const ArticleView {
    if (g_article) |held| {
        if (std.mem.eql(u8, &held.event_id, &event_id)) return held;
    }
    const store = main.g_store orelse return null;
    var se = (store.getEvent(std.heap.page_allocator, event_id) catch return null) orelse return null;
    defer se.deinit();
    if (se.event.kind != article.kind) return null;

    const view = std.heap.page_allocator.create(ArticleView) catch return null;
    view.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .event_id = event_id };
    const a = view.arena.allocator();
    const meta = article.metaOf(se.event);
    const loaded = blk: {
        view.title = article.cleanLine(a, meta.title, 400, false) catch break :blk false;
        view.summary = article.cleanLine(a, meta.summary, 1200, true) catch break :blk false;
        view.body = a.dupe(u8, article.clipUtf8(se.event.content, article_body_cap)) catch break :blk false;
        for (meta.tags[0..meta.tag_count], 0..) |t, i| view.tags[i] = a.dupe(u8, t) catch break :blk false;
        break :blk true;
    };
    if (!loaded) {
        view.arena.deinit();
        std.heap.page_allocator.destroy(view);
        return null;
    }
    view.tag_count = meta.tag_count;
    view.published_at = meta.published_at;
    view.minutes = article.readingMinutes(view.body);
    const cut = article.chunk(view.body, &view.chunks);
    view.chunk_count = cut.len;
    view.truncated = cut.truncated;

    if (g_article) |old| {
        old.arena.deinit();
        std.heap.page_allocator.destroy(old);
    }
    g_article = view;
    return view;
}

/// Whether a level's root is an article to be read rather than a thread.
pub fn isArticleRoot(root: *const Note) bool {
    return root.kind == article.kind;
}
/// A height guess for the head: the byline, the title and summary at their
/// wrapped lengths, the cover, and the date line.
fn articleHeadHeight(root: *const Note, av: ?*const ArticleView) f32 {
    var h: f32 = 20 + avatar_size + 18 + 16 + 12 + 1 + 20;
    if (noteCovered(root)) return h + cover_notice_height + 14 + 22;
    const title = if (av) |a| a.title else root.content();
    const title_lines = @max(@ceil(@as(f32, @floatFromInt(@max(title.len, 1))) / 39), 1);
    h += title_lines * 14.5 * article_title_scale * 1.3 + 10;
    if (av) |a| {
        if (a.summary.len > 0) {
            const lines = @max(@ceil(@as(f32, @floatFromInt(a.summary.len)) / 62), 1);
            h += lines * 14.5 * article_summary_scale * 1.4 + 12;
        }
    }
    if (root.hasImage()) h += pictureHeight(root) + 14;
    return h + 22;
}

fn articleFootHeight(av: ?*const ArticleView) f32 {
    const a = av orelse return article_foot_pad;
    return article_foot_pad + (if (a.tag_count > 0) @as(f32, 30) else 0) + (if (a.truncated) @as(f32, 30) else 0);
}

fn articleHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // The same answer the thread header gives, from the state Back acts on.
    const back_label = backLabel(model, ui.arena);
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            backControl(ui, back_label, .close_thread),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Article", .weight = .bold }}),
            ui.spacer(1),
        }),
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

/// The byline, the title, the summary, the cover and the date: what the card in
/// a feed would say, at the size of the thing being read.
///
/// An article under its author's content warning (NIP-36) shows the byline, the
/// warning with Show, and the date, and nothing it covers: the title and the
/// summary are the article as much as its body is, and the picture is not
/// fetched while it is covered (`fireMediaAt`).
fn articleHead(ui: *AppUi, root: *const Note, av: ?*const ArticleView) AppUi.Node {
    const p = theme.palette;
    const covered = noteCovered(root);
    const title = if (covered) "" else if (av) |a| a.title else root.content();
    const summary = if (covered) "" else if (av) |a| a.summary else "";
    const picture = !covered and root.hasImage();
    return ui.column(.{ .width = article_text_width, .gap = 0 }, .{
        vgap(ui, 20),
        ui.row(.{ .gap = 0, .cross = .center }, .{
            noteAvatar(ui, root),
            hgap(ui, avatar_to_text_gap),
            identityBlock(ui, root),
            ui.spacer(1),
        }),
        vgap(ui, 18),
        if (title.len > 0)
            ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = title, .weight = .bold, .scale = article_title_scale }},
            )
        else
            ui.spacer(0),
        if (title.len > 0) vgap(ui, 10) else ui.spacer(0),
        if (summary.len > 0) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = summary, .scale = article_summary_scale }},
        ) else ui.spacer(0),
        if (summary.len > 0) vgap(ui, 12) else ui.spacer(0),
        if (covered) coverNotice(ui, root.warning(), root.id) else ui.spacer(0),
        if (covered) vgap(ui, 14) else ui.spacer(0),
        if (picture) notePicture(ui, root) else ui.spacer(0),
        if (picture) vgap(ui, 14) else ui.spacer(0),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{
                .text = if (av) |a|
                    ui.fmt("{s} · {d} min read", .{ absoluteNoteTime(ui.arena, a.published_at), a.minutes })
                else
                    "Not on this machine yet",
                .monospace = true,
                .scale = mono_hint_scale,
            }},
        ),
        vgap(ui, 16),
        ui.separator(.{ .style = .{ .foreground = p.divider_card, .background = p.divider_card } }),
        vgap(ui, 12),
    });
}

/// The hashtags the author filed it under, as the same pressable topics a note's
/// hashtags are, and a line saying so when the body was cut.
fn articleFoot(ui: *AppUi, av: ?*const ArticleView) AppUi.Node {
    const p = theme.palette;
    const a = av orelse return vgap(ui, article_foot_pad);
    var spans: [article.max_tags * 2]canvas.TextSpan = undefined;
    var n: usize = 0;
    for (a.tags[0..a.tag_count]) |tag| {
        const link = topicLinkFor(tag) orelse continue;
        if (n > 0) {
            spans[n] = .{ .text = "  " };
            n += 1;
        }
        spans[n] = .{ .text = ui.fmt("#{s}", .{tag}), .color = .text_muted, .link = link };
        n += 1;
    }
    return ui.column(.{ .width = article_text_width, .gap = 0 }, .{
        vgap(ui, 8),
        if (n > 0) ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = p.text_muted } }, spans[0..n]) else ui.spacer(0),
        if (a.truncated) vgap(ui, 10) else ui.spacer(0),
        if (a.truncated) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = "This article is longer than Plaza shows. The rest is in the original.", .scale = join_sub_scale }},
        ) else ui.spacer(0),
        vgap(ui, article_foot_pad),
    });
}

/// One row of the list. `index` 0 is the head, the last is the foot, and the
/// ones between are the body, each rendered from its own slice of the markdown.
pub fn articleRowAt(ui: *AppUi, root: *const Note, av: ?*const ArticleView, index: usize) AppUi.Node {
    const inner: AppUi.Node = if (index == 0)
        articleHead(ui, root, av)
    else if (av) |a| (if (index > a.chunk_count)
        articleFoot(ui, av)
    else blk: {
        const c = a.chunks[index - 1];
        const piece = a.body[c.start..c.end];
        // A row cut out of the middle of a long code block gets its fence back,
        // or the rest of the listing would be read as prose.
        const source = if (c.in_fence) ui.fmt("```\n{s}", .{piece}) else piece;
        break :blk ui.column(.{ .width = article_text_width, .gap = 0 }, .{
            vgap(ui, 6),
            canvas.markdown.Markdown(Msg).view(ui, source, .{
                .on_link = AppUi.linkMsg(.open_url),
                .details_expanded = &article_details_open,
            }),
            vgap(ui, 6),
        });
    }) else articleFoot(ui, av);
    var node = ui.row(.{ .grow = 1, .main = .center }, .{inner});
    node.key = .{ .int = placeholderKey(@intFromEnum(KindOfRow.article), index) };
    return node;
}

/// A `<details>` block in an article is drawn open. The toolkit draws one closed
/// unless told otherwise, and opening it needs a message and a place in the model
/// per block per row; with neither, what the author put inside could not be read
/// at all.
const article_details_open = [_]bool{true} ** canvas.markdown.max_markdown_details_per_document;

/// Row identities in a reader share `placeholderKey`'s space with the thread's
/// placeholder rows; the number only has to differ from theirs.
const KindOfRow = enum(u64) { article = 40 };

/// The reader for one level: the header bar over a windowed list of the body.
/// `occluded` levels build nothing and keep their place, exactly as a thread's do.
pub fn articlePanel(ui: *AppUi, model: *const Model, root: *const Note, level_key: u64, level: usize, occluded: bool) AppUi.Node {
    const av = if (occluded) null else articleFor(root.event_id);
    // Covered, the head is the whole article: no body row is built until the
    // reader presses Show, and the foot's hashtags wait with it.
    const covered = noteCovered(root);
    const total: usize = if (covered) 1 else if (av) |a| a.rowCount() else 1;
    const table = &view_thread.g_thread_extents[@min(level, view_thread.g_thread_extents.len - 1)];
    table.reset();
    if (!occluded) {
        table.push(articleHeadHeight(root, av));
        if (av) |a| {
            if (!covered) {
                for (a.chunks[0..a.chunk_count]) |c| table.push(c.height);
                table.push(articleFootHeight(av));
            }
        }
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("thread-{d}", .{level_key}),
        .item_count = if (occluded) 0 else total,
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 2,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Article" },
    };
    const window = ui.virtualWindow(options);
    if (!occluded) {
        const set = &view_thread.g_level_visible[@min(level, view_thread.g_level_visible.len - 1)];
        set.reset();
        view_thread.g_visible_level = @min(level, view_thread.g_level_visible.len - 1);
        // Only while the head is on screen: the face and the cover are both in
        // it, and a reader deep in the body has no use for either.
        if (window.first_visible_index == 0) {
            set.pushAuthor(root.pubkey);
            set.pushNote(root.id);
        }
    }
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = articleRowAt(ui, root, av, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (occluded) ui.spacer(0) else articleHeader(ui, model),
        ui.virtualList(options, window, .{rows}),
    });
}

/// Forgets the loaded article, for a test that opens several in turn.
pub fn forgetArticleForTest() void {
    if (g_article) |old| {
        old.arena.deinit();
        std.heap.page_allocator.destroy(old);
    }
    g_article = null;
}

/// How many rows the reader built for the article behind `event_id`, and how many
/// the list was told about. The difference is the whole point of windowing.
pub fn articleRowCountForTest(event_id: [32]u8) usize {
    return if (articleFor(event_id)) |a| a.rowCount() else 0;
}

/// Row `index` of the article `root` names, built the way the reader builds it,
/// so a test can read every row and not only the ones a viewport would mount.
pub fn articleRowForTest(ui: *AppUi, root: *const Note, index: usize) AppUi.Node {
    return articleRowAt(ui, root, articleFor(root.event_id), index);
}

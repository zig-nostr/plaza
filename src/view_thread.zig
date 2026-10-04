//! The thread screen: rows, extents, replies and ancestors.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const compose = @import("compose.zig");
const prefs = @import("prefs.zig");
const thread_model = @import("thread_model.zig");
const article = @import("article.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Ancestor = main.Ancestor;
const AppUi = main.AppUi;
const Counts = main.Counts;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const ProfileRows = main.ProfileRows;
const QuoteEntry = main.QuoteEntry;
const ThreadBlock = main.ThreadBlock;
const absoluteNoteTime = main.absoluteNoteTime;
const ancestor_body_lines = main.ancestor_body_lines;
const ancestor_bottom_pad = main.ancestor_bottom_pad;
const ancestor_chars_per_line = main.ancestor_chars_per_line;
const ancestor_identity_gap = main.ancestor_identity_gap;
const ancestor_line_height = main.ancestor_line_height;
const ancestor_row_chrome = main.ancestor_row_chrome;
const ancestor_top_pad = main.ancestor_top_pad;
const anyVerbShown = main.anyVerbShown;
const arrangeThread = main.arrangeThread;
const arrivalTableFor = main.arrivalTableFor;
const avatarDisc = main.avatarDisc;
const avatarTint = main.avatarTint;
const avatar_size = main.avatar_size;
const avatar_to_text_gap = main.avatar_to_text_gap;
const body_line_height = main.body_line_height;
const branch_more_extent = main.branch_more_extent;
const collapsedLen = main.collapsedLen;
const collectThreadIds = main.collectThreadIds;
const countHidden = main.countHidden;
const coverNotice = main.coverNotice;
const cover_notice_height = main.cover_notice_height;
const engagementFor = main.engagementFor;
const engagementRow = main.engagementRow;
const engagementRowAt = main.engagementRowAt;
const feed_row_chrome = main.feed_row_chrome;
const focal_body_scale = main.focal_body_scale;
const focal_leading_pad = main.focal_leading_pad;
const focal_row_chrome = main.focal_row_chrome;
const formatCount = main.formatCount;
const ghost_row_extent = main.ghost_row_extent;
const heldReplies = main.heldReplies;
const hgap = main.hgap;
const identityBlock = main.identityBlock;
const identityInk = main.identityInk;
const isExpanded = main.isExpanded;
const isMediaAsked = main.isMediaAsked;
const isTakenAway = main.isTakenAway;
const kindRender = main.kindRender;
const linkCard = main.linkCard;
const linkFor = main.linkFor;
const link_card_height = main.link_card_height;
const link_card_height_bare = main.link_card_height_bare;
const listening_row_extent = main.listening_row_extent;
const liveRelayCount = main.liveRelayCount;
const meAvatar = main.meAvatar;
const meta_scale = main.meta_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const nested_avatar_size = main.nested_avatar_size;
const nested_body_scale = main.nested_body_scale;
const nested_meta_scale = main.nested_meta_scale;
const nested_name_scale = main.nested_name_scale;
const nested_reply_chrome = main.nested_reply_chrome;
const noteAvatar = main.noteAvatar;
const noteBody = main.noteBody;
const noteBodyAt = main.noteBodyAt;
const noteContextItems = main.noteContextItems;
const noteCovered = main.noteCovered;
const noteFrom = main.noteFrom;
const noteGallery = main.noteGallery;
const noteIsLong = main.noteIsLong;
const noteSpans = main.noteSpans;
const note_collapse_chars = main.note_collapse_chars;
const nowSeconds = main.nowSeconds;
const op_chip_scale = main.op_chip_scale;
const orphan_note_extent = main.orphan_note_extent;
const outside_row_extent = main.outside_row_extent;
const pictureHeight = main.pictureHeight;
const picture_ask_height = main.picture_ask_height;
const pluralize = main.pluralize;
const postSecondsLeft = main.postSecondsLeft;
const pressRow = main.pressRow;
const profileLoading = main.profileLoading;
const profile_notes_max = main.profile_notes_max;
const quiet_row_extent = main.quiet_row_extent;
const quoteCardShown = main.quoteCardShown;
const quoteCovered = main.quoteCovered;
const quoteFor = main.quoteFor;
const quotePictureAspect = main.quotePictureAspect;
const quotePictureBox = main.quotePictureBox;
const quoteShowsPicture = main.quoteShowsPicture;
const quote_aside_chrome = main.quote_aside_chrome;
const quote_body_lines = main.quote_body_lines;
const quote_pill_height = main.quote_pill_height;
const quote_quiet_chrome = main.quote_quiet_chrome;
const quote_skeleton_height = main.quote_skeleton_height;
const refreshAncestorChain = main.refreshAncestorChain;
const relaysSeenFor = main.relaysSeenFor;
const replyNotifyRow = main.replyNotifyRow;
const replyTarget = main.replyTarget;
const reply_editor_height = main.reply_editor_height;
const reply_row_extent = main.reply_row_extent;
const roomVerbFill = main.roomVerbFill;
const roomVerbInk = main.roomVerbInk;
const settings_card_radius = main.settings_card_radius;
const show_more_extent = main.show_more_extent;
const showsImage = main.showsImage;
const showsLink = main.showsLink;
const splitByFollowGraph = main.splitByFollowGraph;
const stampArrival = main.stampArrival;
const stat_scale = main.stat_scale;
const textParaAt = main.textParaAt;
const threadHeader = main.threadHeader;
const threadTime = main.threadTime;
const thread_ancestor_max = main.thread_ancestor_max;
const thread_column_width = main.thread_column_width;
const thread_depth_max = main.thread_depth_max;
const thread_inset = main.thread_inset;
const thread_reply_cap = main.thread_reply_cap;
const thread_reply_chrome = main.thread_reply_chrome;
const thread_skeleton_extent = main.thread_skeleton_extent;
const timeSpans = main.timeSpans;
const vgap = main.vgap;
const viaSuffix = main.viaSuffix;
const videoCard = main.videoCard;
const window_height = main.window_height;

/// A cheap height estimate for the note at `index`, from model facts only
/// (never layout): the card's chrome, its wrapped lines, and its picture.
pub fn noteExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const model: *const Model = @ptrCast(@alignCast(context orelse return 96));
    const i: usize = @intCast(index);
    if (i >= model.notes_len) return feed_row_chrome;
    return noteRowEstimate(&model.notes[i], feed_row_chrome);
}

/// The shared card-height math behind the feed's and the thread's estimates.
/// `chrome` covers everything except the body's wrapped lines; the body wraps in
/// the 540px text column beside the 36px disc.
///
/// The line height is MEASURED, not the redesign's ratio. The mock sets the body
/// at 14.5/1.55 (22.475), but `widgetLineHeight` is `size * 1.25` with no token
/// and no per-element override anywhere in the SDK, so a body line is 18.125 here
/// and the feed reads tighter than the mock. Recorded as a wall in the plan.
pub fn noteRowEstimate(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, true);
}

/// The same, for a row that draws the body and NOTHING under it. A nested reply
/// is one: it builds an identity row and a body and stops, so pricing it for a
/// picture and a link card reported hundreds of pixels per reply it never drew.
fn noteRowEstimateBody(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, false);
}

fn noteRowEstimateWith(note: *const Note, chrome: f32, media: bool) f32 {
    const line_height: f32 = body_line_height;
    const chars_per_line: f32 = 70;
    // A covered note is its chrome and one chip: no body lines, no fold, no
    // picture, no link card and no quote, whatever it carries underneath.
    if (noteCovered(note)) {
        var covered = chrome + cover_notice_height;
        if (note.has_reply_parent) covered += line_height + 4;
        if (note.has_reposter) covered += line_height + 4;
        return covered;
    }
    // A collapsed long note shows only the fold, plus a line for "Show more".
    const collapsed = noteIsLong(note) and !isExpanded(note.id);
    const shown_chars: f32 = @floatFromInt(if (collapsed) collapsedLen(note.content(), note_collapse_chars) else note.content_len);
    const lines = @max(1, @ceil(shown_chars / chars_per_line));
    // A kind nothing can draw puts a chip where the body would be, so the row
    // is priced as that chip rather than as a line of text it does not have.
    // `@max(1, ...)` above would otherwise charge it a full line for a body of
    // length zero, which is close enough to hide in the slack and still wrong.
    const unsupported = kindRender(note.kind) == .unsupported;
    var extent = chrome + (if (unsupported) quote_pill_height else lines * line_height);
    if (collapsed) extent += line_height;
    // The reply line and its gap, priced whatever state it is in: it occupies
    // one line while it says "reply to a note" and one line once it names
    // somebody, so the row does not resize under the reader when the parent
    // resolves a moment later.
    if (note.has_reply_parent) extent += line_height + 4;
    // The line naming who passed this on, and the gap under it.
    if (note.has_reposter) extent += line_height + 4;
    if (!media) return extent;
    // A link card, once the page has answered; nothing before that.
    if (note.hasLink()) {
        if (linkFor(note.linkUrl())) |l| {
            if (l.state == .loaded) {
                extent += 3 + (if (l.description().len > 0) link_card_height else link_card_height_bare);
            }
        }
    }
    // A picture nobody asked for is one quiet chip, not a reserved box.
    if (note.hasImage()) {
        const shown = prefs.g_media_previews or isMediaAsked(note.id) or note.media_id() != 0;
        extent += (if (shown) pictureHeight(note) else picture_ask_height) + 8;
    }
    // The quote, which is only now a knowable height: the clamp is what makes it
    // one (the shot's own note beside 11f says quote rows clamp "so their height
    // is known at insert"). The bordered card it replaces was never priced at
    // all, so a feed of quoting notes reported less than it drew.
    // The card sits at its own byte span in the body, so a collapsed note shows
    // it only when the fold reaches past it, exactly as `noteBodyAt` decides.
    if (quoteCardShown(note, true)) {
        extent += quoteAsideExtent(note.quote.id);
    }
    return extent;
}

/// How tall a quote's aside draws: its margin, the identity block (the disc sets
/// it), and up to `quote_body_lines` lines of the quoted note. A quote still
/// resolving is priced at the skeleton it shows, so the row does not jump when
/// it lands.
fn quoteAsideExtent(id: [32]u8) f32 {
    const e = quoteFor(id) orelse return quote_quiet_chrome + quote_skeleton_height;
    return switch (e.state) {
        // The quiet states draw no identity block, so they do not carry its
        // chrome: only the 5 above, the sibling gap and the 2px pads. Pricing
        // them like the loaded aside over-charged every quoting row by nearly
        // three lines from first paint until its quote landed.
        .idle, .fetching => quote_quiet_chrome + quote_skeleton_height,
        .missing => quote_quiet_chrome + body_line_height,
        // The depth-1 pill, when the quoted note quotes something itself: it is
        // a row of its own under the body, and the row around it is priced.
        .loaded => blk: {
            // A covered quote swaps its body for the cover chip and draws no
            // picture; the pills under it are unchanged.
            const covered = quoteCovered(e);
            break :blk quote_aside_chrome +
                (if (covered) cover_notice_height else quoteBodyLines(e) * body_line_height) +
                (if (e.has_quote_of) quote_pill_height + 4 else 0) +
                (if (kindRender(e.kind) == .unsupported) quote_pill_height + 4 else 0) +
                (if (e.image_host_len > 0 and !covered) (if (quoteShowsPicture(e)) quotePictureBox(quotePictureAspect(e)).height else quote_pill_height) + 4 else 0);
        },
    };
}

/// The lines a cached quote's body draws, counted the way the clamp cuts them.
pub fn quoteBodyLines(e: *const QuoteEntry) f32 {
    // No body, no line. A quoted note that is nothing but a picture draws no
    // body at all, and charging it one line reserved a blank row under the name
    // that nothing ever filled.
    if (e.text_len == 0) return 0;
    var lines: usize = 1;
    var column: usize = 0;
    for (e.text_buf[0..e.text_len]) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= quote_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, quote_body_lines));
}

/// One thread level's row plan: row 0 is the root note, rows 1..n the replies
/// in conversation order, with skeleton rows (first fetch still out) or the
/// quiet empty line appended. Arena-allocated per frame so the virtual list's
/// estimate callback can price unbuilt rows from model facts.
pub const ThreadRows = struct {
    /// The model, so the composer row can read the draft and the signer state.
    model: *const Model,
    root: *const Note,
    /// The chain above the focal note, oldest first, drawn as the rows before
    /// it. Empty for a thread opened at its own root.
    ancestors: []const Ancestor,
    /// Top-level replies with their own replies folded in, so ONE row is one
    /// conversation rather than one note.
    blocks: []const ThreadBlock,
    /// How many of the in-graph blocks this page shows, and how many wait behind
    /// the line. `hidden` counts CONVERSATIONS, which is the row arithmetic;
    /// `hidden_held` counts the replies inside them, which is what the line says.
    shown: usize,
    hidden: usize,
    hidden_held: usize,
    /// Replies from outside the follow graph, held below the rest. They are never
    /// dropped: the row says how many there are and opens them.
    outside: []const ThreadBlock,
    /// How many REPLIES those blocks hold, which is what the line says. A block
    /// is one conversation: its own note, the replies drawn under it, and
    /// whatever those collapse into.
    outside_held: usize,
    outside_open: bool,
    skeletons: bool,
    empty: bool,
    /// The line that says the subscription is still open. Absent in the empty
    /// state, which says it in its own words.
    footer: bool,

    /// What sits at `index`, for both the builder and the estimator. ONE function
    /// answers it, because two parallel index walks is how a row draws itself at
    /// another row's height: every earlier version of this list had the plan
    /// written out twice and had to keep the arithmetic in step by hand.
    pub const Row = union(enum) {
        ancestor: usize,
        focal,
        composer,
        block: usize,
        show_more,
        outside_line,
        outside_block: usize,
        skeleton,
        empty,
        footer,
    };

    /// The chain, then the focal note, then the reply field, then one row per
    /// shown conversation, the lines that hold what is not shown, and the footer.
    /// The field is a ROW rather than a pinned footer because the design puts it
    /// under the note being answered, where it scrolls with the conversation
    /// instead of hovering over it.
    pub fn rowAt(self: *const ThreadRows, index: usize) Row {
        if (index < self.ancestors.len) return .{ .ancestor = index };
        var i = index - self.ancestors.len;
        if (i == 0) return .focal;
        if (i == 1) return .composer;
        i -= 2;
        if (i < self.shown) return .{ .block = i };
        i -= self.shown;
        if (self.hidden > 0) {
            if (i == 0) return .show_more;
            i -= 1;
        }
        if (self.outside.len > 0) {
            if (i == 0) return .outside_line;
            i -= 1;
            if (self.outside_open) {
                if (i < self.outside.len) return .{ .outside_block = i };
                i -= self.outside.len;
            }
        }
        if (self.skeletons) {
            if (i < thread_skeleton_rows) return .skeleton;
            i -= thread_skeleton_rows;
        }
        if (self.empty) {
            if (i == 0) return .empty;
            i -= 1;
        }
        return .footer;
    }

    pub fn count(self: *const ThreadRows) usize {
        return self.ancestors.len + 2 + self.shown + @intFromBool(self.hidden > 0) +
            @intFromBool(self.outside.len > 0) + (if (self.outside_open) self.outside.len else 0) +
            (if (self.skeletons) thread_skeleton_rows else 0) + @intFromBool(self.empty) +
            @intFromBool(self.footer);
    }
};

/// How many top-level replies a page of a thread shows, and how many more each
/// press of the line reveals. No shot states a number; twenty is a long read
/// already, and the line says exactly how many are behind it.
const thread_page_size: usize = 20;
const thread_skeleton_rows: usize = 3;

/// A cheap height estimate for one thread row, sharing the feed's note math.
/// A level's row heights, precomputed at build time and read back by the SDK
/// whenever it wants them.
///
/// The SDK RETAINS `extent_context` and calls the estimator through it long
/// after the build that supplied it returned: in a post-layout measure pass, and
/// since 0.7.2 from inside `virtualWindow` on a LATER build. Both lists used to
/// hand it an arena-allocated view context full of slices, on the reasoning that
/// the arena outlives the build. It does not outlive two: the runtime rotates a
/// small set of arenas and resets the one it is about to build into, so a
/// context handed over on build N is read on build N+2 with its slices pointing
/// at whatever the new build has since allocated there. That is a segfault in
/// `noteRowEstimateWith`, reading a Note out of a reused index, and it is what
/// took the app down on a mouse-up over a person's page.
///
/// So the retained context holds NO POINTERS. It is a table of numbers with
/// process lifetime, filled from the real row structures while they are alive
/// and valid, and read afterwards by an estimator that cannot dereference
/// anything. There is nothing left in it that a later frame can invalidate.
pub const RowExtents = struct {
    /// A tag, because the other half of the pairing cannot be checked by the
    /// compiler: `extent_context` is `?*const anyopaque` and accepts any
    /// pointer, so wiring the estimator to a view context instead of a table
    /// would read one struct as the other and hand the list garbage heights,
    /// silently. This turns that into a fallback the suite can catch.
    magic: u64 = row_extents_magic,
    heights: [row_extent_cap]f32 = [_]f32{0} ** row_extent_cap,
    len: usize = 0,

    pub fn reset(self: *RowExtents) void {
        self.len = 0;
    }

    pub fn push(self: *RowExtents, height: f32) void {
        if (self.len >= self.heights.len) return;
        self.heights[self.len] = height;
        self.len += 1;
    }

    fn at(self: *const RowExtents, index: usize) f32 {
        if (index >= self.len) return quiet_row_extent;
        return self.heights[index];
    }
};

const row_extents_magic: u64 = 0x524f57455854_4142;

/// Rows one retained table can price. A thread holds at most its cap plus the
/// rows around the replies; an article holds its body rows plus its head and
/// foot; a person's page holds as many notes as it will plus its header and
/// footer. Past it a row falls back to the quiet extent rather than being
/// priced, which is the estimate being wrong, not a crash.
const row_extent_cap = @max(thread_reply_cap * 2, @max(article.max_chunks + 2, profile_notes_max + 4));

/// Who and what is ON SCREEN in a level right now: the authors whose faces are
/// being drawn, and the notes whose pictures are.
///
/// The canvas registry holds SIXTEEN images for the whole window, split nine
/// faces, one banner and six pictures. That is ample, because only about a
/// screenful of rows is ever visible at once, and the feed has always spent it
/// that way: it marks and fetches `visibleRange()` and nothing else.
///
/// A thread and a person's page did not. They marked EVERY note in the level as
/// on screen, so in a long thread the first nine authors and the first six
/// pictures took every slot and held them: the allocator refuses to evict
/// anything marked wanted this pass, and everything was marked. Every other
/// author kept initials and every other picture stayed blank, for as long as the
/// level was open, and the bigger the thread the worse it got. This is what
/// "avatars and images do not load in big threads" was.
///
/// Filled during the build from the visible window, which is the only place that
/// knows which rows are on screen, and read on the next tick by the two passes
/// that lend slots. One frame stale, exactly like the feed's own range.
const VisibleSet = struct {
    authors: [visible_set_cap][32]u8 = undefined,
    author_count: usize = 0,
    notes: [visible_set_cap]i64 = undefined,
    note_count: usize = 0,

    pub fn reset(self: *VisibleSet) void {
        self.author_count = 0;
        self.note_count = 0;
    }

    pub fn pushAuthor(self: *VisibleSet, pubkey: [32]u8) void {
        if (self.author_count >= self.authors.len) return;
        for (self.authors[0..self.author_count]) |had| {
            if (std.mem.eql(u8, &had, &pubkey)) return;
        }
        self.authors[self.author_count] = pubkey;
        self.author_count += 1;
    }

    pub fn pushNote(self: *VisibleSet, id: i64) void {
        if (self.note_count >= self.notes.len) return;
        for (self.notes[0..self.note_count]) |had| {
            if (had == id) return;
        }
        self.notes[self.note_count] = id;
        self.note_count += 1;
    }
};

/// A screenful of rows, with the overscan the lists declare and a block's own
/// replies counted: comfortably more than can be on screen, and far fewer than a
/// long thread holds.
pub const visible_set_cap = 48;

/// One per mounted level. UI-thread only, like every other per-level cache here.
pub var g_level_visible: [thread_depth_max + 1]VisibleSet = [_]VisibleSet{.{}} ** (thread_depth_max + 1);
/// Which level is the one being READ, so the passes that lend slots spend them
/// on the level in front rather than on an occluded one underneath.
pub var g_visible_level: usize = 0;

/// One per mounted level, plus one for a person's page at that level. Levels are
/// UI-thread only, like every other per-level cache in this file.
pub var g_thread_extents: [thread_depth_max + 1]RowExtents = [_]RowExtents{.{}} ** (thread_depth_max + 1);
pub var g_profile_extents: [thread_depth_max + 1]RowExtents = [_]RowExtents{.{}} ** (thread_depth_max + 1);

/// Reads a precomputed height. The whole point is that this touches nothing but
/// its own numbers.
/// Records the authors and pictures on screen in a thread level.
///
/// A visible ROW is not one note: a block is a reply plus the replies drawn
/// under it, and all of them are on screen together. The overscan the list
/// declares is included, which is what makes a face arrive before the row
/// carrying it does.
fn recordThreadVisible(rows: *const ThreadRows, level: usize, first: usize, last: usize) void {
    const set = &g_level_visible[@min(level, g_level_visible.len - 1)];
    set.reset();
    g_visible_level = @min(level, g_level_visible.len - 1);
    var index = first;
    while (index <= last and index < rows.count()) : (index += 1) {
        switch (rows.rowAt(index)) {
            .ancestor => |ai| if (ai < rows.ancestors.len) {
                set.pushAuthor(rows.ancestors[ai].note.pubkey);
                set.pushNote(rows.ancestors[ai].note.id);
            },
            .focal => {
                set.pushAuthor(rows.root.pubkey);
                set.pushNote(rows.root.id);
            },
            .block => |bi| if (bi < rows.blocks.len) pushBlock(set, &rows.blocks[bi]),
            .outside_block => |oi| if (oi < rows.outside.len) pushBlock(set, &rows.outside[oi]),
            else => {},
        }
    }
}

fn pushBlock(set: *VisibleSet, block: *const ThreadBlock) void {
    set.pushAuthor(block.parent.pubkey);
    set.pushNote(block.parent.id);
    for (block.children) |*child| {
        set.pushAuthor(child.pubkey);
        set.pushNote(child.id);
    }
}

/// The same for a person's page: the subject owns a face first, then whichever
/// of their notes is on screen.
pub fn recordProfileVisible(rows: *const ProfileRows, level: usize, first: usize, last: usize) void {
    const set = &g_level_visible[@min(level, g_level_visible.len - 1)];
    set.reset();
    g_visible_level = @min(level, g_level_visible.len - 1);
    // The 72px face is the largest thing on the page, so the subject is first in
    // line whether or not their card is scrolled into view.
    set.pushAuthor(rows.subject());
    var index = first;
    while (index <= last and index < rows.count()) : (index += 1) {
        switch (rows.rowAt(index)) {
            .note => |ni| if (ni < rows.notes.len) {
                set.pushAuthor(rows.notes[ni].pubkey);
                set.pushNote(rows.notes[ni].id);
            },
            else => {},
        }
    }
}
pub fn rowExtentFromTable(context: ?*const anyopaque, index: u64) f32 {
    const table: *const RowExtents = @ptrCast(@alignCast(context orelse return quiet_row_extent));
    if (table.magic != row_extents_magic) return quiet_row_extent;
    return table.at(@intCast(index));
}
/// One thread row's height, measured from the live row structures.
///
/// TYPED, and deliberately: it takes a `*const ThreadRows` rather than the
/// SDK's `?*const anyopaque` callback shape, so it cannot be handed over as a
/// retained estimator. Only `rowExtentFromTable` has that shape now, and it
/// reads numbers. See `RowExtents` for what went wrong when this was the
/// callback.
fn threadRowHeight(rows: *const ThreadRows, i: usize) f32 {
    return switch (rows.rowAt(i)) {
        // An ancestor: the identity block pinned to its disc, a body clamped to
        // two lines, and the rail's segment down to the next disc.
        .ancestor => |ai| blk: {
            const a = &rows.ancestors[ai];
            const lead: f32 = if (ai == 0) ancestor_top_pad else 0;
            if (a.ghost != .none) break :blk lead + ghost_row_extent;
            break :blk lead + ancestor_row_chrome + @as(f32, @floatFromInt(a.lines)) * ancestor_line_height;
        },
        // The focal note carries the identity block, its exact-time line, the
        // stats row and the verb row on top of a body set one register up. Its
        // leading space belongs to the ancestor above it when there is one.
        .focal => noteRowEstimate(rows.root, focal_row_chrome) -
            (if (rows.ancestors.len > 0) focal_leading_pad else 0),
        // The reply field: a fixed shape whatever the thread holds.
        .composer => reply_row_extent,
        // A block is its top-level reply plus the level of conversation under it,
        // so it is priced as the sum: one reply's chrome and body, then each
        // child's.
        .block => |bi| blockExtent(&rows.blocks[bi]),
        .outside_block => |oi| blockExtent(&rows.outside[oi]),
        .show_more => show_more_extent,
        .outside_line => outside_row_extent,
        .footer => listening_row_extent,
        // A skeleton or the empty line: one fixed-shape row.
        .skeleton, .empty => thread_skeleton_extent,
    };
}

/// One conversation's height: the top-level reply, then each nested child, then
/// a line for whatever the branch continues into.
fn blockExtent(block: *const ThreadBlock) f32 {
    var extent = noteRowEstimate(block.parent, thread_reply_chrome);
    if (block.parent.parent_missing) extent += orphan_note_extent;
    for (block.children, block.deeper) |*child, deeper| {
        extent += noteRowEstimateBody(child, nested_reply_chrome) * nested_body_scale;
        if (deeper > 0) extent += branch_more_extent;
    }
    return extent;
}

/// How many lines an ancestor's clamped body wraps to: one or two, the clamp's
/// whole point.
pub fn ancestorBodyLines(note: *const Note) f32 {
    // The cover chip is a line and a half of this register tall, which two lines
    // price without ever under-reserving it.
    if (noteCovered(note)) return @floatFromInt(ancestor_body_lines);
    // No body, no line. An image-only reply is a common shape, and its content
    // is empty because the URL is lifted out of the text: pricing it at a line
    // the row never draws is space the level reports and does not fill.
    if (note.content_len == 0) return 0;
    var lines: usize = 1;
    var column: usize = 0;
    for (note.content()) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= ancestor_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, ancestor_body_lines));
}

/// One thread level's panel: header, the windowed root-and-replies list, and
/// the reply composer. Rendered for the open thread AND every ancestor still on
/// the back-stack (occluded beneath it), so each level's list stays mounted and
/// keeps its scroll offset. The list is a virtualList: only the rows in the
/// viewport are built, so a busy thread, or a stack of occluded ancestor
/// levels, stays far under the per-view widget budget (a plain scroll built
/// every reply of every level and blew straight through it). The list id is
/// the level key, so a level's scroll identity is stable as it moves between
/// current and ancestor.
pub fn threadPanel(ui: *AppUi, model: *const Model, root: *const Note, replies: []const Note, thread_loading: bool, level_key: u64, level: usize, occluded: bool) AppUi.Node {
    // While the first fetch is out with nothing in hand, a few skeleton rows say
    // "replies are coming"; once it has come back empty, a quiet line instead of
    // a lone root over blank space.
    const loading = replies.len == 0 and thread_loading;
    const empty = replies.len == 0 and !thread_loading;
    const rows_ctx = ui.arena.create(ThreadRows) catch return ui.column(.{}, .{});
    // Group first, then page: a page is twenty CONVERSATIONS, not twenty notes, so
    // a reply with a busy branch counts once.
    const grouped = groupThreadBlocks(ui, replies);
    // Replies from people the reader follows rank first; strangers are held below
    // one quiet line, never dropped. The partition is stable, so it preserves the
    // arrival and chronological order inside each tier.
    const split = splitByFollowGraph(ui, grouped, root.pubkey);
    const shown = @min(split.inside.len, model.thread_page[@min(level, model.thread_page.len - 1)] * thread_page_size);
    rows_ctx.* = .{
        .model = model,
        .root = root,
        .ancestors = ancestorsFor(ui, level, root, occluded),
        .blocks = split.inside,
        .shown = shown,
        .hidden = split.inside.len - shown,
        .hidden_held = heldReplies(split.inside[shown..]),
        .outside = split.outside,
        .outside_held = heldReplies(split.outside),
        .outside_open = model.thread_outside_open[@min(level, model.thread_outside_open.len - 1)],
        .skeletons = loading,
        .empty = empty,
        // The empty state says the same thing in its own words, so the footer
        // would only repeat it.
        .footer = !empty,
    };
    // Filled from the context while it is alive and valid, and handed to the
    // SDK in its place. See `RowExtents`.
    const table = &g_thread_extents[@min(level, g_thread_extents.len - 1)];
    table.reset();
    if (!occluded) {
        var row: usize = 0;
        const total = rows_ctx.count();
        while (row < total) : (row += 1) table.push(threadRowHeight(rows_ctx, row));
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("thread-{d}", .{level_key}),
        // Nothing to cover when nothing is drawn. A list that declares items and
        // builds none is permanently "undercovered", so the runtime answers by
        // rebuilding and re-laying out the whole view a second time, every time.
        // The feed learned this; the levels stacked under it have the same shape,
        // and at a back stack two deep or more there is always one occluded.
        .item_count = if (occluded) 0 else rows_ctx.count(),
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Thread" },
    };
    const window = ui.virtualWindow(options);
    // What is ACTUALLY on screen in this level, recorded where the row
    // structures are alive. The two passes that lend registry slots read it on
    // the next tick. See `VisibleSet`.
    if (!occluded) recordThreadVisible(rows_ctx, level, window.first_visible_index, window.last_visible_index);
    // An OCCLUDED level is behind an opaque panel: it is mounted to keep its
    // scroll offset, and nothing it builds can be seen. So it builds nothing.
    // The offset survives on the list's id and its content height, which comes
    // from the row COUNT and the estimates, not from the rows, so the walk back
    // still lands where the reader left. This is not only cheaper, it is what
    // keeps a deep back-stack inside the 1024-node ceiling: a view past it is
    // REFUSED whole, and six mounted levels of a busy thread crossed it.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = threadRowAt(ui, rows_ctx, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (occluded) ui.spacer(0) else threadHeader(ui, model),
        ui.virtualList(options, window, .{rows}),
    });
}

/// Builds the thread row at `index` (see `ThreadRows` for the plan), centred
/// like a feed row. `grow` on the wrapper is safe here: the virtual list
/// positions rows absolutely, so a growing row spreads WIDTH, exactly like the
/// feed's cards (the old plain-scroll column grew rows VERTICALLY instead,
/// which is why these wrappers were once forbidden).
fn threadRowAt(ui: *AppUi, rows_ctx: *const ThreadRows, index: usize) AppUi.Node {
    const plan = rows_ctx.rowAt(index);
    const inner = switch (plan) {
        .ancestor => |ai| ancestorRow(ui, &rows_ctx.ancestors[ai], ai == 0),
        .focal => threadRoot(ui, rows_ctx.root, rows_ctx.ancestors.len == 0),
        .composer => replyComposer(ui, rows_ctx.model, rows_ctx.root),
        // `first` draws the full-width rule under the note being answered, and
        // `last` suppresses the trailing one: a rule with nothing under it is a
        // dangling line, and its trailing space is what tips a thread that fits
        // into reporting more content than it draws. So the flags are about what
        // is ACTUALLY above and below the block, held replies included.
        .block => |bi| replyBlock(ui, &rows_ctx.blocks[bi], rows_ctx.root.pubkey, bi == 0, bi + 1 == rows_ctx.shown and rows_ctx.hidden == 0 and rows_ctx.outside.len == 0),
        .outside_block => |oi| replyBlock(ui, &rows_ctx.outside[oi], rows_ctx.root.pubkey, oi == 0 and rows_ctx.shown == 0, oi + 1 == rows_ctx.outside.len),
        .show_more => showMoreReplies(ui, rows_ctx.hidden_held),
        .outside_line => outsideGraphRow(ui, rows_ctx.outside_held, rows_ctx.outside_open),
        .footer => listeningFooter(ui),
        .empty => threadEmptyNote(ui),
        .skeleton => replySkeleton(ui),
    };
    var node = ui.row(.{ .grow = 1, .main = .center }, .{inner});
    // Stable row identity for the windowed reconciler: the note's own id, or a
    // synthetic high-bit key for the placeholder rows (their bit sits above the
    // masked 63-bit note-id space, so no collision).
    // A row with no note of its own is keyed by WHAT IT IS, not by where it sits:
    // a key folds into every descendant's identity, so keying the composer by
    // index would hand it a new identity, and drop the caret mid-typing, the
    // moment a missing ancestor resolves and every row below it shifts down.
    node.key = .{
        .int = switch (plan) {
            .focal => @intCast(rows_ctx.root.id),
            .block => |bi| @intCast(rows_ctx.blocks[bi].parent.id),
            .outside_block => |oi| @intCast(rows_ctx.outside[oi].parent.id),
            // A ghost row has no note behind it, so it takes a synthetic key like
            // the other placeholders, folding in its seat in the chain.
            .ancestor => |ai| if (rows_ctx.ancestors[ai].ghost == .none)
                @intCast(rows_ctx.ancestors[ai].note.id)
            else
                placeholderKey(@intFromEnum(std.meta.activeTag(plan)), ai),
            // Skeletons repeat, so they keep their position; every other
            // placeholder appears at most once in a level.
            .skeleton => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), index),
            else => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), 0),
        },
    };
    return node;
}

/// A key for a row with no note behind it: its kind, plus a discriminator for the
/// kinds that can repeat. The high bit sits above the masked 63-bit note-id
/// space, so it can never collide with a real note.
pub fn placeholderKey(kind: u64, nth: usize) u64 {
    return (@as(u64, 1) << 63) | (kind << 32) | @as(u64, @intCast(nth));
}

/// The open thread's replies read from the store at render time, into the arena,
/// oldest first. Used for the ANCESTOR levels (the current level reads its cached
/// `thread_notes` instead): they are occluded, so a per-frame read keeps their
/// scroll content stable without a second full reply cache. The `#e` closure
/// walk is the costly part, so its RESULT (the id set) is cached per level and
/// re-walked only when the store's event count moves; the notes themselves are
/// rebuilt into the frame arena from cheap point reads.
pub fn threadRepliesFromStore(ui: *AppUi, level: usize, root_event_id: [32]u8) []const Note {
    const store = main.g_store orelse return &.{};
    const cache = &thread_model.g_level_replies[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize) or cache.stamp != stamp or !std.mem.eql(u8, &cache.root, &root_event_id)) {
        cache.root = root_event_id;
        cache.stamp = stamp;
        cache.len = collectThreadIds(store, root_event_id, &cache.ids);
    }
    const now = nowSeconds();
    const notes = ui.arena.alloc(Note, cache.len) catch return &.{};
    var n: usize = 0;
    for (cache.ids[0..cache.len]) |id| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        notes[n] = noteFrom(se.event, now);
        n += 1;
    }
    // The SAME order the level had when it was the open thread, from the SAME
    // table: a level is mounted underneath precisely so the walk back lands where
    // the reader left it, and a second sort here would re-order the rows under an
    // offset restored for the first. This level is not fetching (its own fetch
    // finished before the reader moved on), so anything new here is genuinely
    // late and opens a batch.
    stampArrival(arrivalTableFor(level, root_event_id), notes[0..n], true);
    arrangeThread(notes[0..n], root_event_id);
    return notes[0..n];
}

/// The chain above the focal note, as rows: the ancestors in the store (oldest
/// first) with a ghost row on top when the chain does not reach the thread's
/// opening note. Built into the frame arena from the cached id list, like the
/// occluded levels' replies.
///
/// Every mounted level computes its own chain, INCLUDING the occluded ones: a
/// level's row plan has to be the same when it is beneath the current thread as
/// when it is the current thread, or its restored scroll offset would land
/// somewhere else on the way back.
fn ancestorsFor(ui: *AppUi, level: usize, focal: *const Note, occluded: bool) []const Ancestor {
    if (!focal.has_reply_parent) return &.{};
    const store = main.g_store orelse return &.{};
    if (level >= thread_model.g_ancestor_chains.len) return &.{};
    const chain = &thread_model.g_ancestor_chains[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize)) return &.{};
    if (chain.stamp != stamp or !std.mem.eql(u8, &chain.focal, &focal.event_id)) {
        refreshAncestorChain(chain, store, focal, stamp);
    }

    const ghost = @intFromBool(chain.gap != .none);
    const rows = ui.arena.alloc(Ancestor, chain.len + ghost) catch return &.{};
    if (ghost == 1) rows[0] = .{ .ghost = chain.gap, .is_root = chain.gap_is_root };
    var n: usize = ghost;
    // An occluded level draws nothing, so it reads nothing: the row count and
    // the cached line counts are the whole of what its estimates need, and its
    // content height (which is what its restored scroll offset is measured
    // against) comes out identical either way.
    if (occluded) {
        for (chain.lines[0..chain.len]) |lines| {
            rows[n] = .{ .lines = lines };
            n += 1;
        }
        return rows[0..n];
    }
    const now = nowSeconds();
    for (chain.ids[0..chain.len], chain.lines[0..chain.len]) |id, lines| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        rows[n] = .{ .note = noteFrom(se.event, now), .lines = lines };
        n += 1;
    }
    return rows[0..n];
}

/// The quiet line under a note that has no replies, so an empty thread reads as
/// "nothing here yet" rather than a lone post over a wall of blank space.
fn threadEmptyNote(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .main = .center }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "No replies yet. Yours would be the first.", .scale = stat_scale }}),
        }),
        vgap(ui, 12),
        // What the thread is doing about it, rather than a dead end: the
        // subscription is open and a reply will appear when one lands.
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = p.status_success, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = pluralize(ui, liveRelayCount(), "listening on {d} relay", "listening on {d} relays"), .monospace = true, .scale = mono_meta_scale }},
            ),
        }),
    });
}

/// A back control: a chevron, where it goes, and a press.
///
/// `ui.row`, NOT `ui.el(.data_row, ...)`, and that is the whole point of this
/// function existing. A `.data_row` does not take its width from its children:
/// it lays out at ZERO wide while its chevron and label paint outside it. The
/// row containing it then places the next sibling at the back control's own x
/// plus the gap, so the screen's title is drawn ON TOP of the thing that goes
/// back. Three headers did this, and the thread's read as one unbroken smear of
/// "Starter pack", "Thread" and "3 replies" in the same place.
///
/// The zero width is invisible to the widget tree and to mouse input, which
/// hit-tests to the label and walks UP to whatever claims the press. Only a
/// laid-out frame shows it, which is why `no control that can be pressed is
/// laid out at nothing` measures rather than inspects.
pub fn backControl(ui: *AppUi, label: []const u8, press: Msg) AppUi.Node {
    const p = theme.palette;
    return pressRow(ui, .{
        .cross = .center,
        .gap = 3,
        .padding = 4,
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Back", .focusable = true },
    }, .{
        ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
        ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_muted } }, label),
    });
}

/// What Back says it goes to, read from the same state `closeThread` acts on so
/// the two cannot disagree: the level stacked underneath, else Notifications when
/// that is the way back, else the feed.
pub fn backLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
    if (model.thread_stack_len > 0) return model.thread_stack[model.thread_stack_len - 1].backLabel(arena);
    if (model.notifications_return) return "Notifications";
    return model.scope_name();
}
/// A placeholder reply row shown while the first fetch is still out: a skeleton
/// avatar and lines the same shape a real reply takes, so the thread reads as
/// "loading" rather than "empty".
fn replySkeleton(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width }, .{
        ui.row(.{ .gap = 12, .cross = .start, .padding = 14 }, .{
            ui.el(.skeleton, .{ .width = avatar_size, .height = avatar_size }, .{}),
            ui.column(.{ .gap = 8, .grow = 1, .padding = 3 }, .{
                ui.el(.skeleton, .{ .width = 130, .height = 10 }, .{}),
                ui.el(.skeleton, .{ .height = 10 }, .{}),
                ui.el(.skeleton, .{ .width = 220, .height = 10 }, .{}),
            }),
        }),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
    });
}

/// The @handle for a thread identity line: the same label and the same ink rule
/// the feed's identity block uses (violet for a NIP-05, muted for a kind:0 name
/// or a short npub), or a thin skeleton while the profile is still loading, so the
/// line does not visibly fill in a beat later. `fill` grows the element to hang
/// the time to the far right (reply rows); the root note puts the handle on its
/// own line, so it does not.
fn identityHandle(ui: *AppUi, note: *const Note, fill: bool) AppUi.Node {
    const p = theme.palette;
    const label = note.handleLabel(ui.arena);
    const h = label.text;
    const ink = if (label.nip05) identityInk() else p.text_faint;
    if (h.len > 0) {
        return if (fill)
            ui.text(.{ .grow = 1, .style = .{ .foreground = ink } }, h)
        else
            ui.text(.{ .size = .sm, .style = .{ .foreground = ink } }, h);
    }
    // Profile still being fetched: a placeholder rather than an empty gap. Once
    // it resolves (handle or none) or we give up, this stops showing.
    if (profileLoading(note.pubkey)) {
        const bar = ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
        return if (fill) ui.row(.{ .grow = 1, .cross = .center }, .{bar}) else bar;
    }
    return if (fill) ui.spacer(1) else ui.spacer(0);
}

/// The focused root note: the same 40px avatar and 14px inset as the feed and
/// the replies (so every row's avatar and text share one left edge), set apart
/// by a slightly larger name, the name-over-handle stack, and the composer below.
fn threadRoot(ui: *AppUi, note: *const Note, leads: bool) AppUi.Node {
    const c = engagementFor(note.id);
    // A fixed-width column, centred by the scroll column's `cross = .center`. No
    // outer growing row: a `grow` child in the scroll's column grows vertically
    // and would overlap the next row. Every block inside sits 4px in, which is
    // the focal note's own inset within the reading column.
    return ui.column(.{
        .width = thread_column_width,
        .gap = 0,
        // The focal note answers a right-click like every other post. `in_thread`
        // drops "Open thread" from the list, which from the note the thread is
        // ABOUT would be an offer to arrive where the reader already is.
        .context_menu = noteContextItems(ui, note, true),
    }, .{
        // The space above the focal note, unless an ancestor row is up there: its
        // own bottom pad is the rail's segment down to this disc, and adding both
        // would break the chain's rhythm exactly where the eye follows it.
        if (leads) vgap(ui, focal_leading_pad) else ui.spacer(0),
        // The identity line, at the disc's height, with the overflow menu at the
        // far end. No timestamp here: the focal note states its time in full
        // below, where there is room to be exact.
        ui.row(.{ .gap = 0, .cross = .center }, .{
            hgap(ui, thread_inset),
            noteAvatar(ui, note),
            hgap(ui, avatar_to_text_gap),
            identityBlock(ui, note),
            ui.spacer(1),
            // No overflow trigger up here any more. Every post carries its menu
            // as the last verb under it now, this note included, and two
            // triggers keyed on the same note opened two identical menus at
            // once: the state is per NOTE, not per control.
            hgap(ui, thread_inset),
        }),
        vgap(ui, 9),
        // One register up from a feed row: this is the note being read.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                focalBody(ui, note),
                if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                vgap(ui, 9),
                focalMeta(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        vgap(ui, 12),
        focalStats(ui, c),
        focalVerbs(ui, note),
    });
}

/// The focal note's body: the SAME builder every other note uses, one register up.
/// Writing a second paragraph path here cost the embedded quote card, which is
/// exactly the kind of quiet loss a parallel implementation buys.
fn focalBody(ui: *AppUi, note: *const Note) AppUi.Node {
    return noteBodyAt(ui, note, false, focal_body_scale, theme.palette.text_focal);
}

/// When the focal note was written and how widely it is held.
///
/// The note's address used to sit here as a copyable pill, sixty characters of
/// bech32 under every focal note. It is in the note's own menu now, under
/// "Copy note address", which is where a reader looks for a thing to copy and
/// is not where a reader looks while reading.
fn focalMeta(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const seen = relaysSeenFor(note.id);
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{
                .text = if (seen > 0)
                    ui.fmt("{s} · {s}{s}", .{
                        absoluteNoteTime(ui.arena, note.created_at),
                        pluralize(ui, seen, "seen on {d} relay", "seen on {d} relays"),
                        viaSuffix(ui, note),
                    })
                else
                    // Nothing delivered it this session (it came off disk), so the
                    // line says when it was written and what wrote it, and stops.
                    ui.fmt("{s}{s}", .{ absoluteNoteTime(ui.arena, note.created_at), viaSuffix(ui, note) }),
                .monospace = true,
                .scale = mono_hint_scale,
            }},
        ),
        ui.spacer(1),
    });
}

/// The focal note's tallies, as words rather than icons: the verbs below carry
/// the actions, so these are the numbers, stated plainly.
///
/// A tally that has been turned off is GONE, not zeroed. It used to be zeroed,
/// which meant somebody who switched every count off in Settings watched the
/// feed lose its numbers and then opened a thread to "0 replies 0 reposts 0
/// likes 0 sats" across the top of it. That is worse than leaving them on: it
/// states four facts about the note, all four of them false, in the register the
/// app uses for facts. This line is nothing BUT counts, so when a count is
/// hidden there is nothing left for it to say, and when every one is hidden
/// there is nothing left for the band to say either.
fn focalStats(ui: *AppUi, c: Counts) AppUi.Node {
    const p = theme.palette;
    const stats = [_]struct { hidden: bool, count: u64, one: []const u8, many: []const u8 }{
        .{ .hidden = countHidden(.replies, .reply_counts), .count = c.replies, .one = "reply", .many = "replies" },
        .{ .hidden = countHidden(.reposts, .repost_counts), .count = c.reposts, .one = "repost", .many = "reposts" },
        .{ .hidden = countHidden(.reactions, .reaction_counts), .count = c.likes, .one = "like", .many = "likes" },
        .{ .hidden = countHidden(.zaps, .zap_totals), .count = c.zap_msat / 1000, .one = "sat", .many = "sats" },
    };
    // Two leading gaps, then at most a tally and its separating gap per stat,
    // then the trailing spacer. Counted from `stats` rather than written as the
    // 10 it currently comes to, so a fifth tally cannot outgrow its own row.
    const kids = ui.arena.alloc(AppUi.Node, 2 + stats.len * 2) catch return ui.spacer(0);
    var n: usize = 0;
    kids[n] = hgap(ui, thread_inset + 2);
    n += 1;
    kids[n] = vgap(ui, 33);
    n += 1;
    var any = false;
    for (stats) |stat| {
        if (stat.hidden) continue;
        // The gap belongs BETWEEN tallies, so it is charged by the one that
        // follows another rather than reserved by every one of them: hiding the
        // first would otherwise leave the row starting 18px further in than the
        // note above it.
        if (any) {
            kids[n] = hgap(ui, 18);
            n += 1;
        }
        kids[n] = statCount(ui, stat.count, stat.one, stat.many);
        n += 1;
        any = true;
    }
    if (!any) return ui.spacer(0);
    kids[n] = ui.spacer(1);
    n += 1;
    return ui.column(.{ .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        ui.row(.{ .cross = .center, .gap = 0 }, .{kids[0..n]}),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

fn statCount(ui: *AppUi, n: u64, singular: []const u8, plural: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{
        .{ .text = if (n == 0) "0" else formatCount(ui.arena, n), .weight = .medium, .color = .text, .scale = stat_scale },
        .{ .text = ui.fmt(" {s}", .{if (n == 1) singular else plural}), .scale = stat_scale },
    });
}

/// The focal note's verbs: the SAME row every other note carries.
///
/// It used to be two glyphs, a like and an open-on-the-web, shoved to opposite
/// ends of the column by a grow spacer. Two verbs is not the row a reader has
/// just scrolled past a screenful of, and forty pixels of nothing between them
/// reads as a row that lost its middle. The counts are left off, because the
/// stats line directly above states them in words: this is the same builder,
/// told not to repeat itself.
fn focalVerbs(ui: *AppUi, note: *const Note) AppUi.Node {
    if (!anyVerbShown()) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 2),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            engagementRowAt(ui, note, false),
        }),
        vgap(ui, 4),
    });
}
/// Groups the arranged (depth-stamped, conversation-ordered) replies into blocks.
/// The arrangement is a DFS, so a parent's subtree is contiguous: everything at
/// depth 2 until the next top-level reply is a child, and anything deeper counts
/// against the child it hangs beneath.
pub fn groupThreadBlocks(ui: *AppUi, notes: []const Note) []const ThreadBlock {
    if (notes.len == 0) return &.{};
    const blocks = ui.arena.alloc(ThreadBlock, notes.len) catch return &.{};
    const deeper_pool = ui.arena.alloc(usize, notes.len) catch return &.{};
    var block_count: usize = 0;
    var pool_used: usize = 0;
    var i: usize = 0;
    while (i < notes.len) {
        const parent = &notes[i];
        i += 1;
        const child_start = i;
        var child_count: usize = 0;
        while (i < notes.len and notes[i].depth >= 2) {
            if (notes[i].depth == 2) {
                deeper_pool[pool_used + child_count] = 0;
                child_count += 1;
            } else if (child_count > 0) {
                // Deeper than the one level shown: counted against the child whose
                // branch it continues.
                deeper_pool[pool_used + child_count - 1] += 1;
            }
            i += 1;
        }
        blocks[block_count] = .{
            .parent = parent,
            .children = notes[child_start..][0..child_count],
            .deeper = deeper_pool[pool_used..][0..child_count],
        };
        block_count += 1;
        pool_used += child_count;
    }
    return blocks[0..block_count];
}

/// How many indent steps a reply at `depth` shows. Direct replies (depth 1)
/// sit flush; each further level steps in once, capped so a long back-and-forth
/// never squeezes the text to a sliver; past the cap, deeper replies share the
/// cap's inset (the convention every threaded reader settles on).
const thread_indent_cap = 3;
const thread_indent_step: f32 = 24;

pub fn threadIndentLevels(depth: u8) usize {
    if (depth <= 1) return 0;
    return @min(@as(usize, depth - 1), thread_indent_cap);
}

/// The nesting gutter to the left of an indented reply: one fixed-width cell
/// per ancestor level, each carrying a hairline rail, so siblings at a depth
/// visibly hang off the same line. Empty (and costless) at the top level.
fn threadGutter(ui: *AppUi, levels: usize) AppUi.Node {
    if (levels == 0) return ui.spacer(0);
    const p = theme.palette;
    const cells = ui.arena.alloc(AppUi.Node, levels) catch return ui.spacer(0);
    for (cells) |*cell| {
        // The rail fills the row's height on its own via cross-axis stretch.
        cell.* = ui.row(.{ .width = thread_indent_step, .main = .center }, .{
            ui.separator(.{ .width = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
        });
    }
    return ui.row(.{}, .{cells});
}

/// One top-level reply and the level of conversation under it. The block draws
/// the reply at note size against a rail, then each of its own replies at a
/// smaller register hanging off that rail, then a line for whatever the branch
/// continues into.
///
/// The reply itself is a feed-style row, with an "OP" chip when the replier is
/// the thread's original author, seated under the note it answers by the nesting
/// gutter. The WRAPPER row carries the press and the hover wash, so every
/// horizontal pixel of the row (gutter included) opens this reply as its own
/// thread and washes as one unit; the picture and the engagement controls keep
/// their own presses as the deeper hit targets. The bottom hairline lives INSIDE
/// the content column: it starts after the gutter (so it aligns with the content
/// it separates) and the gutter's rails span the wrapper's full height across it,
/// keeping a sibling run's rail continuous.
///
/// The rail replaces the round-4 indent gutter: the redesign nests ONE level in
/// place and sends the rest to their own thread, rather than stepping every reply
/// further right until the text runs out of room.
/// One line saying this reply answers something the app does not have.
///
/// The same words the ghost row uses at the top of an ancestor chain, for the
/// same reason: the note is not claimed to be gone, only absent from here. It
/// may arrive when a relay answers.
fn orphanNote(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.appIcon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_dim } }, "clock"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "The note this answers is not on your relays yet", .scale = stat_scale }},
            ),
        }),
        vgap(ui, 6),
    });
}

pub fn replyBlock(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    const p = theme.palette;
    const note = block.parent;
    const kids = ui.arena.alloc(AppUi.Node, block.children.len * 2) catch return ui.spacer(0);
    var n: usize = 0;
    for (block.children, block.deeper) |*child, deeper| {
        kids[n] = nestedReply(ui, child, root_author);
        n += 1;
        if (deeper > 0) {
            kids[n] = branchMore(ui, child, deeper);
            n += 1;
        }
    }

    var node = ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The first block takes the full-width rule that separates the replies
        // from the note they answer; between blocks the rule is inset to the text,
        // so the rails run unbroken down the gutter.
        if (first)
            ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } })
        else
            ui.spacer(0),
        vgap(ui, 12),
        if (note.parent_missing)
            ui.row(.{ .gap = 0 }, .{ hgap(ui, thread_inset + avatar_size + avatar_to_text_gap), orphanNote(ui) })
        else
            ui.spacer(0),
        // No `cross` here: the default stretches the children, which is what
        // gives the rail a height to grow into. Pinned to the top, the disc's
        // column would be exactly as tall as the disc and the rail would draw
        // nothing at all, which is how it shipped invisible.
        // The reply's OWN row, and only it: the wash belongs to the row under the
        // pointer, and a band covering this reply plus everything nested under it
        // is one highlight over three rows.
        ui.el(.data_row, .{
            .width = thread_column_width,
            .padding = 0.01,
            .on_press = Msg{ .open_thread = note.id },
            .context_menu = noteContextItems(ui, note, false),
            .semantics = .{ .label = "Open thread" },
        }, .{
            hgap(ui, thread_inset),
            // The disc, with the rail below it: the line a reply's own replies
            // hang from. It runs to the bottom of this row and the children's
            // section picks it up from there, so the line reads as one.
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    if (isTakenAway(.replies))
                        threadTime(ui, note, true, .{}, .{ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale))})
                    else
                        ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale)),
                }),
                vgap(ui, 5),
                noteBody(ui, note, true),
                if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                vgap(ui, 8),
                engagementRow(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        // What hangs off this reply: its own replies and the line into whatever
        // the branch continues into, in the same gutter so the rail runs on.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.row(.{ .width = avatar_size, .main = .center }, .{
                ui.separator(.{ .width = 2, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.column(.{ .gap = 0 }, .{kids[0..n]}),
                vgap(ui, if (last) 4 else 12),
                // The rule between blocks starts at the text, not the window edge,
                // so the rail crosses it without a break. The last block draws
                // none: a rule with nothing under it is a dangling line, and its
                // trailing space is what tips a thread that fits into reporting
                // more content than it draws.
                if (last)
                    ui.spacer(0)
                else
                    ui.separator(.{ .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
            }),
            hgap(ui, thread_inset),
        }),
    });
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// One note in the chain above the focal note: the same disc and identity block
/// as a reply, a body clamped to two lines, and the rail running down to the next
/// disc. Pressing it focuses that note, which is how a reader walks back up a
/// conversation without leaving the thread.
///
/// The chain is drawn INLINE rather than as the stack of panels it used to be:
/// one scroll, so the ancestors read as the run-up to the note being read instead
/// of as screens behind it. The panel stack stays mounted underneath purely to
/// hold each level's scroll offset for the walk back.
pub fn ancestorRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    if (ancestor.ghost != .none) return ghostRow(ui, ancestor, first);
    const p = theme.palette;
    const note = &ancestor.note;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        // The row stretches its children (the default cross alignment), which is
        // what gives the rail a height to grow into: pinned to the top instead,
        // the avatar column would be exactly as tall as the disc and the rail
        // would draw nothing.
        // A `list_item`, which is the kind the renderer washes on hover, given an
        // explicit width so it constrains the body instead of sizing to it.
        pressRow(ui, .{
            .width = thread_column_width,
            .padding = 0.01,
            // By EVENT id: an ancestor is neither in the feed nor in the open
            // thread's replies, so the render key `open_thread` resolves through
            // would find nothing and the press would quietly do nothing.
            .on_press = Msg{ .open_event = note.event_id },
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "Focus this note", .focusable = true },
        }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                // The rail, filling whatever is left of the row: the line that
                // ties this note to the one it leads to.
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, meta_scale)),
                }),
                // The gap stays whatever the body is: it is a term of the row's
                // chrome, and dropping it would make the estimate wrong by 4px
                // for exactly the rows nothing measures.
                vgap(ui, ancestor_identity_gap),
                if (note.content_len == 0 and !noteCovered(note)) ui.spacer(0) else ancestorBody(ui, note),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// An ancestor's body, cut to two lines. The SDK has no multi-line clamp, so the
/// cut is made in the SPANS: building them from the whole text first keeps a
/// mention reading as `@name` rather than as half of a bech32 token.
fn ancestorBody(ui: *AppUi, note: *const Note) AppUi.Node {
    if (noteCovered(note)) return coverNotice(ui, note.warning(), note.id);
    const spans = clampSpansToLines(ui, noteSpans(ui, note, note.content()), ancestor_body_lines);
    return textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
}

/// `spans` cut to at most `lines` lines, with an ellipsis where the cut falls.
///
/// Lines are counted the way the estimator counts them, by characters against a
/// column width, plus every newline the text writes for itself: a note that
/// breaks its own lines is the case a character budget alone gets wrong, and it
/// is a common shape (a note that ends in a `nostr:` reference on its own line).
pub fn clampSpansToLines(ui: *AppUi, spans: []const canvas.TextSpan, lines: usize) []const canvas.TextSpan {
    const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch return spans;
    // One column of the last line belongs to the ellipsis. Cutting at the full
    // budget and THEN appending it wrapped one character onto a third line,
    // which is a line the estimator does not price and the design does not have.
    const budget = ancestor_chars_per_line - 1;
    var n: usize = 0;
    var line: usize = 1;
    var column: usize = 0;
    for (spans) |span| {
        var cut: ?usize = null;
        for (span.text, 0..) |c, i| {
            // A continuation byte is the middle of a character, not another one.
            if ((c & 0xc0) == 0x80) continue;
            if (c == '\n' or column >= budget) {
                line += 1;
                column = 0;
                if (line > lines) {
                    cut = i;
                    break;
                }
            }
            if (c != '\n') column += 1;
        }
        if (cut) |at| {
            // Back off to a word boundary, so the ellipsis follows a whole word.
            // The budget is the WHOLE span, not `at`: `collapsedLen` returns the
            // length unchanged when the text already fits, so cutting a slice at
            // its own length backs off nowhere.
            const end = collapsedLen(span.text, at);
            if (end > 0) {
                out[n] = span;
                out[n].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, span.text[0..end], " \n")});
                n += 1;
            } else if (n > 0) {
                out[n - 1].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, out[n - 1].text, " \n")});
            }
            return out[0..n];
        }
        out[n] = span;
        n += 1;
    }
    return out[0..n];
}
/// The gap at the top of the chain: a dashed seat where a note would be, saying
/// what is missing and what the app is doing about it. Never a spinner over the
/// thread, and never a claim that the note does not exist.
pub fn ghostRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    const p = theme.palette;
    const capped = ancestor.ghost == .capped;
    const headline: []const u8 = if (capped)
        "Earlier notes in this thread are not shown"
    else if (ancestor.is_root)
        "Root note not on your relays yet"
    else
        "The note this answers is not on your relays yet";
    const detail: []const u8 = if (capped)
        ui.fmt("showing the {d} nearest below", .{thread_ancestor_max})
    else
        pluralize(ui, liveRelayCount(), "asking {d} relay · fills in when one answers", "asking {d} relays · fills in when one answers");
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                // The empty seat: the canvas has no dashed strokes, so the ring is
                // an icon with its dashes baked into the geometry, with the glyph
                // stacked over it.
                ui.stack(.{ .width = avatar_size, .height = avatar_size }, .{
                    ui.appIcon(.{ .width = avatar_size, .height = avatar_size, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                    ui.column(.{ .width = avatar_size, .height = avatar_size, .main = .center, .cross = .center }, .{
                        // A runtime choice of glyph, so `appIcon` (which resolves
                        // the built-in names too) rather than comptime `icon`.
                        ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_dim } }, if (capped) "chevron-up" else "clock"),
                    }),
                }),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 2),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = headline, .scale = nested_name_scale }}),
                vgap(ui, 3),
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = detail, .monospace = true, .scale = mono_meta_scale }}),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// The line at the foot of a thread: the subscription is still open, and what
/// arrives is appended rather than shuffled into what has already been read,
/// which is the promise the reply order keeps.
pub fn listeningFooter(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const live = liveRelayCount();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The last conversation above closes at 4px (it draws no rule of its
        // own, so nothing dangles), and this makes up the rest of the step.
        vgap(ui, 8),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_row, .background = p.divider_row } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = if (live > 0) p.status_success else p.status_offline, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{
                .text = if (live > 0)
                    "listening · new replies land as relays answer, appended, never reordered"
                else
                    "no relay connected · replies land when one answers",
                .monospace = true,
                .scale = mono_meta_scale,
            }}),
        }),
        vgap(ui, 10),
    });
}

/// A reply to a reply: the one level of nesting the redesign draws in place, at a
/// smaller disc and a smaller register than the reply it answers.
fn nestedReply(ui: *AppUi, note: *const Note, root_author: [32]u8) AppUi.Node {
    const p = theme.palette;
    const is_author = std.mem.eql(u8, &note.pubkey, &root_author);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.el(.data_row, .{
            .grow = 1,
            .padding = 0.01,
            .cross = .start,
            .on_press = Msg{ .open_thread = note.id },
            .context_menu = noteContextItems(ui, note, false),
            .semantics = .{ .label = "Open thread" },
        }, .{
            avatarDisc(ui, note, nested_avatar_size),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .center }, .{
                    ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = note.author(), .weight = .medium, .scale = nested_name_scale }}),
                    // The original poster, marked in their own thread. In the
                    // author's avatar tint, so the chip reads as them.
                    if (is_author) opChip(ui, note.pubkey) else ui.spacer(0),
                    if (note.verified())
                        ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle")
                    else
                        ui.spacer(0),
                    nestedHandle(ui, note),
                    ui.spacer(1),
                    // A nested reply draws no verbs, so its time is the only way
                    // the keyboard has into it (see `threadTime`).
                    threadTime(ui, note, true, .{}, .{ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, timeSpans(ui, note, nested_meta_scale))}),
                }),
                vgap(ui, 3),
                noteBodyAt(ui, note, true, nested_body_scale, p.text_nested),
            }),
        }),
    });
}

/// The OP chip: the thread's author, marked where they answer inside it.
fn opChip(ui: *AppUi, pubkey: [32]u8) AppUi.Node {
    const tint = avatarTint(pubkey);
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = tint.bg, .border = tint.border, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = tint.glyph } }, &.{.{ .text = "OP", .weight = .medium, .monospace = true, .scale = op_chip_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// A nested reply's handle, one register below the reply it answers.
///
/// The same ladder the row above it uses, not `Note.handle`. These sit on the
/// same screen, so an author whose NIP-05 reads `dergigi@primal.net` in one and
/// `@dergigi` in the other is the app spelling one identity two ways within a
/// thread.
fn nestedHandle(ui: *AppUi, note: *const Note) AppUi.Node {
    const handle = note.handleLabel(ui.arena).text;
    if (handle.len == 0) return ui.spacer(0);
    return ui.paragraph(
        .{ .style = .{ .foreground = identityInk() } },
        &.{.{ .text = handle, .scale = nested_meta_scale }},
    );
}

/// The line that holds the strangers: how many replies came from outside the
/// follow graph, and a press that shows them. They are never deleted, only held,
/// which is what the line says.
pub fn outsideGraphRow(ui: *AppUi, count: usize, open: bool) AppUi.Node {
    const p = theme.palette;
    // The row's own padding sits INSIDE it, so the wash covers the band the shot
    // pads rather than a stripe through the middle of it. The height is stated
    // because a `list_item` carries a 28px intrinsic row floor, and this line is
    // a single 18px text line: without it the quiet line grows ten pixels looser
    // than the shot.
    return pressRow(
        ui,
        .{
            .width = thread_column_width,
            .height = outside_row_extent,
            .padding = 0.01,
            .cross = .center,
            .on_press = .toggle_outside_replies,
            .style = .{ .radius = 0 },
            // The row is a disclosure, so it says which way it is pointing: the
            // glyph, the verb in the label, and the accessible expanded state.
            .expanded = open,
            .semantics = .{ .role = .button, .label = if (open) "Hide replies from outside your graph" else "Show replies from outside your graph", .focusable = true },
        },
        .{
            hgap(ui, 52),
            // The glyph is chosen at runtime, so `appIcon` (which resolves the
            // built-in names too) rather than the comptime-checked `icon`.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_dim } }, if (open) "chevron-up" else "eye"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = pluralize(ui, count, "{d} reply from outside your graph", "{d} replies from outside your graph"), .scale = meta_scale }},
            ),
            hgap(ui, 7),
            // What the line is doing right now: holding them, or having shown
            // them. Saying "held below" under replies that are on screen would
            // be the same kind of stale label the round keeps finding.
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = if (open) "shown, below your graph" else "held below, never deleted", .monospace = true, .scale = mono_meta_scale }},
            ),
        },
    );
}

/// The line under a page of replies: how many conversations are still folded, and
/// a press that reveals the next page.
pub fn showMoreReplies(ui: *AppUi, hidden: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 12),
        // Height stated for the same reason as the held line: a `list_item` (the
        // kind that washes) carries a 28px intrinsic floor.
        pressRow(ui, .{
            .width = thread_column_width,
            .height = show_more_extent - 12 - 10,
            .padding = 0.01,
            .cross = .center,
            .on_press = .show_more_replies,
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "Show more replies", .focusable = true },
        }, .{
            hgap(ui, 52),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = pluralize(ui, hidden, "Show {d} more reply", "Show {d} more replies"), .weight = .medium, .scale = stat_scale }},
            ),
        }),
        vgap(ui, 10),
    });
}

/// What a branch continues into: how many replies hang below the level shown, and
/// a press that opens that reply as its own thread, where they all fit.
fn branchMore(ui: *AppUi, child: *const Note, deeper: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 6),
        pressRow(ui, .{
            .grow = 1,
            .height = branch_more_extent - 6,
            .padding = 0.01,
            .cross = .center,
            .on_press = Msg{ .open_thread = child.id },
            .style = .{ .radius = 0 },
            .semantics = .{ .role = .button, .label = "More in this branch", .focusable = true },
        }, .{
            // Indented to the nested rail, so the line reads as part of the branch
            // it belongs to.
            hgap(ui, nested_avatar_size + 10),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "arrow-right"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = ui.fmt("More in this branch · {d}", .{deeper}), .weight = .medium, .scale = stat_scale }},
            ),
        }),
    });
}

/// The pinned reply composer at the bottom of a thread: type a reply and send it
/// to the root note. Pre-filled with whom you are answering.
fn replyComposer(ui: *AppUi, model: *const Model, root: *const Note) AppUi.Node {
    const p = theme.palette;
    const ready = !model.reply_empty();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        // Top-aligned, because the field is taller than one line now: the avatar
        // belongs beside the first line of what you are writing, not floating in
        // the middle of a half-empty box.
        ui.row(.{ .cross = .start, .gap = 0 }, .{
            hgap(ui, thread_inset),
            meAvatar(ui, avatar_size),
            hgap(ui, avatar_to_text_gap),
            // A `textarea`, not a `text_field`: Enter inserts a newline here and
            // the primary chord submits, which is the whole point. A reply is
            // often the paragraph the note deserved, and a single line asked
            // people to write it somewhere else and paste it back.
            //
            // The pill had to go with it. A capsule only reads as one on a
            // single line; at three it becomes a lozenge with the text pushed
            // off its own corners, so the shape follows the content and matches
            // the cards everywhere else.
            ui.el(.textarea, .{
                .grow = 1,
                .height = reply_editor_height,
                .padding = 14,
                .text = model.reply_draft(),
                // By handle, as the shot addresses them: a reply is to an account,
                // and the name above already said who that is.
                .placeholder = ui.fmt("Reply to {s}…", .{replyTarget(ui, root)}),
                .on_input = AppUi.inputMsg(.reply_edit),
                .on_submit = .reply_submit,
                .style = .{ .background = p.surface_input, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 },
            }, .{}),
            hgap(ui, 10),
            // The verb sits beside the field, quiet until there is something to
            // send: an empty reply has nothing to confirm.
            pressRow(ui, .{
                .cross = .center,
                .gap = 0,
                // Pressable while it counts even though the field is now empty of
                // intent: taking it back is the whole point, so `ready` must not
                // gate the press once something is held.
                .on_press = if (ready or compose.g_reply_due_s != 0) Msg.reply_submit else null,
                .style = .{ .quiet_hover = true },
                // A button that is currently unavailable, said in the words the
                // platform has for it. `disabled` empties the widget's advertised
                // actions at the source (`semanticActions` returns nothing for a
                // disabled widget), so it announces the true thing to a screen
                // reader, "Reply, dimmed", rather than a button that is silent
                // about why pressing it does nothing.
                .disabled = !ready,
                .semantics = .{ .role = .button, .label = if (compose.g_reply_due_s != 0) "Undo" else "Reply", .focusable = ready or compose.g_reply_due_s != 0 },
            }, .{
                ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = if (ready or compose.g_reply_due_s != 0) roomVerbFill() else p.surface_rail_tile, .radius = 8, .stroke_width = 0 } }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 14),
                        vgap(ui, 30),
                        ui.paragraph(
                            .{ .style = .{ .foreground = if (ready or compose.g_reply_due_s != 0) roomVerbInk() else p.text_muted } },
                            &.{.{
                                .text = if (compose.g_reply_due_s != 0)
                                    std.fmt.allocPrint(ui.arena, "Undo · {d}", .{postSecondsLeft(compose.g_reply_due_s, nowSeconds())}) catch "Undo"
                                else
                                    "Reply",
                                .weight = .medium,
                                .scale = stat_scale,
                            }},
                        ),
                        hgap(ui, 14),
                    }),
                }),
            }),
            hgap(ui, thread_inset),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset + avatar_size + avatar_to_text_gap),
            replyNotifyRow(ui, model, root),
        }),
        vgap(ui, 10),
    });
}

/// Wraps a thread level's panel in a full-bleed opaque panel that occludes
/// whatever is beneath it (a bare column does not reliably paint its background;
/// the `.card` element does). Keyed by the level's root id so the whole level
/// keeps its identity, and its scroll offset, as levels push and pop above it.
pub fn threadOccluder(ui: *AppUi, level_key: u64, panel: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // A bare `.card` injects the house 24px content padding whenever `padding`
    // is left at zero (zero IS the unset sentinel), which framed the whole
    // thread page in a margin the feed does not have. A hair above zero opts
    // out while staying invisibly small, so the thread sits flush like the feed.
    return ui.el(.card, .{ .grow = 1, .padding = 0.01, .global_key = .{ .int = level_key }, .style = .{ .background = p.surface_window, .border = p.surface_window, .radius = 0, .stroke_width = 0 } }, .{panel});
}

/// Pretends a build put exactly these notes on screen in the front level.
pub fn recordVisibleNotesForTest(ids: []const i64) void {
    const set = &g_level_visible[0];
    set.reset();
    g_visible_level = 0;
    for (ids) |id| set.pushNote(id);
}
/// Pretends a build put exactly these authors on screen in the front level.
pub fn recordVisibleAuthorsForTest(authors: []const [32]u8) void {
    const set = &g_level_visible[0];
    set.reset();
    g_visible_level = 0;
    for (authors) |pk| set.pushAuthor(pk);
}

/// The retained tables, for a test that drops the build arena and then reads
/// them exactly as the SDK does.
pub fn threadExtentTableForTest(level: usize) *const anyopaque {
    return &g_thread_extents[@min(level, g_thread_extents.len - 1)];
}

pub fn profileExtentTableForTest(level: usize) *const anyopaque {
    return &g_profile_extents[@min(level, g_profile_extents.len - 1)];
}

pub fn rowExtentFromTableForTest(context: ?*const anyopaque, index: u64) f32 {
    return rowExtentFromTable(context, index);
}

pub fn extentTableLenForTest(context: ?*const anyopaque) usize {
    const table: *const RowExtents = @ptrCast(@alignCast(context orelse return 0));
    return table.len;
}
/// The ancestor row and one reply block, for a test that asserts what they PAINT
/// (the rail between two discs is a grown separator, so it only exists when the
/// row hands its avatar column a height, which is exactly what once went wrong).
pub fn ancestorRowForTest(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    return ancestorRow(ui, ancestor, first);
}

pub fn replyBlockForTest(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    return replyBlock(ui, block, root_author, first, last);
}

/// The rows a level can hold whose height is a fixed constant, so a test can
/// measure each one and hold its estimate to what it actually draws. Every
/// constant here was hand-calibrated once and then drifted.
pub fn ghostRowForTest(ui: *AppUi, capped: bool) AppUi.Node {
    const ancestor: Ancestor = .{ .ghost = if (capped) .capped else .missing };
    return ghostRow(ui, &ancestor, true);
}

pub fn listeningFooterForTest(ui: *AppUi) AppUi.Node {
    return listeningFooter(ui);
}

pub fn outsideGraphRowForTest(ui: *AppUi, open: bool) AppUi.Node {
    return outsideGraphRow(ui, 2, open);
}

pub fn showMoreRepliesForTest(ui: *AppUi) AppUi.Node {
    return showMoreReplies(ui, 3);
}

pub fn ancestorBodyLinesForTest(note: *const Note) f32 {
    return ancestorBodyLines(note);
}
pub fn quoteBodyLinesForTest(e: *const QuoteEntry) f32 {
    return quoteBodyLines(e);
}

pub fn noteRowEstimateForTest(note: *const Note, chrome: f32) f32 {
    return noteRowEstimate(note, chrome);
}

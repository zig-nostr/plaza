//! The note row: author, time, body, quote, and the verbs under it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const places = @import("places.zig");
const prefs = @import("prefs.zig");
const relay_conn = @import("relay_conn.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Conn = main.Conn;
const Counts = main.Counts;
const MentionRef = main.MentionRef;
const Msg = main.Msg;
const Note = main.Note;
const QuoteEntry = main.QuoteEntry;
const abbreviateNpub = main.abbreviateNpub;
const avatarRadius = main.avatarRadius;
const avatarTint = main.avatarTint;
const avatar_size = main.avatar_size;
const avatar_to_text_gap = main.avatar_to_text_gap;
const blurGrid = main.blurGrid;
const clampSpansToLines = main.clampSpansToLines;
const connHolds = main.connHolds;
const countHidden = main.countHidden;
const coverNotice = main.coverNotice;
const engagementFor = main.engagementFor;
const feedKeyOf = main.feedKeyOf;
const feed_column_width = main.feed_column_width;
const findQuoteRef = main.findQuoteRef;
const identityInk = main.identityInk;
const isEventRefStart = main.isEventRefStart;
const isHashtagChar = main.isHashtagChar;
const isTakenAway = main.isTakenAway;
const kindRender = main.kindRender;
const likeCountFor = main.likeCountFor;
const likeEntry = main.likeEntry;
const linkCard = main.linkCard;
const lookupProfile = main.lookupProfile;
const mediaSlotFor = main.mediaSlotFor;
const meta_scale = main.meta_scale;
const name_scale = main.name_scale;
const nested_body_scale = main.nested_body_scale;
const noteContextItems = main.noteContextItems;
const noteGallery = main.noteGallery;
const note_collapse_chars = main.note_collapse_chars;
const nowSeconds = main.nowSeconds;
const picture_column_width = main.picture_column_width;
const picture_default_aspect = main.picture_default_aspect;
const picture_radius = main.picture_radius;
const profileLoading = main.profileLoading;
const quoteCovered = main.quoteCovered;
const quoteFor = main.quoteFor;
const quoteMediaKey = main.quoteMediaKey;
const quoteShownText = main.quoteShownText;
const quoteSkeleton = main.quoteSkeleton;
const quote_body_lines = main.quote_body_lines;
const quote_picture_max_aspect = main.quote_picture_max_aspect;
const quote_picture_min_aspect = main.quote_picture_min_aspect;
const quote_picture_width = main.quote_picture_width;
const quote_pill_height = main.quote_pill_height;
const quote_pill_label_width = main.quote_pill_label_width;
const rearmQuoteAddress = main.rearmQuoteAddress;
const recalledAspect = main.recalledAspect;
const relayAt = main.relayAt;
const relaySlots = main.relaySlots;
const reply_context_snippet_chars = main.reply_context_snippet_chars;
const row_pad_bottom = main.row_pad_bottom;
const row_pad_side = main.row_pad_side;
const row_pad_top = main.row_pad_top;
const setAuthor = main.setAuthor;
const timeSpans = main.timeSpans;
const topicLinkFor = main.topicLinkFor;
const videoCard = main.videoCard;
const wantQuote = main.wantQuote;

/// A metadata run: the 12px register, in the ink the caller names.
fn metaText(ui: *AppUi, text: []const u8, color: canvas.Color) AppUi.Node {
    return ui.paragraph(.{ .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = meta_scale }});
}

/// The same, in a box it is not allowed to outgrow.
///
/// The width goes on the TEXT ELEMENT, not on an ancestor, and that distinction
/// is the whole fix. A definite width on the containing column does nothing: a
/// text leaf with no `wrap` measures as one line at its natural width whatever
/// its parents are, and `overflow = .ellipsis` cannot elide anything, because
/// an ellipsis needs a box to be too small for. I bounded the column, then the
/// column's parent, and the offending run measured exactly as wide both times.
/// Cuts `text` to at most `max` bytes and marks the cut with an ellipsis.
///
/// Because the engine has no max-width. `width` is a DEFINITE size: it bounds
/// the text, and it also makes the box exactly that wide whatever is in it. For
/// a leaf that owns its whole line that is precisely right. For one with a
/// neighbour it is wrong in a way that looks like a different bug: bounding a
/// profile's name that way put the verified check on the far side of the page,
/// and bounding the handle put a hand's width of nothing between it and the
/// npub. So where something sits beside the text, the string is shortened
/// instead and the box goes on hugging it.
///
/// Cuts on a UTF-8 boundary, so a name ending in an emoji or any non-Latin
/// script loses the character rather than being left as half of one.
pub fn elide(ui: *AppUi, text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return ui.fmt("{s}\u{2026}", .{text[0..end]});
}

fn metaTextIn(ui: *AppUi, text: []const u8, color: canvas.Color, width: f32) AppUi.Node {
    return ui.paragraph(.{ .width = width, .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = meta_scale }});
}

/// How much of a note's identity row belongs to the name and the handle.
///
/// The row is the identity block, a 6px gap, then the time. The time is the
/// app's own string, so it is the part that can be budgeted; the name and the
/// handle are a stranger's, so they get what is left and are held to it.
/// Sixty-four characters of display name and a hundred and twenty-eight of
/// NIP-05 both fit the buffers that receive them, which is to say both will
/// arrive eventually.
///
/// 148, and it has been wrong twice in opposite directions.
///
/// It was 124, set against "4h via Amethyst" while the real longest is
/// "11h via Damus Notedeck": a client name may be fourteen characters and an
/// age may be three. That string did not elide, it WRAPPED, onto a second line
/// the row had reserved no height for, so it painted over the handle beneath
/// and was clipped away again depending on what else was on screen. That was
/// the flicker somebody saw scrolling past it.
///
/// 136 stopped the wrap and was still too narrow: it was measured against
/// "11h" and "35m" is wider, so the same client name overflowed by eight
/// points. It did not show, because the box was definite and the engine elided
/// the tail. Now that the box hugs its text (see the paragraph that draws it),
/// an overflow has nowhere to hide, so this is measured against the widest AGE
/// as well as the longest NAME.
///
/// It cannot cover a name of fourteen wide glyphs; that would want two hundred
/// points and eat the column the name and handle live in. Such a name overflows
/// a little rather than eliding, which is the one thing this arrangement gives
/// up, and it is a `client` tag nobody ships against a row that still reads.
const time_column_width: f32 = 148;
const identity_text_width: f32 = picture_column_width - 6 - time_column_width;

/// How long a stranger's string may be where something sits BESIDE it.
///
/// Lengths, not widths, and that is the engine's doing rather than a
/// preference: `width` is definite, so it would fix the box at that size and
/// send the verified check, the npub and "follows you" off to the right of a
/// three-letter name. See `elide`.
///
/// Chosen against the column each one lives in and then measured: the sweep
/// renders these at the capacity of the buffers that hold them, so a budget
/// that is too generous fails rather than shipping.
pub const profile_name_max: usize = 28;
pub const profile_band_name_max: usize = 32;
pub const profile_handle_max: usize = 34;

/// A row that answers a press, built so the keyboard can use it.
///
/// A `row`, a `column` or a `data_row` with an `on_press` answers a click and
/// nothing else. The toolkit gives Tab a stop, a focus ring and a Return or
/// Space activation to its own controls and to `list_item`, and the layout kinds
/// get none of the three: Tab can land on one, nothing is drawn, and the key
/// does nothing. So every hand-built pressable is a `list_item`, which is the
/// toolkit's row-with-children, and this is the one place that says so. A row
/// with no press stays a plain row, because a statement is not a stop.
///
/// `list_item` insets its children by default, which a row never did, so the
/// padding is zeroed unless the caller states one. Its height floor is the
/// toolkit's row height; a caller whose row is shorter gives it a `height`.
pub fn pressRow(ui: *AppUi, options: AppUi.ElementOptions, children: anytype) AppUi.Node {
    if (options.on_press == null) return ui.row(options, children);
    var o = options;
    if (o.padding == null) o.padding = 0.01;
    return ui.el(.list_item, o, children);
}

/// A note's time, made the keyboard's way into the note's thread when nothing
/// else in the row is.
///
/// A row whose body wraps stays a `data_row` (see `pressRow`), so the row is the
/// pointer's target and cannot be a stop of its own. The Reply verb under the
/// note opens the same thread and is the stop. Where there is no Reply verb (a
/// nested reply never draws one, and a reader can take the verb away) the time
/// is, so no thread can be opened by the pointer alone. With `stop` false this
/// is the plain row it always was.
pub fn threadTime(ui: *AppUi, note: *const Note, stop: bool, options: AppUi.ElementOptions, children: anytype) AppUi.Node {
    var o = options;
    if (stop) {
        o.on_press = Msg{ .open_thread = note.id };
        o.style = .{ .radius = 4, .quiet_hover = true };
        o.semantics = .{ .role = .button, .label = "Open thread", .focusable = true };
    }
    return pressRow(ui, o, children);
}

/// Fixed empty space along ONE axis. `ui.spacer(n)` takes a GROW factor, not a
/// size, so it cannot express an inset; these are the sized counterparts, used
/// wherever the redesign asks for a step that a uniform `padding` or `gap` cannot
/// state (a row inset of 12 top, 16 sides and 14 bottom; a column whose steps are
/// 5, 8 and 10). One axis each, so a spacer in a row never claims height and one
/// in a column never claims width.
pub fn hgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .width = size }, .{});
}

pub fn vgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .height = size }, .{});
}

/// The author disc: 36px, the tint keyed off the pubkey, initials when no
/// picture has been registered. The size is the redesign's, and it is what the
/// identity block beside it is pinned to.
pub fn noteAvatar(ui: *AppUi, note: *const Note) AppUi.Node {
    // The face is the way to the person. An `avatar` is not a hit target, so the
    // press needs a box around it, and that box is sized to the disc EXACTLY:
    // the reply rail hangs on the disc's centre line, computed as
    // `thread_inset + avatar_size / 2`, so a wrapper even a pixel wider moves
    // the rail off the avatars it is supposed to connect.
    return ui.el(.list_item, .{
        .width = avatar_size,
        .height = avatar_size,
        .padding = 0.01,
        .on_press = Msg{ .open_person = note.pubkey },
        // The hit target follows the disc's own shape, or a square face wears a
        // circular hover wash.
        .style = .{ .radius = avatarRadius(avatar_size), .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Open profile", .focusable = true },
    }, .{
        avatarDisc(ui, note, avatar_size),
    });
}

/// The same disc at an explicit size, for the surfaces that draw a smaller or
/// larger one (a nested thread child, a quote pill, a profile header).
pub fn avatarDisc(ui: *AppUi, note: *const Note, size: f32) AppUi.Node {
    const tint = avatarTint(note.pubkey);
    return ui.avatar(.{
        .image = note.avatar_id(),
        .width = size,
        .height = size,
        // The radius is stated rather than left to the widget: `avatar` falls
        // back to a full pill only when the style names none, and the place's
        // `avatarStyleDefault` is exactly the case that wants to name one.
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1, .radius = avatarRadius(size) },
    }, note.initials());
}

/// The identity block: the name over the handle, in a box pinned to the avatar's
/// height so the two lines sit against the disc's top and bottom edges. The
/// second line carries the verified check only when the author's NIP-05 actually
/// resolves to their pubkey; without a handle at all the block is just the name,
/// and the box still holds its height so a row never changes shape.
///
/// The redesign insets the two lines by 1px top and bottom. Padding is uniform
/// on this engine, and a 1px horizontal inset would push the name off the body's
/// left edge, so the box takes no padding: the name sits 1px higher and the
/// handle 1px lower than the mock, and every text run stays on one rail.
pub fn identityBlock(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // DEFINITE, and definite on the LEAF as well as the box.
    //
    // This used to say `grow`, reasoning that the block would take the width
    // left after the timestamp and a long display name would ellipsize inside
    // it. That is not what `grow` does: it hands out SPARE space and never
    // takes any back, so a name wider than the row keeps its full width and
    // takes the handle, the time and the card's right edge with it. Sixty-four
    // characters of display name reached 354px past the window.
    //
    // ONE line. The block is as tall as the disc and holds the name over the
    // handle, so a name that wrapped onto a second line drew the handle over
    // its own second line and the body under it. A paragraph built from spans
    // does not elide at its width, so the name is cut by width units first.
    return ui.column(.{ .height = avatar_size, .width = identity_text_width, .main = .space_between }, .{
        ui.paragraph(
            .{ .width = identity_text_width, .wrap = false, .style = .{ .foreground = p.text_primary } },
            &.{.{ .text = elideUnits(ui, note.author(), identity_name_units), .weight = .medium, .scale = name_scale }},
        ),
        handleLine(ui, note),
    });
}

pub fn identityBlockForTest(ui: *AppUi, note: *const Note) AppUi.Node {
    return identityBlock(ui, note);
}

/// How much of a display name the identity line shows, in width units (a
/// narrow character is one, a wide one two; see `elideUnits`). Measured against
/// `identity_text_width` at the name's size: 48 narrow characters of an
/// ordinary name fill about 340 of its 386 points, and a name set in capitals
/// that runs past the block still stops short of the time at the row's end.
const identity_name_units = 48;

/// `text` cut to `units` width units with an ellipsis where it was cut. A
/// character from U+2E80 up (CJK, emoji) counts two, because it draws about
/// twice as wide as a Latin letter and a cap on codepoints alone would let a
/// line of them run twice as far.
pub fn elideUnits(ui: *AppUi, text: []const u8, units: usize) []const u8 {
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch break;
        const w: usize = if (cp >= 0x2E80) 2 else 1;
        if (used + w > units) {
            return ui.fmt("{s}\u{2026}", .{std.mem.trimEnd(u8, text[0..i], " ,")});
        }
        used += w;
        i += len;
    }
    return text[0..i];
}

/// The identity block's second line: the verified check, then the handle. The
/// check appears only when the author's NIP-05 resolved back to their pubkey, so
/// a claimed identity never wears a mark it has not earned.
fn handleLine(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // Checked BEFORE the label: a profile in flight shows the bar, never a
    // placeholder handle that swaps a beat later.
    if (profileLoading(note.pubkey)) return ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
    const label = note.handleLabel(ui.arena);
    if (label.text.len == 0) return ui.spacer(0);
    // Bounded, and bounded by LESS when a check sits in front of it, so the two
    // together fit the block rather than the handle alone fitting it.
    const room = if (note.verified()) identity_text_width - 12 - 5 else identity_text_width;
    const handle = metaTextIn(ui, label.text, if (label.nip05) identityInk() else p.text_faint, room);
    // The check and its 5px gap exist only when there IS a check. A row gap is
    // charged for every flow child, so substituting a zero-width spacer for the
    // glyph would still indent the handle 5px past the name's rail.
    if (!note.verified()) return handle;
    return ui.row(.{ .gap = 5, .cross = .center }, .{
        ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.status_success } }, "check-circle"),
        handle,
    });
}

/// How wide one verb's slot is, and how big its glyph is.
///
/// A SLOT, not a gap, and that is the whole point. The verbs used to sit in a
/// row with a 30px gap and a count beside each glyph, so the width of every
/// count pushed everything after it along: the heart landed at a different x on
/// every note in the feed, and a column of notes read as a column of rows that
/// could not agree where anything went. A fixed slot per verb puts every glyph
/// in the same column down the whole feed, whatever the counts do inside it.
///
/// 64 holds the glyph, its gap and the widest count `formatCount` can produce
/// (`999.9k`) without the next slot moving.
const verb_slot_width: f32 = 64;
/// And how tall. The row used to be exactly as tall as its glyphs measured
/// (18.125), so the verbs sat hard against the rule above them and the row
/// below: a strip of icons rather than a row of controls. This is the same
/// height the chrome gives its own pressable rows.
pub const verb_slot_height: f32 = 30;
const verb_icon_size: f32 = 15;

/// The engagement row: reply, repost and like, in that fixed order, each an icon
/// and its crowd count (the count omitted at zero), then the note's zap total as
/// a plain figure.
///
/// It used to carry two more. A bookmark, which had nothing behind it and was
/// drawn quiet to say so, and an ellipsis that opened the note's menu. Both are
/// gone. The bookmark was a control that could only ever disappoint somebody who
/// pressed it, and the ellipsis offered exactly what a right-click on the row
/// already offers, so it was a second door to one room, taking up a slot and a
/// hit target to get there. The right-click menu is the door now
/// (`noteContextItems`), on every row and on the focal note.
///
/// Reply, repost and like work. The zap total is only a figure: Plaza cannot
/// send a zap yet, so it is drawn as text rather than as a control that
/// answers a press with nothing.
pub fn engagementRow(ui: *AppUi, note: *const Note) AppUi.Node {
    if (!verbRowShown(note)) return ui.spacer(0);
    return engagementRowAt(ui, note, true);
}

/// Whether a note's row (with its counts) draws anything: a verb, or a zap
/// total on its own. Turning the three verbs off while keeping zaps on is a
/// reader asking for the totals and nothing else, so the row stays for a note
/// that has one. The count table is only read in that case, which is rare: with
/// any verb on, the row is drawn anyway.
fn verbRowShown(note: *const Note) bool {
    if (anyVerbShown()) return true;
    return zapTotalSats(engagementFor(note.id), true) > 0;
}

/// A note's zap total in sats as the row draws it, or 0 when there is none to
/// draw: zaps taken away, the totals hidden, or a row told to leave its counts
/// off.
fn zapTotalSats(c: Counts, counts: bool) u64 {
    if (isTakenAway(.zaps) or !counts or countHidden(.zaps, .zap_totals)) return 0;
    return c.zap_msat / 1000;
}

/// Whether the verb row has anything left to draw.
///
/// Three verbs, each removable in Settings. The zap total is not one of them: it
/// is a figure that exists on some notes and not others, so counting it here
/// would keep an empty row, and the band of nothing above it, on every note
/// that has none.
pub fn anyVerbShown() bool {
    return !isTakenAway(.replies) or !isTakenAway(.reposts) or !isTakenAway(.reactions);
}

/// The same row, told whether to carry its counts. The focal note in a thread
/// does not: the stats line above it already states every one of them in words,
/// and a number said twice in two registers is the second one looking like a
/// control.
pub fn engagementRowAt(ui: *AppUi, note: *const Note, counts: bool) AppUi.Node {
    const p = theme.palette;
    const glyph = AppUi.ElementOptions{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = p.text_metric } };
    const c = engagementFor(note.id);
    return ui.row(.{ .gap = 0, .cross = .center }, .{
        // Reply opens the note's thread, where the pinned composer answers it.
        // It is also the keyboard's way into that thread, because the note row
        // around it is a pointer target only (see `threadTime`).
        if (isTakenAway(.replies)) ui.spacer(0) else verbSlot(ui, verbWithCount(ui, ui.appIcon(glyph, "reply"), if (counts and !countHidden(.replies, .reply_counts)) c.replies else 0, p.text_metric, .{
            .on_press = Msg{ .open_thread = note.id },
            .style = .{ .quiet_hover = true },
            .semantics = .{ .role = .button, .label = "Reply", .focusable = true },
        })),
        if (isTakenAway(.reposts)) ui.spacer(0) else verbSlot(ui, repostAction(ui, note, c, counts)),
        if (isTakenAway(.reactions)) ui.spacer(0) else verbSlot(ui, likeAction(ui, note, counts)),
        // Plaza cannot send a zap yet, so the total is a figure and not a verb:
        // no bolt, no hover, nothing to press. It is the summed sats (msat /
        // 1000), and nothing at all when there are none or the count is hidden.
        zapTotal(ui, zapTotalSats(c, counts)),
    });
}

/// What a note was zapped, as plain text in the verb row. Read-only on purpose:
/// it carries no press, no hover and no role, and draws no icon, so it cannot be
/// mistaken for the verbs beside it. Absent at zero rather than "0 sats".
fn zapTotal(ui: *AppUi, sats: u64) AppUi.Node {
    if (sats == 0) return ui.spacer(0);
    return ui.row(.{ .height = verb_slot_height, .cross = .center, .gap = 0 }, .{
        metaText(ui, ui.fmt("{s} {s}", .{ formatCount(ui.arena, sats), if (sats == 1) "sat" else "sats" }), theme.palette.text_metric),
    });
}

/// One verb in its slot: the control at the left, the rest of the slot empty.
///
/// The slot is a fixed-width container rather than a fixed-width CONTROL, so a
/// press still has to land on the glyph and its count. A 64-wide hit target
/// would reach across the space between two verbs and answer for its neighbour,
/// and the neighbour of the heart is a glyph that does nothing yet: aiming at
/// the inert one and landing on the live one would publish a reaction.
fn verbSlot(ui: *AppUi, inner: AppUi.Node) AppUi.Node {
    return ui.row(.{ .width = verb_slot_width, .height = verb_slot_height, .cross = .center, .gap = 0 }, .{inner});
}

/// A verb's glyph and its count, as one control.
///
/// The count is left OUT of the children rather than substituted with an empty
/// node when it is zero. Both a row gap and a widget node are charged per flow
/// child whether or not it draws anything, and most notes in a feed carry zero
/// on most of these: a placeholder per empty count came to a tenth of the
/// window's whole widget budget across a screen of rows.
fn verbWithCount(ui: *AppUi, glyph: AppUi.Node, count: u64, color: canvas.Color, options: AppUi.ElementOptions) AppUi.Node {
    var kids: [2]AppUi.Node = undefined;
    kids[0] = glyph;
    var n: usize = 1;
    if (count > 0) {
        kids[1] = metaText(ui, formatCount(ui.arena, count), color);
        n = 2;
    }
    var opts = options;
    opts.gap = 6;
    opts.cross = .center;
    return pressRow(ui, opts, .{kids[0..n]});
}

/// A count beside an action icon, or nothing at zero (so the icon stands alone
/// rather than showing a "0").
fn countLabel(ui: *AppUi, n: u64, color: canvas.Color) AppUi.Node {
    // `ui.spacer(0)` would still be charged the row's 6px gap, leaving a hole
    // where the count is not, so a zero count collapses the gap too.
    if (n == 0) return ui.el(.stack, .{ .width = 0, .height = 0 }, .{});
    return metaText(ui, formatCount(ui.arena, n), color);
}

/// The like control: a pressable heart and its count. Liked is never colour
/// alone (spec): the glyph fills red AND the count turns red together. The count
/// is the crowd's likes plus this session's own optimistic +1, which is dropped
/// once our own reaction comes back through the subscription (so it is not
/// counted twice).
fn likeAction(ui: *AppUi, note: *const Note, counts: bool) AppUi.Node {
    // Our own reaction id (if we liked this note), so the count can retire the
    // optimistic +1 once the reaction is folded into the crowd total.
    const my_reaction: ?[32]u8 = if (likeEntry(note.id)) |e| e.reaction_id else null;
    const liked = my_reaction != null;
    const count = likeCountFor(note.id, my_reaction);
    const tint = if (liked) theme.palette.status_like else theme.palette.text_metric;
    // Hidden means the NUMBER goes, not the verb. You can still like a note
    // with the count taken away; what you lose is being told how many others
    // did, which is the part the preference is about.
    const shown = if (counts and !countHidden(.reactions, .reaction_counts)) count else 0;
    return verbWithCount(ui, ui.appIcon(.{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = tint } }, "like"), shown, tint, .{
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .like = note.id },
        .semantics = .{ .role = .button, .label = if (liked) "Unlike" else "Like", .focusable = true },
    });
}

/// The repost verb: pressable, and tinted once it is ours.
///
/// The tint is the same success green a repost notification uses, so the one
/// colour means the same thing in both places.
fn repostAction(ui: *AppUi, note: *const Note, c: Counts, counts: bool) AppUi.Node {
    const tint = if (c.reposted_by_me) theme.palette.status_success else theme.palette.text_metric;
    return verbWithCount(ui, ui.icon(.{ .width = verb_icon_size, .height = verb_icon_size, .style = .{ .foreground = tint } }, "repeat"), if (counts and !countHidden(.reposts, .repost_counts)) c.reposts else 0, tint, .{
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .repost = note.id },
        .semantics = .{ .role = .button, .label = if (c.reposted_by_me) "Reposted" else "Repost", .focusable = true },
    });
}

/// Formats an engagement count: the integer below 1000, one-decimal `k` above,
/// and empty at zero so the caller draws the icon alone rather than a "0".
pub fn formatCount(arena: std.mem.Allocator, n: u64) []const u8 {
    if (n == 0) return "";
    if (n < 1000) return std.fmt.allocPrint(arena, "{d}", .{n}) catch "";
    const k = @as(f64, @floatFromInt(n)) / 1000.0;
    return std.fmt.allocPrint(arena, "{d:.1}k", .{k}) catch "";
}

// Which long notes the reader has expanded past the "Show more" fold, by note
// id. Session-only and small: few notes are open at once, so a linear set with
// LRU-ish eviction is plenty. Id 0 marks an empty slot (a note's id is masked
// non-negative and never 0 in practice, the same sentinel `viewing_thread` uses).
const expanded_cap = 64;
/// The pictures the reader has asked for while previews are off. A per-note UI
/// fact, so it lives beside the reader rather than on the Note, which is rebuilt
/// from the store on every refresh. Oldest asked is dropped when it fills, the
/// same shape as the expanded-notes ring.
pub const asked_cap = 32;
pub var g_media_asked = [_]i64{0} ** asked_cap;

pub fn isMediaAsked(note_id: i64) bool {
    for (g_media_asked) |a| {
        if (a == note_id) return true;
    }
    return false;
}

pub fn askForMedia(note_id: i64) void {
    if (isMediaAsked(note_id)) return;
    for (&g_media_asked) |*a| {
        if (a.* == 0) {
            a.* = note_id;
            return;
        }
    }
    std.mem.copyForwards(i64, g_media_asked[0 .. asked_cap - 1], g_media_asked[1..]);
    g_media_asked[asked_cap - 1] = note_id;
}
/// The covered notes the reader has uncovered, by note id.
///
/// Session-only and per note, deliberately: a warning is about one note, so
/// pressing it must not carry to the next launch or to any other note. A ring
/// like the two above, oldest dropped when it fills, which re-covers a note the
/// reader uncovered long ago and has since scrolled far away from.
pub const uncovered_cap = 64;
pub var g_uncovered = [_]i64{0} ** uncovered_cap;

pub fn isUncovered(note_id: i64) bool {
    for (g_uncovered) |u| {
        if (u == note_id) return true;
    }
    return false;
}

pub fn uncoverNote(note_id: i64) void {
    if (note_id == 0 or isUncovered(note_id)) return;
    for (&g_uncovered) |*u| {
        if (u.* == 0) {
            u.* = note_id;
            return;
        }
    }
    std.mem.copyForwards(i64, g_uncovered[0 .. uncovered_cap - 1], g_uncovered[1..]);
    g_uncovered[uncovered_cap - 1] = note_id;
}
/// Whether something the author marked sensitive is covered right now: the
/// author asked, the reader has not turned the warnings off, and has not pressed
/// this one. The ONE answer every surface asks, so the text, the pictures, the
/// link card, the fetches and the row's height cannot disagree about it.
pub fn warningCovered(warned: bool, key: i64) bool {
    return warned and !prefs.g_show_sensitive and !isUncovered(key);
}

/// Whether `note` is covered. Its pictures and link are covered with it, and
/// nothing is fetched for them while it is.
pub fn noteCovered(note: *const Note) bool {
    return warningCovered(note.warned, note.id);
}

/// A covered note draws no picture and no link card, whatever it carries.
pub fn showsImage(note: *const Note) bool {
    return note.hasImage() and !noteCovered(note);
}

pub fn showsLink(note: *const Note) bool {
    return note.hasLink() and !noteCovered(note);
}

var g_expanded = [_]i64{0} ** expanded_cap;

pub fn isExpanded(note_id: i64) bool {
    for (g_expanded) |e| {
        if (e == note_id) return true;
    }
    return false;
}

/// Toggles whether `note_id`'s long body is expanded. Evicts the oldest slot
/// when the (generous) set is full rather than refusing to expand.
pub fn toggleExpanded(note_id: i64) void {
    for (&g_expanded) |*e| {
        if (e.* == note_id) {
            e.* = 0;
            return;
        }
    }
    for (&g_expanded) |*e| {
        if (e.* == 0) {
            e.* = note_id;
            return;
        }
    }
    g_expanded[0] = note_id;
}

/// The byte length of `text` to show collapsed: the whole thing when it is not
/// long, else a prefix near `max` that ends on a codepoint boundary and, when
/// one is close, a word boundary, so the fold never cuts mid-word or mid-glyph.
pub fn collapsedLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var end = max;
    // Back to the start of a codepoint (never mid-sequence).
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    // Prefer the last space/newline in the final quarter, so a word stays whole.
    const floor = (max * 3) / 4;
    var w = end;
    while (w > floor and text[w - 1] != ' ' and text[w - 1] != '\n') w -= 1;
    if (w > floor) end = w;
    return end;
}

/// Whether a note is long enough to collapse: comfortably past the fold, so a
/// note only a line or two over is shown whole rather than hiding a few words.
pub fn noteIsLong(note: *const Note) bool {
    return note.content_len > note_collapse_chars + 80;
}

/// A styled body paragraph, the same shape everywhere text is rendered.
fn textPara(ui: *AppUi, spans: []const canvas.TextSpan) AppUi.Node {
    return textParaAt(ui, spans, 1, theme.palette.text_body);
}

/// The same paragraph at a stated register and ink: the thread's focal note reads
/// one step up from a feed row, and a shade brighter.
pub fn textParaAt(ui: *AppUi, spans: []const canvas.TextSpan, scale: f32, ink: canvas.Color) AppUi.Node {
    // A paragraph one step DOWN is asked for by its SIZE, never by scaling
    // every span in it, and the difference is a point of vertical position.
    //
    // The line box and the baseline come from `size * max(1, largest span
    // scale)`. That floor of 1 is the whole problem: a paragraph whose spans
    // are all scaled DOWN is still boxed and baselined as though it were full
    // size, so the nested register drew 13.5pt text on a 14.5pt baseline inside
    // an 18.125pt box instead of a 13.5pt baseline in a 16.875pt one. A point
    // lower than the text around it, with a point and a quarter of extra air
    // above, which is what a reply's context line looked like next to the note
    // it belongs to.
    //
    // `.sm` is `body_size - 1`, which is exactly the 13.5 the ratio was
    // approximating, and the spans then sit at scale 1 of a genuinely smaller
    // paragraph. Scaling UP is unaffected and stays a scale: the floor only
    // bites below 1.
    if (scale == nested_body_scale) {
        return ui.paragraph(.{
            .size = .sm,
            .wrap = true,
            .on_link = AppUi.linkMsg(.open_url),
            .style = .{ .foreground = ink },
        }, spans);
    }
    const sized = if (scale == 1) spans else blk: {
        const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch break :blk spans;
        for (spans, out) |src, *dst| {
            dst.* = src;
            // A span that already states its own scale keeps its ratio to the
            // body around it.
            dst.scale = (if (src.scale == 0) 1 else src.scale) * scale;
        }
        break :blk out;
    };
    return ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = ink } }, sized);
}

/// A note's body: the styled text, an embedded quote card where the note quotes
/// another event, and a "Show more" affordance when it is long (unless the reader
/// has expanded it, or `collapsible` is false, as for a thread's focused root).
/// The body splits around the quoted event's raw token (its byte span), never
/// cutting the card; a quote at or past the fold appears only once expanded.
pub fn noteBody(ui: *AppUi, note: *const Note, collapsible: bool) AppUi.Node {
    return noteBodyAt(ui, note, collapsible, 1, theme.palette.text_body);
}

/// The body at a stated register: everything above, one step larger, for the note
/// a thread is about.
pub fn noteBodyAt(ui: *AppUi, note: *const Note, collapsible: bool, scale: f32, ink: canvas.Color) AppUi.Node {
    const p = theme.palette;
    // The author's warning replaces the whole body: the words, the quote card
    // and the fold with it. One chip, in the space the body would have taken.
    if (noteCovered(note)) return coverNotice(ui, note.warning(), note.id);
    // A kind nothing here can draw says which kind, where the body would be.
    // `noteFrom` leaves the body empty for these, and an empty paragraph is
    // what made such a card read as a note that had failed to load rather than
    // as one this app was never going to draw.
    if (kindRender(note.kind) == .unsupported) return unsupportedKindChip(ui, note.kind);
    const full = note.content();
    const long = collapsible and noteIsLong(note);
    const expanded = long and isExpanded(note.id);
    const cut: usize = if (long and !expanded) collapsedLen(full, note_collapse_chars) else full.len;
    const q = note.quote;
    const card_end = @as(usize, q.off) + @as(usize, q.len);
    const has_card = q.kind == .event and card_end <= cut;

    // Fast path unchanged: a plain note with no fold is exactly one paragraph.
    if (!has_card and !long) return textParaAt(ui, noteSpans(ui, note, full[0..cut]), scale, ink);

    var kids: [5]AppUi.Node = undefined;
    var n: usize = 0;
    if (has_card) {
        const head = std.mem.trim(u8, full[0..q.off], " \t\r\n");
        if (head.len > 0) {
            kids[n] = textParaAt(ui, noteSpans(ui, note, head), scale, ink);
            n += 1;
        }
        rearmQuoteAddress(&q);
        kids[n] = quoteRule(ui, q.id);
        n += 1;
        const tail = std.mem.trim(u8, full[card_end..cut], " \t\r\n");
        if (tail.len > 0) {
            kids[n] = textParaAt(ui, noteSpans(ui, note, tail), scale, ink);
            n += 1;
        }
    } else {
        kids[n] = textParaAt(ui, noteSpans(ui, note, full[0..cut]), scale, ink);
        n += 1;
    }
    if (long) {
        // A deeper hit target than the row's open-thread press, so tapping it
        // toggles the fold rather than opening the thread.
        kids[n] = pressRow(ui, .{ .on_press = Msg{ .toggle_expand = note.id }, .padding = 2, .style = .{ .quiet_hover = true }, .semantics = .{ .role = .button, .label = if (expanded) "Show less" else "Show more", .focusable = true } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_secondary } }, if (expanded) "Show less" else "Show more"),
        });
        n += 1;
    }
    return ui.column(.{ .gap = 8 }, .{kids[0..n]});
}

/// The line above a reply saying what it answers.
///
/// A feed that mixes replies in with root notes shows half a conversation: an
/// answer with no question reads as a non sequitur, and worse, as though the
/// person said it unprompted. Every other client puts the missing half back,
/// and this is that line.
///
/// Deliberately ONE line and no avatar. The picture would want a registry slot,
/// and there are sixteen for the whole app; a screenful of replies would spend
/// them all on thumbnails of notes the reader is not reading. The name and the
/// opening words are what identify a conversation anyway.
pub fn replyContext(ui: *AppUi, note: *const Note) AppUi.Node {
    const e = quoteFor(note.reply_parent);
    if (e == null) {
        // The parent's cache slot was reclaimed (it is one LRU shared with
        // quotes). Ask again so the next tick fills it, and say the neutral
        // thing meanwhile rather than flickering a wrong name.
        wantQuote(note.reply_parent);
        return replyContextLine(ui, "reply to a note", "");
    }
    const q = e.?;
    if (q.state == .idle or q.state == .fetching) return replyContextLine(ui, "reply to a note", "");
    if (q.state == .missing) {
        // The same sentence the thread's ancestor row uses for the same fact,
        // because it IS the same fact.
        return replyContextLine(ui, "reply to a note not on your relays yet", "");
    }

    const name = quoteAuthorName(ui, q.pubkey);
    const label = std.fmt.allocPrint(ui.arena, "reply to {s}", .{name}) catch "reply to a note";
    return replyContextLine(ui, label, quoteShownText(q));
}

/// One muted line: who was answered, then the opening of what they said.
///
/// The snippet is a SEPARATE span so it can carry its own dimmer colour, which
/// is what keeps the name readable when the two run together. Both elide rather
/// than wrap: this is a pointer at a conversation, not a second note.
fn replyContextLine(ui: *AppUi, label: []const u8, snippet: []const u8) AppUi.Node {
    const p = theme.palette;
    var spans: [2]canvas.TextSpan = undefined;
    var n: usize = 0;
    // The name carries the weight and the snippet does not, so the two read
    // apart on one line without needing a second colour.
    spans[n] = .{ .text = label, .weight = .medium };
    n += 1;
    if (snippet.len > 0) {
        // One line's worth. The cache already clamps to `quote_text_cap`, and a
        // paragraph that elides needs less than that or it never reaches the
        // ellipsis before running out of box.
        const cut = firstLineOf(snippet, reply_context_snippet_chars);
        if (cut.len > 0) {
            spans[n] = .{ .text = std.fmt.allocPrint(ui.arena, "  {s}", .{cut}) catch "", .scale = 0 };
            n += 1;
        }
    }
    // `.sm`, not spans scaled to 13.5/14.5, and the difference is a point of
    // vertical position rather than a nicety.
    //
    // A paragraph's line box and baseline come from `size * max(1, largest span
    // scale)`. The floor of 1 is what matters: a paragraph whose spans are ALL
    // scaled DOWN is still boxed and baselined as though it were full size, so
    // this line drew its 13.5pt text on a 14.5pt baseline inside an 18.125pt box
    // instead of a 13.5pt baseline in a 16.875pt one. A point lower than the
    // text beside it, with a point and a quarter of extra air above.
    //
    // The size TOKEN says the same thing without the floor applying: `.sm` is
    // `body_size - 1`, which is exactly the 13.5 the ratio was approximating,
    // and the spans then sit at scale 1 of a genuinely smaller paragraph.
    return ui.paragraph(
        .{ .size = .sm, .width = picture_column_width, .style = .{ .foreground = p.text_muted } },
        spans[0..n],
    );
}

/// The opening of `text`, stopping at the first newline and at `max` bytes, on a
/// UTF-8 boundary. A snippet cut mid-codepoint draws a replacement glyph, which
/// is a worse thing to show than a shorter snippet.
pub fn firstLineOf(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var end = @min(trimmed.len, max);
    if (std.mem.indexOfScalar(u8, trimmed[0..end], '\n')) |nl| end = nl;
    // Back off to a character boundary by looking at the byte AT the cut, not
    // the one before it. Stripping trailing continuation bytes is not enough:
    // it leaves the lead byte they belonged to, which is a broken sequence of
    // its own. If the first EXCLUDED byte is a continuation, the cut landed
    // mid-character, so walk back until it is not.
    if (end < trimmed.len) {
        while (end > 0 and (trimmed[end] & 0xc0) == 0x80) end -= 1;
    }
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}
pub fn collectText(w: canvas.Widget, arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (w.text.len > 0) {
        try out.appendSlice(arena, w.text);
        try out.append(arena, ' ');
    }
    for (w.children) |c| try collectText(c, arena, out);
}

/// An embedded quote card for a quoted event `id`: a bordered inset showing the
/// quoted author and a truncated body, tappable to open it. Loading and
/// unavailable states are non-pressable and hold the same height, so the feed
/// never reflows as the quote resolves. The author is drawn as initials-on-tint
/// (`image = 0`), so a quote card never competes for the scarce avatar ids.
fn quoteRule(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const e = quoteFor(id);
    if (e == null or e.?.state == .idle or e.?.state == .fetching) {
        // A reused feed note (never re-parsed) whose quote slot was reclaimed by
        // a newer quote lands here with no cache entry; re-queue it so the next
        // tick resolves it again instead of showing a skeleton forever.
        if (e == null) wantQuote(id);
        return quoteAside(ui, null, quoteSkeleton(ui));
    }
    const q = e.?;
    if (q.state == .missing) {
        // "Yet", because that is now true. This card said "unavailable" from
        // when three unanswered tries ended the search for good; the search does
        // not end any more, so the card must not say it does. It is the same
        // sentence the ancestor row above a thread has always used for the same
        // situation, which is the other reason to use it.
        return quoteAside(ui, null, ui.paragraph(
            .{ .size = .sm, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = "Not on your relays yet" }},
        ));
    }

    // A synthetic note, so the quote wears the SAME identity recipe as every
    // other row instead of a second one built from the cache's parts. Writing a
    // parallel builder is what cost the focal note its quote card once already.
    const note = ui.arena.create(Note) catch return ui.spacer(0);
    note.* = .{ .pubkey = q.pubkey, .created_at = q.created_at, .kind = q.kind };
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[q.pubkey[0] >> 4], hexdigits[q.pubkey[0] & 0x0f] };
    setAuthor(note, q.pubkey);
    note.setTime(nowSeconds());
    const text = q.text_buf[0..q.text_len];
    @memcpy(note.content_buf[0..text.len], text);
    note.content_len = @intCast(text.len);
    // The quoted note's OWN reference is drawn as the pill below, so it comes
    // out of the body: left in, it is a hundred characters of bech32 that no
    // line break can split, which runs straight out of the reading column.
    findQuoteRef(note);
    if (note.quote.kind == .event) {
        const cut_start = @as(usize, note.quote.off);
        const cut_end = cut_start + @as(usize, note.quote.len);
        if (cut_end <= note.content_len) {
            const tail = note.content_buf[cut_end..note.content_len];
            std.mem.copyForwards(u8, note.content_buf[cut_start..], tail);
            note.content_len = @intCast(cut_start + tail.len);
            const trimmed = std.mem.trimEnd(u8, note.content_buf[0..note.content_len], " \n\r\t");
            note.content_len = @intCast(trimmed.len);
        }
    }

    // `grow` so the quote fills the column beside the rule: hugging its content,
    // the body wrapped at about half the width the shot gives it.
    return quoteAside(ui, id, ui.column(.{ .grow = 1, .gap = 4 }, .{
        ui.row(.{ .gap = 10, .cross = .start }, .{
            avatarDisc(ui, note, avatar_size),
            identityBlock(ui, note),
            // The same grow every other row that carries a time has. Without it
            // the time sat wherever the name left it, so it was LEFT aligned in
            // a card whose every other row is right aligned, and its right edge
            // moved with the width of the text: "1d" and "12h" ended seven
            // points apart.
            ui.spacer(1),
            ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, &.{.{ .text = note.time(), .scale = meta_scale }}),
        }),
        // Four lines of the quoted note, and no more: a quote is an aside, and
        // its height has to be known where the outer row is priced.
        if (quoteCovered(q)) coverNotice(ui, q.warning_buf[0..q.warning_len], feedKeyOf(id)) else if (q.text_len > 0) quoteBody(ui, note) else ui.spacer(0),
        // What the card cannot draw, said rather than left blank. The chip for
        // an unsupported kind sits beside the one for a picture because they
        // answer the same question: a card with a name, a time and nothing
        // under it reads as a rendering fault, and this says which it is.
        if (kindRender(q.kind) == .unsupported) unsupportedKindChip(ui, q.kind) else ui.spacer(0),
        if (q.image_host_len > 0 and !quoteCovered(q)) quoteMediaChip(ui, q) else ui.spacer(0),
        // A quote of a quote stops here. One more body would be a third voice in
        // a row, so the second hop is a pill that says where it goes.
        if (q.has_quote_of) quotingPill(ui, q.quote_of) else ui.spacer(0),
    }));
}

/// The quoted note's own words, four lines of them. Labelled, because the one
/// thing worth asserting about it is how WIDE it is: hugging its content instead
/// of filling the column beside the rule, it wrapped at about half the width the
/// shot gives it and read as a column of its own rather than an aside.
fn quoteBody(ui: *AppUi, note: *const Note) AppUi.Node {
    const spans = clampSpansToLines(ui, noteSpans(ui, note, note.content()), quote_body_lines);
    var node = textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
    node.widget.semantics.label = "Quoted note body";
    return node;
}

/// Says that an event is of a kind this app has no way to draw, and which kind.
///
/// The kind NUMBER, deliberately. A reader who sees "kind 31923" can look it up
/// or open the event somewhere that draws it; a reader looking at a blank card
/// has been told nothing, and cannot tell a kind Plaza will never draw from a
/// note that failed to load. Jumble draws the same conclusion and puts a client
/// picker next to it (`src/components/NoteContent/UnknownNote.tsx`).
fn unsupportedKindChip(ui: *AppUi, kind: u16) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .height = quote_pill_height,
            .padding = 0.01,
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 8),
                // `dashed-ring`, which is this app's placeholder glyph, used at
                // avatar size wherever there is nothing yet to draw. `appIcon`
                // takes an APP-REGISTERED name and there are ten of them; an
                // unregistered one draws the missing-icon fallback, a slashed
                // circle, with no compile error and no test failure. This said
                // "file" when it shipped, and drew exactly that.
                ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "dashed-ring"),
                hgap(ui, 6),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Plaza cannot draw a kind {d} event", .{kind}), .scale = meta_scale }},
                ),
                hgap(ui, 8),
            }),
        }),
        ui.spacer(1),
    });
}

/// Whether the card draws the picture itself rather than naming it. Previews
/// off keeps the old, honest chip (nothing is fetched, so nothing could be
/// drawn), and so does a quote with no address worth fetching.
pub fn quoteShowsPicture(q: *const QuoteEntry) bool {
    return prefs.g_media_previews and q.image_url_len > 0 and !quoteCovered(q);
}

/// The shape to reserve for a quote's picture: what its `imeta` declares, else
/// what it measured the last time it was decoded (remembered past its slot, so
/// an evicted picture does not shrink the card), else the feed's guess.
pub fn quotePictureAspect(q: *const QuoteEntry) f32 {
    if (q.image_aspect > 0) return q.image_aspect;
    return recalledAspect(quoteMediaKey(q.id)) orelse picture_default_aspect;
}

pub const QuotePictureBox = struct { width: f32, height: f32 };

/// The box a quote's picture is drawn in, for a given height over width.
///
/// Total on purpose: a note can declare any dimensions it likes and a decode can
/// report none, so zero, negative, infinite and absurd shapes all land on a box
/// the card can be priced for.
pub fn quotePictureBox(aspect: f32) QuotePictureBox {
    const shape = if (std.math.isFinite(aspect) and aspect > 0) aspect else picture_default_aspect;
    const height = quote_picture_width * std.math.clamp(shape, quote_picture_min_aspect, quote_picture_max_aspect);
    // Taller than the cap: the box is the picture's own shape at the capped
    // height, so `contain` leaves no bare gutters inside the border.
    const width = if (shape > quote_picture_max_aspect) height / shape else quote_picture_width;
    return .{ .width = width, .height = height };
}

/// The picture a quote card holds, drawn from the media slot the scan pass gave
/// it: its blurhash (or stripes) while it loads, the picture when it has arrived,
/// a plain box when it will not come. All three are the same size. A picture
/// whose note declares its shape lands without moving the card; one that does
/// not is sized by the feed's guess until it has been decoded once, as a feed
/// picture is.
///
/// With previews off, or no address worth fetching, the card names the picture
/// and where it is from instead. Not a control either way: pressing the CARD
/// already opens the quoted note, and a second press target here would only be a
/// shorter way to the same place.
fn quoteMediaChip(ui: *AppUi, q: *const QuoteEntry) AppUi.Node {
    const host = q.image_host_buf[0..q.image_host_len];

    if (quoteShowsPicture(q)) {
        const p = theme.palette;
        const box = quotePictureBox(quotePictureAspect(q));
        const slot = mediaSlotFor(quoteMediaKey(q.id));
        const inner: AppUi.Node = if (slot != null and slot.?.state == .loaded and slot.?.image_id != 0) blk: {
            var picture = ui.image(.{
                .image = slot.?.image_id,
                .grow = 1,
                .semantics = .{ .label = "Picture in the quoted note" },
            });
            picture.widget.image_fit = .contain;
            break :blk picture;
        } else if (slot != null and slot.?.state == .failed)
            ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 6 }, .{
                ui.appIcon(.{ .width = 14, .height = 14, .style = .{ .foreground = p.text_dim } }, "image"),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Picture from {s} would not load", .{host}), .scale = meta_scale }},
                ),
            })
        else
            // Its own colours when the note carries a blurhash, stripes when it
            // does not. Flat cells and not a registered image, so the wait costs
            // no registry id: the id is claimed for the picture itself.
            blurGrid(ui, q.imageBlurhash(), box.height);
        return ui.row(.{ .gap = 0 }, .{
            ui.el(.data_row, .{
                .width = box.width,
                .height = box.height,
                .padding = 0,
                .style = .{ .radius = picture_radius, .border = p.border_hairline, .stroke_width = 1, .background = p.surface_inset },
            }, .{inner}),
            ui.spacer(1),
        });
    }

    // Otherwise show a pill saying the picture is there and where it's from.
    const p = theme.palette;
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.panel, .{
            .height = quote_pill_height,
            .padding = 0.01,
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 8),
                ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "image"),
                hgap(ui, 6),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = ui.fmt("Picture from {s}", .{host}), .scale = meta_scale }},
                ),
                hgap(ui, 8),
            }),
        }),
        ui.spacer(1),
    });
}

/// 11g's pill: where the quoted note's own quote goes, one hop, as a line rather
/// than a third nested body. Pressing it walks that hop.
fn quotingPill(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const tint = avatarTint(quotingPillAuthor(id));
    const hexdigits = "0123456789abcdef";
    const author = quotingPillAuthor(id);
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = quote_pill_height,
            .cross = .center,
            .on_press = Msg{ .open_event = id },
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Quoted note inside it", .focusable = true },
        }, .{
            hgap(ui, 4),
            ui.avatar(.{
                .image = 0,
                .width = 14,
                .height = 14,
                .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
            }, ui.fmt("{c}{c}", .{ hexdigits[author[0] >> 4], hexdigits[author[0] & 0x0f] })),
            hgap(ui, 6),
            // ONE line, elided at the tail: the pill says where the hop goes and
            // begins what it says, and a long note may not push the row wider.
            // `wrap = false` is what makes the single-line overflow policy apply.
            ui.text(.{
                .width = quote_pill_label_width,
                .wrap = false,
                .overflow = .ellipsis,
                .size = .sm,
                .style = .{ .foreground = p.text_muted_alt },
            }, quotingPillLabel(ui, id)),
            hgap(ui, 9),
        }),
        // Hugging its content, so the pill is a pill and not a bar.
        ui.spacer(1),
    });
}

/// `text` with its line breaks folded into spaces, for a control that is one
/// line by construction. A widget that measures single-line still PAINTS the
/// newlines its text carries, so an unfolded label draws its second line over
/// whatever is under the row.
pub fn oneLine(ui: *AppUi, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n") == null) return text;
    const out = ui.arena.alloc(u8, text.len) catch return text;
    var n: usize = 0;
    var last_space = false;
    for (text) |c| {
        const space = c == '\n' or c == '\r' or c == ' ' or c == '\t';
        if (space) {
            if (last_space or n == 0) continue;
            out[n] = ' ';
        } else {
            out[n] = c;
        }
        last_space = space;
        n += 1;
    }
    return out[0..n];
}
/// Whose note the pill walks to, once that note is resolved; a zero key until
/// then, which tints the disc neutrally rather than guessing.
fn quotingPillAuthor(id: [32]u8) [32]u8 {
    const e = quoteFor(id) orelse return [_]u8{0} ** 32;
    if (e.state != .loaded) return [_]u8{0} ** 32;
    return e.pubkey;
}

/// What the pill says. It names the author once that note has arrived, and says
/// plainly that it is still coming until then, rather than showing a name it
/// does not have.
pub fn quotingPillLabel(ui: *AppUi, id: [32]u8) []const u8 {
    // Re-queued when the entry is gone, the same way the aside itself does it:
    // the pill's target is asked for once, when the note holding it is filled,
    // and the 64-entry cache can evict it while the pill is still on screen. Then
    // nothing would ever ask again, because the note holding it is loaded and a
    // loaded entry is never revisited.
    const e = quoteFor(id) orelse {
        wantQuote(id);
        return "Quoting a note";
    };
    return switch (e.state) {
        // Whose note, and the start of what it says: the shot's own pill reads
        // "Quoting @edith · Shipping it: the feed renders…", so the reader can
        // tell whether the hop is worth taking before taking it.
        .loaded => switch (kindRender(e.kind)) {
            // Naming the kind beats naming the author and then showing nothing:
            // a kind whose content is empty by design drew "Quoting @somebody"
            // with a blank after it, which reads as a note that failed to load.
            .unsupported => ui.fmt("Quoting a kind {d} event", .{e.kind}),
            else => ui.fmt("Quoting {s} · {s}", .{
                quotePillHandle(ui, e.pubkey),
                if (quoteCovered(e)) "content warning" else oneLine(ui, e.text_buf[0..e.text_len]),
            }),
        },
        .missing => "Quotes a note no relay has",
        else => "Quoting a note",
    };
}

/// The handle for a pill: `@name` when the author has one, else their display
/// name, else a short npub. The pill is one line, so it names them the shortest
/// true way rather than the fullest.
fn quotePillHandle(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.nip05_len > 0) {
            const nip05 = pr.nip05();
            if (std.mem.indexOfScalar(u8, nip05, '@')) |at| {
                const local = nip05[0..at];
                const shown = if (std.mem.eql(u8, local, "_")) nip05[at + 1 ..] else local;
                if (shown.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{shown}) catch "";
            }
        }
        const user = pr.username();
        if (user.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{user}) catch "";
    }
    return quoteAuthorName(ui, pubkey);
}

/// The rule down the left of a quote, and whatever sits beside it. The redesign
/// replaces the bordered card with this: a card inside a row reads as a second
/// surface competing with the note, where the rule reads as an aside, which is
/// what a quote is.
///
/// `id` non-null makes the block open that note. The rule brightening on hover
/// (11f) is not expressible: hover is a background wash on one widget, and a
/// wash here would be a state the design does not draw.
fn quoteAside(ui: *AppUi, id: ?[32]u8, body: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // `grow` on the row, so the aside is as wide as the column it sits in. Its
    // parent is a column, where grow is the vertical axis for the WRAPPER but the
    // width for this row's own sizing: without it the row took its intrinsic
    // width, which for a long quote measured three times the window.
    const inner = ui.row(.{ .grow = 1, .gap = 0 }, .{
        // The rule takes the row's height from the default cross STRETCH. It must
        // not `grow`: grow in a row is the horizontal axis, so a growing 2px rule
        // and the growing content column split the width between them, and the
        // quote wrapped at half the space the shot gives it. The thread's rail
        // uses the same construct correctly because it sits in a COLUMN, where
        // grow is the axis it wants.
        ui.separator(.{ .width = 2, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
        hgap(ui, 12),
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            vgap(ui, 2),
            body,
            vgap(ui, 2),
        }),
    });
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 5),
        if (id) |event_id|
            // A plain row: it paints nothing, which is right, because 11f gives a
            // quote no hover state (its rule brightening is not expressible) and
            // a wash here would invent one. It also MEASURES, which `list_item`
            // does not: the width-aware measurer has no case for that kind, so a
            // wrapping quote body would measure one line tall and draw over the
            // verbs under it.
            pressRow(ui, .{
                .grow = 1,
                // By EVENT id, read straight from the store: a quoted note is in
                // neither the feed nor the open thread's replies.
                .on_press = Msg{ .open_event = event_id },
                .semantics = .{ .role = .button, .label = "Quoted note", .focusable = true },
            }, .{inner})
        else
            inner,
    });
}
/// The quoted author's display name (from the profile cache) or a short npub.
fn quoteAuthorName(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.name_len > 0) return pr.name();
    }
    const buf = ui.arena.alloc(u8, 24) catch return "";
    return abbreviateNpub(buf, pubkey);
}

/// The focal note's timestamp in full: the time and the date, since a note being
/// read deserves to say exactly when it was written rather than "3h".
pub fn absoluteNoteTime(arena: std.mem.Allocator, created_at: i64) []const u8 {
    // LOCAL time, because a reader reads a clock, not an offset. Neither the SDK
    // nor the standard library carries a timezone database, so the offset comes
    // from libc, which knows the zone and the daylight rule. Off macOS (the
    // portability build) there is no such call wired, and the line says UTC
    // rather than pretending.
    const shifted = created_at + localOffsetSeconds(created_at);
    const secs: u64 = @intCast(@max(shifted, 0));
    const days = secs / 86_400;
    const day_secs = secs % 86_400;
    const hour24 = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const pm = hour24 >= 12;
    const hour12 = if (hour24 % 12 == 0) 12 else hour24 % 12;
    // Civil date from the Unix epoch, by Howard Hinnant's algorithm: exact, and
    // no dependency on a timezone database the app does not carry.
    const z = @as(i64, @intCast(days)) + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_name = months[@intCast(@min(@max(m - 1, 0), 11))];
    return std.fmt.allocPrint(arena, "{d}:{d:0>2} {s}{s} · {s} {d}, {d}", .{
        hour12, minute, if (pm) "PM" else "AM", if (comptime builtin.os.tag == .windows) " UTC" else "", month_name, d, year,
    }) catch "";
}

/// Seconds to add to a Unix timestamp to get local wall-clock time, from libc's
/// own zone handling (so daylight saving is right, and right for the DATE in
/// question rather than for today).
fn localOffsetSeconds(unix_seconds: i64) i64 {
    // Not macOS-only. `c_tm` below is laid out for the BSD and glibc `struct
    // tm` (it carries `tm_gmtoff` and `tm_zone`), and `localtime_r` is in glibc
    // as well, so a Linux build reads the reader's real zone and their real
    // daylight saving. Gated on Windows instead, which has `localtime_s` and a
    // different struct, and where this would be a link error rather than a
    // wrong answer.
    if (comptime builtin.os.tag == .windows) return 0;
    var tm: c_tm = std.mem.zeroes(c_tm);
    const t: i64 = unix_seconds;
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.tm_gmtoff;
}

/// The fields of `struct tm` this needs, in libc's order. Only `tm_gmtoff` is
/// read; the rest are here so the struct is the right size for libc to fill.
const c_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn localtime_r(timer: *const i64, result: *c_tm) ?*c_tm;

/// Who a reply is addressed to: the handle when one is known, else the display
/// name, which is all a profile without a nip05 offers.
pub fn replyTarget(ui: *AppUi, note: *const Note) []const u8 {
    const handle = note.handle(ui.arena);
    return if (handle.len > 0) handle else note.author();
}

/// One phrase or the other, by count. English, and the only two shapes the
/// chrome needs.
pub fn pluralize(ui: *AppUi, n: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return if (n == 1) ui.fmt(one, .{n}) else ui.fmt(many, .{n});
}

/// How many relays are connected right now.
pub fn liveRelayCount() usize {
    var n: usize = 0;
    for (0..relaySlots()) |i| {
        // A dormant seat is not a live relay whatever its last status said.
        if (relayAt(i) == null) continue;
        const state: Conn = @enumFromInt(relay_conn.g_relay_status[i].load(.monotonic));
        // Quiet counts. It holds a socket, its subscriptions are still open on
        // the relay, and a note published now goes out on it.
        if (connHolds(state)) n += 1;
    }
    return n;
}

/// The quoted note's relative timestamp, computed for the frame.
fn quoteTime(ui: *AppUi, created_at: i64) []const u8 {
    const dt = nowSeconds() - created_at;
    if (dt < 60) return "now";
    if (dt < 3600) return ui.fmt("{d}m", .{@divTrunc(dt, 60)});
    if (dt < 86_400) return ui.fmt("{d}h", .{@divTrunc(dt, 3600)});
    if (dt < 604_800) return ui.fmt("{d}d", .{@divTrunc(dt, 86_400)});
    return ui.fmt("{d}w", .{@divTrunc(dt, 604_800)});
}

/// One feed note: a bare row on the window, no card. Avatar column, then an
/// identity line (name, and the time hung to the right), the body, any image,
/// and the engagement row. The content is a fixed reading column centered in
/// the window, with a hairline under each row as the only separation. Keyed by
/// the note id so the list diff holds scroll position across reconciles.
/// Who passed this note on, above the card.
///
/// The reposter in the quiet colour over the author's row in the normal one,
/// which is the shape Amethyst uses: the wrapper's byline is greyed
/// (`NoteCompose.kt:2013`, `textColor = grayText` when `isRepost`) and the note
/// underneath is drawn as itself.
///
/// No icon. `appIcon` resolves an APP-REGISTERED name and this app registers
/// ten, none of them a repost glyph; an unregistered name draws the
/// missing-icon fallback rather than failing, so a word is the honest choice
/// until there is a glyph to use.
fn repostByline(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.row(.{ .gap = 0, .cross = .center }, .{
            hgap(ui, row_pad_side),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint_alt } },
                &.{.{ .text = ui.fmt("{s} reposted", .{quotePillHandle(ui, note.reposter)}), .scale = meta_scale }},
            ),
        }),
        vgap(ui, 4),
    });
}

pub fn noteCard(ui: *AppUi, note: *const Note) AppUi.Node {
    var node = ui.row(.{ .grow = 1, .main = .center }, .{
        ui.column(.{ .width = feed_column_width }, .{
            // A `list_item`, because that is the kind the renderer washes on
            // hover, and the row wash is the redesign's one hover state. It has
            // to be given an explicit WIDTH: a list_item sizes to its content,
            // and without one the body paragraph ran to its unwrapped width and
            // overflowed the reading column. Its children lay out on the
            // horizontal axis, so the single column below is what holds the
            // vertical stack. The inner controls (like, reply, links, the
            // picture) keep their own presses as the deeper hit targets.
            //
            // Every inset is stated once, on the axis that owns it: this column
            // carries the redesign's 12 above and 14 below, the row inside it
            // carries 16 on each side and the 12 between disc and text, and the
            // content column's own steps are 5, 8 and 10. A uniform `padding`
            // cannot express any of that, and a `gap` on the row would also apply
            // around each inset box, which is what threw the first attempt 12px
            // off the reading rail.
            ui.el(.data_row, .{ .width = feed_column_width, .padding = 0.01, .on_press = Msg{ .open_thread = note.id }, .context_menu = noteContextItems(ui, note, false), .semantics = .{ .label = "Open thread" } }, .{ui.column(.{ .gap = 0, .width = feed_column_width }, .{
                vgap(ui, row_pad_top),
                if (note.has_reposter) repostByline(ui, note) else ui.spacer(0),
                ui.row(.{ .gap = 0, .cross = .start }, .{
                    hgap(ui, row_pad_side),
                    noteAvatar(ui, note),
                    hgap(ui, avatar_to_text_gap),
                    // DEFINITE, not `grow`. `grow` hands out SPARE space and
                    // never takes any back, so a column whose widest child is
                    // already wider than the row keeps that width and pushes
                    // everything to its right off the card. This is the same
                    // width the picture and the link card already use, and it
                    // is what makes an ellipsis on anything inside possible:
                    // an ellipsis needs a box to be too small for.
                    ui.column(.{ .gap = 0, .width = picture_column_width }, .{
                        // The identity header: the name over the handle in a box
                        // the avatar's height, with the time hung top-right.
                        ui.row(.{ .gap = 6, .cross = .start }, .{
                            identityBlock(ui, note),
                            // Right-aligned in a stated column, so it ends at
                            // the card's edge whatever it says. Left to hug its
                            // text it began at a fixed x (the identity block
                            // beside it is a definite width) and stopped
                            // wherever it ran out, leaving a ragged gap after
                            // "6m via Damus" that grew as the string got
                            // shorter.
                            //
                            // ONE line, always. A paragraph in a stated width
                            // wraps, and a client name long enough to need a
                            // second line got one: "11h via Damus Notedeck"
                            // broke after "Damus" and hung "Notedeck" under it,
                            // into the handle's row. Scrolling then flickered it
                            // between two lines and one, because the row's
                            // height and the width this box is measured at are
                            // settled in different passes and a wrap sits right
                            // on the boundary between them. A single line cannot
                            // do that, and the engine trims the tail with the
                            // same metrics it paints with, so a name that does
                            // not fit ends in an ellipsis instead of moving the
                            // furniture.
                            threadTime(ui, note, isTakenAway(.replies), .{ .gap = 0, .width = time_column_width }, .{
                                ui.spacer(1),
                                ui.paragraph(
                                    .{
                                        .wrap = false,
                                        .text_alignment = .end,
                                        .style = .{ .foreground = theme.palette.text_faint_alt },
                                    },
                                    timeSpans(ui, note, meta_scale),
                                ),
                            }),
                        }),
                        vgap(ui, 5),
                        // What this answers, above the answer. Feed only: in a
                        // thread the parent is the row directly above, so the
                        // line would restate what is already on screen.
                        if (note.has_reply_parent) replyContext(ui, note) else ui.spacer(0),
                        if (note.has_reply_parent) vgap(ui, 4) else ui.spacer(0),
                        noteBody(ui, note, true),
                        // The picture. The space is reserved at the picture's own
                        // shape whether or not it has loaded, so the feed never
                        // shifts as images arrive.
                        if (showsImage(note)) vgap(ui, 8) else ui.spacer(0),
                        if (showsImage(note)) noteGallery(ui, note) else ui.spacer(0),
                        if (showsLink(note)) (if (note.link_is_video) videoCard(ui, note) else linkCard(ui, note)) else ui.spacer(0),
                        if (verbRowShown(note)) vgap(ui, 10) else ui.spacer(0),
                        engagementRow(ui, note),
                    }),
                    hgap(ui, row_pad_side),
                }),
                vgap(ui, row_pad_bottom),
            })}),
            // The only separation between rows: a hairline. The `.separator`
            // element paints a real line (an empty column with a background does
            // not, which is why every divider was invisible before).
            ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = theme.palette.divider_row, .background = theme.palette.divider_row } }),
        }),
    });
    // The note id is masked non-negative at build time, so this cast is safe.
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// Splits rendered note text into styled runs so a note reads like a note.
/// Every interactive run takes the identity violet, because each one names a
/// person or something they wrote: an `@mention` (one weight up, the way a name
/// is set), a `#hashtag`, a bare `nostr:` event reference, and a web link. A
/// link and a hashtag carry a pressable payload (the URL, the topic), and a
/// recorded mention gets one in `contentSpansIn`. A hashtag too long to be a
/// topic carries none and stays muted rather than look pressable. The design
/// shows no hashtag, so their color follows the redesign's stated rule ("violet
/// for identity and content") rather than a shot.
/// Every span's text is a subslice of the note's own content, so nothing is
/// copied. A paragraph holds at most 32 runs, so a link-heavy note keeps its
/// tail as one plain run rather than losing it.
pub fn contentSpans(ui: *AppUi, text: []const u8) []const canvas.TextSpan {
    return contentSpansIn(ui, text, &.{}, 0);
}

/// Spans for a piece of a note's rendered content, with its mentions pressable.
///
/// `mentions` are the note's, whose offsets are relative to the whole of
/// `content_buf`; `base` is where `text` starts inside it. The body splits
/// around a quote card and trims what is left, so what reaches one paragraph is
/// usually a piece rather than the whole.
///
/// A recorded mention is authoritative and is checked before anything else. That
/// is not only about the link: the `@` heuristic below reads a mention as ending
/// at the first space, so `@Sepehr Safari` was styled as far as `@Sepehr` and the
/// surname fell out of the run. A recorded range knows exactly how long the label
/// is because it is what wrote it.
pub fn contentSpansIn(ui: *AppUi, text: []const u8, mentions: []const MentionRef, base: usize) []const canvas.TextSpan {
    @setRuntimeSafety(true); // Splits a stranger's text into runs, and does it on every rebuild.
    const max_spans = 32;
    if (text.len == 0) return &.{};
    const spans = ui.arena.alloc(canvas.TextSpan, max_spans) catch return &.{};

    var n: usize = 0;
    var i: usize = 0;
    var plain_start: usize = 0;
    // Mentions are recorded as the content is walked, so the table is in offset
    // order, and this walk is in offset order too: one cursor covers it. Scanning
    // the whole table at every byte would multiply the per-byte work in this loop
    // by the number of mentions, and this loop runs over every note on screen.
    // A piece of the body can start part-way in, so the cursor skips what is
    // behind it rather than assuming it starts at the first.
    var next: usize = 0;
    while (i < text.len) {
        while (next < mentions.len and mentions[next].off < base + i) next += 1;
        // A label straddling the end of this piece is passed over rather than
        // clipped: the fold cuts the text at a character count, so the last
        // mention before it can be half-present, and half a name is not
        // something to make pressable.
        if (next < mentions.len and mentions[next].off == base + i and mentions[next].len <= text.len - i) {
            const ref = &mentions[next];
            if (n + 2 > max_spans) break;
            if (i > plain_start) {
                spans[n] = .{ .text = text[plain_start..i] };
                n += 1;
            }
            // The same colour and weight the heuristic gives a mention, plus the
            // payload that makes it go somewhere. The renderer underlines every
            // span carrying a link, so this reads as pressable without asking.
            spans[n] = .{ .text = text[i..][0..ref.len], .color = .info, .weight = .medium, .link = ref.link() };
            n += 1;
            i += ref.len;
            plain_start = i;
            continue;
        }
        const is_url = std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://");
        const is_mention = text[i] == '@' and i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1]);
        // A hashtag is `#` + word characters at a word boundary, so `C#` and a
        // URL fragment (`…#section`) are left as plain text.
        const is_hashtag = text[i] == '#' and i + 1 < text.len and isHashtagChar(text[i + 1]) and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]));
        // A `nostr:nevent`/`note`/`naddr` reference (the first is usually lifted
        // into a quote card upstream; a second one, or one inside a quoted body,
        // still reads as a reference here). No link: there is no in-app target
        // for a bare extra ref yet.
        const is_eventref = isEventRefStart(text, i);
        if (!is_url and !is_mention and !is_hashtag and !is_eventref) {
            i += 1;
            continue;
        }
        // Two slots for this run plus the trailing plain run.
        if (n + 3 > max_spans) break;
        if (i > plain_start) {
            spans[n] = .{ .text = text[plain_start..i] };
            n += 1;
        }
        var j = i;
        if (is_hashtag) {
            // Just the tag word: trailing punctuation (`#nostr!`) stays plain.
            j = i + 1;
            while (j < text.len and isHashtagChar(text[j])) j += 1;
        } else {
            while (j < text.len and !std.ascii.isWhitespace(text[j])) j += 1;
        }
        const run = text[i..j];
        // Content color is the identity violet, reached through the `info`
        // token (a span names a token field, not a Color). A @mention
        // additionally sits one weight up, the way a name does.
        //
        // Colour and nothing else, which the renderer now honours. It used to
        // underline every span carrying a link payload whatever `underline`
        // said, so a paragraph with three URLs came out striped; leaving
        // `underline` unset stated the intent and got a hairline anyway. SDK
        // 0.9.2 made the flag mean what it says, so the intent and the pixels
        // finally agree. Mentions are marked by weight and colour, not a rule.
        // A hashtag opens its topic, so it takes the same violet as the other
        // runs that go somewhere. Only one that carries the topic does: a tag
        // too long to be a topic (`contentTags` drops it too) has nowhere to go,
        // and the violet on a run that does nothing when pressed is the trap
        // this colour must never set, so that one stays muted.
        spans[n] = if (is_url)
            .{ .text = run, .color = .info, .link = run }
        else if (is_mention)
            .{ .text = run, .color = .info, .weight = .medium }
        else if (is_hashtag) blk: {
            const link = topicLinkFor(run[1..]) orelse break :blk canvas.TextSpan{ .text = run, .color = .text_muted };
            break :blk canvas.TextSpan{ .text = run, .color = .info, .link = link };
        } else .{ .text = run, .color = .info };
        n += 1;
        i = j;
        plain_start = j;
    }
    if (plain_start < text.len and n < max_spans) {
        spans[n] = .{ .text = text[plain_start..] };
        n += 1;
    }
    return spans[0..n];
}

/// Spans for a sub-slice of `note`'s content, with the note's mentions mapped
/// onto it. `text` must be a piece of `note.content()`; anything else falls back
/// to the plain reading, since the offsets would mean nothing.
pub fn noteSpans(ui: *AppUi, note: *const Note, text: []const u8) []const canvas.TextSpan {
    const whole = note.content();
    const start = @intFromPtr(text.ptr);
    const first = @intFromPtr(whole.ptr);
    if (start < first or start + text.len > first + whole.len) return contentSpans(ui, text);
    return contentSpansIn(ui, text, note.mentions.all(), start - first);
}

pub fn liveRelayCountForTest() usize {
    return liveRelayCount();
}
pub fn askForMediaForTest(note_id: i64) void {
    askForMedia(note_id);
}

pub fn forgetAskedMediaForTest() void {
    g_media_asked = [_]i64{0} ** asked_cap;
}

pub fn uncoverNoteForTest(note_id: i64) void {
    uncoverNote(note_id);
}

pub fn forgetUncoveredForTest() void {
    g_uncovered = [_]i64{0} ** uncovered_cap;
}

pub fn firstLineOfForTest(text: []const u8, max: usize) []const u8 {
    return firstLineOf(text, max);
}

/// Renders just the reply line and returns its concatenated text, so a test can
/// read what a reader would see without standing up a whole feed.
pub fn buildReplyContextForTest(arena: std.mem.Allocator, note: *const Note) ![]const u8 {
    var ui = AppUi.init(arena);
    const node = replyContext(&ui, note);
    const tree = try ui.finalize(node);
    var out: std.ArrayList(u8) = .empty;
    try collectText(tree.root, arena, &out);
    return out.items;
}

pub fn oneLineForTest(ui: *AppUi, text: []const u8) []const u8 {
    return oneLine(ui, text);
}

pub fn quotingPillLabelForTest(ui: *AppUi, id: [32]u8) []const u8 {
    return quotingPillLabel(ui, id);
}
pub fn toggleExpandedForTest(note_id: i64) void {
    toggleExpanded(note_id);
}

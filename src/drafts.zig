//! Drafts: the note being written, kept across a restart, and the replies parked per thread.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const compose = @import("compose.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const WarnCarry = main.WarnCarry;
const refused_text_clip_key = main.refused_text_clip_key;
const writeClipboardText = main.writeClipboardText;
const Effects = main.Effects;
const note_content_cap = main.note_content_cap;
const warning_input_capacity = main.warning_input_capacity;
const Model = main.Model;
const compose_capacity = main.compose_capacity;
const plazaDir = main.plazaDir;
const secret_file_permissions = main.secret_file_permissions;
const setPlain = main.setPlain;
const setToast = main.setToast;

// Unsent replies, kept for the threads the reader stepped out of. The reply box
// holds one reply, and it belongs to the open thread, so every move to another
// level used to empty it: a sentence half written was gone after a Back, where
// a half written note survives a restart. A draft lives here from the moment its
// thread is left until the reader returns to it, which takes it back out, so a
// slot only ever holds a thread that is not open. Session only, a few at a
// time, and the oldest is dropped when they run out.
const reply_draft_slots = 8;
const ReplyDraft = struct {
    used: bool = false,
    event_id: [32]u8 = @splat(0),
    /// When it was kept, so the one dropped when the slots run out is the oldest.
    kept: u64 = 0,
    len: usize = 0,
    text: [compose_capacity]u8 = undefined,
};
pub var g_reply_drafts: [reply_draft_slots]ReplyDraft = [_]ReplyDraft{.{}} ** reply_draft_slots;
var g_reply_draft_clock: u64 = 0;

/// Keeps what is in the reply box under the thread it belongs to, then empties
/// the box. The box only ever holds the open thread's reply, and every move to
/// another level passes through here, so `thread_root` is whose it is. An empty
/// box keeps nothing and leaves any other thread's draft alone.
///
/// A reply held under its Undo pause is the box's text too, so it stops here
/// and is kept with the rest. Left armed it would fire into whatever thread is
/// open when the pause ran out, with whatever draft that thread put back in the
/// box, and nobody would have pressed Reply on it.
pub fn parkReplyDraft(model: *Model) void {
    defer model.reply_buffer.clear();
    const held = compose.g_reply_due_s != 0;
    compose.g_reply_due_s = 0;
    const text = model.reply_buffer.text();
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    keepReplyDraft(model.thread_root.event_id, text, true);
    if (held) setToast(model, "Reply not sent. It is kept in its thread.");
}

/// Files `text` as the kept reply for the thread rooted at `event_id`. A thread
/// that already has one keeps it unless `replace`, so a reply coming back from
/// a refused signature never writes over one typed since.
pub fn keepReplyDraft(event_id: [32]u8, text: []const u8, replace: bool) void {
    var slot: ?usize = null;
    for (&g_reply_drafts, 0..) |*d, i| {
        if (d.used and std.mem.eql(u8, &d.event_id, &event_id)) slot = i;
    }
    if (slot != null and !replace) return;
    if (slot == null) {
        for (&g_reply_drafts, 0..) |*d, i| {
            if (!d.used) {
                slot = i;
                break;
            }
        }
    }
    // Full: the one kept longest ago makes room. Not a rotating index, which
    // would pick whichever slot it reached next, and that can be the draft kept
    // a moment ago into a slot a return had just freed.
    const i = slot orelse blk: {
        var oldest: usize = 0;
        for (&g_reply_drafts, 0..) |*d, j| {
            if (d.kept < g_reply_drafts[oldest].kept) oldest = j;
        }
        break :blk oldest;
    };
    const n = @min(text.len, compose_capacity);
    g_reply_draft_clock += 1;
    g_reply_drafts[i].used = true;
    g_reply_drafts[i].event_id = event_id;
    g_reply_drafts[i].kept = g_reply_draft_clock;
    g_reply_drafts[i].len = n;
    @memcpy(g_reply_drafts[i].text[0..n], text[0..n]);
}

/// The reply kept for the thread rooted at `event_id`, if there is one.
fn keptReplyDraft(event_id: [32]u8) ?[]const u8 {
    for (&g_reply_drafts) |*d| {
        if (d.used and std.mem.eql(u8, &d.event_id, &event_id)) return d.text[0..d.len];
    }
    return null;
}

/// Puts back the reply the reader left in this thread, or leaves the box empty.
pub fn takeReplyDraft(model: *Model, event_id: [32]u8) void {
    model.reply_buffer.clear();
    for (&g_reply_drafts) |*d| {
        if (!d.used or !std.mem.eql(u8, &d.event_id, &event_id)) continue;
        model.reply_buffer.set(d.text[0..d.len]);
        d.used = false;
        return;
    }
}

/// Forgets every kept reply, for a session that is ending. The text is wiped as
/// well as released: it is the leaving account's private thinking.
pub fn forgetReplyDrafts() void {
    forgetRefused();
    for (&g_reply_drafts) |*d| {
        @memset(&d.text, 0);
        d.used = false;
        d.event_id = @splat(0);
        d.kept = 0;
        d.len = 0;
    }
}
/// Where an unsent draft waits between launches. One slot, because the composer
/// is one sheet: a list of drafts is a different feature and the plan says so.
const draft_file = "draft";
const draft_warning_file = "draft_warning";
/// Set by an edit, cleared by the tick that writes it: a keystroke must not
/// carry a file write, and a file write must not wait for the sheet to close.
pub var g_draft_dirty = false;

/// The content warning that goes with the draft, when one is switched on.
pub fn applyStashedDraft(model: *Model, stashed: StashedDraft) void {
    if (stashed.text.len == 0) return;
    setPlain(compose_capacity, &model.draft_buffer, stashed.text);
    if (stashed.warn) |reason| {
        model.warn_on = true;
        model.warn_buffer.set(reason);
    }
}

pub fn draftWarningOf(model: *const Model) ?[]const u8 {
    return if (model.warn_on) model.warn_buffer.text() else null;
}

/// Keeps what was written but not sent. The composer already survives being
/// closed within a session; this is what makes it survive the app quitting,
/// which is the case that actually loses words: a machine that sleeps, an
/// update, a crash.
///
/// Written with the same restrictive permissions as the rest of ~/.plaza,
/// because an unsent note is as private as a sent one and rather more likely
/// to be unfinished thinking.
///
/// The warning rides along as a sibling file whose existence is the switch and
/// whose content is the reason, written and deleted in the same breath as the
/// draft: a note that was going to be covered must not come back from a quit
/// one press from going out uncovered.
pub fn saveDraft(text: []const u8, warn: ?[]const u8) void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    writeDraft(io, &dir, text, warn);
}

pub fn writeDraft(io: std.Io, dir: *std.Io.Dir, text: []const u8, warn: ?[]const u8) void {
    if (text.len == 0) {
        // Nothing to keep: the slot is removed rather than left holding a stale
        // draft that would reappear over the next empty composer.
        dir.deleteFile(io, draft_file) catch {};
        dir.deleteFile(io, draft_warning_file) catch {};
        return;
    }
    dir.writeFile(io, .{
        .sub_path = draft_file,
        .data = text,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
    if (warn) |reason| {
        dir.writeFile(io, .{
            .sub_path = draft_warning_file,
            .data = reason,
            .flags = .{ .permissions = secret_file_permissions },
        }) catch {};
    } else {
        dir.deleteFile(io, draft_warning_file) catch {};
    }
}

const StashedDraft = struct {
    text: []const u8 = "",
    /// The reason, when the draft was saved with a warning switched on (an empty
    /// reason is still a warning).
    warn: ?[]const u8 = null,
};

/// Reads the stashed draft back, or an empty one when there is none.
pub fn loadDraft(out: []u8, warn_out: []u8) StashedDraft {
    const io = main.g_io orelse return .{};
    const environ = main.g_environ orelse return .{};
    var dir = plazaDir(io, environ) catch return .{};
    defer dir.close(io);
    return readDraft(io, &dir, out, warn_out);
}

pub fn readDraft(io: std.Io, dir: *std.Io.Dir, out: []u8, warn_out: []u8) StashedDraft {
    const n = dir.readFile(io, draft_file, out) catch return .{};
    if (n.len == 0) return .{};
    const w = dir.readFile(io, draft_warning_file, warn_out) catch return .{ .text = out[0..n.len] };
    return .{ .text = out[0..n.len], .warn = warn_out[0..w.len] };
}

/// The thread a kept reply is filed under, for a test of where a reply went.
pub fn keptReplyDraftForTest(event_id: [32]u8) ?[]const u8 {
    return keptReplyDraft(event_id);
}
pub fn writeDraftForTest(io: std.Io, dir: *std.Io.Dir, text: []const u8, warn: ?[]const u8) void {
    writeDraft(io, dir, text, warn);
}

pub fn draftWarningForModelForTest(model: *const Model) ?[]const u8 {
    return draftWarningOf(model);
}

/// Restores a launch's composer from `dir`, the way startup does.
pub fn loadDraftIntoForTest(io: std.Io, dir: *std.Io.Dir, model: *Model) void {
    var draft_buf: [note_content_cap]u8 = undefined;
    var warn_buf: [warning_input_capacity]u8 = undefined;
    const stashed = readDraft(io, dir, &draft_buf, &warn_buf);
    applyStashedDraft(model, stashed);
}

// ---------------------------------------------------------------- refused text
//
// A note or reply a signer refused, or never answered, is the reader's words,
// and it comes back by one rule wherever it was written.
//
// It goes back into its box only when the box is empty and nothing is held in
// it for the post pause. Anything else in the box is the reader's, and joining
// the refused text to it did three wrong things: a note held in its pause went
// out with the refused one inside it, the box's text changed under a reader who
// was typing (the editor adopts new text with its caret at the end), and when
// the two did not fit the clipboard was written without anyone asking.
//
// Otherwise it is kept aside here, in memory, and a line under the box says how
// many are kept, with a press that copies them all and one that lets them go.
// The clipboard is written only by that press. A note's content warning stays
// with its own text.

/// Which box a refused text was written in.
pub const RefusedBox = enum(u8) { note, reply };

/// Where a refused text went, so what is said about it is true.
pub const RefusedBack = enum {
    /// Into its empty box, as it was.
    box,
    /// A reply whose thread is not open: kept for that thread, in its box or
    /// beside it, for when the reader goes back.
    thread,
    /// Kept aside, under its box.
    aside,
    /// Kept aside was full, so it could not be kept.
    full,
};

/// How many are kept aside at most. Sized so all of them, a blank line between
/// each, fit on the clipboard in one copy: the toolkit refuses a copy over 64
/// KiB outright, and a Copy that does nothing would lose them all at once.
pub const refused_slots = 12;
comptime {
    std.debug.assert(refused_slots * (compose_capacity + 2) <= native_sdk.max_effect_clipboard_bytes);
}

const RefusedText = struct {
    box: RefusedBox = .note,
    /// The thread a reply answers. Zero for a note.
    root: [32]u8 = @splat(0),
    /// A note's own content warning, never lent to anything else.
    warn: WarnCarry = .{},
    len: usize = 0,
    text: [compose_capacity]u8 = undefined,
};

var g_refused: [refused_slots]RefusedText = [_]RefusedText{.{}} ** refused_slots;
var g_refused_len: usize = 0;
/// One copy of everything kept for a box, built when Copy is pressed.
var g_refused_copy: [refused_slots * (compose_capacity + 2)]u8 = undefined;

/// Gives a note the signer refused back to the reader, and never at the cost
/// of what is in the composer now.
pub fn giveDraftBack(model: *Model, text: []const u8, warn: WarnCarry) RefusedBack {
    if (model.draft_empty() and compose.g_post_due_s == 0) {
        setPlain(compose_capacity, &model.draft_buffer, text);
        warn.restoreInto(model);
        return .box;
    }
    return keepRefused(.note, @splat(0), text, warn);
}

/// Puts a reply the signer refused back where the reader can find it.
///
/// The reply box belongs to whatever thread is open NOW, so a reply to another
/// thread never goes into it: it would read as an answer to somebody else, one
/// press from being sent there. It is kept for its own thread instead, the way
/// a reply left in a thread is, unless that thread already keeps one.
pub fn putBackRefusedReply(model: *Model, root: [32]u8, text: []const u8) RefusedBack {
    if (model.viewing_thread != 0 and std.mem.eql(u8, &model.thread_root.event_id, &root)) {
        if (model.reply_empty() and compose.g_reply_due_s == 0) {
            model.reply_buffer.set(text);
            return .box;
        }
        return keepRefused(.reply, root, text, .{});
    }
    if (keptReplyDraft(root) == null) {
        keepReplyDraft(root, text, false);
        return .thread;
    }
    return switch (keepRefused(.reply, root, text, .{})) {
        .aside => .thread,
        else => |back| back,
    };
}

/// What to say about a refused note, by where it went.
pub fn refusedNoteToast(back: RefusedBack) []const u8 {
    return switch (back) {
        .box => "Not signed. Your draft is back.",
        // A note is never kept for a thread; said as if it were aside.
        .aside, .thread => "Not signed. It is kept in the composer.",
        .full => "Not signed, and no room is left to keep it.",
    };
}

fn keepRefused(box: RefusedBox, root: [32]u8, text: []const u8, warn: WarnCarry) RefusedBack {
    if (g_refused_len == g_refused.len) return .full;
    const slot = &g_refused[g_refused_len];
    const n = @min(text.len, compose_capacity);
    slot.* = .{ .box = box, .root = root, .warn = warn, .len = n };
    @memcpy(slot.text[0..n], text[0..n]);
    g_refused_len += 1;
    return .aside;
}

/// The thread whose refused replies show under the reply box: the open one.
fn refusedRoot(model: *const Model, box: RefusedBox) [32]u8 {
    return if (box == .reply) model.thread_root.event_id else @splat(0);
}

fn refusedIsFor(r: *const RefusedText, box: RefusedBox, root: [32]u8) bool {
    return r.box == box and (box == .note or std.mem.eql(u8, &r.root, &root));
}

/// How many refused texts are kept for this box: every refused note for the
/// composer, and the open thread's refused replies for the reply box.
pub fn refusedCount(model: *const Model, box: RefusedBox) usize {
    if (box == .reply and model.viewing_thread == 0) return 0;
    const root = refusedRoot(model, box);
    var n: usize = 0;
    for (g_refused[0..g_refused_len]) |*r| {
        if (refusedIsFor(r, box, root)) n += 1;
    }
    return n;
}

/// Whether the next refused text would find no room.
pub fn refusedFull() bool {
    return g_refused_len == g_refused.len;
}

/// Copy: every text kept for this box, oldest first and a blank line apart, to
/// the clipboard, and then they are let go. The only place a refused text is
/// written to the clipboard.
pub fn copyRefused(model: *Model, fx: *Effects, box: RefusedBox) void {
    const root = refusedRoot(model, box);
    var len: usize = 0;
    var warned = false;
    for (g_refused[0..g_refused_len]) |*r| {
        if (!refusedIsFor(r, box, root)) continue;
        if (len > 0) {
            @memcpy(g_refused_copy[len..][0..2], "\n\n");
            len += 2;
        }
        @memcpy(g_refused_copy[len..][0..r.len], r.text[0..r.len]);
        len += r.len;
        warned = warned or r.warn.on;
    }
    if (len == 0) return;
    // The toolkit copies the text when it is handed over, so the copy here can
    // be wiped at once.
    writeClipboardText(fx, refused_text_clip_key, g_refused_copy[0..len]);
    @memset(g_refused_copy[0..len], 0);
    dropRefused(box, root);
    // The warning cannot ride on the clipboard, so it is said instead.
    setToast(model, if (warned) "Copied. Set its content warning again." else "Copied");
}

/// Dismiss: lets go of every text kept for this box.
pub fn dismissRefused(model: *const Model, box: RefusedBox) void {
    dropRefused(box, refusedRoot(model, box));
}

fn dropRefused(box: RefusedBox, root: [32]u8) void {
    var kept: usize = 0;
    for (0..g_refused_len) |i| {
        if (refusedIsFor(&g_refused[i], box, root)) continue;
        if (kept != i) g_refused[kept] = g_refused[i];
        kept += 1;
    }
    // Wiped, not only released: it is the reader's unsent writing.
    for (g_refused[kept..g_refused_len]) |*r| {
        @memset(&r.text, 0);
        r.* = .{};
    }
    g_refused_len = kept;
}

/// Forgets every refused text, for a session that is ending.
pub fn forgetRefused() void {
    for (g_refused[0..g_refused_len]) |*r| {
        @memset(&r.text, 0);
        r.* = .{};
    }
    g_refused_len = 0;
}

/// The texts kept aside, oldest first, for a test of what is held and where.
pub fn refusedTextForTest(index: usize) ?[]const u8 {
    if (index >= g_refused_len) return null;
    return g_refused[index].text[0..g_refused[index].len];
}

pub fn refusedWarnForTest(index: usize) ?WarnCarry {
    if (index >= g_refused_len) return null;
    return g_refused[index].warn;
}

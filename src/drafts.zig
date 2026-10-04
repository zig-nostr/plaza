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

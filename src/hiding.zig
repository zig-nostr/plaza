//! The things a reader can take away, and the registry that names them.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const follows = @import("follows.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const comment_kind = main.comment_kind;
const engagement_kinds = main.engagement_kinds;
const invalidateFeed = main.invalidateFeed;
const resetFeedEnd = main.resetFeedEnd;

/// What can be hidden. The enum is the index into the registry below, so a call
/// site is checked at compile time while the table stays data.
/// What can be taken away. Each verb has two, and they are a hierarchy rather
/// than two independent switches: hiding the VERB hides its count with it,
/// because an icon that is not drawn has nowhere to put a number.
pub const Hideable = enum {
    replies,
    reply_counts,
    reposts,
    repost_counts,
    reactions,
    reaction_counts,
    zaps,
    zap_totals,
};

pub const HideableInfo = struct {
    /// Stable across releases: it is written to the settings file, so renaming
    /// one silently un-hides whatever somebody had already hidden.
    id: []const u8,
    label: []const u8,
    /// What hiding it says, in the one place a reader will look for it.
    detail: []const u8,
    /// The kinds the app stops asking for. Empty means hiding this one changes
    /// what is drawn and nothing else, which has to be stated rather than
    /// implied.
    drops: []const u16 = &.{},
};

pub const hideables = [_]HideableInfo{
    .{
        .id = "replies",
        .label = "Replying",
        .detail = "The reply verb itself. Hiding it takes the count with it, and stops the feed asking relays for replies to the notes on screen. You can still open a note and answer it there.",
        .drops = &.{1},
    },
    .{
        .id = "reply_counts",
        .label = "Reply counts",
        .detail = "How many people answered a note, with the verb left in place. The number alone is enough to stop the feed asking for them.",
        .drops = &.{1},
    },
    .{
        // No `drops` on either repost row, and this is the honest half of the
        // feature rather than an oversight. Whether YOU reposted something is
        // read out of the same kind:6 stream as everybody else's reposts, so
        // dropping it would leave the repost verb unable to say it had already
        // been pressed. Hiding it is worth having; claiming the data is gone
        // would not be true.
        .id = "reposts",
        .label = "Reposting",
        .detail = "The repost verb itself. Still fetched either way: it is the same stream that tells Plaza whether you reposted something.",
    },
    .{
        .id = "repost_counts",
        .label = "Repost counts",
        .detail = "How many people passed a note on. Still fetched, for the same reason as the row above.",
    },
    .{
        .id = "reactions",
        .label = "Reacting",
        .detail = "The like verb itself. Hiding it takes the count with it and stops the feed asking relays for reactions. Your own likes are still remembered here.",
        .drops = &.{7},
    },
    .{
        .id = "reaction_counts",
        .label = "Reaction counts",
        .detail = "How many people liked a note. Hiding it stops the FEED asking relays for reactions. Your notifications are a separate subscription and keep theirs, so you still hear when somebody reacts to you. You can still like things; your own heart is remembered here.",
        .drops = &.{7},
    },
    .{
        .id = "zaps",
        .label = "Zapping",
        .detail = "Zaps on notes. Hiding it takes the total with it and stops the feed asking relays for zap receipts.",
        .drops = &.{9735},
    },
    .{
        .id = "zap_totals",
        .label = "Zap totals",
        .detail = "How many sats a note was sent. Hiding it stops the FEED asking relays for zap receipts. You still hear when somebody zaps you.",
        .drops = &.{9735},
    },
};

// The registry is indexed by `Hideable`, so the two have to stay in step. They
// are checked here rather than trusted: a row inserted in the wrong place would
// hide the wrong thing, and nothing about that failure looks like a mistake.
// Making the id the tag's own name is what lets this be a compile error.
comptime {
    if (hideables.len != @typeInfo(Hideable).@"enum".fields.len) {
        @compileError("every Hideable needs exactly one registry row");
    }
    for (@typeInfo(Hideable).@"enum".fields) |field| {
        const row = hideables[field.value];
        if (!std.mem.eql(u8, row.id, field.name)) {
            @compileError("Hideable." ++ field.name ++ " does not line up with registry id \"" ++ row.id ++ "\"");
        }
    }
}

pub var g_hidden: [hideables.len]bool = @splat(false);

/// Whether the reader has taken `what` away.
pub fn isTakenAway(what: Hideable) bool {
    return g_hidden[@intFromEnum(what)];
}

pub fn setHidden(what: Hideable, off: bool) void {
    if (g_hidden[@intFromEnum(what)] == off) return;
    g_hidden[@intFromEnum(what)] = off;
    // The open subscriptions are asking a question that has changed. Without
    // this, turning reactions off stops the counts being drawn and leaves every
    // relay still sending them, which is the cosmetic version of this feature
    // and the one it exists not to be.
    _ = follows.g_follow_gen.fetchAdd(1, .monotonic);
    // The author set moved, so whatever was concluded about the end of their
    // history was concluded about a different question.
    resetFeedEnd();
    invalidateFeed();
}

/// How many things are hidden right now, for the settings screen to say so.
pub fn hiddenCount() usize {
    var n: usize = 0;
    for (g_hidden) |h| {
        if (h) n += 1;
    }
    return n;
}

/// Backing store for the engagement filter's kinds. A `Filter` borrows its
/// `kinds` slice, so it cannot be built on the caller's stack.
var g_engagement_kinds: [engagement_kinds.len]u16 = undefined;

/// The kinds an engagement subscription asks for, with the hidden ones left out.
///
/// This is the function that makes the preference real. Kind 1 is always in it
/// (a reply count is not hideable, and replies are the notes themselves), and so
/// are 6 and 16, for the reason in the registry.
///
/// THE FEED'S subscription, and only that one. `inbox_kinds` asks the same
/// relays for the same kinds and is deliberately left alone: hiding how many
/// people liked a note is not asking to stop being told when somebody likes
/// YOURS. Those are different questions and they get different answers, which
/// is why the settings rows say "the feed" rather than "Plaza". Claiming a kind
/// is no longer requested while another subscription still requests it is the
/// exact shape of overclaim this feature exists not to make.
pub fn engagementKinds() []const u16 {
    var n: usize = 0;
    for (engagement_kinds) |k| {
        const drop = switch (k) {
            // A comment IS a reply, so it follows the reply preference. Asking
            // for it while replies are hidden would ask relays for the thing
            // the reader turned off, which is the overclaim this function
            // exists to avoid.
            1, comment_kind => countHidden(.replies, .reply_counts),
            7 => countHidden(.reactions, .reaction_counts),
            9735 => countHidden(.zaps, .zap_totals),
            // 6 and 16 stay whatever is hidden, for the reason in the registry.
            else => false,
        };
        if (drop) continue;
        g_engagement_kinds[n] = k;
        n += 1;
    }
    return g_engagement_kinds[0..n];
}

/// Whether a verb's number is gone, either because the number was hidden or
/// because the whole verb was.
///
/// The hierarchy, in one place. Hiding a verb hides its count with it: an icon
/// that is not drawn has nowhere to put a number, so treating the two as
/// independent would leave a count that could never be seen still being fetched.
pub fn countHidden(verb: Hideable, count: Hideable) bool {
    return isTakenAway(verb) or isTakenAway(count);
}

/// The settings file's `hidden=` value: the ids of what is hidden, comma
/// separated.
///
/// By ID, never by position. A list of booleans in registry order would mean
/// that adding an element, or reordering one, silently moves everybody's
/// preferences onto different things. These ids are also the shape a NIP-78
/// record will use when this syncs, so they are already the durable name.
pub fn hiddenLine(buf: []u8) []const u8 {
    var len: usize = 0;
    for (hideables, 0..) |h, i| {
        if (!g_hidden[i]) continue;
        const sep = if (len == 0) "" else ",";
        const wrote = std.fmt.bufPrint(buf[len..], "{s}{s}", .{ sep, h.id }) catch break;
        len += wrote.len;
    }
    return buf[0..len];
}

/// The other half. An id this build does not know is skipped rather than
/// refused: a settings file written by a newer Plaza should still open here with
/// everything it does understand intact.
pub fn applyHiddenLine(value: []const u8) void {
    var ids = std.mem.splitScalar(u8, value, ',');
    while (ids.next()) |id| {
        for (hideables, 0..) |h, i| {
            if (std.mem.eql(u8, h.id, id)) g_hidden[i] = true;
        }
    }
}

pub fn engagementKindsForTest() []const u16 {
    return engagementKinds();
}

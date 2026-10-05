//! Tests of hiding.zig. The things a reader can take away, and the registry that names them.

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
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const oneNoteFeed = harness.oneNoteFeed;
const signedNote = harness.signedNote;

/// Whether the widget `id`, or an ancestor of it below the note card, answers a
/// press. A press hit-tests to the deepest widget and walks UP to the nearest
/// ancestor that claims one, so a plain label inside a pressable row is
/// pressable too. The card itself opens the thread, so the walk stops there.
fn pressOnPathTo(tree: AppUi.Tree, widget: canvas.Widget, id: anytype) bool {
    return pressOnPath(tree, widget, id) orelse false;
}

fn pressOnPath(tree: AppUi.Tree, widget: canvas.Widget, id: anytype) ?bool {
    var here = false;
    if (!std.mem.eql(u8, widget.semantics.label, "Open thread")) {
        for (tree.handlers) |h| {
            if (h.id == widget.id and h.event == .press) here = true;
        }
    }
    if (widget.id == id) return here;
    for (widget.children) |child| {
        if (pressOnPath(tree, child, id)) |below| return here or below;
    }
    return null;
}

test "a zap total is a plain figure in the verb row, not a control" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x78} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var target = [_]u8{0} ** 32;
    target[0] = 0x51;
    target[7] = 0x22;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].event_id = target;
    model.notes[0].id = @intCast(std.mem.readInt(u64, target[0..8], .big) & std.math.maxInt(i64));
    model.notes_len = 1;

    // No zaps: nothing is drawn for them, rather than a bolt over a blank or a
    // "0 sats".
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "sat") == null);
    }

    main.setZapMsatForTest(model.notes[0].id, 21_000);
    const tree = try buildTree(arena, &model);
    const figure = findAnyText(tree.root, "21 sats") orelse return error.ZapTotalMissing;
    // Text, and only text: no press, no role and no label for a reader to try.
    try testing.expect(figure.semantics.role != .button);
    try testing.expectEqual(@as(usize, 0), figure.semantics.label.len);
    try testing.expect(!canvas.semanticActions(figure).press);
    try testing.expect(!pressOnPathTo(tree, tree.root, figure.id));

    // And no bolt beside the verbs.
    const p = try painted.Painted.render(arena, &model);
    for (p.layout.nodes) |node| {
        const by_channel = node.widget.icon.len > 0 and std.mem.eql(u8, node.widget.icon, "zap");
        const by_text = node.widget.kind == .icon and std.mem.eql(u8, node.widget.text, "zap");
        try testing.expect(!by_channel and !by_text);
    }

    // One sat reads as one, and the total goes with the preference.
    main.setZapMsatForTest(model.notes[0].id, 1_000);
    {
        const one = try buildTree(arena, &model);
        try testing.expect(findAnyText(one.root, "1 sat") != null);
    }
    main.setHidden(.zap_totals, true);
    {
        const hidden = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(hidden.root, " sat") == null);
    }
    main.setHidden(.zap_totals, false);

    // The three verbs off and zaps left on is a reader asking for the totals
    // alone. The row stays for a note that has one.
    main.setHidden(.replies, true);
    main.setHidden(.reposts, true);
    main.setHidden(.reactions, true);
    {
        const alone = try buildTree(arena, &model);
        try testing.expect(findAnyText(alone.root, "1 sat") != null);
    }
}
test "hiding a count stops the app asking relays for it" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    // Everything on: replies, reposts, reactions, zaps. 1111 rides with 1
    // because a NIP-22 comment IS a reply, so it follows the reply preference
    // and drops with it below.
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, main.engagementKindsForTest());

    // This is the whole feature. Taking the number away has to take the REQUEST
    // away, or it is a number painted over: the bytes still arrive, still parse,
    // still land in the store, and the app is only pretending to be quieter.
    main.setHidden(.reaction_counts, true);
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 9735 }, main.engagementKindsForTest());

    main.setHidden(.zap_totals, true);
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6 }, main.engagementKindsForTest());

    // And back, so this is a preference rather than a one-way door.
    main.setHidden(.reaction_counts, false);
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7 }, main.engagementKindsForTest());
}

test "a thread's tallies go away with the counts, rather than reading zero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);
    model.viewing_thread = 1;
    model.thread_root = model.notes[0];
    // The feed obeyed these switches and the thread did not: somebody who
    // turned every count off watched the feed lose its numbers, opened a note,
    // and got "0 replies 0 reposts 0 likes 0 sats" across the top of it. Four
    // statements about the note, all four false, in the register the app uses
    // for facts.
    const rules_with_stats = blk: {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findTally(p.tree.root, "replies"));
        break :blk countKind(p.tree.root, .separator);
    };

    main.setHidden(.reply_counts, true);
    main.setHidden(.repost_counts, true);
    main.setHidden(.reaction_counts, true);
    main.setHidden(.zap_totals, true);
    {
        const p = try painted.Painted.render(arena, &model);
        // A tally, not any text carrying the word: "Show 3 more replies" is a
        // control and stays. A tally reads "<number> <noun>".
        for ([_][]const u8{ "replies", "reposts", "likes", "sats" }) |word| {
            if (findTally(p.tree.root, word)) {
                std.debug.print("the thread still tallies \"{s}\" with its counts hidden\n", .{word});
                return error.TallyStillThere;
            }
        }
        // And the band goes with them. Two rules with nothing between them is a
        // gap that reads as something failing to load.
        if (countKind(p.tree.root, .separator) >= rules_with_stats) {
            std.debug.print("the tally band is empty rather than gone\n", .{});
            return error.EmptyBandLeftBehind;
        }
    }

    // One back on: that one alone, and no band of zeroes around it.
    main.setHidden(.reply_counts, false);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findTally(p.tree.root, "replies"));
        try testing.expect(!findTally(p.tree.root, "sats"));
    }
}

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var n: usize = if (widget.kind == kind) 1 else 0;
    for (widget.children) |child| n += countKind(child, kind);
    return n;
}

/// A tally line: a number, a space, then the noun. Distinguishes "12 replies"
/// from the "Show 3 more replies" control, which is not a count of anything and
/// stays whatever the switches say.
fn findTally(widget: canvas.Widget, noun: []const u8) bool {
    if (widget.kind == .text and widget.text.len > 0 and std.ascii.isDigit(widget.text[0])) {
        if (std.mem.endsWith(u8, widget.text, noun)) return true;
    }
    for (widget.children) |child| {
        if (findTally(child, noun)) return true;
    }
    return false;
}

test "turning every verb off leaves no band where the row was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);

    const with_verbs = try painted.Painted.render(arena, &model);
    try testing.expect(countKind(with_verbs.tree.root, .icon) > 0);
    const tall = noteCardHeight(with_verbs);
    try testing.expect(tall > 0);

    // The row used to be four verbs, a bookmark and an ellipsis, so switching
    // the four off still left two glyphs holding it open. With those gone it
    // empties completely, and an empty row is a band of nothing under every
    // note: the gap above it belongs to the verbs and goes with them.
    for ([_]main.Hideable{ .replies, .reposts, .reactions, .zaps }) |what| main.setHidden(what, true);
    const without = try painted.Painted.render(arena, &model);
    const short = noteCardHeight(without);
    // The row is 30px and the gap above it is 10. Dropping only the row leaves
    // the gap, which is the dead band: 40 is both of them going together.
    const verbs_and_their_gap: f32 = 40;
    if (tall - short < verbs_and_their_gap) {
        std.debug.print(
            "a note is {d:.1}px with its verbs and {d:.1}px without: {d:.1}px of the row is still reserved\n",
            .{ tall, short, verbs_and_their_gap - (tall - short) },
        );
        return error.DeadBandLeftBehind;
    }
}

/// The height of the note card, which is what a reader sees shrink when the row
/// under it goes away. The tallest `list_item` on screen: the feed's rows are
/// that kind, and so are several one-line things in the chrome.
fn noteCardHeight(p: painted.Painted) f32 {
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .data_row) continue;
        if (!std.mem.eql(u8, node.widget.semantics.label, "Open thread")) continue;
        return node.widget.frame.height;
    }
    return 0;
}

test "hiding repost counts does not claim to stop fetching them" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    main.setHidden(.repost_counts, true);
    // Kind 6 stays. Whether YOU reposted something is read out of the same
    // stream as everybody else's reposts, so dropping it would leave the repost
    // icon unable to say it had already been pressed. The registry says so in
    // the row's own words rather than letting the reader assume otherwise.
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, main.engagementKindsForTest());
    for (main.hideables) |h| {
        if (!std.mem.eql(u8, h.id, "repost_counts")) continue;
        try testing.expectEqual(@as(usize, 0), h.drops.len);
        try testing.expect(std.mem.indexOf(u8, h.detail, "Still fetched") != null);
    }
}

test "every hideable has a stable id, a label and a sentence" {
    // The ids go in a file and will go in a NIP-78 record, so a rename silently
    // un-hides whatever somebody had already hidden. The sentence is what the
    // settings screen shows instead of leaving a reader to guess whether hiding
    // something stops it being downloaded.
    for (main.hideables, 0..) |h, i| {
        try testing.expect(h.id.len > 0);
        try testing.expect(h.label.len > 0);
        try testing.expect(h.detail.len > 0);
        for (main.hideables[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, h.id, other.id));
        }
    }
}

test "the settings screen lists everything hideable, not only what is hidden" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;

    // Hide one, so the screen is in the state where a reader has forgotten what
    // they did and has come looking. Every row is still here, which is the whole
    // reason this screen exists: there is nothing left in the feed to press.
    main.setHidden(.zap_totals, true);
    const tree = try buildTree(arena, &model);
    for (main.hideables) |h| {
        try testing.expect(findAnyText(tree.root, h.label) != null);
    }
}

test "what is hidden survives a restart, and is written by id" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", main.hiddenLine(&buf));

    main.setHidden(.reaction_counts, true);
    main.setHidden(.zap_totals, true);
    const line = main.hiddenLine(&buf);
    // By NAME. A list of booleans in registry order would mean that adding an
    // element, or reordering one, silently moves everybody's preferences onto
    // different things.
    try testing.expect(std.mem.indexOf(u8, line, "reaction_counts") != null);
    try testing.expect(std.mem.indexOf(u8, line, "zap_totals") != null);
    try testing.expect(std.mem.indexOf(u8, line, "repost_counts") == null);

    // Round trip: what was written comes back as the same three answers.
    var kept: [64]u8 = undefined;
    @memcpy(kept[0..line.len], line);
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    main.applyHiddenLine(kept[0..line.len]);
    try testing.expect(main.isTakenAway(.reaction_counts));
    try testing.expect(main.isTakenAway(.zap_totals));
    try testing.expect(!main.isTakenAway(.repost_counts));
    // And the subscription is narrowed from the first frame, not once somebody
    // opens settings.
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6 }, main.engagementKindsForTest());
}

test "a settings file from a newer Plaza still opens here" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    // An id this build has never heard of, beside two it has. Refusing the whole
    // line would drop the preferences it does understand; this reader downgraded
    // one version and should not lose the rest of their settings for it.
    main.applyHiddenLine("reaction_counts,link_previews_from_the_future,zap_totals");
    try testing.expect(main.isTakenAway(.reaction_counts));
    try testing.expect(main.isTakenAway(.zap_totals));
    try testing.expect(!main.isTakenAway(.repost_counts));
}
test "hiding a count narrows the feed's subscription and leaves notifications alone" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    main.setHidden(.reaction_counts, true);
    main.setHidden(.zap_totals, true);
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6 }, main.engagementKindsForTest());

    // And the inbox keeps asking its own question. Hiding how many people liked
    // a note is not asking to stop being told when somebody likes YOURS: two
    // different questions, two subscriptions, and only one of them narrows.
    //
    // This is here because the settings copy said "stops Plaza asking relays for
    // reactions at all", which was false while this array said otherwise. The
    // sentence is fixed; this is what keeps it fixed.
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, &main.inbox_kinds);
}
test "hiding a verb hides its count and stops its fetch too" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, main.engagementKindsForTest());

    // The hierarchy. Hiding the VERB has to take the count with it: an icon
    // that is not drawn has nowhere to put a number, so treating the two as
    // independent would leave a count nobody can see still being downloaded.
    main.setHidden(.reactions, true);
    try testing.expect(main.countHidden(.reactions, .reaction_counts));
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 9735 }, main.engagementKindsForTest());

    // And it holds with only the count hidden, which is the other half.
    main.setHidden(.reactions, false);
    main.setHidden(.reaction_counts, true);
    try testing.expect(main.countHidden(.reactions, .reaction_counts));
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 9735 }, main.engagementKindsForTest());
}

test "reply counts can be hidden, and that stops the feed asking for replies" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    // Kind 1 here is the engagement subscription asking for REPLIES to the
    // notes on screen, which is a different question from the feed's own
    // subscription asking for notes by author. Dropping it costs the reply
    // count and nothing else; a thread still fetches its own replies.
    main.setHidden(.reply_counts, true);
    try testing.expectEqualSlices(u16, &.{ 6, 7, 9735 }, main.engagementKindsForTest());

    main.setHidden(.reply_counts, false);
    main.setHidden(.replies, true);
    try testing.expectEqualSlices(u16, &.{ 6, 7, 9735 }, main.engagementKindsForTest());
}

test "reposting is hideable but never claims to stop being fetched" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    // Both repost rows, verb and count, leave kind 6 in place. Whether YOU
    // reposted something arrives on that same stream, so dropping it would
    // leave the verb unable to say it had already been pressed.
    main.setHidden(.reposts, true);
    main.setHidden(.repost_counts, true);
    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, main.engagementKindsForTest());

    for (main.hideables) |h| {
        if (!std.mem.eql(u8, h.id, "reposts") and !std.mem.eql(u8, h.id, "repost_counts")) continue;
        try testing.expectEqual(@as(usize, 0), h.drops.len);
        try testing.expect(std.mem.indexOf(u8, h.detail, "Still fetched") != null);
    }
}

test "every hideable lines up with its enum tag" {
    // The registry is indexed by the enum, and a row in the wrong place would
    // hide the wrong thing. There is a comptime check for exactly this; this is
    // the runtime statement of the same property, so the intent is visible to
    // somebody reading the tests rather than only to the compiler.
    try testing.expectEqual(@typeInfo(main.Hideable).@"enum".fields.len, main.hideables.len);
    inline for (@typeInfo(main.Hideable).@"enum".fields) |field| {
        try testing.expectEqualStrings(field.name, main.hideables[field.value].id);
    }
}

test "the notes settings screen lists all eight, verbs and counts" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x73} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;

    main.setHidden(.zaps, true);
    const tree = try buildTree(arena, &model);
    for (main.hideables) |h| {
        try testing.expect(findAnyText(tree.root, h.label) != null);
    }
    // And the section is not called QUIET any more, which read as
    // do-not-disturb: a switch about notifications rather than about what a
    // note row draws.
    try testing.expect(findAnyText(tree.root, "QUIET") == null);
    try testing.expect(findAnyText(tree.root, "NOTES") != null);
}

test "a hidden verb is gone from the note row, not just its number" {
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x75} ** 32);

    main.setIdentityForTest([_]u8{0x76} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(try signedNote(arena, signer, kp, 1_800_000_000, "a note with a verb row"), 1_800_000_100);
    model.notes_len = 1;

    // All four verbs are on the row to begin with.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByLabel(tree.root, "Like") != null);
        try testing.expect(findByLabel(tree.root, "Reply") != null);
        try testing.expect(findByLabel(tree.root, "Repost") != null);
    }

    // Hiding the verb removes the control itself. Hiding only its count would
    // leave the icon sitting there, which is the thing this is not.
    main.setHidden(.reactions, true);
    main.setHidden(.replies, true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByLabel(tree.root, "Like") == null);
        try testing.expect(findByLabel(tree.root, "Reply") == null);
        // Untouched, so this is the verb being hidden rather than the whole row
        // failing to build.
        try testing.expect(findByLabel(tree.root, "Repost") != null);
    }

    // Hiding only the COUNT leaves the verb pressable, which is the other half
    // of the pair and the reason there are two rows per verb.
    main.setHidden(.reactions, false);
    main.setHidden(.reaction_counts, true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByLabel(tree.root, "Like") != null);
    }
}
test "hiding replies stops asking relays for comments too" {
    // A comment IS a reply, so it follows the reply preference. Leaving it in
    // while replies are hidden would ask relays for the thing the reader turned
    // off, which is the exact overclaim `engagementKinds` exists to prevent.
    for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);
    defer for (0..main.hideables.len) |i| main.setHidden(@enumFromInt(i), false);

    try testing.expectEqualSlices(u16, &.{ 1, 1111, 6, 7, 9735 }, main.engagementKindsForTest());

    main.setHidden(.replies, true);
    for (main.engagementKindsForTest()) |k| {
        try testing.expect(k != main.comment_kind);
        try testing.expect(k != 1);
    }
}

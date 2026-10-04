//! Tests of updates.zig. The release check: whether a newer Plaza exists, asked politely and at most once at a time.

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
const findAnyTextContainingText = harness.findAnyTextContainingText;
const pressMsgByLabel = harness.pressMsgByLabel;
const releaseDoc = harness.releaseDoc;

test "a newer release is newer by order, not by spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;

    // The one that matters. "0.9.0" sorts AFTER "0.10.0" as text, so a string
    // inequality offers an upgrade that is a downgrade, once per launch forever.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.10.0", ""), "0.9.0", &v, &u) != null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.9.0", ""), "0.10.0", &v, &u) == null);

    // Ordinary forward, and the two that are not news.
    if (main.newerRelease(releaseDoc(arena, "v0.21.0", ""), "0.20.1", &v, &u)) |news| {
        try testing.expectEqualStrings("0.21.0", v[0..news.version_len]);
        try testing.expectEqualStrings("https://github.com/zig-nostr/plaza/releases/tag/v0.21.0", u[0..news.url_len]);
    } else return error.MissedANewerRelease;
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.20.1", ""), "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.20.0", ""), "0.20.1", &v, &u) == null);

    // Every component, so a major or minor bump is not read off the patch alone.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v1.0.0", ""), "0.99.99", &v, &u) != null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ""), "0.20.99", &v, &u) != null);
}

test "a release nobody should be sent to is not news" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;

    // A draft or a prerelease is not something to point somebody at, even
    // though neither appears on `/releases/latest` today.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"draft\":true"), "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"prerelease\":true"), "0.20.1", &v, &u) == null);
    // And the same document with both false IS news, so the guard above is
    // reading the flag rather than the key's presence.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"draft\":false,\"prerelease\":false"), "0.20.1", &v, &u) != null);

    // Nothing a bad answer can do should produce a destination.
    try testing.expect(main.newerRelease("", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("not json at all", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("[]", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{}", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{\"tag_name\":\"not-a-version\"}", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{\"tag_name\":\"v0.21.0\"}", "0.20.1", &v, &u) == null); // no html_url
    // A link somewhere else entirely, which is the one that would matter.
    try testing.expect(main.newerRelease(
        \\{"tag_name":"v0.21.0","html_url":"http://evil.example/plaza"}
    , "0.20.1", &v, &u) == null);
}

test "switched off, Plaza does not ask at all" {
    // The promise in the issue is not "asks less often" or "asks and ignores
    // the answer", it is makes no request. The fetch cannot run under test
    // (`networkAllowed` is comptime false), so this asserts the decision.
    const now: i64 = 1_000_000;

    // Off, and no clock makes it due. Long overdue, never asked, still no.
    try testing.expect(!main.updateCheckDue(false, false, now, 0));
    try testing.expect(!main.updateCheckDue(false, false, now, now - 999_999));
    try testing.expect(!main.updateCheckDue(false, true, now, 0));

    // On, and the clock decides.
    try testing.expect(main.updateCheckDue(true, false, now, 0));
    try testing.expect(main.updateCheckDue(true, false, now, now));
    try testing.expect(!main.updateCheckDue(true, false, now, now + 1));

    // One at a time: a request already out is not a reason to send another.
    try testing.expect(!main.updateCheckDue(true, true, now, 0));
}

test "a newer release is offered, put away, and never offered when switched off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetUpdateStateForTest();
    defer main.resetUpdateStateForTest();

    // Nothing known yet: no line.
    try testing.expectEqualStrings("", main.pendingUpdateVersion());

    // A release document arrives that names something newer than this build.
    const newer = try std.fmt.allocPrint(arena,
        \\{{"tag_name":"v99.0.0","html_url":"https://github.com/zig-nostr/plaza/releases/tag/v99.0.0"}}
    , .{});
    main.updateNewsForTest(newer);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
    try testing.expectEqualStrings("https://github.com/zig-nostr/plaza/releases/tag/v99.0.0", main.pendingUpdateUrl());

    // It draws, and says both versions rather than only the new one.
    var model = main.initialModel();
    model.stage = .ready;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "99.0.0") != null);
        try testing.expect(findAnyTextContainingText(tree.root, main.plaza_version_for_test) != null);
        try testing.expect(pressMsgByLabel(tree, "See what is new") != null);
    }

    // Put away for this session.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.dismiss_update, &fx);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(pressMsgByLabel(tree, "See what is new") == null);
    }

    // Switched off, nothing is offered, even though the release is still out.
    main.resetUpdateStateForTest();
    main.updateNewsForTest(newer);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
    main.setUpdateCheck(false);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
    try testing.expectEqualStrings("", main.pendingUpdateUrl());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(pressMsgByLabel(tree, "See what is new") == null);
    }

    // And switched back on it comes straight back, because that version is
    // still out. Making the reader wait up to six hours for the next check to
    // rediscover what Plaza already knew would be a worse answer.
    main.setUpdateCheck(true);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
}

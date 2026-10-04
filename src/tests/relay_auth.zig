//! Tests of relay_auth.zig. Relay AUTH (NIP-42): the reader's choice per relay, challenges, signing, and resending what was refused.

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
const auth_test_url = harness.auth_test_url;
const buildTree = harness.buildTree;
const challengeAndRefuse = harness.challengeAndRefuse;
const closedMsg = harness.closedMsg;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const pressMsgByLabel = harness.pressMsgByLabel;

/// The socket the reader thread would send its reply on. Records the one thing
/// the exchange puts on the wire so a test can look at the event itself.
const AuthRecorder = struct {
    sent: usize = 0,
    kind: u16 = 0,
    id: [32]u8 = [_]u8{0} ** 32,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    verified: bool = false,
    content_len: usize = 0,
    relay_buf: [128]u8 = undefined,
    relay_len: usize = 0,
    challenge_buf: [300]u8 = undefined,
    challenge_len: usize = 0,

    pub fn authenticate(self: *AuthRecorder, ev: nostr.event.Event) !void {
        self.sent += 1;
        self.kind = ev.kind;
        self.id = ev.id;
        self.pubkey = ev.pubkey;
        self.content_len = ev.content.len;
        for (ev.tags) |tag| {
            if (tag.len < 2) continue;
            if (std.mem.eql(u8, tag[0], "relay")) {
                @memcpy(self.relay_buf[0..tag[1].len], tag[1]);
                self.relay_len = tag[1].len;
            }
            if (std.mem.eql(u8, tag[0], "challenge")) {
                @memcpy(self.challenge_buf[0..tag[1].len], tag[1]);
                self.challenge_len = tag[1].len;
            }
        }
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        self.verified = nostr.event.verify(testing.allocator, signer, ev) catch false;
    }

    fn relay(self: *const AuthRecorder) []const u8 {
        return self.relay_buf[0..self.relay_len];
    }
    fn challenge(self: *const AuthRecorder) []const u8 {
        return self.challenge_buf[0..self.challenge_len];
    }
};

fn authFixture() !usize {
    main.resetRelayAuthForTest();
    main.clearRelaysForTest();
    main.setIdentityForTest([_]u8{0x71} ** 32);
    return main.addRelayForTest(auth_test_url, true, true) orelse error.NoSeat;
}

fn authCleanup() void {
    main.silenceTestSignerForTest(false);
    main.resetRelayAuthForTest();
    main.clearIdentityForTest();
    main.resetRelaysToBootstrapForTest();
}

pub fn authMsg(challenge: []const u8) nostr.message.RelayMessage {
    return .{ .auth = .{ .challenge = challenge } };
}
test "a relay's AUTH is asked about once it refuses something, in a notice that names the relay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();

    var sess = main.AuthSessionForTest{ .index = idx };
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // Nothing has asked yet, so nothing is on screen.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }

    // A challenge on its own is held quietly: the relay has not refused
    // anything, so there is nothing to ask about.
    const heard = main.authReactForTest(&sess, auth_test_url, authMsg("chal-1"), 0);
    try testing.expect(heard.handled);
    try testing.expect(!heard.resend.any());
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }

    // The relay refusing a subscription for want of AUTH is what asks.
    const refusal = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in first"), 1);
    try testing.expect(refusal.handled);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "auth.example.com asks you to identify yourself to it.") != null);
        const allow = pressMsgByLabel(tree, "Let auth.example.com know who you are") orelse return error.NoAllow;
        try testing.expectEqual(idx, allow.auth_allow);
        const deny = pressMsgByLabel(tree, "Do not identify yourself to auth.example.com") orelse return error.NoDeny;
        try testing.expectEqual(idx, deny.auth_deny);
    }

    // The same relay asking again on the same socket is still one question.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("chal-2"), 0);
    try testing.expectEqual(@as(usize, 1), main.authAskingCount());

    // A second relay is a second question, shown after the first and named as
    // waiting beside it rather than stacked on top of it.
    const idx2 = main.addRelayForTest("wss://second.example.com", true, true) orelse return error.NoSeat;
    var sess2 = main.AuthSessionForTest{ .index = idx2 };
    challengeAndRefuse(&sess2, "wss://second.example.com", "chal-9", 0);
    try testing.expectEqual(@as(usize, 2), main.authAskingCount());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "1 more is waiting.") != null);
    }

    // Answering the first moves the notice to the second.
    main.update(&model, Msg{ .auth_allow = @intCast(idx) }, &fx);
    try testing.expectEqual(@as(?usize, idx2), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "second.example.com asks you") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "more is waiting") == null);
    }

    // And the answer is remembered: the next connection to that relay hears the
    // same challenge and is not asked again, it goes straight to being signed.
    main.authSlotResetForTest(idx);
    var again = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&again, auth_test_url, "chal-3", 0);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() != null and main.authAsking().? == idx2);
}

test "a challenge alone raises no notice and sends nothing, even for a relay the reader already allowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    // Several busy public relays challenge every connection and gate nothing.
    // Ask first: no notice.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("hello"), 0);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }
    // Things the relay says that are not an auth refusal do not count as one.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "error: too many subscriptions"), 2);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{3} ** 32, .accepted = false, .message = "blocked: no" } }, 3);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{3} ** 32, .accepted = true, .message = "auth-required: but fine" } }, 4);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    try testing.expect(main.authRowNoteForTest(idx) == null);

    // Allow already said yes for this relay: still nothing is signed or sent
    // for a relay that only greeted.
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var allowed = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&allowed, auth_test_url, authMsg("hello-again"), 10);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    try testing.expect(!main.authHelperBusyForTest());
    _ = main.authPollForTest(&allowed, auth_test_url, &rec, 11);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
}

test "a challenge followed by an auth-required refusal asks, or answers when the reader allowed, and re-sends what was refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    // Ask: the refusal raises the notice, naming the relay.
    var asked = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&asked, auth_test_url, authMsg("held"), 0);
    try testing.expect(main.authAsking() == null);
    _ = main.authReactForTest(&asked, auth_test_url, closedMsg("plaza-feed", "auth-required: log in"), 1);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "auth.example.com asks you to identify yourself to it.") != null);
    }
    _ = main.authPollForTest(&asked, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);

    // Allow: the refusal alone is enough, the held challenge is signed and
    // sent, and the feed it refused is asked again once the relay says OK.
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("held-2"), 10);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in"), 11);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 12);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("held-2", rec.challenge());
    try testing.expectEqualStrings(auth_test_url, rec.relay());
    const ok = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 13);
    try testing.expect(ok.resend.feed);
    try testing.expect(!ok.resend.inbox);

    // An OK that says no to an event with an auth-required reason is the same
    // refusal as a CLOSED for a REQ.
    main.authSlotResetForTest(idx);
    var event_refused = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&event_refused, auth_test_url, authMsg("held-3"), 20);
    const no = main.authReactForTest(&event_refused, auth_test_url, .{ .ok = .{ .event_id = [_]u8{4} ** 32, .accepted = false, .message = "auth-required: only for members" } }, 21);
    try testing.expect(no.handled);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&event_refused, auth_test_url, &rec, 22);
    try testing.expectEqual(@as(usize, 2), rec.sent);
    try testing.expectEqualStrings("held-3", rec.challenge());
}

test "a relay the reader refused sends nothing when it refuses, and the choice is not asked for again" {
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .deny));
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("nope"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 1);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "allowing signs a kind 22242 that names the dialed address and the challenge, and the refused subscriptions are re-sent after the relay's OK" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    main.forgetLastPublishedForTest();

    // The order a strict relay uses: it refuses the subscriptions first, then
    // challenges. Each refusal is held, not treated as the end of anything.
    const feed = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in first"), 0);
    try testing.expect(feed.handled);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-inbox", "auth-required: log in first"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-engagement", "auth-required: log in first"), 0);
    // A one-shot question has nothing to be re-sent from, and a probe is only
    // a latency reading. Neither is owed.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-ask-profile", "auth-required: log in first"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("chal-xyz"), 0);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Until the reader answers, nothing is sent and nothing is signed.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 10);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Allow, pressed in the notice itself.
    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const press = pressMsgByLabel(tree, "Let auth.example.com know who you are") orelse return error.NoAllow;
    main.update(&model, press, &fx);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // The tick gets it signed, through the same keyholder path a note takes.
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // The reader thread sends it.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 20);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqual(@as(u16, 22242), rec.kind);
    try testing.expectEqualStrings(auth_test_url, rec.relay());
    try testing.expectEqualStrings("chal-xyz", rec.challenge());
    try testing.expectEqual(@as(usize, 0), rec.content_len);
    try testing.expectEqualSlices(u8, &me, &rec.pubkey);
    try testing.expect(rec.verified);
    try testing.expectEqualStrings("sent", main.authPhaseNameForTest(idx));
    // It was not stored and not published: it is for one relay's ears.
    try testing.expect(main.lastPublishedForTest() == null);

    // Sent once. Another wake does not send it again.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 30);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    // An OK for something else is not the verdict on this.
    const stranger = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{9} ** 32, .accepted = true, .message = "" } }, 40);
    try testing.expect(!stranger.handled);
    try testing.expect(!stranger.resend.any());

    // The relay accepts. NOW the refused subscriptions come back, and only the
    // ones it refused.
    const accepted = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 50);
    try testing.expect(accepted.handled);
    try testing.expect(accepted.resend.feed);
    try testing.expect(accepted.resend.inbox);
    try testing.expect(accepted.resend.engagement);
    try testing.expectEqualStrings("done", main.authPhaseNameForTest(idx));
    try testing.expect(main.authRowNoteForTest(idx) == null);

    // And a relay that still says auth-required after accepting us is final: the
    // loop's own handling of a closed feed takes over, not a second round.
    const still = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: and again"), 60);
    try testing.expect(!still.handled);
}

test "a relay that rejects the reply is not asked again, and says so in its row" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("c"), 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    const no = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = false, .message = "restricted: not on the list" } }, 2);
    try testing.expect(no.handled);
    try testing.expect(!no.resend.any());
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "would not accept") != null);

    // Nothing more goes out for the same challenge.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqual(@as(usize, 1), rec.sent);
}

test "not allowing sends nothing, is remembered, and the relay's row says what it is waiting for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    challengeAndRefuse(&sess, auth_test_url, "chal-no", 0);
    const tree = try buildTree(arena, &model);
    const press = pressMsgByLabel(tree, "Do not identify yourself to auth.example.com") orelse return error.NoDeny;
    main.update(&model, press, &fx);

    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    try testing.expect(main.authAsking() == null);

    // The notice is gone, and the tick has nothing to sign and the reader
    // thread nothing to send.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 5);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    {
        const after = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(after.root, "identify yourself") == null);
    }

    // The subscription the relay refuses afterwards is a refusal that stays: no
    // reply is composed for it, and the row tells the reader why this relay is
    // giving them nothing even though its dot is green.
    const refused = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 6);
    try testing.expect(refused.handled);
    try testing.expect(!refused.resend.any());
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 7);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "You chose not to tell it.") != null);

    // Written down in the file beside the other local settings, as the word,
    // the account it was said for, and the address, and nothing else.
    var buf: [512]u8 = undefined;
    var want_buf: [256]u8 = undefined;
    const me_hex = std.fmt.bytesToHex(main.activePubkeyForTest().?, .lower);
    const want = try std.fmt.bufPrint(&want_buf, "deny {s} wss://auth.example.com\n", .{me_hex[0..]});
    try testing.expectEqualStrings(want, main.authFileForTest(&buf).?);

    // A later connection hears the challenge, is not asked, and sends nothing.
    main.authSlotResetForTest(idx);
    var later = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&later, auth_test_url, authMsg("chal-again"), 100);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    _ = main.authReactForTest(&later, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 100);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&later, auth_test_url, &rec, 101);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "changing the choice to anonymous after the signature is ready still sends nothing" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "late-no", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // allow -> deny from the relay row, with the reply already composed.
    main.authCycleForTest(idx);
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
}

test "a guest is never asked, and is asked once there is someone to ask about" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    main.clearIdentityForTest();

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    _ = main.authReactForTest(&sess, auth_test_url, authMsg("guest-chal"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    try testing.expectEqualStrings("no_key", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);

    // A refused subscription for a guest is explained in the row, with the way
    // out, rather than reading as a relay with nothing to say.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 2);
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "Sign in to answer it.") != null);
    // Nothing was decided on the guest's behalf, so no choice was recorded.
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceForTest(auth_test_url));

    // Signing in is when the question becomes askable.
    // And no badge either: a guest has no identity to give, so there is
    // nothing for it to change.
    try testing.expect(main.authBadgeTextForTest(idx, auth_test_url) == null);

    main.setIdentityForTest([_]u8{0x71} ** 32);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    try testing.expectEqualStrings("ask first", main.authBadgeTextForTest(idx, auth_test_url).?);
}

test "a CLOSED for any other reason still ends the feed, and a relay that never challenges is dialed again" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};

    // Not an auth refusal: the loop's own handling of a closed feed stands.
    const other = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "error: too many subscriptions"), 0);
    try testing.expect(!other.handled);
    try testing.expect(!sess.owed.any());

    // An auth refusal with no challenge to answer it with. It waits a while for
    // one, because relays send theirs at connect and a late one is possible, and
    // then the connection is dropped and dialed again.
    const gate = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 1_000);
    try testing.expect(gate.handled);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1_000 + main.auth_gate_wait_ms_for_test));
    try testing.expectEqualStrings("redial", main.authPollForTest(&sess, auth_test_url, &rec, 1_001 + main.auth_gate_wait_ms_for_test));

    // A challenge arriving ends the wait for one.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("late"), 5_000);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1_001 + main.auth_gate_wait_ms_for_test));
}

test "a signature for an old challenge, another key, or another relay is never sent" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const secret = [_]u8{0x71} ** 32;
    const other_secret = [_]u8{0x72} ** 32;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // A signer that has not answered yet.
    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "old", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    // One at a time through the keyholder.
    try testing.expect(main.authHelperBusyForTest());

    // The relay sends a newer challenge while the signature is out. The slot
    // goes back to wanting one, and the late signature for "old" is dropped.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("new"), 1);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    const old_ev = try signAuthEvent(a, signer, secret, auth_test_url, "old");
    main.authDeliverSignedForTest(idx, old_ev);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // And the sharper case, a bunker's: the request for "new" is out as well
    // when the answer for "old" turns up. It must not be taken for the answer to
    // the question being asked now.
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authDeliverSignedForTest(idx, old_ev);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // A reply signed by someone who is not the signed-in account.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 2);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    const wrong_key = try signAuthEvent(a, signer, other_secret, auth_test_url, "fresh");
    main.authDeliverSignedForTest(idx, wrong_key);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // The same for another relay's name in the tag: the signer was asked for
    // this relay, and an answer for a different one is not that.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 3);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    const wrong_relay = try signAuthEvent(a, signer, secret, "wss://elsewhere.example.com", "fresh");
    main.authDeliverSignedForTest(idx, wrong_relay);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // And the right one, to show the checks are not simply refusing everything.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 4);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    const right = try signAuthEvent(a, signer, secret, auth_test_url, "fresh");
    main.authDeliverSignedForTest(idx, right);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // Nothing of the refused ones was ever sent.
    try testing.expectEqual(@as(usize, 0), rec.sent);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 5);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("fresh", rec.challenge());
}

fn signAuthEvent(a: std.mem.Allocator, signer: nostr.keys.Signer, secret: [32]u8, url: []const u8, challenge: []const u8) !nostr.event.Event {
    const kp = try signer.keyPairFromSecretKey(secret);
    return nostr.nip42.authEvent(a, signer, kp, url, challenge, 1_700_000_000, null);
}

test "a connection identified as one account is left when the reader becomes someone else" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "who", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1));
    try testing.expectEqual(@as(usize, 1), rec.sent);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 2);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 3));

    // Signing out (or in as somebody else) moves the identity generation. The
    // relay still knows this socket as the old account, and the only way to stop
    // that is to leave it.
    main.bumpIdentityGeneration();
    try testing.expectEqualStrings("redial", main.authPollForTest(&sess, auth_test_url, &rec, 4));
}

test "a signature that never comes back fails the exchange instead of hanging it" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var fx: main.EffectsForTest = undefined;

    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "slow", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authSweepForTest(0);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authSweepForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
}

test "a bunker that refuses or never answers fails the exchange" {
    const idx = try authFixture();
    defer authCleanup();
    try testing.expectEqual(@as(usize, 0), idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.clearPendingForTest();
    defer main.clearPendingForTest();

    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "bunk", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));

    // The bunker's table holds the request with the slot as its tag. Its answer
    // is an error: the tick retires it and the exchange fails with it.
    try testing.expect(main.registerPendingForTest("auth-req-1", .sign_auth, null));
    try testing.expect(main.failPendingForTest("auth-req-1"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
}

test "the choice survives a relaunch and is keyed by the account and the address, not its spelling" {
    main.resetRelayAuthForTest();
    defer main.resetRelayAuthForTest();
    const alice = [_]u8{0xa1} ** 32;
    const bob = [_]u8{0xb2} ** 32;

    try testing.expect(main.setAuthChoiceForTest(alice, "wss://Relay.Example.com/", .allow));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com/"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://other.example.com"));
    // Alice's yes is hers. Bob has not been asked.
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(bob, "wss://relay.example.com"));
    try testing.expect(main.setAuthChoiceForTest(alice, "wss://nope.example.com", .deny));
    try testing.expect(main.setAuthChoiceForTest(bob, "wss://relay.example.com", .deny));

    var buf: [1024]u8 = undefined;
    const text = try testing.allocator.dupe(u8, main.authFileForTest(&buf).?);
    defer testing.allocator.free(text);

    main.resetRelayAuthForTest();
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    main.applyAuthFileForTest(text);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(alice, "wss://nope.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(bob, "wss://nope.example.com"));

    // "Ask first" is a real choice too: it forgets the answer, and only that
    // account's.
    try testing.expect(main.setAuthChoiceForTest(alice, "wss://relay.example.com", .ask));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, "wss://relay.example.com"));

    // A hand-edited file does not get to name things that are not relays, or
    // words that are not answers, or accounts that are not keys.
    main.resetRelayAuthForTest();
    const a_hex = std.fmt.bytesToHex(alice, .lower);
    var raw_buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(&raw_buf, "allow {0s} http://not-a-relay\nmaybe {0s} wss://odd.example.com\n# allow {0s} wss://c.example.com\nallow abc wss://short.example.com\nallow {0s} wss://two.example.com extra\nallow {0s} wss://ok.example.com\n", .{a_hex[0..]});
    main.applyAuthFileForTest(raw);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://ok.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://odd.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://c.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://short.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://two.example.com"));
}

test "an answer written before answers named an account is not taken as anyone's" {
    main.resetRelayAuthForTest();
    defer main.resetRelayAuthForTest();
    const alice = [_]u8{0xa1} ** 32;

    // The old shape: a word and an address. Whoever said it, it was not
    // necessarily the account signed in now, so the relay is asked again.
    main.applyAuthFileForTest("allow wss://old.example.com\ndeny wss://older.example.com\n");
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://old.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://older.example.com"));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", main.authFileForTest(&buf).?);
}

test "the relay row carries the choice as a badge once the relay has asked, and the badge changes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    var model = main.initialModel();
    model.stage = .settings;
    var fx: main.EffectsForTest = undefined;
    var sess = main.AuthSessionForTest{ .index = idx };
    const label = "Change whether wss://auth.example.com may know who you are";

    // A relay that has never mentioned identity gets no control about it.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByLabel(tree.root, label) == null);
    }

    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("row"), 0);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "ask first") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "Waiting for your answer.") != null);
        const msg = pressMsgByLabel(tree, label) orelse return error.NoBadge;
        main.update(&model, msg, &fx);
    }
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceForTest(auth_test_url));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "identify") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "Identifying you to it.") != null);
        main.update(&model, pressMsgByLabel(tree, label).?, &fx);
    }
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "anonymous") != null);
        main.update(&model, pressMsgByLabel(tree, label).?, &fx);
    }
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceForTest(auth_test_url));
    // Back to asking means the notice is back, because the relay is still
    // waiting and the reader has not decided.
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
}

test "a relay taken out of the list stops asking, and does not hide the one behind it" {
    const idx = try authFixture();
    defer authCleanup();
    const idx2 = main.addRelayForTest("wss://second.example.com", true, true) orelse return error.NoSeat;
    var a = main.AuthSessionForTest{ .index = idx };
    var b = main.AuthSessionForTest{ .index = idx2 };
    challengeAndRefuse(&a, auth_test_url, "one", 0);
    challengeAndRefuse(&b, "wss://second.example.com", "two", 0);
    try testing.expectEqual(@as(usize, 2), main.authAskingCount());
    try testing.expectEqual(@as(?usize, idx), main.authAsking());

    main.removeRelayForTest(idx);
    try testing.expectEqual(@as(usize, 1), main.authAskingCount());
    try testing.expectEqual(@as(?usize, idx2), main.authAsking());
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
}

test "a second account on the same machine is asked for itself, and the first keeps its answer" {
    const idx = try authFixture();
    defer authCleanup();
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const alice = main.activePubkeyForTest().?;

    var first = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&first, auth_test_url, "a-1", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&first, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &alice, &rec.pubkey);

    // Someone else signs in on this machine. The relay is the same, the person
    // it would learn is not, so it is a new question.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    main.authSlotResetForTest(idx);
    var second = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&second, auth_test_url, "b-1", 10);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&second, auth_test_url, &rec, 11);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    // Bob says no. That is his answer and leaves Alice's alone.
    main.authAnswerForTest(idx, false);
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, auth_test_url));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, auth_test_url));

    // Alice back: not asked again, straight to being signed, as her.
    main.setIdentityForTest([_]u8{0x71} ** 32);
    main.authSlotResetForTest(idx);
    var third = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&third, auth_test_url, "a-2", 20);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
}

test "switching account between the yes and the signature asks the new account instead of signing as it" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "between", 0);
    main.authAnswerForTest(idx, true);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // The UI thread switches account before its tick, and before the reader
    // thread has woken to look again. Alice said yes; Bob has said nothing.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "a reply signed as one account is never sent once the reader is another, or has gone back to ask first" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const alice = main.activePubkeyForTest().?;

    // Composed for Alice and waiting for the reader thread.
    challengeAndRefuse(&sess, auth_test_url, "mine", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // Alice puts the badge back to "ask first" (allow, anonymous, ask). It is
    // not a no, but it is not a yes either.
    try testing.expect(main.setAuthChoiceForTest(alice, auth_test_url, .ask));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Yes again, signed again, and before it goes out Bob signs in. Bob has
    // said yes to this relay himself, which is exactly when Alice's reply would
    // have slipped through: the choice in force is a yes, just not hers.
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    try testing.expect(main.setAuthChoiceForTest(bob, auth_test_url, .allow));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // Bob's own yes gets Bob's own signature, and that is what goes out.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &bob, &rec.pubkey);
    try testing.expect(rec.verified);
}

test "an exchange that failed is tried again when the reader answers, and not on its own" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    // A bunker whose person was away: the signature timed out.
    main.silenceTestSignerForTest(true);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("away"), 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    main.authSweepForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // The reader thread waking does not start it over: a signer that refuses
    // would be asked again every time.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // Pressing the badge round to identify again is an answer, and it is.
    main.silenceTestSignerForTest(false);
    main.authCycleForTest(idx);
    main.authCycleForTest(idx);
    main.authCycleForTest(idx);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceForTest(auth_test_url));
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("away", rec.challenge());
}

test "a signature that comes back after the reader switched account is dropped and the new account is asked" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Alice's signature is out with a keyholder that has not answered yet.
    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "switch", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));

    // Bob signs in and has said yes to this relay himself. Alice's answer then
    // arrives. It is not his, and it is not a broken signer either: the
    // exchange goes on for Bob instead of failing for good.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    try testing.expect(main.setAuthChoiceForTest(bob, auth_test_url, .allow));
    const alices = try signAuthEvent(a, signer, [_]u8{0x71} ** 32, auth_test_url, "switch");
    main.authDeliverSignedForTest(idx, alices);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    main.silenceTestSignerForTest(false);
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &bob, &rec.pubkey);
}
test "a re-issued feed that a relay refuses for want of AUTH is asked again once the relay says yes" {
    // The feed is closed and asked again under a new id each time its question
    // changes (`plaza-feed-<generation>`), and sign-in is one of those times, so
    // the feed a relay refuses for want of AUTH is almost never the bare
    // `plaza-feed` any more. Matched by name alone, the refusal was not recorded
    // as owed, nothing was re-sent after the relay accepted the reply, and that
    // relay sent the reader no feed for the rest of the connection.
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("after-sign-in"), 0);
    const refused = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed-7", "auth-required: log in"), 1);
    try testing.expect(refused.handled);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    const ok = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 3);
    try testing.expect(ok.resend.feed);
    try testing.expect(!ok.resend.inbox);
    try testing.expect(!ok.resend.engagement);
}

//! Tests of private_lists.zig. The encrypted halves of mute and bookmark lists.

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

test "a bunker can open a private half, and a refusal is not an empty one" {
    // Before this, `scanPrivateHalves` only knew one way to ask: an HTTP call
    // to the local keyholder. A reader signed in through an external signer has
    // no local keyholder holding their key, so the ask came back not-ok and the
    // half was marked refused forever. `writeMute` then refused every mute
    // write, correctly, because a private half that is present and unreadable
    // is exactly what it will not publish over. The guard was firing on a
    // question never asked of the right signer.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(index));

    // The bunker answers. The listener parks it; the tick applies it.
    main.parkRemoteHalfAnswerForTest(index, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(index));

    // And the half that matters more: a refusal or a timeout leaves it
    // REFUSED, never open-and-empty. An empty answer here is how a client
    // publishes a list with every private entry stripped out of it.
    main.forgetPrivateHalvesForTest();
    const second = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    if (!main.failRemoteHalfForTest(second)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
}
test "a NIP-04 half is the bunker's to open and not Notary's" {
    // Notary's loopback door opens NIP-44 and nothing else. Asking it for a
    // NIP-04 half can only fail, and recording that failure as a refusal would
    // have every press re-ask a door that cannot answer. So it reads as
    // unreadable, which is the truth. A bunker can open it, so there it waits.
    const legacy = "AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=Zm9vYmFyYmF6cXV4MTIzNA==";
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    main.setSignerKindForTest("helper");
    try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(legacy));

    main.forgetPrivateHalvesForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(legacy));
}

test "a declined private half is asked again on the next press, never read as empty" {
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));

    // The reader dismisses the prompt on their bunker, or it times out.
    if (!main.failRemoteHalfForTest(index)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));

    // The press says so and puts the ask back for the next tick. It does not
    // report the half as readable or as empty at any point.
    try testing.expectEqualStrings("declined", main.privateHalfGateNameForTest(ciphertext));
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
    // A second press while that ask is out is a wait, not a second prompt.
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));

    // The tick sends it, and the reader approves this time.
    main.markIdleHalvesAskedForTest();
    main.parkRemoteHalfAnswerForTest(index, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("readable", main.privateHalfGateNameForTest(ciphertext));
}

test "an ask that died with its session is asked again" {
    // A reconnect bumps the generation, and a request from the old one is
    // dropped by the sweep. The half it was about stayed "asking" for ever, and
    // nothing asks a half that is already being asked, so the list was read-only
    // until a restart.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqual(@as(u8, 0), index);
    try testing.expect(main.registerRemoteHalfAskForTest(index, .nip04_decrypt));
    main.bumpRemoteGenerationForTest();
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
}

test "signing out forgets what the private halves said" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const ciphertext = "a-half-that-belonged-to-the-last-reader";
    main.openPrivateHalfForTest(ciphertext, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(0));

    main.performLogoutForTest(&model, &fx);
    try testing.expectEqualStrings("none", main.privateHalfStateForTest(0));
}

test "a bunker that stays silent is asked again once the wait is over, and one that said no is not" {
    // A timeout is not an answer. The prompt can sit unseen on a phone or the
    // reply can be lost on the way, and a half marked refused for the whole
    // session leaves the reader's private mutes unenforced until they happen
    // to press a write. An explicit error is different: that is a no, and it
    // waits for a press.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;

    // Silence: refused, with a stamp saying when it may be asked again.
    if (!main.timeoutRemoteHalfForTest(index)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));
    const retry_at = main.privateHalfRetryAtForTest(index);
    try testing.expect(retry_at > 0);

    // Not before the wait is over, and not by anything but that.
    main.rearmPrivateHalvesForTest(retry_at - 1);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));
    main.rearmPrivateHalvesForTest(retry_at);
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
    try testing.expectEqual(@as(i64, 0), main.privateHalfRetryAtForTest(index));

    // Idle is what the tick asks from, and an ask in flight is never moved:
    // at most one prompt is out per half.
    main.forgetPrivateHalvesForTest();
    const second = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(second));

    // An explicit error from the bunker is a no: no stamp, no timed re-ask.
    if (!main.failRemoteHalfForTest(second)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
    try testing.expectEqual(@as(i64, 0), main.privateHalfRetryAtForTest(second));
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
}

test "a reconnect to the bunker asks the halves it refused again" {
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const refused_text = "AsAQ==?iv=refusedciphertext";
    const r = main.claimPrivateHalfPendingForTest(refused_text) orelse return error.NoSlot;
    if (!main.failRemoteHalfForTest(r)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(r));
    const waiting = main.claimPrivateHalfPendingForTest("AsAQ==?iv=stillasking") orelse return error.NoSlot;

    main.bumpRemoteGenerationForTest();
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(r));
    // A half whose ask is still out is not the reconnect's to move: that ask is
    // retired by the stale sweep.
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(waiting));
}

test "what the keyholder says it cannot read is never asked again, and a refusal is" {
    // 422 is Notary saying it looked at this ciphertext and it does not open;
    // so is a 200 whose body is not an answer. Reporting those as "declined"
    // had every press ask a question whose answer cannot change. A 403, a 409
    // or a dead daemon are refusals: they might say yes next time.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();
    const ciphertext = "a-half-notary-cannot-read";

    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(422, "{\"error\":\"unreadable\"}");
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    // Every press reads the same, and none of them goes back to idle.
    for (0..3) |_| try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(ciphertext));
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    // Nor does a new connection or a timer.
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    main.bumpRemoteGenerationForTest();
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));

    main.forgetPrivateHalvesForTest();
    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(200, "this is not json");
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(ciphertext));

    for ([_]u16{ 403, 409, 500, 0 }) |status| {
        main.forgetPrivateHalvesForTest();
        main.askPrivateHalfForTest(ciphertext);
        main.deliverPrivateHalfForTest(status, "{\"error\":\"refused\"}");
        try testing.expectEqualStrings("refused", main.privateHalfStateForTest(0));
        // The press says declined and puts the ask back; a second one waits.
        try testing.expectEqualStrings("declined", main.privateHalfGateNameForTest(ciphertext));
        try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));
    }
}

test "an answer that lands after a sign-out is not applied to the next account's half" {
    // The answer carries a slot index and nothing else, and a sign-out frees
    // the slots while answers are parked or on the wire. Account A's plaintext
    // arriving once account B holds slot zero must change nothing in B's half.
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.clearPendingForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const a_text = "AsAQ==?iv=accountAciphertext";
    const b_text = "AsAQ==?iv=accountBciphertext";
    const a_plain = "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]";

    // A's ask is out, a parked answer for it is waiting, and A signs out.
    const a = main.claimPrivateHalfPendingForTest(a_text) orelse return error.NoSlot;
    main.parkRemoteHalfAnswerForTest(a, a_plain);
    main.performLogoutForTest(&model, &fx);
    main.setSignerKindForTest("remote");

    // B signs in and asks from the same slot.
    const b = main.claimPrivateHalfPendingForTest(b_text) orelse return error.NoSlot;
    try testing.expectEqual(a, b);
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));

    // Then A's answer arrives after all, as the listener would park it, and
    // so does A's timeout and A's refusal. None of them is B's.
    main.parkRemoteHalfAnswerForCiphertextForTest(a, a_text, a_plain);
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));
    try testing.expect(!main.privateHalfIsReadableForTest(b_text));

    try testing.expect(main.endRemoteHalfAskForTest(a, a_text, .timed_out));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));
    try testing.expect(main.endRemoteHalfAskForTest(a, a_text, .failed));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));

    // B's own answer still lands.
    main.parkRemoteHalfAnswerForCiphertextForTest(b, b_text, "[]");
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(b));
}

test "an answer from Notary that lands after a sign-out is not applied either" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    main.askPrivateHalfForTest("a-half-of-the-first-account");
    const first_key = main.privateHalfAskKeyForTest(0);
    main.performLogoutForTest(&model, &fx);

    // The reply for the first account's ask finds nothing waiting for it.
    main.deliverPrivateHalfKeyedForTest(first_key, 200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("none", main.privateHalfStateForTest(0));

    // And once the next account is asking from the same slot, it is still not
    // that ask's answer.
    main.askPrivateHalfForTest("a-half-of-the-second-account");
    main.deliverPrivateHalfKeyedForTest(first_key, 200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(0));
    main.deliverPrivateHalfForTest(200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(0));
}

test "signing out clears an answer the bunker had already handed over" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const text = "AsAQ==?iv=sameciphertextbothtimes";
    const idx = main.claimPrivateHalfPendingForTest(text) orelse return error.NoSlot;
    main.parkRemoteHalfAnswerForTest(idx, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    try testing.expect(main.halfInboxHoldsForTest());
    main.performLogoutForTest(&model, &fx);
    try testing.expect(!main.halfInboxHoldsForTest());

    // Even for the very same ciphertext, a new session has to ask again: what
    // was parked is gone, not merely unmatched.
    main.setSignerKindForTest("remote");
    _ = main.claimPrivateHalfPendingForTest(text) orelse return error.NoSlot;
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(idx));
}
test "a private half Notary has not opened yet is unreadable, not empty" {
    // The distinction this whole cache exists for. Plaza used to open the
    // private half of a NIP-51 list inline against a secret key in this
    // process; there is no secret here now, so it asks the keyholder, and an
    // answer that has not arrived yet must not read as "the half is empty".
    //
    // Treating them alike is how a client publishes a list back with every
    // private entry deleted. Jumble does exactly that, which is why the guard
    // this feeds was written in the first place.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();

    // No keyholder has opened anything, and nothing can: there is no identity,
    // so the stand-in cannot answer either.
    const ciphertext = "AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=notarealciphertext";
    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), main.privateMutesForTest(ciphertext, &out));
    // Zero mutes AND unreadable, which is not the same as zero mutes and empty.
    try testing.expect(!main.privateHalfIsReadableForTest(ciphertext));
}

test "an opened private half is read without asking again" {
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "whatever-the-keyholder-was-given";
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{[_]u8{0x5a} ** 32});
    const plain = try std.fmt.allocPrint(testing.allocator, "[[\"p\",\"{s}\"]]", .{hex});
    defer testing.allocator.free(plain);

    main.openPrivateHalfForTest(ciphertext, plain);
    try testing.expect(main.privateHalfIsReadableForTest(ciphertext));

    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), main.privateMutesForTest(ciphertext, &out));
    try testing.expectEqualSlices(u8, &[_]u8{0x5a} ** 32, &out[0]);
}

test "a keyholder that refuses to open a private half leaves it unreadable" {
    // The other half of the same distinction, and the one an app meets in
    // practice: Notary answering 403 because nobody approved the decrypt, or
    // 409 because the key is locked, or not answering at all.
    //
    // None of those means the list is empty. Recording them as "open with no
    // content" would publish the list back with every private entry deleted,
    // which is the bug this whole cache is shaped around.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();

    const ciphertext = "a-half-the-keyholder-will-not-open";

    for ([_]u16{ 403, 409, 500, 0 }) |status| {
        main.askPrivateHalfForTest(ciphertext);
        main.deliverPrivateHalfForTest(status, "{\"error\":\"refused\"}");
        if (main.privateHalfIsReadableForTest(ciphertext)) {
            std.debug.print("\nstatus {d} was treated as a readable half\n", .{status});
            return error.RefusalReadAsEmpty;
        }
    }

    // And an answer carrying no items is not an empty list either.
    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(200, "{\"items\":[]}");
    try testing.expect(!main.privateHalfIsReadableForTest(ciphertext));
}

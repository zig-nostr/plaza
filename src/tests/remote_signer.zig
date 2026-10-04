//! Tests of remote_signer.zig. NIP-46: the remote signer connection, its pending requests, and their answers.

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

test "a NIP-46 response is matched to its request by id, and unknown ids are dropped" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    // The pending table frees held drafts with the page allocator, so a draft
    // handed to it must come from the same allocator.
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-1", .sign_event, try gpa.dupe(u8, "hello world")));

    // An unknown id resolves nothing: this is the drop that keeps a stray or
    // duplicated response from being published as if it were our note.
    try testing.expect(main.takePendingContentForTest("req-99") == null);

    // The matching id returns the slot, carrying the original draft back.
    const taken = main.takePendingContentForTest("req-1") orelse return error.NoMatch;
    try testing.expect(taken.method == .sign_event);
    try testing.expectEqualStrings("hello world", taken.content.?);
    gpa.free(taken.content.?);

    // A second response for the same id finds nothing: no double resolve.
    try testing.expect(main.takePendingContentForTest("req-1") == null);
}

test "only the signer we connected to can answer a signing request" {
    // NIP-44 derives its conversation key from the SENDER, so a response from
    // anybody at all decrypts, as long as they encrypted it to our client key.
    // That key is public: it is the `p` tag on every request we publish. So the
    // relay filter cannot be the only thing standing between the reader and a
    // stranger's answer, and the handler has to check the sender itself.
    //
    // Left unchecked, an answer carrying a forged event is stored and published
    // to the reader's own relays from the reader's own machine, and an answer
    // carrying an error throws away the note they just wrote.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    // Real keys, and a real sealed response, because a test that hands the
    // handler undecryptable rubbish passes whether the check is there or not:
    // the decrypt fails and the slot survives for the wrong reason. The
    // stranger here does exactly what a stranger could do, correctly.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const client_kp = try signer.keyPairFromSecretKey([_]u8{0x11} ** 32);
    const bunker_kp = try signer.keyPairFromSecretKey([_]u8{0x22} ** 32);
    const stranger_kp = try signer.keyPairFromSecretKey([_]u8{0x33} ** 32);
    main.setRemotePubkeyForTest(bunker_kp.public_key);

    try testing.expect(main.registerPendingForTest("f00dcafe", .connect, null));

    // The stranger encrypts a perfectly valid ack to our client key, under the
    // id of the request in flight. Nothing about the ciphertext is wrong: the
    // conversation key comes from THEIR key, so it decrypts on our side.
    var sealed = try nostr.nip46.seal(
        gpa,
        io,
        signer,
        stranger_kp,
        client_kp.public_key,
        "{\"id\":\"f00dcafe\",\"result\":\"ack\",\"error\":\"\"}",
        1_700_000_000,
    );
    defer sealed.deinit();
    main.deliverNip46ResponseForTest(signer, client_kp, sealed.event);

    // The request is still waiting, which is the point: the stranger neither
    // answered it nor consumed it.
    if (main.takePendingContentForTest("f00dcafe") == null) {
        std.debug.print("a stranger's response resolved the reader's pending request\n", .{});
        return error.StrangerAnsweredForTheBunker;
    }

    // And the bunker's own answer, byte for byte the same message, still works.
    try testing.expect(main.registerPendingForTest("f00dcafe", .connect, null));
    var real = try nostr.nip46.seal(
        gpa,
        io,
        signer,
        bunker_kp,
        client_kp.public_key,
        "{\"id\":\"f00dcafe\",\"result\":\"ack\",\"error\":\"\"}",
        1_700_000_000,
    );
    defer real.deinit();
    main.deliverNip46ResponseForTest(signer, client_kp, real.event);
    if (main.takePendingContentForTest("f00dcafe") != null) {
        std.debug.print("the bunker's own answer was rejected along with the stranger's\n", .{});
        return error.LockedOutTheRealSigner;
    }
}

test "logout empties the NIP-46 pending table so a new session inherits nothing" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-a", .sign_event, try gpa.dupe(u8, "draft a")));
    try testing.expect(main.registerPendingForTest("req-b", .connect, null));

    main.clearPendingForTest(); // what performLogout calls; frees the held draft

    try testing.expect(main.takePendingContentForTest("req-a") == null);
    try testing.expect(main.takePendingContentForTest("req-b") == null);
}

test "a refused remote sign restores the lost draft to the composer" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-x", .sign_event, try gpa.dupe(u8, "my precious note")));

    // The signer refused: the listener flags the slot rather than dropping it,
    // because only the UI thread may touch the composer.
    try testing.expect(main.failPendingForTest("req-x"));

    // The UI sweep restores the draft into the empty composer and raises the
    // notice, so the text is never silently lost on a hung or refused sign.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    try testing.expect(model.draft_empty());
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("my precious note", model.draft());
    try testing.expect(main.remoteSignNoticeForTest());

    // The slot is retired: a late response for it now finds nothing.
    try testing.expect(main.takePendingContentForTest("req-x") == null);
}
test "a legacy half is asked of the bunker as nip04_decrypt, and a current one as nip44_decrypt" {
    // NIP-51 lets the private half be either, and a bunker answers each with its
    // own method. A NIP-04 half sent as nip44_decrypt comes back an error, which
    // reads as a refusal: the reader would have a mute list they could never
    // write to. Both clients tell the two apart by the `?iv=` marker.
    try testing.expectEqualStrings("nip04_decrypt", main.remoteDecryptMethodNameForTest("AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=Zm9vYmFyYmF6cXV4MTIzNA=="));
    try testing.expectEqualStrings("nip44_decrypt", main.remoteDecryptMethodNameForTest("AqRcpq0Cw2h2Vd5Tk1Fk5wAqRcpq0Cw2h2Vd5Tk1Fk5w=="));
    // A NIP-44 payload is base64, which has no `?` in it to be mistaken.
    try testing.expectEqualStrings("nip44_decrypt", main.remoteDecryptMethodNameForTest(""));
}
test "a draft handed back by a timed-out sign has the warning it was signed with" {
    // Several signs can be out at once with a remote signer. The warning rides
    // with each one, so the draft that comes back gets its own, not whichever
    // post was submitted last.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.setIdentityForTest([_]u8{0x4d} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    var fx: main.EffectsForTest = undefined;

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    // First post, warned. Second post, not.
    model.draft_buffer.set("first, behind a warning");
    model.warn_on = true;
    model.warn_buffer.set("spoilers");
    try testing.expect(main.submitPostForTest(&model, &fx));
    model.draft_buffer.set("second, nothing to warn about");
    try testing.expect(main.submitPostForTest(&model, &fx));

    // The first one times out. The second is still with the signer.
    try testing.expect(main.failPendingByContentForTest("first, behind a warning"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("first, behind a warning", model.draft());
    try testing.expect(model.warn_on);
    try testing.expectEqualStrings("spoilers", model.warn_draft());

    // Now the second one, into a clean composer: it must not inherit the first
    // one's warning, which the single global it used to share would have given it.
    model.draft_buffer.clear();
    model.warn_on = false;
    model.warn_buffer.clear();
    try testing.expect(main.failPendingByContentForTest("second, nothing to warn about"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("second, nothing to warn about", model.draft());
    try testing.expect(!model.warn_on);
    try testing.expectEqual(@as(usize, 0), model.warn_draft().len);
}
test "a bunker link signs the reader in when the signer answers, not before" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    var id_buf: [24]u8 = undefined;
    const id = main.beginBunkerConnectForTest([_]u8{0x5A} ** 32, &id_buf);

    // Waiting: the sheet is up, the reader is a guest, and the button says so.
    main.driveBunkerConnectForTest(&model);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expectEqualStrings("Connecting to your signer…", model.login_status());
    // A second press while waiting does not replace the pairing.
    model.login_buffer.set("bunker://anything");
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());

    // The signer answers: now, and only now, the reader is in.
    main.answerBunkerConnectForTest(id);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!model.is_guest());
    try testing.expect(!model.joining and !model.bunker_mode);
    try testing.expectEqual(main.Stage.ready, model.stage);
}

test "a bunker that does not answer leaves the reader a guest, with the reason" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    var id_buf: [24]u8 = undefined;
    const id = main.beginBunkerConnectForTest([_]u8{0x5B} ** 32, &id_buf);
    // The send could not reach the relay, or the signer said no.
    try testing.expect(main.failPendingForTest(id));
    main.scanPendingRemoteForTest(&model, &fx);
    main.driveBunkerConnectForTest(&model);

    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());
    // Still on the sheet they pasted into, told what happened.
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expect(std.mem.indexOf(u8, model.login_status(), "Couldn't connect to your signer") != null);
    // And no sign request can be waiting on a signer that was never reached.
    try testing.expect(main.takePendingContentForTest(id) == null);

    // Backing out of the sheet while it waits cancels the pairing.
    _ = main.beginBunkerConnectForTest([_]u8{0x5C} ** 32, &id_buf);
    main.update(&model, .close_bunker, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("", model.login_status());

    // A request nothing is waiting for any more (it never went out) is a
    // failure too, not a spinner.
    _ = main.beginBunkerConnectForTest([_]u8{0x5D} ** 32, &id_buf);
    main.clearPendingForTest();
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
}

test "pasting a bunker link waits for the signer instead of signing in" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    // A link that is not one. Nothing starts, and the sheet says it cannot read it.
    model.login_buffer.set("bunker://not-a-key");
    main.update(&model, .login_submit, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("Couldn't read that bunker link.", model.login_status());

    // A well-formed link to a relay nobody is listening on. The press connects,
    // and that is all it does: no account, no feed, the sheet still up.
    const link = "bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=abc";
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expectEqualStrings("Connecting to your signer…", model.login_status());

    // The signer answers the request that went out, and then the reader is in.
    var id_buf: [24]u8 = undefined;
    const id = main.pendingConnectIdForTest(&id_buf) orelse return error.NoConnectRequest;
    main.answerBunkerConnectForTest(id);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!model.is_guest());
    try testing.expect(!model.joining and !model.bunker_mode);
}

test "a bunker pairing that is taken back leaves its secret nowhere" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;
    const link = "bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=pairing-secret-one";

    // The signer refuses, or the relay never carried the request.
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(main.remoteSecretHeldForTest("pairing-secret-one"));
    var id_buf: [24]u8 = undefined;
    const id = main.pendingConnectIdForTest(&id_buf) orelse return error.NoConnectRequest;
    try testing.expect(main.failPendingForTest(id));
    main.scanPendingRemoteForTest(&model, &fx);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
    // A length of zero is not the same as gone: the bytes are wiped, and the
    // client key with them.
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-one"));

    // And the same when the reader backs out while it waits.
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.remoteSecretHeldForTest("pairing-secret-one"));
    main.update(&model, .close_bunker, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-one"));
}

test "a key adopted while a bunker link waits takes the link down with it" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    model.login_buffer.set("bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=pairing-secret-two");
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    const generation = main.remoteGenerationForTest();

    // An import finished in Notary meanwhile, and the keyholder's key was
    // adopted. That account is the reader's now.
    main.setIdentityForTest([_]u8{0x6A} ** 32);
    main.driveBunkerConnectForTest(&model);

    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!model.is_guest());
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());
    // The pairing went with it: its listener was told to stop, nothing waits
    // on its answer, and its secret is gone.
    try testing.expect(main.remoteGenerationForTest() != generation);
    var id_buf: [24]u8 = undefined;
    try testing.expect(main.pendingConnectIdForTest(&id_buf) == null);
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-two"));
}

test "a connect answered by the signer is never read as one that never went out" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    // The listener takes an answer on its own thread while the tick asks
    // whether the request is still out. Between "the slot is gone" and "the
    // connection is up" there must be no moment the tick can see, or a signer
    // that said yes is reported as silent and the reader is turned away.
    const Listener = struct {
        go: std.atomic.Value(u32) = .init(0),
        done: std.atomic.Value(u32) = .init(0),
        id: []const u8 = "",
        fn run(self: *@This(), rounds: u32) void {
            var round: u32 = 1;
            while (round <= rounds) : (round += 1) {
                while (self.go.load(.acquire) != round) std.atomic.spinLoopHint();
                main.answerBunkerConnectForTest(self.id);
                self.done.store(round, .release);
            }
        }
    };
    const rounds: u32 = 20_000;
    var listener: Listener = .{};
    var id_buf: [24]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, Listener.run, .{ &listener, rounds });
    var misread: u32 = 0;
    var round: u32 = 1;
    while (round <= rounds) : (round += 1) {
        listener.id = main.beginBunkerConnectForTest([_]u8{0x5E} ** 32, &id_buf);
        listener.go.store(round, .release);
        while (listener.done.load(.acquire) != round) {
            if (main.connectWentQuietForTest()) misread += 1;
        }
    }
    thread.join();
    try testing.expectEqual(@as(u32, 0), misread);
}

//! Tests of keyholder.zig. The bundled keyholder: starting it, the first-run ceremony, and signing through it.

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
const awaitUpload = harness.awaitUpload;
const blossom = harness.blossom;
const buildTree = harness.buildTree;
const countTags = harness.countTags;
const findAnyText = harness.findAnyText;
const findAnyTextContaining = harness.findAnyTextContaining;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const findByText = harness.findByText;
const frameOfText = harness.frameOfText;
const freshHints = harness.freshHints;
const hint_a = harness.hint_a;
const hint_b = harness.hint_b;
const isDescendantOf = harness.isDescendantOf;
const pressMsgByLabel = harness.pressMsgByLabel;
const pressableByLabel = harness.pressableByLabel;
const relayListFor = harness.relayListFor;
const signInNothingFound = harness.signInNothingFound;
const signedNote = harness.signedNote;
const tagNamed = harness.tagNamed;
const threadNote = harness.threadNote;
const writeTestPicture = harness.writeTestPicture;

test "a guest is not offered a profile to edit" {
    // A guest has no key: nothing to read their profile from and nothing that
    // could sign an edit. Offering the sheet would sit on "Reading your current
    // profile" for the rest of the session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "IDENTITY") != null);
    try testing.expect(findAnyText(tree.root, "Edit profile") == null);

    // And reaching for it anyway routes to the join sheet rather than opening a
    // sheet that can never finish.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(!model.editing_profile);
    try testing.expect(model.joining);
}

test "the Edit profile sheet keeps what was typed through Cmd+, and Cmd+L" {
    main.setIdentityForTest([_]u8{0x87} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, .open_settings, &fx);
    main.update(&model, Msg{ .proxy_edit = .{ .insert_text = "https://px.example" } }, &fx);
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(model.editing_profile);
    main.update(&model, Msg{ .profile_name_edit = .{ .insert_text = "Ada" } }, &fx);

    // Settings again, by its shortcut, from inside Settings. Nothing restarts.
    main.update(&model, .open_settings, &fx);
    try testing.expect(model.editing_profile);
    try testing.expectEqualStrings("Ada", model.profile_name());
    try testing.expect(std.mem.indexOf(u8, model.proxy_draft(), "px.example") != null);

    // The address field waits for the sheet: opening it would hide the sheet,
    // and a hit would leave Settings with the sheet still up and unseen.
    main.update(&model, .open_address, &fx);
    try testing.expect(!model.address_open);
    try testing.expect(model.stage == .settings);
    try testing.expect(model.editing_profile);
    try testing.expectEqualStrings("Ada", model.profile_name());
}
test "the rail and guest banner carry the right entry points by identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A guest: the banner carries the always-present join CTAs (as text), and
    // the rail's compose/settings tiles (icons, labelled) route to join too.
    main.clearIdentityForTest();
    var guest = main.initialModel();
    guest.stage = .ready;
    const guest_tree = try buildTree(arena, &guest);
    try testing.expect(findAnyText(guest_tree.root, "Create identity") != null);
    try testing.expect(findAnyText(guest_tree.root, "Sign in") != null);
    // The rail is present in both states: Home, New note, Settings tiles.
    try testing.expect(findByLabel(guest_tree.root, "New note") != null);
    try testing.expect(findByLabel(guest_tree.root, "Settings") != null);

    // Signed in: no join banner; the rail still carries compose and settings,
    // and the compose sheet posts.
    main.setIdentityForTest([_]u8{71} ** 32);
    defer main.clearIdentityForTest();
    var user = main.initialModel();
    user.stage = .ready;
    const user_tree = try buildTree(arena, &user);
    try testing.expect(findByLabel(user_tree.root, "New note") != null);
    try testing.expect(findByLabel(user_tree.root, "Settings") != null);
    try testing.expect(findAnyText(user_tree.root, "Create identity") == null);

    user.composing = true;
    const sheet_tree = try buildTree(arena, &user);
    try testing.expect(findAnyText(sheet_tree.root, "Post") != null);
}

test "opening a thread shows it, and a guest reply routes to the join" {
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{44} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "root note");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    var fx: main.EffectsForTest = undefined;
    // Open the thread: viewing_thread is set and the thread screen shows.
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    const thread_tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(thread_tree.root, "Back") != null);
    try testing.expect(findAnyText(thread_tree.root, "Thread") != null);

    // A guest cannot sign: a reply attempt routes to the join, never publishes.
    model.reply_buffer.set("hi");
    main.update(&model, Msg.reply_submit, &fx);
    try testing.expect(model.joining);

    // Back returns to the feed.
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
}
test "the key that just signed out is not handed back by the health check" {
    // `helperReset` is fire-and-forget with no response handler, and the SDK
    // drops a rejected effect with no trace when every slot is busy. Reset lost,
    // then "Create your identity" clears the logged-out latch before any new key
    // exists, and one second later the poll re-adopts the key the reader just
    // left. Their create fails with AlreadyInitialized, nothing says so, and the
    // next note goes out under the old identity.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setCeremonyForTest(.none);
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    main.setIdentityForTest([_]u8{0xd4} ** 32);
    // The pubkey the daemon would report, which is derived rather than the
    // secret that was handed in.
    const left = main.activePubkeyForTest().?;
    var hex: [64]u8 = undefined;
    for (left, 0..) |b, i| _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    const same = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"pubkey\":\"{s}\",\"state\":\"ready\"}}",
        .{hex[0..]},
    );
    defer testing.allocator.free(same);

    main.performLogoutForTest(&model, &fx);
    try testing.expect(main.loggedOutPubkeyForTest() != null);
    try testing.expect(main.activePubkeyForTest() == null);

    // The reader presses Create, which drops the general latch.
    main.clearLoggedOutLatchForTest();

    // The daemon still holds the old key, because the reset never landed.
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = same });
    try testing.expect(main.activePubkeyForTest() == null);

    // The daemon says it holds nothing. That is the only honest evidence the
    // reset landed, so whatever key appears next is a new one and is adopted.
    const empty = "{\"pubkey\":\"\",\"state\":\"uninitialized\"}";
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = empty });
    try testing.expect(main.loggedOutPubkeyForTest() == null);
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = same });
    try testing.expect(main.activePubkeyForTest() != null);
}
test "a Notary sign that fails hands the note back instead of eating it" {
    // The remote signer has had a pending slot, a deadline and a restore since
    // it shipped. The built-in one had none of it, and `signAndPublish` dropped
    // the restorable flag on the way to it. So a Notary sign that failed for any
    // reason destroyed the note in silence: the composer was cleared, the draft
    // file deleted, the toast said "Posted", and the response handler returned on
    // its first line with no Model to give anything back to. Nothing was stored
    // and nothing was queued, because the outbox is fed after a good signature.
    //
    // The daemon answers non-200 while perfectly alive: 401 on a stale token,
    // 409 with no key yet, 400 on a malformed event, 500 on a signing failure.
    main.setIdentityForTest([_]u8{0x4f} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    const note = "the sentence I actually wanted to publish";

    // The press, driven from the composer so the signer DISPATCH is under test
    // too: it forwarded the restorable flag to the bunker and dropped it on the
    // way to the built-in signer, which is why a note handed to Notary had
    // nothing holding it even after the slot existed.
    model.draft_buffer.set(note);
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(main.helperSignPendingForTest());
    try testing.expect(main.helperSignRestorableForTest());
    try testing.expect(model.draft_empty());

    // And the daemon refuses. 409 is the concrete one: a helper session restored
    // from disk while the daemon comes up with no signer.key.
    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 409, .body = "" });

    // The tick hands it back, into a composer the reader has not started using
    // again, and says why rather than letting it silently reappear.
    try testing.expect(model.draft_empty());
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings(note, model.draft());
    try testing.expect(main.helperSignNoticeForTest());
    try testing.expect(!main.helperSignPendingForTest());
    try testing.expect(std.mem.indexOf(u8, model.identity(testing.allocator), "could not sign") != null);
}
test "a second sign in the same tick is refused, not swallowed" {
    // Every helper sign goes out on ONE effect key, and the SDK refuses a second
    // fetch while that key is held. The refusal used to be dropped on the first
    // line of the response handler, so the second sign of a pair simply never
    // happened, and the caller had already moved its state: the follow set
    // carried a name that was never published and the UI said "Following".
    //
    // Not merely a race. The tick issues `flushRelayList` and
    // `drivePendingIntent` in the same update call with no drain possible
    // between them, so when both are due the second is rejected every time.
    main.setIdentityForTest([_]u8{0x61} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    main.forgetFollowsForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    defer main.releaseHelperSignForTest();
    main.releaseHelperSignForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.signerReadyForTest());

    // One sign goes out and holds the key.
    model.draft_buffer.set("the first thing");
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(!main.signerReadyForTest());

    // THE PROPERTY: every other write says no rather than moving its state and
    // letting the sign be dropped underneath it.
    var alice: [32]u8 = undefined;
    @memset(&alice, 0xa1);
    try testing.expect(!main.writeFollowForTest(&fx, alice, true));
    try testing.expect(!main.publishRelayListForTest(&fx));

    // A second post keeps its draft, rather than emptying the composer for a
    // sign that never left the process.
    model.draft_buffer.set("the second thing");
    try testing.expect(!main.submitPostForTest(&model, &fx));
    try testing.expectEqualStrings("the second thing", model.draft());

    // The signature comes back, and everything works again.
    main.releaseHelperSignForTest();
    try testing.expect(main.signerReadyForTest());
    try testing.expect(main.submitPostForTest(&model, &fx));
}

test "signing out says the key stays in Notary, because it does" {
    // Signing out of Plaza used to ask Notary to forget the key. That
    // conflated two different acts: leaving a client, and taking your identity
    // off the machine. One press in one app should not destroy an identity
    // every other app was using, so Plaza stops using the key and Notary keeps
    // holding it.
    //
    // Which makes the sentence load-bearing. "Signed out" reads as "gone"
    // unless it says otherwise, and a reader who believes their key is gone
    // goes looking for a key that is perfectly fine.
    var model = main.initialModel();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    defer main.setIdentityMintedForTest(false);

    for ([_]bool{ true, false }) |minted| {
        main.setIdentityMintedForTest(minted);
        const said = model.logout_warning();
        if (std.mem.indexOf(u8, said, "stays in Notary") == null) {
            std.debug.print("\nminted={}: \"{s}\"\n", .{ minted, said });
            return error.DidNotSayWhereTheKeyIs;
        }
        // And it must not threaten a deletion that no longer happens.
        try testing.expect(std.mem.indexOf(u8, said, "for good") == null);
        try testing.expect(std.mem.indexOf(u8, said, "deletes") == null);
    }
}

test "a note still being signed is not thrown away without saying so" {
    // A note handed to a signer that has not answered exists in exactly one
    // place: the slot sign-out frees. It cannot be parked in the outbox the way
    // a queued note is, because it has no signature and so no id, and it cannot
    // be left in the composer, because that is the previous reader's writing
    // sitting in front of the next account. So the confirmation says what the
    // press costs.
    main.setIdentityForTest([_]u8{0x50} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") == null);

    main.requestHelperSignForTest(&fx, 1_800_000_000, 1, "half a thought", true);
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") != null);

    // Once it is signed there is nothing to warn about.
    main.releaseHelperSignForTest();
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") == null);
}

test "a sign that never gets an answer at all still gives the note back" {
    // `outcome != .ok` covers a refused connection, but a daemon that accepts
    // the socket and then says nothing produces no terminal at all within the
    // reader's patience. The deadline is the backstop, and without one the note
    // would sit in a slot nobody ever reads.
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.requestHelperSignForTest(&fx, 1_800_000_000, 1, "a note into the void", true);

    // Not yet: the sign is still legitimately out.
    main.scanHelperSignForTest(&model);
    try testing.expect(model.draft_empty());
    try testing.expect(main.helperSignPendingForTest());

    // Past the deadline, it comes back.
    main.expireHelperSignForTest();
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("a note into the void", model.draft());
}

test "a note Notary signs goes to the place it was written in" {
    // The route rides the sign slot across the round trip, and the slot is
    // reset the moment the signature is accepted. Read after that, the route
    // was always "no place": a note written in a place that writes only to its
    // own relay went to the reader's public relays instead.
    // The stand-in keyholder answers through the same handler Notary's answer
    // reaches, so the release and the read happen in the order they ship in.
    main.setIdentityForTest([_]u8{0x52} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    var fx: main.EffectsForTest = undefined;
    main.requestHelperSignRoutedForTest(&fx, 1_800_000_000, "written in the back room", "wss://backroom.example", true);

    const published = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqualStrings("written in the back room", published.content);
    var urls: [4][]const u8 = undefined;
    const n = main.lastPublishedRouteRelaysForTest(&urls);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("wss://backroom.example", urls[0]);
    try testing.expect(main.lastPublishedRouteExclusiveForTest());
}

// ---- B3: guest-first launch ------------------------------------------------

test "a guest feed shows the join strip; dismissing keeps the Guest chip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    try testing.expect(model.is_guest());

    // The strip invites without blocking: the feed is fully built around it.
    const with_strip = try buildTree(arena, &model);
    try testing.expect(findAnyText(with_strip.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") != null);
    try testing.expect(findAnyText(with_strip.root, "Create identity") != null);

    // Dismissal hides the strip but never the way in: the Guest chip stays.
    model.guest_strip_dismissed = true;
    const dismissed = try buildTree(arena, &model);
    try testing.expect(findAnyText(dismissed.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);
    try testing.expect(findAnyText(dismissed.root, "Guest") != null);
}
test "the join sheet renders the ladder and remembers a waiting note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;

    // Bare ladder: title, three ways in, and always the way back.
    const bare = try buildTree(arena, &model);
    try testing.expect(findAnyText(bare.root, "How do you want to join?") != null);
    try testing.expect(findAnyText(bare.root, "Create your identity") != null);
    try testing.expect(findAnyText(bare.root, "Bring your key") != null);
    try testing.expect(findAnyText(bare.root, "Use your own signer") != null);
    try testing.expect(findAnyText(bare.root, "Keep browsing") != null);
    try testing.expect(findAnyText(bare.root, "Your note is waiting.") == null);

    // With a remembered intent, the sheet says so.
    model.pending = .post;
    const pending = try buildTree(arena, &model);
    try testing.expect(findAnyText(pending.root, "Your note is waiting.") != null);
}
test "the composer line tells the truth about the signer connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    defer {
        main.setRemoteStateForTest(0, 0);
        main.clearIdentityForTest();
    }
    var model = main.initialModel();

    main.setRemoteStateForTest(1, 1);
    try testing.expect(std.mem.startsWith(u8, model.identity(arena), "Reaching your signer · "));

    main.setRemoteStateForTest(2, 1);
    try testing.expect(std.mem.startsWith(u8, model.identity(arena), "Signing via your signer · npub1"));

    main.setRemoteStateForTest(3, 1);
    try testing.expectEqualStrings("Your signer is unreachable. Posts will not sign.", model.identity(arena));
}

// ---- C4-C6: name beat, toast, backup nudge ----------------------------------

test "the name beat renders and skipping replays the intent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.naming = true;
    model.pending = .post;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Want a name on it?") != null);
    try testing.expect(findAnyText(tree.root, "Skip") != null);
    try testing.expect(findAnyText(tree.root, "Done") != null);

    // Skip ends the beat and the remembered intent still replays.
    model.naming = false;
    main.replayPendingForTest(&model);
    try testing.expect(model.composing);
}

test "a toast shows its text and the backup nudge states the stakes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    @memcpy(model.toast_buf[0..6], "Posted");
    model.toast_len = 6;
    model.toast_until = 4_000_000_000;
    model.backup_nudge = true;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Posted") != null);
    try testing.expect(findAnyText(tree.root, "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.") != null);
    try testing.expect(findAnyText(tree.root, "Not now") != null);
}

// ---- 3b: helper-held identity restore --------------------------------------

test "a helper session restores the identity from its pubkey, no key in process" {
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{71} ** 32);
    var hexbuf: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (kp.public_key, 0..) |b, i| {
        hexbuf[i * 2] = digits[b >> 4];
        hexbuf[i * 2 + 1] = digits[b & 0x0f];
    }

    // A valid pubkey restores the signed-in helper identity.
    try testing.expect(main.restoreHelperForTest(&hexbuf));
    var model = main.initialModel();
    try testing.expect(!model.is_guest());

    // The feed shows no guest affordances once restored.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findAnyText(tree.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);

    // A short or empty pubkey restores nothing (the parser-mismatch regression).
    main.clearIdentityForTest();
    try testing.expect(!main.restoreHelperForTest(""));
    try testing.expect(!main.restoreHelperForTest("abcd"));
}
test "the account menu has room for every row it can build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The ordinary signed-in shape, and the only one that builds every row: a
    // key held by the keyholder Plaza ships, a window to open it in, and so
    // "Open Notary" and "Bookmarks" both above "Settings...".
    //
    // Every row under the header is conditional, and the row array is allocated
    // at a fixed size. So the size has to hold all of them AT ONCE, and the
    // menu is built here in the state where they are all present rather than in
    // the guest state, where two of them are absent and any size at all passes.
    main.setIdentityForTest([_]u8{0x5c} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindForTest("helper");
    main.setNotaryWindowFoundForTest(true);
    defer main.setNotaryWindowFoundForTest(false);

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .account;
    const tree = try buildTree(arena, &model);

    // All three, and "Settings..." especially: it is written last, so it is the
    // one that falls off the end.
    try testing.expect(findAnyText(tree.root, "Open Notary") != null);
    // Carries its count, so this matches the label rather than the whole string.
    try testing.expect(findAnyTextContainingText(tree.root, "Bookmarks") != null);
    try testing.expect(findAnyTextContainingText(tree.root, "Settings") != null);
}
test "bringing a key through the Notary window signs you in after a sign-out" {
    // The ceremony exits 0 for an import, so `handleNotaryExited` reads it as
    // "not a mint" and signs nobody in: the daemon health check is the only thing
    // that carries the result back, and it opens with `if (g_logged_out) return`.
    //
    // Two of the three ceremony spawn sites drop that latch. This one never did,
    // so a reader who had signed out earlier in the same run pasted their key,
    // watched the window say it was done, and sat in guest mode until they quit.
    // It looked intermittent because the latch is false at launch: it only bites
    // on a run where something signed out first, which is why the second attempt
    // from a fresh start worked.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setCeremonyForTest(.none);

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    // Sign out, which is the precondition. Then press "Bring your key".
    main.setIdentityForTest([_]u8{0xe3} ** 32);
    main.performLogoutForTest(&model, &fx);
    try testing.expect(main.loggedOutForTest());
    // The real message, through the real handler. With no Notary window found
    // the arm cannot open one and says so, without touching `Effects`, which is
    // why the latch clear sits ABOVE the branch rather than inside it.
    //
    // The latch is the point of this test, not where the press lands. A
    // sign-out earlier in the run turns adopt-on-appear off, and a "Bring your
    // key" that leaves it off swallows the whole import: the key reaches the
    // keyholder, the poll refuses it once a second, and the reader sits in
    // guest mode until they quit and reopen.
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(!main.loggedOutForTest());
}
test "an unfollow the keyholder never signed is put back" {
    // Plaza v0.13.0 shipped unable to sign anything: Notary refused every local
    // request until somebody answered a question no window could reach. The app
    // took the refusal, moved the follow set anyway, and showed the press as
    // done. The acceptance journey caught it by reading the list back off the
    // relay and finding the unfollow had reached nothing.
    //
    // The signing half is fixed in Notary. This is the other half: the app must
    // not go on claiming a write that no signature ever covered.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{93} ** 32);
    main.setIdentityForTest([_]u8{93} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    main.silenceTestSignerForTest(true);
    defer main.silenceTestSignerForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/undo.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const tags = [_]nostr.event.Tag{
        &.{ "p", "aa" ** 32 },
        &.{ "p", "bb" ** 32 },
        &.{ "p", "cc" ** 32 },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.noteOwnContactsAnsweredForTest(kp.public_key);

    var bob: [32]u8 = undefined;
    @memset(&bob, 0xbb);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, bob, false));

    // The press moves the live list first, which is deliberate: the feed has to
    // answer immediately. Nothing here disputes that.
    try testing.expectEqual(@as(usize, 2), main.followSetForTest().len);

    // And the keyholder refuses. 403 is the concrete one this shipped against:
    // "awaiting approval", for a question nobody could reach.
    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 403, .body = "" });

    var model = main.initialModel();
    main.scanHelperSignForTest(&model);

    // Put back, all three, with the one that was taken out among them.
    const live = main.followSetForTest();
    try testing.expectEqual(@as(usize, 3), live.len);
    var saw_bob = false;
    for (live) |f| {
        if (std.mem.eql(u8, &f, &bob)) saw_bob = true;
    }
    try testing.expect(saw_bob);

    // And the reader is told. A silent revert is the same lie told backwards.
    try testing.expect(model.toast_text().len > 0);
}

test "a guest pressing follow is offered the join sheet, not a silent failure" {
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x77} ** 32;
    main.clearIdentityForTest();

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .follow_author = .{ .who = [_]u8{0x77} ** 32, .direction = 0 } }, &fx);
    try testing.expect(model.joining);
}

test "the note menu follows the person it named, in the feed as well as in a thread" {
    // Reported as \"the follow button doesn't work\".
    //
    // Every other row in the note menu carries the note it was opened on. This
    // one carried only a direction, so the handler had to find the person
    // itself, and what it reached for was the open thread's ROOT. In the feed
    // there is no open thread, so the row returned before doing anything:
    // enabled, correctly labelled, and silent. Inside a thread it acted on the
    // root's author while the label beside it had been computed from the note
    // actually right-clicked, so the menu could offer to follow one person and
    // follow another.
    //
    // Driven down the guest path because that is the half that needs no signer
    // and no store: it remembers WHO the press was for, and that is the same
    // person the write half is handed.
    var fx: main.EffectsForTest = undefined;
    const clicked = [_]u8{0x5c} ** 32;

    // In the FEED: no thread is open, which is where the row did nothing.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 0;
    main.clearIdentityForTest();
    main.update(&model, Msg{ .follow_author = .{ .who = clicked, .direction = 1 } }, &fx);
    try testing.expect(model.joining);
    switch (model.pending) {
        .follow => |who| try testing.expectEqualSlices(u8, &clicked, &who),
        else => return error.TheFeedPressWasForgotten,
    }

    // In a THREAD, on somebody who is not the root: the person clicked, not the
    // person whose thread it is.
    var deep = main.initialModel();
    deep.stage = .ready;
    deep.viewing_thread = 1;
    deep.thread_root = threadNote(0xAA, 100, 0);
    deep.thread_root.id = 1;
    deep.thread_root.pubkey = [_]u8{0x77} ** 32;
    main.clearIdentityForTest();
    main.update(&deep, Msg{ .follow_author = .{ .who = clicked, .direction = 1 } }, &fx);
    switch (deep.pending) {
        .follow => |who| try testing.expectEqualSlices(u8, &clicked, &who),
        else => return error.ThreadPressWasForgotten,
    }
}
test "the Edit profile sheet gives its introduction's room to a status" {
    // Seven fields, three lines of introduction and a two-line status put the
    // button row below the window at its minimum height, so Try again and Save
    // could not be pressed in exactly the states that need them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = signInNothingFound(0x7b);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    const intro = "Everything this app can read from a profile";

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .absent;
    try testing.expect(model.profile_status().len > 0);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "No relay has a profile for you"));
        try testing.expect(!findAnyTextContaining(tree.root, intro));
    }
    model.profile_stage = .have;
    try testing.expectEqual(@as(usize, 0), model.profile_status().len);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, intro));
    }
}
test "a profile screen renders the person and their notes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5c);
    model.viewing_profile = who;
    model.thread_notes[0] = threadNote(0x01, 100, 0);
    model.thread_notes_len = 1;

    const tree = try buildTree(arena, &model);
    // Back, the tabs, and the counts row are all there.
    try testing.expect(findAnyText(tree.root, "Notes") != null);
    try testing.expect(findAnyText(tree.root, "Replies") != null);
    // The follow count is unknown for a stranger with no contact list in the
    // store, and the screen says so rather than printing a confident zero.
    try testing.expect(findAnyText(tree.root, "Their follow list has not arrived yet") != null);
}

test "a number this app cannot know is not printed" {
    // FOLLOWERS is not computable from a local store: nothing here can know who
    // follows somebody. The design asks for the number; the honest answer is to
    // leave it out rather than state a figure the reader would believe.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5d);
    model.viewing_profile = who;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "followers") == null);
}
test "only the ceremony's own report opens the name beat" {
    // The first version of this asked a 90-second TIMER whether an appearing key
    // was freshly minted. That is a different question from the one that matters,
    // and the gap was reachable: press Create, have it fail, then import a real
    // account inside the window. Plaza offered "Want a name on it?" over an
    // account that already had a name, and publishing that name rewrote its
    // kind:0 from an empty local profile.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    const body = "{\"pubkey\":\"" ++ "5b" ** 32 ++ "\",\"state\":\"ready\"}";

    // The window said it minted a key.
    {
        main.setCeremonyForTest(.created);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(model.naming);
    }

    // A ceremony is open but has said nothing yet. Sign in; do NOT assume.
    {
        main.clearIdentityForTest();
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(!model.naming);
        try testing.expect(main.ceremonyOwesNameForTest());
    }

    // No ceremony at all: an import, a terminal, a restored daemon.
    {
        main.clearIdentityForTest();
        main.setCeremonyForTest(.none);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(!model.naming);
    }
}

test "a ceremony that did not mint arms nothing" {
    // Every way out of that window except a mint: a failure, a cancel, a crash,
    // and a spawn that never ran because one was already open.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);

    for ([_]native_sdk.EffectExit{
        .{ .key = 0, .reason = .exited, .code = 0 },
        .{ .key = 0, .reason = .exited, .code = 1 },
        .{ .key = 0, .reason = .signaled, .code = 0 },
        .{ .key = 0, .reason = .rejected, .code = 0 },
    }) |exit| {
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, exit);
        try testing.expect(!model.naming);
        // And it must not claim the key has no history: that flag is what lets a
        // contact list be published without reading one back first.
        try testing.expect(!main.identityMintedForTest());
    }

    // A rejected spawn is a press that did nothing, so the reader is told.
    {
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
        try testing.expect(model.toast_until != 0);
    }
}

test "a mint confirmed after the poll still gets its name beat" {
    // The window holds its result until the reader dismisses it and Plaza polls
    // every second, so the key is all but always adopted BEFORE the window
    // exits. The beat is owed until the report arrives, and paid when it does.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    main.setCeremonyForTest(.running);
    const body = "{\"pubkey\":\"" ++ "6c" ** 32 ++ "\",\"state\":\"ready\"}";

    var model = main.initialModel();
    model.stage = .onboarding;
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
    try testing.expect(!model.naming);

    main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .exited, .code = 9 });
    try testing.expect(model.naming);
    try testing.expect(main.identityMintedForTest());
}

test "a key that was never made never claims to have no history" {
    // canWriteFollows() lets a contact list be published WITHOUT reading one back
    // when the key was minted here, because a key with no history cannot have a
    // list to destroy. Setting that on the button press rather than on a
    // confirmed mint made the claim false: press Create, have the ceremony fail,
    // import an account with eight hundred follows, and the remembered follow
    // replays into a kind:3 holding the starter pack and nothing else.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    var fx: main.EffectsForTest = undefined;
    main.setIdentityMintedForTest(false);
    // With the daemon parked as unreachable the queued create stays queued, so
    // this exercises the Msg arm without needing an effects layer.
    main.setHelperUnreachableForTest();
    defer main.setHelperUnreachableForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    main.update(&model, .join_create, &fx);
    try testing.expect(!main.identityMintedForTest());

    // And choosing the other rung disclaims it outright.
    main.setIdentityMintedForTest(true);
    main.setCeremonyForTest(.running);
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(!main.identityMintedForTest());
}

test "the ladder offers three ways in and the way back out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    const tree = try buildTree(arena, &model);

    // Each rung says what it is AND what it costs, because "Bring your key" on
    // its own does not tell a reader that the key goes somewhere other than this
    // window, which is the single most important fact on this sheet.
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    try testing.expect(findAnyText(tree.root, "Ready in seconds. Nothing to write down.") != null);
    try testing.expect(findAnyText(tree.root, "Bring your key") != null);
    try testing.expect(findAnyTextContaining(tree.root, "Plaza itself never sees it."));
    try testing.expect(findAnyText(tree.root, "Use your own signer") != null);
    try testing.expect(findAnyText(tree.root, "Keep browsing") != null);
}

test "the sheet names the verb it interrupted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // No verb, no pill: a reader who opened this from the rail is not owed an
    // explanation of something they did not do.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        try testing.expect(!findAnyTextContaining((try buildTree(arena, &model)).root, "is waiting."));
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        model.pending = .post;
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your note is waiting.") != null);
    }
}
test "the sheets' recommended actions actually paint" {
    // Twice in one sitting a control was built as a `.list_item` carrying a
    // background, which paints nothing: the white "Create your identity" card and
    // the white "Done" both rendered as dim text on the sheet's own dark surface.
    // The widget tree was correct both times, so every structural assertion in
    // this file passed. Only a pixel can tell the difference.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        const p = try painted.Painted.render(arena, &model);
        const fill = p.fillAtCenterOf("Create your identity") orelse return error.NoCreateCard;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.naming = true;
        const p = try painted.Painted.render(arena, &model);
        const fill = p.fillAtCenterOf("Done") orelse return error.NoDoneButton;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }
}
test "the rail's own seat opens your page, not your preferences" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A guest has no page to open, so the seat asks who they are. Unchanged.
    main.clearIdentityForTest();
    {
        var model = main.initialModel();
        model.stage = .ready;
        const tree = try buildTree(arena, &model);
        const msg = pressMsgByLabel(tree, "You") orelse return error.SeatHasNoPress;
        switch (msg) {
            .open_join => {},
            else => return error.GuestSeatGoesSomewhereElse,
        }
    }

    main.setIdentityForTest([_]u8{0x5A} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const msg = pressMsgByLabel(tree, "You") orelse return error.SeatHasNoPress;
    switch (msg) {
        .open_person => |pk| try testing.expectEqualSlices(u8, &me, &pk),
        else => return error.SeatGoesSomewhereElse,
    }

    // The page it opens has to KNOW whose it is. Carrying the right thirty-two
    // bytes is not the same thing as landing on a screen that reads as yours,
    // and the screen is the part a reader sees.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, msg, &fx);
    try testing.expectEqualSlices(u8, &me, &(model.viewing_profile orelse return error.NoProfile));
    const page = try buildTree(arena, &model);
    try testing.expect(findAnyText(page.root, "This is you") != null);
    // And offers no Follow. Following yourself writes your own contact list for
    // no reason, which is the one thing this app is most careful with.
    try testing.expect(findAnyText(page.root, "Follow") == null);
}
test "every way into the app is wired, by name" {
    // Deleting `.on_press` from joinCard leaves three inert rectangles that still
    // say button, still focus, still paint, and still hold every string the other
    // tests assert on. The whole suite passed with the ladder dead.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        const tree = try buildTree(arena, &model);
        for ([_][]const u8{ "Create your identity", "Bring your key", "Use your own signer", "Keep browsing" }) |label| {
            if (!pressableByLabel(tree, tree.root, label)) {
                std.debug.print("join sheet: \"{s}\" is not pressable\n", .{label});
                return error.DeadControl;
            }
        }
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.naming = true;
        const tree = try buildTree(arena, &model);
        for ([_][]const u8{ "Done", "Skip" }) |label| {
            if (!pressableByLabel(tree, tree.root, label)) {
                std.debug.print("name card: \"{s}\" is not pressable\n", .{label});
                return error.DeadControl;
            }
        }
    }
}

test "a keyholder that is not there is reported missing, not formatted into a path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    var out: [1024]u8 = undefined;
    // Nothing beside us yet. Formatting a path is not finding a binary, and the
    // version of this that only formatted is what shipped a bundle with no
    // keyholder in it: the app spawned a file that was not there, said so on
    // stderr, and carried on believing it had a daemon.
    try testing.expectEqual(@as(usize, 0), main.resolveSiblingForTest(std.testing.io, &out, dir, "signer"));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "signer", .data = "not really a binary" });
    const n = main.resolveSiblingForTest(std.testing.io, &out, dir, "signer");
    var want_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, "{s}/signer", .{dir}),
        out[0..n],
    );
}

test "with no keyholder the create rung says why and stops being a button" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    const tree = try buildTree(arena, &model);

    // Still named, so the reader is not left hunting for where creating an
    // identity went. Just not a button, and not a promise: "every way into the
    // app is wired, by name" asserts the opposite of this on the same label, and
    // between them they pin both states.
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    try testing.expectEqual(@as(?Msg, null), pressMsgByLabel(tree, "Create your identity"));
    try testing.expect(findAnyText(tree.root, "Not possible in this copy of Plaza.") != null);
    try testing.expect(findAnyText(tree.root, "Ready in seconds. Nothing to write down.") == null);
    // And the reason sits under the card, where a wrapping line has room to be
    // three lines long. `the ladder's rungs hold their own copy` is what keeps
    // it from drifting back INTO the card, where it paints outside the border.
    try testing.expect(findAnyTextContaining(tree.root, "is missing from this install"));

    // Bringing a key goes the same way, and for the same reason: there is
    // nowhere for a key to go. It used to fall back to a field in this process,
    // and that fallback is gone with the field. A rung that leads to a screen
    // refusing every key it is given is worse than one that says it cannot.
    try testing.expect(findAnyText(tree.root, "Bring your key") != null);
    try testing.expectEqual(@as(?Msg, null), pressMsgByLabel(tree, "Bring your key"));

    // The rung that still works is the one that needs nothing from this
    // machine: your key is already in a signer somewhere else.
    try testing.expect(pressableByLabel(tree, tree.root, "Use your own signer"));
    try testing.expect(findAnyText(tree.root, "Opens Notary. Plaza itself never sees it.") == null);
    // And nothing anywhere still offers to keep a key in this app, which is a
    // promise it can no longer make about anything.
    try testing.expect(findAnyText(tree.root, "Pasted here, and kept on this device.") == null);
}

test "with no keyholder nothing queues a mint that can never fire" {
    main.clearIdentityForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    try testing.expect(!main.helperSetupQueuedForTest());

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .join_create, &fx);

    // `queueHelperSetup` parks an intent until the daemon answers, and a daemon
    // that is not installed never answers. Without the guard in `beginCreate`
    // this sits queued for the life of the process while the sheet closes over
    // it, which is a press swallowed whole.
    try testing.expect(!main.helperSetupQueuedForTest());
}

test "with no keyholder there is nowhere for a key to go, and the app says so" {
    main.clearIdentityForTest();
    defer main.setNotaryWindowFoundForTest(false);

    // The window is only the right destination when there is something behind
    // it. Three of these four are the in-Plaza field.
    main.setNotaryWindowFoundForTest(true);
    main.setKeyholderMissingForTest(false);
    try testing.expect(main.ceremonyCanTakeKeyForTest());
    main.setKeyholderMissingForTest(true);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.setNotaryWindowFoundForTest(false);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.setKeyholderMissingForTest(false);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());

    // And the branch that reads it says so, rather than opening a screen that
    // refuses every key it is given. There is no field in this app that can
    // hold one, so "somewhere the reader can finish" is nowhere: the honest
    // move is to name what is missing.
    main.setNotaryWindowFoundForTest(true);
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(model.stage != .onboarding);
    try testing.expect(std.mem.indexOf(u8, model.toast_buf[0..model.toast_len], "missing") != null);
}

/// Every line of text INSIDE one of the join ladder's rungs has to end inside it.
///
/// A rung's subtitle is a wrapped paragraph in a column the surrounding row has
/// already been sized against, so a subtitle long enough to take a third line
/// runs past the card's own bottom edge and paints the last line half outside
/// it. Nothing about the widget tree changes when that happens: the string is
/// all present, in one node, correctly nested under the card, and every
/// structural assertion in this file passed while it was rendering clipped. Only
/// the laid-out frames say so, which is why this is a geometric assertion and
/// why it runs over BOTH states of the ladder rather than the one that happened
/// to be long.
///
/// "Inside" is ANCESTRY, walked through `parent_index`, and not a box test. The
/// first version of this asked whether a text node's frame fell within a rung's
/// frame, which is a different question with the same answer most of the time:
/// the join ladder is a sheet stacked OVER the feed, so a feed line behind it
/// can sit squarely inside a rung's box while belonging to something else
/// entirely. Making the window taller was enough to move one there.
fn expectRungsHoldTheirCopy(p: painted.Painted) !void {
    for ([_][]const u8{ "Create your identity", "Bring your key", "Use your own signer" }) |label| {
        var rung_index: ?usize = null;
        for (p.layout.nodes, 0..) |node, i| {
            if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
            rung_index = i;
            break;
        }
        const rung_i = rung_index orelse {
            std.debug.print("join ladder: no rung labelled \"{s}\"\n", .{label});
            return error.NoRung;
        };
        const rung = p.layout.nodes[rung_i].widget.frame;
        const floor = rung.y + rung.height;
        for (p.layout.nodes, 0..) |node, i| {
            const w = node.widget;
            if (w.kind != .text or w.text.len == 0) continue;
            if (!isDescendantOf(p, i, rung_i)) continue;
            if (w.frame.y + w.frame.height > floor + 0.5) {
                std.debug.print(
                    "join ladder: \"{s}\" runs {d:.1}px past the bottom of the \"{s}\" rung\n",
                    .{ w.text, w.frame.y + w.frame.height - floor, label },
                );
                return error.CopyOverflowsItsRung;
            }
        }
    }
}
test "the ladder's rungs hold their own copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    try expectRungsHoldTheirCopy(try painted.Painted.render(arena_state.allocator(), &model));

    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    try expectRungsHoldTheirCopy(try painted.Painted.render(arena_state.allocator(), &model));
}

test "the fallback welcome screen stops selling a key it cannot make" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // This screen is where a broken install sends "Bring your key", so it is the
    // one a reader with no keyholder actually lands on. Its text is compiled
    // markup and cannot be swapped node-for-node, so the two lines that would
    // otherwise argue with the greyed button are bindings.
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    var model = main.initialModel();
    model.stage = .onboarding;
    const tree = try buildTree(arena, &model);

    const create = findByText(tree.root, .button, "Create your identity") orelse return error.NoCreateButton;
    try testing.expect(create.state.disabled);
    try testing.expect(findAnyTextContaining(tree.root, "is missing from this install"));
    try testing.expect(findAnyTextContaining(tree.root, "Sign in with a key you already have"));
    try testing.expect(!findAnyTextContaining(tree.root, "A second to set up"));
    try testing.expect(!findAnyTextContaining(tree.root, "Create an identity and Plaza sets you up"));

    // And with a keyholder it is the screen it has always been.
    main.setKeyholderMissingForTest(false);
    const whole = try buildTree(arena, &model);
    const live = findByText(whole.root, .button, "Create your identity") orelse return error.NoCreateButton;
    try testing.expect(!live.state.disabled);
    try testing.expect(findAnyTextContaining(whole.root, "A second to set up"));
    try testing.expect(findAnyTextContaining(whole.root, "Create an identity and Plaza sets you up"));
    try testing.expect(!findAnyTextContaining(whole.root, "is missing from this install"));
}

test "the executable's own directory is where the probe looks" {
    // The half of the resolver that `resolveSibling`'s test cannot reach. If
    // this ever returns null, or a relative path, or a directory Plaza was not
    // launched from, `resolveHelper` declares a missing keyholder on an install
    // that is perfectly fine and the app tells the reader to reinstall it. That
    // is the failure mode of trusting argv[0], which is what this replaced, so
    // the replacement is worth pinning.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = main.exeDirForTest(std.testing.io, &buf) orelse return error.NoExecutableDir;
    try testing.expect(dir.len > 0);
    try testing.expectEqual(@as(u8, '/'), dir[0]);
    // And it is a directory that exists, so formatting a sibling onto it and
    // asking whether that file is there is a question with a real answer.
    var probe: [std.fs.max_path_bytes + 64]u8 = undefined;
    try testing.expectEqual(
        @as(usize, 0),
        main.resolveSiblingForTest(std.testing.io, &probe, dir, "a-binary-plaza-does-not-ship"),
    );
    try std.Io.Dir.cwd().access(std.testing.io, dir, .{});
}

test "the dead rung stops looking like it works" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;

    // Normally it is THE recommendation: the one accent-filled rung on the
    // ladder, a button, a focus stop.
    {
        const tree = try buildTree(arena_state.allocator(), &model);
        const w = findByLabel(tree.root, "Create your identity") orelse return error.NoRung;
        try testing.expectEqual(canvas.WidgetRole.button, w.semantics.role);
        try testing.expect(w.semantics.focusable);
        const p = try painted.Painted.render(arena_state.allocator(), &model);
        const fill = p.fillAtCenterOf("Create your identity") orelse return error.RungPaintsNothing;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }

    // With no keyholder it must not merely stop working. A rung that still
    // wears the accent and still says button, while doing nothing, is worse
    // than one that plainly cannot: the reader presses it, twice, and concludes
    // the app is broken rather than the install. Press-and-text assertions
    // cannot see any of this, which is why the paint is sampled.
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    const tree = try buildTree(arena_state.allocator(), &model);
    const w = findByLabel(tree.root, "Create your identity") orelse return error.NoRung;
    try testing.expectEqual(canvas.WidgetRole.text, w.semantics.role);
    try testing.expect(!w.semantics.focusable);
    const p = try painted.Painted.render(arena_state.allocator(), &model);
    if (p.fillAtCenterOf("Create your identity")) |fill| {
        try testing.expect(!painted.sameColor(fill, theme.palette.accent));
    }
}

test "a restored Notary session on an install with no Notary says so, and does not say starting" {
    // The reader this is for signed in on a working install and updated into a
    // broken one: `restoreSession` runs BEFORE the probe, so they are signed
    // straight back in and the status bar is the only thing that can tell them.
    // "Notary starting" is what an unwritten health state reads as, and it is a
    // word that means wait a moment about a condition that never resolves.
    main.setIdentityForTest([_]u8{0x3C} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);

    try testing.expect(!main.signerIsHealthy());
    try testing.expectEqualStrings("Notary is not installed", main.signerStatusLabelForTest());
}
/// Every widget that can be pressed has to occupy room on screen.
///
/// A control laid out at zero width is not merely invisible. Its siblings are
/// positioned after it as though it were not there, so the next thing in the row
/// is drawn on top of whatever the control painted outside its own box. That is
/// what turned the thread header into one smear of "Starter pack", "Thread" and
/// the reply count in the same place, and what left the bunker card's way back
/// looking like a stray mark next to its own title.
///
/// Nothing structural can see it. The tree is correctly nested either way, and
/// mouse input works either way, because a press hit-tests to the deepest widget
/// and walks UP to the nearest ancestor claiming one. Only a laid-out frame says
/// so, which is why this measures.
fn expectNoZeroSizedPressables(arena: std.mem.Allocator, name: []const u8, m: *main.Model) !void {
    const tree = try buildTree(arena, m);
    const p = try painted.Painted.render(arena, m);
    for (p.layout.nodes) |n| {
        const w = n.widget;
        if (w.frame.width > 0.5 and w.frame.height > 0.5) continue;
        var pressable = false;
        for (tree.handlers) |h| {
            if (h.id == w.id and h.event == .press) pressable = true;
        }
        if (!pressable) continue;
        std.debug.print(
            "{s}: a pressable {s} labelled \"{s}\" is laid out at {d:.1}x{d:.1}\n",
            .{ name, @tagName(w.kind), w.semantics.label, w.frame.width, w.frame.height },
        );
        return error.ZeroSizedControl;
    }
}

test "no control that can be pressed is laid out at nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // One model walked through the screens, because a Model is far too large to
    // hold several of on the stack.
    var m = main.initialModel();
    m.stage = .ready;
    try expectNoZeroSizedPressables(arena, "feed", &m);

    m.viewing_thread = 12345;
    try expectNoZeroSizedPressables(arena, "thread", &m);
    m.viewing_thread = 0;

    m.joining = true;
    try expectNoZeroSizedPressables(arena, "join ladder", &m);
    m.bunker_mode = true;
    try expectNoZeroSizedPressables(arena, "bunker card", &m);
    m.joining = false;
    m.bunker_mode = false;

    m.naming = true;
    try expectNoZeroSizedPressables(arena, "name card", &m);
    m.naming = false;

    m.notifications_open = true;
    try expectNoZeroSizedPressables(arena, "notifications", &m);
    m.notifications_open = false;

    m.viewing_profile = [_]u8{0x2B} ** 32;
    try expectNoZeroSizedPressables(arena, "profile", &m);
    m.viewing_profile = null;

    m.stage = .settings;
    try expectNoZeroSizedPressables(arena, "settings", &m);
    m.stage = .onboarding;
    try expectNoZeroSizedPressables(arena, "welcome", &m);
}

test "a header's back control does not sit under the title" {
    // The consequence, stated as geometry: the thread header's three pieces are
    // laid out one after another, not on top of each other. Before the back
    // control took up room, "Thread" began at the back control's own x plus the
    // row gap, i.e. inside the chevron and across the label.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var m = main.initialModel();
    m.stage = .ready;
    m.viewing_thread = 12345;
    const p = try painted.Painted.render(arena_state.allocator(), &m);

    const back = p.frameOf("Back") orelse return error.NoBackControl;
    try testing.expect(back.width > 0);

    const title = frameOfText(p, "Thread") orelse return error.NoTitle;
    // The title starts after the back control ends. Anything less and they are
    // painting over one another.
    try testing.expect(title.x >= back.x + back.width);
}
test "Settings offers a look at Notary, and only when there is one to look at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.setSignerKindForTest("local");
    defer main.setNotaryWindowFoundForTest(false);

    var model = main.initialModel();
    model.stage = .settings;

    // Notary holds the key and the window is installed beside Plaza: the row
    // that says so gets a way to go and look.
    main.setSignerKindForTest("helper");
    main.setNotaryWindowFoundForTest(true);
    {
        const p = try painted.Painted.render(arena, &model);
        const msg = pressMsgByLabel(p.tree, "Open Notary") orelse {
            std.debug.print("no way to open Notary from Settings\n", .{});
            return error.NoDoor;
        };
        try testing.expectEqualStrings(@tagName(Msg.open_notary_window), @tagName(msg));
    }

    // A remote signer is somebody else's process on somebody else's machine, so
    // Notary has nothing to show about it.
    main.setSignerKindForTest("remote");
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Open Notary") == null);
    }

    // And an install that arrived without the window must not offer a press that
    // opens nothing, which is the whole class of fault this release is about.
    main.setSignerKindForTest("helper");
    main.setNotaryWindowFoundForTest(false);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Open Notary") == null);
    }
}

test "a second Notary window is refused out loud, ceremony or not" {
    // The toast used to be said only while a CEREMONY was running, because that
    // was the only thing that could spawn this window. Opening it from Settings
    // twice was a press that did nothing, silently, which is exactly what the
    // toast exists to prevent.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "none", "running" }) |state| {
        main.setCeremonyForTest(if (std.mem.eql(u8, state, "running")) .running else .none);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
        if (model.toast_until == 0) {
            std.debug.print("a refused spawn said nothing with the ceremony {s}\n", .{state});
            return error.SilentRefusal;
        }
    }

    // And it is said where the press was MADE. The control that raises this
    // lives in Settings, and the toast was drawn on the feed screen only: the
    // model held a message nobody could see, which is the same silence with a
    // passing unit test in front of it.
    main.setCeremonyForTest(.none);
    var model = main.initialModel();
    model.stage = .settings;
    main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
    const p = try painted.Painted.render(arena, &model);
    if (findAnyText(p.tree.root, "A Notary window is already open") == null) {
        std.debug.print("the refusal is in the model but not on the screen\n", .{});
        return error.ToastNotDrawn;
    }
}
test "a follow that could not be written says why instead of nothing" {
    // Not the case where the app is still reading your list: that one is handled
    // properly already, with the button disabled and a sentence under the counts
    // saying so. This is the one with no gate in front of it.
    //
    // The built-in signer signs one thing at a time. Press Follow while a
    // signature is already out and the write is refused, and every affordance
    // for it looks perfectly live: the button is enabled, the menu row is not
    // greyed, and the press did nothing at all. That window is a second or two
    // for a local key and as long as an approval prompt takes for a Notary one.
    defer main.resetOutboxForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{119} ** 32);
    main.setIdentityForTest([_]u8{119} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.forgetOwnListMemoForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    defer main.setSignerKindLocalForTest();
    defer main.releaseHelperSignForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/saywhy.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // A real list of their own, so nothing else can be the reason.
    var tags: [40]nostr.event.Tag = undefined;
    var hexes: [40][64]u8 = undefined;
    for (0..40) |i| {
        _ = try std.fmt.bufPrint(&hexes[i], "{x:0>2}{s}", .{ @as(u8, @intCast(i)), "cd" ** 31 });
        const pair = try arena.alloc([]const u8, 2);
        pair[0] = "p";
        pair[1] = &hexes[i];
        tags[i] = pair;
    }
    const mine = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, mine, signer);
    main.ingestContactListForTest(mine);
    try testing.expect(main.canWriteFollows());

    var stranger: [32]u8 = undefined;
    @memset(&stranger, 0x5a);

    var model = main.Model{};
    model.stage = .ready;
    model.viewing_profile = stranger;
    model.toast_len = 0;
    model.toast_until = 0;
    var fx: main.EffectsForTest = undefined;

    // A signature is already out.
    main.holdHelperSignForTest();
    main.update(&model, main.Msg{ .follow_person = 1 }, &fx);

    // The stranger was not added, which is correct and is not the point.
    try testing.expect(!main.isFollowedByMe(stranger));

    // The point: the reader was told, rather than left pressing a live-looking
    // button that does nothing.
    if (model.toast_len == 0) return error.RefusedInSilence;
    const said = model.toast_buf[0..model.toast_len];
    if (std.mem.indexOf(u8, said, "signer") == null) {
        std.debug.print("\nthe app said \"{s}\"\n", .{said});
        return error.SaidTheWrongThing;
    }

    // And once the signature comes back, the same press works.
    main.releaseHelperSignForTest();
    main.silenceTestSignerForTest(false); // the keyholder answers again
    model.toast_len = 0;
    main.update(&model, main.Msg{ .follow_person = 1 }, &fx);
    try testing.expect(main.isFollowedByMe(stranger));
}
test "the composer actually attaches the tags to the event it publishes" {
    // The parser being right is half of it. This pins the other half: that
    // `submitPost` calls it at all. A correct `contentTags` that nobody invokes
    // publishes exactly the empty tag array this whole change exists to fix,
    // and every other seam here stops short of the event that goes out.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("first light on #Nostr with https://example.com/x.jpg");
    try testing.expect(main.submitPostForTest(&model, &fx));

    const tags = main.lastPublishedTagsForTest();
    const t = tagNamed(tags, "t") orelse return error.TagsNeverReachedTheEvent;
    try testing.expectEqualStrings("nostr", t[1]);
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaOnEvent;
    try testing.expectEqualStrings("url https://example.com/x.jpg", im[1]);
}

test "a github raw link is canonicalised so the picture actually renders" {
    // github.com/<owner>/<repo>/raw/<path> is a 302 whose own response is
    // content-type text/html, so clients that check the type before inlining
    // refuse to draw it and the note lands as text with a link in it. The
    // raw.githubusercontent.com form serves the same bytes as image/jpeg.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x44} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("shipping https://github.com/zig-nostr/plaza/raw/main/docs/shots/hero.jpg");
    try testing.expect(main.submitPostForTest(&model, &fx));

    // The imeta names the rewritten URL, which is only correct if the content
    // was rewritten too: NIP-92 pairs the tag with a URL in the content.
    const im = tagNamed(main.lastPublishedTagsForTest(), "imeta") orelse return error.NoImetaTag;
    try testing.expectEqualStrings(
        "url https://raw.githubusercontent.com/zig-nostr/plaza/main/docs/shots/hero.jpg",
        im[1],
    );
    try testing.expectEqualStrings("m image/jpeg", im[2]);
}

test "a reply reaches everyone already in the thread" {
    // A reply that tags only the person being answered is one the rest of the
    // conversation never hears about, so they answer into a thread that has
    // moved on. Amethyst p-tags every author in the thread plus the parent's
    // own mentions; Jumble the parent author plus the parent's p tags. This is
    // the authors, which is the part Plaza retains.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    main.setIdentityForTest([_]u8{0x66} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    model.thread_root.id = 1;
    model.thread_root.event_id = [_]u8{0xa1} ** 32;
    model.thread_root.pubkey = [_]u8{0xb2} ** 32;

    // Two other people in the thread, one of them twice, plus the root author
    // again and the replier themselves. Only the two distinct others are new.
    // The replier's own key is the DERIVED pubkey, not the secret handed to
    // setIdentityForTest. Planting the secret's bytes here would leave the
    // self-filter untested while the test still looked like it covered it.
    const mine = main.activePubkeyForTest() orelse return error.NoIdentity;
    const others = [_][32]u8{
        [_]u8{0xc3} ** 32,
        [_]u8{0xd4} ** 32,
        [_]u8{0xc3} ** 32,
        [_]u8{0xb2} ** 32,
        mine,
    };
    for (others, 0..) |pk, i| {
        model.thread_notes[i] = .{ .created_at = 1_800_000_000 };
        model.thread_notes[i].id = @intCast(700 + i);
        model.thread_notes[i].pubkey = pk;
    }
    model.thread_notes_len = others.len;

    var fx: main.EffectsForTest = undefined;
    model.reply_buffer.set("agreed, and one more thing");
    main.update(&model, main.Msg.reply_submit, &fx);

    const tags = main.lastPublishedTagsForTest();
    // The root author plus the two distinct others. Not the duplicate, not the
    // root author twice, and never the replier: your own inbox lighting up for
    // your own reply is a bug a reader would report as one.
    try testing.expectEqual(@as(usize, 3), countTags(tags, "p"));

    var mine_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&mine_hex, "{x}", .{&mine}) catch unreachable;
    var saw_self = false;
    var saw_root = false;
    for (tags) |t| {
        if (t.len < 2 or !std.mem.eql(u8, t[0], "p")) continue;
        if (std.mem.eql(u8, t[1], &mine_hex)) saw_self = true;
        if (std.mem.startsWith(u8, t[1], "b2b2")) saw_root = true;
    }
    try testing.expect(saw_root);
    try testing.expect(!saw_self);
}

test "switching somebody off keeps them out of the note" {
    // The chips promise they name exactly who gets tagged. That only holds if
    // the row the reader sees and the tags the event carries come from one
    // derivation, and if switching a name off actually reaches the publish path.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var one = [_]u8{0} ** 32;
    one[0] = 0x11;
    var two = [_]u8{0} ** 32;
    two[0] = 0x22;
    const npub_one = try nostr.nip19.encodeNpub(gpa, one);
    const npub_two = try nostr.nip19.encodeNpub(gpa, two);
    const body = try std.fmt.allocPrint(gpa, "nostr:{s} and nostr:{s}", .{ npub_one, npub_two });

    // Both are derived, and the chips are built from this same call.
    var people: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), main.notifiedByForTest(body, &people));

    model.draft_buffer.set(body);
    main.clearLastPublishedTagsForTest();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expectEqual(@as(usize, 2), countTags(main.lastPublishedTagsForTest(), "p"));

    // Switch the first one off and post again. One tag, and it is the other.
    model.composing = true;
    model.draft_buffer.set(body);
    main.update(&model, main.Msg{ .toggle_mention_off = one }, &fx);
    main.clearLastPublishedTagsForTest();
    try testing.expect(main.submitPostForTest(&model, &fx));

    const tags = main.lastPublishedTagsForTest();
    try testing.expectEqual(@as(usize, 1), countTags(tags, "p"));
    const p = tagNamed(tags, "p") orelse return error.NoMentionTag;
    try testing.expect(std.mem.startsWith(u8, p[1], "2200"));

    // Pressing it again puts them back: the chip is a toggle, not a delete.
    model.composing = true;
    model.draft_buffer.set(body);
    main.update(&model, main.Msg{ .toggle_mention_off = one }, &fx);
    main.clearLastPublishedTagsForTest();
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expectEqual(@as(usize, 2), countTags(main.lastPublishedTagsForTest(), "p"));
}
test "a repost carries the tags other clients read it by" {
    main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x41} ** 32);
    defer {
        main.resetEngagementForTest();
        main.clearIdentityForTest();
    }
    main.clearLastPublishedTagsForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x43} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "worth passing on");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .repost = id }, &fx);

    const tags = main.lastPublishedTagsForTest();
    const e = tagNamed(tags, "e") orelse return error.NoETagOnTheRepost;
    const p = tagNamed(tags, "p") orelse return error.NoPTagOnTheRepost;

    var id_hex: [64]u8 = undefined;
    var author_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&id_hex, "{x}", .{ev.id});
    _ = try std.fmt.bufPrint(&author_hex, "{x}", .{ev.pubkey});

    try testing.expectEqualStrings(&id_hex, e[1]);
    try testing.expectEqualStrings(&author_hex, p[1]);

    // Four fields, and the THIRD is the empty relay hint. This is the one that
    // matters to get right and the easy one to get wrong: the author belongs in
    // the fourth field, so dropping the empty hint would slide the pubkey into
    // the hint's place and tell every reader to dial it as a relay.
    try testing.expectEqual(@as(usize, 4), e.len);
    try testing.expectEqualStrings("", e[2]);
    try testing.expectEqualStrings(&author_hex, e[3]);

    // No `k` tag. Jumble and NDK both add one only for a kind other than 1, and
    // every note in this feed is a kind:1.
    try testing.expect(tagNamed(tags, "k") == null);
}
test "a test identity signs the way the app does, through the keyholder" {
    // The suite's ~400 "be somebody" tests used to hold a secret key in this
    // process and sign inline. Plaza does not do that any more, so neither do
    // they: the shim knows a pubkey and asks a keyholder, and the keyholder in
    // a test is a stand-in that answers the way the daemon does.
    //
    // Worth pinning, because the suite passes either way. Nothing else asserts
    // WHICH path produced a signature, so without this a change could quietly
    // put four hundred tests back on a code path the app no longer has.
    const secret = [_]u8{0x77} ** 32;
    main.setIdentityForTest(secret);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey(secret);

    // Asking a keyholder, with no secret key in this process, and the account
    // is still ours.
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());
    try testing.expect(!main.holdsKeyInProcessForTest());
    try testing.expectEqualSlices(u8, &kp.public_key, &main.activePubkeyForTest().?);

    var fx: main.EffectsForTest = undefined;
    main.signAndPublishForTest(&fx, 1_800_000_000, 1, &.{}, "through the keyholder");

    const published = main.lastPublishedForTest() orelse return error.NothingPublished;
    // A real signature over the real content, by the account we said we were.
    try testing.expectEqualSlices(u8, &kp.public_key, &published.pubkey);
    try testing.expect(try nostr.event.verify(testing.allocator, signer, published));
}

test "the keyholder's secret is minted fresh and never written down" {
    // The whole local security model is this one property. Plaza used to hand
    // its signer a token through a 0600 file, which is the shape every local
    // signing agent uses and the shape none of them defends: file permissions
    // separate USERS, not apps, so every app you run could read it and sign as
    // you. Measured on this machine, along with the other two places a secret
    // leaks: a process's argv (`ps` prints it) and its environment (`ps -Eww`
    // prints it). A pipe to a child has no name and no path, so there is
    // nothing to open.
    const io = testing.io;
    main.mintHelperSecretForTest(io);
    const first = try testing.allocator.dupe(u8, main.helperSecretForTest());
    defer testing.allocator.free(first);

    try testing.expect(first.len >= 32);
    // Newline-terminated, because the daemon's read needs something to stop on.
    try testing.expectEqual(@as(u8, '\n'), first[first.len - 1]);
    // The header presents it without the terminator.
    try testing.expectEqualStrings(first[0 .. first.len - 1], main.helperTokenForTest());

    // Fresh per launch. Two runs sharing a secret would mean a secret that
    // outlives the process that minted it, which is a secret worth stealing.
    main.mintHelperSecretForTest(io);
    try testing.expect(!std.mem.eql(u8, first, main.helperSecretForTest()));
}

test "nothing is sent to the keyholder before it says where it is" {
    // The daemon takes a kernel-chosen port and reports it on stdout, so
    // between the spawn and that line there is no address at all. Sending to
    // port zero would be a request nobody could answer, and the caller would
    // read the failure as a signer that is not working.
    // The daemon is answering AND holding a key, so the only thing standing
    // between Plaza and a request is not knowing the address. Without that
    // being the only difference this test passes for the wrong reason, which is
    // how it passed with the guard removed.
    main.setHelperReadyForTest();
    main.setHelperPortForTest(0);
    defer main.setHelperPortForTest(0);
    try testing.expect(!main.helperReachableForTest());

    // Told the port, and now it is reachable.
    main.setHelperPortForTest(51234);
    try testing.expect(main.helperReachableForTest());

    // And a port it has NOT heard is not one it invents. This is the constant
    // that used to be here.
    main.setHelperPortForTest(8790);
    try testing.expectEqual(@as(u16, 8790), main.helperPortForTest());
}

test "an event signed by somebody else is not published under your name" {
    // The keyholder is a separate product now. Its key can be changed, removed
    // or replaced between the moment Plaza asked whose key it was and the
    // moment an answer comes back, so what it returns is checked rather than
    // trusted. The old comment here said "it came from our own daemon over
    // authenticated loopback", which was true when Plaza built and shipped that
    // daemon and stopped being true when it did not.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x21} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    // A perfectly valid event, signed by a real key, that is not the reader's.
    var other = nostr.keys.Signer.init();
    defer other.deinit();
    const other_kp = try other.keyPairFromSecretKey([_]u8{0x22} ** 32);
    const theirs = try nostr.event.create(arena, other, other_kp, 1_800_000_000, 1, &.{}, "under your name", null);
    const theirs_json = try nostr.event.toJson(arena, theirs);
    const body = try (nostr.signer_ipc.SignEvent{ .event = theirs_json }).toJson(arena);

    main.deliverHelperSignedForTest(body);

    // Nothing was published. A signature proves the event was signed by the key
    // it names; it says nothing about WHOSE key that is, and publishing on that
    // alone puts a note on relays under an account nobody is signed in to.
    if (main.lastPublishedForTest()) |ev| {
        std.debug.print("\npublished an event by {x} while signed in as somebody else\n", .{ev.pubkey});
        return error.PublishedSomebodyElsesEvent;
    }
}

test "an event whose signature does not check is not published either" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const secret = [_]u8{0x23} ** 32;
    main.setIdentityForTest(secret);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey(secret);
    var ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, "tampered", null);
    // The right author, and a signature that is not one. Whoever is answering
    // could be anything; the account is only as safe as what is checked.
    ev.sig[0] ^= 0xff;
    const json = try nostr.event.toJson(arena, ev);
    const body = try (nostr.signer_ipc.SignEvent{ .event = json }).toJson(arena);

    main.deliverHelperSignedForTest(body);
    try testing.expect(main.lastPublishedForTest() == null);
}

test "the note's deadline and the wire's are one number" {
    // They were two, and they disagreed. The fetch carried no timeout at all,
    // so the SDK's thirty-second default applied while the app-side backstop
    // fired at ten.
    //
    // The gap is worse than a slow note. At ten seconds Plaza restores the
    // draft and says the sign failed, while the request is still live; an
    // answer at twenty then publishes an event the reader was just told had
    // failed. For those twenty seconds `signerReady` reports true because the
    // slot is clear, while the effect key is still held, so the next sign is
    // rejected by the SDK and silently does nothing.
    //
    // Latent while the keyholder answered in a millisecond and could do nothing
    // else. Notary can refuse and ask a person, and that answer comes back on a
    // human timescale.
    try testing.expectEqual(
        @as(u32, @intCast(main.helperSignTimeoutSecondsForTest() * 1000)),
        main.helperSignTimeoutMillisForTest(),
    );
    // And long enough to be worth having: a person has to see the prompt and
    // reach for it.
    try testing.expect(main.helperSignTimeoutSecondsForTest() >= 20);
}

test "a locked keyholder is not an empty one" {
    // Plaza tested only for "ready" and read every other answer as "reachable,
    // no key here". So a Notary holding a key it cannot use yet looked like a
    // Notary holding nothing.
    //
    // The library's contract names this as the mistake worth designing the
    // vocabulary against: a client that believes a keyholder is empty offers to
    // make a key over the top of an identity somebody already has, and a nostr
    // key cannot be replaced. Nothing was destroyed, because Notary refuses a
    // second setup, but the reader pressed "Create your identity", got a toast,
    // and was never offered the one thing that would have worked.
    var model = main.initialModel();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    const pk = "ab" ** 32;
    var buf: [256]u8 = undefined;
    const locked = try std.fmt.bufPrint(&buf, "{{\"state\":\"locked\",\"pubkey\":\"{s}\"}}", .{pk});
    main.deliverHelperPubkeyForTest(&model, locked);

    try testing.expectEqual(main.HelperState.locked, main.helperStateForTest());
    // And the screen says which of the two it is, because they want opposite
    // things from the reader: one wants a key, the other wants a passphrase.
    try testing.expectEqualStrings("Notary is locked", main.signerStatusLabelForTest());
    // Holding a key is not signing.
    try testing.expect(!main.signerIsHealthy());

    // An answer this app does not recognise counts as "cannot sign", never as
    // "no key yet", which is the rule stated beside the constants.
    var other: [128]u8 = undefined;
    const future = try std.fmt.bufPrint(&other, "{{\"state\":\"something-new\",\"pubkey\":\"{s}\"}}", .{pk});
    main.deliverHelperPubkeyForTest(&model, future);
    try testing.expect(main.helperStateForTest() != .empty);
    try testing.expect(!main.signerIsHealthy());

    // Empty really is empty, and says so.
    main.deliverHelperPubkeyForTest(&model, "{\"state\":\"uninitialized\",\"pubkey\":\"\"}");
    try testing.expectEqual(main.HelperState.empty, main.helperStateForTest());
    try testing.expectEqualStrings("Notary has no key", main.signerStatusLabelForTest());
}

test "a queued setup never fires at a keyholder that already holds a key" {
    // Offering to create a key over the top of an existing identity is the one
    // mistake the protocol's state vocabulary exists to prevent, because a
    // nostr key cannot be replaced. Notary refuses a second setup, so nothing
    // is destroyed, but the reader presses "Create your identity" and gets a
    // toast instead of the passphrase box that would have worked.
    try testing.expect(main.helperSetupMayFireForTest(true, .empty));

    try testing.expect(!main.helperSetupMayFireForTest(true, .locked));
    try testing.expect(!main.helperSetupMayFireForTest(true, .ready));
    try testing.expect(!main.helperSetupMayFireForTest(true, .starting));
    try testing.expect(!main.helperSetupMayFireForTest(true, .unreachable_));

    // And nothing goes out when nothing was asked for.
    try testing.expect(!main.helperSetupMayFireForTest(false, .empty));
}
test "no secret key can live in this process" {
    // The property the whole consolidation exists for, asserted rather than
    // described. Plaza held its identity in `g_identity_kp` and wrote it to
    // `~/.plaza/identity.key` at mode 0600, which sounds protective and is not:
    // file permissions separate USERS, not apps, so every app on the machine
    // could read it. A nostr identity is the one thing that cannot be replaced
    // after it leaks.
    //
    // There is now no field in this program that can hold one, so this is a
    // constant. It is here to fail the day somebody adds one back.
    const secret = [_]u8{0x31} ** 32;
    main.setIdentityForTest(secret);
    defer main.clearIdentityForTest();

    try testing.expect(!main.holdsKeyInProcessForTest());
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());

    // Signed in all the same: the account is known by its pubkey, and the
    // signatures come from the keyholder.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey(secret);
    try testing.expectEqualSlices(u8, &kp.public_key, &main.activePubkeyForTest().?);
}
test "the rail opens search, signed in or not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Shipped behind Cmd+L and a row in the account menu, which is a menu about
    // identity and settings. Going to a note somebody sent you is navigation,
    // so the only visible way to it sat behind the avatar.
    //
    // Both identity states, because reading needs no key: a link somebody sent
    // is one of the first things a person who has not signed in arrives with.
    main.clearIdentityForTest();
    {
        var model = main.initialModel();
        model.stage = .ready;
        const tree = try buildTree(arena, &model);
        const msg = pressMsgByLabel(tree, "Search") orelse return error.GuestRailHasNoAddressTile;
        switch (msg) {
            .open_address => {},
            else => return error.RailTileGoesSomewhereElse,
        }
    }

    main.setIdentityForTest([_]u8{0x3a} ** 32);
    defer main.clearIdentityForTest();
    {
        var model = main.initialModel();
        model.stage = .ready;
        const tree = try buildTree(arena, &model);
        const msg = pressMsgByLabel(tree, "Search") orelse return error.SignedInRailHasNoAddressTile;
        switch (msg) {
            .open_address => {},
            else => return error.RailTileGoesSomewhereElse,
        }
    }
}
test "the composer can set a content warning, with or without a reason" {
    main.setIdentityForTest([_]u8{0x34} ** 32);
    defer main.clearIdentityForTest();
    var fx: main.EffectsForTest = undefined;

    // With a reason.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.composing = true;
        main.clearLastPublishedTagsForTest();
        model.draft_buffer.set("a note I want covered");
        model.warn_on = true;
        model.warn_buffer.set("  nudity  ");
        try testing.expect(main.submitPostForTest(&model, &fx));
        const tag = tagNamed(main.lastPublishedTagsForTest(), "content-warning") orelse return error.NoWarningTag;
        try testing.expectEqual(@as(usize, 2), tag.len);
        try testing.expectEqualStrings("nudity", tag[1]);
        // One warning per note: the next one starts clean.
        try testing.expect(!model.warn_on);
        try testing.expectEqual(@as(usize, 0), model.warn_draft().len);
    }
    // On with no reason: still a tag, because the tag is what covers it.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.composing = true;
        main.clearLastPublishedTagsForTest();
        model.draft_buffer.set("covered, no reason given");
        model.warn_on = true;
        try testing.expect(main.submitPostForTest(&model, &fx));
        const tag = tagNamed(main.lastPublishedTagsForTest(), "content-warning") orelse return error.NoWarningTag;
        try testing.expectEqualStrings("", tag[1]);
    }
    // Off: no tag at all, even with text left in the reason field.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.composing = true;
        main.clearLastPublishedTagsForTest();
        model.draft_buffer.set("an ordinary note");
        model.warn_buffer.set("stale reason");
        try testing.expect(main.submitPostForTest(&model, &fx));
        try testing.expect(tagNamed(main.lastPublishedTagsForTest(), "content-warning") == null);
    }
}

test "a draft handed back after a failed sign keeps its content warning" {
    // A note whose warning did not come back with it is one press from going out
    // uncovered.
    main.setIdentityForTest([_]u8{0x4e} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("the sentence I actually wanted to publish");
    model.warn_on = true;
    model.warn_buffer.set("spoilers");
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(model.draft_empty());
    try testing.expect(!model.warn_on);

    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 409, .body = "" });
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("the sentence I actually wanted to publish", model.draft());
    try testing.expect(model.warn_on);
    try testing.expectEqualStrings("spoilers", model.warn_draft());
}
test "a line break in the warning reason does not reach the tag" {
    main.setIdentityForTest([_]u8{0x35} ** 32);
    defer main.clearIdentityForTest();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.clearLastPublishedTagsForTest();
    model.draft_buffer.set("a note");
    model.warn_on = true;
    model.warn_buffer.set("first line\nsecond line\r\n\tthird");
    try testing.expect(main.submitPostForTest(&model, &fx));
    const tag = tagNamed(main.lastPublishedTagsForTest(), "content-warning") orelse return error.NoWarningTag;
    for (tag[1]) |c| try testing.expect(c >= 0x20 and c != 0x7f);
    try testing.expect(std.mem.startsWith(u8, tag[1], "first line"));
    try testing.expect(std.mem.indexOf(u8, tag[1], "second line") != null);
    try testing.expect(std.mem.endsWith(u8, tag[1], "third"));
    // And a reader's side of it: the reason is shown, not dropped as malformed.
    const read = main.contentWarningIn(&.{tag}).?;
    try testing.expect(read.len > 0);
}
test "a like, a repost and a reply name where the note lives" {
    defer main.resetOutboxForTest();
    freshHints();
    defer freshHints();
    main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x55} ** 32);
    defer {
        main.resetEngagementForTest();
        main.clearIdentityForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x56} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/tags.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "worth answering");
    // The author writes to B, and A is where this reader got the note.
    _ = try main.plazaIngestForTest(arena, ev);
    _ = try main.plazaIngestForTest(arena, try relayListFor(arena, signer, kp, &.{hint_b}));
    main.recordSeenOnForTest(ev.id, hint_a);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;
    var fx: main.EffectsForTest = undefined;

    // Like: the hint closes both tags, per NIP-25.
    main.clearLastPublishedTagsForTest();
    main.update(&model, Msg{ .like = id }, &fx);
    {
        const tags = main.lastPublishedTagsForTest();
        const e = tagNamed(tags, "e") orelse return error.NoETag;
        const p = tagNamed(tags, "p") orelse return error.NoPTag;
        try testing.expectEqual(@as(usize, 3), e.len);
        try testing.expectEqualStrings(hint_a, e[2]);
        // The person's tag points at where THEY publish, not at where one note was.
        try testing.expectEqual(@as(usize, 3), p.len);
        try testing.expectEqualStrings(hint_b, p[2]);
    }

    // Repost: the hint fills the empty third slot and the author stays fourth.
    main.clearLastPublishedTagsForTest();
    main.update(&model, Msg{ .repost = id }, &fx);
    {
        const tags = main.lastPublishedTagsForTest();
        const e = tagNamed(tags, "e") orelse return error.NoETag;
        const p = tagNamed(tags, "p") orelse return error.NoPTag;
        try testing.expectEqual(@as(usize, 4), e.len);
        try testing.expectEqualStrings(hint_a, e[2]);
        var author_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&author_hex, "{x}", .{ev.pubkey});
        try testing.expectEqualStrings(&author_hex, e[3]);
        try testing.expectEqualStrings(hint_b, p[2]);
    }

    // Reply: the root marker stays in slot four.
    main.clearLastPublishedTagsForTest();
    model.viewing_thread = id;
    model.thread_root = model.notes[0];
    model.reply_buffer.set("agreed");
    main.update(&model, Msg.reply_submit, &fx);
    {
        const tags = main.lastPublishedTagsForTest();
        const e = tagNamed(tags, "e") orelse return error.NoETag;
        const p = tagNamed(tags, "p") orelse return error.NoPTag;
        try testing.expectEqual(@as(usize, 4), e.len);
        try testing.expectEqualStrings(hint_a, e[2]);
        try testing.expectEqualStrings("root", e[3]);
        try testing.expectEqualStrings(hint_b, p[2]);
    }
}

test "with nothing known the tags are exactly what they were" {
    freshHints();
    defer freshHints();
    main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x57} ** 32);
    defer {
        main.resetEngagementForTest();
        main.clearIdentityForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x58} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "no one has said where");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;
    var fx: main.EffectsForTest = undefined;

    main.clearLastPublishedTagsForTest();
    main.update(&model, Msg{ .like = id }, &fx);
    {
        const tags = main.lastPublishedTagsForTest();
        try testing.expectEqual(@as(usize, 2), (tagNamed(tags, "e") orelse return error.NoETag).len);
        try testing.expectEqual(@as(usize, 2), (tagNamed(tags, "p") orelse return error.NoPTag).len);
    }
    main.clearLastPublishedTagsForTest();
    main.update(&model, Msg{ .repost = id }, &fx);
    {
        const e = tagNamed(main.lastPublishedTagsForTest(), "e") orelse return error.NoETag;
        try testing.expectEqual(@as(usize, 4), e.len);
        try testing.expectEqualStrings("", e[2]);
    }
    main.clearLastPublishedTagsForTest();
    model.viewing_thread = id;
    model.thread_root = model.notes[0];
    model.reply_buffer.set("agreed");
    main.update(&model, Msg.reply_submit, &fx);
    {
        const e = tagNamed(main.lastPublishedTagsForTest(), "e") orelse return error.NoETag;
        try testing.expectEqualStrings("", e[2]);
        try testing.expectEqualStrings("root", e[3]);
    }
}
test "an upload whose signer refuses, or never answers, fails without sending anything" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4d} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    const path = try writeTestPicture("upload-test-signer.png", 8, 8, "");
    defer testing.allocator.free(path);
    const srv = try blossom.TestServer.start(testing.io, .accept, 2);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 1 }, &fx);
    try awaitUpload("ready");

    // The keyholder holds the request, then refuses it.
    main.silenceTestSignerForTest(true);
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 409, .body = "" });
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("failed", main.uploadStateForTest());
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "signer did not approve") != null);
    // The composer's own failure notice is not raised for a token.
    try testing.expect(!main.helperSignNoticeForTest());
    main.driveUploadForTest(&model);
    try testing.expectEqual(@as(usize, 0), srv.heads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), srv.puts.load(.acquire));
}
test "a signer that answers an upload token with a note has nothing published, and the reverse loses no draft" {
    // The built-in keyholder is a separate product, so what it returns is
    // checked. An event of another kind where a token was asked for is not
    // what the reader approved, and the note path would have published it.
    main.forgetBlossomForTest();
    const secret = [_]u8{0x56} ** 32;
    main.setIdentityForTest(secret);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.setSignerKindLocalForTest();
    defer main.releaseHelperSignForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey(secret);
    const path = try writeTestPicture("upload-test-wrong-kind.png", 8, 8, "");
    defer testing.allocator.free(path);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.setSignerKindHelperForTest();
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());

    // The reader's own key and a good signature, on something they never wrote.
    const note = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, "never written by the reader", null);
    main.deliverHelperSignedForTest(try (nostr.signer_ipc.SignEvent{ .event = try nostr.event.toJson(arena, note) }).toJson(arena));
    try testing.expect(main.lastPublishedForTest() == null);
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("failed", main.uploadStateForTest());

    // And a token where a note was asked for: the note comes back to the
    // composer instead of going with the slot.
    main.dropUploadForTest();
    const draft = "the note that was out being signed";
    model.draft_buffer.set(draft);
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(model.draft_empty());
    const tags = try blossom.authTags(arena, "ab" ** 32, 1, 1_900_000_000);
    const token = try nostr.event.create(arena, signer, kp, 1_800_000_000, blossom.auth_kind, tags, blossom.auth_content, null);
    main.deliverHelperSignedForTest(try (nostr.signer_ipc.SignEvent{ .event = try nostr.event.toJson(arena, token) }).toJson(arena));
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings(draft, model.draft());
    try testing.expect(main.lastPublishedForTest() == null);
}
test "an upload token is never stored or published, whatever signed it" {
    main.setIdentityForTest([_]u8{0x4f} ** 32);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4f} ** 32);
    const tags = try blossom.authTags(a.allocator(), "ab" ** 32, 1, 1_900_000_000);
    const ev = try nostr.event.create(a.allocator(), signer, kp, 1_800_000_000, blossom.auth_kind, tags, "x", null);
    main.ingestAndPublishForTest(a.allocator(), ev);
    try testing.expect(main.lastPublishedForTest() == null);
}
test "a server address that is not an origin is refused in the field and nothing is written" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x55} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    var model = main.initialModel();
    model.stage = .settings;
    var fx: main.EffectsForTest = undefined;
    for ([_][]const u8{ "not a url", "http://cdn.example.com", "https://cdn.example.com/media", "https://user@cdn.example.com" }) |bad| {
        model.blossom_buffer.set(bad);
        main.update(&model, .blossom_add, &fx);
        try testing.expectEqualStrings("A server address starts with https:// and names a host.", model.blossom_status());
        // The field keeps what was typed, so it can be fixed.
        try testing.expectEqualStrings(bad, model.blossom_draft());
    }
    try testing.expect(!main.helperSignPendingForTest());
    // Typing answers the complaint.
    model.blossom_buffer.set("https://cdn.example.com");
    main.update(&model, .{ .blossom_edit = .{ .insert_text = "x" } }, &fx);
    try testing.expect(std.mem.indexOf(u8, model.blossom_status(), "starts with https") == null);
}
test "creating an identity with no key window says so instead of queueing a mint the daemon refuses" {
    // The daemon will not make a key without a passphrase, and the passphrase
    // is typed into Notary's window. With the window absent the press queued a
    // setup that came back "passphrase required" over a sheet that had already
    // closed: nothing happened, and nothing said why.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setKeyholderMissingForTest(false);
    main.setNotaryWindowFoundForTest(false);
    defer main.setNotaryWindowFoundForTest(false);
    main.setHelperUnreachableForTest();
    defer main.setHelperUnreachableForTest();
    try testing.expect(!main.helperSetupQueuedForTest());

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .join_create, &fx);

    try testing.expect(!main.helperSetupQueuedForTest());
    try testing.expect(model.is_guest());
    try testing.expect(std.mem.indexOf(u8, model.toast_text(), "key window is missing") != null);

    // The welcome screen's button goes through the same door.
    model.toast_until = 0;
    main.update(&model, .create_identity, &fx);
    try testing.expect(!main.helperSetupQueuedForTest());
    try testing.expect(std.mem.indexOf(u8, model.toast_text(), "key window is missing") != null);

    // And with no keyholder at all it is still a said refusal, not a silent one.
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    model.toast_until = 0;
    main.update(&model, .join_create, &fx);
    try testing.expectEqualStrings("Notary is missing from this install.", model.toast_text());
}

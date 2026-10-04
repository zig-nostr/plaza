//! Tests of own_profile.zig. The reader's own profile: reading it back, editing it, and publishing it.

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
const bookmarkFixture = harness.bookmarkFixture;
const FreshStore = harness.FreshStore;
const buildTree = harness.buildTree;
const closedMsg = harness.closedMsg;
const findAnyTextContaining = harness.findAnyTextContaining;
const findByText = harness.findByText;
const frameOfText = harness.frameOfText;
const pressableByLabel = harness.pressableByLabel;
const signInNothingFound = harness.signInNothingFound;
const threadNote = harness.threadNote;

test "a remembered intent replays once and only once" {
    var model = main.initialModel();
    model.stage = .ready;
    model.pending = .post;

    // Identity arrives: the composer opens by itself, the intent is spent.
    main.replayPendingForTest(&model);
    try testing.expect(model.composing);
    try testing.expect(!model.pending.waiting());

    // A second replay is a no-op: closing the sheet stays closed.
    model.composing = false;
    main.replayPendingForTest(&model);
    try testing.expect(!model.composing);
}
test "editing a profile keeps every field this app does not model" {
    // kind:0 is REPLACEABLE: what is published replaces the whole profile. Real
    // profiles carry a lightning address, a banner, a website and whatever else
    // their owner's other clients wrote. This app models three fields, so it
    // edits three keys and leaves the rest exactly where they were. Getting this
    // wrong silently stops somebody being paid.
    const existing =
        \\{"name":"alice","display_name":"Alice","about":"old bio","picture":"https://old.example.com/a.png",
        \\"lud16":"alice@getalby.com","banner":"https://ex.com/b.png","website":"https://alice.example",
        \\"nip05":"alice@example.com","pronouns":"she/her"}
    ;
    var model = main.initialModel();
    // Seeded the way the sheet seeds it from the published record, then edited.
    // The merge writes what the MODEL holds, so a field this app models and has
    // not read is a field it would delete: `profile_can_save` is what stops that
    // reaching a relay, and `the sheet refuses to save until it has read the
    // profile it would replace` is what holds it.
    main.seedProfileFieldsForTest(&model, existing, false);
    model.profile_name_buffer.set("Alice Liddell");
    model.profile_about_buffer.set("new bio");
    model.profile_picture_buffer.set("https://new.example.com/a.png");
    model.profile_lud16_buffer.set("alice@walletofsatoshi.com");

    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);

    // What the reader edited.
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\":\"Alice Liddell\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"about\":\"new bio\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"picture\":\"https://new.example.com/a.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"alice@walletofsatoshi.com\"") != null);
    // What they did not touch, but which the sheet now shows: carried through
    // from the published record rather than dropped.
    try testing.expect(std.mem.indexOf(u8, merged, "\"banner\":\"https://ex.com/b.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"website\":\"https://alice.example\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"nip05\":\"alice@example.com\"") != null);
    // And what this app still cannot see at all, which is the point of the merge.
    try testing.expect(std.mem.indexOf(u8, merged, "\"pronouns\":\"she/her\"") != null);
    // The handle is not the display name, and an account that already has one
    // keeps it: renaming yourself must not rename your @handle out from under
    // everyone who mentions you.
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\":\"alice\"") != null);
}

test "the fields Plaza reads are the fields Plaza can write" {
    // The gap this closes: `parseMetadataInto` and `parsePersonMetadata` read
    // nine keys and the sheet offered three, so an account set up only here had
    // no way to put in a lightning address and could not be zapped by anyone, in
    // any client, until its owner opened something else.
    const existing = "{\"name\":\"alice\",\"pronouns\":\"she/her\"}";
    var model = main.initialModel();
    main.seedProfileFieldsForTest(&model, existing, false);
    model.profile_name_buffer.set("Alice");
    model.profile_website_buffer.set("https://alice.example");
    model.profile_banner_buffer.set("https://ex.com/b.png");
    model.profile_lud16_buffer.set("alice@walletofsatoshi.com");
    model.profile_nip05_buffer.set("alice@example.com");

    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);

    try testing.expect(std.mem.indexOf(u8, merged, "\"website\":\"https://alice.example\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"banner\":\"https://ex.com/b.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"alice@walletofsatoshi.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"nip05\":\"alice@example.com\"") != null);
    // And the key it still cannot see comes through untouched.
    try testing.expect(std.mem.indexOf(u8, merged, "\"pronouns\":\"she/her\"") != null);
}

test "a published profile seeds every field the sheet shows" {
    // Seeding is what stands between the merge and deleting a key: the merge
    // writes what the MODEL holds, so a field shown but never read would be
    // published as absent.
    const existing =
        \\{"name":"alice","about":"bio","picture":"https://p.example/a.png",
        \\"website":"https://alice.example","banner":"https://b.example/x.png",
        \\"lud16":"alice@getalby.com","nip05":"alice@example.com"}
    ;
    var model = main.initialModel();
    main.seedProfileFieldsForTest(&model, existing, false);

    try testing.expectEqualStrings("bio", model.profile_about());
    try testing.expectEqualStrings("https://p.example/a.png", model.profile_picture());
    try testing.expectEqualStrings("https://alice.example", model.profile_website());
    try testing.expectEqualStrings("https://b.example/x.png", model.profile_banner());
    try testing.expectEqualStrings("alice@getalby.com", model.profile_lud16());
    try testing.expectEqualStrings("alice@example.com", model.profile_nip05());
}
test "an emptied profile field removes its key rather than blanking it" {
    // `"about": ""` reads to other clients as a bio deliberately blanked, which
    // is a different statement from not having one.
    const existing = "{\"name\":\"alice\",\"about\":\"old bio\",\"pronouns\":\"she/her\"}";
    var model = main.initialModel();
    model.profile_name_buffer.set("Alice");
    model.profile_about_buffer.set("   ");
    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "about") == null);
    // `pronouns` rather than `lud16`: the sheet shows a lightning address now,
    // so it is no longer an example of a key this app leaves alone.
    try testing.expect(std.mem.indexOf(u8, merged, "\"pronouns\":\"she/her\"") != null);
}

test "a profile with no handle gets one, and prose survives being prose" {
    // An account with no `name` at all gets one, so clients that read only
    // `name` have something to show. And a name with a quote in it is ESCAPED,
    // not stripped: dropping characters was a fixed-size buffer away from an
    // overflow, and it silently renamed people.
    var model = main.initialModel();
    model.profile_name_buffer.set("A \"quoted\" name \\ here");
    const merged = main.mergeProfileJsonForTest(testing.allocator, "{}", &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\\\"quoted\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\"") != null);
}

test "the name beat merges too, so it can never publish a name as the whole profile" {
    // The beat runs when there is nothing to merge into, but it goes through the
    // merge anyway: the destructive shape is a name published as the WHOLE
    // profile, and one path means that shape cannot come back.
    const existing = "{\"about\":\"kept\",\"lud16\":\"me@example.com\"}";
    const merged = main.mergeNameJsonForTest(testing.allocator, existing, "Bob").?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\":\"Bob\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"about\":\"kept\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"me@example.com\"") != null);
}

test "a profile that will not parse does not become a blank profile" {
    // This asserted the opposite of its own title: that garbage merged into an
    // empty object with the sheet's fields written over it, on the reasoning
    // that the caller would decide whether to publish. The caller does not. It
    // publishes whatever the merge hands back, so an unreadable record came out
    // the other side as a kind:0 holding nothing but a display name, and the
    // reader's lightning address, NIP-05, banner and website were gone from
    // every relay and every other client.
    var model = main.initialModel();
    model.profile_name_buffer.set("Alice");
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, "not json at all", &model) == null);

    // Not only outright garbage. Zig's JSON parser rejects an unpaired
    // surrogate half, which parsers elsewhere in the ecosystem accept, so a
    // profile carrying one is a real profile that this app cannot read. It is
    // exactly the reader most likely to have a full profile to lose.
    const lone_surrogate = "{\"name\":\"a\\ud83db\",\"lud16\":\"alice@example.com\"}";
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, lone_surrogate, &model) == null);

    // A root that is valid JSON but not an object is the same story.
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, "[1,2,3]", &model) == null);

    // Only a caller that says there is nothing there starts from nothing. That
    // is the literal `{}` handed over when no record was found.
    const fresh = main.mergeProfileJsonForTest(testing.allocator, "{}", &model) orelse
        return error.RefusedToWriteAFirstProfile;
    defer testing.allocator.free(fresh);
    try testing.expect(std.mem.indexOf(u8, fresh, "\"display_name\":\"Alice\"") != null);

    // And the ordinary path still merges: a field the sheet does not show must
    // come through the edit untouched, which is what the merge is for.
    const held = "{\"name\":\"alice\",\"pronouns\":\"she/her\",\"lud06\":\"LNURL1DP68\"}";
    const merged = main.mergeProfileJsonForTest(testing.allocator, held, &model) orelse
        return error.LostAReadableProfile;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\":\"Alice\"") != null);
    // Keys the sheet still does not show. `lud16` and `nip05` used to stand here
    // and both are editable now, so they no longer prove anything about fields
    // the merge carries blind.
    try testing.expect(std.mem.indexOf(u8, merged, "\"pronouns\":\"she/her\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud06\":\"LNURL1DP68\"") != null);
}
test "an unanswered relay round is never read as 'you have no profile'" {
    // This is the wipe. "The store has no kind:0 for me" means either that the
    // account has no profile or that nobody answered, and only one of those is
    // safe to publish over. The answer therefore records WHO it is about and is
    // only set when a relay actually replied.
    // The identity hooks take a SECRET key; the answer is recorded against the
    // PUBLIC one, which is what a relay was asked about.
    main.forgetOwnProfileAnswerForTest();
    main.setIdentityForTest([_]u8{1} ** 32);
    defer main.clearIdentityForTest();
    const a = main.activePubkeyForTest().?;
    try testing.expect(!main.ownProfileAnsweredForTest());

    // A round where every relay was offline, write-only or refused the dial
    // proves nothing, even though the round finished.
    main.recordOwnProfileAnswerForTest(a, false);
    try testing.expect(!main.ownProfileAnsweredForTest());

    // A relay that replied does prove it.
    main.recordOwnProfileAnswerForTest(a, true);
    try testing.expect(main.ownProfileAnsweredForTest());

    // And it proves it about account A only. Signing in as B must not inherit
    // A's conclusion, or B's Save publishes an empty object over B's profile.
    main.setIdentityForTest([_]u8{2} ** 32);
    try testing.expect(!main.ownProfileAnsweredForTest());
}
test "typing while the profile is still arriving does not delete the rest of it" {
    // The sheet opens on a cold store, the reader types a display name, and the
    // real profile lands a second later. The seeding was all or nothing: one
    // typed character skipped all three fields, and the stage flipped to `have`
    // regardless, so Save lit up over an about and a picture that had never been
    // read. The merge REMOVES a key whose field is empty, so pressing Save
    // deleted the reader's bio and avatar from a profile the app had by then
    // read correctly.
    var model = main.initialModel();
    const existing =
        "{\"display_name\":\"old name\",\"about\":\"the bio they wrote years ago\"," ++
        "\"picture\":\"https://example.com/face.png\",\"lud16\":\"a@b.com\"}";

    // Mid-fetch, the reader has typed a new name and nothing else.
    model.profile_name_buffer.set("new name");

    // The profile arrives. Their sentence survives; the fields they never
    // touched are filled from what actually arrived.
    main.seedProfileFieldsForTest(&model, existing, true);
    try testing.expectEqualStrings("new name", model.profile_name());
    try testing.expectEqualStrings("the bio they wrote years ago", model.profile_about());
    try testing.expectEqualStrings("https://example.com/face.png", model.profile_picture());

    // And the save that follows keeps every one of them.
    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "new name") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "the bio they wrote years ago") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "face.png") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"a@b.com\"") != null);
}

test "a field too long to show is left alone rather than written back truncated" {
    // The buffers hold 64, 280 and 200 bytes. A longer bio shown cut off, then
    // saved untouched, writes the cut-off version back over the real one: data
    // loss from merely opening a sheet.
    var model = main.initialModel();
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    const existing = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"name\":\"alice\",\"about\":\"{s}\",\"lud16\":\"a@b.com\"}}",
        .{long},
    );
    defer testing.allocator.free(existing);

    main.seedProfileFieldsForTest(&model, existing, false);
    // Not shown at all, rather than shown cut in half.
    try testing.expectEqualStrings("", model.profile_about());
    try testing.expect(model.profile_about_long);

    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    // The real bio is still there, at its full length.
    try testing.expect(std.mem.indexOf(u8, merged, long[0..400]) != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"a@b.com\"") != null);
}

test "the name edit rewrites the key it was read from" {
    // The field is seeded from display_name, displayName or name, whichever the
    // profile has. Always writing display_name would leave the value the reader
    // edited exactly where it was, so the rename would silently do nothing.
    var model = main.initialModel();

    // A profile using the legacy camelCase key.
    const legacy = "{\"displayName\":\"Old\",\"lud16\":\"a@b.com\"}";
    main.seedProfileFieldsForTest(&model, legacy, false);
    try testing.expectEqualStrings("Old", model.profile_name());
    model.profile_name_buffer.set("New");
    const m1 = main.mergeProfileJsonForTest(testing.allocator, legacy, &model).?;
    defer testing.allocator.free(m1);
    try testing.expect(std.mem.indexOf(u8, m1, "\"displayName\":\"New\"") != null);
    try testing.expect(std.mem.indexOf(u8, m1, "\"Old\"") == null);

    // A profile with only a handle: the handle is what the reader saw, so the
    // handle is what they edited.
    var m2model = main.initialModel();
    const handle_only = "{\"name\":\"alice\",\"lud16\":\"a@b.com\"}";
    main.seedProfileFieldsForTest(&m2model, handle_only, false);
    try testing.expectEqualStrings("alice", m2model.profile_name());
    m2model.profile_name_buffer.set("alice2");
    const m2 = main.mergeProfileJsonForTest(testing.allocator, handle_only, &m2model).?;
    defer testing.allocator.free(m2);
    try testing.expect(std.mem.indexOf(u8, m2, "\"name\":\"alice2\"") != null);
    try testing.expect(std.mem.indexOf(u8, m2, "\"lud16\":\"a@b.com\"") != null);
}
test "pressing Follow when every relay finished empty asks first, and writes only on a yes" {
    // The account the hunt found: no kind:3 anywhere. Follow used to stay grey for
    // the whole session. Now it is live, and the press puts the one question only
    // the reader can answer. A no leaves the relays exactly as they were.
    defer main.resetOutboxForTest();
    var fs: FreshStore = undefined;
    try fs.open("askfollow");
    defer fs.close();
    _ = signInNothingFound(0x6a);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const bob = [_]u8{0xb3} ** 32;

    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask != null);
    try testing.expectEqual(main.FreshAsk.Action.follow, model.fresh_ask.?.action);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 3) == null);
    // The question is on screen, with both answers pressable.
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const tree = try buildTree(arena_state.allocator(), &model);
        try testing.expect(findAnyTextContaining(tree.root, "Start a new follow list?"));
        try testing.expect(findAnyTextContaining(tree.root, "would replace it with a list holding only this one person"));
        try testing.expect(pressableByLabel(tree, tree.root, "Start a new list") or findByText(tree.root, .button, "Start a new list") != null);
        try testing.expect(findByText(tree.root, .button, "Cancel") != null);
    }

    // No: nothing is written, nothing is remembered, and the next press asks again.
    main.update(&model, .fresh_list_cancel, &fx);
    try testing.expect(model.fresh_ask == null);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 3) == null);
    try testing.expect(!main.canWriteFollows());
    main.update(&model, Msg{ .follow_author = .{ .who = bob, .direction = 1 } }, &fx);
    try testing.expect(model.fresh_ask != null);

    // Yes: the follow goes out as a list of one, and the answer covers follows
    // only. Mutes and bookmarks are separate lists and still ask.
    main.update(&model, .fresh_list_confirm, &fx);
    try testing.expect(model.fresh_ask == null);
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 3) orelse return error.NothingWritten;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "b3" ** 32) != null);
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.needsFreshConsentForTest(.mutes));
    try testing.expect(main.needsFreshConsentForTest(.bookmarks));
}

test "a first profile is published only after a second, informed press" {
    // Save was dead for good on an account with no kind:0 on the relays. It is
    // live once every relay has finished, the first press shows what a wrong
    // guess costs and writes nothing, and the second is the reader's answer.
    defer main.resetOutboxForTest();
    var fs: FreshStore = undefined;
    try fs.open("firstprofile");
    defer fs.close();
    _ = signInNothingFound(0x6f);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .absent;
    model.profile_name_buffer.set("Fresh");
    var fx: main.EffectsForTest = undefined;

    try testing.expect(model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "No relay has a profile for you") != null);
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);
    try testing.expect(model.profile_stage == .absent);
    try testing.expect(main.ownRecordContentForTest(testing.allocator, 0) == null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "would be replaced") != null);

    // Closing and reopening forgets the first press: the question is asked again.
    model.profile_confirm_new = false;
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);
    main.update(&model, .profile_save, &fx);
    const content = main.ownRecordContentForTest(testing.allocator, 0) orelse return error.NothingWritten;
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Fresh") != null);

    // Not every relay finished: Save stays off, and says so.
    main.forgetOwnRecordAnswersForTest();
    main.ownListsWaitedForTest(60);
    var other = main.initialModel();
    other.profile_stage = .absent;
    try testing.expect(!other.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, other.profile_status(), "not every relay that may keep one answered") != null);
}

test "the unsaved picture notice stays until Save really sends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("unsavedpic");
    defer fs.close();
    _ = signInNothingFound(0x7a);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    defer main.setProfileUploadUnsavedForTest(false);

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .absent;
    model.profile_picture_buffer.set("https://media.example/new.png");
    var fx: main.EffectsForTest = undefined;
    main.setProfileUploadUnsavedForTest(true);
    const notice = "not published until you press Save";

    // Still reading: Save does nothing, and the notice stays.
    model.profile_stage = .fetching;
    main.update(&model, .profile_save, &fx);
    try testing.expect(findAnyTextContaining((try buildTree(arena, &model)).root, notice));

    // The first press on a first profile only asks. Nothing went out.
    model.profile_stage = .absent;
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);
    try testing.expect(main.ownRecordContentForTest(testing.allocator, 0) == null);
    try testing.expect(findAnyTextContaining((try buildTree(arena, &model)).root, notice));

    // The answer sends it, and only then does the notice go.
    main.update(&model, .profile_save, &fx);
    const content = main.ownRecordContentForTest(testing.allocator, 0) orelse return error.NothingWritten;
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "new.png") != null);
    try testing.expect(!findAnyTextContaining((try buildTree(arena, &model)).root, notice));
}

test "a profile that lands between the two presses is shown, not merged over" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("lateprofile");
    defer fs.close();
    _ = signInNothingFound(0x79);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .absent;
    model.profile_name_buffer.set("Fresh");
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .profile_save, &fx);
    try testing.expect(model.profile_confirm_new);

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x79} ** 32);
    const real_json = "{\"name\":\"Real\",\"about\":\"keep me\",\"lud16\":\"pay@real.example\"}";
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &.{}, real_json, null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    // The press that would have published: it shows the profile instead.
    main.update(&model, .profile_save, &fx);
    try testing.expectEqual(main.ProfileStage.have, model.profile_stage);
    try testing.expect(!model.profile_confirm_new);
    const content = main.ownRecordContentForTest(testing.allocator, 0) orelse return error.ProfileGone;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(real_json, content);
    try testing.expectEqualStrings("keep me", model.profile_about_buffer.text());
    try testing.expectEqualStrings("pay@real.example", model.profile_lud16_buffer.text());
}

test "the length a seal must come back at is the length NIP-44 produces" {
    // The check before a sealed half is published compares its length with the
    // one this plaintext seals to. Wrong by a byte, it would refuse every good
    // seal of that size, so it is held against the real encryption across the
    // padding's chunk boundaries.
    const gpa = std.heap.page_allocator;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x91} ** 32);
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const plain = try gpa.alloc(u8, 65535);
    defer gpa.free(plain);
    @memset(plain, 'x');
    for ([_]usize{ 1, 31, 32, 33, 255, 256, 257, 300, 1000, 1025, 2560, 2561, 4096, 30000, 65535 }) |n| {
        const sealed = try nostr.nip44.encrypt(gpa, threaded.io(), signer, kp.secret_key, kp.public_key, plain[0..n]);
        defer gpa.free(sealed);
        try testing.expectEqual(sealed.len, main.nip44CiphertextLenForTest(n));
        try testing.expect(main.plausibleSealForTest(sealed, n));
        try testing.expect(!main.plausibleSealForTest(sealed[0 .. sealed.len - 4], n));
    }
}

/// Signs in a reader whose bookmark list holds `count` private bookmarks and
/// nothing public, with its private half open, and returns their key.
fn privateBookmarksFixture(arena: std.mem.Allocator, signer: *nostr.keys.Signer, store: *nostr.store.Store, count: usize) !nostr.keys.KeyPair {
    var plain = std.ArrayList(u8).empty;
    try plain.append(arena, '[');
    for (0..count) |i| {
        if (i > 0) try plain.append(arena, ',');
        var id = [_]u8{0xd0} ** 32;
        id[31] = @intCast(i);
        try plain.print(arena, "[\"e\",\"{x}\"]", .{&id});
    }
    try plain.append(arena, ']');
    const kp = try signer.keyPairFromSecretKey([_]u8{0x84} ** 32);
    var threaded = std.Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const sealed = try nostr.nip44.encrypt(arena, threaded.io(), signer.*, kp.secret_key, kp.public_key, plain.items);
    return bookmarkFixture(arena, signer, store, &.{}, sealed);
}

test "a bunker's seal of a long private bookmark list is published whole" {
    // Thirty-five private bookmarks seal to under 4096 bytes and thirty-six to
    // over it. The bunker's answer was copied into a 4096-byte buffer with the
    // length clamped to fit, and the cut copy was published as the list's
    // content: a private half no client can decrypt, so every private bookmark
    // was gone, on every relay, the moment the 36th was added.
    main.forgetBookmarksForTest();
    main.forgetPrivateSealForTest();
    defer {
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.clearPendingForTest();
        main.setSignerKindLocalForTest();
        main.forgetLastPublishedForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmlong.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    const kp = try privateBookmarksFixture(arena, &signer, &store, 35);
    const thirty_sixth = [_]u8{0xd1} ** 32;

    // The press goes to the bunker.
    var fx_dummy: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    main.setRemotePubkeyForTest(kp.public_key);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx_dummy, thirty_sixth, true));

    // The bunker seals exactly what was asked, and it is longer than 4096.
    var threaded = std.Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const sealed = try nostr.nip44.encrypt(arena, threaded.io(), signer, kp.secret_key, kp.public_key, main.lastSealPlaintextForTest());
    try testing.expect(sealed.len > 4096);
    main.parkSealAnswerForTest(sealed);

    // The splice is signed by the keyholder a test has, so it can be read back.
    main.setSignerKindLocalForTest();
    main.forgetLastPublishedForTest();
    var model = main.initialModel();
    main.scanPendingRemoteForTest(&model, &fx_dummy);
    const published = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expectEqual(@as(u16, 10003), published.kind);
    try testing.expectEqualStrings(sealed, published.content);
    const opened = try nostr.nip44.decrypt(arena, signer, kp.secret_key, kp.public_key, published.content);
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&thirty_sixth});
    try testing.expect(std.mem.indexOf(u8, opened, &hex) != null);
}

test "a private half past 4096 bytes is read, and the list can still be written" {
    // The private-half cache held 4096 bytes of ciphertext and of plaintext.
    // Thirty-six private bookmarks seal to 4188, so that list read as
    // unreadable: its private bookmarks did not show, and every bookmark
    // press after that was refused.
    main.forgetBookmarksForTest();
    defer {
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.forgetLastPublishedForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmbig.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try privateBookmarksFixture(arena, &signer, &store, 36);

    var last = [_]u8{0xd0} ** 32;
    last[31] = 35;
    try testing.expect(main.isBookmarked(last));

    var fx: main.EffectsForTest = undefined;
    try testing.expectEqual(main.BookmarkWrite.published, main.writeBookmarkForTest(&fx, [_]u8{0xd3} ** 32, true));
    try testing.expect(main.isBookmarked(last));
}

test "a second list write inside one bunker round trip waits for the first" {
    // A bunker has several signatures out at once, and the store does not hold
    // a list write until its signature comes back. Two mute presses inside that
    // round trip both spliced onto the same stored list, and the second, newer,
    // published a list without the first. The same for bookmarks and media
    // servers.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.forgetPrivateSealForTest();
    defer main.forgetPrivateSealForTest();
    defer main.forgetMutesForTest();
    defer main.forgetBookmarksForTest();
    main.setIdentityForTest([_]u8{0x86} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    var fx: main.EffectsForTest = undefined;

    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, [_]u8{0xe1} ** 32, true));
    try testing.expectEqual(main.MuteWrite.signer_busy, main.writeMuteForTest(&fx, [_]u8{0xe2} ** 32, true));

    try testing.expectEqual(main.BookmarkWrite.published, main.writeBookmarkForTest(&fx, [_]u8{0xe3} ** 32, true));
    try testing.expectEqual(main.BookmarkWrite.signer_busy, main.writeBookmarkForTest(&fx, [_]u8{0xe4} ** 32, true));
    // A private bookmark is a write to the same list.
    try testing.expectEqual(main.BookmarkWrite.signer_busy, main.writePrivateBookmarkForTest(&fx, [_]u8{0xe5} ** 32, true));

    try testing.expectEqual(main.BlossomWrite.published, main.writeBlossomServersForTest(&fx, "https://one.example", null));
    try testing.expectEqual(main.BlossomWrite.signer_busy, main.writeBlossomServersForTest(&fx, "https://two.example", null));

    // Taken out of the table by the listener and not stored yet is still out.
    var idbuf: [24]u8 = undefined;
    const mute_sign = main.pendingSignIdForKindForTest(10000, &idbuf) orelse return error.NoPendingSign;
    try testing.expect(main.takeAnsweredForTest(mute_sign));
    defer main.signLandedForTest();
    try testing.expectEqual(main.MuteWrite.signer_busy, main.writeMuteForTest(&fx, [_]u8{0xe2} ** 32, true));
}

test "a public bookmark waits for a private one being sealed, and the other way round" {
    // A seal finishes only over the record it was built on. A public bookmark
    // still with the signer is in no store, so that check passed with neither
    // stored, and whichever landed second published the list without the other.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.forgetPrivateSealForTest();
    defer main.forgetPrivateSealForTest();
    defer main.forgetBookmarksForTest();
    main.setIdentityForTest([_]u8{0x87} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    var fx: main.EffectsForTest = undefined;

    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xe6} ** 32, true));
    try testing.expectEqual(main.BookmarkWrite.signer_busy, main.writeBookmarkForTest(&fx, [_]u8{0xe7} ** 32, true));
}

test "a relay that sent the reader's list and Plaza could not keep it has not said there is none" {
    // The feed's EOSE counted as "this relay has finished without your list"
    // even when one of the reader's own records had arrived on that very
    // subscription and been dropped: a store error, or a signature that did not
    // verify. A list one relay really holds then looked absent, and the
    // new-list question would replace it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("selfread");
    defer fs.close();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const me = try signer.keyPairFromSecretKey([_]u8{0x88} ** 32);
    const stranger = try signer.keyPairFromSecretKey([_]u8{0x89} ** 32);

    // The reader's own mute list, stored: an answer.
    {
        var read: main.SelfReadForTest = .{};
        const ok = try nostr.event.create(arena, signer, me, 1_800_000_000, 10000, &.{}, "", null);
        try testing.expect(main.ingestFeedEventForTest(arena, signer, ok, me.public_key, &read));
        try testing.expect(read.eoseAnswers());
    }
    // The reader's own mute list, arriving and not verifying: not an answer.
    {
        var read: main.SelfReadForTest = .{};
        var bad = try nostr.event.create(arena, signer, me, 1_800_000_001, 10000, &.{}, "", null);
        bad.sig[0] ^= 0xff;
        try testing.expect(!main.ingestFeedEventForTest(arena, signer, bad, me.public_key, &read));
        try testing.expect(!read.eoseAnswers());
    }
    // A stranger's bad list, or the reader's bad note, says nothing about the
    // reader's lists.
    {
        var read: main.SelfReadForTest = .{};
        var theirs = try nostr.event.create(arena, signer, stranger, 1_800_000_002, 10000, &.{}, "", null);
        theirs.sig[0] ^= 0xff;
        _ = main.ingestFeedEventForTest(arena, signer, theirs, me.public_key, &read);
        var note = try nostr.event.create(arena, signer, me, 1_800_000_003, 1, &.{}, "hello", null);
        note.sig[0] ^= 0xff;
        _ = main.ingestFeedEventForTest(arena, signer, note, me.public_key, &read);
        try testing.expect(read.eoseAnswers());
    }
    // And a message that could not be read at all may have been the list.
    {
        var read: main.SelfReadForTest = .{};
        read.sawUnreadable();
        try testing.expect(!read.eoseAnswers());
    }
    // Which the connection reports by counting it: only a count that moved
    // since the question was asked says one arrived.
    {
        var read: main.SelfReadForTest = .{};
        read.sawUnreadableSince(3, 3);
        try testing.expect(read.eoseAnswers());
        read.sawUnreadableSince(3, 4);
        try testing.expect(!read.eoseAnswers());
    }
}

test "a private bookmark list with control characters in it seals back whole" {
    // NIP-51 entries can carry anything a JSON string can: a label with a
    // newline or a tab, a control byte, any script. The new private half was
    // escaped by hand for `"` and `\` only, so those went in raw, the sealed
    // JSON did not parse, and the whole private half became unreadable for
    // every client.
    main.forgetBookmarksForTest();
    main.forgetPrivateSealForTest();
    defer {
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmctl.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const old_id = "d4" ** 32;
    const entries = [_][]const []const u8{
        &.{ "e", old_id, "wss://relay.example", "line one\nline two" },
        &.{ "t", "tab\there" },
        &.{ "title", "bell\x01and quote \" and slash \\" },
        &.{ "title", "日本語 und Grüße 🌿" },
    };
    const plain = try std.json.Stringify.valueAlloc(arena, entries, .{});
    const kp = try signer.keyPairFromSecretKey([_]u8{0x84} ** 32);
    var threaded = std.Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const sealed = try nostr.nip44.encrypt(arena, threaded.io(), signer, kp.secret_key, kp.public_key, plain);
    _ = try bookmarkFixture(arena, &signer, &store, &.{}, sealed);

    var fx: main.EffectsForTest = undefined;
    const new_id = [_]u8{0xd5} ** 32;
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, new_id, true));
    const opened = try nostr.nip44.decrypt(arena, signer, kp.secret_key, kp.public_key, main.lastSealedForTest());
    const back = try std.json.parseFromSliceLeaky([]const []const []const u8, arena, opened, .{});
    try testing.expectEqual(entries.len + 1, back.len);
    for (entries, 0..) |want, i| {
        try testing.expectEqual(want.len, back[i].len);
        for (want, 0..) |field, j| try testing.expectEqualStrings(field, back[i][j]);
    }
    var new_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&new_hex, "{x}", .{&new_id});
    try testing.expectEqualStrings("e", back[entries.len][0]);
    try testing.expectEqualStrings(&new_hex, back[entries.len][1]);
}

test "a list published but not stored holds the next write until it is read back" {
    // Notary's writes are published even when the store refuses them, so the
    // store can be a write behind the relays. The next mute spliced onto the
    // stored list and published it without the mute that was already out.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("unstored");
    defer fs.close();
    main.setIdentityForTest([_]u8{0x8d} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    defer main.forgetMutesForTest();
    defer main.failIngestForTest(false);
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    const first = [_]u8{0xf1} ** 32;
    const second = [_]u8{0xf2} ** 32;

    // The first mute is signed and published, and the store refuses it.
    main.failIngestForTest(true);
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, first, true));
    main.failIngestForTest(false);
    const out = main.lastPublishedForTest() orelse return error.NothingPublished;
    try testing.expect(main.ownWriteUnstoredForTest(10000));

    // The second is held back, and says why.
    main.forgetLastPublishedForTest();
    const held = main.writeMuteForTest(&fx, second, true);
    try testing.expectEqual(main.MuteWrite.not_read_back, held);
    try testing.expect(main.lastPublishedForTest() == null);
    main.sayMuteWriteForTest(&model, held, true);
    try testing.expectEqualStrings("Last change not read back yet. Try again soon.", model.toast_text());

    // The first comes back from a relay. Now the second splices onto it.
    _ = try main.plazaIngestVerifiedForTest(arena, out, signer);
    try testing.expect(!main.ownWriteUnstoredForTest(10000));
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, second, true));
    const tags = main.ownRecordTagsJoinedForTest(testing.allocator, 10000) orelse return error.NothingStored;
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "f1" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, tags, "f2" ** 32) != null);
}

test "a list published but not stored is stored by the tick, or let go and said" {
    // Nothing tried the store again, so a refusal that no relay ever answered
    // kept every write of that kind refused for the session.
    var fs: FreshStore = undefined;
    try fs.open("unstored-retry");
    defer fs.close();
    main.setIdentityForTest([_]u8{0x8e} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    defer main.forgetMutesForTest();
    defer main.failIngestForTest(false);
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    const first = [_]u8{0xf3} ** 32;
    const second = [_]u8{0xf4} ** 32;
    const third = [_]u8{0xf5} ** 32;
    var now: i64 = 1_800_000_000;

    // Refused once, and stored by the next try.
    main.failIngestForTest(true);
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, first, true));
    main.failIngestForTest(false);
    try testing.expect(main.ownWriteUnstoredForTest(10000));
    main.retryUnstoredOwnWrites(&model, now);
    try testing.expect(!main.ownWriteUnstoredForTest(10000));
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, second, true));
    const tags = main.ownRecordTagsJoinedForTest(testing.allocator, 10000) orelse return error.NothingStored;
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "f3" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, tags, "f4" ** 32) != null);

    // Refused every time: held while it is tried, then let go, and said.
    main.failIngestForTest(true);
    try testing.expectEqual(main.MuteWrite.published, main.writeMuteForTest(&fx, third, true));
    var tries: usize = 0;
    while (main.ownWriteUnstoredForTest(10000)) : (tries += 1) {
        if (tries > 100) return error.HeldForever;
        try testing.expect(model.toast_len == 0 or !std.mem.eql(u8, model.toast_text(), main.unstored_lost_toast));
        now += 1;
        main.retryUnstoredOwnWrites(&model, now);
    }
    try testing.expect(tries > 1);
    try testing.expectEqualStrings(main.unstored_lost_toast, model.toast_text());
}

test "a seal that comes back the wrong length is not published" {
    // Whatever cut or mangled it, a ciphertext that is not the length this
    // plaintext seals to would replace every private bookmark with bytes
    // nobody can open.
    main.forgetBookmarksForTest();
    main.forgetPrivateSealForTest();
    defer {
        main.forgetPrivateSealForTest();
        main.forgetBookmarksForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
        main.forgetPrivateHalvesForTest();
        main.clearPendingForTest();
        main.setSignerKindLocalForTest();
        main.forgetLastPublishedForTest();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bmcut.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    const kp = try privateBookmarksFixture(arena, &signer, &store, 3);

    var fx_dummy: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    main.setRemotePubkeyForTest(kp.public_key);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx_dummy, [_]u8{0xd2} ** 32, true));
    var threaded = std.Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const sealed = try nostr.nip44.encrypt(arena, threaded.io(), signer, kp.secret_key, kp.public_key, main.lastSealPlaintextForTest());
    main.parkSealAnswerForTest(sealed[0 .. sealed.len - 8]);

    main.setSignerKindLocalForTest();
    main.forgetLastPublishedForTest();
    var model = main.initialModel();
    main.scanPendingRemoteForTest(&model, &fx_dummy);
    try testing.expect(main.lastPublishedForTest() == null);
    try testing.expectEqualStrings("That seal came back damaged. Nothing was sent.", model.toast_text());
}

test "a private bookmark is not published over a list that landed while it was sealed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fs: FreshStore = undefined;
    try fs.open("lateseal");
    defer fs.close();
    _ = signInNothingFound(0x7a);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();
    defer main.forgetBookmarksForTest();
    defer main.forgetPrivateHalvesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = [_]u8{0x5a} ** 32;
    model.thread_notes[0] = threadNote(0x02, 100, 0);
    model.thread_notes[0].id = 78;
    model.thread_notes[0].pubkey = [_]u8{0x5a} ** 32;
    model.thread_notes_len = 1;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .bookmark_privately = 78 }, &fx);
    try testing.expect(model.fresh_ask != null);
    // Yes: the seal goes out (inline in a test binary), and the list is not
    // written until the ciphertext is back.
    main.update(&model, .fresh_list_confirm, &fx);
    try testing.expect(main.ownRecordTagsJoinedForTest(testing.allocator, 10003) == null);

    // The real list lands in between, private half and all.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x7a} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "e", "13" ** 32 }};
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10003, &tags, "a-private-half-this-seal-never-saw", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    main.finishPrivateBookmarkForTest(&model, &fx);
    const content = main.ownRecordContentForTest(testing.allocator, 10003) orelse return error.ListGone;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("a-private-half-this-seal-never-saw", content);
}

test "a private bookmark being sealed ends with the session it was pressed in" {
    // The seal in flight was cleared only by its own answer. Cut off by a
    // sign-out, a dropped bunker or a bunker ask that died with its session, it
    // stayed set, and every private bookmark after it read as "your signer is
    // busy" for the rest of the run.
    main.forgetPrivateSealForTest();
    defer main.forgetPrivateSealForTest();
    main.forgetBookmarksForTest();
    defer main.forgetBookmarksForTest();
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    defer main.setIdentityMintedForTest(false);
    defer main.clearIdentityForTest();
    defer main.clearLoggedOutLatchForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const note = [_]u8{0xc5} ** 32;

    // A sign-out.
    main.setIdentityForTest([_]u8{0x7c} ** 32);
    main.setIdentityMintedForTest(true);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, note, true));
    try testing.expect(main.privateSealActiveForTest());
    main.performLogoutForTest(&model, &fx);
    try testing.expect(!main.privateSealActiveForTest());

    // A bunker ask whose session was replaced before it was answered.
    main.setIdentityForTest([_]u8{0x7d} ** 32);
    main.setIdentityMintedForTest(true);
    main.setSignerKindForTest("remote");
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, note, true));
    try testing.expect(main.privateSealActiveForTest());
    main.bumpRemoteGenerationForTest();
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expect(!main.privateSealActiveForTest());

    // A bunker connection taken down.
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, note, true));
    try testing.expect(main.privateSealActiveForTest());
    main.resetBunkerConnectForTest();
    try testing.expect(!main.privateSealActiveForTest());
}

test "a private bookmark sealed for one account is never published as another" {
    // The ciphertext is a list encrypted to the account that pressed. Finished
    // under somebody else it would be published as THEIR bookmark list, which
    // they cannot read and which replaces whatever they had.
    main.forgetPrivateSealForTest();
    defer main.forgetPrivateSealForTest();
    main.forgetBookmarksForTest();
    defer main.forgetBookmarksForTest();
    defer main.setIdentityMintedForTest(false);
    defer main.clearIdentityForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.setIdentityForTest([_]u8{0x7e} ** 32);
    main.setIdentityMintedForTest(true);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xc6} ** 32, true));
    try testing.expect(main.lastSealedForTest().len > 0);

    // Another account is in the seat when the ciphertext lands.
    main.setIdentityForTest([_]u8{0x7f} ** 32);
    main.finishPrivateBookmarkForTest(&model, &fx);
    try testing.expect(main.lastPublishedForTest() == null);
}

test "Notary's late answer to an abandoned seal does not finish the next one" {
    // Every seal used to go out under one effect key, so an answer still on its
    // way when the reader signed out arrived looking exactly like the answer to
    // the next seal they asked for, and was published as it.
    main.forgetPrivateSealForTest();
    defer main.forgetPrivateSealForTest();
    main.forgetBookmarksForTest();
    defer main.forgetBookmarksForTest();
    defer main.setIdentityMintedForTest(false);
    defer main.clearIdentityForTest();
    defer main.clearLoggedOutLatchForTest();
    main.forgetLastPublishedForTest();
    defer main.forgetLastPublishedForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    const secret = [_]u8{0x7b} ** 32;

    main.setIdentityForTest(secret);
    main.setIdentityMintedForTest(true);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xc7} ** 32, true));
    const abandoned = main.privateSealKeyForTest();
    var old_sealed: [8192]u8 = undefined;
    const old_len = main.lastSealedForTest().len;
    @memcpy(old_sealed[0..old_len], main.lastSealedForTest());
    main.performLogoutForTest(&model, &fx);

    // The same reader, back, bookmarking something else privately.
    main.clearLoggedOutLatchForTest();
    main.setIdentityForTest(secret);
    main.setIdentityMintedForTest(true);
    try testing.expectEqual(main.BookmarkWrite.published, main.writePrivateBookmarkForTest(&fx, [_]u8{0xc8} ** 32, true));
    main.forgetLastPublishedForTest();

    main.deliverPrivateSealForTest(&model, &fx, abandoned, old_sealed[0..old_len]);
    try testing.expect(main.lastPublishedForTest() == null);
    try testing.expect(main.privateSealActiveForTest());
}

test "signing out wipes the bunker's pairing secret and client key" {
    // Dropping a bunker connection wiped both. Signing out only set a length to
    // zero and the key to null, which leaves every byte where it was.
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    defer main.clearLoggedOutLatchForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    model.login_buffer.set("bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=pairing-secret-three");
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.remoteSecretHeldForTest("pairing-secret-three"));
    const client_secret = main.remoteClientSecretForTest() orelse return error.NoClientKey;

    main.performLogoutForTest(&model, &fx);
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-three"));
    try testing.expect(!main.remoteClientSecretLingersForTest(client_secret));
}
test "a CLOSED is a finished question and never an answer" {
    // The kind:0 check read `.eose, .closed` as one outcome. An auth-required
    // CLOSED is a relay declining to look, and counting it as "this account has
    // no profile here" is how an empty profile replaces a real one.
    const eose: nostr.message.RelayMessage = .{ .eose = .{ .subscription_id = "plaza-me" } };
    try testing.expectEqualStrings("answered", main.askVerdictForTest(eose));
    try testing.expectEqualStrings("refused", main.askVerdictForTest(closedMsg("plaza-me", "auth-required: x")));
    try testing.expectEqualStrings("refused", main.askVerdictForTest(closedMsg("plaza-me", "error: shutting down")));
    try testing.expectEqualStrings("refused", main.askVerdictForTest(closedMsg("plaza-me", "")));
    const notice: nostr.message.RelayMessage = .{ .notice = .{ .message = "hello" } };
    try testing.expectEqualStrings("pending", main.askVerdictForTest(notice));
}
test "the relay list note sits under its field instead of spilling out of it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetRelaysForTest();
    main.forgetOwnRecordAnswersForTest();
    main.setIdentityForTest([_]u8{81} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetOwnRecordAnswersForTest();

    var model = main.initialModel();
    model.stage = .settings;
    // A list this account has not been read back from: the note is showing.
    const note = main.relayWriteBlockedReason() orelse return error.NoNote;

    // The narrowest window the app allows, where the note wraps the most.
    const p = try painted.Painted.renderAt(arena, &model, 880, 1600);
    const field = p.frameOf("Add a relay") orelse return error.NoField;
    const note_frame = frameOfText(p, note) orelse return error.NoNoteFrame;
    const next = frameOfText(p, "APPEARANCE") orelse return error.NoNextSection;
    // Below the field, not drawn over it, and clear of the next heading.
    try testing.expect(note_frame.y >= field.y + field.height - 0.5);
    try testing.expect(note_frame.y + note_frame.height <= next.y);
}

test "Edit profile keeps Close and Save inside the sheet at the window's smallest size" {
    // The sheet was a column of seven fields with nothing to give, 675pt tall
    // against the 632 a modal gets at the 680pt floor: the buttons were drawn
    // under the sheet's edge and off the bottom of the window.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    const floor_h: f32 = 680; // app.zon min_height
    const p = try painted.Painted.renderAt(arena, &model, main.window_min_width, floor_h);
    var sheet_index: ?usize = null;
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind == .dialog and std.mem.eql(u8, node.widget.semantics.label, "Edit profile")) sheet_index = i;
    }
    const si = sheet_index orelse return error.NoSheet;
    const sheet = p.layout.nodes[si].widget.frame;
    try testing.expect(sheet.y + sheet.height <= floor_h);
    var buttons: usize = 0;
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .button) continue;
        const t = node.widget.text;
        if (!std.mem.eql(u8, t, "Close") and !std.mem.eql(u8, t, "Save")) continue;
        if (!layoutDescends(p.layout, i, si)) continue;
        buttons += 1;
        const f = node.widget.frame;
        try testing.expect(f.y + f.height <= sheet.y + sheet.height + 0.5);
    }
    try testing.expectEqual(@as(usize, 2), buttons);
}

/// Whether layout node `i` sits somewhere under node `ancestor`.
fn layoutDescends(layout: canvas.WidgetLayoutTree, i: usize, ancestor: usize) bool {
    var at: ?usize = layout.nodes[i].parent_index;
    while (at) |a| {
        if (a == ancestor) return true;
        at = layout.nodes[a].parent_index;
    }
    return false;
}

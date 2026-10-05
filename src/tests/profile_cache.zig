//! Tests of profile_cache.zig. Profiles: which are wanted, the cache and its index, and NIP-05 verification.

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
const findAnyTextContaining = harness.findAnyTextContaining;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const frameOfTextContaining = harness.frameOfTextContaining;
const inboxEvent = harness.inboxEvent;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

test "a kind:0 profile gives an author a display name" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{7} ** 32);

    // Before a profile is known, the author renders as an abbreviated npub.
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
    const before = main.noteFrom(ev, 1_800_000_000);
    try testing.expect(std.mem.startsWith(u8, before.author(), "npub1"));

    // Seed the cache from kind:0 metadata; the author now renders as the name,
    // and no avatar is loaded yet (initials fallback).
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Satoshi\",\"name\":\"nakamoto\",\"picture\":\"https://ex.com/a.png\"}");
    const after = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqualStrings("Satoshi", after.author());
    try testing.expectEqual(@as(u64, 0), after.avatar_id());
}

test "malformed or empty kind:0 leaves the npub fallback" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    const pk = [_]u8{8} ** 32;
    const p = main.upsertProfile(pk).?;
    // Not JSON, and JSON with no usable fields: neither sets a name.
    main.parseMetadataInto(p, "this is not json");
    main.parseMetadataInto(p, "{\"about\":\"just a bio\"}");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey(pk);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "x");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
}

test "nostr: mentions render as @name or a short npub" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{5} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);

    var buf: [220]u8 = undefined;

    // Unknown pubkey: the mention becomes a short @npub, and "nostr:" is gone.
    const src_unknown = try std.fmt.allocPrint(arena, "hey nostr:{s} welcome", .{npub});
    const n1 = main.renderContent(&buf, src_unknown, "");
    const out1 = buf[0..n1];
    try testing.expect(std.mem.indexOf(u8, out1, "nostr:") == null);
    try testing.expect(std.mem.indexOf(u8, out1, "@npub1") != null);
    try testing.expect(std.mem.startsWith(u8, out1, "hey @npub1"));

    // Known pubkey: the mention becomes @<name>.
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"jack\"}");
    const n2 = main.renderContent(&buf, src_unknown, "");
    const out2 = buf[0..n2];
    try testing.expect(std.mem.indexOf(u8, out2, "@jack") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "nostr:") == null);
}

test "an image link is lifted out of the note text" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{11} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "look at this https://i.example.com/cat.jpg");
    const note = main.noteFrom(ev, 1_800_000_000);

    // The URL becomes the note's picture and leaves the text (trimmed).
    try testing.expect(note.hasImage());
    try testing.expectEqualStrings("https://i.example.com/cat.jpg", note.imageUrl());
    try testing.expectEqualStrings("look at this", note.content());
    // Nothing is registered yet, so the card draws no image.
    try testing.expectEqual(@as(u64, 0), note.media_id());
}

test "an empty display_name falls through to the name" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{12} ** 32);

    // Real profiles ship `"display_name": ""` alongside a real name (jb55's
    // does); the empty one must not win and drop the author to an npub.
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"\",\"name\":\"jb55\"}");

    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqualStrings("jb55", note.author());
}

test "the @handle is the NIP-05, and nothing without one" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{21} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");

    // No profile, or a profile with no nip05: no handle at all (never a bare npub).
    const bare = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqualStrings("", bare.handle(arena));
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Satoshi\",\"name\":\"nakamoto\"}");
    try testing.expectEqualStrings("", main.noteFrom(ev, 1_800_000_000).handle(arena));

    // A user@domain nip05 shows as @user.
    main.parseMetadataInto(p, "{\"name\":\"nakamoto\",\"nip05\":\"satoshi@bitcoin.org\"}");
    try testing.expectEqualStrings("@satoshi", main.noteFrom(ev, 1_800_000_000).handle(arena));

    // The root "_@domain" form shows as @domain, not @_.
    main.parseMetadataInto(p, "{\"nip05\":\"_@dergigi.com\"}");
    try testing.expectEqualStrings("@dergigi.com", main.noteFrom(ev, 1_800_000_000).handle(arena));
}

test "a NIP-05 check needs a real well-known name to pubkey match" {
    const pubkey = [_]u8{0xAB} ** 32;
    // The hex of the pubkey above, which a matching well-known maps the name to.
    const hex = "ab" ** 32;

    const good = "{\"names\":{\"bob\":\"" ++ hex ++ "\"}}";
    try testing.expect(main.nip05Matches("bob@example.com", pubkey, good));
    // The root "_" name is a valid identifier form and verifies the same way.
    const root = "{\"names\":{\"_\":\"" ++ hex ++ "\"}}";
    try testing.expect(main.nip05Matches("_@example.com", pubkey, root));

    // A different pubkey for the name is NOT a match (impersonation guard).
    const other = "{\"names\":{\"bob\":\"" ++ ("cd" ** 32) ++ "\"}}";
    try testing.expect(!main.nip05Matches("bob@example.com", pubkey, other));
    // The queried name is simply absent.
    try testing.expect(!main.nip05Matches("carol@example.com", pubkey, good));
    // Malformed body, or no @ in the identifier: never a match.
    try testing.expect(!main.nip05Matches("bob@example.com", pubkey, "not json"));
    try testing.expect(!main.nip05Matches("nobody", pubkey, good));
}

test "a NIP-05 identifier must be well-formed to be fetched" {
    try testing.expect(main.validNip05Name("dergigi"));
    try testing.expect(main.validNip05Name("_"));
    try testing.expect(main.validNip05Name("a.b-c_1"));
    try testing.expect(!main.validNip05Name(""));
    try testing.expect(!main.validNip05Name("has space"));
    try testing.expect(!main.validNip05Name("naïve")); // non-ASCII

    try testing.expect(main.validNip05Domain("example.com"));
    try testing.expect(main.validNip05Domain("relay.example.com:8443"));
    try testing.expect(!main.validNip05Domain("localhost")); // no dot
    try testing.expect(!main.validNip05Domain("has space.com"));
    try testing.expect(!main.validNip05Domain(""));
}
test "bare npub mentions resolve, but not inside a URL" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{31} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"alice\"}");

    var buf: [220]u8 = undefined;

    // Written without the nostr: scheme, it still resolves.
    const bare = try std.fmt.allocPrint(arena, "hey {s} hi", .{npub});
    const n1 = main.renderContent(&buf, bare, "");
    try testing.expect(std.mem.indexOf(u8, buf[0..n1], "@alice") != null);

    // The same token inside a URL is left alone.
    const in_url = try std.fmt.allocPrint(arena, "see https://njump.me/{s} ok", .{npub});
    const n2 = main.renderContent(&buf, in_url, "");
    try testing.expect(std.mem.indexOf(u8, buf[0..n2], "@alice") == null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n2], "njump.me") != null);
}

test "avatar ids go to the authors on screen, and never exceed the registry cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    // This used to say "the first `cap` authors IN READING ORDER of the whole
    // thread", which is precisely the bug: a level marked every author it held
    // as on screen, the claim pass never evicts anything marked wanted, so the
    // first nine took every id and kept it while the level was open. Everyone
    // below them showed initials no matter how far the reader scrolled.
    //
    // The rule is the one the feed always had: the authors ON SCREEN hold the
    // ids. So this drives a real build, which is what fills the visible set.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const count = 40;
    var keys: [count][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = [_]u8{0} ** 32;
        k.*[0] = @intCast(i + 1); // distinct, non-zero
        main.setProfilePictureForTest(k.*, true);
    }
    model.thread_root.pubkey = keys[0];
    for (1..count) |i| {
        model.thread_notes[i - 1] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i - 1].id = @intCast(700 + i);
        model.thread_notes[i - 1].pubkey = keys[i];
        model.thread_notes[i - 1].event_id = [_]u8{@intCast(i)} ** 32;
    }
    model.thread_notes_len = count - 1;

    _ = try painted.Painted.render(arena, &model);
    var fx: main.EffectsForTest = undefined;
    main.assignAvatarSlotsForTest(&fx, &model);

    const cap = main.image_registry_slots;
    var seen = [_]bool{false} ** (cap + 1);
    var lent: usize = 0;
    for (keys) |k| {
        const id = main.avatarImageIdForTest(k);
        if (id == 0) continue;
        // Never past the pool, and never the same id twice.
        try testing.expect(id >= 1 and id <= cap);
        if (seen[@intCast(id)]) {
            std.debug.print("id {d} lent twice\n", .{id});
            return error.DuplicateAvatarId;
        }
        seen[@intCast(id)] = true;
        lent += 1;
    }
    try testing.expect(lent <= cap);
    // And it really did lend some: a pass that starves everybody would satisfy
    // every line above.
    if (lent == 0) {
        std.debug.print("no author on screen was lent a face\n", .{});
        return error.NothingLent;
    }
}

test "an author deep in a thread gets a face once they are on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    // THE BUG, stated as a rule. Somebody thirty replies down a thread could
    // never hold a face, however far the reader scrolled: the ids were spoken
    // for by the top of the thread and unreclaimable. Scrolling has to be able
    // to hand a face to whoever is now being read.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const count = 40;
    var keys: [count][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = [_]u8{0} ** 32;
        k.*[0] = @intCast(i + 1);
        main.setProfilePictureForTest(k.*, true);
    }
    model.thread_root.pubkey = keys[0];
    for (1..count) |i| {
        model.thread_notes[i - 1] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i - 1].id = @intCast(700 + i);
        model.thread_notes[i - 1].pubkey = keys[i];
        model.thread_notes[i - 1].event_id = [_]u8{@intCast(i)} ** 32;
    }
    model.thread_notes_len = count - 1;

    // At the top of the thread: the deep author is nowhere near the screen.
    _ = try painted.Painted.render(arena, &model);
    var fx: main.EffectsForTest = undefined;
    main.assignAvatarSlotsForTest(&fx, &model);
    const deep = keys[count - 1];
    const before = main.avatarImageIdForTest(deep);

    // Now they ARE on screen. Recorded the same way the build records it, which
    // is the seam this fix put in.
    main.recordVisibleAuthorsForTest(&.{deep});
    main.assignAvatarSlotsForTest(&fx, &model);
    const after = main.avatarImageIdForTest(deep);

    if (after == 0) {
        std.debug.print("an author on screen still holds no face (was {d})\n", .{before});
        return error.DeepAuthorStarved;
    }
    try testing.expect(after >= 1 and after <= main.image_registry_slots);
}
test "the reader's own face goes in the rail seat, not their initials" {
    // Every link already worked. The reader's own kind:0 is asked for by the feed
    // subscription and by the dedicated profile round, `refreshProfiles` puts
    // their pubkey in the author list explicitly, and `assignAvatarSlots` pushes
    // them FIRST so they win one of the nine scarce ids ahead of any feed author.
    // All of that ran, and then the widget was built without the id it had earned:
    // `meAvatar` set width, height and style and never `.image`, so it took the
    // initials branch on every frame forever.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xe4} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;

    var model = main.initialModel();
    model.stage = .ready;

    // No face known yet: initials, which is correct and is what it always did.
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 0), avatarImageIn(seat));
    }

    // A loaded face. The `.loaded` gate is the load-bearing half: the renderer
    // takes the image branch for ANY non-zero id and draws initials only in the
    // else, so a claimed-but-not-arrived id would paint an EMPTY disc.
    main.setProfileAvatarForTest(me, 3, .fetching);
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 0), avatarImageIn(seat));
    }

    main.setProfileAvatarForTest(me, 3, .loaded);
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 3), avatarImageIn(seat));
    }
}

/// The image id on the avatar widget inside `widget`, or 0 if there is none.
fn avatarImageIn(widget: canvas.Widget) u64 {
    if (widget.kind == .avatar and widget.image_id != 0) return widget.image_id;
    for (widget.children) |child| {
        const found = avatarImageIn(child);
        if (found != 0) return found;
    }
    return 0;
}

test "a profile shows the address it was verified as, not just a tick" {
    // The page drew a bare check next to the name and no address anywhere, so a
    // verified profile said "verified" without ever saying verified as WHAT. The
    // domain is the half that names who vouched, and this is the one screen a
    // reader opens specifically to decide whether somebody is who they claim.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var who: [32]u8 = undefined;
    @memset(&who, 0x7c);
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = who;

    // Verified: the address is on the page.
    main.setProfileNip05ForTest(who, "someone@example.com", true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "someone@example.com"));
    }

    // The root form is shown as the bare domain, which is what `_@domain` means.
    main.setProfileNip05ForTest(who, "_@example.com", true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "example.com"));
        try testing.expect(!findAnyTextContaining(tree.root, "_@example.com"));
    }

    // THE PROPERTY THAT MATTERS: unverified shows NOTHING. An address the app has
    // not checked, printed under a name, reads as an endorsement to everyone who
    // has seen one anywhere else, which is the impersonation this guards against.
    main.setProfileNip05ForTest(who, "impostor@example.com", false);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(!findAnyTextContaining(tree.root, "impostor@example.com"));
    }
    try testing.expectEqualStrings("", main.verifiedNip05ForTest(who));
}
test "somebody who turns up in your notifications gets a name fetched" {
    // The profile round asks for kind:0 for three sets: the people the reader
    // follows, the people a note mentions, and the reader themself. Somebody who
    // replies to you, likes you or zaps you is in none of those, and nothing else
    // ever asked. So the notifications page listed raw npubs for exactly the
    // people it is about, which is the one screen where the name IS the row.
    main.setIdentityForTest([_]u8{0xb8} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.forgetWantedProfilesForTest();
    defer main.forgetWantedProfilesForTest();

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    // A stranger replies to the reader. Nobody has ever asked who they are.
    const stranger = [_]u8{0xb9} ** 32;
    try testing.expect(!main.profileWantedForTest(stranger));

    var ev = inboxEvent(1, 0xb9, &mine, 1_800_000_000);
    ev.pubkey = stranger;
    try testing.expect(main.inboxAddForTest(ev, 1_800_000_000));

    // Filing the notification is what arms the question, on the next tick: a
    // relay reader files it, and the wanted list is the UI thread's.
    main.welcomeInboxArrivalsForTest();
    try testing.expect(main.profileWantedForTest(stranger));
}
test "a display name cannot push the pill out of the sheet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // The name in that sentence is a stranger's kind:0 field, so it has no length
    // and no alphabet. The pill does not wrap, so an unclipped one walks out of
    // the card and off the window.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    const who = [_]u8{0x2C} ** 32;
    const prof = main.upsertProfile(who).?;
    main.parseMetadataInto(prof, "{\"display_name\":\"" ++ "wide" ** 40 ++ "\"}");

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.pending = .{ .follow = who };
    const tree = try buildTree(arena, &model);
    const line = findAnyTextContainingText(tree.root, "is waiting.") orelse return error.NoPill;
    try testing.expect(line.len < 60);
}
/// How many widgets in the tree carry exactly this text.
fn countAnyText(widget: canvas.Widget, text: []const u8) usize {
    var n: usize = if (std.mem.eql(u8, widget.text, text)) 1 else 0;
    for (widget.children) |child| n += countAnyText(child, text);
    return n;
}

test "a page with no name on it says the npub once" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.setIdentityForTest([_]u8{0x6C} ** 32);
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const who = [_]u8{0x2B} ** 32;
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = who }, &fx);

    // The header band names whoever the page is about, which 11b asks for and
    // which is not the duplication at issue. So the band is the one legitimate
    // occurrence, and the question is whether the CARD says it again underneath
    // its own name line.
    const short = main.npubShortForTest(arena, who);
    try testing.expect(short.len > 0);

    // No kind:0, so `personName` hands back the short npub for the name line.
    // The npub row must then stand down: band + name line is two, and the row
    // would make three, the same string stacked on itself.
    const nameless = try buildTree(arena, &model);
    const said = countAnyText(nameless.root, short);
    if (said != 2) {
        std.debug.print("nameless page prints \"{s}\" {d} times, want 2 (band + name line)\n", .{ short, said });
        return error.SaidTwice;
    }

    // Given a name, the two lines carry different strings and both belong: the
    // band and the name line say "Grace", the row says the npub, once.
    const prof = main.upsertProfile(who).?;
    main.parseMetadataInto(prof, "{\"display_name\":\"Grace\"}");
    const named = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 2), countAnyText(named.root, "Grace"));
    try testing.expectEqual(@as(usize, 1), countAnyText(named.root, short));
}
test "there is always something under a name" {
    // The identity block is pinned to the avatar's height, so an empty second
    // line is not restraint: it is a hole in the row that reads as a rendering
    // bug. It was empty for anyone with no NIP-05 and no username distinct from
    // their display name, which is a great many people.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const Case = struct { secret: u8, meta: []const u8, want: []const u8, violet: bool };
    const cases = [_]Case{
        // A NIP-05 is shown WHOLE. The domain is the half that says who vouched
        // for the name, so dropping it threw away the part worth showing.
        .{ .secret = 0x11, .meta = "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}", .want = "dergigi@primal.net", .violet = true },
        // The root form is the domain alone: `_@fiatjaf.com` is `fiatjaf.com`.
        .{ .secret = 0x12, .meta = "{\"display_name\":\"fiatjaf\",\"nip05\":\"_@fiatjaf.com\"}", .want = "fiatjaf.com", .violet = true },
        // No NIP-05: the username, muted, because violet has to keep meaning
        // attested somewhere.
        .{ .secret = 0x13, .meta = "{\"display_name\":\"Satoshi\",\"name\":\"nakamoto\"}", .want = "@nakamoto", .violet = false },
        // A username that only echoes the name above it is not a handle, so the
        // website stands in, as its host.
        .{ .secret = 0x14, .meta = "{\"display_name\":\"jack\",\"name\":\"jack\",\"website\":\"https://www.cash.app/about\"}", .want = "cash.app", .violet = false },
        // Nothing but a display name: the npub, which is the last honest handle
        // and the case that used to render as a void.
        .{ .secret = 0x15, .meta = "{\"display_name\":\"Anonymous\"}", .want = "", .violet = false },
        // ORDER. Every row above reaches its rung by the ones before it being
        // absent, which pins no precedence at all: a ladder that tried the
        // website first would satisfy all of them. These two carry more than one
        // rung's worth of data and say which wins.
        .{
            .secret = 0x17,
            .meta = "{\"display_name\":\"Gigi\",\"name\":\"gigi\",\"website\":\"https://dergigi.com\",\"nip05\":\"dergigi@primal.net\"}",
            .want = "dergigi@primal.net",
            .violet = true,
        },
        .{
            .secret = 0x18,
            .meta = "{\"display_name\":\"Somebody\",\"name\":\"someone\",\"website\":\"https://example.com\"}",
            .want = "@someone",
            .violet = false,
        },
        // A website that is not a web address never reaches the line. kind:0 is
        // a stranger's JSON and this string is rendered under their name.
        .{
            .secret = 0x19,
            .meta = "{\"display_name\":\"Trickster\",\"website\":\"javascript:alert(1)\"}",
            .want = "",
            .violet = false,
        },
    };

    for (cases) |c| {
        const kp = try signer.keyPairFromSecretKey([_]u8{c.secret} ** 32);
        const p = main.upsertProfile(kp.public_key).?;
        main.parseMetadataInto(p, c.meta);
        const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
        const note = main.noteFrom(ev, 1_800_000_000);
        const got = note.handleLabel(arena);

        if (c.want.len > 0) {
            try testing.expectEqualStrings(c.want, got.text);
        } else {
            // The npub case: whatever the exact string, it must be the npub and
            // it must not be empty.
            try testing.expect(got.text.len > 0);
            try testing.expect(std.mem.startsWith(u8, got.text, "npub1"));
        }
        try testing.expectEqual(c.violet, got.nip05);
    }

    // And the one case where saying nothing is right: a stranger with no kind:0
    // at all already has the short npub on the NAME line, so repeating it
    // underneath would be the same string twice.
    const stranger = try signer.keyPairFromSecretKey([_]u8{0x16} ** 32);
    const ev = try signedNote(arena, signer, stranger, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
    try testing.expectEqualStrings("", note.handleLabel(arena).text);
}

test "an npub is shortened one way, everywhere" {
    // There were two rules, twelve characters on the feed's name line and ten
    // everywhere else, so the same key rendered as two different strings
    // depending on which line it landed on. Anything comparing them to avoid
    // repeating a handle compared unequal and printed it twice, in two
    // spellings, which is worse than the duplication it was avoiding.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x2F} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);

    // The name line falls back to the npub, and the shortener every other
    // surface uses has to produce the same characters.
    try testing.expectEqualStrings(note.author(), main.npubShortForTest(arena, kp.public_key));
}

test "one identity, one spelling, on the same screen" {
    // `handleLabel` shows the whole NIP-05 and `Note.handle` shows `@local`.
    // Both are fine, for different jobs: an identity LINE wants the domain,
    // because that is the half saying who vouched for the name, and naming
    // somebody INLINE in a sentence does not, because a whole address mid
    // sentence reads as an email.
    //
    // What is not fine is both on the same screen for the same person, which is
    // what a nested reply did: the row's line read "dergigi@primal.net" and the
    // reply nested under it read "@dergigi".
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x21} ** 32);
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}");

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);

    // The identity line, wherever it is drawn, is the ladder's answer.
    try testing.expectEqualStrings("dergigi@primal.net", note.handleLabel(arena).text);
    // The inline form stays compact, and stays DIFFERENT on purpose, so this
    // pins the distinction rather than letting the two drift back together.
    try testing.expectEqualStrings("@dergigi", note.handle(arena));
}

test "a website that is not a web address never reaches the line" {
    // kind:0 is a stranger's JSON, and this string is rendered under their name.
    // `picture` has been gated on the scheme since it was added; `website`
    // arrived without the same gate, and `websiteHost` trims only schemes it
    // recognises, so anything else would have been stored and shown whole.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const hostile = [_][]const u8{
        "javascript:alert(1)",
        "data:text/html,<script>x</script>",
        "file:///etc/passwd",
        "not a url at all",
        "//evil.example.com",
    };
    for (hostile, 0..) |bad, i| {
        const kp = try signer.keyPairFromSecretKey([_]u8{@intCast(0x30 + i)} ** 32);
        const p = main.upsertProfile(kp.public_key).?;
        const meta = try std.fmt.allocPrint(arena, "{{\"display_name\":\"X\",\"website\":\"{s}\"}}", .{bad});
        main.parseMetadataInto(p, meta);
        const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
        const note = main.noteFrom(ev, 1_800_000_000);
        const got = note.handleLabel(arena).text;
        // It falls through to the npub rung, which is the honest answer, and
        // never to the string itself.
        try testing.expect(std.mem.indexOf(u8, got, bad) == null);
    }

    // And a real one still gets through, trimmed to its host.
    const ok_kp = try signer.keyPairFromSecretKey([_]u8{0x3F} ** 32);
    const ok_p = main.upsertProfile(ok_kp.public_key).?;
    main.parseMetadataInto(ok_p, "{\"display_name\":\"Y\",\"website\":\"https://www.example.com/a/b?c=d\"}");
    const ok_ev = try signedNote(arena, signer, ok_kp, 1_800_000_000, "hi");
    const ok_note = main.noteFrom(ok_ev, 1_800_000_000);
    try testing.expectEqualStrings("example.com", ok_note.handleLabel(arena).text);
}

test "a nested reply spells its author the same way the row above does" {
    // Both are identity lines, on the same screen, about the same person. One
    // reading "dergigi@primal.net" and the other "@dergigi" is the app spelling
    // one identity two ways inside a single thread.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const author = [_]u8{0x55} ** 32;
    const p = main.upsertProfile(author).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}");

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = author;
    model.thread_notes[0] = threadNote(0x10, 200, 0xAA);
    model.thread_notes[0].pubkey = author;
    model.thread_notes[0].id = 10;
    model.thread_notes[1] = threadNote(0x11, 300, 0x10);
    model.thread_notes[1].pubkey = author;
    model.thread_notes[1].id = 11;
    model.thread_notes_len = 2;
    main.arrangeThread(model.thread_notes[0..2], model.thread_root.event_id);
    try testing.expectEqual(@as(u8, 2), model.thread_notes[1].depth);

    // The whole NIP-05 has to be on screen at least twice, once for the reply
    // and once for the reply nested under it, and the compact form nowhere.
    const tree = try buildTree(arena, &model);
    try testing.expect(countAnyText(tree.root, "dergigi@primal.net") >= 2);
    try testing.expect(findAnyText(tree.root, "@dergigi") == null);
}
/// The dismiss Msg of the surface that CONTAINS `text`, and nothing else.
///
/// Not every dismiss in the view: the mention picker floats inside the compose
/// sheet, which has a dismiss of its own, and firing both closed the sheet and
/// took the picker off screen with it. The test then passed with the picker's
/// own dismissal doing nothing at all, which is the bug it was written for.
fn dismissMsgOfSurfaceHolding(p: painted.Painted, text: []const u8) ?Msg {
    var holder: ?usize = null;
    for (p.layout.nodes, 0..) |node, i| {
        if (!std.mem.eql(u8, node.widget.text, text)) continue;
        holder = i;
        break;
    }
    var cursor = holder orelse return null;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const w = p.layout.nodes[cursor].widget;
        switch (w.kind) {
            .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu => {
                for (p.tree.handlers) |h| {
                    if (h.id != w.id or h.event != .dismiss) continue;
                    return switch (h.action) {
                        .message => |m| m,
                        else => null,
                    };
                }
                return null;
            },
            else => {},
        }
        cursor = p.layout.nodes[cursor].parent_index orelse return null;
    }
    return null;
}

test "dismissing a surface clears the state that opened it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The engine hides a dismissed surface immediately and the next rebuild is
    // truth again, so a dismiss wired to somebody ELSE's state hides the surface
    // for one frame and puts it straight back. It looks like a flicker and it
    // reads as a control that does not work.
    //
    // Found live on the note menu, which sent `close_menu` (the chrome's state)
    // while its own open flag was its own, and then on the mention picker, which
    // had no open flag at all. Both had the same shape: the surface is on screen
    // after the dismiss it declared. That note menu is gone (a right-click does
    // its job now), so the picker is what stands guard over the shape.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const Case = struct {
        name: []const u8,
        text: []const u8,
        open: *const fn (*Model) void,
    };
    const cases = [_]Case{
        .{
            .name = "the mention picker",
            .text = "inserts a nostr: link, not just a name",
            .open = struct {
                fn f(m: *Model) void {
                    m.stage = .ready;
                    m.composing = true;
                    // Somebody to offer: the picker draws nothing without a name it
                    // could insert.
                    const who = [_]u8{0x91} ** 32;
                    if (main.upsertProfile(who)) |pr| {
                        main.parseMetadataInto(pr, "{\"display_name\":\"Alice\"}");
                    }
                    m.draft_buffer.set("hello @Al");
                }
            }.f,
        },
    };

    for (cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const before = try painted.Painted.render(arena, &model);
        if (findAnyText(before.tree.root, c.text) == null) {
            std.debug.print("{s} is not on screen to begin with\n", .{c.name});
            return error.SurfaceNotOpen;
        }

        // The dismiss THIS surface declares, and only it.
        const msg = dismissMsgOfSurfaceHolding(before, c.text) orelse {
            std.debug.print("{s} declares no dismiss of its own\n", .{c.name});
            return error.NoDismissDeclared;
        };
        var fx: main.EffectsForTest = undefined;
        main.update(&model, msg, &fx);

        const after = try painted.Painted.render(arena, &model);
        if (findAnyText(after.tree.root, c.text) != null) {
            std.debug.print("{s} is still on screen after its own dismiss\n", .{c.name});
            return error.DismissDidNotClose;
        }
    }
}
test "a profile's name, check and npub sit next to each other" {
    // The overflow sweep cannot see this. Bounding the name with a definite
    // width satisfied it completely and still ruined the page: `width` is a
    // definite SIZE, so the name's box stayed 559px wide for a three-letter
    // name and the verified check sat at the far right of the window, with the
    // same hole between the handle and the npub. It measured perfectly and
    // looked broken.
    //
    // So this measures the gaps, which is what a reader actually sees.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Signed in, or the page under test is the guest banner. The first version
    // of this test measured that banner and reported the rail's icon as a
    // verified check adrift by 277px, which is a good reminder that a
    // measurement is only as good as the screen it was taken on.
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();

    var them: [32]u8 = undefined;
    @memset(&them, 0x11);
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.fillProfileTextForTest(them, "Sep", "sep", "https://zignostr.com");
    main.setProfileNip05ForTest(them, "sep@zignostr.com", true);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = them;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);

    // Anchored on the CHECK, then the name is whatever sits on its line to its
    // left. Anchoring on the name instead found the copy in the header band
    // forty pixels up, whose line has no check on it, so the whole assertion
    // was skipped and the test passed the bug it exists for.
    var check: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (n.widget.kind != .icon) continue;
        if (!std.mem.eql(u8, n.widget.text, "check")) continue;
        check = n.widget.frame;
    }
    const c = check orelse return error.NoVerifiedCheckOnThePage;

    var name: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (n.widget.text.len == 0 or n.widget.kind == .icon) continue;
        if (n.widget.frame.y < c.y - 14 or n.widget.frame.y > c.y + 14) continue;
        if (n.widget.frame.x >= c.x) continue;
        if (name == null or n.widget.frame.x > name.?.x) name = n.widget.frame;
    }
    const nm = name orelse return error.NoNameBesideTheCheck;

    // Measured from where the name STARTS, not from the far side of its box.
    // Measuring from the box passes the exact bug this exists for: give the
    // name a definite 559px width and the check sits 7px past the end of that
    // box, dutifully adjacent to a rectangle that is almost entirely empty.
    // The reader sees the distance from the word.
    const from_word = c.x - nm.x;
    if (from_word > 90) {
        std.debug.print(
            "\nthe verified check is {d:.0}px from the start of a three-letter name (its box is {d:.0} wide)\n",
            .{ from_word, nm.width },
        );
        return error.CheckAdrift;
    }

    const handle = frameOfTextContaining(p, "sep@zignostr.com") orelse return error.NoHandle;

    // And the npub follows the handle rather than starting a column of its own.
    if (frameOfTextContaining(p, "npub1")) |npub| {
        const npub_gap = npub.x - handle.x;
        if (npub_gap > 160) {
            std.debug.print(
                "\nthe npub is {d:.0}px from the start of the handle (its box is {d:.0} wide)\n",
                .{ npub_gap, handle.width },
            );
            return error.NpubAdrift;
        }
    }
}

test "a profile states one identifier per line, in order" {
    // Name, then the address they proved, then the key. They shared a row
    // before, which read as one strip of identifiers and put the npub, the part
    // most likely to be copied, in the middle of it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    var them: [32]u8 = undefined;
    @memset(&them, 0x11);
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.fillProfileTextForTest(them, "Sep", "sep", "https://zignostr.com");
    main.setProfileNip05ForTest(them, "sep@zignostr.com", true);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = them;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);
    const nip05 = frameOfTextContaining(p, "sep@zignostr.com") orelse return error.NoHandle;
    const npub = frameOfTextContaining(p, "npub1") orelse return error.NoNpub;

    // Below, not beside. A row would put them at the same y.
    if (npub.y <= nip05.y + 2) {
        std.debug.print("\nthe npub is at y={d:.0} and the handle at y={d:.0}\n", .{ npub.y, nip05.y });
        return error.NpubNotBelowHandle;
    }
    // And on the same rail, so the column reads as a column.
    if (@abs(npub.x - nip05.x) > 1.5) {
        std.debug.print("\nthe npub starts at x={d:.0} and the handle at x={d:.0}\n", .{ npub.x, nip05.x });
        return error.NotOnOneRail;
    }
}
test "a wanted profile is never silently dropped, however many are wanted" {
    // The old table held 48 and, once full, looked for a slot already asked the
    // maximum number of times. Finding none it fell off the end of the function
    // having queued nothing at all. With 144 notifications that is what it did
    // every time, which is why a name only ever appeared after visiting that
    // person's profile: visiting asks for one pubkey, so it survived the churn.
    //
    // No shipping client caps authors here. NDK merges them with no limit at
    // all; Amethyst rebuilds one REQ from every name currently on screen.
    main.resetWantedProfilesForTest();

    const many = 300;
    var i: usize = 0;
    while (i < many) : (i += 1) {
        var pk = [_]u8{0} ** 32;
        pk[0] = @intCast(i % 251);
        pk[1] = @intCast(i / 251);
        pk[2] = @intCast(i % 7 + 1);
        main.wantProfileForTest(pk);
    }

    // Every distinct key asked for is still being asked for. The exact count is
    // not the point: that none of them vanished is.
    try testing.expect(main.wantedProfileCountForTest() >= 200);
}

test "a feed author with no name is asked about, before the row is on screen" {
    // The wanted set had exactly two sources: the inbox, and quoted notes. The
    // feed registered nobody. That was survivable only while `refreshProfiles`
    // walked the whole follow list, and when that walk left the render path the
    // feed lost its only source of names. Real accounts, with profiles sitting
    // on the relays, drew as a raw npub and a two-character avatar for the
    // whole session.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;

    // A feed longer than one screen, so the band matters.
    const rows = 40;
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        var note = threadNote(@intCast(i + 1), @intCast(1000 - @as(i64, @intCast(i))), 0);
        note.id = @intCast(i + 1);
        note.pubkey = [_]u8{@intCast(i + 1)} ** 32;
        model.notes[i] = note;
    }
    model.notes_len = rows;
    main.setVisibleRangeForTest(0, 4);

    main.wantProfilesAheadForTest(&model);

    // On screen: asked about, obviously.
    try testing.expect(main.isProfileWantedForTest([_]u8{1} ** 32));
    try testing.expect(main.isProfileWantedForTest([_]u8{5} ** 32));

    // And ahead of the fold, which is the point: a name that only starts
    // loading when the row appears is a name the reader watches arrive. It is
    // also what lets a face be warmed early, since the picture URL lives in the
    // kind:0 and there is nothing to warm until it lands.
    try testing.expect(main.isProfileWantedForTest([_]u8{12} ** 32));

    // Not the whole feed, though: the band is bounded, or a long scrollback
    // would ask about everybody at once.
    try testing.expect(!main.isProfileWantedForTest([_]u8{40} ** 32));
}
test "rendering a mention records where its label landed and whom it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{7} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"jack\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "hey nostr:{s} welcome", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);

    try testing.expectEqualStrings("hey @jack welcome", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), mentions.all().len);
    const ref = mentions.all()[0];
    // The recorded range is the label in the RENDERED buffer, not the token in
    // the source: the pubkey is gone from the text by then, which is the whole
    // reason this table exists.
    try testing.expectEqualStrings("@jack", buf[ref.off..][0..ref.len]);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(ref.link()).?));
}
test "a mention with a space in the name is one pressable span, not two" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ui = main.AppUi.init(arena);

    const pk = [_]u8{11} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"Sepehr Safari\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "gm nostr:{s} o/", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);
    const text = buf[0..n];

    const spans = main.contentSpansIn(&ui, text, mentions.all(), 0);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("gm ", spans[0].text);
    // The `@`-to-first-space heuristic reads this as `@Sepehr` and leaves the
    // surname behind as plain text. The recorded range knows how long the label
    // is because it is what wrote it.
    try testing.expectEqualStrings("@Sepehr Safari", spans[1].text);
    try testing.expectEqualStrings(" o/", spans[2].text);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(spans[1].link).?));
}

test "an offset recorded before the trim still points at the label after it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{13} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"ana\"}");

    // The picture is lifted out of the text and drawn as a picture, which is
    // what strands the whitespace the trim then removes, and the trim shifts
    // everything after it to the left.
    const image = "https://example.com/a.jpg";
    const src = try std.fmt.allocPrint(arena, "{s} nostr:{s}", .{ image, npub });
    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const n = main.renderContentInto(&buf, src, &.{image}, &mentions);

    try testing.expectEqualStrings("@ana", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), mentions.all().len);
    const ref = mentions.all()[0];
    try testing.expectEqual(@as(u16, 0), ref.off);
    try testing.expectEqualStrings("@ana", buf[ref.off..][0..ref.len]);
}

test "mentions map onto a piece of the content, not only the whole of it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ui = main.AppUi.init(arena);

    const pk = [_]u8{17} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"bo\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "hello nostr:{s}", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);
    const text = buf[0..n];

    // What a body does when it splits around a quote card: the paragraph after
    // the rule is handed a slice starting part-way in, and the offsets recorded
    // against the whole have to be read relative to that.
    const tail_at: usize = 6;
    const spans = main.contentSpansIn(&ui, text[tail_at..], mentions.all(), tail_at);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("@bo", spans[0].text);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(spans[0].link).?));

    // And with the offset NOT applied, the same mention is not found, so the
    // check above is testing the rebasing rather than passing for free.
    const wrong = main.contentSpansIn(&ui, text[tail_at..], mentions.all(), 0);
    try testing.expect(wrong.len == 0 or main.mentionLinkPubkey(wrong[0].link) == null);
}

// -- Reposting ----------------------------------------------------------------

// -- The mute list you already have -------------------------------------------

test "a refused host sends the face back through its own door, once" {
    defer main.resetProfilesForTest();
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
    }
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    var fx: main.EffectsForTest = undefined;
    const pk = [_]u8{0x3b} ** 32;
    main.setProfileAvatarForTest(pk, 1, .fetching);

    // wsrv.nl's refusal of the HOST. The face goes back to idle so the next
    // pass asks again, and it is now pinned to its own host.
    main.deliverAvatarResponseForTest(&fx, pk, .ok, 400, "");
    const after = main.avatarFallbackStateForTest(pk).?;
    try testing.expect(after.idle);
    try testing.expect(after.direct);

    // Once. A second refusal, this time from the host itself, is a real
    // failure: there is nowhere else to ask, so it must not loop.
    main.setProfileAvatarForTest(pk, 1, .fetching);
    main.deliverAvatarResponseForTest(&fx, pk, .ok, 400, "");
    const again = main.avatarFallbackStateForTest(pk).?;
    try testing.expect(!again.idle);
}

// -- A note with more than one picture ----------------------------------------

test "a face assembles from slices too, and never outlives its fetch" {
    // Faces and banners were left on one request when pictures moved to slices,
    // so a full-size profile picture straight from its own host still drew
    // initials for exactly the reason a photo drew a blank cell. One Download,
    // three consumers.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var fx: main.EffectsForTest = undefined;
    const pk = [_]u8{0x2a} ** 32;
    main.setProfileAvatarForTest(pk, 1, .fetching);

    const full = try arena.alloc(u8, main.maxImageBytesForTest());
    @memset(full, 0x5a);
    try testing.expectEqual(main.SliceOutcome.want_more, main.appendAvatarSliceForTest(pk, full).?);
    try testing.expectEqual(main.SliceOutcome.complete, main.appendAvatarSliceForTest(pk, "tail").?);
    try testing.expectEqual(@as(usize, 1), main.avatarPartialCountForTest());

    // The host stops answering partway through the next one: the bytes go with
    // the fetch, or a feed of failing hosts leaks megabytes of faces.
    main.deliverAvatarResponseForTest(&fx, pk, .timed_out, 0, "");
    try testing.expectEqual(@as(usize, 0), main.avatarPartialCountForTest());

    // And a busy effect table is the other way a fetch ends without an answer.
    // It sends the face back to idle to be asked again from the start, so what
    // it already had has to go with it: keeping it would splice the front of
    // one download onto the front of the next.
    _ = main.appendAvatarSliceForTest(pk, full);
    try testing.expectEqual(@as(usize, 1), main.avatarPartialCountForTest());
    main.deliverAvatarResponseForTest(&fx, pk, .rejected, 0, "");
    try testing.expectEqual(@as(usize, 0), main.avatarPartialCountForTest());
}

test "a face on a private host is not drawn" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    const p = main.upsertProfile([_]u8{0x73} ** 32).?;
    main.parseMetadataInto(p, "{\"name\":\"inward\",\"picture\":\"http://127.0.0.1:8080/face.png\"}");
    try testing.expectEqual(@as(usize, 0), @as(usize, p.picture_len));
}

test "a banner on a private host is not drawn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x75} ** 32);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/banner.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    const meta = try signedKind(arena, signer, kp, 1_800_000_000, 0, &.{}, "{\"name\":\"inward\",\"banner\":\"https://10.1.2.3/banner.jpg\"}");
    _ = try store.ingest(arena, meta, .{});
    try testing.expectEqualStrings("", main.personBanner(kp.public_key));
}

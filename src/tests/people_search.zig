//! Tests of people_search.zig. Finding a person: the local index, the relays asked, and NIP-05 lookups.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig
const buildTree = harness.buildTree;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const pressMsgByLabel = harness.pressMsgByLabel;
const search = harness.search;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

fn profileEvent(arena: std.mem.Allocator, signer: nostr.keys.Signer, seed: u8, created_at: i64, json: []const u8) !nostr.event.Event {
    const kp = try signer.keyPairFromSecretKey([_]u8{seed} ** 32);
    return signedKind(arena, signer, kp, created_at, 0, &.{}, json);
}

fn typeIntoSearch(model: *Model, text: []const u8) void {
    var fx: main.EffectsForTest = undefined;
    main.update(model, Msg.open_address, &fx);
    main.update(model, Msg{ .address_edit = .{ .insert_text = text } }, &fx);
}
test "profiles on this machine are found by any part of a name, and the follows come first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/findlocal.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfilesForTest();
    main.searchResetForTest();
    defer main.searchResetForTest();

    main.setIdentityForTest([_]u8{0x7a} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&me_hex, "{x}", .{&me});

    // 0x21 is followed, 0x22 follows the reader, the rest are strangers.
    const people = [_]struct { seed: u8, json: []const u8 }{
        .{ .seed = 0x21, .json = "{\"display_name\":\"Black Jack\"}" },
        .{ .seed = 0x22, .json = "{\"name\":\"jack\"}" },
        .{ .seed = 0x23, .json = "{\"name\":\"jackson\"}" },
        .{ .seed = 0x24, .json = "{\"display_name\":\"Hijack\"}" },
        .{ .seed = 0x25, .json = "{\"name\":\"bob\",\"nip05\":\"bob@jack.example\"}" },
        .{ .seed = 0x26, .json = "{\"name\":\"zed\"}" },
        // Nothing to find it by.
        .{ .seed = 0x27, .json = "{\"about\":\"jack of nothing\"}" },
    };
    var pks: [people.len][32]u8 = undefined;
    for (people, 0..) |person, i| {
        const ev = try profileEvent(arena, signer, person.seed, 1_800_000_000, person.json);
        pks[i] = ev.pubkey;
        _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    }
    _ = main.setFollowsForTest(&.{pks[0]}, 1_800_000_001);
    const kp22 = try signer.keyPairFromSecretKey([_]u8{0x22} ** 32);
    const followed_back = try signedKind(arena, signer, kp22, 1_800_000_002, 3, &[_]nostr.event.Tag{&.{ "p", &me_hex }}, "");
    _ = try main.plazaIngestVerifiedForTest(arena, followed_back, signer);

    main.searchIndexRefreshForTest();
    // The profile with only an `about` is not in it: nothing to match on.
    try testing.expectEqual(@as(usize, 6), main.searchIndexLenForTest());

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "JACK");

    // Five matches, in the order the field promises, and not one network call:
    // typing alone has asked no relay.
    try testing.expect(!main.searchAskedForTest());
    try testing.expectEqual(@as(usize, 5), main.searchRowCountForTest());
    const want = [_]usize{ 0, 1, 2, 4, 3 };
    for (want, 0..) |who, i| {
        try testing.expectEqualSlices(u8, &pks[who], &main.searchRowPubkeyForTest(i));
        try testing.expect(main.searchRowLocalForTest(i));
        try testing.expectEqual(@as(u8, 0), main.searchRowRelaysForTest(i));
    }

    // Matching an address's domain alone is enough.
    var by_domain = main.initialModel();
    by_domain.stage = .ready;
    typeIntoSearch(&by_domain, "jack.exam");
    try testing.expectEqual(@as(usize, 1), main.searchRowCountForTest());
    try testing.expectEqualSlices(u8, &pks[4], &main.searchRowPubkeyForTest(0));
    // The row shows the address that put it in the list, so it is never a
    // mystery why Bob is there, even though nobody has checked it yet.
    {
        const tree = try buildTree(arena, &by_domain);
        try testing.expect(findAnyText(tree.root, "bob@jack.example") != null);
        try testing.expect(findAnyText(tree.root, "this device") != null);
    }

    // And somebody the reader has muted is not offered.
    try testing.expect(main.setMutesForTest(&.{pks[1]}, 1_800_000_003));
    defer main.forgetMutesForTest();
    var muted = main.initialModel();
    muted.stage = .ready;
    typeIntoSearch(&muted, "jack");
    try testing.expectEqual(@as(usize, 4), main.searchRowCountForTest());
    for (0..main.searchRowCountForTest()) |i| {
        try testing.expect(!std.mem.eql(u8, &pks[1], &main.searchRowPubkeyForTest(i)));
    }
}

test "the index reads every page of profiles, not just the first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/pages.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.clearIdentityForTest();

    // One more than a page, each its own author with its own second, so the
    // oldest is on the second page and only a build that pages can see it.
    const total = main.search_scan_page_for_test + 5;
    for (0..total) |i| {
        var secret = [_]u8{0} ** 32;
        std.mem.writeInt(u32, secret[0..4], @intCast(i + 1), .big);
        secret[31] = 1;
        const kp = try signer.keyPairFromSecretKey(secret);
        const json = try std.fmt.allocPrint(arena, "{{\"name\":\"person{d}\"}}", .{i});
        const ev = try signedKind(arena, signer, kp, 1_700_000_000 + @as(i64, @intCast(i)), 0, &.{}, json);
        _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    }
    main.searchIndexRefreshForTest();
    try testing.expectEqual(total, main.searchIndexLenForTest());

    var model = main.initialModel();
    model.stage = .ready;
    // The very first one written, the last the newest-first walk reaches.
    typeIntoSearch(&model, "person0");
    try testing.expect(main.searchRowCountForTest() >= 1);
}

test "typing asks the relays once the typing stops, once" {
    var model = main.initialModel();
    model.stage = .ready;
    main.searchResetForTest();
    defer main.searchResetForTest();

    typeIntoSearch(&model, "alice");
    const gen = main.searchGenForTest();
    // Still typing: not yet.
    main.searchTickForTest(&model, 0);
    try testing.expect(!main.searchAskedForTest());

    // Typed on, which starts the wait again.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "x" } }, &fx);
    try testing.expect(main.searchGenForTest() != gen);
    main.searchTickForTest(&model, 100);
    try testing.expect(!main.searchAskedForTest());

    // Quiet for long enough: asked, and asking again changes nothing.
    main.searchTickForTest(&model, 100_000);
    try testing.expect(main.searchAskedForTest());

    // A single letter is never sent on its own.
    var one = main.initialModel();
    one.stage = .ready;
    typeIntoSearch(&one, "a");
    main.searchTickForTest(&one, 100_000);
    try testing.expect(!main.searchAskedForTest());

    // An address is not a name, so it never goes to a relay.
    var addr = main.initialModel();
    addr.stage = .ready;
    typeIntoSearch(&addr, "npub1abc");
    main.searchTickForTest(&addr, 100_000);
    try testing.expect(!main.searchAskedForTest());
    try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());

    // Nor a NIP-05 address: the domain answers that, not the search relays.
    var nip = main.initialModel();
    nip.stage = .ready;
    typeIntoSearch(&nip, "alice@example.com");
    main.searchTickForTest(&nip, 100_000);
    try testing.expect(!main.searchAskedForTest());
}

test "opening search again while it is up keeps the term and what it found" {
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "alice");
    const gen = main.searchGenForTest();
    main.searchArrivedForTest(gen, 0, [_]u8{0x21} ** 32);
    main.searchTickForTest(&model, 0);
    try testing.expectEqual(@as(usize, 1), main.searchRowCountForTest());

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.open_address, &fx);
    try testing.expect(model.address_open);
    try testing.expectEqualStrings("alice", model.address_draft());
    try testing.expectEqual(@as(usize, 1), main.searchRowCountForTest());
    // And the term is still put to the relays once typing has settled.
    main.searchTickForTest(&model, 100_000);
    try testing.expect(main.searchAskedForTest());
}

test "a key, a signer link or a web link typed into search never leaves the machine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();

    const nsec = try nostr.nip19.encodeNsec(arena, [_]u8{0x5a} ** 32);
    const upper = try std.ascii.allocUpperString(arena, nsec);
    const keys = [_][]const u8{
        nsec,
        upper,
        try std.fmt.allocPrint(arena, "nostr:{s}", .{nsec}),
        try std.fmt.allocPrint(arena, "my key is {s}", .{nsec}),
        "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p",
        "bunker://" ++ "ab" ** 32 ++ "?relay=wss://relay.example.com&secret=hunter2",
        "nostrconnect://" ++ "ab" ** 32 ++ "?relay=wss://relay.example.com&secret=hunter2",
        "5a" ** 32,
    };
    for (keys) |text| {
        try testing.expectEqual(main.SearchInput.key, main.classifySearch(text));
        var model = main.initialModel();
        model.stage = .ready;
        var fx: main.EffectsForTest = undefined;
        typeIntoSearch(&model, text);
        // Long past the pause that sends a name, and Enter pressed too.
        main.searchTickForTest(&model, 100_000);
        main.update(&model, Msg.address_submit, &fx);
        main.searchTickForTest(&model, 200_000);
        try testing.expect(!main.searchAskedForTest());
        try testing.expect(!main.nip05AskedForTest());
        try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());
        // The field is left as it was, and its button does nothing.
        try testing.expect(model.address_open);
        try testing.expect(model.viewing_profile == null);
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "It is not searched for") != null);
    }

    // A link that is not a Nostr address is something to open, not a name, and
    // what its path and query carry is not put to the relays either.
    var link = main.initialModel();
    link.stage = .ready;
    const url = "https://docs.example.com/d/1x2y3z?token=abc";
    try testing.expectEqual(main.SearchInput.address, main.classifySearch(url));
    typeIntoSearch(&link, url);
    main.searchTickForTest(&link, 100_000);
    try testing.expect(!main.searchAskedForTest());
}

test "a search relay that ignores its limit cannot flood the list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/flood.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.searchResetForTest();
    defer main.searchResetForTest();
    const gen = main.searchGenForTest();
    var seen: main.SearchSeenForTest = .{};

    // The same person three times is one arrival, not three.
    const twice = try profileEvent(arena, signer, 0x40, 1_800_000_000, "{\"name\":\"again\"}");
    try testing.expect(main.searchAcceptSeenForTest(gen, 0, signer, twice, &seen));
    try testing.expect(!main.searchAcceptSeenForTest(gen, 0, signer, twice, &seen));
    try testing.expect(!main.searchAcceptSeenForTest(gen, 0, signer, twice, &seen));
    try testing.expectEqual(@as(usize, 1), main.searchInboxLenForTest());

    // Forty more people from a relay asked for thirty: the first thirty in all
    // are queued and the rest are left at the door.
    var accepted: usize = 1;
    for (0..40) |i| {
        const ev = try profileEvent(arena, signer, @intCast(0x41 + i), 1_800_000_000, "{\"name\":\"more\"}");
        if (main.searchAcceptSeenForTest(gen, 0, signer, ev, &seen)) accepted += 1;
    }
    try testing.expectEqual(@as(usize, main.searchRelayLimitForTest), accepted);
    try testing.expectEqual(@as(usize, main.searchRelayLimitForTest), main.searchInboxLenForTest());
}

test "a search relay has one thread out at a time, and is asked again once it is free" {
    main.searchResetForTest();
    defer main.searchResetForTest();

    // The first term takes relay 0.
    try testing.expect(main.claimSearchSlotForTest(0, 5));
    // The reader types on while that thread is still dialling: no second thread
    // for the same relay, however many terms settle meanwhile. The others are
    // their own.
    try testing.expect(!main.claimSearchSlotForTest(0, 6));
    try testing.expect(!main.claimSearchSlotForTest(0, 7));
    try testing.expect(main.claimSearchSlotForTest(1, 7));
    // Once it has gone, the term on screen is put to it, once.
    main.releaseSearchSlotForTest(0);
    try testing.expect(main.claimSearchSlotForTest(0, 7));
    main.releaseSearchSlotForTest(0);
    try testing.expect(!main.claimSearchSlotForTest(0, 7));
    main.releaseSearchSlotForTest(1);
}

test "a search term replaced while the socket opened is never sent" {
    main.searchResetForTest();
    defer main.searchResetForTest();
    const Sender = struct {
        sent: *usize,
        pub fn send(self: @This(), text: []const u8) !void {
            _ = text;
            self.sent.* += 1;
        }
    };
    var sent: usize = 0;
    const gen = main.searchGenForTest();
    try testing.expect(try main.searchSendCurrentForTest(gen, Sender{ .sent = &sent }, "req"));
    try testing.expectEqual(@as(usize, 1), sent);
    // The reader cleared the field, or typed something else, during the dial.
    main.searchResetForTest();
    try testing.expect(!try main.searchSendCurrentForTest(gen, Sender{ .sent = &sent }, "req"));
    try testing.expectEqual(@as(usize, 1), sent);
}

test "a key pasted with a character too many still never leaves the machine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();

    const hex = "5a" ** 32;
    const nsec = try nostr.nip19.encodeNsec(arena, [_]u8{0x5a} ** 32);
    const upper = try std.ascii.allocUpperString(arena, nsec);
    const keys = [_][]const u8{
        // A raw key with what a paste brings along. Each of these used to be a
        // name, and 62 to 64 of the key's digits went to the search relays.
        "\"" ++ hex ++ "\"",
        "'" ++ hex ++ "'",
        "0x" ++ hex,
        "0X" ++ hex,
        "@" ++ hex,
        hex ++ ".",
        hex ++ ",",
        "my key: " ++ hex ++ ", thanks",
        // Cut short by a character or two, it is still most of a key.
        hex[0..62],
        hex[0..60],
        // The bech32 forms, wrapped the same ways and in either case.
        try std.fmt.allocPrint(arena, "\"{s}\"", .{nsec}),
        try std.fmt.allocPrint(arena, "@{s}.", .{upper}),
        try std.fmt.allocPrint(arena, "({s}),", .{nsec}),
        "\"ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p\"",
        "@BUNKER://" ++ "AB" ** 32 ++ "?relay=wss://relay.example.com&secret=hunter2",
        "<NostrConnect://" ++ "ab" ** 32 ++ "?secret=hunter2>",
    };
    for (keys) |text| {
        try testing.expectEqual(main.SearchInput.key, main.classifySearch(text));
        var model = main.initialModel();
        model.stage = .ready;
        var fx: main.EffectsForTest = undefined;
        typeIntoSearch(&model, text);
        main.searchTickForTest(&model, 100_000);
        main.update(&model, Msg.address_submit, &fx);
        main.searchTickForTest(&model, 200_000);
        try testing.expect(!main.searchAskedForTest());
        try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "It is not searched for") != null);
    }

    // A name with some hex in it is still a name.
    try testing.expectEqual(main.SearchInput.term, main.classifySearch("deadbeef cafe"));
    try testing.expectEqual(main.SearchInput.term, main.classifySearch(hex[0..59]));
}

test "people the relays name are folded in, marked with who named them, and counted once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/fold.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfilesForTest();
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.clearIdentityForTest();

    // One person the store already holds, one it does not.
    const held = try profileEvent(arena, signer, 0x31, 1_800_000_000, "{\"name\":\"alice held\"}");
    _ = try main.plazaIngestVerifiedForTest(arena, held, signer);
    const stranger = try profileEvent(arena, signer, 0x32, 1_800_000_000, "{\"display_name\":\"Alicia Stranger\"}");
    main.searchIndexRefreshForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "ali");
    const gen = main.searchGenForTest();
    try testing.expectEqual(@as(usize, 1), main.searchRowCountForTest());
    try testing.expect(main.searchRowLocalForTest(0));

    // A relay thread's work on an event: verified, stored, handed over.
    try testing.expect(main.searchAcceptForTest(gen, 0, signer, stranger));
    // Not a profile, so not a person.
    const note = try signedNote(arena, signer, try signer.keyPairFromSecretKey([_]u8{0x33} ** 32), 1_800_000_000, "hi");
    try testing.expect(!main.searchAcceptForTest(gen, 0, signer, note));
    // A forgery is dropped at the door.
    var forged = stranger;
    forged.content = "{\"name\":\"someone else\"}";
    try testing.expect(!main.searchAcceptForTest(gen, 0, signer, forged));

    // The same stranger from a second relay, the held person from the first, and
    // an answer to a term that has since been replaced.
    main.searchArrivedForTest(gen, 1, stranger.pubkey);
    main.searchArrivedForTest(gen, 0, held.pubkey);
    main.searchArrivedForTest(gen -% 1, 2, [_]u8{0x99} ** 32);

    main.searchTickForTest(&model, 0);
    try testing.expectEqual(@as(usize, 2), main.searchRowCountForTest());

    // The person already held stays where they were, and gains the relay.
    try testing.expectEqualSlices(u8, &held.pubkey, &main.searchRowPubkeyForTest(0));
    try testing.expect(main.searchRowLocalForTest(0));
    try testing.expectEqual(@as(u8, 0b001), main.searchRowRelaysForTest(0));
    // The stranger is one row naming both relays that returned them.
    try testing.expectEqualSlices(u8, &stranger.pubkey, &main.searchRowPubkeyForTest(1));
    try testing.expect(!main.searchRowLocalForTest(1));
    try testing.expectEqual(@as(u8, 0b011), main.searchRowRelaysForTest(1));

    // And the sheet says so, by relay name, with the profile read from the store.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Alicia Stranger") != null);
    const first = main.searchRelayUrlForTest(0);
    const second = main.searchRelayUrlForTest(1);
    const both = try std.fmt.allocPrint(arena, "{s}, {s}", .{ main.relayShortName(first), main.relayShortName(second) });
    try testing.expect(findAnyTextContainingText(tree.root, both) != null);
    const device = try std.fmt.allocPrint(arena, "this device, {s}", .{main.relayShortName(first)});
    try testing.expect(findAnyTextContainingText(tree.root, device) != null);

    // Editing the term drops what the old one found.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "z" } }, &fx);
    main.searchArrivedForTest(gen, 0, stranger.pubkey);
    main.searchTickForTest(&model, 0);
    try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());
}

test "every relay's answer reaches the list when they all answer at once" {
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "nobody held");
    const gen = main.searchGenForTest();

    // Three relays each send a full answer before the next tick drains them.
    // The first lists the same people the third ends with.
    const per_relay = search.relay_limit;
    for (0..main.searchRelayCountForTest()) |relay| {
        for (0..per_relay) |i| {
            var pk = [_]u8{0} ** 32;
            pk[0] = @intCast(relay);
            pk[1] = @intCast(i);
            if (relay == 2 and i + 1 == per_relay) pk = [_]u8{0} ** 32;
            main.searchArrivedForTest(gen, @intCast(relay), pk);
        }
    }
    try testing.expect(main.search_inbox_cap_for_test >= main.searchRelayCountForTest() * per_relay);
    main.searchTickForTest(&model, 0);

    // The list is full, and the first person in it carries the mark of the last
    // relay to name them, which arrived after everything else.
    try testing.expectEqual(@as(usize, main.search_rows_max), main.searchRowCountForTest());
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &main.searchRowPubkeyForTest(0));
    try testing.expectEqual(@as(u8, 0b101), main.searchRowRelaysForTest(0));

    // And one relay sending a person twice has named one person.
    var seen: search.Seen = .{};
    try testing.expect(seen.add([_]u8{1} ** 32));
    try testing.expect(!seen.add([_]u8{1} ** 32));
    try testing.expect(seen.add([_]u8{2} ** 32));
}

test "a relay that found no one is named, not left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "nobody here");

    main.searchSetStatusForTest(0, .answered, 0);
    main.searchSetStatusForTest(1, .unreachable_, 0);
    main.searchSetStatusForTest(2, .declined, 0);

    const tree = try buildTree(arena, &model);
    // Every relay has its own line, with what became of it.
    for (0..main.searchRelayCountForTest()) |i| {
        try testing.expect(findAnyText(tree.root, main.relayShortName(main.searchRelayUrlForTest(i))) != null);
    }
    try testing.expect(findAnyText(tree.root, "found no one") != null);
    try testing.expect(findAnyText(tree.root, "could not connect") != null);
    try testing.expect(findAnyText(tree.root, "does not take searches") != null);
    // And the list itself says nobody turned up, rather than showing a blank.
    try testing.expect(findAnyTextContainingText(tree.root, "the search relays found no one") != null);
}

test "an empty field says what it takes and where a name goes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.open_address, &fx);

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "Nothing leaves it until you stop typing") != null);
    try testing.expect(findAnyTextContainingText(tree.root, "name@domain") != null);
    // The relays a name will be put to are named before anything is typed.
    for (0..main.searchRelayCountForTest()) |i| {
        try testing.expect(findAnyTextContainingText(tree.root, main.relayShortName(main.searchRelayUrlForTest(i))) != null);
    }
    // Nothing to act on yet.
    try testing.expectEqualStrings("Open", model.address_action());
    try testing.expect(model.address_empty());
}
test "an npub typed into the field opens that person, not a search" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();

    const pk = [_]u8{0x44} ** 32;
    const relays = [_][]const u8{"wss://one.example"};
    for ([_][]const u8{
        try nostr.nip19.encodeNpub(arena, pk),
        try nostr.nip19.encodeNprofile(arena, pk, &relays),
        try std.fmt.allocPrint(arena, "nostr:{s}", .{try nostr.nip19.encodeNpub(arena, pk)}),
    }) |address| {
        var model = main.initialModel();
        model.stage = .ready;
        var fx: main.EffectsForTest = undefined;
        typeIntoSearch(&model, address);
        // Nothing is listed or asked for while it is typed.
        try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());
        main.update(&model, Msg.address_submit, &fx);
        try testing.expect(!model.address_open);
        try testing.expect(model.viewing_profile != null);
        try testing.expectEqualSlices(u8, &pk, &model.viewing_profile.?);
        try testing.expect(!main.searchAskedForTest());
    }
}

test "a NIP-05 address typed into the field opens the person its domain names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.searchResetForTest();
    defer main.searchResetForTest();

    const hex = "cd" ** 32;
    const body = "{\"names\":{\"alice\":\"" ++ hex ++ "\"}}";
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    typeIntoSearch(&model, "alice@example.com");
    main.update(&model, Msg.address_submit, &fx);
    // Waiting on the domain, with the field still up.
    try testing.expect(main.nip05AskedForTest());
    try testing.expect(model.address_open);

    main.handleNip05FoundForTest(&model, .{ .key = main.nip05AskKeyForTest(), .status = 200, .body = body });
    try testing.expect(!model.address_open);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqualSlices(u8, &([_]u8{0xcd} ** 32), &model.viewing_profile.?);
    try testing.expect(!main.nip05AskedForTest());
}

test "a NIP-05 lookup that fails says why and leaves the field to be fixed" {
    main.searchResetForTest();
    defer main.searchResetForTest();
    var fx: main.EffectsForTest = undefined;

    // The domain does not list the name.
    {
        var model = main.initialModel();
        model.stage = .ready;
        typeIntoSearch(&model, "bob@example.com");
        main.update(&model, Msg.address_submit, &fx);
        main.handleNip05FoundForTest(&model, .{ .key = main.nip05AskKeyForTest(), .status = 200, .body = "{\"names\":{}}" });
        try testing.expect(model.address_open);
        try testing.expectEqual(main.AddressError.not_found, model.address_error);
        try testing.expectEqualStrings("bob@example.com", model.address_draft());
    }
    // The domain did not answer properly.
    {
        var model = main.initialModel();
        model.stage = .ready;
        typeIntoSearch(&model, "bob@example.com");
        main.update(&model, Msg.address_submit, &fx);
        main.handleNip05FoundForTest(&model, .{ .key = main.nip05AskKeyForTest(), .status = 503, .body = "" });
        try testing.expect(model.address_open);
        try testing.expectEqual(main.AddressError.lookup_failed, model.address_error);
        try testing.expect(model.viewing_profile == null);
    }
    // The reader typed on while it was out: the answer is to a question nobody
    // is asking, and navigates nowhere.
    {
        var model = main.initialModel();
        model.stage = .ready;
        typeIntoSearch(&model, "bob@example.com");
        main.update(&model, Msg.address_submit, &fx);
        main.update(&model, Msg{ .address_edit = .{ .insert_text = "x" } }, &fx);
        const hex = "ef" ** 32;
        main.handleNip05FoundForTest(&model, .{ .key = main.nip05AskKeyForTest(), .status = 200, .body = "{\"names\":{\"bob\":\"" ++ hex ++ "\"}}" });
        try testing.expect(model.address_open);
        try testing.expect(model.viewing_profile == null);
    }
}

test "an answer to an earlier NIP-05 lookup never names the person for the next one" {
    main.searchResetForTest();
    defer main.searchResetForTest();
    const evil = "ee" ** 32;
    const good = "11" ** 32;

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    typeIntoSearch(&model, "bob@one.example");
    main.update(&model, Msg.address_submit, &fx);
    const first = main.nip05AskKeyForTest();

    // The reader moves to the same name at another domain and asks again
    // before the first domain has answered.
    model.address_buffer.clear();
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "bob@two.example" } }, &fx);
    try testing.expectEqualStrings("A NIP-05 address. Enter asks its domain who that is.", model.address_status());
    main.update(&model, Msg.address_submit, &fx);
    const second = main.nip05AskKeyForTest();
    try testing.expect(first != second);
    try testing.expectEqualStrings("Asking the domain who that is.", model.address_status());

    // The first domain answers last-asked's name with its own person: dropped,
    // and the second lookup is still the one awaited.
    main.handleNip05FoundForTest(&model, .{ .key = first, .status = 200, .body = "{\"names\":{\"bob\":\"" ++ evil ++ "\"}}" });
    try testing.expect(model.address_open);
    try testing.expect(model.viewing_profile == null);
    try testing.expect(main.nip05AskedForTest());

    main.handleNip05FoundForTest(&model, .{ .key = second, .status = 200, .body = "{\"names\":{\"bob\":\"" ++ good ++ "\"}}" });
    try testing.expect(!model.address_open);
    try testing.expectEqualSlices(u8, &([_]u8{0x11} ** 32), &model.viewing_profile.?);
}

test "pressing a result opens that person and puts the field away" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/press.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfilesForTest();
    main.searchResetForTest();
    defer main.searchResetForTest();

    const ev = try profileEvent(arena, signer, 0x41, 1_800_000_000, "{\"name\":\"pressme\"}");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.searchIndexRefreshForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "pressme");
    const tree = try buildTree(arena, &model);
    // The row is a button carrying the person, found by the name it shows.
    const msg = pressMsgByLabel(tree, "pressme") orelse return error.ResultIsNotPressable;
    switch (msg) {
        .search_pick => |pk| try testing.expectEqualSlices(u8, &ev.pubkey, &pk),
        else => return error.ResultPressesSomethingElse,
    }
    var fx: main.EffectsForTest = undefined;
    main.update(&model, msg, &fx);
    try testing.expect(!model.address_open);
    try testing.expectEqualSlices(u8, &ev.pubkey, &model.viewing_profile.?);
    try testing.expectEqual(@as(usize, 0), main.searchRowCountForTest());
}

test "the search sheet fits the view budget with a full list over the deepest thing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "full");
    // As many rows as the list can ever hold.
    const gen = main.searchGenForTest();
    for (0..main.search_rows_max) |i| main.searchArrivedForTest(gen, @intCast(i % 3), [_]u8{@intCast(i + 1)} ** 32);
    main.searchTickForTest(&model, 0);
    try testing.expectEqual(main.search_rows_max, main.searchRowCountForTest());

    const author = [_]u8{0x55} ** 32;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = author;
    var n: usize = 0;
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        model.thread_notes[n] = threadNote(0x10 + i, 200 + @as(i64, i), 0xAA);
        model.thread_notes[n].pubkey = author;
        model.thread_notes[n].id = @as(i64, i) + 10;
        n += 1;
    }
    model.thread_notes_len = n;
    for (0..main.thread_depth_max) |d| {
        model.thread_stack[d] = .{ .note = threadNote(0xC0 + @as(u8, @intCast(d)), 50, 0) };
        model.thread_stack[d].note.id = 500 + @as(i64, @intCast(d));
        model.thread_stack[d].note.pubkey = author;
    }
    model.thread_stack_len = main.thread_depth_max;

    const p = painted.Painted.render(arena, &model) catch |err| {
        std.debug.print("search sheet over a full back stack refused: {s}\n", .{@errorName(err)});
        return err;
    };
    // Inside the ceiling AND leaving a tenth of it free, the margin the other
    // sheets keep.
    try testing.expect(p.layout.nodes.len < native_sdk.runtime.max_canvas_widget_nodes_per_view / 10 * 9);
}
test "a person found by name or by NIP-05 over Settings leaves Settings" {
    // The search field is the address field, and Cmd+L opens it over Settings.
    // A pressed result or a domain's answer opens a person's page, which is
    // drawn under Settings, so it has to leave Settings the way an address does.
    main.searchResetForTest();
    defer main.searchResetForTest();
    var fx: main.EffectsForTest = undefined;

    {
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, Msg.open_settings, &fx);
        main.update(&model, Msg.open_address, &fx);
        try testing.expectEqual(main.Stage.settings, model.stage);
        const pk = [_]u8{0x4e} ** 32;
        main.update(&model, Msg{ .search_pick = pk }, &fx);
        try testing.expectEqual(main.Stage.ready, model.stage);
        try testing.expectEqualSlices(u8, &pk, &(model.viewing_profile orelse return error.NoProfile));
    }
    {
        const hex = "4f" ** 32;
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, Msg.open_settings, &fx);
        typeIntoSearch(&model, "alice@example.com");
        main.update(&model, Msg.address_submit, &fx);
        try testing.expectEqual(main.Stage.settings, model.stage);
        main.handleNip05FoundForTest(&model, .{ .key = main.nip05AskKeyForTest(), .status = 200, .body = "{\"names\":{\"alice\":\"" ++ hex ++ "\"}}" });
        try testing.expectEqual(main.Stage.ready, model.stage);
        try testing.expectEqualSlices(u8, &([_]u8{0x4f} ** 32), &(model.viewing_profile orelse return error.NoProfile));
    }
}

/// The search sheet with one row from a relay: Rowan Reader, whose profile has a
/// kind:0 username and no NIP-05 address.
fn renderOneSearchRow(arena: std.mem.Allocator) !painted.Painted {
    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "row");
    const pk = [_]u8{0x4e} ** 32;
    main.fillProfileTextForTest(pk, "Rowan Reader", "rowan", "");
    main.searchArrivedForTest(main.searchGenForTest(), 0, pk);
    main.searchTickForTest(&model, 0);
    try testing.expectEqual(@as(usize, 1), main.searchRowCountForTest());
    return painted.Painted.render(arena, &model);
}

test "a search result leaves room for its focus ring" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    const p = try renderOneSearchRow(arena_state.allocator());

    const row = p.frameOf("Rowan Reader") orelse return error.NoRow;
    // The list the row scrolls in: the scroll view that contains it.
    var list: ?geometry.RectF = null;
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .scroll_view) continue;
        const f = node.widget.frame;
        if (f.x <= row.x and row.x + row.width <= f.x + f.width and f.y <= row.y and row.y <= f.y + f.height) list = f;
    }
    const f = list orelse return error.NoList;
    // The ring is drawn 2pt outside the row with a 2pt stroke, so the row must
    // stand at least that far inside the region that clips it.
    try testing.expect(row.x - f.x >= main.search_ring_room - 0.01);
    try testing.expect((f.x + f.width) - (row.x + row.width) >= main.search_ring_room - 0.01);
    // Only the rows are held in: the section label keeps the list's own edge.
    for (p.layout.nodes) |node| {
        if (!std.mem.startsWith(u8, node.widget.text, "FROM SEARCH RELAYS")) continue;
        try testing.expectApproxEqAbs(f.x, node.widget.frame.x, 0.01);
    }
}

test "a search result inks a username quietly and keeps the violet for an address" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.searchResetForTest();
    defer main.searchResetForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    const p = try renderOneSearchRow(arena_state.allocator());

    var handle_ink: ?canvas.Color = null;
    for (p.layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, "@rowan")) handle_ink = node.widget.style.foreground;
    }
    const ink = handle_ink orelse return error.NoHandle;
    try testing.expect(!std.meta.eql(ink, main.identityInkForTest()));

    // The same person once their address checks out: that line is violet.
    main.setProfileNip05ForTest([_]u8{0x4e} ** 32, "rowan@example.com", true);
    var model = main.initialModel();
    model.stage = .ready;
    typeIntoSearch(&model, "row");
    const q = try painted.Painted.render(arena_state.allocator(), &model);
    var address_ink: ?canvas.Color = null;
    for (q.layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, "rowan@example.com")) address_ink = node.widget.style.foreground;
    }
    try testing.expect(std.meta.eql(address_ink orelse return error.NoAddress, main.identityInkForTest()));
}

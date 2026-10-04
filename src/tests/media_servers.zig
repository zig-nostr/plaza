//! Tests of media_servers.zig. The reader's media servers: the list, asking whether one exists, and writing it.

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
const findByLabel = harness.findByLabel;

test "the composer names where pictures go before anything is chosen" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer main.clearIdentityForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    const tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyText(tree.root, "Add picture") != null);
    // No list published: the built-in server, named.
    try testing.expect(findAnyText(tree.root, "Uploads to blossom.primal.net") != null);

    main.setBlossomServersForTest(&.{"https://media.example.org"});
    const own = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyText(own.root, "Uploads to media.example.org") != null);
}

test "Settings lists the media servers and offers to add one, and a guest is not shown them" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x52} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyText(tree.root, "MEDIA SERVERS") != null);
    try testing.expect(findAnyText(tree.root, "blossom.primal.net") != null);
    try testing.expect(findAnyText(tree.root, "blossom.band") != null);
    try testing.expect(findAnyText(tree.root, "built in") != null);

    main.setBlossomServersForTest(&.{ "https://one.example", "https://two.example" });
    const own = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyText(own.root, "one.example") != null);
    try testing.expect(findAnyText(own.root, "two.example") != null);
    try testing.expect(findAnyText(own.root, "blossom.primal.net") == null);
    try testing.expect(findByLabel(own.root, "Remove https://one.example") != null);

    main.clearIdentityForTest();
    const guest = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyText(guest.root, "MEDIA SERVERS") == null);
}

fn blossomFixture(
    arena: std.mem.Allocator,
    signer: *nostr.keys.Signer,
    store: *nostr.store.Store,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !void {
    const secret = [_]u8{0x53} ** 32;
    const kp = try signer.keyPairFromSecretKey(secret);
    main.setIdentityForTest(secret);
    main.setStoreForTest(store);
    const ev = try nostr.event.create(arena, signer.*, kp, 1_800_000_000, 10063, tags, content, null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer.*);
    main.loadBlossomFromStoreForTest();
}

test "the server list is spliced, not rebuilt, and is never written over a list that was not read" {
    defer main.resetOutboxForTest();
    main.forgetBlossomForTest();
    defer {
        main.forgetBlossomForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    var fx: main.EffectsForTest = undefined;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bl.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // A list from another client: two servers, a tag this app does not know, and
    // a server address it cannot use. Everything that is not the one change must
    // come back out exactly as it went in.
    const existing = [_]nostr.event.Tag{
        &.{ "server", "https://one.example" },
        &.{ "server", "gopher://odd.example" },
        &.{ "alt", "media servers" },
        &.{ "server", "https://two.example" },
    };
    try blossomFixture(arena, &signer, &store, &existing, "legacy");
    try testing.expect(main.blossomOwnListForTest());

    try testing.expectEqual(main.BlossomWrite.published, main.writeBlossomServersForTest(&fx, "https://three.example", null));
    const added = main.ownRecordTagsJoinedForTest(arena, 10063).?;
    try testing.expect(std.mem.indexOf(u8, added, "server https://one.example") != null);
    try testing.expect(std.mem.indexOf(u8, added, "server gopher://odd.example") != null);
    try testing.expect(std.mem.indexOf(u8, added, "alt media servers") != null);
    try testing.expect(std.mem.indexOf(u8, added, "server https://two.example") != null);
    try testing.expect(std.mem.indexOf(u8, added, "server https://three.example") != null);
    try testing.expectEqualStrings("legacy", main.ownRecordContentForTest(arena, 10063).?);
    // Newer than what it replaced, or every relay drops it.
    try testing.expect(main.ownRecordCreatedAtForTest(10063) > 1_800_000_000);

    // Adding what is there already is nothing to do.
    main.releaseHelperSignForTest();
    try testing.expectEqual(main.BlossomWrite.nothing_to_do, main.writeBlossomServersForTest(&fx, "https://ONE.example/", null));

    // A fifth usable server is more than Plaza sends to.
    try testing.expectEqual(main.BlossomWrite.published, main.writeBlossomServersForTest(&fx, "https://four.example", null));
    main.releaseHelperSignForTest();
    try testing.expectEqual(main.BlossomWrite.full, main.writeBlossomServersForTest(&fx, "https://five.example", null));
    main.releaseHelperSignForTest();

    // Removing one drops that one and nothing else.
    try testing.expectEqual(main.BlossomWrite.published, main.writeBlossomServersForTest(&fx, null, "https://two.example"));
    const removed = main.ownRecordTagsJoinedForTest(arena, 10063).?;
    try testing.expect(std.mem.indexOf(u8, removed, "two.example") == null);
    try testing.expect(std.mem.indexOf(u8, removed, "server https://one.example") != null);
    try testing.expect(std.mem.indexOf(u8, removed, "server gopher://odd.example") != null);
    try testing.expect(std.mem.indexOf(u8, removed, "alt media servers") != null);
    main.releaseHelperSignForTest();
    try testing.expectEqual(main.BlossomWrite.nothing_to_do, main.writeBlossomServersForTest(&fx, null, "https://nowhere.example"));
}

test "with no list read, nothing is written, not even once every relay in the pool has said there is none" {
    main.forgetBlossomForTest();
    defer {
        main.forgetBlossomForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bl2.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setIdentityForTest([_]u8{0x54} ** 32);
    main.setStoreForTest(&store);

    // An empty store is "not fetched yet" as much as "has none".
    try testing.expectEqual(main.BlossomWrite.no_list_yet, main.writeBlossomServersForTest(&fx, "https://one.example", null));
    try testing.expect(main.ownRecordTagsJoinedForTest(arena, 10063) == null);

    // Some relay failed to answer: still not proof.
    main.markBlossomProbeCleanForTest(false);
    try testing.expectEqual(main.BlossomWrite.no_list_yet, main.writeBlossomServersForTest(&fx, "https://one.example", null));

    // Every relay in the pool answered and none had one: still not proof. On a
    // cold import the pool is the bootstrap relays, and the list lives on the
    // relays the reader writes to. Writing here would publish a list of one
    // over the reader's real one.
    main.markBlossomProbeCleanForTest(true);
    try testing.expectEqual(main.BlossomWrite.no_list_yet, main.writeBlossomServersForTest(&fx, "https://one.example", null));
    try testing.expect(main.ownRecordTagsJoinedForTest(arena, 10063) == null);
}
test "a relay that declines to look, or a list only held in memory, never licenses writing a first list" {
    // EOSE is a relay saying it looked. CLOSED is one saying it will not
    // (auth-required, rate-limited), and the list may well be kept there.
    try testing.expect(main.probeReplyAnswersForTest(.eose));
    try testing.expect(!main.probeReplyAnswersForTest(.closed));

    main.forgetBlossomForTest();
    defer {
        main.forgetBlossomForTest();
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bl3.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setIdentityForTest([_]u8{0x59} ** 32);
    main.setStoreForTest(&store);
    main.markBlossomProbeCleanForTest(false);

    // Two servers held in memory, and nothing in the store to splice onto.
    // Writing now would publish a list of one and replace whatever is out there.
    main.setBlossomServersForTest(&.{ "https://one.example", "https://two.example" });
    try testing.expectEqual(main.BlossomWrite.no_list_yet, main.writeBlossomServersForTest(&fx, "https://three.example", null));
    try testing.expect(main.ownRecordTagsJoinedForTest(arena, 10063) == null);

    // A round that could not tell is asked again; one that could is not.
    try testing.expect(main.blossomProbeWantedForTest());
    main.markBlossomProbeCleanForTest(true);
    try testing.expect(!main.blossomProbeWantedForTest());
}

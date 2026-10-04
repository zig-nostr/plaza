//! Tests of addresses.zig. Addressable events: the naddr table, and the fetches that find an article by its address.

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
const articleStore = harness.articleStore;
const buildTree = harness.buildTree;
const findAnyTextContaining = harness.findAnyTextContaining;
const signedKind = harness.signedKind;

test "pasting an naddr opens the article it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x65} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "pasted");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "pasted-one" },
        &[_][]const u8{ "title", "Pasted into the address field" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "# Heading\n\nThe body.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    // A different article by the same author must not be what opens.
    const other_tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "not-this-one" }};
    const other = try signedKind(arena, signer, kp, 1_800_000_500, 30023, &other_tags, "Some other article.");
    _ = try main.plazaIngestVerifiedForTest(arena, other, signer);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.open_address, &fx);
    const naddr = try nostr.nip19.encodeNaddr(arena, "pasted-one", kp.public_key, 30023, &.{});
    main.update(&model, Msg{ .address_edit = .{ .insert_text = naddr } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));
    try testing.expectEqual(@as(u16, 30023), model.thread_root.kind);
    // And it is the reader, with the title on the page.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(tree.root, "Pasted into the address field"));
}

test "the newest copy of an address is the one that opens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x66} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "newest");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "edited" }};
    const older = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The first draft of the text.");
    const newer = try signedKind(arena, signer, kp, 1_800_009_000, 30023, &tags, "The edited text.");
    // The newer arrives first, so the older one is the late arrival, which is
    // the order a stale relay produces.
    _ = try main.plazaIngestVerifiedForTest(arena, newer, signer);
    _ = try main.plazaIngestVerifiedForTest(arena, older, signer);

    const addr_id = main.newestAddressIdForTest(&store, 30023, kp.public_key, "edited") orelse return error.NothingFound;
    try testing.expect(std.mem.eql(u8, &addr_id, &newer.id));

    var model = main.initialModel();
    model.stage = .ready;
    main.openAddressedArticleForTest(&model, 30023, kp.public_key, "edited");
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &newer.id));
}

test "an article that is not held is fetched, opened when it lands, and replaced by a newer copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x67} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "lands");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "arrives" }};
    const first = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The copy on the first relay.");
    const second = try signedKind(arena, signer, kp, 1_800_005_000, 30023, &tags, "The copy that was edited since.");

    var model = main.initialModel();
    model.stage = .ready;
    // Loading: nothing is held, the reader is told, and a window is watching.
    main.openAddressedArticleForTest(&model, 30023, kp.public_key, "arrives");
    try testing.expectEqualStrings("Fetching that article", model.toast_text());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expect(main.addressFetchArmedForTest());
    main.refreshAddressFetchForTest(&model);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // Found: it lands, and the reader is in it without asking again.
    _ = try main.plazaIngestVerifiedForTest(arena, first, signer);
    main.refreshAddressFetchForTest(&model);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &first.id));
    // The window stays open for a newer copy.
    try testing.expect(main.addressFetchArmedForTest());
    const depth = model.thread_stack_len;

    // A newer copy arrives while the reader is still on it. Not yet drawn, so
    // the reader could be anywhere in it, and it waits: a swap opens the new copy
    // at its title.
    _ = try main.plazaIngestVerifiedForTest(arena, second, signer);
    main.refreshAddressFetchForTest(&model);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &first.id));
    // Drawn with the title on screen: it replaces the one on screen without
    // adding a level to the back-stack.
    _ = try buildTree(arena, &model);
    main.refreshAddressFetchForTest(&model);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &second.id));
    try testing.expectEqual(depth, model.thread_stack_len);
}

test "an article nobody has says so rather than waiting forever" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "never");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    var model = main.initialModel();
    model.stage = .ready;
    main.openAddressedArticleForTest(&model, 30023, [_]u8{0x5a} ** 32, "nothing-here");

    // The whole window, still watching: a relay that answers on the last tick of
    // it is still in time.
    for (0..15) |_| main.refreshAddressFetchForTest(&model);
    try testing.expect(main.addressFetchArmedForTest());
    try testing.expectEqualStrings("Fetching that article", model.toast_text());

    // One past it, and the reader is told, and nothing is left running.
    main.refreshAddressFetchForTest(&model);
    try testing.expect(!main.addressFetchArmedForTest());
    try testing.expectEqualStrings("That article did not turn up.", model.toast_text());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
}

test "an article that arrives after you have walked away does not drag you back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x68} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "walked");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "late" }};
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "Asked for, then abandoned.");

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.openAddressedArticleForTest(&model, 30023, kp.public_key, "late");
    try testing.expect(main.addressFetchArmedForTest());

    main.update(&model, Msg{ .open_person = kp.public_key }, &fx);
    main.refreshAddressFetchForTest(&model);
    try testing.expect(!main.addressFetchArmedForTest());

    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.refreshAddressFetchForTest(&model);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expect(model.viewing_profile != null);
}

test "an naddr for a draft opens nothing and says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x69} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "draftaddr");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();

    const tags = [_]nostr.event.Tag{&[_][]const u8{ "d", "unfinished" }};
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30024, &tags, "Half a thought.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.openAddressedArticleForTest(&model, 30024, kp.public_key, "unfinished");
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqualStrings("That is an unpublished draft.", model.toast_text());
    try testing.expect(!main.addressFetchArmedForTest());
}
test "the author's write relays are the ones an address is asked of" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6c} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "outbox");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var out: [main.outboxRelaysPerAuthorForTest][96]u8 = undefined;
    var lens: [main.outboxRelaysPerAuthorForTest]u8 = undefined;
    // No list on this machine: nothing to ask, so the indexers are the next step.
    try testing.expectEqual(@as(usize, 0), main.storedWriteRelaysForTest(kp.public_key, &out, &lens));

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "r", "wss://writes.example.com", "write" },
        &[_][]const u8{ "r", "wss://reads.example.com", "read" },
        &[_][]const u8{ "r", "wss://both.example.com" },
        &[_][]const u8{ "r", "ws://cleartext.example.com", "write" },
    };
    const list = try signedKind(arena, signer, kp, 1_800_000_000, 10002, &tags, "");
    _ = try main.plazaIngestVerifiedForTest(arena, list, signer);

    const n = main.storedWriteRelaysForTest(kp.public_key, &out, &lens);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("wss://writes.example.com", out[0][0..lens[0]]);
    try testing.expectEqualStrings("wss://both.example.com", out[1][0..lens[1]]);
}

test "an address dials only relays on the public internet" {
    // The ordinary shapes a relay list or an naddr carries.
    try testing.expect(main.isPublicRelayUrl("wss://relay.example.com"));
    try testing.expect(main.isPublicRelayUrl("wss://relay.example.com/"));
    try testing.expect(main.isPublicRelayUrl("wss://relay.example.com:4443/path"));
    try testing.expect(main.isPublicRelayUrl("wss://93.184.216.34"));

    // The reader's own machine and network, in the spellings a resolver reads.
    const refused = [_][]const u8{
        "wss://127.0.0.1",
        "wss://127.0.0.1:7777",
        "wss://127.1",
        "wss://0x7f.0.0.1",
        "wss://2130706433.com.1",
        "wss://10.0.0.5",
        "wss://192.168.1.10/",
        "wss://172.16.0.1",
        "wss://169.254.169.254",
        "wss://0.0.0.0",
        "wss://[::1]",
        "wss://[fe80::1]:443",
        "wss://localhost",
        "wss://localhost:8080",
        "wss://relay.localhost",
        "wss://printer.local",
        "wss://nas.lan",
        "wss://router.home.arpa",
        "wss://svc.internal",
        "wss://expyuzz4wqqyqhjn.onion",
        "wss://user@relay.example.com",
        "ws://relay.example.com",
    };
    for (refused) |url| {
        if (main.isPublicRelayUrl(url)) {
            std.debug.print("dialled: {s}\n", .{url});
            return error.PrivateRelayAccepted;
        }
    }
}

test "the addresses due in a round go to the pool as one message" {
    const a = [_]u8{0x47} ** 32;
    const b = [_]u8{0x48} ** 32;
    const addrs = [_]main.Address{
        main.addressForTest(30023, a, "first").?,
        main.addressForTest(30023, a, "second").?,
        main.addressForTest(30023, b, "third").?,
    };
    var filters: [main.addressPoolBatchForTest + 1]nostr.filter.Filter = undefined;
    const n = main.addressPoolFiltersForTest(&addrs, &filters);
    // One filter per address, and one asking for both authors' relay lists.
    try testing.expectEqual(@as(usize, 4), n);
    for (filters[0..3], addrs) |f, addr| {
        try testing.expectEqualSlices(u8, &addr.pubkey, &f.authors.?[0]);
        try testing.expectEqualStrings(addr.ident_buf[0..addr.ident_len], f.tags.?[0].values[0]);
    }
    try testing.expectEqual(@as(usize, 2), filters[3].authors.?.len);
    try testing.expectEqual(@as(u16, 10002), filters[3].kinds.?[0]);
    // Past the batch, the rest wait for a later message.
    var many: [6]main.Address = undefined;
    for (&many, 0..) |*m, i| m.* = main.addressForTest(30023, a, &[_]u8{ 'x', @intCast('0' + i) }).?;
    try testing.expectEqual(@as(usize, main.addressPoolBatchForTest + 1), main.addressPoolFiltersForTest(&many, &filters));
}
test "a quote card's address is never evicted from under it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const pk = [_]u8{0x4a} ** 32;
    const naddr = try nostr.nip19.encodeNaddr(arena, "on-screen", pk, 30023, &.{});
    const card = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}));
    main.wantQuoteForTest(card.quote.id);

    // A feed that names hundreds of other articles afterwards.
    for (0..400) |i| {
        const other = try nostr.nip19.encodeNaddr(arena, try std.fmt.allocPrint(arena, "other-{d}", .{i}), pk, 30023, &.{});
        _ = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{other}));
    }
    // The card still knows what it names, so it can still be asked for and opened.
    try testing.expect(main.addressRegisteredForTest(card.quote.id));
}

test "a public host is told by its spelling, the same way for a relay and a picture" {
    // Each host as a relay and as a picture: the two share one host rule.
    const Case = struct { relay: []const u8, picture: []const u8 };
    const accepted = [_]Case{
        // An internationalised top-level domain has a digit in its last label,
        // and is a name all the same.
        .{ .relay = "wss://relay.example.xn--p1ai", .picture = "https://img.example.xn--p1ai/a.png" },
        .{ .relay = "wss://relay.xn--80asehdb.xn--p1ai/", .picture = "http://img.xn--80asehdb.xn--p1ai/a.png" },
        // The scheme's own port, written out, goes where no port goes.
        .{ .relay = "wss://relay.example.com:443", .picture = "https://img.example.com:443/a.png" },
        .{ .relay = "wss://relay.example.com:443/", .picture = "http://img.example.com:80/a.png" },
        // A plain public address, a zero octet included.
        .{ .relay = "wss://93.184.0.34", .picture = "https://93.184.0.34/a.png" },
    };
    for (accepted) |c| {
        if (!main.isPublicRelayUrl(c.relay) or !main.isPublicMediaUrl(c.picture)) {
            std.debug.print("\nrefused a public host: {s} / {s}\n", .{ c.relay, c.picture });
            return error.PublicHostRefused;
        }
    }
    const refused = [_]Case{
        // A last label that is a number, decimal or hex, makes it an address,
        // and only the plain four-number form is one.
        .{ .relay = "wss://127.1", .picture = "https://127.1/a.png" },
        .{ .relay = "wss://0x7f.1", .picture = "https://0x7f.1/a.png" },
        .{ .relay = "wss://93.184.216.0x22", .picture = "https://93.184.216.0x22/a.png" },
        .{ .relay = "wss://example.0x1f", .picture = "https://example.0x1f/a.png" },
        // A leading zero reads as octal to some parsers, so the address is not
        // one address everywhere.
        .{ .relay = "wss://010.0.0.1", .picture = "https://010.0.0.1/a.png" },
        .{ .relay = "wss://093.184.216.34", .picture = "https://093.184.216.34/a.png" },
        .{ .relay = "wss://93.184.216.034", .picture = "http://93.184.216.034/a.png" },
        .{ .relay = "wss://0177.0.0.1", .picture = "https://0177.0.0.1/a.png" },
        // Still the reader's own network.
        .{ .relay = "wss://192.168.1.2", .picture = "https://192.168.1.2/a.png" },
        .{ .relay = "wss://relay.local", .picture = "https://img.local/a.png" },
    };
    for (refused) |c| {
        if (main.isPublicRelayUrl(c.relay) or main.isPublicMediaUrl(c.picture)) {
            std.debug.print("\naccepted a host it should not: {s} / {s}\n", .{ c.relay, c.picture });
            return error.PrivateHostAccepted;
        }
    }
    // A picture names no port but its scheme's own.
    try testing.expect(!main.isPublicMediaUrl("https://img.example.com:80/a.png"));
    try testing.expect(!main.isPublicMediaUrl("http://img.example.com:443/a.png"));
    try testing.expect(!main.isPublicMediaUrl("https://img.example.com:8443/a.png"));
    try testing.expect(!main.isPublicMediaUrl("https://img.example.com:/a.png"));
}

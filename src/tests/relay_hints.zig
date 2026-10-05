//! Tests of relay_hints.zig. Relay hints: which relays a note was seen on, and the addresses that carry them.

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
const freshHints = harness.freshHints;
const hint_a = harness.hint_a;
const hint_b = harness.hint_b;
const hint_c = harness.hint_c;
const relayListFor = harness.relayListFor;
const signedKind = harness.signedKind;
const signedNote = harness.signedNote;

fn nodeForHints(event_id: [32]u8, pubkey: [32]u8) main.Note {
    var note = main.Note{ .created_at = 1_800_000_000 };
    note.id = 4242;
    note.event_id = event_id;
    note.pubkey = pubkey;
    return note;
}
test "a relay is only named when a stranger could dial it" {
    try testing.expect(main.isHintableRelayForTest("wss://relay.damus.io"));
    try testing.expect(main.isHintableRelayForTest("wss://relay.example.com:7777/path"));
    try testing.expect(main.isHintableRelayForTest("wss://172.32.0.1"));
    // Cleartext, and a name with no dot.
    try testing.expect(!main.isHintableRelayForTest("ws://relay.damus.io"));
    try testing.expect(!main.isHintableRelayForTest("wss://localhost"));
    // Addresses only the publisher can reach, which a published tag would leak.
    try testing.expect(!main.isHintableRelayForTest("wss://127.0.0.1"));
    try testing.expect(!main.isHintableRelayForTest("wss://127.0.0.1:7777"));
    try testing.expect(!main.isHintableRelayForTest("wss://10.0.0.5"));
    try testing.expect(!main.isHintableRelayForTest("wss://192.168.1.20"));
    try testing.expect(!main.isHintableRelayForTest("wss://172.16.4.4"));
    try testing.expect(!main.isHintableRelayForTest("wss://169.254.1.1"));
    try testing.expect(!main.isHintableRelayForTest("wss://relay.local"));
    try testing.expect(!main.isHintableRelayForTest("wss://nas.lan"));
    try testing.expect(!main.isHintableRelayForTest("wss://[::1]"));
}

test "a hint never carries a token, a hidden-network name or a disguised local address" {
    // A query or fragment on a relay address is usually an access token, and a
    // hint would copy it to every reader.
    try testing.expect(!main.isHintableRelayForTest("wss://relay.example.com/?token=s3cret"));
    try testing.expect(!main.isHintableRelayForTest("wss://relay.example.com?auth=abc"));
    try testing.expect(!main.isHintableRelayForTest("wss://relay.example.com/#key"));
    // A login in front of the host.
    try testing.expect(!main.isHintableRelayForTest("wss://me:pw@relay.example.com"));
    // Reachable only through Tor or I2P.
    try testing.expect(!main.isHintableRelayForTest("wss://abcdefghijklmnop.onion"));
    try testing.expect(!main.isHintableRelayForTest("wss://relay.i2p"));
    // A trailing dot does not carry a private name past the check.
    try testing.expect(!main.isHintableRelayForTest("wss://localhost."));
    try testing.expect(!main.isHintableRelayForTest("wss://nas.local."));
    try testing.expect(!main.isHintableRelayForTest("wss://192.168.1.20."));
    // Short and hex forms of loopback, and the ranges nobody routes to.
    try testing.expect(!main.isHintableRelayForTest("wss://127.1"));
    try testing.expect(!main.isHintableRelayForTest("wss://0x7f.0.0.1"));
    try testing.expect(!main.isHintableRelayForTest("wss://1.2.3.4.5"));
    try testing.expect(!main.isHintableRelayForTest("wss://239.1.2.3"));
    // A public address, a public name with a path, and a name with digits in it
    // all still pass.
    try testing.expect(main.isHintableRelayForTest("wss://203.0.114.7"));
    try testing.expect(main.isHintableRelayForTest("wss://filter.nostr.wine/npub1abc"));
    try testing.expect(main.isHintableRelayForTest("wss://relay2.example.com"));
}

test "the relay that delivered a note is the hint, and one the author writes to beats one they do not" {
    freshHints();
    defer freshHints();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x71} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/hints.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const note_id = [_]u8{0x31} ** 32;

    // Nothing known: no hint, which is an answer.
    try testing.expectEqual(@as(usize, 0), main.hintsForTest(note_id, kp.public_key).count);

    // Delivered by A and then B. Nothing about the author yet, so the first one
    // to deliver it leads.
    main.recordSeenOnForTest(note_id, hint_a);
    main.recordSeenOnForTest(note_id, hint_b);
    {
        const h = main.hintsForTest(note_id, kp.public_key);
        try testing.expectEqual(@as(usize, 2), h.count);
        try testing.expectEqualStrings(hint_a, h.at(0));
        try testing.expectEqualStrings(hint_b, h.at(1));
    }

    // The author says they write to B and C. B is both delivered and written to,
    // so it leads; A still follows, and C is cut by the cap of two.
    _ = try main.plazaIngestForTest(arena, try relayListFor(arena, signer, kp, &.{ hint_b, hint_c }));
    {
        const h = main.hintsForTest(note_id, kp.public_key);
        try testing.expectEqual(@as(usize, 2), h.count);
        try testing.expectEqualStrings(hint_b, h.at(0));
        try testing.expectEqualStrings(hint_a, h.at(1));
    }

    // A note nobody is known to have delivered (read off disk after a restart)
    // falls back to where its author says they write.
    {
        const h = main.hintsForTest([_]u8{0x32} ** 32, kp.public_key);
        try testing.expectEqual(@as(usize, 2), h.count);
        try testing.expectEqualStrings(hint_b, h.at(0));
        try testing.expectEqualStrings(hint_c, h.at(1));
    }
    // And with no author to ask, the same note has nothing to say.
    try testing.expectEqual(@as(usize, 0), main.hintsForTest([_]u8{0x32} ** 32, null).count);
}

test "a relay nobody else can reach is never remembered as a hint" {
    freshHints();
    defer freshHints();
    const note_id = [_]u8{0x33} ** 32;
    main.recordSeenOnForTest(note_id, "wss://127.0.0.1:7777");
    main.recordSeenOnForTest(note_id, "ws://relay.alpha.example");
    main.recordSeenOnForTest(note_id, "wss://192.168.0.9");
    main.recordSeenOnForTest(note_id, "wss://relay.paid.example/?token=s3cret");
    main.recordSeenOnForTest(note_id, "wss://abcdefghijklmnop.onion");
    try testing.expectEqual(@as(usize, 0), main.hintsForTest(note_id, null).count);
    try testing.expectEqual(@as(usize, 0), main.seenUrlCountForTest());
    main.recordSeenOnForTest(note_id, hint_a ++ "/");
    // Without the trailing slash, which is how a relay is written into a tag.
    try testing.expectEqualStrings(hint_a, main.hintsForTest(note_id, null).at(0));
}

test "a note that collides with another's slot never borrows its relay" {
    freshHints();
    defer freshHints();
    // Same low bits, so the same slot, and different ids.
    var first = [_]u8{0} ** 32;
    first[0] = 0x44;
    first[7] = 0x05;
    var second = first;
    second[0] = 0x45;
    main.recordSeenOnForTest(first, hint_a);
    main.recordSeenOnForTest(second, hint_b);
    try testing.expectEqualStrings(hint_b, main.hintsForTest(second, null).at(0));
    try testing.expectEqual(@as(usize, 0), main.hintsForTest(first, null).count);
}

test "the funnel records the relay that delivered an event, and only a verified one" {
    freshHints();
    defer freshHints();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x72} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/funnel.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const note = try signedNote(arena, signer, kp, 1_800_000_000, "carried by two relays");
    _ = try main.plazaIngestFromForTest(arena, note, signer, hint_a);
    _ = try main.plazaIngestFromForTest(arena, note, signer, hint_b);
    const h = main.hintsForTest(note.id, null);
    try testing.expectEqual(@as(usize, 2), h.count);
    try testing.expectEqualStrings(hint_a, h.at(0));
    try testing.expectEqualStrings(hint_b, h.at(1));

    // A forged event proves nothing about where anything lives.
    var forged = try signedNote(arena, signer, kp, 1_800_000_001, "not what it claims");
    forged.sig = [_]u8{0x11} ** 64;
    _ = try main.plazaIngestFromForTest(arena, forged, signer, hint_c);
    try testing.expectEqual(@as(usize, 0), main.hintsForTest(forged.id, null).count);

    // Reactions are most of what a relay sends and nobody hints at one.
    const before = main.seenUrlCountForTest();
    const like = try signedKind(arena, signer, kp, 1_800_000_002, 7, &.{}, "+");
    _ = try main.plazaIngestFromForTest(arena, like, signer, "wss://relay.delta.example");
    try testing.expectEqual(before, main.seenUrlCountForTest());
    try testing.expectEqual(@as(usize, 0), main.hintsForTest(like.id, null).count);
}
test "a copied note address names where the note can be found" {
    freshHints();
    defer freshHints();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const event_id = [_]u8{0x51} ** 32;
    const pubkey = [_]u8{0x52} ** 32;
    const note = nodeForHints(event_id, pubkey);
    var buf: [main.note_address_cap_for_test]u8 = undefined;

    // Nothing known: the bare address it always was.
    {
        const addr = main.noteAddressForTest(&buf, &note, 2) orelse return error.NoAddress;
        const ptr = try nostr.nip19.decodeNevent(arena, addr);
        try testing.expectEqual(@as(usize, 0), ptr.relays.len);
        try testing.expectEqualSlices(u8, &event_id, &ptr.id);
    }

    main.recordSeenOnForTest(event_id, hint_a);
    main.recordSeenOnForTest(event_id, hint_b);
    main.recordSeenOnForTest(event_id, hint_c);
    {
        const addr = main.noteAddressForTest(&buf, &note, 2) orelse return error.NoAddress;
        const ptr = try nostr.nip19.decodeNevent(arena, addr);
        try testing.expectEqual(@as(usize, 2), ptr.relays.len);
        try testing.expectEqualStrings(hint_a, ptr.relays[0]);
        try testing.expectEqualStrings(hint_b, ptr.relays[1]);
        // The rest of the pointer is untouched.
        try testing.expectEqualSlices(u8, &event_id, &ptr.id);
        try testing.expectEqualSlices(u8, &pubkey, &(ptr.author orelse return error.NoAuthor));
        try testing.expectEqual(@as(?u32, 1), ptr.kind);
    }
    // The quote draft keeps its address short.
    {
        const addr = main.noteAddressForTest(&buf, &note, 1) orelse return error.NoAddress;
        const ptr = try nostr.nip19.decodeNevent(arena, addr);
        try testing.expectEqual(@as(usize, 1), ptr.relays.len);
    }
}

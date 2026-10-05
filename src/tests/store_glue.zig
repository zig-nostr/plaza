//! Tests of store_glue.zig. The way into the local store, and the backups of the reader's own replaceable lists.

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

test "a forged event cannot rotate the backup ring" {
    // The backup used to be written on the way IN, before the signature was
    // checked inside `ingest`. So three forged events carrying the reader's own
    // pubkey and a future stamp would push three copies of the current version
    // into a three-slot ring and destroy the real history, from across the
    // network, for the cost of three frames. The copy is kept only when the
    // store says it actually REPLACED something, which happens after verifying.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{88} ** 32);
    main.setIdentityForTest([_]u8{88} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/forged.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Two real versions, so the ring holds something worth destroying.
    const v0_tags = [_]nostr.event.Tag{&.{ "r", "wss://real-one.example.com" }};
    const v0 = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &v0_tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, v0, signer);
    const v1_tags = [_]nostr.event.Tag{&.{ "r", "wss://real-two.example.com" }};
    const v1 = try nostr.event.create(arena, signer, kp, 1_800_000_100, 10002, &v1_tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, v1, signer);
    {
        const before = main.ownListBackups(testing.allocator, 10002).?;
        defer testing.allocator.free(before);
        try testing.expect(std.mem.indexOf(u8, before, "real-one") != null);
    }

    // Now the attack: our pubkey, a future stamp, and a signature of nothing.
    var i: i64 = 1;
    while (i <= 3) : (i += 1) {
        const bad_tags = [_]nostr.event.Tag{&.{ "r", "wss://forged.example.com" }};
        const forged = nostr.event.Event{
            .id = [_]u8{@intCast(i)} ** 32,
            .pubkey = kp.public_key,
            .created_at = 1_800_000_100 + i,
            .kind = 10002,
            .tags = &bad_tags,
            .content = "",
            .sig = [_]u8{0} ** 64,
        };
        const result = try main.plazaIngestVerifiedForTest(arena, forged, signer);
        // Rejected, as it always was.
        try testing.expectEqual(nostr.store.IngestResult.invalid, result);
    }

    // And the real history is untouched: no forged copy, and the version the
    // reader would actually want back is still there.
    const after = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "forged.example.com") == null);
    try testing.expect(std.mem.indexOf(u8, after, "real-one.example.com") != null);
}
test "pressing a hashtag opens what this machine already holds for it" {
    // The point of the topic view is that it is a LOCAL query. The store
    // indexes tags, so the notes are on screen before any relay is asked, and
    // this test never opens a socket.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{44} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/topic.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Two tagged, one not. `contentTags` lowercases on the way out, so the
    // stored tag is lowercase and the lookup has to be too.
    const zig_tag = [_]nostr.event.Tag{&.{ "t", "zig" }};
    const other_tag = [_]nostr.event.Tag{&.{ "t", "bitcoin" }};
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_001, 1, &zig_tag, "comptime is nice", null));
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_002, 1, &zig_tag, "allocators too", null));
    _ = try main.plazaIngestForTest(arena, try nostr.event.create(arena, signer, kp, 1_800_000_003, 1, &other_tag, "unrelated", null));

    var model = main.initialModel();
    model.stage = .ready;
    main.openTopicForTest(&model, "zig");

    try testing.expectEqualStrings("zig", model.viewingTopic() orelse return error.NoTopic);
    try testing.expect(model.levelOpen());
    // Both tagged notes, and not the third.
    try testing.expectEqual(@as(usize, 2), model.thread_notes_len);
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (std.mem.indexOf(u8, note.content(), "unrelated") != null) return error.WrongNotesInTopic;
    }

    // Back leaves it, and lands on the feed rather than on a half-open level.
    main.closeThreadForTest(&model);
    try testing.expectEqual(@as(?[]const u8, null), model.viewingTopic());
    try testing.expect(!model.levelOpen());
}

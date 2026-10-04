//! Tests of engagement.zig. Counts under a note, the reader's own likes, and zap amounts.

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
const signedNote = harness.signedNote;
const threadNote = harness.threadNote;

test "a guest like is remembered and routed to the join, never published" {
    main.resetLikesForTest();
    main.clearIdentityForTest();
    defer main.resetLikesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{31} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "hi");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    // A guest press cannot sign: the like is remembered and the join opens, but
    // the heart does not fill (nothing was published).
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .like = id }, &fx);
    try testing.expectEqual(id, model.pending.like);
    try testing.expect(model.joining);
    try testing.expect(!main.isLikedForTest(id));
}

test "a signed-in like fills the heart, and pressing again clears it" {
    main.resetLikesForTest();
    main.setIdentityForTest([_]u8{5} ** 32);
    defer {
        main.resetLikesForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{9} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "like me");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    // Optimistic: the heart fills on the first press without waiting on publish,
    // and a second press toggles it back off (the un-like path).
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .like = id }, &fx);
    try testing.expect(main.isLikedForTest(id));
    main.update(&model, Msg{ .like = id }, &fx);
    try testing.expect(!main.isLikedForTest(id));
}

// Builds a bare engagement event of `kind` e-tagging `target_hex`, with a
// distinct id per `nonce` so the dedup set treats each as its own.
fn engagementEvent(nonce: u8, kind: u16, content: []const u8, tags_extra: []const nostr.event.Tag) nostr.event.Event {
    var id = [_]u8{0} ** 32;
    // The dedup key is the id's first 8 bytes, so vary those per event.
    id[0] = nonce;
    id[1] = 0xEE;
    return .{
        .id = id,
        .pubkey = [_]u8{nonce} ** 32,
        .created_at = 1_800_000_000,
        .kind = kind,
        .tags = tags_extra,
        .content = content,
        .sig = [_]u8{0} ** 64,
    };
}

test "engagement folds replies, reposts, and plus-likes, and skips the rest" {
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    // A target note: its i64 key (as noteIdOf derives) and its hex e-tag.
    var target_id = [_]u8{0} ** 32;
    target_id[0] = 0x12;
    target_id[1] = 0xAB;
    target_id[7] = 0x34;
    const target_i64: i64 = @intCast(std.mem.readInt(u64, target_id[0..8], .big) & std.math.maxInt(i64));
    const target_hex = std.fmt.bytesToHex(target_id, .lower);
    const e_tag = [_][]const u8{ "e", &target_hex };
    const tags = [_]nostr.event.Tag{&e_tag};
    const feed = [_]i64{target_i64};

    main.countEngagementForTest(engagementEvent(1, 1, "a reply", &tags), &feed);
    main.countEngagementForTest(engagementEvent(2, 6, "", &tags), &feed);
    main.countEngagementForTest(engagementEvent(3, 7, "+", &tags), &feed);
    main.countEngagementForTest(engagementEvent(4, 7, "", &tags), &feed); // empty counts as like
    main.countEngagementForTest(engagementEvent(5, 7, "-", &tags), &feed); // dislike: skip
    main.countEngagementForTest(engagementEvent(6, 7, "🔥", &tags), &feed); // emoji: skip

    const c = main.engagementFor(target_i64);
    try testing.expectEqual(@as(u32, 1), c.replies);
    try testing.expectEqual(@as(u32, 1), c.reposts);
    try testing.expectEqual(@as(u32, 2), c.likes);
}

test "engagement dedupes the same event and ignores unfollowed notes" {
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    var target_id = [_]u8{0} ** 32;
    target_id[0] = 0x77;
    const target_i64: i64 = @intCast(std.mem.readInt(u64, target_id[0..8], .big) & std.math.maxInt(i64));
    const target_hex = std.fmt.bytesToHex(target_id, .lower);
    const e_tag = [_][]const u8{ "e", &target_hex };
    const tags = [_]nostr.event.Tag{&e_tag};
    const feed = [_]i64{target_i64};

    const like = engagementEvent(9, 7, "+", &tags);
    main.countEngagementForTest(like, &feed);
    main.countEngagementForTest(like, &feed); // same id again (a second relay): no double count
    try testing.expectEqual(@as(u32, 1), main.engagementFor(target_i64).likes);

    // An event e-tagging a note not in the feed set is not counted at all.
    const empty_feed = [_]i64{};
    main.countEngagementForTest(engagementEvent(10, 7, "+", &tags), &empty_feed);
    try testing.expectEqual(@as(u32, 1), main.engagementFor(target_i64).likes);
}

test "engagement counts one event against its single target, not every e-tag" {
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    // A thread: root R and its reply P, both loaded.
    var root_id = [_]u8{0} ** 32;
    root_id[0] = 0xC0;
    var parent_id = [_]u8{0} ** 32;
    parent_id[0] = 0x1B;
    const root_i64: i64 = @intCast(std.mem.readInt(u64, root_id[0..8], .big) & std.math.maxInt(i64));
    const parent_i64: i64 = @intCast(std.mem.readInt(u64, parent_id[0..8], .big) & std.math.maxInt(i64));
    const root_hex = std.fmt.bytesToHex(root_id, .lower);
    const parent_hex = std.fmt.bytesToHex(parent_id, .lower);
    const feed = [_]i64{ root_i64, parent_i64 };

    // A NIP-10 reply to P carrying [e, R, "", "root"] and [e, P, "", "reply"].
    const root_tag = [_][]const u8{ "e", &root_hex, "", "root" };
    const reply_tag = [_][]const u8{ "e", &parent_hex, "", "reply" };
    const tags = [_]nostr.event.Tag{ &root_tag, &reply_tag };
    main.countEngagementForTest(engagementEvent(20, 1, "a threaded reply", &tags), &feed);

    // Only the direct parent P is credited; the root R is not inflated.
    try testing.expectEqual(@as(u32, 1), main.engagementFor(parent_i64).replies);
    try testing.expectEqual(@as(u32, 0), main.engagementFor(root_i64).replies);

    // An event that lists the same target id in two e-tags counts it once.
    const dup_a = [_][]const u8{ "e", &parent_hex };
    const dup_b = [_][]const u8{ "e", &parent_hex };
    const dup_tags = [_]nostr.event.Tag{ &dup_a, &dup_b };
    main.countEngagementForTest(engagementEvent(21, 7, "+", &dup_tags), &feed);
    try testing.expectEqual(@as(u32, 1), main.engagementFor(parent_i64).likes);
}

/// A zap receipt whose `description` carries a real, signed kind:9734 asking
/// about `target_hex`. Anything less is not a zap the counting path will take.
fn zapReceipt(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    target_hex: []const u8,
    invoice: []const u8,
    amount_msat: ?[]const u8,
) !nostr.event.Event {
    // Every slice here is arena-allocated on purpose: `create` borrows the tag
    // slice rather than copying it, so a local array would dangle the moment
    // this function returned.
    const req_e = try arena.dupe([]const u8, &.{ "e", target_hex });
    var req_tags = try arena.alloc(nostr.event.Tag, if (amount_msat != null) @as(usize, 2) else 1);
    req_tags[0] = req_e;
    if (amount_msat) |a| req_tags[1] = try arena.dupe([]const u8, &.{ "amount", a });
    const req = try nostr.event.create(arena, signer, kp, 1_800_000_000, 9734, req_tags, "", null);
    const req_json = try nostr.event.toJson(arena, req);

    var tags = try arena.alloc(nostr.event.Tag, 3);
    tags[0] = try arena.dupe([]const u8, &.{ "e", target_hex });
    tags[1] = try arena.dupe([]const u8, &.{ "bolt11", invoice });
    tags[2] = try arena.dupe([]const u8, &.{ "description", req_json });
    return nostr.event.create(arena, signer, kp, 1_800_000_001, 9735, tags, "", null);
}

test "a zap counts only when a signed request backs it, for this note" {
    // The counting path used to add the receipt's own bolt11 string with
    // nothing checked, and a kind:9735 is an ordinary public event. So any note
    // could be given any total by publishing a receipt with a big invoice in it
    // and no payment behind it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x42} ** 32);

    var target_id = [_]u8{0} ** 32;
    target_id[0] = 0x5A;
    const target_i64: i64 = @intCast(std.mem.readInt(u64, target_id[0..8], .big) & std.math.maxInt(i64));
    const target_hex = std.fmt.bytesToHex(target_id, .lower);
    const feed = [_]i64{target_i64};

    // A real one: signed request, about this note, 21 sats.
    {
        main.resetEngagementForTest();
        defer main.resetEngagementForTest();
        const receipt = try zapReceipt(arena, signer, kp, &target_hex, "lnbc210n1pjxxxxx", "21000");
        main.countEngagementForTest(receipt, &feed);
        try testing.expectEqual(@as(u64, 21_000), main.engagementFor(target_i64).zap_msat);
    }

    // A bare invoice with no request behind it: the forgery, now worth nothing.
    {
        main.resetEngagementForTest();
        defer main.resetEngagementForTest();
        const e_tag = [_][]const u8{ "e", &target_hex };
        const bolt11 = [_][]const u8{ "bolt11", "lnbc10m1pxxx" }; // a million sats
        const tags = [_]nostr.event.Tag{ &e_tag, &bolt11 };
        main.countEngagementForTest(engagementEvent(11, 9735, "", &tags), &feed);
        try testing.expectEqual(@as(u64, 0), main.engagementFor(target_i64).zap_msat);
    }

    // A genuine receipt for a DIFFERENT note, replayed onto this one.
    {
        main.resetEngagementForTest();
        defer main.resetEngagementForTest();
        var other = [_]u8{0} ** 32;
        other[0] = 0x77;
        const other_hex = std.fmt.bytesToHex(other, .lower);
        // Request names the other note; the receipt's own e tag names this one.
        const receipt = try zapReceipt(arena, signer, kp, &other_hex, "lnbc210n1pjxxxxx", "21000");
        var tags = try arena.alloc(nostr.event.Tag, receipt.tags.len);
        for (receipt.tags, 0..) |t, i| tags[i] = t;
        tags[0] = try arena.dupe([]const u8, &.{ "e", &target_hex });
        var moved = receipt;
        moved.tags = tags;
        main.countEngagementForTest(moved, &feed);
        try testing.expectEqual(@as(u64, 0), main.engagementFor(target_i64).zap_msat);
    }

    // Request and invoice disagreeing: the smaller wins, so neither number
    // alone can inflate the total.
    {
        main.resetEngagementForTest();
        defer main.resetEngagementForTest();
        const receipt = try zapReceipt(arena, signer, kp, &target_hex, "lnbc10m1pxxx", "21000");
        main.countEngagementForTest(receipt, &feed);
        try testing.expectEqual(@as(u64, 21_000), main.engagementFor(target_i64).zap_msat);
    }

    // And a real request for an absurd amount is still clamped.
    {
        main.resetEngagementForTest();
        defer main.resetEngagementForTest();
        const receipt = try zapReceipt(arena, signer, kp, &target_hex, "lnbc51pxxx", "500000000000");
        main.countEngagementForTest(receipt, &feed);
        try testing.expectEqual(main.zap_msat_ceiling_for_test, main.engagementFor(target_i64).zap_msat);
    }
}

test "bolt11 amounts parse across multipliers" {
    try testing.expectEqual(@as(u64, 21_000), main.bolt11Msat("lnbc210n1pjxxx")); // 210 nano-BTC
    try testing.expectEqual(@as(u64, 250_000_000), main.bolt11Msat("lnbc2500u1pxxx")); // 2500 micro-BTC
    try testing.expectEqual(@as(u64, 1_000_000_000), main.bolt11Msat("lnbc10m1pxxx")); // 10 milli-BTC
    try testing.expectEqual(@as(u64, 500_000_000_000), main.bolt11Msat("lnbc51pxxx")); // 5 whole BTC, no multiplier
    try testing.expectEqual(@as(u64, 0), main.bolt11Msat("lnbc1pxxx")); // the "1" is the separator: amountless
    try testing.expectEqual(@as(u64, 0), main.bolt11Msat("lntb1pxxx")); // amountless testnet
    try testing.expectEqual(@as(u64, 0), main.bolt11Msat("not an invoice"));
}
test "a heart filled by one account is not the next account's to un-like" {
    // The like table was keyed by note id alone, which is identical under every
    // account, and nothing ever cleared it. So a note liked as A showed a filled
    // red heart to B, signed in on the same machine, who had never touched it,
    // and B's first press took the UN-like branch: a kind:5 signed under B's key
    // naming A's reaction. That is a permanent public link between two
    // identities the reader was keeping apart, it destroys the app's only record
    // of A's reaction, and B's intended like never publishes at all.
    main.resetLikesForTest();
    defer main.resetLikesForTest();
    defer main.clearIdentityForTest();
    const note: i64 = 0x5EED;
    const a_reaction = [_]u8{0x71} ** 32;

    main.setIdentityForTest([_]u8{0xa1} ** 32);
    main.rememberLikeForTest(note, a_reaction);
    try testing.expect(main.isLikedForTest(note));

    // B signs in. The starter pack is shown to every account, so the same note
    // being on screen under both is routine, not a stunt.
    main.setIdentityForTest([_]u8{0xb2} ** 32);
    try testing.expect(!main.isLikedForTest(note));

    // B's own like is B's, and A still has theirs.
    main.rememberLikeForTest(note, [_]u8{0xb7} ** 32);
    try testing.expect(main.isLikedForTest(note));
    main.setIdentityForTest([_]u8{0xa1} ** 32);
    try testing.expect(main.isLikedForTest(note));
    try testing.expectEqual(a_reaction, main.likeReactionIdForTest(note).?);

    // And a guest has no likes at all.
    main.clearIdentityForTest();
    try testing.expect(!main.isLikedForTest(note));
}
test "a zap total no invoice could hold does not take the screen down with it" {
    // A zap total is a saturating u64, and the action bar narrowed it into a u32
    // to draw it: an abort in a safety build, a silently wrong number in the
    // shipped one. Receipts are validated and clamped on the way in now, so a
    // single one can no longer produce a total like this; totals accumulate,
    // though, and the arithmetic saturates, so the render still has to survive
    // whatever it is handed. That is what this checks, so it sets the total
    // directly rather than pretending a forged receipt could still do it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.event_id = [_]u8{0xAA} ** 32;
    // The engagement table is keyed by the id DERIVED from the e tag, so the note
    // has to carry that same key or the count lands nowhere.
    model.thread_root.id = @intCast(std.mem.readInt(u64, model.thread_root.event_id[0..8], .big) & std.math.maxInt(i64));
    model.viewing_thread = model.thread_root.id;

    var e_hex: [64]u8 = undefined;
    for (model.thread_root.event_id, 0..) |b, i| _ = std.fmt.bufPrint(e_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    main.setZapMsatForTest(model.thread_root.id, std.math.maxInt(u64));
    // Well past what a u32 of sats can hold.
    try testing.expect(main.engagementFor(model.thread_root.id).zap_msat / 1000 > std.math.maxInt(u32));

    // The screen still builds. Before, this line aborted the process.
    const tree = try buildTree(arena, &model);
    try testing.expect(tree.root.children.len > 0);
}
test "the verbs under a note line up down the whole feed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The row used to be four controls with a gap between them and a count
    // beside each glyph, so every count pushed everything after it along: the
    // heart landed at a different x on every note and a column of rows could not
    // agree where anything went. Each verb has a fixed slot now.
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;

    // Five notes, each with a different number of replies, so the count beside
    // the FIRST verb is a different width on every row. That is the shape that
    // moved everything after it.
    var feed: [5]i64 = undefined;
    for (0..5) |i| {
        var target = [_]u8{0} ** 32;
        target[0] = @intCast(0x40 + i);
        target[7] = 0x11;
        model.notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.notes[i].event_id = target;
        model.notes[i].id = @intCast(std.mem.readInt(u64, target[0..8], .big) & std.math.maxInt(i64));
        feed[i] = model.notes[i].id;
    }
    model.notes_len = 5;
    for (0..5) |i| {
        const hex = std.fmt.bytesToHex(model.notes[i].event_id, .lower);
        const e_tag = [_][]const u8{ "e", &hex };
        const tags = [_]nostr.event.Tag{&e_tag};
        // Row i gets 10^i replies: 1, 10, 100, 1000, 10000, so the count beside
        // the reply glyph is one, two, three, four and five characters wide.
        var made: usize = 0;
        const want = std.math.pow(usize, 10, i);
        while (made < want and made < 250) : (made += 1) {
            main.countEngagementForTest(engagementEvent(@intCast(made % 250), 1, "r", &tags), &feed);
        }
    }

    const p = try painted.Painted.render(arena, &model);
    for ([_][]const u8{ "Reply", "Like" }) |verb| {
        const frames = p.framesOf(verb);
        if (frames.len < 3) {
            std.debug.print("only {d} \"{s}\" controls on screen\n", .{ frames.len, verb });
            return error.NotEnoughRows;
        }
        for (frames[1..]) |f| {
            if (@abs(f.x - frames[0].x) > 0.5) {
                std.debug.print(
                    "\"{s}\" sits at x={d:.1} on one row and x={d:.1} on another\n",
                    .{ verb, frames[0].x, f.x },
                );
                return error.VerbsWobble;
            }
        }
    }
}
test "reposting fills the icon at once but leaves the count to the crowd" {
    main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x45} ** 32);
    defer {
        main.resetEngagementForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x47} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "pass it on");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    try testing.expect(!main.engagementFor(id).reposted_by_me);

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .repost = id }, &fx);

    try testing.expect(main.engagementFor(id).reposted_by_me);
    // NOT the count. Our own kind:6 arrives through the same subscription as
    // everybody else's and is counted there; adding one here would show two.
    try testing.expectEqual(@as(u32, 0), main.engagementFor(id).reposts);
}

test "a guest reaching for repost is remembered rather than dropped" {
    main.resetEngagementForTest();
    defer main.resetEngagementForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x49} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "hello");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .repost = id }, &fx);
    try testing.expectEqual(id, model.pending.repost);
    try testing.expect(model.joining);
    // Nothing published, so nothing claims to have been reposted.
    try testing.expect(!main.engagementFor(id).reposted_by_me);
}

test "reposting twice is one repost" {
    main.resetEngagementForTest();
    main.setIdentityForTest([_]u8{0x4B} ** 32);
    defer {
        main.resetEngagementForTest();
        main.clearIdentityForTest();
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4D} ** 32);
    const ev = try signedNote(arena_state.allocator(), signer, kp, 1_800_000_000, "once");

    var model = main.initialModel();
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .repost = id }, &fx);
    main.clearLastPublishedTagsForTest();
    // The second press publishes nothing. There is no un-repost (Jumble simply
    // disables the button, NDK offers none), so a second press must not send a
    // duplicate either.
    main.update(&model, Msg{ .repost = id }, &fx);
    try testing.expectEqual(@as(usize, 0), main.lastPublishedTagsForTest().len);
    try testing.expect(main.engagementFor(id).reposted_by_me);
}
test "every other write nobody signed is put back too" {
    // The five that shipped with the undo but without a test for it. Arming is
    // not what these check: `signAndPublish` takes the record as an argument,
    // so a write cannot reach the signer without stating one. What these check
    // is that each record puts the RIGHT thing back, which is the half a
    // compiler cannot enforce.
    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();
    main.resetLikesForTest();
    main.resetEngagementForTest();
    defer {
        main.resetLikesForTest();
        main.resetEngagementForTest();
    }

    const note_id: i64 = 909;

    // A like that was never signed leaves no phantom heart behind.
    main.rememberLikeForTest(note_id, [_]u8{0x31} ** 32);
    try testing.expect(main.isLikedForTest(note_id));
    {
        var model = main.initialModel();
        main.armUndoForTest(.{ .like = note_id });
        main.applyUndoForTest(&model);
        try testing.expect(!main.isLikedForTest(note_id));
        try testing.expect(model.toast_text().len > 0);
    }

    // A repost that was never signed does not leave the button dead. It used to
    // set a flag written only ever `true` and not cleared on logout, so the
    // press stayed spent for the process AND for the next account.
    {
        var model = main.initialModel();
        main.markRepostedByMeForTest(note_id);
        try testing.expect(main.repostedByMeForTest(note_id));
        main.armUndoForTest(.{ .repost = note_id });
        main.applyUndoForTest(&model);
        try testing.expect(!main.repostedByMeForTest(note_id));
    }

    // A reply that was never signed gives the typed text back, into the thread
    // it answers.
    {
        var model = main.initialModel();
        model.thread_root = main.Note{ .id = 31, .created_at = 1_800_000_000 };
        model.thread_root.event_id = [_]u8{0x31} ** 32;
        model.viewing_thread = 31;
        const kept = try std.heap.page_allocator.dupe(u8, "the answer I actually typed");
        main.armUndoForTest(.{ .reply = .{ .text = kept, .root = model.thread_root.event_id } });
        main.applyUndoForTest(&model);
        try testing.expectEqualStrings("the answer I actually typed", model.reply_draft());
    }

    // And a relay list that was never signed puts its stamp back, which is the
    // half that outlives the press: it is written to disk, so leaving it forward
    // keeps the reader's real list out across restarts.
    {
        var model = main.initialModel();
        main.setRelayListStampForTest(9_000);
        main.armUndoForTest(.{ .relay_list = 1_234 });
        main.applyUndoForTest(&model);
        try testing.expectEqual(@as(i64, 1_234), main.relayListStampForTest());
    }
}

test "an un-like nobody signed keeps the reaction it was going to delete" {
    // `unlike` drops the reaction id BEFORE signing, so a refusal used to empty
    // the heart while the kind:7 stayed on every relay, and the next press took
    // the `like` branch and published a SECOND reaction.
    main.setIdentityForTest([_]u8{0x61} ** 32);
    defer main.clearIdentityForTest();
    main.resetLikesForTest();
    defer main.resetLikesForTest();

    const note_id: i64 = 4242;
    const reaction_id = [_]u8{0x77} ** 32;
    main.rememberLikeForTest(note_id, reaction_id);
    try testing.expect(main.isLikedForTest(note_id));

    main.armUnlikeUndoForTest(note_id, reaction_id);
    var model = main.initialModel();
    main.applyUndoForTest(&model);

    // The id is back, so the next press deletes the reaction instead of adding
    // a second one.
    try testing.expect(main.isLikedForTest(note_id));
    try testing.expect(model.toast_text().len > 0);
}

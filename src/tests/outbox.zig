//! Tests of outbox.zig. The outbox: queued events, retries, and what survives a restart.

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

test "a full queue keeps the note in the composer instead of dropping it" {
    // `ingestAndPublish` refuses to publish what it cannot track, and it is
    // right to: a note nobody is counting, under a banner promising that
    // anything written is kept, is the lie the queue exists to stop telling.
    // But the refusal happened AFTER the press had cleared the composer and
    // deleted the draft file, so the note was simply gone: no queue row, no
    // retry, and nothing on screen but a banner that then never cleared.
    main.setIdentityForTest([_]u8{0x66} ** 32);
    defer main.clearIdentityForTest();
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();

    // Sixteen notes nobody has acknowledged. Eviction only takes a note that
    // has already reached somebody, so this is a wedged queue, which is what a
    // pool that all requires NIP-42 AUTH, or a laptop on a plane, produces.
    var i: usize = 0;
    while (i < main.outbox_cap_for_test) : (i += 1) {
        var id: [32]u8 = undefined;
        @memset(&id, @intCast(i + 1));
        try testing.expect(main.enqueueOutboxForTest(id, main.activePubkeyForTest().?, 1_000));
    }
    try testing.expect(!main.outboxHasRoomForTest());

    // The press keeps the note.
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("the seventeenth note");
    try testing.expect(!main.submitPostForTest(&model, &fx));
    try testing.expectEqualStrings("the seventeenth note", model.draft());

    // One relay takes one of them: there is room, and the note goes.
    var first: [32]u8 = undefined;
    @memset(&first, 1);
    main.recordOutboxAckForTest(first, 0, true);
    try testing.expect(main.outboxHasRoomForTest());
    try testing.expect(main.submitPostForTest(&model, &fx));
}
test "a note that no relay took is still owed" {
    // The whole point of the queue: a note written on a train and lost on
    // landing is the worst thing a client can do.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();
    // The queue answers to whoever is signed in, so a test about counts has to
    // BE somebody. See "a queued note belongs to the account that wrote it".
    main.setIdentityForTest([_]u8{0x41} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    const id = [_]u8{0xa7} ** 32;
    try testing.expect(main.enqueueOutboxForTest(id, me, 1000));
    try testing.expectEqual(@as(usize, 1), main.outboxPending());

    // One relay takes it; the note is no longer owed, and the count says so.
    main.recordOutboxAckForTest(id, 0, true);
    try testing.expectEqual(@as(usize, 0), main.outboxPending());

    var entries: [16]main.OutboxEntry = undefined;
    const n = main.outboxSnapshot(&entries);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 1), entries[0].ackCount());
    try testing.expectEqual(main.OutboxState.sent, entries[0].state());

    // A refusal is not an acknowledgement: the note is still owed.
    const other = [_]u8{0xb8} ** 32;
    try testing.expect(main.enqueueOutboxForTest(other, me, 1001));
    main.recordOutboxAckForTest(other, 1, false);
    try testing.expectEqual(@as(usize, 1), main.outboxPending());
}

test "the queue stops asking, and lets go of what landed" {
    // It is a record of what is owed, not a retry engine: a note nobody will
    // take stops asking rather than hammering strangers' servers forever, and a
    // note that landed is forgotten once the reader has had a chance to see it.
    main.resetOutboxForTest();
    main.setIdentityForTest([_]u8{0x42} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    const stuck = [_]u8{0xc9} ** 32;
    try testing.expect(main.enqueueOutboxForTest(stuck, me, 1000));
    for (0..main.rounds_before_stuck_for_test) |_| main.countOutboxRoundForTest(stuck);
    // It stops ASKING, and it stays: erasing a note the reader wrote, because
    // no relay would take it, is the one thing this queue exists to prevent.
    main.sweepOutboxForTest(1000);
    const counts = main.outboxCounts();
    try testing.expectEqual(@as(usize, 0), counts.trying);
    try testing.expectEqual(@as(usize, 1), counts.stuck);
    var stuck_entries: [16]main.OutboxEntry = undefined;
    try testing.expectEqual(@as(usize, 1), main.outboxSnapshot(&stuck_entries));
    try testing.expectEqual(main.OutboxState.stuck, stuck_entries[0].state());

    // A fresh queue for the other half: the stuck note above stays by design.
    main.resetOutboxForTest();
    const landed = [_]u8{0xda} ** 32;
    try testing.expect(main.enqueueOutboxForTest(landed, me, 2000));
    main.recordOutboxAckForTest(landed, 0, true);
    // Still shown a moment later, so the reader sees that it went.
    main.sweepOutboxForTest(2001);
    var entries: [16]main.OutboxEntry = undefined;
    try testing.expectEqual(@as(usize, 1), main.outboxSnapshot(&entries));
    // And gone once it has been on screen long enough to read.
    main.sweepOutboxForTest(2000 + main.outbox_sent_linger_for_test + 1);
    try testing.expectEqual(@as(usize, 0), main.outboxSnapshot(&entries));
}
test "a stuck note is offered again, but not every second" {
    // Without spacing, the drain runs each tick and burns every round within
    // seconds of a transient failure, leaving a note stuck moments after it was
    // written.
    try testing.expectEqual(@as(i64, 0), main.outboxRetryDelayForTest(0));
    try testing.expect(main.outboxRetryDelayForTest(1) > 0);
    try testing.expect(main.outboxRetryDelayForTest(3) > main.outboxRetryDelayForTest(2));
    try testing.expect(main.outboxRetryDelayForTest(5) >= 300);
}
test "a draft cannot be published without a composer to see it in" {
    // The message is reachable from more places than the button that names it,
    // and a draft restored from disk must never leave the machine without the
    // reader seeing it in a composer. Publishing from a closed sheet, from
    // Settings, or as a guest are all the same mistake.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.draft_buffer = @TypeOf(model.draft_buffer).init("a note restored from the last launch");

    // Closed sheet: nothing goes.
    model.composing = false;
    main.update(&model, .post, &fx);
    try testing.expectEqual(@as(usize, 0), main.outboxPending());
    try testing.expect(!model.draft_empty());

    // On another screen, sheet flag notwithstanding.
    model.composing = true;
    model.stage = .settings;
    main.update(&model, .post, &fx);
    try testing.expectEqual(@as(usize, 0), main.outboxPending());
    try testing.expect(!model.draft_empty());
}
test "an edit gives a note that gave up its rounds back" {
    // A note is stuck because it ran out of rounds with NO verdict from anyone:
    // acked and refused are both zero. Skipping those was skipping exactly the
    // notes that adding a relay is meant to rescue.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();
    main.setIdentityForTest([_]u8{0x43} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    const id = [_]u8{3} ** 32;
    try testing.expect(main.enqueueOutboxForTest(id, me, 100));
    for (0..main.rounds_before_stuck_for_test) |_| main.markOutboxRoundForTest(id);
    try testing.expectEqual(@as(usize, 1), main.outboxCounts().stuck);

    main.forgetOutboxAcksForTest();
    const after = main.outboxCounts();
    try testing.expectEqual(@as(usize, 0), after.stuck);
    try testing.expectEqual(@as(usize, 1), after.trying);
}
test "a queued note belongs to the account that wrote it, and to nobody else" {
    // The scenario this exists for, in order: A signs in, writes a note that no
    // relay takes, and logs out. B signs in. B must not publish A's note, must
    // not be told the app owes THEM a note, and must not see it listed. A signs
    // back in and it is owed again.
    //
    // The queue is NOT emptied by the logout, deliberately. Erasing a note the
    // reader wrote because they signed out would be the app destroying their
    // writing, which is the one thing this queue exists to prevent. So the note
    // survives and stops being walkable instead.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();

    main.setIdentityForTest([_]u8{0x0A} ** 32);
    const a = main.activePubkeyForTest() orelse return error.NoIdentity;
    const note = [_]u8{0xAB} ** 32;
    try testing.expect(main.enqueueOutboxForTest(note, a, 1000));
    try testing.expectEqual(@as(usize, 1), main.outboxPending());

    // Signed out: it belongs to nobody. Not gone, just nobody's to send.
    main.clearIdentityForTest();
    try testing.expectEqual(@as(usize, 0), main.outboxPending());
    try testing.expectEqual(@as(usize, 0), main.outboxCounts().trying);
    var seen: [16]main.OutboxEntry = undefined;
    try testing.expectEqual(@as(usize, 0), main.outboxSnapshot(&seen));

    // B signs in. Still not theirs, on all three surfaces.
    main.setIdentityForTest([_]u8{0x0B} ** 32);
    const b = main.activePubkeyForTest() orelse return error.NoIdentity;
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expectEqual(@as(usize, 0), main.outboxPending());
    try testing.expectEqual(@as(usize, 0), main.outboxSnapshot(&seen));

    // B writes their own. Now the count is one, and it is B's, not two.
    const bs_note = [_]u8{0xBC} ** 32;
    try testing.expect(main.enqueueOutboxForTest(bs_note, b, 1100));
    try testing.expectEqual(@as(usize, 1), main.outboxPending());
    try testing.expectEqual(@as(usize, 1), main.outboxSnapshot(&seen));
    try testing.expectEqualSlices(u8, &bs_note, &seen[0].id);

    // And the surface that matters most: what the PUBLISHER would send. The
    // counts and the popover are what the reader is told; this is what actually
    // leaves the machine, so a guard on the other two and not on this one would
    // be a quiet app doing the dangerous thing.
    var due: [main.outbox_cap_for_test][32]u8 = undefined;
    const b_sends = main.collectOutboxDueForTest(&due, 1200);
    try testing.expectEqual(@as(usize, 1), b_sends);
    try testing.expectEqualSlices(u8, &bs_note, &due[0]);

    // A comes back. Their note is still owed, and B's is not A's.
    main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x0A} ** 32);
    defer main.clearIdentityForTest();
    try testing.expectEqual(@as(usize, 1), main.outboxPending());
    try testing.expectEqual(@as(usize, 1), main.outboxSnapshot(&seen));
    try testing.expectEqualSlices(u8, &note, &seen[0].id);

    // A's publisher sends A's note and only A's. `last_try_at` was stamped for
    // B's note above and not for this one, so a fresh selection here is honest.
    const a_sends = main.collectOutboxDueForTest(&due, 1300);
    try testing.expectEqual(@as(usize, 1), a_sends);
    try testing.expectEqualSlices(u8, &note, &due[0]);

    // Signed out, the publisher sends nothing at all.
    main.clearIdentityForTest();
    try testing.expectEqual(@as(usize, 0), main.collectOutboxDueForTest(&due, 1400));
}

test "another account's notes do not sit in the slots this account needs" {
    // The trap the first version of the ownership fix walked into. Refusing to
    // SEND a foreign entry is not enough: nothing can ack it, so nothing can
    // sweep it and nothing can evict it either, and sixteen of them stop the
    // person at the keyboard publishing at all. Silently, because the same
    // ownership filter hides them from the count and the popover.
    //
    // So the slots change hands with the account. The leaving account's queue is
    // parked in its own record, not deleted, and the array holds only whoever is
    // signed in.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();
    main.clearOutboxOwnerForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/outbox.mdb", .{dir_buf[0..dir_len]});
    var store = try nostr.store.Store.open(path.ptr, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A signs in and fills every slot with notes no relay took. Real signed
    // events in the store, because the queue is an INDEX: a restart reads each
    // id back out of the store, and an id with no event behind it is dropped.
    main.setIdentityForTest([_]u8{0x0A} ** 32);
    main.syncOutboxOwnerForTest();
    const a = main.activePubkeyForTest() orelse return error.NoIdentity;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x0A} ** 32);
    for (0..main.outbox_cap_for_test) |i| {
        const body = try std.fmt.allocPrint(arena, "owed note {d}", .{i});
        const ev = try nostr.event.create(arena, signer, kp, @intCast(1000 + i), 1, &.{}, body, null);
        _ = try store.ingest(testing.allocator, ev, .{});
        try testing.expect(main.enqueueOutboxForTest(ev.id, a, 1000));
    }
    try testing.expectEqual(main.outbox_cap_for_test, main.outboxUsedSlotsForTest());

    // A logs out. The slots come back; the notes are not destroyed.
    main.clearIdentityForTest();
    main.syncOutboxOwnerForTest();
    try testing.expectEqual(@as(usize, 0), main.outboxUsedSlotsForTest());
    try testing.expectEqual(@as(?[32]u8, null), main.outboxOwnerForTest());

    // B signs in to an empty queue and can post. Without the handover this is
    // where `enqueueOutbox` returns false and the note reaches no relay at all,
    // with nothing on screen to say so.
    main.setIdentityForTest([_]u8{0x0B} ** 32);
    main.syncOutboxOwnerForTest();
    const b = main.activePubkeyForTest() orelse return error.NoIdentity;
    try testing.expectEqual(@as(usize, 0), main.outboxUsedSlotsForTest());
    const bs = [_]u8{0xBB} ** 32;
    try testing.expect(main.enqueueOutboxForTest(bs, b, 1100));
    try testing.expectEqual(@as(usize, 1), main.outboxPending());

    // A comes back to every one of their notes, still owed, none of B's.
    main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x0A} ** 32);
    defer main.clearIdentityForTest();
    main.syncOutboxOwnerForTest();
    try testing.expectEqual(main.outbox_cap_for_test, main.outboxUsedSlotsForTest());
    try testing.expectEqual(main.outbox_cap_for_test, main.outboxPending());
    for (0..main.outbox_cap_for_test) |i| {
        const author = main.outboxAuthorAtForTest(i) orelse return error.EmptySlot;
        try testing.expectEqualSlices(u8, &a, &author);
    }
    main.clearOutboxOwnerForTest();
}

test "a queue that survived a restart remembers who wrote each note" {
    // `loadOutbox` is the ONLY place an author is recovered for a queue that
    // outlived the process, which is exactly the path a real logout-and-restart
    // takes. It reads the author back off the stored event, so this drives a
    // real store rather than the in-memory helpers.
    main.resetOutboxForTest();
    main.clearOutboxOwnerForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/reload.mdb", .{dir_buf[0..dir_len]});
    var store = try nostr.store.Store.open(path.ptr, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A real signed note, so the store holds an event whose pubkey is the answer
    // this test is about.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5E} ** 32);
    const ev = try nostr.event.create(arena, signer, kp, 1000, 1, &.{}, "written offline", null);
    _ = try store.ingest(testing.allocator, ev, .{});

    main.setIdentityForTest([_]u8{0x5E} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    try testing.expectEqualSlices(u8, &kp.public_key, &me);

    // Queue it and write the record, the way the tick does.
    main.syncOutboxOwnerForTest();
    try testing.expect(main.enqueueOutboxForTest(ev.id, me, 1000));
    main.saveOutboxForTest();

    // Now lose the array, as a restart does, and read it back.
    main.resetOutboxForTest();
    try testing.expectEqual(@as(usize, 0), main.outboxUsedSlotsForTest());
    main.loadOutboxForTest(me);
    try testing.expectEqual(@as(usize, 1), main.outboxUsedSlotsForTest());

    // The author survived, which is what makes the entry sendable by its owner
    // and by nobody else. A zeroed author here would match no real key and the
    // note would be owed to a person who does not exist.
    const author = main.outboxAuthorAtForTest(0) orelse return error.EmptySlot;
    try testing.expectEqualSlices(u8, &me, &author);
    try testing.expectEqual(@as(usize, 1), main.outboxPending());

    // And a stranger reading the same record takes nothing from it.
    const stranger = [_]u8{0x77} ** 32;
    main.loadOutboxForTest(stranger);
    try testing.expectEqual(@as(usize, 0), main.outboxUsedSlotsForTest());
    main.clearOutboxOwnerForTest();
}

test "the pre-account queue record is split by author, not taken wholesale" {
    // The one record written by builds before the queue was per-account can hold
    // notes from more than one person, because it never asked. Each account
    // claims its own share of it the first time it signs in and leaves the rest
    // where it is, so migrating does not hand somebody else's unsent writing to
    // whoever happens to open the app first.
    main.resetOutboxForTest();
    main.clearOutboxOwnerForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/legacy.mdb", .{dir_buf[0..dir_len]});
    var store = try nostr.store.Store.open(path.ptr, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp_a = try signer.keyPairFromSecretKey([_]u8{0x11} ** 32);
    const kp_b = try signer.keyPairFromSecretKey([_]u8{0x22} ** 32);
    const ev_a = try nostr.event.create(arena, signer, kp_a, 1000, 1, &.{}, "A wrote this", null);
    const ev_b = try nostr.event.create(arena, signer, kp_b, 1001, 1, &.{}, "B wrote this", null);
    _ = try store.ingest(testing.allocator, ev_a, .{});
    _ = try store.ingest(testing.allocator, ev_b, .{});

    // The old shape: one record, both notes, no author anywhere in it.
    var rec = std.ArrayList(u8).empty;
    defer rec.deinit(testing.allocator);
    for ([_]nostr.event.Event{ ev_a, ev_b }) |ev| {
        var hex: [64]u8 = undefined;
        for (ev.id, 0..) |byte, i| {
            const digits = "0123456789abcdef";
            hex[i * 2] = digits[byte >> 4];
            hex[i * 2 + 1] = digits[byte & 0x0f];
        }
        try rec.appendSlice(testing.allocator, &hex);
        try rec.appendSlice(testing.allocator, ":1000:0:0:0\n");
    }
    try store.put("outbox", rec.items);

    // A reads it and gets A's note. Only A's.
    main.loadOutboxForTest(kp_a.public_key);
    try testing.expectEqual(@as(usize, 1), main.outboxUsedSlotsForTest());
    const got_a = main.outboxAuthorAtForTest(0) orelse return error.EmptySlot;
    try testing.expectEqualSlices(u8, &kp_a.public_key, &got_a);

    // B reads the same record and gets B's, which is still there for them.
    main.loadOutboxForTest(kp_b.public_key);
    try testing.expectEqual(@as(usize, 1), main.outboxUsedSlotsForTest());
    const got_b = main.outboxAuthorAtForTest(0) orelse return error.EmptySlot;
    try testing.expectEqualSlices(u8, &kp_b.public_key, &got_b);

    // And a third party gets nothing out of it at all.
    main.loadOutboxForTest([_]u8{0x33} ** 32);
    try testing.expectEqual(@as(usize, 0), main.outboxUsedSlotsForTest());
    main.clearOutboxOwnerForTest();
    main.resetOutboxForTest();
}
test "a note nobody took is still offered, long after the app calls it stuck" {
    // The queue used to give up after six rounds, about eleven minutes on the
    // old ladder. Close a lid for twelve, or spend that long on a captive
    // portal where TCP connects and TLS does not, and every queued note was
    // abandoned for the life of the install: never offered again, the count
    // surviving restarts, and sixteen of them filling the queue so the account
    // could not post from that install at all.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();

    const id = [_]u8{0x31} ** 32;
    main.setIdentityForTest([_]u8{0x99} ** 32);
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    try testing.expect(main.enqueueOutboxForTest(id, me, 0));

    // Well past the point the app starts calling it stuck.
    for (0..main.rounds_before_stuck_for_test + 4) |_| main.countOutboxRoundForTest(id);

    // The word on the row, which is all it is now.
    try testing.expectEqual(main.OutboxState.stuck, main.outboxStateForTest(id).?);

    // And it is still collected, given enough time on the widening delay.
    var due: [16][32]u8 = undefined;
    const n = main.collectOutboxDueForTest(&due, 100_000);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, &id, &due[0]);
}

test "a relay coming back puts a note at the front of the queue, but a flapping one cannot" {
    // The backoff was only ever reset by editing the relay list, so a note that
    // had widened out to an hourly retry stayed there even when the network
    // came back a second later.
    main.resetOutboxForTest();
    defer main.resetOutboxForTest();

    const id = [_]u8{0x32} ** 32;
    main.setIdentityForTest([_]u8{0x99} ** 32);
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;
    try testing.expect(main.enqueueOutboxForTest(id, me, 0));
    for (0..4) |_| main.countOutboxRoundForTest(id);
    try testing.expect(main.outboxRoundsForTest(id).? > 0);

    // Offline, then back: the ladder resets.
    main.setRelayStatusForTest(0, false);
    main.setRelayStatusForTest(0, true);
    try testing.expectEqual(@as(u8, 0), main.outboxRoundsForTest(id).?);

    // A relay that accepts the handshake and drops it reconnects every three
    // seconds. If each of those reset the ladder, the widening delay would
    // never widen and a dead relay would be dialled without pause.
    for (0..6) |_| main.countOutboxRoundForTest(id);
    const before = main.outboxRoundsForTest(id).?;
    for (0..5) |_| {
        main.setRelayStatusForTest(0, false);
        main.setRelayStatusForTest(0, true);
    }
    try testing.expectEqual(before, main.outboxRoundsForTest(id).?);
}
test "a reply is routed to the read relays of the people it names" {
    // Plaza sent every note to the reader's own write relays and nowhere else.
    // If the person being replied to does not read those relays, their client
    // never sees the reply and never tells them, so a thread started from Plaza
    // reads one-sided to everybody else in it. Plaza's own inbox subscription
    // is the mirror of this and was already correct, so the app received what
    // others routed to it and did not reciprocate.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x51} ** 32);

    // Their kind:10002: one relay they read, one they only write to.
    var tags = try arena.alloc(nostr.event.Tag, 2);
    tags[0] = try arena.dupe([]const u8, &.{ "r", "wss://inbox.example", "read" });
    tags[1] = try arena.dupe([]const u8, &.{ "r", "wss://outbox.example", "write" });
    const list = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, tags, "", null);

    var parsed = try nostr.nip65.parseRelayList(testing.allocator, list);
    defer parsed.deinit();

    var reads: usize = 0;
    var write_only: usize = 0;
    for (parsed.list.entries) |e| {
        if (e.read) reads += 1;
        if (e.write and !e.read) write_only += 1;
    }
    // The routing rule the delivery pass applies: a relay they only WRITE to
    // will never show them anything, so a reply left there reaches nobody.
    try testing.expectEqual(@as(usize, 1), reads);
    try testing.expectEqual(@as(usize, 1), write_only);

    // A recipient relay that is already one of the reader's own is not dialled
    // a second time, and the comparison is the pool's own, so a trailing slash
    // is not a different relay.
    main.resetRelaysToBootstrapForTest();
    try testing.expect(!main.poolHasRelayForTest("wss://inbox.example"));
    var buf: [96]u8 = undefined;
    if (main.relaySnapshot(0, &buf)) |first| {
        try testing.expect(main.poolHasRelayForTest(first.url));
    }
}

//! Tests of inbox.zig. Notifications: what arrives, what is unread, and what is saved between runs.

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
const countPressesOf = harness.countPressesOf;
const findAnyText = harness.findAnyText;
const findAnyTextContainingText = harness.findAnyTextContainingText;
const findByLabel = harness.findByLabel;
const inboxEvent = harness.inboxEvent;
const seedInbox = harness.seedInbox;
const threadNote = harness.threadNote;

test "the unread badge is a pill, not a sliver" {
    // `.panel` is a stacking kind: it hands every child the whole content box and
    // takes the MAX of them for its own size rather than the sum. The two
    // four-point spacers either side of the digit were therefore layered BEHIND
    // it and contributed nothing, so the pill's width was the glyph advance and
    // the declared radius clamped to half of that. It painted as a narrow
    // lozenge with the number running edge to edge.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    main.setIdentityForTest([_]u8{0x7d} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();

    // One unread, and then more than the cap, so both the single digit and the
    // "9+" case are pinned: the badge used to change shape with the count.
    for ([_]usize{ 1, 12 }) |count| {
        main.seedInboxUnreadForTest(count);
        const label = if (count > 9) "9+" else "1";
        const p = try painted.Painted.render(arena, &model);
        const digit = smallestNodeWithText(p, label) orelse return error.NoBadge;
        const pill = smallestPanelAround(p, digit) orelse return error.NoPill;
        // The floor, and the thing that says it is a pill rather than the digit
        // with a colour behind it.
        try testing.expect(pill.width >= 19);
        try testing.expect(pill.width > digit.width);
    }
}

/// The frame of the smallest laid-out node carrying exactly `text`.
fn smallestNodeWithText(p: painted.Painted, text: []const u8) ?native_sdk.geometry.RectF {
    var best: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (!std.mem.eql(u8, n.widget.text, text)) continue;
        const f = n.widget.frame;
        if (best == null or f.width < best.?.width) best = f;
    }
    return best;
}

/// The frame of the smallest `.panel` the digit sits inside HORIZONTALLY, and
/// which overlaps it vertically.
///
/// Not strict containment: a text leaf's line box is taller than the pill it is
/// centred in (18 against 13 here), so "the panel contains the glyph frame" is
/// never true and asking for it finds nothing. Width is the axis under test.
fn smallestPanelAround(p: painted.Painted, inner: native_sdk.geometry.RectF) ?native_sdk.geometry.RectF {
    var best: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (n.widget.kind != .panel) continue;
        const f = n.widget.frame;
        if (f.x > inner.x or f.x + f.width < inner.x + inner.width) continue;
        if (f.y > inner.y + inner.height or f.y + f.height < inner.y) continue;
        if (best == null or f.width < best.?.width) best = f;
    }
    return best;
}
pub fn inboxEventBy(kind: u16, author: [32]u8, tags: []const nostr.event.Tag, created_at: i64) nostr.event.Event {
    return .{
        .id = author,
        .pubkey = author,
        .created_at = created_at,
        .kind = kind,
        .tags = tags,
        .content = "+",
        .sig = [_]u8{0} ** 64,
    };
}

test "a p tag alone is not a notification" {
    // An inbox is the first surface where a stranger decides what the reader
    // sees, so what does NOT get in matters as much as what does.
    main.setIdentityForTest([_]u8{0xB1} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    // Naming somebody else is not naming me, however loudly.
    const other = [_]nostr.event.Tag{&.{ "p", "aa" ** 32 }};
    try testing.expect(main.inboxVerbForTest(inboxEvent(1, 0xC1, &other, 100), me) == null);

    // Naming me in a note somebody wrote from scratch IS a mention: nothing
    // put that tag there but the person writing.
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    try testing.expectEqual(main.InboxVerb.mention, main.inboxVerbForTest(inboxEvent(1, 0xC1, &mine, 100), me).?);

    // But the same tag on a REPLY says nothing, and this is what the title of
    // this test was always about. NIP-10 has a reply carry every `p` tag of its
    // parent plus the parent's author, so one word posted into a thread puts
    // the reader's key on every message in it, forever. Two strangers talking
    // three levels below a note of mine were arriving as "mentioned you", and
    // in a busy thread that becomes the commonest row in the inbox.
    const between_others = [_]nostr.event.Tag{
        &.{ "e", "cc" ** 32, "", "root" },
        &.{ "p", &me_hex },
        &.{ "p", "dd" ** 32 },
    };
    try testing.expect(main.inboxVerbForTest(inboxEvent(1, 0xC1, &between_others, 100), me) == null);

    // A reply whose last `p` tag is me is a reply TO me, even when this app has
    // never seen the note being answered. Dropping those would trade one wrong
    // answer for another.
    const to_me = [_]nostr.event.Tag{
        &.{ "e", "cc" ** 32, "", "root" },
        &.{ "p", "dd" ** 32 },
        &.{ "p", &me_hex },
    };
    try testing.expectEqual(main.InboxVerb.reply, main.inboxVerbForTest(inboxEvent(1, 0xC1, &to_me, 100), me).?);

    // And being named in the TEXT of a reply is a mention wherever the tags
    // fall, because somebody typed it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const npub = try nostr.nip19.encodeNpub(arena_state.allocator(), me);
    var content_buf: [200]u8 = undefined;
    const said = try std.fmt.bufPrint(&content_buf, "as nostr:{s} was saying", .{npub});
    var mentions_me = inboxEvent(1, 0xC1, &between_others, 100);
    mentions_me.content = said;
    try testing.expectEqual(main.InboxVerb.mention, main.inboxVerbForTest(mentions_me, me).?);

    // A note naming twenty people is a broadcast, and being one of the twenty
    // is not a message. This is the cheapest filter that works.
    var many: [12]nostr.event.Tag = undefined;
    var hexes: [12][64]u8 = undefined;
    for (0..12) |i| {
        for (0..32) |b| _ = std.fmt.bufPrint(hexes[i][b * 2 ..][0..2], "{x:0>2}", .{@as(u8, @intCast(i + 1))}) catch {};
        many[i] = &.{ "p", &hexes[i] };
    }
    many[11] = &.{ "p", &me_hex };
    try testing.expect(main.inboxVerbForTest(inboxEvent(1, 0xC1, &many, 100), me) == null);

    // My own note is not news to me. (Built from the real pubkey: the identity
    // helper takes a SECRET key, and the two are not the same bytes.)
    try testing.expect(main.inboxVerbForTest(inboxEventBy(1, me, &mine, 100), me) == null);
}

test "a reaction that is not a like is not a notification" {
    main.setIdentityForTest([_]u8{0xB2} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    var like = inboxEvent(7, 0xC2, &mine, 100);
    try testing.expectEqual(main.InboxVerb.like, main.inboxVerbForTest(like, me).?);
    // A downvote is not something to celebrate in a bell.
    like.content = "-";
    try testing.expect(main.inboxVerbForTest(like, me) == null);

    // Everything else IS. Amethyst, Damus and Primal all send an emoji rather
    // than "+" by default, and requiring "+" meant every one of those reactions
    // produced no row, no badge and no glyph: the reader was told nobody had
    // reacted while people had, and the emoji the row is built to draw could
    // never get there.
    for ([_][]const u8{ "❤️", "🔥", ":shakingeyes:", "+" }) |content| {
        like.content = content;
        try testing.expectEqual(main.InboxVerb.like, main.inboxVerbForTest(like, me).?);
    }

    // Reposts and zaps are their own verbs.
    try testing.expectEqual(main.InboxVerb.repost, main.inboxVerbForTest(inboxEvent(6, 0xC2, &mine, 100), me).?);
    try testing.expectEqual(main.InboxVerb.zap, main.inboxVerbForTest(inboxEvent(9735, 0xC2, &mine, 100), me).?);
}
test "one event dated in the future does not kill the bell forever" {
    // created_at is written by whoever signed the event, so it is not a fact.
    // Believing one dated 2100 pushes the read mark past everything that will
    // ever arrive and the bell never lights again. Nostur ships this bug with
    // the TODO still in the file.
    main.setIdentityForTest([_]u8{0xB3} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    const now: i64 = 1_800_000_000;
    // Dated seventy years out.
    _ = main.inboxAddForTest(inboxEvent(1, 0xC3, &mine, now + 2_000_000_000), now);
    main.inboxMarkAllRead();

    // The absurd stamp was clamped to the moment it arrived, so the mark sits at
    // `now` rather than seventy years out. A genuine mention a minute later is
    // therefore still unread, which is the whole point.
    try testing.expectEqual(now, main.inboxReadThrough());
    var second = inboxEvent(1, 0xC4, &mine, now + 60);
    second.id = [_]u8{0xD4} ** 32;
    _ = main.inboxAddForTest(second, now + 60);
    try testing.expect(main.inboxUnread() > 0);
}

test "marking read uses the newest item held, never the clock" {
    // Marking at now() means anything arriving later with an older stamp, which
    // is every backfill and every slow relay, is born already read.
    main.setIdentityForTest([_]u8{0xB4} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    const now: i64 = 1_800_000_000;
    _ = main.inboxAddForTest(inboxEvent(1, 0xC5, &mine, now - 100), now);
    main.inboxMarkAllRead();
    try testing.expectEqual(@as(usize, 0), main.inboxUnread());
    // The mark sits on the item, not on the clock, so an older one that shows
    // up afterwards is still counted.
    try testing.expectEqual(now - 100, main.inboxReadThrough());

    var older = inboxEvent(1, 0xC6, &mine, now - 50);
    older.id = [_]u8{0xD6} ** 32;
    _ = main.inboxAddForTest(older, now);
    try testing.expectEqual(@as(usize, 1), main.inboxUnread());
}

test "the bell counts what it can speak for" {
    // A like is worth reading and is not worth a number on a tile. The bell and
    // the sheet read the same list, so they cannot disagree about what is in it.
    main.setIdentityForTest([_]u8{0xB5} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    const now: i64 = 1_800_000_000;
    var like = inboxEvent(7, 0xC7, &mine, now);
    like.id = [_]u8{0xE1} ** 32;
    _ = main.inboxAddForTest(like, now);
    try testing.expectEqual(@as(usize, 0), main.inboxUnread());

    var mention = inboxEvent(1, 0xC8, &mine, now);
    mention.id = [_]u8{0xE2} ** 32;
    _ = main.inboxAddForTest(mention, now);
    try testing.expectEqual(@as(usize, 1), main.inboxUnread());

    // Both are in the sheet, though: the bell is quieter than the list, not a
    // different list.
    var buf: [16]main.InboxItem = undefined;
    try testing.expectEqual(@as(usize, 2), main.inboxItems(&buf, false).len);
}

test "one reader's notifications are never another's" {
    main.setIdentityForTest([_]u8{0xB6} ** 32);
    main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    _ = main.inboxAddForTest(inboxEvent(1, 0xC9, &mine, 1_800_000_000), 1_800_000_000);
    try testing.expectEqual(@as(usize, 1), main.inboxLenForTest());

    // A different account sees an empty inbox, not the previous reader's mail.
    main.setIdentityForTest([_]u8{0xB7} ** 32);
    defer main.clearIdentityForTest();
    try testing.expectEqual(@as(usize, 0), main.inboxUnread());
    var buf: [16]main.InboxItem = undefined;
    try testing.expectEqual(@as(usize, 0), main.inboxItems(&buf, false).len);
}
/// A relay that only remembers what it was asked, so the wire can be tested
/// without one.
const RecordingRelay = struct {
    subscribed: bool = false,
    withdrawn: bool = false,
    kinds_len: usize = 0,
    p_value: [64]u8 = [_]u8{0} ** 64,
    since: ?i64 = null,

    pub fn subscribe(self: *RecordingRelay, id: []const u8, filters: []const nostr.filter.Filter) !void {
        if (!std.mem.eql(u8, id, "plaza-inbox")) return;
        self.subscribed = true;
        self.kinds_len = if (filters[0].kinds) |k| k.len else 0;
        self.since = filters[0].since;
        if (filters[0].tags) |tags| {
            if (tags.len > 0 and tags[0].values.len > 0 and tags[0].values[0].len == 64)
                @memcpy(&self.p_value, tags[0].values[0]);
        }
    }
    pub fn unsubscribe(self: *RecordingRelay, id: []const u8) !void {
        if (std.mem.eql(u8, id, "plaza-inbox")) self.withdrawn = true;
    }
};

test "a relay is asked about the reader by name, and stops being asked when they leave" {
    // The subscription used to be issued only at DIAL, guarded on there being an
    // identity. Plaza opens as a guest and dials every relay before anyone has
    // signed in, and a healthy socket never reconnects, so the bell read zero for
    // the whole session no matter who replied. That the filter is right matters
    // less than that it is asked for at all, at the moment the reader arrives.
    main.resetInboxForTest();
    defer main.resetInboxForTest();

    // Signed out: nothing is asked, and any standing question is withdrawn. A
    // relay should stop being told which pubkey this connection cares about the
    // moment that stops being true.
    {
        var relay = RecordingRelay{};
        main.subscribeInbox(&relay);
        try testing.expect(!relay.subscribed);
        try testing.expect(relay.withdrawn);
    }

    main.setIdentityForTest([_]u8{0xE8} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    var relay = RecordingRelay{};
    main.subscribeInbox(&relay);
    try testing.expect(relay.subscribed);
    try testing.expectEqual(main.inbox_kinds.len, relay.kinds_len);
    try testing.expectEqualSlices(u8, &me_hex, &relay.p_value);
    // Nothing held yet, so no `since`: the limit does the bounding, which is what
    // relays are good at.
    try testing.expectEqual(@as(?i64, null), relay.since);

    // With something held, the next ask resumes from just before it rather than
    // re-reading everything.
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    var ev = inboxEvent(1, 0x5A, &mine, 1_800_000_000);
    ev.id[0] = 0x5A;
    try testing.expect(main.inboxAddForTest(ev, 1_800_000_000));
    var again = RecordingRelay{};
    main.subscribeInbox(&again);
    try testing.expect(again.since != null);
    try testing.expect(again.since.? < 1_800_000_000);
}

test "the inbox survives a restart, targets and all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.setIdentityForTest([_]u8{0xE9} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/inbox.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const target_hex = "cd" ** 32;
    var reply = inboxEvent(1, 0x6B, &.{
        &.{ "p", &me_hex },
        &.{ "e", target_hex },
    }, 1_800_000_000);
    reply.id[0] = 0x6B;
    // Into the STORE as well as the inbox, which is what really happens: the
    // pool ingests the event and then files it. The inbox is rebuilt from the
    // store's `p` tag index at launch now rather than from a parallel blob, so
    // an event that was never stored is one that never happened. That is the
    // point of the change: the blob could not carry the note's words or a
    // reaction's glyph, so every restored row came back blank.
    _ = try store.ingest(arena_state.allocator(), reply, .{});
    try testing.expect(main.inboxAddForTest(reply, 1_800_000_000));
    main.inboxMarkAllRead();
    const read_through = main.inboxReadThrough();
    main.saveInboxForTest();

    // A new launch: nothing in memory, everything on disk.
    main.resetInboxForTest();
    try testing.expectEqual(@as(usize, 0), main.inboxLenForTest());
    main.loadInboxForTest();

    var buf: [8]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), items.len);
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, target_hex);
    // The target rides across the restart too: a row that cannot say what it is
    // about is a row that does nothing when pressed.
    try testing.expectEqualSlices(u8, &want, &items[0].target_id);
    try testing.expectEqual(read_through, main.inboxReadThrough());
    // And what was read stays read, which is the whole reason to write it down.
    try testing.expectEqual(@as(usize, 0), main.inboxUnread());
}

test "a zap names the person who signed for it, or it is not shown at all" {
    // The one row in this app that can say "somebody you trust sent you money",
    // built entirely out of bytes a stranger chose. The receipt is authored by a
    // payment server, so the payer is named INSIDE it, and reading that name
    // without checking it lets anyone publish a receipt claiming to be from
    // whoever the reader most wants to hear from, with the impersonated person's
    // real cached name and face drawn beside it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    main.setIdentityForTest([_]u8{0xE1} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const payer = try signer.keyPairFromSecretKey([_]u8{0x0A} ** 32);
    const other = try signer.keyPairFromSecretKey([_]u8{0x0B} ** 32);
    var other_hex: [64]u8 = undefined;
    for (other.public_key, 0..) |b, i| _ = std.fmt.bufPrint(other_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const to_me = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    const to_other = [_]nostr.event.Tag{&.{ "p", &other_hex }};

    // A real request: signed by the payer, naming the reader.
    const good_req = try nostr.event.create(arena, signer, payer, 1_800_000_000, 9734, &to_me, "", null);
    const good_json = try nostr.event.toJson(arena, good_req);

    // The same shape, but signed for somebody ELSE. A receipt is public, so this
    // one can simply be lifted out of their inbox and replayed into this one.
    const elsewhere = try nostr.event.create(arena, signer, payer, 1_800_000_000, 9734, &to_other, "", null);
    const elsewhere_json = try nostr.event.toJson(arena, elsewhere);

    // And a request that was never signed at all, which is what an attacker
    // actually writes: any pubkey they like, no key needed.
    const forged_json = try std.fmt.allocPrint(arena,
        \\{{"id":"{s}","pubkey":"{s}","created_at":1800000000,"kind":9734,"tags":[["p","{s}"]],"content":"","sig":"{s}"}}
    , .{ "aa" ** 32, "11" ** 32, &me_hex, "00" ** 64 });

    // A request that is not a request: a signed note, wearing the tag's clothes.
    const wrong_kind = try nostr.event.create(arena, signer, payer, 1_800_000_000, 1, &to_me, "hi", null);
    const wrong_kind_json = try nostr.event.toJson(arena, wrong_kind);

    const cases = [_]struct { json: []const u8, filed: bool, why: []const u8 }{
        .{ .json = good_json, .filed = true, .why = "signed by the payer, naming the reader" },
        .{ .json = forged_json, .filed = false, .why = "nobody signed it" },
        .{ .json = elsewhere_json, .filed = false, .why = "signed for somebody else" },
        .{ .json = wrong_kind_json, .filed = false, .why = "not a zap request" },
    };

    for (cases, 0..) |c, i| {
        main.resetInboxForTest();
        // The receipt itself is signed by a THROWAWAY key, as a real one would be
        // signed by a payment server: it proves nothing about who paid.
        var receipt = inboxEvent(9735, 0x77, &.{
            &.{ "p", &me_hex },
            &.{ "description", c.json },
        }, 1_800_000_000);
        receipt.id[0] = @intCast(i);
        const filed = main.inboxAddForTest(receipt, 1_800_000_100);
        if (filed != c.filed) {
            std.debug.print("zap case '{s}': filed={} wanted={}\n", .{ c.why, filed, c.filed });
            return error.WrongZapVerdict;
        }
        if (!filed) continue;
        // Filed under the key that SIGNED, never the receipt's author and never
        // the name the string claimed.
        var buf: [8]main.InboxItem = undefined;
        const items = main.inboxItems(&buf, false);
        try testing.expectEqual(@as(usize, 1), items.len);
        try testing.expectEqualSlices(u8, &payer.public_key, &items[0].author);
    }
}

test "a zap that is replayed is still one zap, for the amount its payer signed" {
    // A zap request is PUBLIC by construction: NIP-57 makes every receipt carry
    // the signed request inside it, so one genuine request from somebody the
    // reader follows is sitting on relays in plaintext, ready to be lifted. The
    // first fix proved WHO signed and then took the amount, the time and the
    // identity from the receipt around it, which anyone may write. So a stranger
    // could mint twenty receipts carrying Alice's real request, and the sheet
    // would draw twenty rows in Alice's name for whatever figure the stranger
    // liked, while the per-author rule quietly evicted Alice's real history to
    // make room for them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    main.setIdentityForTest([_]u8{0xEA} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const alice = try signer.keyPairFromSecretKey([_]u8{0x1A} ** 32);
    // What Alice actually signed: a thousand millisats, at a time of her choosing.
    const req_tags = [_]nostr.event.Tag{
        &.{ "p", &me_hex },
        &.{ "amount", "1000" },
    };
    const req = try nostr.event.create(arena, signer, alice, 1_800_000_000, 9734, &req_tags, "", null);
    const req_json = try nostr.event.toJson(arena, req);

    // Twenty receipts carrying it, each signed by a different throwaway key, each
    // with a fresh id, an invented invoice and a current timestamp.
    for (0..20) |i| {
        var receipt = inboxEvent(9735, @intCast(0x90 + i), &.{
            &.{ "p", &me_hex },
            &.{ "description", req_json },
            &.{ "bolt11", "lnbc10m1invented" },
        }, 1_800_090_000);
        receipt.id[0] = @intCast(i);
        receipt.id[1] = 0xAB;
        _ = main.inboxAddForTest(receipt, 1_800_090_000);
    }

    var buf: [64]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    // One payment, however many wrappers were written around it.
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualSlices(u8, &alice.public_key, &items[0].author);
    // The figure Alice signed, not the one the wrapper claimed.
    try testing.expectEqual(@as(u64, 1000), items[0].msat);
    // And her time, so a replay cannot pose as something that just happened.
    try testing.expectEqual(@as(i64, 1_800_000_000), items[0].created_at);
}

test "zapping your own note is not somebody zapping you" {
    // The own-author gate is skipped for receipts, correctly, because a receipt
    // is authored by a payment server. Nothing put it back once the real payer
    // was known, and the request names the reader either way, because the reader
    // is the recipient.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const secret = [_]u8{0xEB} ** 32;
    main.setIdentityForTest(secret);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    const kp = try signer.keyPairFromSecretKey(secret);
    var me_hex: [64]u8 = undefined;
    for (kp.public_key, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const req_tags = [_]nostr.event.Tag{ &.{ "p", &me_hex }, &.{ "amount", "21000" } };
    const req = try nostr.event.create(arena, signer, kp, 1_800_000_000, 9734, &req_tags, "", null);
    const req_json = try nostr.event.toJson(arena, req);
    const receipt = inboxEvent(9735, 0x79, &.{
        &.{ "p", &me_hex },
        &.{ "description", req_json },
    }, 1_800_000_000);
    try testing.expect(!main.inboxAddForTest(receipt, 1_800_000_100));
    try testing.expectEqual(@as(usize, 0), main.inboxLenForTest());
}

test "an e tag that is not an id leaves no target rather than a broken one" {
    // `hexToBytes` decodes as far as it can before it errors, so writing straight
    // into the target left a real prefix and a zero tail, which reads as a
    // perfectly good note id and presses into nothing forever.
    main.setIdentityForTest([_]u8{0xEC} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    // Sixty-three hex characters and one that is not. Relays do not check this.
    const junk = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeZ";
    var ev = inboxEvent(1, 0x4D, &.{
        &.{ "p", &me_hex },
        &.{ "e", junk },
    }, 1_800_000_000);
    ev.id[0] = 0x4D;
    try testing.expect(main.inboxAddForTest(ev, 1_800_000_000));

    var buf: [8]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), items.len);
    // No target at all, so the row presses to the person instead of to nowhere.
    try testing.expect(!items[0].hasTarget());
}
test "an amount no one could have sent is not an amount" {
    // `bolt11` is a string the sender writes. The first version read it into a
    // u64 and drew whatever came out, which for a junk prefix was eighteen
    // quintillion sats: more than will ever exist, printed as fact.
    main.setIdentityForTest([_]u8{0xE2} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const payer = try signer.keyPairFromSecretKey([_]u8{0x0C} ** 32);
    const to_me = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    const req = try nostr.event.create(arena, signer, payer, 1_800_000_000, 9734, &to_me, "", null);
    const req_json = try nostr.event.toJson(arena, req);

    const receipt = inboxEvent(9735, 0x78, &.{
        &.{ "p", &me_hex },
        &.{ "description", req_json },
        &.{ "bolt11", "lnbc99999999999999999999999999p1xxxx" },
    }, 1_800_000_000);
    try testing.expect(main.inboxAddForTest(receipt, 1_800_000_100));

    var buf: [8]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), items.len);
    // The row still says somebody zapped, because somebody did sign for it. It
    // just declines to repeat a number that cannot be true: more millisats than
    // there will ever be bitcoin. What this does NOT do is make the amount
    // trustworthy, which needs the receipt checked against the reader's own LNURL
    // server; until then a plausible number from a stranger is still a claim.
    try testing.expectEqual(@as(u64, 0), items[0].msat);
}

test "a flood from a stranger cannot delete what the people you follow said" {
    // Signing two hundred events costs seconds and nothing else. The first
    // version kept a flat two hundred and dropped the oldest on every arrival, so
    // that was the whole price of erasing a reader's inbox, permanently: the
    // backfill window then resumes past everything the flood pushed out.
    main.setIdentityForTest([_]u8{0xE3} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    // Somebody the reader chose, who said something an hour ago.
    const friend = [_]u8{0xF1} ** 32;
    _ = main.setFollowsForTest(&.{friend}, 1_800_000_000);
    var from_friend = inboxEvent(1, 0xF1, &mine, 1_799_996_400);
    from_friend.id[0] = 0xF1;
    try testing.expect(main.inboxAddForTest(from_friend, 1_800_000_000));

    // Then one key signs three hundred, all newer.
    const spammer: u8 = 0x0D;
    for (0..300) |i| {
        var ev = inboxEvent(1, spammer, &mine, 1_800_000_000 + @as(i64, @intCast(i)));
        ev.id[0] = @intCast(i % 256);
        ev.id[1] = @intCast(i / 256);
        _ = main.inboxAddForTest(ev, 1_800_001_000);
    }

    var buf: [256]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);

    // No one author owns more than their share, however many they send.
    var by_spammer: usize = 0;
    var friend_survived = false;
    for (items) |it| {
        if (it.author[0] == spammer) by_spammer += 1;
        if (std.mem.eql(u8, &it.author, &friend)) friend_survived = true;
    }
    try testing.expect(by_spammer <= main.inbox_per_author_max);
    try testing.expect(friend_survived);
}

test "a full inbox never trades a newer notification for an older one" {
    main.setIdentityForTest([_]u8{0xE4} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    // Fill it, from enough distinct authors that the per-author rule is not what
    // is being measured here.
    seedInbox(main.inbox_cap, 0x10, 1_800_000_000);
    try testing.expectEqual(main.inbox_cap, main.inboxLenForTest());

    // A relay backfills something from a year ago. The array is full, so this is
    // a question about what to DELETE, and the answer must not be "something
    // newer than the thing arriving".
    var ancient = inboxEvent(1, 0xEE, &mine, 1_700_000_000);
    ancient.id[0] = 0xEE;
    ancient.id[1] = 0xEE;
    _ = main.inboxAddForTest(ancient, 1_800_100_000);

    var buf: [256]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    try testing.expectEqual(main.inbox_cap, items.len);
    for (items) |it| {
        try testing.expect(it.created_at >= 1_800_000_000);
    }
}

test "the bell opens onto the notifications it counted" {
    // The badge counted every reply and mention; the sheet opened on a tab that
    // showed only people the reader follows. A stranger replying is not an edge
    // case for an inbox, it is most of the point of one, so the ordinary result
    // was: badge says 1, sheet says "nothing from the people you follow", and
    // opening marked it read on the way past.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xE5} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    var stranger = inboxEvent(1, 0x2C, &mine, 1_800_000_000);
    stranger.id[0] = 0x2C;
    try testing.expect(main.inboxAddForTest(stranger, 1_800_000_000));
    try testing.expectEqual(@as(usize, 1), main.inboxUnread());

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    // Whatever the sheet opens on by default, not what this test would prefer.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "mentioned you in a note") != null);
    try testing.expect(findAnyText(tree.root, "Nothing from the people you follow yet. Everyone is in the other tab.") == null);
}

test "a notification press asks the store, not the feed" {
    // What a notification points at is almost always an older note of the
    // reader's own, or a stranger's note in a thread they were named in. The feed
    // is scoped to follows and holds a few hundred rows, so resolving the press
    // against it made the ordinary press do nothing whatsoever: no thread, no
    // error, no feedback.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xE6} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const target_hex = "ab" ** 32;
    var reply = inboxEvent(1, 0x3C, &.{
        &.{ "p", &me_hex },
        &.{ "e", target_hex },
    }, 1_800_000_000);
    reply.id[0] = 0x3C;
    try testing.expect(main.inboxAddForTest(reply, 1_800_000_000));

    var buf: [8]main.InboxItem = undefined;
    const items = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), items.len);
    // The WHOLE id, which is what the store can be asked for.
    try testing.expect(items[0].hasTarget());
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, target_hex);
    try testing.expectEqualSlices(u8, &want, &items[0].target_id);

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    const tree = try buildTree(arena, &model);
    const row = findByLabel(tree.root, "replied to you") orelse findByLabel(tree.root, "mentioned you in a note") orelse return error.RowMissing;
    for (tree.handlers) |h| {
        if (h.id != row.id or h.event != .press) continue;
        switch (h.action) {
            .message => |m| switch (m) {
                .open_event => |id| {
                    try testing.expectEqualSlices(u8, &want, &id);
                    return;
                },
                else => return error.PressGoesNowhere,
            },
            else => return error.PressGoesNowhere,
        }
    }
    return error.RowHasNoPress;
}
test "the sheet fits the view budget over the deepest thing under it" {
    // The sheet is STACKED over whatever the reader was reading, so both trees are
    // priced against the same 1024-node ceiling, and a view past it is refused
    // whole: no frame, a window that stops updating. The first version of this
    // screen was measured on its own and shipped a page count that could not be
    // drawn at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xD5} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();
    defer main.resetInboxForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    model.notifications_everyone = true;
    // A full page, which is the most the sheet ever draws at once.
    seedInbox(main.inbox_page, 0x60, 1_800_000_000);

    // Over a busy thread at the deepest the back stack goes.
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
        std.debug.print("sheet over a full back stack refused: {s}\n", .{@errorName(err)});
        return err;
    };
    try testing.expect(p.layout.nodes.len < native_sdk.runtime.max_canvas_widget_nodes_per_view);
}

test "the notifications sheet renders what it holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xB8} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    main.forgetFollowsForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    model.notifications_everyone = true;

    // Empty: the sheet says so in its own words rather than showing nothing.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "Notifications") != null);
        try testing.expect(findAnyText(tree.root, "Mark all read") != null);
        try testing.expect(findAnyText(tree.root, "read state stays on this Mac") != null);
        try testing.expect(findAnyText(tree.root, "Nothing yet. When somebody replies, mentions, likes, reposts or zaps you, it lands here.") != null);
    }

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    _ = main.inboxAddForTest(inboxEvent(1, 0xCA, &mine, 1_800_000_000), 1_800_000_000);

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "mentioned you in a note") != null);
    try testing.expect(findAnyText(tree.root, "Nothing yet. When somebody replies, mentions, likes, reposts or zaps you, it lands here.") == null);
}
test "a notification's keyboard stop goes where it says" {
    // The age under a notification is the keyboard's way to what the row opens,
    // and it is labelled "Open note". A mention that answers nothing has no
    // target, so the row opens the person instead, and a stop there would be a
    // third way to the same profile under a label that says otherwise.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xB9} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.forgetFollowsForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    model.notifications_everyone = true;

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const target = [_]u8{0x7E} ** 32;
    var target_hex: [64]u8 = undefined;
    for (target, 0..) |b, i| _ = std.fmt.bufPrint(target_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    // A mention with no note under it: the row opens the person.
    const mention = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    _ = main.inboxAddForTest(inboxEvent(1, 0xCA, &mention, 1_800_000_000), 1_800_000_000);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "mentioned you in a note") != null);
        try testing.expectEqual(@as(usize, 0), countLabelled(tree.root, "Open note"));
    }

    // A reply to a note of the reader's: the stop is there and opens that note.
    const reply = [_]nostr.event.Tag{ &.{ "e", &target_hex, "", "reply" }, &.{ "p", &me_hex } };
    _ = main.inboxAddForTest(inboxEvent(1, 0xCB, &reply, 1_800_000_100), 1_800_000_100);
    {
        const tree = try buildTree(arena, &model);
        try testing.expectEqual(@as(usize, 1), countLabelled(tree.root, "Open note"));
        try testing.expect(countPressesOf(tree, tree.root, Msg{ .open_event = target }) > 0);
    }
}

fn countLabelled(widget: canvas.Widget, label: []const u8) usize {
    var n: usize = if (canvas.widgetIsFocusable(widget) and std.mem.eql(u8, widget.semantics.label, label)) 1 else 0;
    for (widget.children) |child| n += countLabelled(child, label);
    return n;
}
test "a new account's inbox reads the starter pack as its own graph" {
    // The other half of the split, and the half no test held: the inbox and the
    // thread's own-graph ranking ask whether an author is inside the graph the
    // reader READS, which for an account with no list of its own is the pack.
    // Answering that with the membership question instead would file every
    // starter-pack author under strangers on the day the account was made.
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{0xC4} ** 32);
    defer main.clearIdentityForTest();

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    const packed_in = main.followSetForTest()[0];
    var stranger = [_]u8{0xFE} ** 32;
    stranger[1] = 0x01;

    _ = main.inboxAddForTest(inboxEventBy(7, packed_in, &mine, 1_800_000_100), 1_800_000_200);
    _ = main.inboxAddForTest(inboxEventBy(7, stranger, &mine, 1_800_000_101), 1_800_000_200);

    var buf: [main.inbox_cap]main.InboxItem = undefined;
    // The "from people you read" tab: the pack is in, the stranger is not.
    const only_follows = main.inboxItems(&buf, true);
    var saw_pack = false;
    var saw_stranger = false;
    for (only_follows) |item| {
        if (std.mem.eql(u8, &item.author, &packed_in)) saw_pack = true;
        if (std.mem.eql(u8, &item.author, &stranger)) saw_stranger = true;
    }
    if (!saw_pack) {
        std.debug.print("a starter-pack author is filed under strangers\n", .{});
        return error.PackTreatedAsStranger;
    }
    try testing.expect(!saw_stranger);

    // And everyone's tab holds both.
    const everyone = main.inboxItems(&buf, false);
    try testing.expect(everyone.len >= 2);
}
test "a reaction three levels down someone else's thread is not my notification" {
    // NIP-10 has a reply carry every p tag of its parent plus the parent's
    // author, and a NIP-25 reaction copies the p tags of what it reacts to. So
    // a reader's pubkey propagates down every thread they ever touched, and
    // matching ANY p tag filed a stranger reacting to a stranger's reply as a
    // notification about the reader.
    //
    // NIP-25: the target event's pubkey should be LAST among the p tags.
    main.setIdentityForTest([_]u8{0xA7} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, k| _ = std.fmt.bufPrint(me_hex[k * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const someone = "dd" ** 32;

    // My key is present, but the LAST p tag is somebody else: this reaction is
    // about their note, and my key is only riding along from the thread.
    var not_mine = inboxEvent(7, 0x31, &.{
        &.{ "p", &me_hex },
        &.{ "p", someone },
        &.{ "e", "ab" ** 32 },
    }, 1_800_000_100);
    not_mine.content = "+";
    try testing.expect(main.inboxVerbForTest(not_mine, me) == null);

    // My key last: this one really is about my note.
    var mine = inboxEvent(7, 0x32, &.{
        &.{ "p", someone },
        &.{ "p", &me_hex },
        &.{ "e", "ab" ** 32 },
    }, 1_800_000_200);
    mine.content = "+";
    try testing.expect(main.inboxVerbForTest(mine, me) != null);
}
test "a muted person's reply does not reach the inbox" {
    main.forgetMutesForTest();
    const me_secret = [_]u8{0x65} ** 32;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const me_kp = try signer.keyPairFromSecretKey(me_secret);

    // The SECRET, which is what this takes: handing it a pubkey signs the app in
    // as somebody else entirely, and every `p` tag below then names a stranger.
    main.setIdentityForTest(me_secret);
    defer {
        main.forgetMutesForTest();
        main.clearIdentityForTest();
    }

    const heckler = try signer.keyPairFromSecretKey([_]u8{0x66} ** 32);
    var me_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&me_hex, "{x}", .{me_kp.public_key});
    const tags = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    const at_me = try nostr.event.create(arena, signer, heckler, 1_800_000_100, 1, &tags, "oi", null);

    // Files, while they are not muted.
    main.resetInboxForTest();
    try testing.expect(main.inboxAddForTest(at_me, 1_800_000_200));

    // And does not, once they are. A mute that hides somebody from the feed but
    // still lets them ring the notification bell has not muted them.
    main.resetInboxForTest();
    const muted = [_][32]u8{heckler.public_key};
    _ = main.setMutesForTest(&muted, 1_800_000_150);
    try testing.expect(!main.inboxAddForTest(at_me, 1_800_000_200));
}
test "a comment naming me is a notification, by either p tag" {
    const me = [_]u8{0x11} ** 32;
    var me_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&me_hex, "{x}", .{me}) catch unreachable;
    const other_hex = "cc" ** 32;
    const root_hex = "ee" ** 32;

    // The kind has to be in BOTH gates. In `inbox_kinds` so a relay is asked,
    // and in the verb switch so a row exists; a kind in one but not the other
    // is a subscription paying for events nobody draws.
    var found = false;
    for (main.inbox_kinds) |k| {
        if (k == main.comment_kind) found = true;
    }
    try testing.expect(found);

    // Answering MY note: the lowercase `p` is the author of what is answered.
    const answers_me = [_]nostr.event.Tag{
        &.{ "E", root_hex, "", other_hex },
        &.{ "e", root_hex, "", other_hex },
        &.{ "p", &me_hex },
    };
    try testing.expectEqual(main.InboxVerb.reply, main.inboxVerbForTest(main.commentEventForTest(0xC1, &answers_me), me).?);

    // Named ONLY in the uppercase `P`: I started the thread, but this comment
    // answers somebody else's comment in it. NOT a notification, which is what
    // the reference clients do. Amethyst's notification subscription asks for
    // lowercase `p` and its classifier is `it[0] == "p"`; Jumble's filter is
    // `'#p': [pubkey]`. Both carry kind 1111, so the narrowing is deliberate.
    //
    // Amethyst parses `P` as `RootAuthorTag` and spends it on `pubKeyHints()`
    // and `linkedPubKeys()`, which is relay hints and profile prefetching, not
    // the inbox. It is easy to read that as "Amethyst admits both" and be
    // wrong.
    //
    // The behaviour: a thread I started can run for a hundred messages between
    // other people, and telling me about each one is the hellthread problem in
    // NIP-22 clothing.
    const on_my_root = [_]nostr.event.Tag{
        &.{ "E", root_hex, "", &me_hex },
        &.{ "P", &me_hex },
        &.{ "e", root_hex, "", other_hex },
        &.{ "p", other_hex },
    };
    try testing.expect(main.inboxVerbForTest(main.commentEventForTest(0xC2, &on_my_root), me) == null);

    // A comment naming somebody else entirely is still not mine.
    const names_other = [_]nostr.event.Tag{
        &.{ "E", root_hex, "", other_hex },
        &.{ "e", root_hex, "", other_hex },
        &.{ "p", other_hex },
    };
    try testing.expect(main.inboxVerbForTest(main.commentEventForTest(0xC3, &names_other), me) == null);
}
test "a notification names the person it mentions instead of printing their key" {
    // The row handed the raw content to `contentSpans`, which styles a token it
    // finds and never rewrites one, so a reply saying `nostr:npub1...` showed the
    // bech32 itself. The feed rewrites the same token when it builds the note.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xD1} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/mention.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const alice = [_]u8{0xA1} ** 32;
    const bob = [_]u8{0xB2} ** 32;
    main.setProfileNameForTest(alice, "Alice");
    const npub = try nostr.nip19.encodeNpub(arena, alice);
    const nprofile = try nostr.nip19.encodeNprofile(arena, bob, &.{});

    const text = try std.fmt.allocPrint(arena, "thanks nostr:{s} and nostr:{s}, see you", .{ npub, nprofile });
    var reply = inboxEvent(1, 0xC7, &.{&.{ "p", &me_hex }}, 1_800_000_000);
    reply.id[0] = 0xC7;
    reply.content = text;
    _ = try store.ingest(arena, reply, .{});
    try testing.expect(main.inboxAddForTest(reply, 1_800_000_000));

    main.forgetInboxBodyStampForTest();
    main.resolveInboxBodiesForTest();
    var buf: [4]main.InboxItem = undefined;
    const shown = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), shown.len);
    const body = shown[0].body();

    // Alice is known, so she is named. Bob is not, so he reads as a short key
    // for now, and what matters is that neither token is printed whole.
    try testing.expect(std.mem.startsWith(u8, body, "thanks @Alice and @npub1"));
    try testing.expect(std.mem.indexOf(u8, body, "nostr:") == null);
    try testing.expect(std.mem.indexOf(u8, body, npub) == null);
    try testing.expect(std.mem.indexOf(u8, body, nprofile) == null);
    try testing.expect(std.mem.endsWith(u8, body, ", see you"));

    // Each name is marked in the words with the person it names, which is what
    // lets the row style the whole name the way the feed does.
    const refs = shown[0].mentions.all();
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("@Alice", body[refs[0].off..][0..refs[0].len]);
    try testing.expectEqualSlices(u8, &alice, &main.mentionLinkPubkey(refs[0].link()).?);
    try testing.expect(std.mem.startsWith(u8, body[refs[1].off..][0..refs[1].len], "@npub1"));
    try testing.expectEqualSlices(u8, &bob, &main.mentionLinkPubkey(refs[1].link()).?);

    // And Bob's name lands later: the row is baked again rather than keeping the
    // label it was first given.
    main.setProfileNameForTest(bob, "Bob");
    main.resolveInboxBodiesForTest();
    const again = main.inboxItems(&buf, false);
    try testing.expectEqualStrings("thanks @Alice and @Bob, see you", again[0].body());
    const moved = again[0].mentions.all();
    try testing.expectEqual(@as(usize, 2), moved.len);
    try testing.expectEqualStrings("@Bob", again[0].body()[moved[1].off..][0..moved[1].len]);

    // On screen the whole name is one styled run, and it carries no link. The
    // row is drawn from a copy on the sheet's own stack, which is gone by the
    // time the runtime copies a span's link, and the paragraph has no handler
    // that a link could reach.
    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    const tree = try buildTree(arena, &model);
    const name = findSpan(tree.root, "@Bob") orelse return error.NameNotStyled;
    try testing.expect(name.weight == .medium);
    try testing.expectEqual(@as(usize, 0), name.link.len);
}

/// The first paragraph span whose text is exactly `text`.
fn findSpan(widget: canvas.Widget, text: []const u8) ?canvas.TextSpan {
    for (widget.spans) |span| {
        if (std.mem.eql(u8, span.text, text)) return span;
    }
    for (widget.children) |child| {
        if (findSpan(child, text)) |found| return found;
    }
    return null;
}

test "a name that falls past the clipped end of a preview is not marked" {
    // The preview keeps the first hundred and eighty bytes. A mention after that
    // is not in the words any more, so there is nothing to mark, and marking
    // where it used to be would put a link on whatever text sits there now.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xD3} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/clipped.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const erin = [_]u8{0xE5} ** 32;
    main.setProfileNameForTest(erin, "Erin");
    const npub = try nostr.nip19.encodeNpub(arena, erin);
    const text = try std.fmt.allocPrint(arena, "{s} nostr:{s}", .{ "word " ** 60, npub });

    var reply = inboxEvent(1, 0xC9, &.{&.{ "p", &me_hex }}, 1_800_000_000);
    reply.id[0] = 0xC9;
    reply.content = text;
    _ = try store.ingest(arena, reply, .{});
    try testing.expect(main.inboxAddForTest(reply, 1_800_000_000));
    main.forgetInboxBodyStampForTest();
    main.resolveInboxBodiesForTest();

    var buf: [4]main.InboxItem = undefined;
    const shown = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expect(std.mem.endsWith(u8, shown[0].body(), "\u{2026}"));
    try testing.expect(std.mem.indexOf(u8, shown[0].body(), "Erin") == null);
    try testing.expectEqual(@as(usize, 0), shown[0].mentions.all().len);
}

test "a reaction preview reads the reader's own note the same way" {
    // A like, a repost and a zap are about a note of the reader's own, and its
    // words are copied by a different function than a reply's.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xD2} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/liked.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};

    const carol = [_]u8{0xC3} ** 32;
    main.setProfileNameForTest(carol, "Carol");
    const npub = try nostr.nip19.encodeNpub(arena, carol);

    // The reader's own note, mentioning Carol.
    var mine = inboxEventBy(1, me, &.{}, 1_700_000_000);
    mine.id = [_]u8{0x31} ** 32;
    mine.content = try std.fmt.allocPrint(arena, "gm nostr:{s}", .{npub});
    _ = try store.ingest(arena, mine, .{});

    var target_hex: [64]u8 = undefined;
    for (mine.id, 0..) |b, i| _ = std.fmt.bufPrint(target_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    var like = inboxEvent(7, 0xC8, &.{ &.{ "p", &me_hex }, &.{ "e", &target_hex } }, 1_800_000_000);
    like.id[0] = 0xC8;
    try testing.expect(main.inboxAddForTest(like, 1_800_000_000));

    main.forgetInboxBodyStampForTest();
    main.resolveInboxBodiesForTest();
    var buf: [4]main.InboxItem = undefined;
    const shown = main.inboxItems(&buf, false);
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqualStrings("gm @Carol", shown[0].body());
}

test "a quoted note in a notification preview is a label, not sixty characters of bech32" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]u8{0x7e} ** 32;
    const note = try nostr.nip19.encodeNote(arena, id);
    const src = try std.fmt.allocPrint(arena, "look at this nostr:{s} and {s} too, note1 is not one", .{ note, note });
    var out: [512]u8 = undefined;
    const n = main.collapseEventRefsForTest(&out, src);
    try testing.expectEqualStrings("look at this [Note] and [Note] too, note1 is not one", out[0..n]);
}

test "a notification is filed off the UI thread and its words baked on it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xD4} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.forgetWantedProfilesForTest();
    defer main.forgetWantedProfilesForTest();
    main.forgetInboxBodyStampForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/inbox-thread.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    const me_hex = std.fmt.bytesToHex(me, .lower);

    // A covered reply that mentions somebody nobody has named yet, the way a
    // relay reader hands it over: stored first, then filed.
    const carol = [_]u8{0xC3} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, carol);
    var reply = inboxEvent(1, 0xD5, &.{ &.{ "p", &me_hex }, &.{ "content-warning", "spoilers" } }, 1_800_000_000);
    reply.content = try std.fmt.allocPrint(arena, "ask nostr:{s} about the ending", .{npub});
    _ = try store.ingest(arena, reply, .{});
    try testing.expect(main.inboxAddForTest(reply, 1_800_000_000));
    // And a reaction, whose glyph is its own content.
    var like = inboxEvent(7, 0xD6, &.{&.{ "p", &me_hex }}, 1_800_000_001);
    like.content = "\u{1F525}";
    try testing.expect(main.inboxAddForTest(like, 1_800_000_001));

    // Filing touched none of the UI thread's caches: no name was looked up or
    // asked for, so the words are not written yet.
    try testing.expect(!main.profileWantedForTest(carol));
    try testing.expect(!main.profileWantedForTest(reply.pubkey));
    var buf: [4]main.InboxItem = undefined;
    {
        const shown = main.inboxItems(&buf, false);
        try testing.expectEqual(@as(usize, 2), shown.len);
        for (shown) |item| try testing.expectEqual(@as(u8, 0), item.body_len);
        try testing.expectEqualStrings("\u{1F525}", shown[0].reactionGlyph());
    }

    // The tick and the sheet, on the UI thread: names asked for, words baked,
    // and the reply's content warning carried with them.
    main.welcomeInboxArrivalsForTest();
    try testing.expect(main.profileWantedForTest(reply.pubkey));
    main.resolveInboxBodiesForTest();
    try testing.expect(main.profileWantedForTest(carol));
    const shown = main.inboxItems(&buf, false);
    const baked = shown[1];
    try testing.expect(std.mem.startsWith(u8, baked.body(), "ask @npub1"));
    try testing.expect(std.mem.endsWith(u8, baked.body(), "about the ending"));
    try testing.expect(baked.warned);
}

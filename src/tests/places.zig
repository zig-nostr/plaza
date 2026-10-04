//! Tests of places.zig. Places: the place document, the open place and its feed, and the places the reader keeps.

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
const findAnyTextContaining = harness.findAnyTextContaining;
const buildTree = harness.buildTree;
const closedMsg = harness.closedMsg;
const AddressFixture = harness.AddressFixture;
const expectKeyboardReach = harness.expectKeyboardReach;
const frameOfText = harness.frameOfText;
const noteContext = harness.noteContext;
const oneNoteFeed = harness.oneNoteFeed;
const signedNote = harness.signedNote;

test "a place brings its own relays, and a feed can be about people" {
    // The document is fiatjaf's Monero Hallway instance, trimmed. Its "People"
    // feed names twenty pubkeys and NO relay, and Plaza used to drop any feed
    // without one: the room simply never appeared, with nothing said about why.
    const doc =
        \\{"appName": "Monero Hallway",
        \\ "readRepliesFrom": ["wss://xmr.usenostr.org", "wss://nostr.xmr.rocks"],
        \\ "publishTargets": ["wss://xmr.usenostr.org", "wss://nostr.xmr.rocks"],
        \\ "hardcodedFeeds": [
        \\   {"name": "Monero Topic", "relays": ["wss://topic.relays.land/monero"]},
        \\   {"name": "People", "pubkeys": [
        \\     "35d38fa2efb7c9f4b1bf20a4d2cded731b152ed871a0aac9d72347265c9b42d8",
        \\     "5f17d7be02ab98c11360c241556017377fa0f00127cd0a912f128e288c8c4dca",
        \\     "0c45d7d45edb0fadda4215d36ca0d9aba0c771b85d3717764b8a128d5e443e4d"]}]}
    ;
    const place = main.parsePlace(testing.allocator, doc) orelse return error.PlaceRefused;

    // Both feeds, not one.
    try testing.expectEqual(@as(u8, 2), place.feeds_len);
    try testing.expectEqualStrings("Monero Topic", place.feeds[0].name());
    try testing.expectEqualStrings("People", place.feeds[1].name());

    // The relay feed keeps its relay and names nobody.
    try testing.expectEqualStrings("wss://topic.relays.land/monero", place.feeds[0].relay());
    try testing.expectEqual(@as(usize, 0), place.feeds[0].people().len);

    // The people feed names its people and no relay, so it has to ask the
    // place's own.
    try testing.expectEqual(@as(usize, 3), place.feeds[1].people().len);
    try testing.expectEqual(@as(usize, 0), place.feeds[1].relay().len);

    try testing.expectEqual(@as(u8, 2), place.read_relays_len);
    try testing.expectEqualStrings("wss://xmr.usenostr.org", place.readRelay(0));
    try testing.expectEqual(@as(u8, 2), place.write_relays_len);
    try testing.expectEqualStrings("wss://xmr.usenostr.org", place.writeRelay(0));

    // Absent means additive, never "only mine". A place that says nothing must
    // not be read as taking the reader's own relays away.
    try testing.expect(!place.read_exclusive);
    try testing.expect(!place.write_exclusive);
}

test "a place says where it reads a kind, and a pattern is checked before it is offered" {
    // fiatjaf's Monero instance names Nosmero for kind 1. The pattern needs a
    // QUERY, which is exactly what `isSafeShareUrl` refuses, so handlers get
    // their own gate rather than a loosened version of that one.
    const doc =
        \\{"appName": "Monero Hallway",
        \\ "clientHandlers": {"byKind": {"1": [{"name": "Nosmero", "urlPattern": "https://nosmero.com/?thread={e}"}]}, "fallback": null},
        \\ "hardcodedFeeds": [{"name": "x", "relays": ["wss://ok.example"]}]}
    ;
    const place = main.parsePlace(testing.allocator, doc) orelse return error.PlaceRefused;
    const h = place.handlerFor(1) orelse return error.NoHandler;
    try testing.expectEqualStrings("Nosmero", h.name());
    try testing.expectEqualStrings("https://nosmero.com/?thread={e}", h.pattern());
    // And nothing is claimed for a kind the place said nothing about.
    try testing.expect(place.handlerFor(30023) == null);
}
test "saving a place keeps everything the parser understood" {
    // The places file is what a restart reads, so a field the parser
    // understands and the writer forgets is a field that works once and is gone
    // by morning. That is exactly what happened: the logo, the community's
    // relays, its handlers, its own words for a room and a feed's people were
    // all read correctly and then dropped on the next save.
    const doc =
        \\{"appName":"Monero Hallway",
        \\ "logoUrl":"https://example.test/logo.png",
        \\ "readRepliesFrom":["wss://a.example"],
        \\ "publishTargets":["wss://b.example"],
        \\ "clientHandlers":{"byKind":{"1":[{"name":"Nosmero","urlPattern":"https://nosmero.com/?thread={e}"}]}},
        \\ "translations":{"Empty list.":"Private, and proud of it.","Loading":"Mixing…","Lost in the void":"Unlinkable."},
        \\ "hardcodedFeeds":[{"name":"People","pubkeys":["35d38fa2efb7c9f4b1bf20a4d2cded731b152ed871a0aac9d72347265c9b42d8"]}]}
    ;
    const first = main.parsePlace(testing.allocator, doc) orelse return error.PlaceRefused;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try main.writePlaceDocumentForTest(testing.allocator, &out, &first);

    // Read back what was written: the round trip is the property, not the bytes.
    const again = main.parsePlace(testing.allocator, out.items) orelse return error.RoundTripRefused;
    try testing.expectEqualStrings("https://example.test/logo.png", again.logo());
    try testing.expectEqual(@as(u8, 1), again.read_relays_len);
    try testing.expectEqualStrings("wss://a.example", again.readRelay(0));
    try testing.expectEqual(@as(u8, 1), again.write_relays_len);
    try testing.expectEqualStrings("wss://b.example", again.writeRelay(0));
    const h = again.handlerFor(1) orelse return error.NoHandler;
    try testing.expectEqualStrings("Nosmero", h.name());
    try testing.expectEqualStrings("Mixing…", again.loadingLine());
    try testing.expectEqualStrings("Private, and proud of it.", again.emptyLine());
    // And the feed is still about people.
    try testing.expectEqual(@as(u8, 1), again.feeds_len);
    try testing.expectEqual(@as(usize, 1), again.feeds[0].people().len);
}
test "a place may name what its own room says, and nothing else" {
    // Hallway's `translations` maps its OWN English to replacements, and
    // Plaza's wording is different, so nothing matches by accident. Three keys
    // are picked for what they mean in a room. Everything else in the map is
    // read and ignored on purpose: a place may name its room, not rename
    // Settings.
    const doc =
        \\{"appName": "Monero Hallway",
        \\ "translations": {
        \\   "Empty list.": "Empty list. Private, and proud of it.",
        \\   "Loading": "Mixing…",
        \\   "Lost in the void": "Lost in the void, unlinkable and untraceable",
        \\   "Not following anyone": "Fungible, and free."},
        \\ "hardcodedFeeds": [{"name": "x", "relays": ["wss://ok.example"]}]}
    ;
    const place = main.parsePlace(testing.allocator, doc) orelse return error.PlaceRefused;
    try testing.expectEqualStrings("Empty list. Private, and proud of it.", place.emptyLine());
    try testing.expectEqualStrings("Mixing…", place.loadingLine());
    try testing.expectEqualStrings("Lost in the void, unlinkable and untraceable", place.lostLine());

    // A place that rewrites nothing leaves the app's own words alone, which is
    // what an absent key has to mean or every silent place would blank its room.
    const plain =
        \\{"appName": "Plain", "hardcodedFeeds": [{"name": "x", "relays": ["wss://ok.example"]}]}
    ;
    const p2 = main.parsePlace(testing.allocator, plain) orelse return error.PlaceRefused;
    try testing.expectEqual(@as(usize, 0), p2.emptyLine().len);
    try testing.expectEqual(@as(usize, 0), p2.loadingLine().len);
}

test "a handler pattern this app will not open" {
    // Each of these is a way of sending the reader somewhere other than where
    // the row says. The row names the host, so the host is the thing that must
    // not be up for grabs.
    try testing.expect(main.isSafeHandlerUrl("https://nosmero.com/?thread={e}"));
    try testing.expect(main.isSafeHandlerUrl("https://n.example/e/{e}"));

    // Not https.
    try testing.expect(!main.isSafeHandlerUrl("http://nosmero.com/?thread={e}"));
    // Credentials in the authority: the row would name the wrong host.
    try testing.expect(!main.isSafeHandlerUrl("https://evil.example@real.example/{e}"));
    // A placeholder in the HOST, which would let a note id choose the server.
    try testing.expect(!main.isSafeHandlerUrl("https://{e}.example/x"));
    // No placeholder is a fixed link that ignores which note was pressed.
    try testing.expect(!main.isSafeHandlerUrl("https://nosmero.com/"));
    // Several is an ambiguity not worth resolving.
    try testing.expect(!main.isSafeHandlerUrl("https://n.example/{e}/{e}"));
    // A backslash, and a control character.
    try testing.expect(!main.isSafeHandlerUrl("https://n.example\\@x/{e}"));
    try testing.expect(!main.isSafeHandlerUrl("https://n.example/\x01{e}"));
}

test "a place cannot point the reader at something that is not a relay" {
    // Every address a stranger fills in goes through the same gate. A place
    // naming http, or a credential, or nothing at all, keeps none of it.
    const doc =
        \\{"appName": "Nowhere",
        \\ "readRepliesFrom": ["http://insecure.example", "wss://ok.example"],
        \\ "publishTargets": ["not a url"],
        \\ "publishTargetsExclusive": true,
        \\ "hardcodedFeeds": [{"name": "x", "relays": ["wss://ok.example"]}]}
    ;
    const place = main.parsePlace(testing.allocator, doc) orelse return error.PlaceRefused;

    try testing.expectEqual(@as(u8, 1), place.read_relays_len);
    try testing.expectEqualStrings("wss://ok.example", place.readRelay(0));

    // And exclusivity over an empty list is refused. A place claiming "only
    // mine" while naming none would otherwise silence the reader completely.
    try testing.expectEqual(@as(u8, 0), place.write_relays_len);
    try testing.expect(!place.write_exclusive);
}
test "a right-click in a place keeps every row it wrote" {
    // The overrun this pins: `noteContextItems` allocated seven items and, in
    // the feed inside a place declaring a handler for kind 1, wrote eight. One
    // row was bounds-checked and the two after it were not, so the guard sat
    // directly above the write that went past the end.
    //
    // In Debug this test PANICS before the fix, which is the assertion: an
    // out-of-bounds index is not an error a test can catch. In ReleaseFast, the
    // mode Plaza ships, there is no bounds check at all and the eighth row is
    // written into memory the arena did not hand out. So the case has to be
    // built rather than reasoned about, and it has to run in both modes.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    if (!main.visitParsedPlaceForTest(arena,
        \\{"appName":"Alpha","hardcodedFeeds":[{"relays":["wss://a.example"]}],"clientHandlers":{"byKind":{"1":[{"name":"Alphaweb","urlPattern":"https://alpha.example/e/{e}"}]}}}
    )) return error.NoPlace;
    const place = main.activePlace() orelse return error.NoPlace;
    if (place.handlerFor(1) == null) return error.NoHandler;

    var model = main.initialModel();
    oneNoteFeed(&model);

    const p = try painted.Painted.render(arena, &model);
    const menu = noteContext(p) orelse return error.NoContextMenu;

    // Every row the feed case writes, including the two that used to land past
    // the end. The handler row is what pushes the count over.
    for ([_][]const u8{ "Open thread", "Copy note address", "Quote", "Copy text", "Open in Alphaweb" }) |want| {
        for (menu.items) |item| {
            if (std.mem.eql(u8, item.label, want)) break;
        } else {
            std.debug.print("a right-click in a place offers no \"{s}\"\n", .{want});
            return error.MissingRow;
        }
    }
    // The separator and the follow row were the two written past the end, so
    // their presence is the receipt rather than a nicety.
    var separators: usize = 0;
    for (menu.items) |item| {
        if (item.separator) separators += 1;
    }
    try testing.expectEqual(@as(usize, 1), separators);
    const last = menu.items[menu.items.len - 1];
    try testing.expect(!last.separator);
    try testing.expect(last.label.len > 0);
}
test "no view paints past the right edge at the narrowest the window can be" {
    // The reported bug was "link previews overflow the window". The card was
    // part of it and was bounded separately, but the rest was structural and
    // would have clipped anything sitting at the column's right edge: a link
    // preview is simply where a reader SEES it, because it is the only element
    // there with a border of its own to be cut in half.
    //
    // Plaza's layout is a fixed 620px reading column by choice, so the honest
    // guarantee is not that it reflows, it is that the window can never be made
    // narrower than the column needs. That is a create-time floor in app.zon,
    // and the layout it has to hold only exists in Zig, so nothing connected
    // them and they drifted: the floor was set before the feed became a
    // virtualList, the list then reserved an 11px scrollbar gutter, and the
    // narrowest window the app allowed had been 7px too small ever since.
    //
    // So this sweeps from the floor the MANIFEST declares, passed in by
    // build.zig, rather than from a number repeated here. Widen the column and
    // this fails until the floor moves with it.
    defer main.resetOutboxForTest();
    const floor = @import("window_floor").manifest_min_width;

    const States = enum { feed, feed_with_link, thread, profile, settings, notifications, composing, joining, places_rail, place_visiting, place_about, place_leaving, menu_scope, menu_relays, menu_account, menu_outbox };

    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    const url = "https://github.com/zig-nostr/notary/pull/35";
    main.setLinkPreviewForTest(
        url,
        "github.com",
        "Notary is Notary by sepehr-safari, Pull Request #35, zig-nostr/notary",
        "A native remote signer (NIP-46 bunker) for Nostr. Your key stays on a machine you control, and nothing else ever holds it.",
    );

    // Every stranger-supplied field filled to the capacity of the buffer that
    // holds it. A row that fits a name is not the question; a row that fits a
    // name of the sixty-four characters the buffer allows is, because that is
    // what will eventually arrive.
    const long_name = "N" ** 64;
    const long_user = "u" ** 64;
    const long_site = "https://" ++ ("a" ** 112) ++ ".example";
    const long_nip05 = ("h" ** 60) ++ "@" ++ ("d" ** 60) ++ ".example";
    const long_relay = "wss://" ++ ("r" ** 96) ++ ".example.com";
    // A place's name and its feed's name, at the capacity of the buffers that
    // receive them (`place_name_cap`, `place_feed_name_cap`). Both are a
    // stranger's, and both land in fixed-width chrome.
    const long_place = "P" ** 64;
    const long_feed = "F" ** 48;
    // A host's markdown, with a heading and a list, wide enough to wrap.
    const long_about = "# " ++ ("A" ** 60) ++ "\n\nA description a stranger wrote, long enough to wrap more than once in the column it is given.\n\n- " ++ ("b" ** 70) ++ "\n- and another\n";
    // Exactly the 128 bytes `lud16_buf` holds. A single byte over and the
    // parser drops the field without a word, which is correct of it and made
    // the first version of this measure an empty line.
    const long_lud16 = ("l" ** 59) ++ "@" ++ ("w" ** 60) ++ ".example";

    // The profile page reads its website and lightning address from a
    // PersonCard, which is parsed out of a kind:0 IN THE STORE, not from the
    // Profile record the helper above fills. They are different buffers behind
    // similar names, so filling the one the sweep knew about left the two
    // widest lines on that page rendered from empty strings and measured as
    // clean.
    var arena_state_store = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state_store.deinit();
    const store_arena = arena_state_store.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/sweep.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Unsigned on purpose: `ingest` only verifies when it is handed a signer,
    // and what is under test is how wide these strings paint rather than
    // whether the event is authentic.
    const subject = main.noteWithLinkForTest("").pubkey;
    const meta = try std.fmt.allocPrint(
        store_arena,
        "{{\"name\":\"{s}\",\"website\":\"{s}\",\"lud16\":\"{s}\",\"about\":\"{s}\"}}",
        .{ long_name, long_site, long_lud16, "A stranger's biography, long enough that it has to wrap more than once in the column it is given." },
    );
    _ = try store.ingest(store_arena, .{
        .id = [_]u8{0xa1} ** 32,
        .pubkey = subject,
        .created_at = 1_800_000_000,
        .kind = 0,
        .tags = &.{},
        .content = meta,
        .sig = [_]u8{0} ** 64,
    }, .{});

    var worst_over: f32 = 0;
    // What the plain feed renders, so a state that opens something on top of it
    // can prove it actually opened. A screen the sweep cannot reach measures
    // clean, and a clean measurement of nothing is the failure this sweep is
    // most likely to have: it reads exactly like coverage.
    var base_nodes: usize = 0;
    inline for (@typeInfo(States).@"enum".fields) |f| {
        const st: States = @enumFromInt(f.value);
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();

        // On the heap, not the stack. `inline for` unrolls the body once per
        // state, and in a Debug build the copies do not share stack slots, so a
        // Model carrying three hundred notes of fixed buffers overflowed the
        // thread's stack once this reached thirteen states. It crashed rather
        // than failed, which is what #139 saw when it first tried to add the
        // menus and read as a missing precondition. It was the test's own
        // frame. ReleaseFast reuses the slots and hides it, so this only ever
        // showed up in CI.
        const model = try arena_state.allocator().create(main.Model);
        model.* = main.initialModel();
        model.stage = .ready;
        model.notes[0] = main.noteWithLinkForTest(if (st == .feed) "" else url);
        // A note body long enough to wrap several times, so the body's own
        // wrapping is exercised alongside everything else.
        const body = "A stranger wrote this and it goes on for a while https://example.com/a/rather/long/link ";
        const b = @min(body.len, model.notes[0].content_buf.len);
        @memcpy(model.notes[0].content_buf[0..b], body[0..b]);
        model.notes[0].content_len = @intCast(b);
        model.notes_len = 1;

        main.resetProfilesForTest();
        main.fillProfileTextForTest(model.notes[0].pubkey, long_name, long_user, long_site);
        main.setProfileNip05ForTest(model.notes[0].pubkey, long_nip05, true);
        main.clearRelaysForTest();
        _ = main.addRelayForTest(long_relay, true, true);
        _ = main.addRelayForTest("wss://relay.example.org", true, true);
        main.seedInboxUnreadForTest(3);
        // Every state starts out of every place, or one state's room and one
        // state's rail leak into the next one's measurement.
        main.resetPlacesForTest();
        switch (st) {
            .feed, .feed_with_link => {},
            .thread => {
                model.viewing_thread = model.notes[0].id;
                model.thread_root = model.notes[0];
                model.thread_notes[0] = model.notes[0];
                model.thread_notes_len = 1;
            },
            .profile => model.viewing_profile = model.notes[0].pubkey,
            .settings => model.stage = .settings,
            .notifications => model.notifications_open = true,
            .composing => model.composing = true,
            .joining => model.joining = true,
            .menu_scope => model.menu = .scope,
            .menu_relays => model.menu = .relays,
            .menu_account => model.menu = .account,
            .menu_outbox => {
                // The zone this menu hangs off is absent unless something is
                // actually queued, and the menu itself is absent unless the
                // queue has rows, so a flag alone drew nothing at all. The
                // node-count guard is what found that.
                main.resetOutboxForTest();
                _ = main.enqueueOutboxForTest(model.notes[0].pubkey, model.notes[0].pubkey, 1_800_000_000);
                model.outbox_pending = 1;
                model.menu = .outbox;
            },
            // The second rail, full, with a visit above the list: every string
            // on it is a stranger's, and the rail is a fixed 180pt column that
            // cannot grow to fit one.
            .places_rail => {
                var fx: main.EffectsForTest = undefined;
                main.visitPlaceForTest([_]u8{0x71} ** 32, "one", long_place);
                main.update(model, .place_enter, &fx);
                main.visitPlaceForTest([_]u8{0x72} ** 32, "two", "Bass Pistol");
                main.update(model, .place_enter, &fx);
                main.goToOwnPlazaForTest();
                main.visitPlaceForTest([_]u8{0x73} ** 32, "three", long_place);
                main.goToOwnPlazaForTest();
                main.setRailForTest(true);
            },
            // Inside a place, which replaces the scope line with a header of a
            // stranger's name, their feed's name, and their markdown.
            // Entered, with the description open behind its control: the
            // widest the header can be, because that row then carries the
            // About toggle as well as Leave.
            .place_about => {
                var fx: main.EffectsForTest = undefined;
                main.visitPlaceWithFeedForTest([_]u8{0x75} ** 32, "five", long_place, long_feed);
                main.setPlaceHomeForTest(long_about);
                main.update(model, .place_enter, &fx);
                main.setPlaceLinkForTest(.unreachable_relay);
                main.setRailForTest(true);
                main.setPlaceInfoForTest(.open);
            },
            // The same card with the leave warning up, which is the taller of
            // the two states and carries a sentence of its own.
            .place_leaving => {
                var fx: main.EffectsForTest = undefined;
                main.visitPlaceWithFeedForTest([_]u8{0x76} ** 32, "six", long_place, long_feed);
                main.setPlaceHomeForTest(long_about);
                main.update(model, .place_enter, &fx);
                main.setRailForTest(true);
                main.setPlaceInfoForTest(.leaving);
            },
            .place_visiting => {
                main.visitPlaceWithFeedForTest([_]u8{0x74} ** 32, "four", long_place, long_feed);
                // The longest thing the header can say about the connection,
                // measured with the longest name and feed name beside it.
                main.setPlaceLinkForTest(.unreachable_relay);
                main.setRailForTest(true);
            },
        }

        const p = try painted.Painted.renderAt(arena_state.allocator(), model, floor, floor);
        // The baseline is the feed WITH the link note, because that is what
        // every menu state is drawn on top of. Taking it from the plain feed
        // instead made this guard pass a menu that rendered nothing: the link
        // note alone accounts for eighteen nodes, which was enough to look like
        // an opened menu.
        if (st == .feed_with_link) base_nodes = p.layout.nodes.len;
        try expectKeyboardReach(p.tree, p.tree.root, f.name);
        {
            const tk = theme.tokens(main.Model)(model);
            canvas.expectA11yAuditSweepClean(arena_state.allocator(), p.tree.root, .{
                .tokens = tk,
                .min_size = native_sdk.geometry.SizeF.init(floor, 520),
                .default_size = native_sdk.geometry.SizeF.init(main.window_width, main.window_height),
            }) catch |err| {
                std.debug.print("\nthe accessibility audit found something on the {s} screen (its own report is above)\n", .{f.name});
                return err;
            };
        }
        // The profile's two widest lines come from the store, so prove they
        // reached the screen. Without this the state passes whether the strings
        // are painted or empty, and an empty string measures beautifully.
        if (st == .profile) {
            var saw_site = false;
            var saw_lud16 = false;
            for (p.layout.nodes) |n| {
                if (std.mem.startsWith(u8, n.widget.text, "https://aaaaaaaaaa")) saw_site = true;
                if (std.mem.startsWith(u8, n.widget.text, "llllllllll")) saw_lud16 = true;
            }
            if (!saw_site or !saw_lud16) {
                std.debug.print(
                    "\nthe profile painted no website ({}) and no lightning address ({}): this state is measuring empty strings\n",
                    .{ saw_site, saw_lud16 },
                );
                return error.ProfileLinksNeverPainted;
            }
        }

        // A menu is drawn OVER the feed, so opening one can only add. If a
        // state ever stops reaching its screen this fails here rather than
        // reporting a clean sweep of a screen it never drew.
        switch (st) {
            .places_rail, .place_visiting, .place_about, .place_leaving, .menu_scope, .menu_relays, .menu_account, .menu_outbox => {
                if (p.layout.nodes.len <= base_nodes) {
                    std.debug.print(
                        "\n{s} rendered {d} nodes and the feed under it renders {d}: the menu never opened, so this state measures nothing\n",
                        .{ f.name, p.layout.nodes.len, base_nodes },
                    );
                    return error.SweptStateRenderedNothing;
                }
            },
            else => {},
        }

        // Measuring painted geometry, not options. Every one of these nodes
        // reports a perfectly reasonable width on its own; the defect only
        // exists as a position.
        for (p.layout.nodes) |n| {
            const right = n.widget.frame.x + n.widget.frame.width;
            const over = right - floor;
            if (over > 0.5 and over > worst_over) {
                worst_over = over;
                const label = if (n.widget.text.len > 0) n.widget.text else n.widget.semantics.label;
                std.debug.print(
                    "\n{s}: a {s} reaches {d:.0} in a {d:.0}px window, {d:.0}px past the edge  \"{s}\"\n",
                    .{ f.name, @tagName(n.widget.kind), right, floor, over, label[0..@min(label.len, 40)] },
                );
            }
        }
    }
    if (worst_over > 0) {
        std.debug.print(
            "\nthe window's floor is {d:.0}px and its content needs {d:.0}px. Raise .min_width in app.zon.\n",
            .{ floor, floor + worst_over },
        );
    }
    try testing.expect(worst_over == 0);
}
test "a place is read out of a stranger's event, using Hallway's own field names" {
    // The names are fiatjaf's, not mine: `window.hallway.universe` is a flat
    // object of 41 camelCase keys embedded in every site his deployer ships. A
    // place published once should mean the same thing in both clients.
    const gpa = testing.allocator;

    const good =
        \\{"appName":"nOasis","homeMarkdown":"# Rules\n\n- be interesting",
        \\ "hardcodedFeeds":[{"name":"Spatia-Arcana","relays":["wss://spatia-arcana.com"]}]}
    ;
    const m = main.parsePlace(gpa, good) orelse return error.NoPlace;
    try testing.expectEqualStrings("nOasis", m.name());
    try testing.expectEqualStrings("# Rules\n\n- be interesting", m.home());
    try testing.expectEqual(@as(u8, 1), m.feeds_len);
    try testing.expectEqualStrings("Spatia-Arcana", m.feeds[0].name());
    try testing.expectEqualStrings("wss://spatia-arcana.com", m.feeds[0].relay());

    // The other 36 keys are ignored rather than refused, so a place carrying the
    // whole object still applies the five this version reads. `feedKinds`,
    // `kindGroups`, `indexerUrls` and `dearrowYoutube` below are among the
    // ignored; `defaultPrimaryColor` used to be and is now read, which is what
    // the assertion under this block pins.
    const full =
        \\{"appName":"Later","defaultPrimaryColor":"CYAN","feedKinds":[1,6,20],
        \\ "kindGroups":[{"kinds":[1,6],"label":"Notes"}],
        \\ "indexerUrls":["wss://purplepag.es"],"dearrowYoutube":true,
        \\ "hardcodedFeeds":[{"relays":["wss://a.example"],"pubkeys":["abcd"]}]}
    ;
    const n = main.parsePlace(gpa, full) orelse return error.NoPlace;
    try testing.expectEqualStrings("Later", n.name());
    try testing.expectEqual(@as(u8, 1), n.feeds_len);
    // A feed with no name of its own is labelled by its host: Hallway's own
    // data has one like this, so it is a real case and not a hypothetical.
    try testing.expectEqualStrings("a.example", n.feeds[0].name());
    // And the colour, which this version does read.
    const cyan = n.color orelse return error.NoColour;
    try testing.expectEqualStrings("CYAN", cyan.name);

    // Not a place at all. kind:30078 is shared by every app that stores
    // settings, so an empty document must not be applied as one.
    try testing.expect(main.parsePlace(gpa, "{}") == null);
    try testing.expect(main.parsePlace(gpa, "{\"unrelated\":true}") == null);
    try testing.expect(main.parsePlace(gpa, "not json") == null);
}

test "a place cannot point Plaza at a relay it should not dial" {
    // The relay URL is the one field that reaches the network, so it is checked
    // rather than trusted.
    const gpa = testing.allocator;

    const refused = [_][]const u8{
        "ws://plain.example", // cleartext
        "http://not.a.relay",
        "wss://", // nothing after the scheme
        "wss://has space.example",
        "wss://has\nnewline.example", // would smuggle a line into a frame
        "wss://has\ttab.example",
    };
    for (refused) |url| {
        if (main.isSafeRelayUrl(url)) {
            std.debug.print("accepted a relay it should refuse: {s}\n", .{url});
            return error.UnsafeRelayAccepted;
        }
    }
    try testing.expect(main.isSafeRelayUrl("wss://basspistol.org"));

    // A feed picks the first relay it WILL dial, rather than the first listed:
    // one bad entry must not cost the whole feed.
    const mixed =
        \\{"appName":"Mixed","hardcodedFeeds":[
        \\ {"name":"ok","relays":["ws://plain.example","wss://good.example"]},
        \\ {"name":"none","relays":["http://nope.example"]}]}
    ;
    const m = main.parsePlace(gpa, mixed) orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 1), m.feeds_len);
    try testing.expectEqualStrings("wss://good.example", m.feeds[0].relay());
}

test "an overlong place field is cut on a character boundary" {
    // A name or home text longer than the buffer is a stranger's choice, not an
    // error, so it is cut. Cut mid-character it would draw a replacement glyph.
    const gpa = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"appName\":\"");
    var i: usize = 0;
    while (i < 40) : (i += 1) try buf.appendSlice(gpa, "\u{1F600}"); // 4 bytes each, 160 total
    try buf.appendSlice(gpa, "\"}");

    const m = main.parsePlace(gpa, buf.items) orelse return error.NoPlace;
    try testing.expect(m.name_len > 0);
    try testing.expect(m.name_len <= 64);
    if (!std.unicode.utf8ValidateSlice(m.name())) {
        std.debug.print("the cut name is not valid UTF-8: {any}\n", .{m.name()});
        return error.CutMidCharacter;
    }
}

test "a place brings its own colour, and only a name Hallway knows" {
    // `defaultPrimaryColor` is an ENUM NAME, not a hex: fiatjaf's deployer
    // offers eighteen and writes one of them. Resolving it here rather than in
    // a view means a stranger's string is checked at the boundary like every
    // other field, and a name nobody knows changes nothing rather than picking
    // whatever sorted first.
    const gpa = testing.allocator;

    const yellow = main.parsePlace(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW"}
    ) orelse return error.NoPlace;
    const c = yellow.color orelse return error.NoColour;
    try testing.expectEqualStrings("YELLOW", c.name);
    // Hallway's own dark row for YELLOW, so a place published once looks the
    // same in both clients.
    try testing.expectEqual(canvas.Color.rgb8(0xff, 0xe5, 0x00), c.primary);

    // The deployer writes upper case; a hand-written document may not.
    const lower = main.parsePlace(gpa,
        \\{"appName":"Quiet","defaultPrimaryColor":"teal"}
    ) orelse return error.NoPlace;
    const t = lower.color orelse return error.NoColour;
    try testing.expectEqualStrings("TEAL", t.name);

    // A name this version does not know and an absent key are the SAME state,
    // and it is the safe one: leave Plaza's own accent alone.
    const unknown = main.parsePlace(gpa,
        \\{"appName":"Odd","defaultPrimaryColor":"CHARTREUSE"}
    ) orelse return error.NoPlace;
    try testing.expect(unknown.color == null);
    const absent = main.parsePlace(gpa,
        \\{"appName":"Plain"}
    ) orelse return error.NoPlace;
    try testing.expect(absent.color == null);

    // And a colour alone is not a place. kind:30078 is shared by every app that
    // stores settings, so a document with nothing to SAY stays refused.
    try testing.expect(main.parsePlace(gpa,
        \\{"defaultPrimaryColor":"ROSE"}
    ) == null);
}

test "the app wears the place's colour, and takes it off on the way out" {
    // The character was in the document and nowhere on screen. This is the seam
    // that fixes it: `tokens_fn` is consulted every rebuild and was ignoring its
    // argument, so a place colour costs no invalidation of its own.
    const gpa = testing.allocator;
    const model = main.initialModel();
    main.resetPlacesForTest();
    main.installThemeHooks();
    defer main.resetPlacesForTest();

    // Out of a place the chrome is porcelain, which is the locked M10 decision
    // and must not move just because places exist.
    const own = theme.tokens(Model)(&model);
    try testing.expectEqual(theme.palette.accent, own.colors.accent);

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW",
        \\ "hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    )) return error.NoPlace;

    const inside = theme.tokens(Model)(&model);
    const yellow = theme.placeColor("YELLOW") orelse return error.NoColour;
    try testing.expectEqual(yellow.primary, inside.colors.accent);
    try testing.expectEqual(yellow.on_primary, inside.colors.accent_text);
    // The CONTROL table too, and this is the half that is easy to miss: a
    // filled primary reads `controls.button_primary` FIRST and only falls
    // through to `colors.accent` when that channel is null. The house pack
    // fills it, so setting the colour alone would repaint everything except the
    // one control the reader presses to enter.
    if (inside.controls.button_primary.background) |bg| {
        try testing.expectEqual(yellow.primary, bg);
    } else {
        std.debug.print("the Enter button kept the house accent inside a place\n", .{});
        return error.ButtonKeptHouseAccent;
    }

    // A place that states no colour leaves the chrome alone rather than
    // reaching for a default, because DEFAULT is a magenta and nobody asked.
    main.clearActivePlaceForTest();
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Plain","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    try testing.expectEqual(theme.palette.accent, theme.tokens(Model)(&model).colors.accent);

    // And walking out puts it back.
    main.clearActivePlaceForTest();
    try testing.expectEqual(theme.palette.accent, theme.tokens(Model)(&model).colors.accent);

    // Tokens are not pixels. This is the same claim at the paint layer: the
    // Enter button in a visited place is FILLED with the place's colour, which
    // is what a reader actually sees on the way in.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var painted_model = main.initialModel();
    painted_model.stage = .ready;
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW",
        \\ "hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    )) return error.NoPlace;
    const p = try painted.Painted.render(arena_state.allocator(), &painted_model);
    // By its TEXT: the frame under the word is the button's own fill, which is
    // what `fillAt` reports (text draws are not fills).
    const enter = frameOfText(p, "Enter") orelse return error.NoEnterButton;
    const fill = p.fillAt(enter.x + enter.width / 2, enter.y + enter.height / 2) orelse
        return error.EnterNeverPainted;
    if (!painted.sameColor(fill, yellow.primary)) {
        std.debug.print("the Enter button did not paint the place's colour\n", .{});
        return error.AccentNeverPainted;
    }
}

test "two places with no branding still do not look like each other" {
    // Tier 0 of the character work, and the half that needs no configuration at
    // all: the rail used to draw every place on one flat `surface_link_tile`,
    // so a column of them was identical grey squares distinguished only by the
    // letter inside. Most places will never state a colour, so the fallback is
    // the case that matters most.
    const gpa = testing.allocator;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Alpha","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    var alpha = (main.activePlace() orelse return error.NoPlace).*;
    var beta = alpha;
    // Only the host differs, which is the whole point: the tile is keyed off
    // the pubkey the way a face is.
    alpha.author = @splat(0x01);
    beta.author = @splat(0x02);

    const a = main.placeTileColorsForTest(&alpha);
    const b = main.placeTileColorsForTest(&beta);
    if (painted.sameColor(a.bg, b.bg)) {
        std.debug.print("two hosts, one tile colour\n", .{});
        return error.TilesIdentical;
    }
    // And neither is the flat fill they all used to share.
    try testing.expect(!painted.sameColor(a.bg, theme.palette.surface_link_tile));

    // A stated colour wins over the rotation, so branding is never overridden
    // by a hash of somebody's key.
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW",
        \\ "hardcodedFeeds":[{"relays":["wss://basspistol.org"]}]}
    )) return error.NoPlace;
    const branded = main.placeTileColorsForTest(main.activePlace() orelse return error.NoPlace);
    const yellow = theme.placeColor("YELLOW") orelse return error.NoColour;
    try testing.expect(painted.sameColor(branded.bg, yellow.primary));
}

test "a feed asks for the kinds it named, not for notes it does not carry" {
    // Hallway's own Livestreams feed is `kinds:[1,30311]`, and the room
    // subscribed to kind 1 no matter what the place said. A community that
    // publishes streams got a socket that worked, a relay that answered, and an
    // empty room forever, which reads as a broken relay rather than as a
    // client that was not listening.
    const gpa = testing.allocator;

    const streams = main.parsePlace(gpa,
        \\{"appName":"Livelier","hardcodedFeeds":[
        \\ {"name":"Livestreams","relays":["wss://livestream.livelier.live"],"kinds":[1,30311]}]}
    ) orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 1), streams.feeds_len);
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 30311 }, streams.feeds[0].kinds());

    // A feed that names none stays EMPTY here rather than being filled in with
    // a 1: the fallback lives at the subscription, so "said nothing" and "said
    // notes" remain different facts.
    const quiet = main.parsePlace(gpa,
        \\{"appName":"Quiet","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    ) orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 0), quiet.feeds[0].kinds_len);

    // Bounded like every other field a stranger fills: too many keeps the first
    // few rather than refusing the feed.
    const greedy = main.parsePlace(gpa,
        \\{"appName":"Greedy","hardcodedFeeds":[
        \\ {"relays":["wss://a.example"],"kinds":[1,2,3,4,5,6,7,8,9,10,11,12]}]}
    ) orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 8), greedy.feeds[0].kinds_len);
    try testing.expectEqual(@as(u16, 1), greedy.feeds[0].kinds()[0]);
}

test "a place that asks for square faces gets them, and only in its own room" {
    // `avatarStyleDefault`. One field, and the shape belongs to the ROOM:
    // walking out has to restore the disc without touching a single note.
    const gpa = testing.allocator;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const round = main.avatarRadiusForTest(32);
    try testing.expectEqual(@as(f32, 16), round);

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Squares","avatarStyleDefault":"square",
        \\ "hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    const square = main.avatarRadiusForTest(32);
    if (square >= round) {
        std.debug.print("a square place still draws discs: radius {d}\n", .{square});
        return error.StillRound;
    }
    // Rounded, not a hard corner: at 32px against a 1px rule a true zero reads
    // as a rendering fault.
    try testing.expect(square > 0);

    // "circle" is the app's own shape, and so is saying nothing.
    main.clearActivePlaceForTest();
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Circles","avatarStyleDefault":"circle",
        \\ "hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    try testing.expectEqual(round, main.avatarRadiusForTest(32));

    main.clearActivePlaceForTest();
    try testing.expectEqual(round, main.avatarRadiusForTest(32));
}

test "arriving in a place opens the host's welcome, coming back does not" {
    // Two decisions collided here and running it settled them. `homeMarkdown`
    // behind the Info button is character nobody sees on the way in. The same
    // text OVER the feed is worse: the only verb on screen is Enter, and Enter
    // dismisses it, so there is no way to READ a welcome at all.
    //
    // The card is the surface built for it. Opened for you on arrival, whole
    // and scrollable, with Enter and Close both in reach, and the markdown
    // still never sits over the feed, which is the older decision this nearly
    // walked back.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x7d} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/welcome.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const talkative = [_]nostr.event.Tag{&.{ "d", "talkative" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &talkative,
        \\{"appName":"BASSPISTOL","homeMarkdown":"# House rules\n\n- turn it up","defaultPrimaryColor":"YELLOW","hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, ev);

    main.armPlaceFetchForTest(kp.public_key, "talkative");
    main.refreshPlaceFetchForTest();
    try testing.expect(main.activePlace() != null);
    try testing.expectEqual(main.PlaceInfo.open, main.placeInfo());
    // The whole text, not an excerpt: this is the surface a reader came to for
    // the rest, so there is no "rest" to send them anywhere else for.
    const p = try painted.Painted.renderAt(arena, &model, main.window_width, main.window_height);
    try testing.expect(paintsText(p, "turn it up"));

    // Closing it leaves you standing in the room, not back on your own feed.
    main.update(&model, .close_place_info, &fx);
    try testing.expectEqual(main.PlaceInfo.closed, main.placeInfo());
    try testing.expect(main.activePlace() != null);

    // Coming back from the rail is not a first impression. A card in the way
    // every time you switch rooms is the banner problem in a different hat.
    main.update(&model, .place_enter, &fx);
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());
    main.openKeptPlaceForTest(0);
    try testing.expectEqual(main.PlaceInfo.closed, main.placeInfo());

    // And a place with nothing to say does not open a card to say it.
    main.resetPlacesForTest();
    const quiet = [_]nostr.event.Tag{&.{ "d", "quiet" }};
    const ev2 = try nostr.event.create(arena, signer, kp, 1000, 30078, &quiet,
        \\{"appName":"Quiet","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, ev2);
    main.armPlaceFetchForTest(kp.public_key, "quiet");
    main.refreshPlaceFetchForTest();
    try testing.expect(main.activePlace() != null);
    try testing.expectEqual(main.PlaceInfo.closed, main.placeInfo());
}

test "a long welcome does not push Leave off the bottom of the Info card" {
    // Found by running it: BASSPISTOL's real `homeMarkdown` is two headings and
    // two lists, and the card had no height bound at all, so the dialog grew
    // taller than the window and took its own footer off the bottom edge. The
    // reader who most wants Close and Leave is the one standing in a place they
    // are trying to get out of.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    main.resetProfilesForTest();
    defer main.resetPlacesForTest();
    defer main.resetProfilesForTest();

    // The real shape: headings, prose and lists, not one long paragraph.
    var home: std.ArrayList(u8) = .empty;
    defer home.deinit(testing.allocator);
    try home.appendSlice(testing.allocator, "# BASSPISTOL\n\nOne relay, seven rigs.\n\n## House rules\n\n");
    var i: usize = 0;
    while (i < 24) : (i += 1) try home.print(testing.allocator, "- rule number {d}, stated at length\n", .{i});

    main.visitPlaceWithFeedForTest([_]u8{0x82} ** 32, "bass", "BASSPISTOL", "The Dance");
    main.setPlaceHomeForTest(home.items);
    main.update(&model, .place_enter, &fx);
    main.update(&model, .open_place_info, &fx);

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    const close = frameOfText(p, "Close") orelse return error.NoCloseButton;
    if (close.y + close.height > main.window_height) {
        std.debug.print("Close sits {d} past the bottom of a {d} window\n", .{ close.y + close.height - main.window_height, main.window_height });
        return error.FooterOffScreen;
    }
    const leave = frameOfText(p, "Leave") orelse return error.NoLeaveButton;
    if (leave.y + leave.height > main.window_height) return error.LeaveOffScreen;

    // Still the WHOLE text in there, not an excerpt: cutting is the welcome's
    // job, and Info is where a reader goes for the rest.
    if (!paintsText(p, "rule number 0, stated at length")) return error.HomeTextMissing;
}
test "inside a place the purples are the community's, not Plaza's" {
    // The complaint this came from: one tinted button does not feel like a
    // community. It was right. The accent reached two controls, while every
    // @handle, @mention and in-text URL in the feed, which is most of what a
    // feed IS, stayed Plaza's violet. Those runs are where a room either reads
    // as somebody's or does not.
    const gpa = testing.allocator;
    const model = main.initialModel();
    main.resetPlacesForTest();
    main.installThemeHooks();
    defer main.resetPlacesForTest();

    // Out of a place: the violet. The M10 rule stands where no community has
    // asked for anything.
    try testing.expectEqual(theme.palette.accent_identity, main.identityInkForTest());
    try testing.expectEqual(theme.palette.accent_identity, theme.tokens(Model)(&model).colors.info);

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW",
        \\ "hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    )) return error.NoPlace;
    const yellow = theme.placeColor("YELLOW") orelse return error.NoColour;

    // Both halves, because they are different mechanisms and either one left
    // behind puts a violet run back in a yellow room: element foregrounds go
    // through the helper, and TextSpans name the `info` token.
    try testing.expectEqual(yellow.on_dark, main.identityInkForTest());
    try testing.expectEqual(yellow.on_dark, theme.tokens(Model)(&model).colors.info);

    // Text takes `on_dark`, never the fill. Hallway's `primary` is a background
    // value with near-black knocked out of it; set as text on this window it is
    // a rumour of text.
    try testing.expect(!painted.sameColor(yellow.primary, main.identityInkForTest()));

    // The room's bright verb DOES take the fill, which is what it is for.
    try testing.expect(painted.sameColor(yellow.primary, main.roomVerbFillForTest()));

    // A place that states no colour is left alone entirely.
    main.clearActivePlaceForTest();
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Plain","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    try testing.expectEqual(theme.palette.accent_identity, main.identityInkForTest());

    main.clearActivePlaceForTest();
    try testing.expectEqual(theme.palette.accent_identity, main.identityInkForTest());
}
test "a place edited since your last visit does not show you the old one" {
    // A place is a REPLACEABLE event, and the copy sitting in the local store
    // when a link is followed is LAST SESSION'S. It was read on the first tick,
    // applied instantly, and the fetch window was then closed, so the host's
    // current document, still in flight from their relay, arrived a moment
    // later, was ingested, and never reached the room.
    //
    // Found the hard way: the BASSPISTOL place was republished with real
    // Hallway keys, and a client that had visited the earlier version kept
    // showing it (no colour, round faces) while the store underneath already
    // held the new one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x8f} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/places.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const tags = [_]nostr.event.Tag{&.{ "d", "outernational-dancehall" }};

    const old = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags,
        \\{"appName":"BASSPISTOL","homeMarkdown":"one relay","hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, old);

    main.armPlaceFetchForTest(kp.public_key, "outernational-dancehall");
    main.refreshPlaceFetchForTest();
    const first = main.activePlace() orelse return error.NoPlace;
    try testing.expectEqualStrings("BASSPISTOL", first.name());
    try testing.expect(first.color == null);

    // The host's current document lands from their relay a beat later.
    const current = try nostr.event.create(arena, signer, kp, 2000, 30078, &tags,
        \\{"appName":"BASSPISTOL","homeMarkdown":"one relay","defaultPrimaryColor":"YELLOW","avatarStyleDefault":"square","hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, current);

    main.refreshPlaceFetchForTest();
    const upgraded = main.activePlace() orelse return error.NoPlace;
    const c = upgraded.color orelse return error.ColourNeverArrived;
    try testing.expectEqualStrings("YELLOW", c.name);
    try testing.expect(upgraded.square_avatars);

    // An OLDER copy arriving late (a slow relay with a stale replica) must not
    // walk the room backwards.
    const stale = try nostr.event.create(arena, signer, kp, 500, 30078, &tags,
        \\{"appName":"BASSPISTOL","homeMarkdown":"one relay","hardcodedFeeds":[{"relays":["wss://basspistol.org"]}]}
    , null);
    _ = main.plazaIngestForTest(arena, stale) catch {};
    main.refreshPlaceFetchForTest();
    const still = main.activePlace() orelse return error.NoPlace;
    try testing.expect(still.color != null);
}

test "a place carries all of its feeds, and you can change which one you read" {
    // `place_feeds_cap` was 1. Hallway's OWN default document lists five, so
    // that was not a simplification of the format, it was four fifths of a
    // community discarded at the parser: a room with "Basically Global",
    // "Kinda Trending" and "Livestreams" showed one of them and no way to say
    // where the others went.
    const gpa = testing.allocator;
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","defaultPrimaryColor":"YELLOW","hardcodedFeeds":[
        \\ {"name":"The Dance","relays":["wss://basspistol.org"]},
        \\ {"name":"Outernational","relays":["wss://nos.lol"],"kinds":[1,30311]},
        \\ {"relays":["wss://offchain.pub"]}]}
    )) return error.NoPlace;
    const m = main.activePlace() orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 3), m.feeds_len);

    // The room opens on the one its host listed FIRST.
    try testing.expectEqual(@as(u8, 0), main.placeFeedIndexForTest());
    try testing.expectEqualStrings("The Dance", model.scope_name());

    // Changing feed changes what the room IS, so the name follows it.
    main.update(&model, main.Msg{ .place_feed = 1 }, &fx);
    try testing.expectEqual(@as(u8, 1), main.placeFeedIndexForTest());
    try testing.expectEqualStrings("Outernational", model.scope_name());
    // And the subscription follows it too, kinds and all.
    const now = main.activePlace() orelse return error.NoPlace;
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 30311 }, now.feeds[1].kinds());

    // A feed with no name of its own is its relay's host, the same substitution
    // the parser and the header already make.
    main.update(&model, main.Msg{ .place_feed = 2 }, &fx);
    try testing.expectEqualStrings("offchain.pub", model.scope_name());

    // An index the place does not have is refused rather than clamped: a menu
    // cannot produce one, so anything that does is a bug and should not be
    // quietly rounded into a different room.
    main.update(&model, main.Msg{ .place_feed = 9 }, &fx);
    try testing.expectEqual(@as(u8, 2), main.placeFeedIndexForTest());

    // Bounded like every other field a stranger fills.
    main.clearActivePlaceForTest();
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Greedy","hardcodedFeeds":[
        \\ {"name":"a","relays":["wss://a.example"]},{"name":"b","relays":["wss://b.example"]},
        \\ {"name":"c","relays":["wss://c.example"]},{"name":"d","relays":["wss://d.example"]},
        \\ {"name":"e","relays":["wss://e.example"]},{"name":"f","relays":["wss://f.example"]},
        \\ {"name":"g","relays":["wss://g.example"]}]}
    )) return error.NoPlace;
    try testing.expectEqual(@as(u8, 5), (main.activePlace() orelse return error.NoPlace).feeds_len);
}

test "the feed name is a switcher only when there is somewhere to go" {
    // A chevron beside a name that opens nothing is a promise the room cannot
    // keep.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    main.resetProfilesForTest();
    defer main.resetPlacesForTest();
    defer main.resetProfilesForTest();

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"One","hardcodedFeeds":[{"name":"Only","relays":["wss://a.example"]}]}
    )) return error.NoPlace;
    const single = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    if (single.frameOf("Choose feed") != null) return error.ChevronOnASingleFeed;

    main.clearActivePlaceForTest();
    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"Two","hardcodedFeeds":[
        \\ {"name":"First","relays":["wss://a.example"]},{"name":"Second","relays":["wss://b.example"]}]}
    )) return error.NoPlace;
    const several = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    if (several.frameOf("Choose feed") == null) return error.NoSwitcherWithSeveralFeeds;
}

test "a community's share gateway is checked before a reader is sent to it" {
    // This key is sharper than the relay URL beside it. A relay decides who the
    // app TALKS to; `baseShareURL` decides where the READER is sent, and a
    // place that set it to a convincing copy of njump would be a phishing page
    // one press away from any note.
    const gpa = testing.allocator;

    try testing.expect(main.isSafeShareUrl("https://njump.me/"));
    try testing.expect(main.isSafeShareUrl("https://basspistol.org/n/"));
    const refused = [_][]const u8{
        "http://njump.me/", // cleartext for a web page is a downgrade
        "https://", // nothing after the scheme
        "https://user:pass@evil.example/", // familiar-looking authority
        "https://njump.me/?to=evil.example", // a redirect smuggled in a query
        "https://njump.me/#evil", // or in a fragment
        "https://has space.example/",
        "https://has\nnewline.example/",
        "javascript:alert(1)",
    };
    for (refused) |url| {
        if (main.isSafeShareUrl(url)) {
            std.debug.print("accepted a share base it should refuse: {s}\n", .{url});
            return error.UnsafeShareUrlAccepted;
        }
    }

    // A refused one leaves the app's own gateway in place rather than half-
    // applying: "named nothing" and "named something unusable" are the same
    // outcome, which is the safe one.
    const bad = main.parsePlace(gpa,
        \\{"appName":"Sketchy","baseShareURL":"http://evil.example/","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    ) orelse return error.NoPlace;
    try testing.expectEqual(@as(u8, 0), bad.share_len);

    const good = main.parsePlace(gpa,
        \\{"appName":"BASSPISTOL","baseShareURL":"https://njump.me/","hardcodedFeeds":[{"relays":["wss://basspistol.org"]}]}
    ) orelse return error.NoPlace;
    try testing.expectEqualStrings("https://njump.me/", good.share());

    // The host is what the menu row says, so the reader sees the destination
    // before the press. That naming is the mitigation parsing cannot provide.
    try testing.expectEqualStrings("njump.me", main.shareHost("https://njump.me/"));
    try testing.expectEqualStrings("basspistol.org", main.shareHost("https://basspistol.org/n/"));
}

test "a feed's remembered notes do not leak into the feed beside it" {
    // Found reviewing the multi-feed work, not by a report, because it only
    // shows on the second feed of a place. `seen` is not the PLACE's notes, it
    // is that FEED's notes. Seeded blind, switching to "Outernational" paints
    // "The Dance"'s notes under its name until the relay answers, and the next
    // save writes that mixture down as if it belonged there.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    const gpa = testing.allocator;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    if (!main.visitParsedPlaceForTest(gpa,
        \\{"appName":"BASSPISTOL","hardcodedFeeds":[
        \\ {"name":"The Dance","relays":["wss://basspistol.org"]},
        \\ {"name":"Outernational","relays":["wss://nos.lol"]}]}
    )) return error.NoPlace;
    main.update(&model, .place_enter, &fx);

    // Notes arrive on the first feed and are remembered against it.
    var ids: [3][32]u8 = .{ @splat(1), @splat(2), @splat(3) };
    main.seedPlaceFeedForTest(&ids);
    main.savePlacesForTest();
    try testing.expectEqual(@as(u16, 3), main.keptPlaceSeenLenForTest(0));

    // Switching feeds must NOT bring them along.
    main.update(&model, main.Msg{ .place_feed = 1 }, &fx);
    if (main.placeFeedCount() != 0) {
        std.debug.print("the second feed opened holding {d} of the first feed's notes\n", .{main.placeFeedCount()});
        return error.RoomLeaked;
    }

    // Within a session the live list is the source of truth and a feed refills
    // from its own relay, so switching back does not replay them; `seen` is for
    // the RE-OPEN path. That path is where the leak would have been permanent,
    // so it is the one worth proving: re-entering from the rail seeds feed 0
    // with feed 0's notes.
    main.openKeptPlaceForTest(0);
    try testing.expectEqual(@as(u8, 0), main.placeFeedIndexForTest());
    if (main.placeFeedCount() != 3) {
        std.debug.print("re-opening the place lost its remembered room: {d} ids\n", .{main.placeFeedCount()});
        return error.RoomNotRemembered;
    }
}

test "a place keeps its character across a restart" {
    // The places file IS Hallway's document, one per line, so what is written
    // has to come back through the same parser meaning the same thing. Colour
    // and avatar shape were the fields most likely to be written and then
    // silently dropped, because nothing on screen would have said so until the
    // next launch.
    const gpa = testing.allocator;

    const original = main.parsePlace(gpa,
        \\{"appName":"BASSPISTOL","homeMarkdown":"# Rules\n\n- turn it up",
        \\ "defaultPrimaryColor":"YELLOW","avatarStyleDefault":"square",
        \\ "baseShareURL":"https://njump.me/",
        \\ "hardcodedFeeds":[{"name":"The Dance","relays":["wss://basspistol.org"],"kinds":[1,30311]},
        \\ {"name":"Outernational","relays":["wss://nos.lol"]}]}
    ) orelse return error.NoPlace;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try main.writePlaceDocumentForTest(gpa, &out, &original);

    const back = main.parsePlace(gpa, out.items) orelse return error.NoPlaceBack;
    try testing.expectEqualStrings(original.name(), back.name());
    try testing.expectEqualStrings(original.home(), back.home());
    const c = back.color orelse return error.ColourLost;
    try testing.expectEqualStrings("YELLOW", c.name);
    try testing.expect(back.square_avatars);
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 30311 }, back.feeds[0].kinds());
    try testing.expectEqualStrings("wss://basspistol.org", back.feeds[0].relay());
    // EVERY feed, not just the one the file used to write. A room that had two
    // came back with one, and nothing on screen would have said so.
    try testing.expectEqual(@as(u8, 2), back.feeds_len);
    try testing.expectEqualStrings("Outernational", back.feeds[1].name());
    try testing.expectEqualStrings("wss://nos.lol", back.feeds[1].relay());
    try testing.expectEqualStrings("https://njump.me/", back.share());
    try testing.expectEqual(original.seen_feed, back.seen_feed);

    // And a place with no character written down stays that way rather than
    // gaining a colour on the way through the file.
    const plain = main.parsePlace(gpa,
        \\{"appName":"Plain","hardcodedFeeds":[{"relays":["wss://a.example"]}]}
    ) orelse return error.NoPlace;
    var plain_out: std.ArrayList(u8) = .empty;
    defer plain_out.deinit(gpa);
    try main.writePlaceDocumentForTest(gpa, &plain_out, &plain);
    const plain_back = main.parsePlace(gpa, plain_out.items) orelse return error.NoPlaceBack;
    try testing.expect(plain_back.color == null);
    try testing.expect(!plain_back.square_avatars);
    try testing.expectEqual(@as(u8, 0), plain_back.feeds[0].kinds_len);
}

test "entering a place keeps it, and nothing else is gated on it" {
    // The correction that reshaped this feature: entering is about KEEPING a
    // place, not about permission. Somebody may enter, stay across restarts,
    // and never post; somebody else may read and post while only visiting.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const host = [_]u8{0x77} ** 32;
    main.visitPlaceForTest(host, "plaza-place-test", "Bass Pistol");

    // Visiting: you are in it, and it is not kept.
    try testing.expect(main.activePlace() != null);
    try testing.expect(!main.placeIsKept());
    try testing.expectEqual(@as(usize, 0), main.keptPlaceCount());

    main.update(&model, .place_enter, &fx);
    try testing.expect(main.placeIsKept());
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());

    // Entering twice is not two places. A link followed again while already
    // entered must not duplicate the row.
    main.update(&model, .place_enter, &fx);
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());

    // Leaving takes it out of the list AND out of the place.
    main.update(&model, .place_leave, &fx);
    try testing.expectEqual(@as(usize, 0), main.keptPlaceCount());
    try testing.expect(main.activePlace() == null);
    try testing.expect(!main.placeIsKept());
}

test "returning to a place already entered arrives kept, not visiting" {
    // The link works whether or not the place is in the list. Following it for
    // one already entered must not offer to enter it again.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const host = [_]u8{0x33} ** 32;
    main.visitPlaceForTest(host, "somewhere", "Somewhere");
    main.update(&model, .place_enter, &fx);
    try testing.expect(main.placeIsKept());

    // Walk out without leaving, then follow the link again.
    main.clearActivePlaceForTest();
    try testing.expect(main.activePlace() == null);
    main.visitPlaceForTest(host, "somewhere", "Somewhere");
    if (!main.placeIsKept()) {
        std.debug.print("a place already entered came back as visiting\n", .{});
        return error.KeptPlaceForgotten;
    }
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());
}

test "a place remembers what was in it, so returning is not an empty room" {
    // Reported: entering a place showed "Connecting to the relay pool" and
    // nothing else until a stranger's relay answered, which on a slow one is a
    // long time to stare at nothing. The rest of this app is local-first and a
    // place was not.
    //
    // The notes are already in the store from last visit. The only missing
    // piece was knowing WHICH of them belong to this place, because nothing
    // records the relay an event arrived on, so the ids ride with the place.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const host = [_]u8{0x5a} ** 32;
    main.visitPlaceForTest(host, "somewhere", "Somewhere");
    main.update(&model, .place_enter, &fx);

    // Notes arrive from the place's relay.
    var ids: [3][32]u8 = .{ @splat(1), @splat(2), @splat(3) };
    main.seedPlaceFeedForTest(&ids);
    try testing.expectEqual(@as(usize, 3), main.placeFeedCount());

    // The REAL save path has to carry them onto the kept entry, not a helper
    // called only by this test.
    main.savePlacesForTest();
    if (main.keptPlaceSeenLenForTest(0) != 3) {
        std.debug.print("saving did not remember the room: {d}\n", .{main.keptPlaceSeenLenForTest(0)});
        return error.NotRemembered;
    }

    // And the REAL entry path has to put them back before any socket answers.
    main.clearPlaceFeedForTest();
    try testing.expectEqual(@as(usize, 0), main.placeFeedCount());
    main.startPlaceFeedForTest(0);
    if (main.placeFeedCount() != 3) {
        std.debug.print("returned to an empty room: {d} ids\n", .{main.placeFeedCount()});
        return error.EmptyOnReturn;
    }
}

test "the room is written down while it is being read, not only when entered" {
    // The bug behind an empty room on relaunch: the file was written on Enter
    // and never again, and at that moment the place has no notes yet. So the
    // place was remembered and its contents never were.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    main.visitPlaceForTest([_]u8{0x6b} ** 32, "later", "Later");
    main.update(&model, .place_enter, &fx);
    try testing.expectEqual(@as(u16, 0), main.keptPlaceSeenLenForTest(0));

    // Notes arrive after entering, which is always.
    var ids: [2][32]u8 = .{ @splat(9), @splat(8) };
    main.seedPlaceFeedForTest(&ids);

    // Too soon: a flush every tick would rewrite the file constantly.
    main.flushPlaceIdsForTest(0);
    try testing.expectEqual(@as(u16, 0), main.keptPlaceSeenLenForTest(0));

    // Once the interval has passed, what is on screen is what is written down.
    main.flushPlaceIdsForTest(3600);
    if (main.keptPlaceSeenLenForTest(0) != 2) {
        std.debug.print("the room was never written down: {d}\n", .{main.keptPlaceSeenLenForTest(0)});
        return error.RoomNotFlushed;
    }

    // And it does not rewrite when nothing changed.
    main.setKeptPlaceSeenLenForTest(0, 0);
    main.flushPlaceIdsForTest(7200);
    try testing.expectEqual(@as(u16, 0), main.keptPlaceSeenLenForTest(0));
}

test "inside a place the feed is not called Following" {
    // It said "Following" under a place header, which is simply false: those
    // are not the reader's follows, which is the whole point of a room.
    const model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const own = model.scope_name();
    try testing.expect(std.mem.eql(u8, own, "Following") or std.mem.eql(u8, own, "Starter pack"));

    main.visitPlaceWithFeedForTest([_]u8{0x4d} ** 32, "somewhere", "Somewhere", "The relay");
    const inside = model.scope_name();
    if (std.mem.eql(u8, inside, "Following") or std.mem.eql(u8, inside, "Starter pack")) {
        std.debug.print("a place still calls its feed \"{s}\"\n", .{inside});
        return error.PlaceCalledFollowing;
    }
    try testing.expectEqualStrings("The relay", inside);

    // A place whose feed has no name of its own still must not borrow yours.
    main.visitPlaceForTest([_]u8{0x4e} ** 32, "nameless", "Nameless");
    try testing.expectEqualStrings("This place", model.scope_name());
}

test "a place says what its own connection is doing" {
    // The status bar counts the pool, and a place's relay is deliberately not
    // in it, so a place that is slow or unreachable looked exactly like a
    // connected one while the bar reported 5/5.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    try testing.expectEqual(main.PlaceLink.idle, main.placeLink());
    main.setPlaceLinkForTest(.connecting);
    try testing.expectEqual(main.PlaceLink.connecting, main.placeLink());

    // Walking out resets it, so the next place never inherits the last one's
    // failure.
    main.setPlaceLinkForTest(.unreachable_relay);
    main.clearPlaceFeedForTest();
    if (main.placeLink() != .idle) {
        std.debug.print("a new place inherited the last one's state: {t}\n", .{main.placeLink()});
        return error.StaleLinkState;
    }
}

/// Three places in the list, entered in order, and out of all of them.
fn seedPlacesForRail(model: *main.Model, fx: *main.EffectsForTest) void {
    main.visitPlaceForTest([_]u8{0xa1} ** 32, "one", "Bass Pistol");
    main.update(model, .place_enter, fx);
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "two", "Coldcard Hack");
    main.update(model, .place_enter, fx);
    main.visitPlaceForTest([_]u8{0xa3} ** 32, "three", "Sparc Noasis");
    main.update(model, .place_enter, fx);
    main.goToOwnPlazaForTest();
}

test "the places rail folds and comes back, and Home leaves it alone" {
    // Home hiding the switcher is what the first version did, and it made
    // coming back from your own feed to a room cost two presses. The rail is
    // the Places icon's to open and close, and nothing else touches it.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // Off until there is something to put in it.
    try testing.expect(!main.railOpen());

    main.togglePlacesRailForTest();
    try testing.expect(main.railOpen());
    main.togglePlacesRailForTest();
    try testing.expect(!main.railOpen());

    // Entering a place turns it on, because that is the moment it has a seat
    // to show.
    main.visitPlaceForTest([_]u8{0xe1} ** 32, "one", "Bass Pistol");
    main.update(&model, .place_enter, &fx);
    try testing.expect(main.railOpen());

    // And Home does not take it away again.
    main.goHomeForTest(&model);
    if (!main.railOpen()) return error.HomeFoldedTheSwitcher;
    try testing.expect(main.activePlace() == null);
}

test "Home closes the room without leaving the place" {
    // Two different verbs that were one button for as long as there was no rail
    // to put the place back on. Home means your own feed; the place stays.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    main.visitPlaceForTest([_]u8{0xb1} ** 32, "bass", "Bass Pistol");
    main.update(&model, .place_enter, &fx);
    try testing.expect(main.activePlace() != null);

    main.goHomeForTest(&model);
    if (main.activePlace() != null) return error.HomeStayedInTheRoom;
    if (main.keptPlaceCount() != 1) {
        std.debug.print("Home dropped the place from the list: {d} left\n", .{main.keptPlaceCount()});
        return error.HomeLeftThePlace;
    }

    // And the rail puts you straight back.
    main.openKeptPlaceForTest(0);
    try testing.expect(main.activePlace() != null);
    try testing.expect(main.placeIsKept());
}

test "a visit is not thrown away by pressing Home" {
    // A visit is deliberately not in the list, so once Home could close a room
    // there was nothing on the rail to get back to one. Peeking at your own
    // feed for a second destroyed the room you were reading.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    main.visitPlaceForTest([_]u8{0xc1} ** 32, "guest", "Somewhere");
    try testing.expect(!main.placeIsKept());

    var model = main.initialModel();
    main.goHomeForTest(&model);
    try testing.expect(main.activePlace() == null);
    if (main.visitingPlaceForTest() == null) return error.TheVisitWasLost;

    main.resumeVisitForTest();
    const back = main.activePlace() orelse return error.CouldNotGoBackToTheVisit;
    try testing.expectEqualStrings("Somewhere", back.name());
    // Still a visit. Going back into it is not the same as entering it.
    try testing.expect(!main.placeIsKept());
    try testing.expectEqual(@as(usize, 0), main.keptPlaceCount());
}

test "entering a place takes it out of the visiting seat" {
    // The seat is for a visit in progress. Once the place is in the list it has
    // a row of its own, and leaving the seat set would draw it twice: once
    // under Visiting and once under Entered.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    main.visitPlaceForTest([_]u8{0xd1} ** 32, "one", "Bass Pistol");
    main.goHomeForTest(&model);
    try testing.expect(main.visitingPlaceForTest() != null);

    main.resumeVisitForTest();
    main.update(&model, .place_enter, &fx);
    main.goHomeForTest(&model);
    if (main.visitingPlaceForTest() != null) return error.AnEnteredPlaceIsStillAVisit;
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());
}

test "reopening lands on the place that was open, not the last one entered" {
    // Restoring `g_places_len - 1` was right while entering was the only way
    // to be in a place. With a way out that is not leaving, "the last one
    // entered" and "the one I was looking at" came apart.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    seedPlacesForRail(&model, &fx);
    try testing.expectEqual(@as(usize, 3), main.keptPlaceCount());

    // Open the FIRST, which is not the last one entered.
    main.openKeptPlaceForTest(0);
    var buf: [160]u8 = undefined;
    const line = main.activePlaceLine(&buf);
    try testing.expect(line.len > 65);

    // The restart, as boot actually does it: the list is read back, the line
    // says which one, and the app opens it. Asserting on the index alone left
    // the decision itself untested, which a probe that put "the last one
    // entered" back walked straight through.
    main.applyActivePlaceLineForTest(line);
    main.goToOwnPlazaForTest();
    main.restoreOpenPlaceForTest();
    const landing = main.activePlaceIndexForTest() orelse return error.BootOpenedNoPlace;
    if (landing != 0) {
        std.debug.print("boot opened place {d}, not the one that was open (0)\n", .{landing});
        return error.BootOpenedTheWrongPlace;
    }

    // Home at quit means home at launch.
    main.goToOwnPlazaForTest();
    try testing.expectEqualStrings("", main.activePlaceLine(&buf));
    main.applyActivePlaceLineForTest("");
    main.restoreOpenPlaceForTest();
    if (main.activePlace() != null) return error.BootOpenedAPlaceNobodyWasIn;

    // Written by author and `d`, so a place leaving the list cannot hand its
    // index to whichever one slid into it.
    main.openKeptPlaceForTest(2);
    const third = main.activePlaceLine(&buf);
    var addr: [160]u8 = undefined;
    const third_len = third.len;
    @memcpy(addr[0..third_len], third);
    main.openKeptPlaceForTest(0);
    main.update(&model, .place_leave, &fx);
    main.applyActivePlaceLineForTest(addr[0..third_len]);
    const shifted = main.bootPlaceIndexForTest() orelse return error.BootLostThePlaceAfterALeave;
    try testing.expectEqual(@as(usize, 1), shifted);
}

test "stepping sideways out of a linked room closes its fetch window" {
    // The window stays open past the first copy so a place edited since your
    // last visit still reaches the room. It has to close when the reader walks
    // away, or the next tick drags them back into the room they just left.
    //
    // It read "walked out" as `g_place == null`, which is only the walk HOME.
    // Stepping sideways onto another rail row left it armed, and for the
    // fifteen ticks it lasts the linked place was re-applied over whatever the
    // reader picked: clicking a row on the rail did not stick.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // In the linked room, a copy already shown.
    main.visitPlaceForTest([_]u8{0xa1} ** 32, "moneroh", "Monero Hallway");
    main.armPlaceFetchForTest([_]u8{0xa1} ** 32, "moneroh");
    main.markPlaceFetchAppliedForTest();
    main.refreshPlaceFetchForTest();
    try testing.expect(main.placeFetchArmedForTest());

    // Sideways onto another room: the window has nothing left to watch.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.refreshPlaceFetchForTest();
    try testing.expect(!main.placeFetchArmedForTest());

    // And going home still closes it, which is the case that always worked.
    main.visitPlaceForTest([_]u8{0xa1} ** 32, "moneroh", "Monero Hallway");
    main.armPlaceFetchForTest([_]u8{0xa1} ** 32, "moneroh");
    main.markPlaceFetchAppliedForTest();
    main.clearActivePlaceForTest();
    main.refreshPlaceFetchForTest();
    try testing.expect(!main.placeFetchArmedForTest());
}
test "a link into another place does not inherit the room you are standing in" {
    // Reported as two places that could not be told apart: entering BASSPISTOL
    // and then following a link to Monero Hallway left the second room showing
    // the first one's notes, from the rail, across restarts.
    //
    // The arrival path asked "is a place open?" where it meant "is THIS place
    // open?", so a document for a different place was treated as a new edition
    // of the room being left. It took that room's remembered ids with it, and
    // they are saved, which is why it survived a quit.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    seedPlacesForRail(&model, &fx);

    // Stand in the first place with a room worth inheriting.
    main.openKeptPlaceForTest(0);
    const ids = [_][32]u8{ @splat(0xb1), @splat(0xb2), @splat(0xb3) };
    main.seedPlaceFeedForTest(&ids);
    main.savePlacesForTest();
    main.openKeptPlaceForTest(0);
    try testing.expectEqual(@as(u16, ids.len), main.keptPlaceSeenLenForTest(0));

    // A link to a DIFFERENT place: same host, and only `d` tells them apart.
    try testing.expectEqual(@as(u16, 0), main.arrivalInheritsRoomForTest([_]u8{0xa1} ** 32, "two"));
    // And a different host under the same `d`.
    try testing.expectEqual(@as(u16, 0), main.arrivalInheritsRoomForTest([_]u8{0xa2} ** 32, "one"));

    // A re-fetch of the place you ARE in still keeps the room, which is the
    // whole reason the carry-over exists: a fresh parse has an empty `seen`,
    // and re-seeding from it would blank the room mid-read.
    try testing.expectEqual(@as(u16, ids.len), main.arrivalInheritsRoomForTest([_]u8{0xa1} ** 32, "one"));
}

test "a link into another room closes the card and records where you are" {
    // The same two omissions on the path a reader actually takes: a plaza://
    // link followed while already standing in a room.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6c} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/doors.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    const there = [_]nostr.event.Tag{&.{ "d", "there" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &there,
        \\{"appName":"There","homeMarkdown":"# There"}
    , null);
    _ = try main.plazaIngestForTest(arena, ev);

    // Standing in another room, with the Leave confirmation armed on it.
    main.visitPlaceForTest([_]u8{0xf1} ** 32, "here", "Here");
    main.setPlaceInfoForTest(.leaving);
    const wrote_before = main.settingsWritesForTest();

    main.armPlaceFetchForTest(kp.public_key, "there");
    main.refreshPlaceFetchForTest();

    const now = main.activePlace() orelse return error.TheLinkOpenedNothing;
    try testing.expectEqualStrings("There", now.name());
    // Not still armed on a room the reader never asked to leave.
    if (main.placeInfo() == .leaving) return error.TheConfirmationFollowedTheLink;
    // The room left behind takes the rail's seat rather than vanishing.
    const seat = main.visitingPlaceForTest() orelse return error.NoSeat;
    try testing.expectEqualStrings("There", seat.name());
    // And where the reader is now is written down, so the next launch opens it.
    try testing.expect(main.settingsWritesForTest() > wrote_before);
}

test "a held note goes to the room it was written in" {
    // The pause before a note is sent exists so the reader can change their
    // mind, which means they are free to walk somewhere else while it counts.
    // The publish walk asked which room was open when it finally ran, on a
    // detached thread, so a note written in one community was published to
    // whichever one the reader had wandered into. With that place marked
    // "only these", the note reached nobody else at all.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x5a} ** 32);
    defer main.clearIdentityForTest();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    main.setPostDelayForTest(10);
    defer main.setPostDelayForTest(0);

    // Written inside a place that names its own relay.
    main.visitPlaceWithFeedForTest([_]u8{0xa9} ** 32, "loud", "Loud Room", "The Dance");
    main.setPlaceWriteRelayForTest("wss://loud.example.test");
    main.update(&model, .{ .draft_edit = .{ .insert_text = "written here" } }, &fx);
    main.update(&model, .post, &fx);

    // Pressed, held, and the reader walks into a different room while it counts.
    main.visitPlaceWithFeedForTest([_]u8{0xaa} ** 32, "quiet", "Quiet Room", "The Other");
    main.setPlaceWriteRelayForTest("wss://quiet.example.test");

    var held: [4][]const u8 = undefined;
    const n = main.heldRouteRelaysForTest(&held);
    if (n == 0) return error.TheHeldNoteForgotWhereItWasWritten;
    try testing.expectEqualStrings("wss://loud.example.test", held[0]);

    // And the room on screen now is a different answer, which is the whole
    // point: asking late gets you this one.
    var now: [4][]const u8 = undefined;
    const m = main.routeForOpenPlaceRelaysForTest(&now);
    try testing.expectEqual(@as(usize, 1), m);
    try testing.expectEqualStrings("wss://quiet.example.test", now[0]);
}
test "a visit keeps its seat when you step onto the rail" {
    // The rail holds ONE seat for the place being visited, because a visit is
    // deliberately not in the list and the seat is the only way back to it.
    // Only Home ever filled it. Stepping onto a rail row, or following a link
    // out of a visit, dropped the visit on the floor: nothing named it and no
    // list held it, so it was gone, which is the trap the seat exists to
    // prevent.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    seedPlacesForRail(&model, &fx);

    // Visiting a place that is NOT in the list, then stepping onto one that is.
    main.visitPlaceForTest([_]u8{0xd1} ** 32, "dropped", "Dropped Room");
    main.openKeptPlaceForTest(0);
    const seat = main.visitingPlaceForTest() orelse return error.TheVisitWasDropped;
    try testing.expectEqualStrings("Dropped Room", seat.name());

    // And it is still somewhere to go back to, which is the whole point of it.
    main.resumeVisitForTest();
    const back = main.activePlace() orelse return error.ResumedNowhere;
    try testing.expectEqualStrings("Dropped Room", back.name());
}

test "an armed Leave does not follow you into the next room" {
    // `g_place_info` is the info card, and `.leaving` is its red "Leave this
    // place?" confirmation. The card renders whichever place is active, so an
    // armed confirmation left standing retargets whatever arrives under it, and
    // the press that follows takes the WRONG room off the rail along with the
    // notes it remembered. Home and the rail both closed it; resuming a visit
    // did not.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    main.visitPlaceForTest([_]u8{0xe1} ** 32, "first", "First Room");
    main.goToOwnPlazaForTest();
    main.visitPlaceForTest([_]u8{0xe2} ** 32, "second", "Second Room");
    main.setPlaceInfoForTest(.leaving);

    // Back into the seated visit: a different room arrives under the card.
    main.resumeVisitForTest();
    const now = main.activePlace() orelse return error.ResumedNowhere;
    try testing.expectEqualStrings("First Room", now.name());
    if (main.placeInfo() == .leaving) return error.TheConfirmationFollowedTheReader;
}

test "walking the places goes both ways and wraps" {
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    seedPlacesForRail(&model, &fx);

    // From your own feed, forward is the first and back is the last.
    main.stepPlaceForTest(1);
    try testing.expectEqual(@as(?usize, 0), main.activePlaceIndexForTest());
    main.stepPlaceForTest(1);
    try testing.expectEqual(@as(?usize, 1), main.activePlaceIndexForTest());
    main.stepPlaceForTest(1);
    try testing.expectEqual(@as(?usize, 2), main.activePlaceIndexForTest());
    main.stepPlaceForTest(1);
    try testing.expectEqual(@as(?usize, 0), main.activePlaceIndexForTest());
    main.stepPlaceForTest(-1);
    try testing.expectEqual(@as(?usize, 2), main.activePlaceIndexForTest());

    // And it puts the rail where the eye is going to look.
    try testing.expect(main.railOpen());
}

test "the bounce goes out of the room and back into the same one" {
    // The key exists because a place is a ROOM: being in one hides your own
    // feed entirely, so the way out has to be as cheap as the way in, and the
    // way back must not land somewhere else.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    seedPlacesForRail(&model, &fx);
    main.openKeptPlaceForTest(1);

    main.bouncePlaceForTest();
    try testing.expect(main.activePlace() == null);

    main.bouncePlaceForTest();
    const landed = main.activePlaceIndexForTest() orelse return error.BounceLandedNowhere;
    if (landed != 1) {
        std.debug.print("the bounce came back into place {d}, not the one it left (1)\n", .{landed});
        return error.BounceLandedInTheWrongRoom;
    }
}
test "every place you have entered has a seat on the rail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // Empty first: the rail has to explain itself, because a link is the only
    // door v1 has and a blank column teaches nobody where to find one.
    main.setRailForTest(true);
    {
        const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
        var said_how = false;
        for (p.layout.nodes) |n| {
            if (std.mem.indexOf(u8, n.widget.text, "plaza://") != null) said_how = true;
        }
        if (!said_how) return error.TheEmptyRailSaysNothing;
    }

    seedPlacesForRail(&model, &fx);
    main.setRailForTest(true);
    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);

    // Three DISTINCT names, not three matching nodes. Counting matches let a
    // probe that drew place 0 three times pass: the same seat repeated is
    // exactly the failure this is here to catch.
    const wanted = [_][]const u8{ "Bass Pistol", "Coldcard Hack", "Sparc Noasis" };
    var seen = [_]bool{false} ** wanted.len;
    var still_empty = false;
    for (p.layout.nodes) |n| {
        for (wanted, 0..) |w, i| {
            if (std.mem.eql(u8, n.widget.text, w)) seen[i] = true;
        }
        if (std.mem.indexOf(u8, n.widget.text, "plaza://") != null) still_empty = true;
    }
    for (wanted, seen) |w, ok| {
        if (!ok) {
            std.debug.print("the rail drew no seat for \"{s}\"\n", .{w});
            return error.APlaceHasNoSeat;
        }
    }
    if (still_empty) return error.TheRailStillSaysItIsEmpty;

    // Folded away, it draws nothing at all: contents follow the selection, and
    // the one boolean beside it decides whether they are on screen.
    main.setRailForTest(false);
    const folded = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    for (folded.layout.nodes) |n| {
        if (std.mem.eql(u8, n.widget.text, "Bass Pistol")) return error.TheFoldedRailIsStillDrawn;
    }
}

test "the status bar does not call a place the starter pack" {
    // It lowered "Following" and returned "starter pack" for everything else,
    // which was safe while those were the only two scopes and became a lie the
    // moment a place could be one: the bar said "caught up, starter pack" under
    // a header naming somebody else's room.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    try testing.expectEqualStrings("following", main.lowerScopeForTest("Following"));
    try testing.expectEqualStrings("starter pack", main.lowerScopeForTest("Starter pack"));
    try testing.expectEqualStrings("The relay", main.lowerScopeForTest("The relay"));

    var model = main.initialModel();
    model.notes_len = 3;
    main.visitPlaceWithFeedForTest([_]u8{0xf1} ** 32, "bass", "Bass Pistol", "The relay");
    const line = model.caught_up(arena_state.allocator());
    if (std.mem.indexOf(u8, line, "starter pack") != null) {
        std.debug.print("the status bar says \"{s}\" inside a place\n", .{line});
        return error.ThePlaceIsCalledTheStarterPack;
    }
    try testing.expectEqualStrings("Caught up · The relay · 3 notes", line);
}

test "a place whose notes are already stored still fills" {
    // The report: open the app with no places entered, follow a link to one you
    // have been in before, and it sits on "Connecting" forever while its relay
    // is connected and answering. Enter it and restart, and it works.
    //
    // The cause was one level above the rebuild. A place's notes arrive on its
    // own socket and are ingested like anything else, so a room the reader has
    // never seen fires the store-count check and fills. A room they HAVE seen
    // does not: every note is a duplicate, the count never moves, and the tick
    // decides there is nothing to do without ever asking the place. Restarting
    // hid it, because boot's first tick is stale for other reasons anyway.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5b} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/place-stale.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    main.resetPlacesForTest();
    main.resetProfilesForTest();
    defer main.resetPlacesForTest();
    defer main.resetProfilesForTest();
    defer main.setStoreForTest(null);

    // Everything the place will send is ALREADY in the store, which is the
    // whole point: this is a room the reader has been in before.
    var ids: [3][32]u8 = undefined;
    for (0..3) |i| {
        const ev = try signedNote(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), "a note from the room");
        _ = try store.ingest(arena, ev, .{});
        ids[i] = ev.id;
    }

    // A tick with no place, so the store count is settled and the next one
    // cannot ride in on it.
    var model = main.initialModel();
    model.stage = .ready;
    main.refreshForTest(&model, &store, 1_800_000_100);
    main.refreshForTest(&model, &store, 1_800_000_100);

    // Now visit, and let the place's socket deliver. Nothing new reaches the
    // store, so the revision counter is the only thing that says so.
    main.visitPlaceWithFeedForTest([_]u8{0x5c} ** 32, "room", "Bass Pistol", "The relay");
    main.seedPlaceFeedForTest(&ids);
    main.refreshForTest(&model, &store, 1_800_000_100);

    if (model.notes_len == 0) {
        std.debug.print("the place stayed empty: \"{s}\"\n", .{model.empty_text()});
        return error.ThePlaceNeverFilled;
    }
    try testing.expectEqual(@as(usize, 3), model.notes_len);
}

test "an empty place says what its own relay is doing, not the pool's" {
    // A place's relay is deliberately outside the eight, so "Connecting to the
    // relay pool" under a place header describes a connection that has nothing
    // to do with the empty screen it is explaining.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    var model = main.initialModel();
    try testing.expectEqualStrings("Connecting to the relay pool…", model.empty_text());

    main.visitPlaceWithFeedForTest([_]u8{0x5d} ** 32, "room", "Bass Pistol", "The relay");
    main.setPlaceLinkForTest(.connecting);
    try testing.expectEqualStrings("Connecting to this place…", model.empty_text());

    main.setPlaceLinkForTest(.unreachable_relay);
    const failed = model.empty_text();
    if (std.mem.indexOf(u8, failed, "pool") != null) {
        std.debug.print("an unreachable place blames the pool: \"{s}\"\n", .{failed});
        return error.ThePlaceBlamedThePool;
    }

    main.setPlaceLinkForTest(.connected);
    try testing.expectEqualStrings("Nothing here yet.", model.empty_text());
}

test "a place whose relay closes the feed says so, rather than that it is empty" {
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    main.visitPlaceWithFeedForTest([_]u8{0x5e} ** 32, "gated", "Members Only", "The relay");
    main.setPlaceLinkForTest(.connected);

    // Another subscription's CLOSED is not the room's.
    try testing.expectEqualStrings("more", main.placeFeedStepForTest(false, closedMsg("plaza-feed", "auth-required: no")));
    try testing.expectEqual(main.PlaceLink.connected, main.placeLink());

    // A relay that wants to know who the reader is. The worker stops, and the
    // room says that instead of "Nothing here yet."
    try testing.expectEqualStrings("done", main.placeFeedStepForTest(false, closedMsg("plaza-place", "auth-required: members only")));
    try testing.expectEqual(main.PlaceLink.refused, main.placeLink());
    try testing.expectEqualStrings("This place's relay wants to know who you are before it shows anything.", model.empty_text());
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(tree.root, "wants to know who you are"));
    try testing.expect(findAnyTextContaining(tree.root, "feed closed by its relay"));

    // Any other reason is shown as the relay gave it, without its control bytes.
    main.setPlaceLinkForTest(.connected);
    _ = main.placeFeedStepForTest(false, closedMsg("plaza-place", "error: shutting\x07down\n"));
    try testing.expectEqualStrings("This place's relay closed its feed: error: shutting down", model.empty_text());
    main.setPlaceLinkForTest(.connected);
    _ = main.placeFeedStepForTest(false, closedMsg("plaza-place", ""));
    try testing.expectEqualStrings("This place's relay closed its feed without saying why.", model.empty_text());

    // A worker for a room already left paints nothing.
    main.setPlaceLinkForTest(.connected);
    _ = main.placeFeedStepForTest(true, closedMsg("plaza-place", "auth-required: x"));
    try testing.expectEqual(main.PlaceLink.connected, main.placeLink());
}

test "a smaller line is asked for by its size, not by scaling every span" {
    // A paragraph's line box and baseline come from `size * max(1, largest span
    // scale)`. The floor of 1 means a paragraph whose spans are ALL scaled DOWN
    // keeps a full-size baseline in a full-size box: 13.5pt text drawn on a
    // 14.5pt baseline inside an 18.125pt box. A point lower than the text
    // around it, with a point and a quarter of extra air above, which is what
    // the reply-context line looked like next to the note it belongs to.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.resetPlacesForTest();
    main.resetProfilesForTest();
    defer main.resetPlacesForTest();
    defer main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest("");
    const body = "hop on @primal august workout challenge.";
    const b = @min(body.len, model.notes[0].content_buf.len);
    @memcpy(model.notes[0].content_buf[0..b], body[0..b]);
    model.notes[0].content_len = @intCast(b);
    model.notes[0].reply_parent = [_]u8{0x42} ** 32;
    model.notes[0].has_reply_parent = true;
    model.notes_len = 1;
    main.seedQuoteForTest([_]u8{0x42} ** 32, [_]u8{0x31} ** 32, 1_800_000_000, "the note being answered");

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);

    // Every run of the context line, by the size it actually draws at.
    var line_y: ?f32 = null;
    var runs: usize = 0;
    for (p.commands) |c| switch (c) {
        .draw_text => |t| {
            const mine = std.mem.indexOf(u8, t.text, "reply to") != null or
                std.mem.indexOf(u8, t.text, "being answered") != null;
            if (!mine) continue;
            runs += 1;
            // 13.5, the `.sm` token, NOT 14.5 scaled down to look like it.
            try testing.expectApproxEqAbs(@as(f32, 13.5), t.size, 0.001);
            // Both runs of the line share one baseline, whatever their weight.
            if (line_y) |y| {
                if (@abs(y - t.origin.y) > 0.001) {
                    std.debug.print("the context line draws runs at y={d:.3} and y={d:.3}\n", .{ y, t.origin.y });
                    return error.RunsOffTheirSharedBaseline;
                }
            } else line_y = t.origin.y;
        },
        else => {},
    };
    if (runs < 2) return error.TheContextLineNeverDrewBothRuns;

    // And the box is the height that size needs: 13.5 * 1.25, not 14.5 * 1.25.
    var boxed = false;
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, "reply to") == null) continue;
        boxed = true;
        if (@abs(n.widget.frame.height - 16.875) > 0.01) {
            std.debug.print(
                "the context line reserves {d:.3}pt for 13.5pt text (16.875 is its own height)\n",
                .{n.widget.frame.height},
            );
            return error.TheLineIsBoxedForATextItDoesNotDraw;
        }
    }
    try testing.expect(boxed);

    // The body around it is untouched: full size, one baseline across the
    // plain text and the mention that sits in the middle of it.
    var body_y: ?f32 = null;
    for (p.commands) |c| switch (c) {
        .draw_text => |t| {
            const mine = std.mem.eql(u8, t.text, "hop on ") or
                std.mem.eql(u8, t.text, "@primal") or
                std.mem.eql(u8, t.text, " august workout challenge.");
            if (!mine) continue;
            try testing.expectApproxEqAbs(@as(f32, 14.5), t.size, 0.001);
            if (body_y) |y| try testing.expectApproxEqAbs(y, t.origin.y, 0.001) else body_y = t.origin.y;
        },
        else => {},
    };
    try testing.expect(body_y != null);
}
test "a place says what it is behind one control, and leaving takes two presses" {
    // The host's markdown used to sit inline above the feed on every visit,
    // which is a wall of somebody else's words in front of the thing it is
    // selling. And Leave sat in the header a few pixels from Enter, where one
    // press did it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    main.resetProfilesForTest();
    defer main.resetPlacesForTest();
    defer main.resetProfilesForTest();

    const about = "House rules: be interesting, or be quiet.";
    main.visitPlaceWithFeedForTest([_]u8{0x81} ** 32, "bass", "Bass Pistol", "The relay");
    main.setPlaceHomeForTest(about);
    main.update(&model, .place_enter, &fx);

    // Nothing of the host's text over the feed, and no Leave within reach.
    const closed = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    if (paintsText(closed, about)) return error.TheDescriptionIsBackOverTheFeed;
    if (paintsText(closed, "Leave")) return error.LeaveIsOnePressAway;
    try testing.expect(paintsText(closed, "Info"));

    // Info says what this place is, who hosts it and where it reads from.
    main.update(&model, .open_place_info, &fx);
    const open = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    if (!paintsText(open, about)) return error.InfoDidNotShowTheDescription;
    try testing.expect(paintsText(open, "Host"));
    try testing.expect(paintsText(open, "The relay"));
    try testing.expect(paintsText(open, "Leave"));

    // The first Leave asks. It must not have left yet.
    main.update(&model, .place_leave_request, &fx);
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());
    const asking = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, main.window_height);
    if (!paintsText(asking, "Leave this place?")) return error.LeavingNeverAsked;
    try testing.expect(paintsText(asking, "Cancel"));

    // Backing out changes nothing.
    main.update(&model, .place_leave_cancel, &fx);
    try testing.expectEqual(@as(usize, 1), main.keptPlaceCount());
    try testing.expectEqual(main.PlaceInfo.open, main.placeInfo());

    // The second one does it, and takes the card down with it.
    main.update(&model, .place_leave_request, &fx);
    main.update(&model, .place_leave, &fx);
    try testing.expectEqual(@as(usize, 0), main.keptPlaceCount());
    try testing.expect(main.activePlace() == null);
    try testing.expectEqual(main.PlaceInfo.closed, main.placeInfo());
}

/// Whether any text node on the page carries this string.
fn paintsText(p: painted.Painted, needle: []const u8) bool {
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, needle) != null) return true;
    }
    return false;
}

test "logging out takes your places with you" {
    // Which communities somebody belongs to is sensitive, which is the whole
    // reason the list is a file on their own disk rather than an event on a
    // relay. That is also what made it outlive a logout: a relay-backed list
    // goes when the key does, and a file does not go until something deletes
    // it. The next account to sign in on this Mac inherited the last one's
    // rail, fully populated, opened straight into whichever place they had been
    // reading.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    main.setIdentityForTest([_]u8{0x91} ** 32);
    defer main.clearIdentityForTest();

    main.visitPlaceForTest([_]u8{0x92} ** 32, "one", "Bass Pistol");
    main.update(&model, .place_enter, &fx);
    main.visitPlaceForTest([_]u8{0x93} ** 32, "two", "The Pleb Table");
    main.update(&model, .place_enter, &fx);
    try testing.expectEqual(@as(usize, 2), main.keptPlaceCount());
    try testing.expect(main.activePlace() != null);
    try testing.expect(main.railOpen());

    // A visit in the seat too, so the session-only half is covered.
    main.goToOwnPlazaForTest();
    main.visitPlaceForTest([_]u8{0x94} ** 32, "three", "Somewhere");
    main.goToOwnPlazaForTest();
    try testing.expect(main.visitingPlaceForTest() != null);

    // A note held on the near side of its signature goes too (plaza#330). It
    // waits there precisely so it can still be taken back, and a session ending
    // is the clearest instance of taking it back. Asserted here rather than in
    // its own test because `performLogout` resets a great deal of process-wide
    // state that later tests read, and this test already accounts for that.
    main.holdPostForTest(1_800_000_000);
    try testing.expect(main.postHeldForTest());

    main.performLogoutForTest(&model, &fx);
    try testing.expect(!main.postHeldForTest());

    if (main.keptPlaceCount() != 0) {
        std.debug.print("the next account inherits {d} places\n", .{main.keptPlaceCount()});
        return error.ThePlacesOutlivedTheAccount;
    }
    if (main.activePlace() != null) return error.StillInsideTheLastAccountsPlace;
    if (main.visitingPlaceForTest() != null) return error.TheVisitOutlivedTheAccount;
    // And nothing on disk points the next launch back into one.
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("", main.activePlaceLine(&buf));
    try testing.expect(main.bootPlaceIndexForTest() == null);
    // The rail folds, because an empty rail that is still out is a column
    // saying the previous reader had none.
    try testing.expect(!main.railOpen());
}
test "relay hints are gated, deduped and capped before anything dials them" {
    var h: main.RelayHints = .{};
    h.fill(&.{
        "wss://first.example",
        "wss://first.example", // the same relay twice would spend both slots on one socket
        "ws://cleartext.example", // not wss, so not dialled
        "wss://second.example",
        "wss://third.example", // past the cap
    });
    try testing.expectEqual(@as(u8, 2), h.count);
    try testing.expectEqualStrings("wss://first.example", h.at(0));
    try testing.expectEqualStrings("wss://second.example", h.at(1));
    try testing.expect(!h.isEmpty());

    // Nothing usable in, nothing kept: the fetch then asks the pool and only
    // the pool, which is exactly what it did before hints existed.
    var none: main.RelayHints = .{};
    none.fill(&.{ "http://example.com", "not a url", "" });
    try testing.expectEqual(@as(u8, 0), none.count);
    try testing.expect(none.isEmpty());
}

test "a quoted nevent's relay hints never send this machine to its own network" {
    // An `nevent1` in a note can name any relay, and its hints are dialled with
    // nobody pressing anything: the quote card asks as the note scrolls into
    // view. A hostile note naming a loopback or a LAN address would make every
    // reader's machine knock on its own network. The cleartext forms were already
    // refused for not being wss; the wss forms of the same places got through.
    const private = [_][]const u8{
        "ws://127.0.0.1",         "ws://localhost",        "ws://192.168.1.20",    "ws://10.0.0.7",
        "wss://127.0.0.1",        "wss://localhost",       "wss://192.168.1.20",   "wss://10.0.0.7",
        "wss://[::1]",            "wss://127.0.0.1:7777/", "wss://localhost:4848", "wss://172.16.0.9",
        "wss://relay.home.local", "wss://router.lan",
    };
    const public = "wss://relay.public.example";

    // One at a time, so a refusal is not just the cap of two filling up.
    for (private) |url| {
        var h: main.RelayHints = .{};
        h.fill(&.{url});
        if (!h.isEmpty()) {
            std.debug.print("\nkept a private relay hint: {s}\n", .{url});
            return error.PrivateHintKept;
        }
    }

    // And all together ahead of a public one: none of them takes one of the
    // two slots, so the relay that can actually answer still gets dialled.
    var mixed: [private.len + 1][]const u8 = undefined;
    for (private, 0..) |url, i| mixed[i] = url;
    mixed[private.len] = public;
    var h: main.RelayHints = .{};
    h.fill(&mixed);
    try testing.expectEqual(@as(u8, 1), h.count);
    try testing.expectEqualStrings(public, h.at(0));

    // The same through the quote cache, which is what the card's fetch dials.
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    const id = [_]u8{0x5d} ** 32;
    main.wantQuoteHintedForTest(id, &mixed);
    const kept = main.quoteHintsForTest(id);
    try testing.expectEqual(@as(u8, 1), kept.count);
    try testing.expectEqualStrings(public, kept.at(0));
}
test "an address for a place nobody has says it is looking, then that it did not turn up" {
    // Paste an naddr for a place no relay holds and Plaza said nothing at all:
    // the field closed, the feed stayed the feed, and a missing note, one
    // field over, toasts twice. Silence reads as a paste that did not take.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("nobody");
    defer f.down();

    const host = [_]u8{0x3c} ** 32;
    f.paste(try nostr.nip19.encodeNaddr(arena, "ghost-town", host, main.place_kind_for_test, &.{}));
    try testing.expect(main.placeFetchArmedForTest());
    try testing.expectEqualStrings("Looking for that place", f.model.toast_text());

    // The whole window, with nothing ever arriving. The paste took one look
    // itself, so fourteen more ticks leave it still waiting.
    for (0..14) |_| main.refreshPlaceFetchNoticeForTest(&f.model);
    try testing.expect(main.placeFetchArmedForTest());
    try testing.expectEqualStrings("Looking for that place", f.model.toast_text());

    // One past it, and the reader is told. Without this the window closed with
    // no word and the toast above simply timed out.
    main.refreshPlaceFetchNoticeForTest(&f.model);
    try testing.expect(!main.placeFetchArmedForTest());
    try testing.expectEqualStrings("That place did not turn up.", f.model.toast_text());
    try testing.expect(main.activePlace() == null);
}

test "a plaza link leaves Settings and the notifications sheet, and says it is looking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("linkover");
    defer f.down();
    defer main.forgetPlaceFetchForTest();
    const host = [_]u8{0x3e} ** 32;
    var link_buf: [512]u8 = undefined;
    const naddr = try nostr.nip19.encodeNaddr(arena, "linked-room", host, main.place_kind_for_test, &.{});
    const link = try std.fmt.bufPrint(&link_buf, "plaza://place/{s}", .{naddr});

    // Clicked while Settings is open: the room would arrive under it.
    main.update(&f.model, .open_settings, &f.fx);
    try testing.expect(f.model.stage == .settings);
    main.captureArgvLinkForTest(link);
    main.drainPendingLinkForTest(&f.model, &f.fx);
    try testing.expect(main.placeFetchArmedForTest());
    try testing.expect(f.model.stage == .ready);
    try testing.expectEqualStrings("Looking for that place", f.model.toast_text());

    // Clicked with the notifications sheet up.
    main.resetPlacesForTest();
    f.model.notifications_open = true;
    f.model.toast_len = 0;
    main.captureArgvLinkForTest(link);
    main.drainPendingLinkForTest(&f.model, &f.fx);
    try testing.expect(!f.model.notifications_open);
    try testing.expect(!f.model.notifications_return);
    try testing.expectEqualStrings("Looking for that place", f.model.toast_text());

    // Clicked while a profile is being edited: it waits for the sheet, which
    // keeps what was typed in it.
    main.resetPlacesForTest();
    main.forgetPlaceFetchForTest();
    main.update(&f.model, .open_settings, &f.fx);
    f.model.editing_profile = true;
    main.captureArgvLinkForTest(link);
    main.drainPendingLinkForTest(&f.model, &f.fx);
    try testing.expect(!main.placeFetchArmedForTest());
    try testing.expect(f.model.stage == .settings and f.model.editing_profile);
    f.model.editing_profile = false;
    main.drainPendingLinkForTest(&f.model, &f.fx);
    try testing.expect(main.placeFetchArmedForTest());
    try testing.expect(f.model.stage == .ready);
}

test "a place that turns up retires the looking toast" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("lateplace");
    defer f.down();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x40} ** 32);
    f.paste(try nostr.nip19.encodeNaddr(arena, "late-room", kp.public_key, main.place_kind_for_test, &.{}));
    try testing.expectEqualStrings("Looking for that place", f.model.toast_text());

    // It lands a moment later, as a relay's answer does.
    const tags = [_]nostr.event.Tag{&.{ "d", "late-room" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags,
        \\{"appName":"Late Room","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, ev);
    main.refreshPlaceFetchNoticeForTest(&f.model);
    try testing.expect(main.activePlace() != null);
    try testing.expectEqualStrings("", f.model.toast_text());
}

test "an address whose event is not a place says so instead of staying silent" {
    // Kind 30078 is app-specific data, so a stranger's event under the same
    // pubkey and `d` can hold anything. Parsing failed, the window closed, and
    // that was the whole of the answer.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("notaplace");
    defer f.down();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3d} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "d", "not-json" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags, "this is not a place", null);
    _ = try main.plazaIngestForTest(arena, ev);

    f.paste(try nostr.nip19.encodeNaddr(arena, "not-json", kp.public_key, main.place_kind_for_test, &.{}));
    try testing.expectEqualStrings("That address does not describe a place.", f.model.toast_text());
    try testing.expect(!main.placeFetchArmedForTest());
    try testing.expect(main.activePlace() == null);
}

test "an address for a place already held opens it without a looking toast" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("held");
    defer f.down();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3e} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "d", "held-room" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags,
        \\{"appName":"Held Room","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, ev);

    f.paste(try nostr.nip19.encodeNaddr(arena, "held-room", kp.public_key, main.place_kind_for_test, &.{}));
    try testing.expect(main.activePlace() != null);
    try testing.expectEqualStrings("", f.model.toast_text());
}

test "an address for the room already open does not say it is looking" {
    // The window only watches for a newer copy then, so "Looking for that
    // place" over the room it names describes a search that is not happening.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("sameroom");
    defer f.down();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x41} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "d", "same-room" }};
    const ev = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags,
        \\{"appName":"Same Room","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, ev);

    const addr = try nostr.nip19.encodeNaddr(arena, "same-room", kp.public_key, main.place_kind_for_test, &.{});
    f.paste(addr);
    try testing.expect(main.activePlace() != null);
    f.paste(addr);
    try testing.expect(main.activePlace() != null);
    try testing.expectEqualStrings("", f.model.toast_text());
}

test "a later copy of the open room that is not a place leaves the room alone" {
    // The address was a place, and the reader is in it. A newer edition that
    // does not parse is the host's mistake, not a wrong address, and the room
    // on screen is still the place the address names.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("brokenedit");
    defer f.down();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x42} ** 32);
    const tags = [_]nostr.event.Tag{&.{ "d", "edited-room" }};
    const good = try nostr.event.create(arena, signer, kp, 1000, 30078, &tags,
        \\{"appName":"Edited Room","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    , null);
    _ = try main.plazaIngestForTest(arena, good);
    f.paste(try nostr.nip19.encodeNaddr(arena, "edited-room", kp.public_key, main.place_kind_for_test, &.{}));
    try testing.expect(main.activePlace() != null);

    const broken = try nostr.event.create(arena, signer, kp, 2000, 30078, &tags, "not a place any more", null);
    _ = try main.plazaIngestForTest(arena, broken);
    main.refreshPlaceFetchNoticeForTest(&f.model);
    try testing.expect(main.activePlace() != null);
    try testing.expectEqualStrings("", f.model.toast_text());
}
test "a place with no feed says so instead of connecting forever" {
    // A place document with no `hardcodedFeeds` has nothing to dial, so no
    // socket ever opens and no result ever comes back. The empty state read
    // "Connecting to this place…" for as long as the room stayed open.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    try testing.expect(main.visitParsedPlaceForTest(arena,
        \\{"appName":"No Feeds Place","homeMarkdown":"Nothing to read here."}
    ));
    main.update(&model, .place_enter, &fx);
    main.startPlaceFeedForTest(0);
    try testing.expectEqual(main.PlaceLink.no_feed, main.placeLink());
    try testing.expectEqualStrings("This place has no feed to read.", model.empty_text());

    // A feed that names a relay is a wait, not an absence.
    main.resetPlacesForTest();
    try testing.expect(main.visitParsedPlaceForTest(arena,
        \\{"appName":"Has Feed","hardcodedFeeds":[{"name":"Feed","relays":["wss://a.example"]}]}
    ));
    main.update(&model, .place_enter, &fx);
    main.startPlaceFeedForTest(0);
    try testing.expect(main.placeLink() != .no_feed);
    try testing.expectEqualStrings("Connecting to this place…", model.empty_text());
}

test "a feed worker for a room already left does not paint the next one as connecting" {
    // Click from a room with a feed into one with none, and the first room's
    // worker could wake after the second had said it has no feed, write
    // "connecting" over it, and leave it there for good.
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    main.setPlaceLinkForTest(.no_feed);
    main.runStalePlaceFeedWorkerForTest();
    try testing.expectEqual(main.PlaceLink.no_feed, main.placeLink());
}

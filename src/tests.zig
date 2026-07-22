const std = @import("std");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

/// Builds the real view for `model`: the same root the app runs, so a test sees
/// the markup screens (compiled in) and the hand-written feed exactly as shipped.
fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var ui = AppUi.init(arena);
    const node = main.appView(&ui, model);
    if (ui.failed) return error.ViewBuild;
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// How many note rows the tree actually built (the windowed list materialises
/// only the rows near the viewport). Each note row has exactly one avatar, so
/// avatars are the stable per-row marker now that the rows are not cards.
fn countNoteRows(widget: canvas.Widget) usize {
    var n: usize = if (widget.kind == .avatar) 1 else 0;
    for (widget.children) |child| n += countNoteRows(child);
    return n;
}

/// Like `findByText`, but matches on text content regardless of widget kind.
fn findAnyText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findAnyText(child, text)) |found| return found;
    }
    return null;
}

/// A signed kind:1 note with the given timestamp and content.
fn signedNote(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, created_at: i64, content: []const u8) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, 1, &.{}, content, null);
}

test "first run shows the onboarding welcome, not the feed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Default stage is onboarding (a fresh install with no identity on disk).
    var model = main.initialModel();
    const tree = try buildTree(arena, &model);

    try testing.expect(findAnyText(tree.root, "Welcome to Nostr") != null);
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    // The sign-in paths (import a key or connect a signer) share one field with a
    // Continue action.
    try testing.expect(findAnyText(tree.root, "Continue") != null);
    // The feed's connecting header does not show on the welcome screen.
    try testing.expect(findAnyText(tree.root, "Connecting…") == null);
}

test "login text is classified by prefix" {
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("nsec1abcdef"));
    try testing.expectEqual(main.LoginTarget.bunker, main.classifyLogin("bunker://pubkey?relay=wss://r"));
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("  nsec1withspace  "));
    // An npub (read-only) is not a sign-in path yet, nor is arbitrary text.
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("npub1abcdef"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("hello"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin(""));
}

test "the settings screen shows the identity, key backup, and logout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    try testing.expect(findByText(tree.root, .text, "Settings") != null);
    try testing.expect(findAnyText(tree.root, "Signed in as") != null);
    // Default signer kind is a local key, so the key-backup card and its reveal
    // control render.
    try testing.expect(findAnyText(tree.root, "Local key") != null);
    try testing.expect(findAnyText(tree.root, "Reveal secret key") != null);
    // The logout entry point is present; the confirmation is not yet.
    try testing.expect(findAnyText(tree.root, "Log out") != null);
    try testing.expect(findAnyText(tree.root, "Cancel") == null);
    // The version line renders.
    try testing.expect(findAnyText(tree.root, "Plaza 0.1.0") != null);
}

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

test "plain content passes through renderContent unchanged" {
    var buf: [220]u8 = undefined;
    const src = "just a normal note with a https://example.com link";
    const n = main.renderContent(&buf, src, "");
    try testing.expectEqualStrings(src, buf[0..n]);
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

test "image links are recognised by extension only" {
    try testing.expect(main.firstImageUrl("https://x.com/a.png") != null);
    try testing.expect(main.firstImageUrl("https://x.com/a.JPEG") != null);
    try testing.expect(main.firstImageUrl("https://x.com/a.gif?v=2") != null);
    // A plain link, a non-image file, and bare text are not images.
    try testing.expect(main.firstImageUrl("https://example.com/page") == null);
    try testing.expect(main.firstImageUrl("https://x.com/clip.mp4") == null);
    try testing.expect(main.firstImageUrl("no links here") == null);
    // The first of several wins.
    try testing.expectEqualStrings(
        "https://a.com/1.png",
        main.firstImageUrl("see https://a.com/1.png and https://b.com/2.png").?,
    );
}

test "media URLs route through the proxy, the host, or neither" {
    const saved = main.mediaProxy();
    var saved_buf: [200]u8 = undefined;
    @memcpy(saved_buf[0..saved.len], saved);
    const saved_len = saved.len;
    defer main.setMediaProxy(saved_buf[0..saved_len]);

    var buf: [1024]u8 = undefined;

    // With a proxy configured, the source is percent-encoded into it.
    main.setMediaProxy("https://wsrv.nl/");
    const proxied = main.mediaUrl(&buf, "https://host.example/a b.jpg", 512, .inside);
    try testing.expect(std.mem.startsWith(u8, proxied, "https://wsrv.nl/?url="));
    try testing.expect(std.mem.indexOf(u8, proxied, "https%3A%2F%2Fhost.example%2Fa%20b.jpg") != null);
    try testing.expect(std.mem.indexOf(u8, proxied, "w=512") != null);

    // Avatars ask for a square crop at their own size.
    const square = main.mediaUrl(&buf, "https://host.example/a.jpg", 128, .square);
    try testing.expect(std.mem.indexOf(u8, square, "fit=cover") != null);
    try testing.expect(std.mem.indexOf(u8, square, "h=128") != null);

    // A host that resizes for itself skips the proxy entirely.
    const native_resize = main.mediaUrl(&buf, "https://blossom.nostr.build/abc.jpg", 512, .inside);
    try testing.expectEqualStrings("https://blossom.nostr.build/abc.jpg?w=512", native_resize);

    // No proxy configured: load the original, untouched.
    main.setMediaProxy("");
    const direct = main.mediaUrl(&buf, "https://host.example/a.jpg", 512, .inside);
    try testing.expectEqualStrings("https://host.example/a.jpg", direct);
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

test "note text splits into link, mention, and plain runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "hi @alice see https://example.com/x ok");
    try testing.expectEqual(@as(usize, 5), spans.len);
    // The mention and the link are accented; only the link is pressable.
    try testing.expectEqualStrings("@alice", spans[1].text);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len);
    try testing.expectEqualStrings("https://example.com/x", spans[3].text);
    try testing.expectEqualStrings("https://example.com/x", spans[3].link);
    try testing.expect(spans[3].underline);
    // Plain text has no link payload.
    try testing.expectEqual(@as(usize, 0), spans[0].link.len);
}

test "only plain http(s) links are handed to the opener" {
    try testing.expect(main.isSafeExternalUrl("https://example.com/a"));
    try testing.expect(main.isSafeExternalUrl("http://example.com"));
    // Anything that is not a plain web URL, or that could be read as a flag or
    // carry control bytes, is refused.
    try testing.expect(!main.isSafeExternalUrl("file:///etc/passwd"));
    try testing.expect(!main.isSafeExternalUrl("-a/Applications/Calculator.app"));
    try testing.expect(!main.isSafeExternalUrl("nostr:npub1abc"));
    try testing.expect(!main.isSafeExternalUrl("https://example.com/a b"));
    try testing.expect(!main.isSafeExternalUrl("https://example.com/a\nb"));
    try testing.expect(!main.isSafeExternalUrl(""));
}

test "gif sources are recognised so their frames are kept" {
    try testing.expect(main.isGifUrl("https://x.com/a.gif"));
    try testing.expect(main.isGifUrl("https://x.com/a.GIF?v=1"));
    try testing.expect(!main.isGifUrl("https://x.com/a.jpg"));
}

test "the feed builds only the rows the window asked for" {
    main.resetProfilesForTest();
    main.resetMediaForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{41} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note in a long feed");

    // A feed far longer than any viewport.
    var model = main.initialModel();
    model.stage = .ready;
    for (0..200) |i| {
        model.notes[i] = main.noteFrom(ev, 1_800_000_000);
        // Distinct ids so the list can key its rows.
        model.notes[i].id = @intCast(i + 1);
    }
    model.notes_len = 200;

    const tree = try buildTree(arena, &model);

    // Windowed: the built rows are a small fraction of the 200 notes, which is
    // the whole point (the cost follows the viewport, not the feed length).
    const built = countNoteRows(tree.root);
    try testing.expect(built > 0);
    try testing.expect(built < 60);

    // And the range the view reported back is inside the feed.
    const visible = model.visibleRange();
    try testing.expect(visible.last < model.notes_len);
}

test "a picture reserves the same space loaded or not" {
    main.resetProfilesForTest();
    main.resetMediaForTest();
    defer main.resetMediaForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{21} ** 32);

    // A note whose imeta declares a tall picture: the height is known before a
    // single byte is downloaded, which is what stops the feed shifting.
    const url = "https://host.example/tall.jpg";
    const tags = [_]nostr.event.Tag{
        &.{ "imeta", "url " ++ url, "dim 400x800" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &tags, "look " ++ url, null);
    const note = main.noteFrom(ev, 1_800_000_000);

    try testing.expect(note.hasImage());
    // 2:1 tall against the nominal 300pt width would be 600, clamped to 320.
    try testing.expectApproxEqAbs(@as(f32, 320), main.pictureHeight(&note), 0.5);
    // Nothing is loaded, yet the reserved height is already the final one.
    try testing.expectEqual(@as(u64, 0), note.media_id());
}

test "imeta dimensions parse, including float forms" {
    const url = "https://host.example/a.png";
    const wide = [_]nostr.event.Tag{&.{ "imeta", "url " ++ url, "dim 800x400" }};
    try testing.expectApproxEqAbs(@as(f32, 0.5), main.imetaAspect(&wide, url), 0.001);

    // Real notes carry float dimensions too.
    const floaty = [_]nostr.event.Tag{&.{ "imeta", "url " ++ url, "dim 1320.0x2868.0" }};
    try testing.expect(main.imetaAspect(&floaty, url) > 2.0);

    // An imeta for a different URL says nothing about this one.
    const other = [_]nostr.event.Tag{&.{ "imeta", "url https://host.example/b.png", "dim 800x400" }};
    try testing.expectEqual(@as(f32, 0), main.imetaAspect(&other, url));
    try testing.expectEqual(@as(f32, 0), main.imetaAspect(&.{}, url));
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

test "an unchanged note is reused across rebuilds, not re-parsed" {
    main.resetProfilesForTest();
    main.resetMediaForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{51} ** 32);
    // The feed scopes to the follow set plus the signed-in user; BE the user.
    main.setIdentityForTest([_]u8{51} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/reuse.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "the original text");
    _ = try store.ingest(arena, ev, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(&model, &store, 1_800_000_100);
    try testing.expectEqual(@as(usize, 1), model.notes_len);

    // Plant a sentinel: if the next rebuild re-parses this note, the store's
    // content overwrites it; if the card is reused, it survives.
    const sentinel = "SENTINEL";
    @memcpy(model.notes[0].content_buf[0..sentinel.len], sentinel);
    model.notes[0].content_len = sentinel.len;

    // A second note arrives: the old card must carry over by id untouched.
    const ev2 = try signedNote(arena, signer, kp, 1_800_000_050, "another note");
    _ = try store.ingest(arena, ev2, .{});
    main.reconcileForTest(&model, &store, 1_800_000_100);

    try testing.expectEqual(@as(usize, 2), model.notes_len);
    var found_sentinel = false;
    for (model.notes[0..model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) found_sentinel = true;
    }
    try testing.expect(found_sentinel);

    // A profile gaining a name moves the generation, which forces a re-parse
    // (mention labels are baked into content), replacing the sentinel.
    var meta_buf: [128]u8 = undefined;
    const meta = try std.fmt.bufPrint(&meta_buf, "{{\"name\":\"reuse-test\"}}", .{});
    const kind0 = try nostr.event.create(arena, signer, kp, 1_800_000_060, 0, &.{}, meta, null);
    _ = try store.ingest(arena, kind0, .{});
    main.reconcileForTest(&model, &store, 1_800_000_100);

    var still_there = false;
    for (model.notes[0..model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) still_there = true;
    }
    try testing.expect(!still_there);
}

test "a kind:0 event is parsed once, not every reconcile" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{53} ** 32);
    // Profile queries scope to the follow set plus the signed-in user.
    main.setIdentityForTest([_]u8{53} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/meta.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const kind0 = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &.{}, "{\"name\":\"once\"}", null);
    _ = try store.ingest(arena, kind0, .{});

    var model = main.initialModel();
    main.reconcileForTest(&model, &store, 1_800_000_100);

    // Corrupt the cached name; an unchanged kind:0 must NOT overwrite it (the
    // parse is skipped), which is what proves the guard.
    const p = main.upsertProfile(kp.public_key).?;
    try testing.expectEqualStrings("once", p.name_buf[0..p.name_len]);
    p.name_buf[0] = 'X';
    main.reconcileForTest(&model, &store, 1_800_000_100);
    try testing.expectEqualStrings("Xnce", p.name_buf[0..p.name_len]);

    // A NEWER kind:0 replaces it and is parsed.
    const newer = try nostr.event.create(arena, signer, kp, 1_800_000_500, 0, &.{}, "{\"name\":\"twice\"}", null);
    _ = try store.ingest(arena, newer, .{});
    main.reconcileForTest(&model, &store, 1_800_000_600);
    try testing.expectEqualStrings("twice", p.name_buf[0..p.name_len]);
}

test "a slot wanted on screen is never evicted for another visible picture" {
    main.resetMediaForTest();
    defer main.resetMediaForTest();

    // Fill every slot and mark them all wanted at the current clock, which is
    // what the touch pass does for pictures on screen.
    const clock = main.touchMediaClockForTest();
    var fx: main.EffectsForTest = undefined;
    var i: i64 = 1;
    while (i <= 6) : (i += 1) {
        const slot = main.claimMediaSlotForTest(&fx, i) orelse return error.NoSlot;
        slot.last_used = clock;
    }
    // A seventh visible picture must get NOTHING rather than steal a wanted
    // slot: stealing is the thrash that decoded images every pass.
    try testing.expect(main.claimMediaSlotForTest(&fx, 7) == null);
}

test "the logout confirmation replaces the log-out button" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .settings;
    model.logout_pending = true;
    const tree = try buildTree(arena, &model);

    // The confirmation shows a warning and a Cancel/Log out pair.
    try testing.expect(findAnyText(tree.root, "Cancel") != null);
    try testing.expect(findAnyText(tree.root, "Log out") != null);
}

test "the empty feed renders the brand and a connecting body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);

    // The titlebar wordmark (a paragraph span now, beside the mark icon).
    try testing.expect(findAnyText(tree.root, "Plaza") != null);
    // With no notes yet, the body says what it is waiting for.
    try testing.expect(findAnyText(tree.root, "Connecting to the relay pool…") != null);
}

test "a note becomes an npub-labelled card with a relative time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{3} ** 32);

    const now: i64 = 1_800_000_000;
    const ev = try signedNote(arena, signer, kp, now - 300, "hello from plaza"); // 5 minutes ago
    const note = main.noteFrom(ev, now);

    // Author is the abbreviated, canonical npub.
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
    try testing.expect(std.mem.indexOfScalar(u8, note.author(), '\xe2') != null); // the "…" abbreviation marker
    // Relative time and avatar initials.
    try testing.expectEqualStrings("5m", note.time());
    try testing.expectEqual(@as(usize, 2), note.initials().len);
    // Content survives.
    try testing.expectEqualStrings("hello from plaza", note.content());
}

test "the feed renders a note card from the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{4} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note in the feed");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    const tree = try buildTree(arena, &model);
    // The row shows the content and the npub author, and the status bar's
    // caught-up line carries the count.
    try testing.expect(findAnyText(tree.root, "a note in the feed") != null);
    try testing.expect(findAnyText(tree.root, model.notes[0].author()) != null);
    try testing.expect(findAnyText(tree.root, "Caught up · starter pack · 1 notes") != null);
}

test "the status bar summarises the relay pool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Some relays live: the status bar shows the live count out of the pool
    // (the dot beside it carries the color; the text carries the fact).
    var live = main.initialModel();
    live.stage = .ready;
    live.live_relays = 3;
    const live_tree = try buildTree(arena, &live);
    try testing.expect(findAnyText(live_tree.root, "3/5 relays") != null);

    // The whole pool down: the empty body says so while the bar keeps the count.
    var down = main.initialModel();
    down.stage = .ready;
    down.offline_relays = 5;
    const down_tree = try buildTree(arena, &down);
    try testing.expect(findAnyText(down_tree.root, "Can't reach any relay. Retrying…") != null);
    try testing.expect(findAnyText(down_tree.root, "0/5 relays") != null);
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);

    var nodes: [64]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 440, 680), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "one-process: a signed note round-trips through the local store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{9} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "stored in-process");

    // A throwaway store under the test tmp dir (self-cleaning).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/feed.mdb", .{tmp.sub_path});

    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // Ingest verifies (secp256k1) and stores (LMDB), the whole in-process path.
    const result = try store.ingest(arena, ev, .{ .verify_with = signer });
    try testing.expectEqual(nostr.store.IngestResult.added, result);

    // Query it back and confirm the content survived the round-trip.
    const kinds = [_]u16{1};
    var q = try store.query(arena, .{ .kinds = &kinds, .limit = 10 });
    defer q.deinit();
    try testing.expectEqual(@as(usize, 1), q.events.len);
    try testing.expectEqualStrings("stored in-process", q.events[0].content);
}

test "the titlebar shows join CTAs for a guest, compose and settings when signed in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A guest has no note to compose and no account to configure: the titlebar
    // carries the always-present join CTAs instead.
    main.clearIdentityForTest();
    var guest = main.initialModel();
    guest.stage = .ready;
    const guest_tree = try buildTree(arena, &guest);
    try testing.expect(findAnyText(guest_tree.root, "Create identity") != null);
    try testing.expect(findAnyText(guest_tree.root, "Sign in") != null);
    try testing.expect(findAnyText(guest_tree.root, "New note") == null);
    try testing.expect(findAnyText(guest_tree.root, "Settings") == null);

    // Signed in: New note and Settings return; the compose sheet posts.
    main.setIdentityForTest([_]u8{71} ** 32);
    defer main.clearIdentityForTest();
    var user = main.initialModel();
    user.stage = .ready;
    const user_tree = try buildTree(arena, &user);
    try testing.expect(findAnyText(user_tree.root, "New note") != null);
    try testing.expect(findAnyText(user_tree.root, "Settings") != null);
    try testing.expect(findAnyText(user_tree.root, "Create identity") == null);

    user.composing = true;
    const sheet_tree = try buildTree(arena, &user);
    try testing.expect(findAnyText(sheet_tree.root, "Post") != null);
}

test "a fresh draft is empty and disables Post" {
    var model = main.initialModel();
    try testing.expect(model.draft_empty());
    try testing.expectEqualStrings("", model.draft());
}

test "the feed key survives a high-bit event id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Find a note whose id begins with the high bit set, the case that
    // overflows the markup engine's i64 key cast if the key is stored as u64.
    var seed: u8 = 1;
    const ev = while (seed < 255) : (seed += 1) {
        const kp = try signer.keyPairFromSecretKey([_]u8{seed} ** 32);
        const e = try signedNote(arena, signer, kp, 1_800_000_000, "high-bit id");
        if (e.id[0] >= 0x80) break e;
    } else return error.NoHighBitIdFound;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;

    // Building the list resolves the item key; a u64 key would panic here.
    const tree = try buildTree(arena, &model);
    try testing.expect(findByText(tree.root, .text, "high-bit id") != null);
}

// ---- NIP-46 client hardening: request correlation, timeout, teardown --------

test "a NIP-46 response is matched to its request by id, and unknown ids are dropped" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    // The pending table frees held drafts with the page allocator, so a draft
    // handed to it must come from the same allocator.
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-1", .sign_event, try gpa.dupe(u8, "hello world")));

    // An unknown id resolves nothing: this is the drop that keeps a stray or
    // duplicated response from being published as if it were our note.
    try testing.expect(main.takePendingContentForTest("req-99") == null);

    // The matching id returns the slot, carrying the original draft back.
    const taken = main.takePendingContentForTest("req-1") orelse return error.NoMatch;
    try testing.expect(taken.method == .sign_event);
    try testing.expectEqualStrings("hello world", taken.content.?);
    gpa.free(taken.content.?);

    // A second response for the same id finds nothing: no double resolve.
    try testing.expect(main.takePendingContentForTest("req-1") == null);
}

test "logout empties the NIP-46 pending table so a new session inherits nothing" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-a", .sign_event, try gpa.dupe(u8, "draft a")));
    try testing.expect(main.registerPendingForTest("req-b", .connect, null));

    main.clearPendingForTest(); // what performLogout calls; frees the held draft

    try testing.expect(main.takePendingContentForTest("req-a") == null);
    try testing.expect(main.takePendingContentForTest("req-b") == null);
}

test "a refused remote sign restores the lost draft to the composer" {
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    try testing.expect(main.registerPendingForTest("req-x", .sign_event, try gpa.dupe(u8, "my precious note")));

    // The signer refused: the listener flags the slot rather than dropping it,
    // because only the UI thread may touch the composer.
    try testing.expect(main.failPendingForTest("req-x"));

    // The UI sweep restores the draft into the empty composer and raises the
    // notice, so the text is never silently lost on a hung or refused sign.
    var model = main.initialModel();
    try testing.expect(model.draft_empty());
    main.scanPendingRemoteForTest(&model);
    try testing.expectEqualStrings("my precious note", model.draft());
    try testing.expect(main.remoteSignNoticeForTest());

    // The slot is retired: a late response for it now finds nothing.
    try testing.expect(main.takePendingContentForTest("req-x") == null);
}

// ---- B3: guest-first launch ------------------------------------------------

test "a guest feed shows the join strip; dismissing keeps the Guest chip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    try testing.expect(model.is_guest());

    // The strip invites without blocking: the feed is fully built around it.
    const with_strip = try buildTree(arena, &model);
    try testing.expect(findAnyText(with_strip.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") != null);
    try testing.expect(findAnyText(with_strip.root, "Create identity") != null);

    // Dismissal hides the strip but never the way in: the Guest chip stays.
    model.guest_strip_dismissed = true;
    const dismissed = try buildTree(arena, &model);
    try testing.expect(findAnyText(dismissed.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);
    try testing.expect(findAnyText(dismissed.root, "Guest") != null);
}

test "a signed-in feed carries no guest affordances" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{61} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    try testing.expect(!model.is_guest());

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);
    try testing.expect(findAnyText(tree.root, "Guest") == null);
}

test "the join screen always offers the way back to reading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .onboarding;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Keep browsing") != null);
    try testing.expect(findAnyText(tree.root, "Reading never needs an identity.") != null);
}

// ---- C1: the first-intent sheet ---------------------------------------------

test "the join sheet renders the ladder and remembers a waiting note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;

    // Bare ladder: title, three ways in, and always the way back.
    const bare = try buildTree(arena, &model);
    try testing.expect(findAnyText(bare.root, "How do you want to join?") != null);
    try testing.expect(findAnyText(bare.root, "Create your identity") != null);
    try testing.expect(findAnyText(bare.root, "Bring your key") != null);
    try testing.expect(findAnyText(bare.root, "Use your own signer") != null);
    try testing.expect(findAnyText(bare.root, "Keep browsing") != null);
    try testing.expect(findAnyText(bare.root, "Your note is waiting.") == null);

    // With a remembered intent, the sheet says so.
    model.pending_compose = true;
    const pending = try buildTree(arena, &model);
    try testing.expect(findAnyText(pending.root, "Your note is waiting.") != null);
}

test "a remembered intent replays once and only once" {
    var model = main.initialModel();
    model.stage = .ready;
    model.pending_compose = true;

    // Identity arrives: the composer opens by itself, the intent is spent.
    main.replayPendingForTest(&model);
    try testing.expect(model.composing);
    try testing.expect(!model.pending_compose);

    // A second replay is a no-op: closing the sheet stays closed.
    model.composing = false;
    main.replayPendingForTest(&model);
    try testing.expect(!model.composing);
}

// ---- C2: bunker connect states ----------------------------------------------

test "the composer line tells the truth about the signer connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    defer {
        main.setRemoteStateForTest(0, 0);
        main.clearIdentityForTest();
    }
    var model = main.initialModel();

    main.setRemoteStateForTest(1, 1);
    try testing.expect(std.mem.startsWith(u8, model.identity(arena), "Reaching your signer · "));

    main.setRemoteStateForTest(2, 1);
    try testing.expect(std.mem.startsWith(u8, model.identity(arena), "Signing via your signer · npub1"));

    main.setRemoteStateForTest(3, 1);
    try testing.expectEqualStrings("Your signer is unreachable. Posts will not sign.", model.identity(arena));
}

// ---- C4-C6: name beat, toast, backup nudge ----------------------------------

test "the name beat renders and skipping replays the intent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.naming = true;
    model.pending_compose = true;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Want a name on it?") != null);
    try testing.expect(findAnyText(tree.root, "Skip") != null);
    try testing.expect(findAnyText(tree.root, "Save") != null);

    // Skip ends the beat and the remembered intent still replays.
    model.naming = false;
    main.replayPendingForTest(&model);
    try testing.expect(model.composing);
}

test "a toast shows its text and the backup nudge states the stakes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    @memcpy(model.toast_buf[0..6], "Posted");
    model.toast_len = 6;
    model.toast_until = 4_000_000_000;
    model.backup_nudge = true;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Posted") != null);
    try testing.expect(findAnyText(tree.root, "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.") != null);
    try testing.expect(findAnyText(tree.root, "Not now") != null);
}

// ---- 3b: helper-held identity restore --------------------------------------

test "a helper session restores the identity from its pubkey, no key in process" {
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{71} ** 32);
    var hexbuf: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (kp.public_key, 0..) |b, i| {
        hexbuf[i * 2] = digits[b >> 4];
        hexbuf[i * 2 + 1] = digits[b & 0x0f];
    }

    // A valid pubkey restores the signed-in helper identity.
    try testing.expect(main.restoreHelperForTest(&hexbuf));
    var model = main.initialModel();
    try testing.expect(!model.is_guest());

    // The feed shows no guest affordances once restored.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findAnyText(tree.root, "Browsing as a guest. Reading is yours forever. Join in when something moves you.") == null);

    // A short or empty pubkey restores nothing (the parser-mismatch regression).
    main.clearIdentityForTest();
    try testing.expect(!main.restoreHelperForTest(""));
    try testing.expect(!main.restoreHelperForTest("abcd"));
}

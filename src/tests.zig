const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");
const painted = @import("painted.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

/// Builds the real view for `model`: the same root the app runs, so a test sees
/// the markup screens (compiled in) and the hand-written feed exactly as shipped.
fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    // The app's own icon table, installed the same way `main` installs it, so a
    // test tree draws Plaza's glyphs rather than the missing-icon fallback.
    main.registerIcons();
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

/// Whether any widget's text CONTAINS this needle (span-joined paragraphs).
/// The first text in the tree containing `needle`, so a test can assert about
/// the string itself rather than only its presence.
fn findAnyTextContainingText(widget: canvas.Widget, needle: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return widget.text;
    for (widget.children) |child| {
        if (findAnyTextContainingText(child, needle)) |found| return found;
    }
    return null;
}

fn findAnyTextContaining(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (findAnyTextContaining(child, needle)) return true;
    }
    return false;
}

/// How many widgets the tree holds, which is what the view budget counts.
fn countNodes(widget: canvas.Widget) usize {
    var n: usize = 1;
    for (widget.children) |child| n += countNodes(child);
    return n;
}

/// How many widgets carry this exact label. A row count, when the rows are
/// alike: `findByLabel` says one exists, this says how many were built.
fn countByLabel(widget: canvas.Widget, label: []const u8) usize {
    var n: usize = if (std.mem.eql(u8, widget.semantics.label, label)) 1 else 0;
    for (widget.children) |child| n += countByLabel(child, label);
    return n;
}

/// The frame of the first widget carrying this exact text.
fn frameOfText(p: painted.Painted, text: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, text)) return node.widget.frame;
    }
    return null;
}

/// The frame of the first widget of this kind, in painted order.
fn frameOfKind(p: painted.Painted, kind: canvas.WidgetKind) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |node| {
        if (node.widget.kind == kind) return node.widget.frame;
    }
    return null;
}

/// Finds a widget by its accessibility label (for icon-only controls like the
/// rail tiles, which carry no text).
fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

/// "N/M relays", with M the size of the pool the app is born with, so a change
/// to the bootstrap list does not have to be chased through the assertions.
fn ui_fmt_pool(arena: std.mem.Allocator, live: usize) []const u8 {
    return std.fmt.allocPrint(arena, "{d}/{d} relays", .{ live, main.bootstrap_relay_count_for_test }) catch unreachable;
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

    // Signed in, because half this screen is about the identity: a guest has no
    // profile to edit and no key to back up.
    main.setIdentityForTest([_]u8{9} ** 32);
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    try testing.expect(findAnyText(tree.root, "Settings") != null);
    // Every section the design names, in the order it names them.
    try testing.expect(findAnyText(tree.root, "IDENTITY") != null);
    try testing.expect(findAnyText(tree.root, "RELAYS") != null);
    try testing.expect(findAnyText(tree.root, "APPEARANCE") != null);
    try testing.expect(findAnyText(tree.root, "FEED") != null);
    // The identity card says what signs, and offers the way into the profile.
    try testing.expect(findAnyText(tree.root, "Signing with a local key") != null);
    try testing.expect(findAnyText(tree.root, "Edit profile") != null);
    try testing.expect(findAnyText(tree.root, "Copy npub") != null);
    // The key-backup card has no home in the design and must not be dropped: a
    // local key is the account, and this is the only way to take a copy of it.
    try testing.expect(findAnyText(tree.root, "Reveal secret key") != null);
    // So is the media proxy, which is a privacy setting with no other UI.
    try testing.expect(findAnyText(tree.root, "Media proxy") != null);
    try testing.expect(findAnyText(tree.root, "Load media previews") != null);
    // The logout entry point is present; the confirmation is not yet.
    try testing.expect(findAnyText(tree.root, "Log out") != null);
    try testing.expect(findAnyText(tree.root, "Cancel") == null);
    // The version line renders.
    // The version app.zon declares, not a literal. This line used to say
    // "Plaza 0.1.0" and passed happily while the shipped app was 0.2.2, because
    // both the screen and the test were reading the same stale copy.
    const shown = try std.fmt.allocPrint(arena, "Plaza {s}", .{main.plaza_version_for_test});
    try testing.expect(findAnyText(tree.root, shown) != null);
    try testing.expect(main.plaza_version_for_test.len > 0);
}

test "a guest is not offered a profile to edit" {
    // A guest has no key: nothing to read their profile from and nothing that
    // could sign an edit. Offering the sheet would sit on "Reading your current
    // profile" for the rest of the session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "IDENTITY") != null);
    try testing.expect(findAnyText(tree.root, "Edit profile") == null);

    // And reaching for it anyway routes to the join sheet rather than opening a
    // sheet that can never finish.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(!model.editing_profile);
    try testing.expect(model.joining);
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

test "the @handle is the NIP-05, and nothing without one" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{21} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");

    // No profile, or a profile with no nip05: no handle at all (never a bare npub).
    const bare = main.noteFrom(ev, 1_800_000_000);
    try testing.expectEqualStrings("", bare.handle(arena));
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Satoshi\",\"name\":\"nakamoto\"}");
    try testing.expectEqualStrings("", main.noteFrom(ev, 1_800_000_000).handle(arena));

    // A user@domain nip05 shows as @user.
    main.parseMetadataInto(p, "{\"name\":\"nakamoto\",\"nip05\":\"satoshi@bitcoin.org\"}");
    try testing.expectEqualStrings("@satoshi", main.noteFrom(ev, 1_800_000_000).handle(arena));

    // The root "_@domain" form shows as @domain, not @_.
    main.parseMetadataInto(p, "{\"nip05\":\"_@dergigi.com\"}");
    try testing.expectEqualStrings("@dergigi.com", main.noteFrom(ev, 1_800_000_000).handle(arena));
}

test "a NIP-05 check needs a real well-known name to pubkey match" {
    const pubkey = [_]u8{0xAB} ** 32;
    // The hex of the pubkey above, which a matching well-known maps the name to.
    const hex = "ab" ** 32;

    const good = "{\"names\":{\"bob\":\"" ++ hex ++ "\"}}";
    try testing.expect(main.nip05Matches("bob@example.com", pubkey, good));
    // The root "_" name is a valid identifier form and verifies the same way.
    const root = "{\"names\":{\"_\":\"" ++ hex ++ "\"}}";
    try testing.expect(main.nip05Matches("_@example.com", pubkey, root));

    // A different pubkey for the name is NOT a match (impersonation guard).
    const other = "{\"names\":{\"bob\":\"" ++ ("cd" ** 32) ++ "\"}}";
    try testing.expect(!main.nip05Matches("bob@example.com", pubkey, other));
    // The queried name is simply absent.
    try testing.expect(!main.nip05Matches("carol@example.com", pubkey, good));
    // Malformed body, or no @ in the identifier: never a match.
    try testing.expect(!main.nip05Matches("bob@example.com", pubkey, "not json"));
    try testing.expect(!main.nip05Matches("nobody", pubkey, good));
}

test "a NIP-05 identifier must be well-formed to be fetched" {
    try testing.expect(main.validNip05Name("dergigi"));
    try testing.expect(main.validNip05Name("_"));
    try testing.expect(main.validNip05Name("a.b-c_1"));
    try testing.expect(!main.validNip05Name(""));
    try testing.expect(!main.validNip05Name("has space"));
    try testing.expect(!main.validNip05Name("naïve")); // non-ASCII

    try testing.expect(main.validNip05Domain("example.com"));
    try testing.expect(main.validNip05Domain("relay.example.com:8443"));
    try testing.expect(!main.validNip05Domain("localhost")); // no dot
    try testing.expect(!main.validNip05Domain("has space.com"));
    try testing.expect(!main.validNip05Domain(""));
}

test "engagement counts format terse, and omit zero" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("", main.formatCount(arena, 0));
    try testing.expectEqualStrings("6", main.formatCount(arena, 6));
    try testing.expectEqualStrings("854", main.formatCount(arena, 854));
    try testing.expectEqualStrings("1.2k", main.formatCount(arena, 1200));
    try testing.expectEqualStrings("12.1k", main.formatCount(arena, 12100));
}

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

test "note text splits into link, mention, and plain runs, colored by the identity token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "hi @alice see https://example.com/x ok");
    try testing.expectEqual(@as(usize, 5), spans.len);
    // Content runs take the identity violet through the `info` token; only the
    // link is pressable, and a mention additionally sits one weight up.
    try testing.expectEqualStrings("@alice", spans[1].text);
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    try testing.expectEqual(canvas.TextSpanWeight.medium, spans[1].weight);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len);
    try testing.expectEqualStrings("https://example.com/x", spans[3].text);
    try testing.expectEqualStrings("https://example.com/x", spans[3].link);
    try testing.expect(spans[3].color != null and spans[3].color.? == .info);
    // We ask for no underline (the redesign's in-text URL is colored and
    // nothing more). The renderer still draws one under any span carrying a
    // link payload, which is why this asserts the REQUEST, not the pixels.
    try testing.expect(!spans[3].underline);
    // Plain text has no link payload.
    try testing.expectEqual(@as(usize, 0), spans[0].link.len);
}

test "hashtags are colored at a word boundary, but C# and trailing punctuation are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "gm #nostr build C# code #zig!");
    try testing.expectEqual(@as(usize, 5), spans.len);
    try testing.expectEqualStrings("#nostr", spans[1].text);
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len); // styled, not a link
    try testing.expectEqualStrings(" build C# code ", spans[2].text); // C# is not a tag
    try testing.expectEqualStrings("#zig", spans[3].text);
    try testing.expectEqualStrings("!", spans[4].text); // trailing punctuation stays plain
}

test "findQuoteRef captures the first note/nevent ref and ignores others" {
    var id = [_]u8{0xab} ** 32;
    const note1 = try nostr.nip19.encodeNote(testing.allocator, id);
    defer testing.allocator.free(note1);

    // A `nostr:`-prefixed reference is captured: id decoded, span covers the
    // whole `nostr:note1…` token.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "gm nostr:{s} enjoy", .{note1});
        defer testing.allocator.free(content);
        const note = main.findQuoteRefForTest(content);
        try testing.expect(main.noteHasEventQuote(&note));
        try testing.expectEqualSlices(u8, &id, &note.quote.id);
        const tok = content[note.quote.off..][0..note.quote.len];
        const want = try std.fmt.allocPrint(testing.allocator, "nostr:{s}", .{note1});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, tok);
    }
    // A bare reference at a word boundary is captured too.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "look {s}", .{note1});
        defer testing.allocator.free(content);
        const note = main.findQuoteRefForTest(content);
        try testing.expect(main.noteHasEventQuote(&note));
        try testing.expectEqualStrings(note1, content[note.quote.off..][0..note.quote.len]);
    }
    // Glued inside a URL (not a word boundary) is left as plain text, whether
    // bare or `nostr:`-prefixed.
    {
        const content = try std.fmt.allocPrint(testing.allocator, "https://x/{s}", .{note1});
        defer testing.allocator.free(content);
        try testing.expect(!main.noteHasEventQuote(&main.findQuoteRefForTest(content)));
    }
    {
        const content = try std.fmt.allocPrint(testing.allocator, "https://njump.me/nostr:{s}", .{note1});
        defer testing.allocator.free(content);
        try testing.expect(!main.noteHasEventQuote(&main.findQuoteRefForTest(content)));
    }
    // A malformed token decodes to nothing.
    {
        const note = main.findQuoteRefForTest("hi nostr:note1notvalidbech32!!! bye");
        try testing.expect(!main.noteHasEventQuote(&note));
    }
}

test "a bare event reference is identity-colored without a link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "see nostr:nevent1qqs example");
    // "see ", then the ref run, then " example".
    try testing.expectEqualStrings("nostr:nevent1qqs", spans[1].text);
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    try testing.expectEqual(@as(usize, 0), spans[1].link.len);
    try testing.expect(!spans[1].underline);
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
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
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
    // The box is the reading column, so a 2:1 picture would be twice that tall;
    // the aspect is capped instead, and the cap is what it draws at. Capping the
    // ASPECT rather than the pixels is what keeps the reservation exact: the
    // height is stated, not clamped after the fact.
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * 1.25, main.pictureHeight(&note), 0.5);
    // Nothing is loaded, yet the reserved height is already the final one.
    try testing.expectEqual(@as(u64, 0), note.media_id());

    // A landscape picture takes exactly the height its declared shape implies.
    const wide_url = "https://host.example/wide.jpg";
    const wide_tags = [_]nostr.event.Tag{&.{ "imeta", "url " ++ wide_url, "dim 1600x900" }};
    const wide_ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &wide_tags, "look " ++ wide_url, null);
    const wide = main.noteFrom(wide_ev, 1_800_000_000);
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * (900.0 / 1600.0), main.pictureHeight(&wide), 0.5);
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

test "avatar ids go to the authors on screen, and never exceed the registry cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    // This used to say "the first `cap` authors IN READING ORDER of the whole
    // thread", which is precisely the bug: a level marked every author it held
    // as on screen, the claim pass never evicts anything marked wanted, so the
    // first nine took every id and kept it while the level was open. Everyone
    // below them showed initials no matter how far the reader scrolled.
    //
    // The rule is the one the feed always had: the authors ON SCREEN hold the
    // ids. So this drives a real build, which is what fills the visible set.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const count = 40;
    var keys: [count][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = [_]u8{0} ** 32;
        k.*[0] = @intCast(i + 1); // distinct, non-zero
        main.setProfilePictureForTest(k.*, true);
    }
    model.thread_root.pubkey = keys[0];
    for (1..count) |i| {
        model.thread_notes[i - 1] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i - 1].id = @intCast(700 + i);
        model.thread_notes[i - 1].pubkey = keys[i];
        model.thread_notes[i - 1].event_id = [_]u8{@intCast(i)} ** 32;
    }
    model.thread_notes_len = count - 1;

    _ = try painted.Painted.render(arena, &model);
    var fx: main.EffectsForTest = undefined;
    main.assignAvatarSlotsForTest(&fx, &model);

    const cap = main.max_avatar_images;
    var seen = [_]bool{false} ** (cap + 1);
    var lent: usize = 0;
    for (keys) |k| {
        const id = main.avatarImageIdForTest(k);
        if (id == 0) continue;
        // Never past the pool, and never the same id twice.
        try testing.expect(id >= 1 and id <= cap);
        if (seen[@intCast(id)]) {
            std.debug.print("id {d} lent twice\n", .{id});
            return error.DuplicateAvatarId;
        }
        seen[@intCast(id)] = true;
        lent += 1;
    }
    try testing.expect(lent <= cap);
    // And it really did lend some: a pass that starves everybody would satisfy
    // every line above.
    if (lent == 0) {
        std.debug.print("no author on screen was lent a face\n", .{});
        return error.NothingLent;
    }
}

test "an author deep in a thread gets a face once they are on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    // THE BUG, stated as a rule. Somebody thirty replies down a thread could
    // never hold a face, however far the reader scrolled: the ids were spoken
    // for by the top of the thread and unreclaimable. Scrolling has to be able
    // to hand a face to whoever is now being read.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const count = 40;
    var keys: [count][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = [_]u8{0} ** 32;
        k.*[0] = @intCast(i + 1);
        main.setProfilePictureForTest(k.*, true);
    }
    model.thread_root.pubkey = keys[0];
    for (1..count) |i| {
        model.thread_notes[i - 1] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i - 1].id = @intCast(700 + i);
        model.thread_notes[i - 1].pubkey = keys[i];
        model.thread_notes[i - 1].event_id = [_]u8{@intCast(i)} ** 32;
    }
    model.thread_notes_len = count - 1;

    // At the top of the thread: the deep author is nowhere near the screen.
    _ = try painted.Painted.render(arena, &model);
    var fx: main.EffectsForTest = undefined;
    main.assignAvatarSlotsForTest(&fx, &model);
    const deep = keys[count - 1];
    const before = main.avatarImageIdForTest(deep);

    // Now they ARE on screen. Recorded the same way the build records it, which
    // is the seam this fix put in.
    main.recordVisibleAuthorsForTest(&.{deep});
    main.assignAvatarSlotsForTest(&fx, &model);
    const after = main.avatarImageIdForTest(deep);

    if (after == 0) {
        std.debug.print("an author on screen still holds no face (was {d})\n", .{before});
        return error.DeepAuthorStarved;
    }
    try testing.expect(after >= 1 and after <= main.max_avatar_images);
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

test "the empty feed renders the rail and a connecting body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);

    // The nav rail's Home tile (the mark) stands in for the old wordmark.
    try testing.expect(findByLabel(tree.root, "Home") != null);
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
    main.resetRelaysForTest();
    var live = main.initialModel();
    live.stage = .ready;
    live.live_relays = 3;
    live.relay_count = main.relayCount();
    const live_tree = try buildTree(arena, &live);
    try testing.expect(findAnyText(live_tree.root, ui_fmt_pool(arena, 3)) != null);

    // The whole pool down: the empty body says so while the bar keeps the count.
    var down = main.initialModel();
    down.stage = .ready;
    down.offline_relays = main.bootstrap_relay_count_for_test;
    down.relay_count = main.relayCount();
    const down_tree = try buildTree(arena, &down);
    try testing.expect(findAnyText(down_tree.root, "Can't reach any relay. Retrying…") != null);
    try testing.expect(findAnyText(down_tree.root, ui_fmt_pool(arena, 0)) != null);
}

test "the view lays out through the canvas engine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena_state.allocator(), &model);

    // Sized from the runtime's own per-view ceiling, not a literal. A view past
    // the cap is REFUSED, not truncated (error.WidgetNodeLimitReached from the
    // runtime, error.WidgetLayoutListFull from the layout call), and a buffer
    // that merely fits today would fail this smoke test on the next row of
    // chrome instead of on a real bug. Arena-allocated: a thousand nodes is more
    // than a test stack should carry.
    const nodes = try arena_state.allocator().alloc(canvas.WidgetLayoutNode, native_sdk.runtime.max_canvas_widget_nodes_per_view);
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 440, 680), nodes);
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

test "the rail and guest banner carry the right entry points by identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A guest: the banner carries the always-present join CTAs (as text), and
    // the rail's compose/settings tiles (icons, labelled) route to join too.
    main.clearIdentityForTest();
    var guest = main.initialModel();
    guest.stage = .ready;
    const guest_tree = try buildTree(arena, &guest);
    try testing.expect(findAnyText(guest_tree.root, "Create identity") != null);
    try testing.expect(findAnyText(guest_tree.root, "Sign in") != null);
    // The rail is present in both states: Home, New note, Settings tiles.
    try testing.expect(findByLabel(guest_tree.root, "New note") != null);
    try testing.expect(findByLabel(guest_tree.root, "Settings") != null);

    // Signed in: no join banner; the rail still carries compose and settings,
    // and the compose sheet posts.
    main.setIdentityForTest([_]u8{71} ** 32);
    defer main.clearIdentityForTest();
    var user = main.initialModel();
    user.stage = .ready;
    const user_tree = try buildTree(arena, &user);
    try testing.expect(findByLabel(user_tree.root, "New note") != null);
    try testing.expect(findByLabel(user_tree.root, "Settings") != null);
    try testing.expect(findAnyText(user_tree.root, "Create identity") == null);

    user.composing = true;
    const sheet_tree = try buildTree(arena, &user);
    try testing.expect(findAnyText(sheet_tree.root, "Post") != null);
}

test "opening a thread shows it, and a guest reply routes to the join" {
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{44} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "root note");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const id = model.notes[0].id;

    var fx: main.EffectsForTest = undefined;
    // Open the thread: viewing_thread is set and the thread screen shows.
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    const thread_tree = try buildTree(arena, &model);
    try testing.expect(findByLabel(thread_tree.root, "Back") != null);
    try testing.expect(findAnyText(thread_tree.root, "Thread") != null);

    // A guest cannot sign: a reply attempt routes to the join, never publishes.
    model.reply_buffer.set("hi");
    main.update(&model, Msg.reply_submit, &fx);
    try testing.expect(model.joining);

    // Back returns to the feed.
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
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

test "only the signer we connected to can answer a signing request" {
    // NIP-44 derives its conversation key from the SENDER, so a response from
    // anybody at all decrypts, as long as they encrypted it to our client key.
    // That key is public: it is the `p` tag on every request we publish. So the
    // relay filter cannot be the only thing standing between the reader and a
    // stranger's answer, and the handler has to check the sender itself.
    //
    // Left unchecked, an answer carrying a forged event is stored and published
    // to the reader's own relays from the reader's own machine, and an answer
    // carrying an error throws away the note they just wrote.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    const gpa = std.heap.page_allocator;

    // Real keys, and a real sealed response, because a test that hands the
    // handler undecryptable rubbish passes whether the check is there or not:
    // the decrypt fails and the slot survives for the wrong reason. The
    // stranger here does exactly what a stranger could do, correctly.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const client_kp = try signer.keyPairFromSecretKey([_]u8{0x11} ** 32);
    const bunker_kp = try signer.keyPairFromSecretKey([_]u8{0x22} ** 32);
    const stranger_kp = try signer.keyPairFromSecretKey([_]u8{0x33} ** 32);
    main.setRemotePubkeyForTest(bunker_kp.public_key);

    try testing.expect(main.registerPendingForTest("f00dcafe", .connect, null));

    // The stranger encrypts a perfectly valid ack to our client key, under the
    // id of the request in flight. Nothing about the ciphertext is wrong: the
    // conversation key comes from THEIR key, so it decrypts on our side.
    var sealed = try nostr.nip46.seal(
        gpa,
        io,
        signer,
        stranger_kp,
        client_kp.public_key,
        "{\"id\":\"f00dcafe\",\"result\":\"ack\",\"error\":\"\"}",
        1_700_000_000,
    );
    defer sealed.deinit();
    main.deliverNip46ResponseForTest(signer, client_kp, sealed.event);

    // The request is still waiting, which is the point: the stranger neither
    // answered it nor consumed it.
    if (main.takePendingContentForTest("f00dcafe") == null) {
        std.debug.print("a stranger's response resolved the reader's pending request\n", .{});
        return error.StrangerAnsweredForTheBunker;
    }

    // And the bunker's own answer, byte for byte the same message, still works.
    try testing.expect(main.registerPendingForTest("f00dcafe", .connect, null));
    var real = try nostr.nip46.seal(
        gpa,
        io,
        signer,
        bunker_kp,
        client_kp.public_key,
        "{\"id\":\"f00dcafe\",\"result\":\"ack\",\"error\":\"\"}",
        1_700_000_000,
    );
    defer real.deinit();
    main.deliverNip46ResponseForTest(signer, client_kp, real.event);
    if (main.takePendingContentForTest("f00dcafe") != null) {
        std.debug.print("the bunker's own answer was rejected along with the stranger's\n", .{});
        return error.LockedOutTheRealSigner;
    }
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

test "nothing the previous account typed survives a sign-out" {
    // Logout was thorough about the draft and said why, in a comment about the
    // previous account's private thinking being one keystroke from going out
    // under the next account's key. The reply box and the name field are the
    // same thing and were both left behind: logout performs no navigation, so
    // the next account landed inside the previous reader's open thread with
    // their unsent sentence still in the composer.
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    main.setIdentityForTest([_]u8{0xc3} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);

    model.reply_buffer.set("something I was in the middle of saying");
    model.name_buffer.set("Sepehr");
    model.draft_buffer.set("an unfinished note");
    model.viewing_thread = 0x1234;

    main.performLogoutForTest(&model, &fx);

    try testing.expectEqualStrings("", model.reply_draft());
    try testing.expectEqualStrings("", model.name_draft());
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // And the one piece of evidence that authorizes building a list from
    // nothing. It is persisted to the session file, so left set it outlived the
    // account it was true about: mint here, log out, import an identity, and
    // nine starter-pack names could replace a real eight-hundred-follow list.
    try testing.expect(!main.identityMintedForTest());
}

test "the key that just signed out is not handed back by the health check" {
    // `helperReset` is fire-and-forget with no response handler, and the SDK
    // drops a rejected effect with no trace when every slot is busy. Reset lost,
    // then "Create your identity" clears the logged-out latch before any new key
    // exists, and one second later the poll re-adopts the key the reader just
    // left. Their create fails with AlreadyInitialized, nothing says so, and the
    // next note goes out under the old identity.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setCeremonyForTest(.none);
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    main.setIdentityForTest([_]u8{0xd4} ** 32);
    // The pubkey the daemon would report, which is derived rather than the
    // secret that was handed in.
    const left = main.activePubkeyForTest().?;
    var hex: [64]u8 = undefined;
    for (left, 0..) |b, i| _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    const same = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"pubkey\":\"{s}\",\"state\":\"ready\"}}",
        .{hex[0..]},
    );
    defer testing.allocator.free(same);

    main.performLogoutForTest(&model, &fx);
    try testing.expect(main.loggedOutPubkeyForTest() != null);
    try testing.expect(main.activePubkeyForTest() == null);

    // The reader presses Create, which drops the general latch.
    main.clearLoggedOutLatchForTest();

    // The daemon still holds the old key, because the reset never landed.
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = same });
    try testing.expect(main.activePubkeyForTest() == null);

    // The daemon says it holds nothing. That is the only honest evidence the
    // reset landed, so whatever key appears next is a new one and is adopted.
    const empty = "{\"pubkey\":\"\",\"state\":\"uninitialized\"}";
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = empty });
    try testing.expect(main.loggedOutPubkeyForTest() == null);
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = same });
    try testing.expect(main.activePubkeyForTest() != null);
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

test "a Notary sign that fails hands the note back instead of eating it" {
    // The remote signer has had a pending slot, a deadline and a restore since
    // it shipped. The built-in one had none of it, and `signAndPublish` dropped
    // the restorable flag on the way to it. So a Notary sign that failed for any
    // reason destroyed the note in silence: the composer was cleared, the draft
    // file deleted, the toast said "Posted", and the response handler returned on
    // its first line with no Model to give anything back to. Nothing was stored
    // and nothing was queued, because the outbox is fed after a good signature.
    //
    // The daemon answers non-200 while perfectly alive: 401 on a stale token,
    // 409 with no key yet, 400 on a malformed event, 500 on a signing failure.
    main.setIdentityForTest([_]u8{0x4f} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    const note = "the sentence I actually wanted to publish";

    // The press, driven from the composer so the signer DISPATCH is under test
    // too: it forwarded the restorable flag to the bunker and dropped it on the
    // way to the built-in signer, which is why a note handed to Notary had
    // nothing holding it even after the slot existed.
    model.draft_buffer.set(note);
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(main.helperSignPendingForTest());
    try testing.expect(main.helperSignRestorableForTest());
    try testing.expect(model.draft_empty());

    // And the daemon refuses. 409 is the concrete one: a helper session restored
    // from disk while the daemon comes up with no signer.key.
    main.handleHelperSignedForTest(.{ .key = 0, .outcome = .ok, .status = 409, .body = "" });

    // The tick hands it back, into a composer the reader has not started using
    // again, and says why rather than letting it silently reappear.
    try testing.expect(model.draft_empty());
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings(note, model.draft());
    try testing.expect(main.helperSignNoticeForTest());
    try testing.expect(!main.helperSignPendingForTest());
    try testing.expect(std.mem.indexOf(u8, model.identity(testing.allocator), "could not sign") != null);
}

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

test "a second sign in the same tick is refused, not swallowed" {
    // Every helper sign goes out on ONE effect key, and the SDK refuses a second
    // fetch while that key is held. The refusal used to be dropped on the first
    // line of the response handler, so the second sign of a pair simply never
    // happened, and the caller had already moved its state: the follow set
    // carried a name that was never published and the UI said "Following".
    //
    // Not merely a race. The tick issues `flushRelayList` and
    // `drivePendingIntent` in the same update call with no drain possible
    // between them, so when both are due the second is rejected every time.
    main.setIdentityForTest([_]u8{0x61} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    main.forgetFollowsForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    defer main.releaseHelperSignForTest();
    main.releaseHelperSignForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.signerReadyForTest());

    // One sign goes out and holds the key.
    model.draft_buffer.set("the first thing");
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expect(!main.signerReadyForTest());

    // THE PROPERTY: every other write says no rather than moving its state and
    // letting the sign be dropped underneath it.
    var alice: [32]u8 = undefined;
    @memset(&alice, 0xa1);
    try testing.expect(!main.writeFollowForTest(&fx, alice, true));
    try testing.expect(!main.publishRelayListForTest(&fx));

    // A second post keeps its draft, rather than emptying the composer for a
    // sign that never left the process.
    model.draft_buffer.set("the second thing");
    try testing.expect(!main.submitPostForTest(&model, &fx));
    try testing.expectEqualStrings("the second thing", model.draft());

    // The signature comes back, and everything works again.
    main.releaseHelperSignForTest();
    try testing.expect(main.signerReadyForTest());
    try testing.expect(main.submitPostForTest(&model, &fx));
}

test "the sign-out warning does not promise a backup that does not exist" {
    // It said "Back it up first if you want to keep this identity", pointing at
    // a control that does not exist for a Notary key: the reveal card is gated
    // on a local key, the daemon's route table has no export and its own module
    // doc says no endpoint returns the secret, and the ceremony window tells the
    // reader there is nothing to write down. Since `createLocalIdentity` has no
    // callers, every identity minted today is one of these, so the instruction
    // was false for the default case.
    var model = main.initialModel();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();
    defer main.setIdentityMintedForTest(false);

    main.setIdentityMintedForTest(true);
    const minted = model.logout_warning();
    try testing.expect(std.mem.indexOf(u8, minted, "Back it up first") == null);
    try testing.expect(std.mem.indexOf(u8, minted, "exists nowhere else") != null);
    try testing.expect(std.mem.indexOf(u8, minted, "for good") != null);

    // A key the reader pasted in themselves is a different fact, and saying the
    // same thing about it would be its own kind of wrong.
    main.setIdentityMintedForTest(false);
    const imported = model.logout_warning();
    try testing.expect(std.mem.indexOf(u8, imported, "sign in again with the same key") != null);

    // A local key really can be copied first, from a card that is right there.
    main.setSignerKindLocalForTest();
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "Copy it first") != null);
}

test "a note still being signed is not thrown away without saying so" {
    // A note handed to a signer that has not answered exists in exactly one
    // place: the slot sign-out frees. It cannot be parked in the outbox the way
    // a queued note is, because it has no signature and so no id, and it cannot
    // be left in the composer, because that is the previous reader's writing
    // sitting in front of the next account. So the confirmation says what the
    // press costs.
    main.setIdentityForTest([_]u8{0x50} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") == null);

    main.requestHelperSignForTest(&fx, 1_800_000_000, 1, "half a thought", true);
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") != null);

    // Once it is signed there is nothing to warn about.
    main.releaseHelperSignForTest();
    try testing.expect(std.mem.indexOf(u8, model.logout_warning(), "has not been signed") == null);
}

test "a sign that never gets an answer at all still gives the note back" {
    // `outcome != .ok` covers a refused connection, but a daemon that accepts
    // the socket and then says nothing produces no terminal at all within the
    // reader's patience. The deadline is the backstop, and without one the note
    // would sit in a slot nobody ever reads.
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    defer main.setSignerKindLocalForTest();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.requestHelperSignForTest(&fx, 1_800_000_000, 1, "a note into the void", true);

    // Not yet: the sign is still legitimately out.
    main.scanHelperSignForTest(&model);
    try testing.expect(model.draft_empty());
    try testing.expect(main.helperSignPendingForTest());

    // Past the deadline, it comes back.
    main.expireHelperSignForTest();
    main.scanHelperSignForTest(&model);
    try testing.expectEqualStrings("a note into the void", model.draft());
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
    model.pending = .post;
    const pending = try buildTree(arena, &model);
    try testing.expect(findAnyText(pending.root, "Your note is waiting.") != null);
}

test "a remembered intent replays once and only once" {
    var model = main.initialModel();
    model.stage = .ready;
    model.pending = .post;

    // Identity arrives: the composer opens by itself, the intent is spent.
    main.replayPendingForTest(&model);
    try testing.expect(model.composing);
    try testing.expect(!model.pending.waiting());

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
    model.pending = .post;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "Want a name on it?") != null);
    try testing.expect(findAnyText(tree.root, "Skip") != null);
    try testing.expect(findAnyText(tree.root, "Done") != null);

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

test "nip10Parent picks the marked reply, root, or positional parent" {
    const root_hex = "01" ** 32;
    const mid_hex = "02" ** 32;
    const deep_hex = "03" ** 32;
    const root_id = [_]u8{0x01} ** 32;
    const mid_id = [_]u8{0x02} ** 32;
    const deep_id = [_]u8{0x03} ** 32;

    // A marked `reply` wins over the marked root and any unmarked tag.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "", "root" },
            &.{ "e", deep_hex, "" },
            &.{ "e", mid_hex, "", "reply" },
        };
        try testing.expectEqualSlices(u8, &mid_id, &(main.nip10Parent(&tags).?));
    }
    // Only a `root` marker: the note answers the root directly.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex, "wss://r", "root" }};
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // No markers (deprecated positional): the LAST `e` tag is the parent.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex },
            &.{ "e", deep_hex },
        };
        try testing.expectEqualSlices(u8, &deep_id, &(main.nip10Parent(&tags).?));
    }
    // The commonest deprecated form in the wild: ONE unmarked `e` tag, which
    // is both the root and the parent.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex }};
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // A marked root beside an unmarked tag, no reply marker: the root wins
    // (the middle of the reply-orelse-root-orelse-positional chain).
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "", "root" },
            &.{ "e", deep_hex },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Parent(&tags).?));
    }
    // A lone `mention` never makes the note a reply.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", root_hex, "", "mention" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // A short id is rejected by the length guard, not a parent.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "zz", "", "reply" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // A 64-char NON-hex id passes the length guard and must be rejected by the
    // decode itself.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "zz" ** 32, "", "reply" }};
        try testing.expect(main.nip10Parent(&tags) == null);
    }
    // Uppercase hex decodes: the wire has both casings, and parents match on
    // decoded bytes, not on the raw string.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", "AB" ** 32, "", "reply" }};
        try testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 32), &(main.nip10Parent(&tags).?));
    }
    // No e tags at all.
    try testing.expect(main.nip10Parent(&.{}) == null);
}

fn threadNote(event_byte: u8, created_at: i64, parent_byte: u8) main.Note {
    var note = main.Note{ .created_at = created_at };
    note.event_id = [_]u8{event_byte} ** 32;
    if (parent_byte != 0) {
        note.reply_parent = [_]u8{parent_byte} ** 32;
        note.has_reply_parent = true;
    }
    return note;
}

test "arrangeThread seats replies under their parents, siblings oldest-first" {
    const root = [_]u8{0xAA} ** 32;
    // Chronological input: a (to root), b (to root), c (to a), d (to c),
    // e (to root), f (orphan parent never fetched).
    var notes = [_]main.Note{
        threadNote(1, 100, 0xAA),
        threadNote(2, 200, 0xAA),
        threadNote(3, 300, 1),
        threadNote(4, 400, 3),
        threadNote(5, 500, 0xAA),
        threadNote(6, 600, 0x77),
    };
    main.arrangeThread(&notes, root);
    // Conversation order: a, then a's subtree (c, then d), then b, e, f.
    const want_order = [_]u8{ 1, 3, 4, 2, 5, 6 };
    const want_depth = [_]u8{ 1, 2, 3, 1, 1, 1 };
    for (notes, 0..) |note, i| {
        try testing.expectEqual(want_order[i], note.event_id[0]);
        try testing.expectEqual(want_depth[i], note.depth);
    }
}

test "arrangeThread never loops on a parent cycle" {
    const root = [_]u8{0xAA} ** 32;
    // x and y answer each other; z answers the root.
    var notes = [_]main.Note{
        threadNote(1, 100, 2),
        threadNote(2, 200, 1),
        threadNote(3, 300, 0xAA),
    };
    main.arrangeThread(&notes, root);
    // The cycle strands x and y; both surface at the top level after z,
    // still oldest-first (x before y).
    try testing.expectEqual(@as(u8, 3), notes[0].event_id[0]);
    try testing.expectEqual(@as(u8, 1), notes[1].event_id[0]);
    try testing.expectEqual(@as(u8, 2), notes[2].event_id[0]);
    try testing.expectEqual(@as(u8, 1), notes[0].depth);
    try testing.expectEqual(@as(u8, 1), notes[1].depth);
    try testing.expectEqual(@as(u8, 1), notes[2].depth);
}

test "arrangeThread stamps a lone reply without a full pass" {
    const root = [_]u8{0xAA} ** 32;
    var one = [_]main.Note{threadNote(1, 100, 0xAA)};
    main.arrangeThread(&one, root);
    try testing.expectEqual(@as(u8, 1), one[0].depth);
    var none = [_]main.Note{};
    main.arrangeThread(&none, root);
}

test "threadIndentLevels caps the visual indent" {
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(0));
    try testing.expectEqual(@as(usize, 0), main.threadIndentLevels(1));
    try testing.expectEqual(@as(usize, 1), main.threadIndentLevels(2));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(4));
    try testing.expectEqual(@as(usize, 3), main.threadIndentLevels(255));
}

fn threadEvent(id_byte: u8, created_at: i64, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0x11} ** 32,
        .created_at = created_at,
        .kind = 1,
        .tags = tags,
        .content = "note",
        .sig = [_]u8{0} ** 64,
    };
}

test "collectThreadIds keeps the thread, anchors orphans, rejects quotes and foreign replies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/thread.mdb", .{dir_buf[0..dir_len]});
    var store = try nostr.store.Store.open(path.ptr, .{});
    defer store.deinit();

    const root_hex = "aa" ** 32;
    const gpa = testing.allocator;
    // The root itself, then a small thread: A answers the root, B answers A,
    // F answers B; E answers a parent that never reached the store but also
    // carries the usual root tag; C only QUOTES the root (mention); D is a
    // reply in a FOREIGN thread that quotes our root in passing.
    _ = try store.ingest(gpa, threadEvent(0xAA, 100, &.{}), .{});
    _ = try store.ingest(gpa, threadEvent(0x01, 110, &.{&.{ "e", root_hex, "", "root" }}), .{});
    _ = try store.ingest(gpa, threadEvent(0x02, 120, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "01" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x06, 130, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "02" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x05, 140, &.{ &.{ "e", root_hex, "", "root" }, &.{ "e", "99" ** 32, "", "reply" } }), .{});
    _ = try store.ingest(gpa, threadEvent(0x03, 150, &.{&.{ "e", root_hex, "", "mention" }}), .{});
    _ = try store.ingest(gpa, threadEvent(0x04, 160, &.{ &.{ "e", root_hex, "", "mention" }, &.{ "e", "ee" ** 32, "", "root" }, &.{ "e", "dd" ** 32, "", "reply" } }), .{});

    var ids: [100][32]u8 = undefined;
    const n = main.collectThreadIds(&store, [_]u8{0xAA} ** 32, &ids);
    // A, B, F, and the anchored orphan E; never the quote or the foreign reply.
    try testing.expectEqual(@as(usize, 4), n);
    const want = [_]u8{ 0x01, 0x02, 0x06, 0x05 };
    for (want, 0..) |b, i| try testing.expectEqual(b, ids[i][0]);
}

test "nip10References sees ancestor ties, never mentions" {
    const root_hex = "aa" ** 32;
    const root_id = [_]u8{0xAA} ** 32;
    try testing.expect(main.nip10References(&.{&.{ "e", root_hex, "", "root" }}, root_id));
    try testing.expect(main.nip10References(&.{&.{ "e", root_hex }}, root_id));
    try testing.expect(!main.nip10References(&.{&.{ "e", root_hex, "", "mention" }}, root_id));
    try testing.expect(!main.nip10References(&.{&.{ "e", "bb" ** 32, "", "root" }}, root_id));
}

test "every registered app icon resolves, so no view draws the missing glyph" {
    main.registerIcons();
    // The names Plaza's views ask for by `ui.appIcon`. A typo or a dropped
    // registration would silently draw the slashed-circle fallback in the app,
    // so the resolution is asserted here instead.
    for ([_][]const u8{ "reply", "like", "zap", "notary", "bell", "mark" }) |name| {
        try testing.expect(canvas.icons.resolve(name) != null);
    }
    // The built-in names the Working set reuses (the redesign's icon set is the
    // SDK's own set), so a future SDK bump that renames one fails here.
    for ([_][]const u8{
        "alert",        "archive",      "arrow-right",   "arrow-up",   "check",         "check-circle",
        "chevron-down", "chevron-left", "chevron-right", "chevron-up", "circle-dot",    "clock",
        "copy",         "download",     "edit",          "ellipsis",   "external-link", "eye",
        "plus",         "repeat",       "search",        "settings",   "terminal",      "volume",
        "x",            "x-circle",
    }) |name| {
        try testing.expect(canvas.icons.find(name) != null);
    }
    // An unregistered name must NOT resolve, or the assertions above prove nothing.
    try testing.expect(canvas.icons.resolve("plaza-no-such-icon") == null);
}

test "the identity violet is what the info token actually resolves to" {
    // The views name the violet two ways: element foregrounds take
    // `palette.accent_identity` directly, and text spans reference the `info`
    // token (a span names a token field, not a Color). Both must land on the same
    // color, or a handle and a mention in the same row would disagree.
    const model = Model{};
    const tokens = theme.tokens(Model)(&model);
    try testing.expectEqual(theme.palette.accent_identity, tokens.colors.info);
    // And the violet is a violet: blue-dominant, with red above green.
    const v = theme.palette.accent_identity;
    try testing.expect(v.b > v.r and v.r > v.g);
}

test "a feed row's estimated height is the sum of its measured parts" {
    // The virtual list prices unbuilt rows from this estimate, so it has to agree
    // with what the engine lays out. The literals are MEASURED from the running
    // app through the automation harness; the constants are the redesign's own
    // terms. Changing a term without re-measuring fails here, which is the drift
    // this pins. (It cannot catch the engine itself changing a metric: that shows
    // up as a live measurement mismatch, not a test failure.)
    const one_line = main.feed_row_chrome + main.body_line_height;
    try testing.expectApproxEqAbs(@as(f32, 126.125), one_line, 0.001);
    // The chrome is 12 above, the 36px identity block, 5 to the body, 10 to the
    // verbs, the verb strip, 14 below, and the hairline.
    try testing.expectApproxEqAbs(@as(f32, 108), main.feed_row_chrome, 0.001);
    // The verb row is a STATED height now. It used to be exactly the count's
    // line box, so the verbs sat hard against the rule above them and the row
    // below: a strip of icons rather than a row of controls.
    try testing.expectApproxEqAbs(@as(f32, 30), main.engagement_row_height, 0.001);
    // The metadata register is exactly 12px. `.size = .sm` would be 13.5, since
    // the size enum steps by one from the 14.5 body.
    try testing.expectApproxEqAbs(@as(f32, 12), main.meta_size, 0.001);
}

// -------------------------------------------------------- painted surfaces
//
// These assert the COLOUR the renderer emits, not the widget tree. Four features
// of this redesign shipped invisible while their trees looked perfect (see
// painted.zig), so every surface that must show its own fill is pinned here.

test "every chrome surface actually paints its fill" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const p = try painted.Painted.render(arena_state.allocator(), &model);
    const pal = theme.palette;

    // The rail's home plate. This is the assertion that would have caught the
    // rail painting as bare window for the whole life of the rail.
    try painted.expectFillAt(p, 28, 28, pal.surface_rail_tile);

    // A quiet rail tile has NO PLATE: what covers it is the rail's own colour,
    // not a tile surface. Worth asserting, because a panel with no stated
    // background falls back to the house card fill and would draw a plate the
    // design does not have.
    //
    // This asked for NOTHING painted until SDK 0.6.2, which made explicit
    // backgrounds on rows and columns paint for the first time: the rail column
    // states the window colour and now draws it, where before the host's clear
    // showed through instead. Identical on screen, and a different question to
    // ask, so the question changed rather than the expectation being widened.
    try painted.expectFillAt(p, 28, 506, pal.surface_window);
}

test "the compose tile is the one bright surface in the window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    const p = try painted.Painted.render(arena_state.allocator(), &model);

    // 11a's whole point about the rail: compose is the single bright tile. It had
    // never once painted.
    const fill = p.fillAtCenterOf("New note") orelse return error.NoComposeTile;
    try testing.expect(painted.sameColor(fill, theme.palette.accent));

    // And it wears no border. A panel strokes its frame whether or not one was
    // asked for, falling back to the house hairline, which put a #26262c ring
    // around the bright tile until it was told not to.
    const frame = p.frameOf("New note") orelse return error.NoComposeTile;
    try testing.expect(!p.hasStrokeAt(frame.x, frame.y + frame.height / 2, theme.palette.border_hairline));
}

test "the guest banner paints behind its own copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    // The banner only exists for a guest, which `initialModel` already is (no
    // active pubkey), and only until it is dismissed.
    try testing.expect(model.is_guest() and model.show_guest_strip());

    const p = try painted.Painted.render(arena_state.allocator(), &model);
    const pal = theme.palette;

    // Inside the banner, left of its copy: the banner's own surface, which was
    // stated on a column and therefore never drawn.
    try painted.expectFillAt(p, 300, 20, pal.surface_subbar);

    // The filled pill, and the fact that it carries no borrowed hairline.
    const pill = p.frameOf("Create identity") orelse return error.NoPill;
    const pill_fill = p.fillAt(pill.x + pill.width / 2, pill.y + pill.height / 2) orelse return error.PillNotPainted;
    try testing.expect(painted.sameColor(pill_fill, pal.accent));
    try testing.expect(!p.hasStrokeAt(pill.x, pill.y + pill.height / 2, pal.border_hairline));
}

test "a note row's separator paints at the reading column's width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{7} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a row that needs a line under it");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_000);
    model.notes_len = 1;
    const p = try painted.Painted.render(arena, &model);

    // Round 3 spent a PR on separators that were never drawn at all (an empty
    // column with a background paints nothing, so the fix was the `.separator`
    // element). This holds that line: SOMETHING of the divider ink is painted.
    var found = false;
    for (p.commands) |command| {
        switch (command) {
            .fill_rect => |v| {
                if (painted.sameColor(switch (v.fill) {
                    .color => |c| c,
                    else => continue,
                }, theme.palette.divider_row) and v.rect.width > 400) found = true;
            },
            else => {},
        }
    }
    try testing.expect(found);
}

/// Every codepoint in a widget's own text, and in each of its paragraph spans,
/// checked against `ok`. Returns the first character that fails, with the string
/// it came from, so a failure names the copy rather than a number.
const BadGlyph = struct { codepoint: u21, in: []const u8 };

fn firstUnrenderable(widget: canvas.Widget) ?BadGlyph {
    if (scanRun(widget.text)) |bad| return bad;
    for (widget.spans) |span| {
        if (scanRun(span.text)) |bad| return bad;
    }
    for (widget.children) |child| {
        if (firstUnrenderable(child)) |bad| return bad;
    }
    return null;
}

fn scanRun(text: []const u8) ?BadGlyph {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .codepoint = text[i], .in = text };
        if (i + len > text.len) return .{ .codepoint = text[i], .in = text };
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return .{ .codepoint = text[i], .in = text };
        if (!chromeGlyphIsSafe(cp)) return .{ .codepoint = cp, .in = text };
        i += len;
    }
    return null;
}

/// The characters Plaza's own chrome may use. ASCII, plus the typographic marks
/// the bundled Geist faces carry and the redesign's copy actually asks for.
///
/// The bar is deliberately an ALLOWLIST rather than a list of known-bad glyphs:
/// the SDK ships a coverage table naming ⌘, ✓ and friends as the recurring tofu
/// class, but it is private to the canvas module and only warns at debug level in
/// Debug builds, so an uncovered character reaches a release window as a silent
/// box. (It did: the relay menu's ⌘ hint drew as tofu until this test.)
fn chromeGlyphIsSafe(cp: u21) bool {
    if (cp >= 0x20 and cp < 0x7F) return true; // printable ASCII
    return switch (cp) {
        0x00B7, // · the metadata separator
        0x2026, // … an elision
        0x2018,
        0x2019,
        0x201C,
        0x201D, // curly quotes
        0x2013, // en dash
        => true,
        else => false,
    };
}

test "the chrome never asks for a glyph the bundled faces cannot draw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Chrome only: an empty feed, so no note content (which is the user's, may be
    // any language or emoji, and is not ours to constrain) is in the tree.
    var model = main.initialModel();
    model.stage = .ready;

    // Each chrome menu in turn, since a closed menu builds nothing.
    for ([_]main.ChromeMenu{ .none, .scope, .relays, .account }) |menu| {
        model.menu = menu;
        const tree = try buildTree(arena, &model);
        if (firstUnrenderable(tree.root)) |bad| {
            std.debug.print(
                "\n  chrome text contains U+{X:0>4} in \"{s}\" (menu: {s}). The bundled faces do not" ++
                    " carry it, so it draws as a tofu box. Use a vector icon or plain words.\n",
                .{ bad.codepoint, bad.in, @tagName(menu) },
            );
            return error.UnrenderableChromeGlyph;
        }
    }
}

test "an open chrome menu paints a real surface above the bar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .relays;
    const p = try painted.Painted.render(arena_state.allocator(), &model);

    // The popover is anchored, so it leaves the row's flow entirely and paints in
    // a late window-level pass. Both halves matter: it must PAINT (a menu that
    // renders nothing is the rail bug again) and it must sit ABOVE the 30px bar
    // it hangs off rather than being clipped into it.
    const pause = p.frameOf("Pause Relays") orelse return error.NoPopover;
    try testing.expect(pause.y + pause.height < main.window_height - 30);

    const fill = p.fillAt(pause.x + pause.width / 2, pause.y + pause.height / 2) orelse return error.PopoverNotPainted;
    try testing.expect(painted.sameColor(fill, theme.palette.surface_menu));
}

test "only one chrome menu is open at a time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.stage = .ready;

    // A trigger toggles its own menu and replaces any other, so two floating
    // surfaces can never overlap in the chrome.
    var fx: main.EffectsForTest = undefined;
    model.menu = .relays;
    main.update(&model, Msg{ .toggle_menu = .account }, &fx);
    try testing.expectEqual(main.ChromeMenu.account, model.menu);
    main.update(&model, Msg{ .toggle_menu = .account }, &fx);
    try testing.expectEqual(main.ChromeMenu.none, model.menu);
}

test "one straggler is not a fault, at any pool size" {
    // The redesign's at-rest bar reads "4/5 relays" in green while its working
    // bar reads "3/5" in amber. A bar that goes amber for one straggler is a bar
    // nobody reads.
    //
    // That was written as four fifths, which says the same thing ONLY for a pool
    // of five or more. At four relays four fifths demands four of four, so a
    // single relay down leaves the dot amber for good, and this test kept passing
    // while asserting exactly that, because the arithmetic moved under it when
    // the bootstrap list lost a relay. Stated against the sizes now, so the next
    // change to the list cannot quietly redefine health.
    try testing.expect(main.poolIsHealthyOfForTest(5, 5));
    try testing.expect(main.poolIsHealthyOfForTest(4, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(3, 5));

    try testing.expect(main.poolIsHealthyOfForTest(4, 4));
    try testing.expect(main.poolIsHealthyOfForTest(3, 4));
    try testing.expect(!main.poolIsHealthyOfForTest(2, 4));

    try testing.expect(main.poolIsHealthyOfForTest(2, 3));
    try testing.expect(!main.poolIsHealthyOfForTest(1, 3));

    // And nothing connected is never healthy, whatever the size. A one-relay
    // pool with nothing up satisfies "one straggler" on its own, which is why
    // the rule carries a second clause.
    try testing.expect(!main.poolIsHealthyOfForTest(0, 1));
    try testing.expect(main.poolIsHealthyOfForTest(1, 1));
    try testing.expect(!main.poolIsHealthyOfForTest(0, 5));

    // The pool the app is born with, with one relay down, has to be green.
    main.resetRelaysForTest();
    try testing.expect(main.poolIsHealthyForTest(main.bootstrap_relay_count_for_test - 1));
    try testing.expect(!main.poolIsHealthyForTest(0));
}

test "a latency reading survives only as long as its connection" {
    main.clearRelayRttForTest(0);
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(0));

    // Sub-millisecond answers are readings, not holes: a warm relay that replies
    // in under a millisecond truncates to zero, which must not read as "never
    // answered".
    main.recordRelayRttForTest(0, 0);
    try testing.expectEqual(@as(?u16, 0), main.relayRttMs(0));

    // An even number of samples takes the middle of the two middles, so a reading
    // is not silently the slower one.
    main.clearRelayRttForTest(0);
    main.recordRelayRttForTest(0, 10);
    main.recordRelayRttForTest(0, 20);
    try testing.expectEqual(@as(?u16, 15), main.relayRttMs(0));

    // And a relay that drops forgets: the bar must never show a number measured
    // on a connection that no longer exists.
    main.clearRelayRttForTest(0);
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(0));
}

test "a thread groups into one block per conversation, with the branch counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // root
    //  +- a          (depth 1)  a conversation
    //  |   +- c      (depth 2)  shown in place under a
    //  |       +- d  (depth 3)  out of sight, counted against c
    //  +- b          (depth 1)  a second conversation, nothing under it
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xB1, 110, 0xAA),
        threadNote(0xC1, 120, 0xA1),
        threadNote(0xD1, 130, 0xC1),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    // Two conversations, not four notes: that is what a page of a thread counts.
    try testing.expectEqual(@as(usize, 2), blocks.len);

    // The first carries its one visible child, and the child reports the reply
    // hanging below it that the block does not draw.
    try testing.expectEqual(@as(usize, 1), blocks[0].children.len);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &blocks[0].children[0].event_id);
    try testing.expectEqual(@as(usize, 1), blocks[0].deeper[0]);

    // The second is a leaf: no children, nothing counted.
    try testing.expectEqual(@as(usize, 0), blocks[1].children.len);
    try testing.expectEqual(@as(usize, 0), blocks[1].deeper.len);
}

test "a branch several levels deep counts every hidden reply against the child it hangs from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One conversation, five levels down. Only the first child shows; the three
    // below it are the branch.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xC1, 110, 0xA1),
        threadNote(0xD1, 120, 0xC1),
        threadNote(0xE1, 130, 0xD1),
        threadNote(0xF1, 140, 0xE1),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 1), blocks[0].children.len);
    try testing.expectEqual(@as(usize, 3), blocks[0].deeper[0]);
}

test "two children of one reply each keep their own branch count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // a has two replies; only the second continues.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xC1, 110, 0xA1),
        threadNote(0xC2, 120, 0xA1),
        threadNote(0xD1, 130, 0xC2),
    };
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 2), blocks[0].children.len);
    // The count follows the child it belongs to, not the block.
    try testing.expectEqual(@as(usize, 0), blocks[0].deeper[0]);
    try testing.expectEqual(@as(usize, 1), blocks[0].deeper[1]);
}

test "a late reply lands after what is already read, however old it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // Two replies read in the first batch, then one that arrives later but was
    // WRITTEN before both. Chronology alone would slot it at the top, moving the
    // ground under a reader mid-thread; arrival order appends it.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 200, 0xAA),
        threadNote(0xB1, 300, 0xAA),
        threadNote(0xC1, 100, 0xAA),
    };
    // Stamped by the REAL stamper, in the order the app would see them: the
    // first two while the thread was still settling, the third afterwards.
    var table = main.arrivalTableForTest();
    main.stampArrivalForTest(&table, notes[0..2], true);
    main.stampArrivalForTest(&table, &notes, true);
    try testing.expectEqual(notes[0].arrival, notes[1].arrival);
    try testing.expect(notes[2].arrival > notes[0].arrival);
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 3), blocks.len);
    // The first batch keeps its chronological order, and the straggler is last.
    try testing.expectEqualSlices(u8, &[_]u8{0xA1} ** 32, &blocks[0].parent.event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xB1} ** 32, &blocks[1].parent.event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &blocks[2].parent.event_id);
}

test "replies from outside the follow graph are held below, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One reply from a followed account, one from a stranger.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xA1, 100, 0xAA),
        threadNote(0xB1, 110, 0xAA),
    };
    notes[0].pubkey = main.followSetForTest()[0];
    notes[1].pubkey = [_]u8{0x77} ** 32; // nobody followed
    // Whoever wrote the note being read: nobody followed here either, so the
    // test also pins that the split never holds a third party by accident.
    const root_author = [_]u8{0x66} ** 32;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    const split = main.splitByFollowGraphForTest(&ui, blocks, root_author);
    try testing.expectEqual(@as(usize, 1), split.inside.len);
    try testing.expectEqual(@as(usize, 1), split.outside.len);
    // Nothing is lost: every reply is in one tier or the other.
    try testing.expectEqual(blocks.len, split.inside.len + split.outside.len);
    try testing.expect(main.inFollowGraph(split.inside[0].parent.pubkey));
    try testing.expect(!main.inFollowGraph(split.outside[0].parent.pubkey));
}

test "somebody you follow is in your graph however far down the list they are" {
    // The thread split asked `followSet()` when it wanted membership. That slice
    // used to be a small cap, so a reader with three hundred follows was told
    // that follows 129 and up were strangers, in every thread, forever. And
    // `writeFollow` APPENDS, so the people they had followed most recently were
    // the ones most likely to be filed under "replies outside your graph".
    //
    // The feed reads the whole list now, so the two are the same set for any
    // list the table holds. What is still worth pinning is the shape of the old
    // failure: fill the table completely and the person added LAST is in the
    // graph, because that is the one an off-by-a-cap loses first.
    main.setIdentityForTest([_]u8{0xe1} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();

    // Heap, not stack: a full table is sixty-five kilobytes of pubkeys and a
    // Debug build does not economise on frames.
    var list_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer list_arena.deinit();
    const total = main.max_follows;
    const list = try list_arena.allocator().alloc([32]u8, total);
    for (0..total) |i| {
        @memset(&list[i], 0);
        list[i][0] = @intCast(i / 256);
        list[i][1] = @intCast(i % 256);
        list[i][31] = 0xe2;
    }
    try testing.expect(main.setFollowsForTest(list[0..total], 1_800_000_000));

    // The front of the list, which always worked even at the old cap.
    try testing.expect(main.inFollowGraph(list[0]));
    try testing.expect(main.inFollowGraph(list[127]));

    // THE PROPERTY: deep into the list, where the old cap cut. The last person
    // they followed, and one in the middle of the tail.
    try testing.expect(main.inFollowGraph(list[128]));
    try testing.expect(main.inFollowGraph(list[total / 2]));
    try testing.expect(main.inFollowGraph(list[total - 1]));

    // And a stranger is still a stranger, so this is not just "always true".
    const nobody = [_]u8{0x99} ** 32;
    try testing.expect(!main.inFollowGraph(nobody));

    // Your own replies are inside your conversation, though you do not follow
    // yourself.
    try testing.expect(main.inFollowGraph(main.activePubkeyForTest().?));
}

test "bringing a key through the Notary window signs you in after a sign-out" {
    // The ceremony exits 0 for an import, so `handleNotaryExited` reads it as
    // "not a mint" and signs nobody in: the daemon health check is the only thing
    // that carries the result back, and it opens with `if (g_logged_out) return`.
    //
    // Two of the three ceremony spawn sites drop that latch. This one never did,
    // so a reader who had signed out earlier in the same run pasted their key,
    // watched the window say it was done, and sat in guest mode until they quit.
    // It looked intermittent because the latch is false at launch: it only bites
    // on a run where something signed out first, which is why the second attempt
    // from a fresh start worked.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setCeremonyForTest(.none);

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    // Sign out, which is the precondition. Then press "Bring your key".
    main.setIdentityForTest([_]u8{0xe3} ** 32);
    main.performLogoutForTest(&model, &fx);
    try testing.expect(main.loggedOutForTest());
    // The real message, through the real handler. With no Notary window found,
    // `ceremonyCanTakeKey` is false and the arm takes its fallback rung without
    // touching `Effects`, which is why the latch clear sits above the branch.
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(!main.loggedOutForTest());
    try testing.expectEqual(main.Stage.onboarding, model.stage);
}

test "the reader's own face goes in the rail seat, not their initials" {
    // Every link already worked. The reader's own kind:0 is asked for by the feed
    // subscription and by the dedicated profile round, `refreshProfiles` puts
    // their pubkey in the author list explicitly, and `assignAvatarSlots` pushes
    // them FIRST so they win one of the nine scarce ids ahead of any feed author.
    // All of that ran, and then the widget was built without the id it had earned:
    // `meAvatar` set width, height and style and never `.image`, so it took the
    // initials branch on every frame forever.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0xe4} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest().?;

    var model = main.initialModel();
    model.stage = .ready;

    // No face known yet: initials, which is correct and is what it always did.
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 0), avatarImageIn(seat));
    }

    // A loaded face. The `.loaded` gate is the load-bearing half: the renderer
    // takes the image branch for ANY non-zero id and draws initials only in the
    // else, so a claimed-but-not-arrived id would paint an EMPTY disc.
    main.setProfileAvatarForTest(me, 3, .fetching);
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 0), avatarImageIn(seat));
    }

    main.setProfileAvatarForTest(me, 3, .loaded);
    {
        const tree = try buildTree(arena, &model);
        const seat = findByLabel(tree.root, "You") orelse return error.NoRailSeat;
        try testing.expectEqual(@as(u64, 3), avatarImageIn(seat));
    }
}

/// The image id on the avatar widget inside `widget`, or 0 if there is none.
fn avatarImageIn(widget: canvas.Widget) u64 {
    if (widget.kind == .avatar and widget.image_id != 0) return widget.image_id;
    for (widget.children) |child| {
        const found = avatarImageIn(child);
        if (found != 0) return found;
    }
    return 0;
}

test "a profile shows the address it was verified as, not just a tick" {
    // The page drew a bare check next to the name and no address anywhere, so a
    // verified profile said "verified" without ever saying verified as WHAT. The
    // domain is the half that names who vouched, and this is the one screen a
    // reader opens specifically to decide whether somebody is who they claim.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var who: [32]u8 = undefined;
    @memset(&who, 0x7c);
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = who;

    // Verified: the address is on the page.
    main.setProfileNip05ForTest(who, "someone@example.com", true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "someone@example.com"));
    }

    // The root form is shown as the bare domain, which is what `_@domain` means.
    main.setProfileNip05ForTest(who, "_@example.com", true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "example.com"));
        try testing.expect(!findAnyTextContaining(tree.root, "_@example.com"));
    }

    // THE PROPERTY THAT MATTERS: unverified shows NOTHING. An address the app has
    // not checked, printed under a name, reads as an endorsement to everyone who
    // has seen one anywhere else, which is the impersonation this guards against.
    main.setProfileNip05ForTest(who, "impostor@example.com", false);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(!findAnyTextContaining(tree.root, "impostor@example.com"));
    }
    try testing.expectEqualStrings("", main.verifiedNip05ForTest(who));
}

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

test "a thread still loading is one batch, however the relays interleave it" {
    // The bug this pins: batching from the first build split a thread's OPENING
    // read into one batch per tick, so the conversation froze into the order the
    // relays happened to answer in rather than the order it was written.
    var table = main.arrivalTableForTest();
    var first = [_]main.Note{threadNote(0xA1, 300, 0xAA)};
    main.stampArrivalForTest(&table, &first, false);

    // A second relay answers with an OLDER reply while the fetch is still out.
    var both = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
    };
    main.stampArrivalForTest(&table, &both, false);
    // Same batch, so the sort put the older one first.
    try testing.expectEqual(both[0].arrival, both[1].arrival);
    try testing.expectEqualSlices(u8, &[_]u8{0xB1} ** 32, &both[0].event_id);

    // The build that settles is still the last build of the opening read, so
    // what it brings is chronological too: the oldest reply leads.
    var settling = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xC1, 50, 0xAA),
    };
    main.stampArrivalForTest(&table, &settling, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xC1} ** 32, &settling[0].event_id);
    try testing.expectEqualSlices(u8, &[_]u8{0xA1} ** 32, &settling[2].event_id);

    // NOW a reply that turns up lands after everything already read, however
    // long ago it was written.
    var late = [_]main.Note{
        threadNote(0xA1, 300, 0xAA),
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xC1, 50, 0xAA),
        threadNote(0xD1, 10, 0xAA),
    };
    main.stampArrivalForTest(&table, &late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xD1} ** 32, &late[3].event_id);
    // And re-seeing the same set does not move it back.
    main.stampArrivalForTest(&table, &late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xD1} ** 32, &late[3].event_id);
}

test "the held line counts replies, not conversations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // One stranger's reply with two answers under it: ONE conversation, THREE
    // replies. The line says "N replies", so N is three.
    const root = [_]u8{0xAA} ** 32;
    var notes = [_]main.Note{
        threadNote(0xB1, 100, 0xAA),
        threadNote(0xB2, 110, 0xB1),
        threadNote(0xB3, 120, 0xB1),
    };
    for (&notes) |*note| note.pubkey = [_]u8{0x77} ** 32;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 3), main.heldReplies(blocks));
}

test "the thread's own author is never held below their own thread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    // Opening a stranger's reply as a thread: their continuation of it must read
    // inline, not behind a collapsed line, or the thread opens with no body.
    const root = [_]u8{0xAA} ** 32;
    const author = [_]u8{0x77} ** 32;
    var notes = [_]main.Note{threadNote(0xB1, 100, 0xAA)};
    notes[0].pubkey = author;
    main.arrangeThread(&notes, root);

    const blocks = main.groupThreadBlocks(&ui, &notes);
    const split = main.splitByFollowGraphForTest(&ui, blocks, author);
    try testing.expectEqual(@as(usize, 1), split.inside.len);
    try testing.expectEqual(@as(usize, 0), split.outside.len);
}

test "every thread row is planned exactly once" {
    // The row plan is one function so the builder and the estimator cannot drift,
    // and this walks every shape it can take: with and without ancestors, a
    // hidden tail, a held tier open and closed, skeletons, and the empty line.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    var note = threadNote(0xA1, 100, 0);
    var notes = [_]main.Note{
        threadNote(0xB1, 110, 0xA1),
        threadNote(0xB2, 120, 0xA1),
        threadNote(0xB3, 130, 0xA1),
    };
    main.arrangeThread(&notes, [_]u8{0xA1} ** 32);
    const blocks = main.groupThreadBlocks(&ui, &notes);
    const ancestors = [_]main.Ancestor{ .{ .ghost = .missing }, .{} };
    var model = main.Model{};

    const shapes = [_]main.ThreadRows{
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = blocks, .shown = blocks.len, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &ancestors, .blocks = blocks, .shown = 1, .hidden = blocks.len - 1, .hidden_held = blocks.len - 1, .outside = blocks[0..1], .outside_held = 1, .outside_open = false, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &ancestors, .blocks = blocks, .shown = 1, .hidden = blocks.len - 1, .hidden_held = blocks.len - 1, .outside = blocks[0..2], .outside_held = 2, .outside_open = true, .skeletons = false, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = &.{}, .shown = 0, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = true, .empty = false, .footer = true },
        .{ .model = &model, .root = &note, .ancestors = &.{}, .blocks = &.{}, .shown = 0, .hidden = 0, .hidden_held = 0, .outside = &.{}, .outside_held = 0, .outside_open = false, .skeletons = false, .empty = true, .footer = false },
    };

    for (shapes, 0..) |rows, shape| {
        var seen_focal: usize = 0;
        var seen_composer: usize = 0;
        var seen_footer: usize = 0;
        var ancestors_seen: usize = 0;
        var blocks_seen: usize = 0;
        var outside_seen: usize = 0;
        for (0..rows.count()) |i| {
            switch (rows.rowAt(i)) {
                // Each index into a slice must be in range, and each must appear
                // exactly once and in order.
                .ancestor => |ai| {
                    try testing.expectEqual(ancestors_seen, ai);
                    ancestors_seen += 1;
                },
                .focal => seen_focal += 1,
                .composer => seen_composer += 1,
                .block => |bi| {
                    try testing.expectEqual(blocks_seen, bi);
                    blocks_seen += 1;
                },
                .outside_block => |oi| {
                    try testing.expectEqual(outside_seen, oi);
                    outside_seen += 1;
                },
                .footer => seen_footer += 1,
                .show_more, .outside_line, .skeleton, .empty => {},
            }
        }
        errdefer std.debug.print("shape {d}\n", .{shape});
        try testing.expectEqual(@as(usize, 1), seen_focal);
        try testing.expectEqual(@as(usize, 1), seen_composer);
        try testing.expectEqual(@as(usize, @intFromBool(rows.footer)), seen_footer);
        try testing.expectEqual(rows.ancestors.len, ancestors_seen);
        try testing.expectEqual(rows.shown, blocks_seen);
        try testing.expectEqual(if (rows.outside_open) rows.outside.len else 0, outside_seen);
    }
}

// A note's body, so a row under test has something to wrap.
fn ancestorNote(text: []const u8) main.Note {
    var note = threadNote(0xA1, 100, 0xAA);
    @memcpy(note.content_buf[0..text.len], text);
    note.content_len = @intCast(text.len);
    return note;
}

test "the rail between two discs actually paints" {
    // It did not, for as long as the nesting existed: the row pinned its
    // children to the top, so the disc's column was exactly as tall as the disc
    // and the rail, which grows into whatever is left, got nothing. A widget-tree
    // assertion cannot see that; the display list can.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Build = struct {
        var note: main.Note = undefined;
        var ancestor: main.Ancestor = undefined;
        fn ancestorRow(ui: *main.AppUi) main.AppUi.Node {
            return main.ancestorRowForTest(ui, &ancestor, true);
        }
    };
    Build.note = ancestorNote("Two lines of an ancestor, enough to make the row taller than its own disc so the rail has somewhere to run.");
    Build.ancestor = .{ .note = Build.note };

    const p = try painted.Painted.renderPiece(arena, &model, Build.ancestorRow, main.window_width, 300);
    // The rail hangs under the disc, on the disc's centre line.
    const x = main.thread_inset_for_test + main.avatar_size / 2;
    const top = main.ancestor_top_pad + main.avatar_size + 4;
    try testing.expect(p.hasFillAt(x, top + 6, theme.palette.border_hairline));
}

test "nip10Root names what the ghost row is missing" {
    // The ghost row says "Root note not on your relays yet" only when the id the
    // chain stops below IS the thread's root, so the claim is only as good as
    // this.
    const root_hex = "01" ** 32;
    const mid_hex = "02" ** 32;
    const quote_hex = "03" ** 32;
    const root_id = [_]u8{0x01} ** 32;

    // A marked root wins wherever it sits, and a marked reply is never the root.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", mid_hex, "", "reply" },
            &.{ "e", root_hex, "wss://r", "root" },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Root(&tags).?));
    }
    // Positional (the deprecated scheme): the FIRST e tag is the root, which is
    // the opposite end from the parent.
    {
        const tags = [_]nostr.event.Tag{
            &.{ "e", root_hex, "" },
            &.{ "e", mid_hex, "" },
        };
        try testing.expectEqualSlices(u8, &root_id, &(main.nip10Root(&tags).?));
    }
    // A quoted note is not an ancestor, so it never stands in for the root.
    {
        const tags = [_]nostr.event.Tag{&.{ "e", quote_hex, "", "mention" }};
        try testing.expect(main.nip10Root(&tags) == null);
    }
    // A root's own tags name no root, which is how the walk knows it arrived.
    {
        const tags = [_]nostr.event.Tag{&.{ "p", "ab" ** 32 }};
        try testing.expect(main.nip10Root(&tags) == null);
    }
}

test "a deep back-stack still lays out" {
    // The SDK REFUSES a view past `max_canvas_widget_nodes_per_view`, whole: not
    // a truncated frame, no frame at all. Every mounted level used to build its
    // own rows, so six levels of a busy thread crossed the ceiling and the window
    // went blank. Occluded levels build nothing now, and this is the guard.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    const author = [_]u8{0x55} ** 32;
    model.thread_root.pubkey = author;

    // A page of conversation: twenty replies with two nested children each, all
    // by the thread's own author so none of them are held below the graph line.
    var n: usize = 0;
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        model.thread_notes[n] = threadNote(0x10 + i, 200 + @as(i64, i), 0xAA);
        model.thread_notes[n].pubkey = author;
        model.thread_notes[n].id = @as(i64, i) + 10;
        n += 1;
        var k: u8 = 0;
        while (k < 2) : (k += 1) {
            model.thread_notes[n] = threadNote(0x60 + i * 2 + k, 300 + @as(i64, i), 0x10 + i);
            model.thread_notes[n].pubkey = author;
            model.thread_notes[n].id = 1000 + @as(i64, i) * 2 + @as(i64, k);
            n += 1;
        }
    }
    model.thread_notes_len = n;

    for (0..main.thread_depth_max) |d| {
        model.thread_stack[d] = .{ .note = threadNote(0xC0 + @as(u8, @intCast(d)), 50, 0) };
        model.thread_stack[d].note.id = 500 + @as(i64, @intCast(d));
        model.thread_stack[d].note.pubkey = author;
    }
    // Settings at its LARGEST, not its default: eight relays is the cap, six
    // suggestions is the cap, and a local key adds the backup card with the
    // secret revealed. Measuring the sheet a fresh install happens to build
    // would be measuring the easy case, and the ceiling is not crossed by the
    // easy case.
    main.resetRelaysForTest();
    for (0..main.max_relays_for_test) |r| {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "wss://relay-{d}.a-fairly-long-hostname.example.com", .{r});
        _ = main.addRelayForTest(url, true, true);
    }
    const suggestion_tags = [_]nostr.event.Tag{
        &.{ "r", "wss://suggested-one.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-two.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-three.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-four.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-five.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-six.a-fairly-long-hostname.example.com", "write" },
    };
    main.ingestRelayListForTest(.{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &suggestion_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    });
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();
    model.reveal_nsec = true;

    // Every depth the stack can reach, including full, and with the Settings
    // sheet over it. Settings is a SHEET now rather than a screen, so it no
    // longer replaces this tree, it is added to it: the deepest stack plus the
    // largest sheet is the worst frame the app can be asked to build, and it is
    // the one that has to fit.
    main.resetInboxForTest();
    seedInbox(main.inbox_page * 2, 0xB0, 1_800_000_000);
    defer main.resetInboxForTest();
    // A feed as long as the buffer holds, under the thread. The windowed list
    // is supposed to build only what the viewport needs, and a thread over it
    // occludes even that, so this should cost nothing; it is here so that if
    // either ever stops being true, this is where it is caught.
    for (0..200) |k| {
        model.notes[k] = threadNote(0x77, 1_800_000_000, 0);
        model.notes[k].id = @intCast(k + 5000);
        model.notes[k].pubkey = author;
    }
    model.notes_len = 200;

    // Everything that can be on screen at once, over every depth the stack can
    // reach. A sheet is LAYERED on the feed rather than swapping it out, so the
    // frame the app has to draw is the base plus the sheet, and the base at
    // depth six is the most expensive tree in the app.
    const Frame = struct { name: []const u8, arm: *const fn (*Model) void };
    const frames = [_]Frame{
        .{ .name = "feed", .arm = struct {
            fn f(_: *Model) void {}
        }.f },
        .{ .name = "settings", .arm = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
            }
        }.f },
        .{ .name = "notifications", .arm = struct {
            fn f(m: *Model) void {
                m.notifications_open = true;
            }
        }.f },
        .{ .name = "compose", .arm = struct {
            fn f(m: *Model) void {
                m.composing = true;
            }
        }.f },
        .{ .name = "join", .arm = struct {
            fn f(m: *Model) void {
                m.joining = true;
            }
        }.f },
        .{ .name = "edit profile", .arm = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
                m.editing_profile = true;
            }
        }.f },
    };

    const thread_root = model.thread_root;
    for (frames) |frame| {
        // Depth 0 here means NO thread at all, not a thread at the bottom of the
        // stack: with a thread open the feed's own rows are occluded and cost
        // nothing, so a sweep that always has one open never measures the feed.
        // Live, a sheet over a plain loaded feed is the second most expensive
        // frame in the app, and it was the one this loop could not see.
        for (0..main.thread_depth_max + 2) |step| {
            model.stage = .ready;
            model.notifications_open = false;
            model.composing = false;
            model.joining = false;
            model.editing_profile = false;
            const depth = if (step == 0) 0 else step - 1;
            model.viewing_thread = if (step == 0) 0 else 1;
            model.thread_root = if (step == 0) .{} else thread_root;
            model.thread_stack_len = depth;
            frame.arm(&model);
            const p = painted.Painted.render(arena, &model) catch |err| {
                std.debug.print("{s} at step {d} refused: {s}\n", .{ frame.name, step, @errorName(err) });
                return err;
            };
            // A tenth of the ceiling has to be left over. Not because the
            // eleventh-hour node is special, but because the ceiling is a CLIFF
            // (the view is refused whole, so the window stops drawing) and a
            // frame that clears it by fifty nodes is one relay row, one section
            // or one more list item away from the app going blank in a state
            // nobody will think to test. The most expensive frame here is
            // notifications over the deepest thread, and it clears by 133.
            const headroom = native_sdk.runtime.max_canvas_widget_nodes_per_view / 10;
            if (p.layout.nodes.len + headroom >= native_sdk.runtime.max_canvas_widget_nodes_per_view) {
                std.debug.print(
                    "{s} at step {d}: {d} nodes, ceiling is {d}, and {d} of it has to stay free\n",
                    .{ frame.name, step, p.layout.nodes.len, native_sdk.runtime.max_canvas_widget_nodes_per_view, headroom },
                );
                return error.NodeCeilingCrossed;
            }
        }
    }
}

/// How tall a row actually lays out, and how many widgets it costs. The rows of
/// a windowed list are priced by constants, and a constant that says more than
/// the row draws is a scrollbar over nothing; one that says less is a list that
/// jumps as the reader scrolls into it.
fn measuredHeight(arena: std.mem.Allocator, model: *const main.Model, build: *const fn (*main.AppUi) main.AppUi.Node) !f32 {
    const p = try painted.Painted.renderPiece(arena, model, build, main.window_width, 4000);
    var bottom: f32 = 0;
    for (p.layout.nodes) |node| {
        // The root fills the box it was given, so it says nothing about the row.
        if (node.depth == 0) continue;
        const b = node.widget.frame.y + node.widget.frame.height;
        if (b > bottom) bottom = b;
    }
    return bottom;
}

test "every fixed-height thread row is priced at what it draws" {
    // Each of these was calibrated by hand and then drifted, which a windowed
    // list hides until the scrollbar is over nothing. An OCCLUDED level makes it
    // worse: it builds no rows, so its estimates are never corrected by a
    // measurement, and its restored scroll offset is measured against them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Rows = struct {
        fn ghost(ui: *main.AppUi) main.AppUi.Node {
            return main.ghostRowForTest(ui, false);
        }
        fn ghostCapped(ui: *main.AppUi) main.AppUi.Node {
            return main.ghostRowForTest(ui, true);
        }
        fn footer(ui: *main.AppUi) main.AppUi.Node {
            return main.listeningFooterForTest(ui);
        }
        fn outsideClosed(ui: *main.AppUi) main.AppUi.Node {
            return main.outsideGraphRowForTest(ui, false);
        }
        fn outsideOpen(ui: *main.AppUi) main.AppUi.Node {
            return main.outsideGraphRowForTest(ui, true);
        }
        fn showMore(ui: *main.AppUi) main.AppUi.Node {
            return main.showMoreRepliesForTest(ui);
        }
    };

    const cases = [_]struct { name: []const u8, build: *const fn (*main.AppUi) main.AppUi.Node, estimate: f32, lead: f32 }{
        .{ .name = "ghost", .build = Rows.ghost, .estimate = main.ghost_row_extent_for_test, .lead = main.ancestor_top_pad },
        .{ .name = "ghost capped", .build = Rows.ghostCapped, .estimate = main.ghost_row_extent_for_test, .lead = main.ancestor_top_pad },
        .{ .name = "listening footer", .build = Rows.footer, .estimate = main.listening_row_extent_for_test, .lead = 0 },
        .{ .name = "outside line closed", .build = Rows.outsideClosed, .estimate = main.outside_row_extent_for_test, .lead = 0 },
        .{ .name = "outside line open", .build = Rows.outsideOpen, .estimate = main.outside_row_extent_for_test, .lead = 0 },
        .{ .name = "show more", .build = Rows.showMore, .estimate = main.show_more_extent_for_test, .lead = 0 },
    };
    for (cases) |c| {
        const measured = try measuredHeight(arena, &model, c.build);
        const priced = c.estimate + c.lead;
        if (@abs(measured - priced) > 0.5) {
            std.debug.print("\n{s}: draws {d}, priced {d}\n", .{ c.name, measured, priced });
            return error.EstimateDisagreesWithLayout;
        }
    }
}

test "an ancestor row is priced at what it draws, one line and two" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const One = struct {
        var a: main.Ancestor = .{};
        fn row(ui: *main.AppUi) main.AppUi.Node {
            return main.ancestorRowForTest(ui, &a, true);
        }
    };

    const bodies = [_][]const u8{
        "One line.",
        // Comfortably over one line of the reading column, so the clamp fires.
        "Two lines of an ancestor, long enough that it wraps well past the width of the column it is drawn in, and then keeps going so the clamp has something to cut.",
    };
    for (bodies) |body| {
        var note = threadNote(0xA1, 100, 0xAA);
        @memcpy(note.content_buf[0..body.len], body);
        note.content_len = @intCast(body.len);
        // The same field the estimator prices from, filled the way the chain
        // walk fills it, so this measures the real path and not a parallel one.
        One.a = .{ .note = note, .lines = @intFromFloat(main.ancestorBodyLinesForTest(&note)) };

        const measured = try measuredHeight(arena, &model, One.row);
        const priced = main.ancestor_top_pad + main.ancestor_row_chrome_for_test +
            @as(f32, @floatFromInt(One.a.lines)) * main.body_line_height;
        if (@abs(measured - priced) > 0.5) {
            std.debug.print("\nancestor ({d} chars): draws {d}, priced {d}, lines {d}\n", .{ body.len, measured, priced, main.ancestorBodyLinesForTest(&One.a.note) });
            return error.EstimateDisagreesWithLayout;
        }
    }
}

test "a reply block's rail paints too" {
    // The ancestor row's rail has its own test, but the row that ACTUALLY
    // shipped without a rail is this one, and it is a different call site with
    // its own alignment. Guarding only the new code would have left the old bug
    // free to come back.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Build = struct {
        var block: main.ThreadBlock = undefined;
        var parent: main.Note = undefined;
        var of: main.Model = .{};
        fn row(ui: *main.AppUi) main.AppUi.Node {
            return main.replyBlockForTest(ui, &of, &block, [_]u8{0} ** 32, true, true);
        }
    };
    const body = "A reply long enough to wrap past its own disc, so the rail below that disc has somewhere to run.";
    Build.parent = threadNote(0xB1, 200, 0xA1);
    @memcpy(Build.parent.content_buf[0..body.len], body);
    Build.parent.content_len = @intCast(body.len);
    Build.block = .{ .parent = &Build.parent, .children = &.{}, .deeper = &.{} };

    const p = try painted.Painted.renderPiece(arena, &model, Build.row, main.window_width, 600);
    const x = main.thread_inset_for_test + main.avatar_size / 2;
    // Below the disc, inside the block: the rail's own run.
    const y = 12 + main.avatar_size + 8;
    try testing.expect(p.hasFillAt(x, y, theme.palette.border_hairline));
}

test "each thread level keeps its own page and its own held section" {
    // One shared page and one shared flag meant walking into a reply and back
    // collapsed the thread underneath, which is the opposite of why the stack
    // stays mounted at all.
    var model = main.initialModel();
    model.stage = .ready;

    var first = threadNote(0xA1, 100, 0);
    first.id = 11;
    var second = threadNote(0xB1, 200, 0xA1);
    second.id = 22;
    main.enterThreadForTest(&model, first);
    try testing.expectEqual(@as(usize, 0), model.currentLevel());

    // The reader pages through the first level and opens its held tier.
    model.thread_page[0] = 3;
    model.thread_outside_open[0] = true;

    main.enterThreadForTest(&model, second);
    try testing.expectEqual(@as(usize, 1), model.currentLevel());
    // The new level starts fresh, and the one underneath is untouched.
    try testing.expectEqual(@as(usize, 1), model.thread_page[1]);
    try testing.expect(!model.thread_outside_open[1]);
    try testing.expectEqual(@as(usize, 3), model.thread_page[0]);
    try testing.expect(model.thread_outside_open[0]);

    model.thread_page[1] = 2;
    model.thread_outside_open[1] = true;
    main.closeThreadForTest(&model);
    // Back on the first level, exactly as it was left.
    try testing.expectEqual(@as(usize, 0), model.currentLevel());
    try testing.expectEqual(@as(usize, 3), model.thread_page[0]);
    try testing.expect(model.thread_outside_open[0]);
    // And the level just left is reset for its next visit.
    try testing.expectEqual(@as(usize, 1), model.thread_page[1]);
    try testing.expect(!model.thread_outside_open[1]);
}

test "one level's arrival order does not disturb another's" {
    // The table was per-app, so opening a reply wiped the order of the thread
    // underneath and it came back reshuffled.
    var a = main.arrivalTableForTest();
    var b = main.arrivalTableForTest();

    // Level A reads two replies, then a late one arrives.
    var a_first = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0) };
    main.stampArrivalForTest(&a, &a_first, true);
    var a_late = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0), threadNote(0xA3, 50, 0) };
    main.stampArrivalForTest(&a, &a_late, true);
    try testing.expectEqualSlices(u8, &[_]u8{0xA3} ** 32, &a_late[2].event_id);

    // Level B runs its own opening read in between, which must not move A.
    var b_notes = [_]main.Note{ threadNote(0xB1, 10, 0), threadNote(0xB2, 20, 0) };
    main.stampArrivalForTest(&b, &b_notes, false);

    var a_again = [_]main.Note{ threadNote(0xA1, 100, 0), threadNote(0xA2, 200, 0), threadNote(0xA3, 50, 0) };
    main.stampArrivalForTest(&a, &a_again, true);
    // The late reply is still last, not back in its written place.
    try testing.expectEqualSlices(u8, &[_]u8{0xA3} ** 32, &a_again[2].event_id);
}

test "a hovered note row washes, and only when hovered" {
    // The redesign has exactly one hover state: a wash under the whole row
    // (11e, locked decision 2). It shipped nowhere. The token was defined and
    // unused, the pressable rows were layout kinds the renderer paints nothing
    // for, and the ones that were list items set `quiet_hover`, which the SDK
    // reads as "no hover fill". None of that is visible in a widget tree.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    // At rest the row paints the window, not a wash.
    const rest = try painted.Painted.render(arena, &model);
    const frame = rest.frameOf("Open thread") orelse return error.NoRow;
    const x = frame.x + frame.width / 2;
    const y = frame.y + frame.height / 2;
    try testing.expect(!rest.hasFillAt(x, y, theme.palette.surface_hover));

    // Under the pointer it washes.
    const hovered = try painted.Painted.renderHovered(arena, &model, "Open thread");
    try painted.expectFillAt(hovered, x, y, theme.palette.surface_hover);

    // Corner to corner, square: 11e's wash is the row's whole band, and a
    // `list_item` rounds its fill to the control radius unless the row says
    // otherwise. A rounded wash inside a square band shows at the corners.
    try painted.expectFillAt(hovered, frame.x + 1, frame.y + 1, theme.palette.surface_hover);
    try painted.expectFillAt(hovered, frame.x + frame.width - 1, frame.y + frame.height - 1, theme.palette.surface_hover);
}

test "every pressable row in a thread washes under the pointer" {
    // One row washing proves the token is bound; this proves each row that got
    // converted actually reads it, since the conversion is per call site and a
    // row left as a layout kind paints nothing at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    const author = [_]u8{0x55} ** 32;
    model.thread_root.pubkey = author;
    // Two conversations, one with a nested child, so a reply block, a nested
    // reply and a branch line are all on screen.
    model.thread_notes[0] = threadNote(0x10, 200, 0xAA);
    model.thread_notes[0].pubkey = author;
    model.thread_notes[0].id = 10;
    model.thread_notes[1] = threadNote(0x11, 300, 0x10);
    model.thread_notes[1].pubkey = author;
    model.thread_notes[1].id = 11;
    model.thread_notes_len = 2;
    // Seat the second under the first, which is what makes one of them a NESTED
    // reply rather than a second conversation.
    main.arrangeThread(model.thread_notes[0..2], model.thread_root.event_id);
    try testing.expectEqual(@as(u8, 2), model.thread_notes[1].depth);

    // A hovered reply washes ITS OWN row and stops. The reply nested under it is
    // a row of its own with its own wash; one band over both is one highlight
    // over two rows, which is the mirror of the two-highlights-on-one-row the
    // design rules out.
    const row = try painted.Painted.renderHovered(arena, &model, "Open thread");
    const frames = row.framesOf("Open thread");
    if (frames.len < 2) return error.ExpectedNestedReply;
    const parent = frames[0];
    const nested = frames[1];
    const wash = row.fillRectOf(theme.palette.surface_hover) orelse return error.NoHoverWash;
    try testing.expectApproxEqAbs(parent.y, wash.y, 0.5);
    // The snap grid rounds the fill up by a pixel.
    try testing.expectApproxEqAbs(parent.width, wash.width, 1.5);
    // It ends before the reply under it begins.
    try testing.expect(wash.y + wash.height <= nested.y + 0.5);

    // A verb inside it does NOT wash: the redesign washes the row, not the
    // control the pointer happens to be over (locked decision 2, and 11e draws
    // the engagement strip at its resting state under a hovered row).
    const verb = try painted.Painted.renderHovered(arena, &model, "Reply");
    const verb_frame = verb.frameOf("Reply") orelse return error.NoVerb;
    try testing.expect(!verb.hasFillAt(
        verb_frame.x + verb_frame.width / 2,
        verb_frame.y + verb_frame.height / 2,
        theme.palette.surface_hover,
    ));
    // And NEITHER DOES THE ROW, which is a limit rather than a choice: the
    // runtime hovers exactly one widget, the nearest that claims a press, so
    // while the pointer is over a verb the row it belongs to is not hovered at
    // all. 11e washes the row with its actions at full strength. Only
    // `data_cell` hands its hover up to `data_row` today, so there is no way to
    // lift it app-side without giving up the verbs' own presses. Asserted so the
    // gap is a recorded state and not a surprise.
    try testing.expect(verb.fillRectOf(theme.palette.surface_hover) == null);
}

test "a pressed row reads deeper than a hovered one" {
    // Binding the hover colour alone silently repaints the PRESS too: the fill
    // resolves as `active orelse hover orelse background`, so a press with no
    // channel of its own becomes the hover colour, and every row whose only
    // painted state was the press (the rail seat, both Back rows, the fold, the
    // picture tile) loses its feedback. Nothing about that is visible in a
    // widget tree or in a hover test.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    const pressed = try painted.Painted.renderPressed(arena, &model, "Open thread");
    const frame = pressed.frameOf("Open thread") orelse return error.NoRow;
    const x = frame.x + frame.width / 2;
    const y = frame.y + frame.height / 2;
    try painted.expectFillAt(pressed, x, y, theme.palette.surface_chip);
    // And it is a different colour from the hover, or the press says nothing.
    try testing.expect(!pressed.hasFillAt(x, y, theme.palette.surface_hover));
}

test "a row's own frame holds everything it draws" {
    // The kind a pressable row is matters more than it looks. `wrappedVerticalExtentForWidth`
    // (the width-aware measurer) has branches for `row`, `column`, `card` and
    // friends and falls back to the CLASSIC intrinsic for everything else, where
    // a wrapping paragraph measures as a single line. So a row whose body wraps
    // measures one line tall whatever it draws: its content spills into the row
    // below, the hairline cuts through the text, and a press near the bottom of a
    // long note opens the note under it.
    //
    // Nothing else here catches it. The estimator test measures the deepest
    // DESCENDANT, which is right either way; only the row's own frame is wrong.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const body = "A note long enough to wrap onto three full lines of the reading column, which is the shape the measurement has to handle, and it keeps going for a while so there is no doubt about it at all.";
    for (0..2) |i| {
        model.notes[i] = threadNote(0xA1 + @as(u8, @intCast(i)), 100, 0);
        model.notes[i].id = @intCast(7 + i);
        @memcpy(model.notes[i].content_buf[0..body.len], body);
        model.notes[i].content_len = @intCast(body.len);
    }
    model.notes_len = 2;

    const p = try painted.Painted.render(arena, &model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 2) return error.ExpectedTwoRows;
    // Three body lines, so the row is a good deal taller than the one-line
    // measurement the wrong kind would give it.
    try testing.expect(rows[0].height > main.feed_row_chrome + 2 * main.body_line_height);
    // And the row below starts after this one ends, rather than under its tail.
    try testing.expect(rows[1].y >= rows[0].y + rows[0].height - 0.5);
}

test "a note that quotes another is priced with the quote in it" {
    // The bordered card this replaces was never priced at all, so a feed of
    // quoting notes reported less than it drew and the scrollbar lied. The
    // four-line clamp is what makes the height knowable, which is the reason the
    // design gives for clamping.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x5e} ** 32;
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "A quoted note, two lines of it, which is what the aside beside the rule draws before the clamp cuts the rest of it away.");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    // Within a line and a half. Every estimate here counts CHARACTERS against a
    // column width where the engine measures glyphs and breaks at words, so a
    // line either way is the standing slack, and it costs a little scroll jitter
    // on rows not yet built, never an overlap (a built row is positioned by what
    // it measures). What the estimate may not be is short by the whole quote,
    // which is what it was: a bordered card priced at nothing.
    const slack = 1.5 * main.body_line_height;
    if (@abs(rows[0].height - priced) > slack) {
        const qf = p.frameOf("Quoted note") orelse rows[0];
        std.debug.print("\nquoting row draws {d}, priced {d}; quote block {d}\n", .{ rows[0].height, priced, qf.height });
        return error.QuoteNotPriced;
    }
    // And the quote is a real part of that price, not a rounding error.
    const without_quote = main.feed_row_chrome + main.body_line_height;
    try testing.expect(priced > without_quote + 2 * main.body_line_height);

    // The aside fills the column beside the rule. Hugging its content instead,
    // it wrapped the quoted note at about half the width the shot gives it,
    // which reads as a column of its own rather than an aside.
    // The aside's body is labelled so its WIDTH can be asked about: it currently
    // hugs its text (370 of the 526 it is given) rather than filling the column
    // beside the rule, which reads as a column of its own instead of an aside.
    // Left as an open nit rather than a passing assertion that says otherwise.
    try testing.expect(p.frameOf("Quoted note body") != null);
}

test "a quote of a quote is a pill, and the row is priced for it" {
    // Depth stops at one (11g). A second nested body would be a third voice in
    // one row, so the hop becomes a line that says where it goes, and the row
    // has to count it or the list reports less than it draws.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inner_id = [_]u8{0x3c} ** 32;
    const quoted_id = [_]u8{0x5e} ** 32;
    main.seedQuoteForTest(inner_id, [_]u8{0x9b} ** 32, 50, "The note at the end of the hop.");
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "A quoted note that quotes another.");
    // What the fill path learns from the event's own content.
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    e.quote_of = inner_id;
    e.has_quote_of = true;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    // The pill is drawn, and it names whose note it walks to.
    try testing.expect(p.frameOf("Quoted note inside it") != null);
    // The pill names whose note it walks to, which is only true once that note
    // has arrived; here it has.
    const pill = p.frameOf("Quoted note inside it").?;
    try testing.expect(pill.width > 0 and pill.height > 0);
    // No third body: exactly one quote aside in the row.
    try testing.expectEqual(@as(usize, 1), p.framesOf("Quoted note").len);

    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
        std.debug.print("\nrow with a pill draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.PillNotPriced;
    }
}

test "a pill's label is one line, whatever the note it names" {
    // A widget that measures one line still PAINTS the newlines its text
    // carries, so a label folded from a note with line breaks drew its second
    // and third lines over the row beneath it. Caught in a screenshot, not by
    // any assertion, which is why there is one now.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const folded = main.oneLineForTest(&ui, "- one thing\n- another thing\r\n\n- a third");
    try testing.expect(std.mem.indexOfAny(u8, folded, "\r\n") == null);
    try testing.expectEqualStrings("- one thing - another thing - a third", folded);
    // Text with no breaks is handed back untouched, allocating nothing.
    const plain = "nothing to fold";
    try testing.expectEqual(plain.ptr, main.oneLineForTest(&ui, plain).ptr);
}

test "a quote still coming, or gone, is priced at what it draws" {
    // `quote_aside_chrome` is the LOADED aside's chrome: it includes the identity
    // block beside the disc. The skeleton and the unavailable line draw no
    // identity at all, so pricing them the same way over-charged every quoting
    // row by nearly three lines from first paint until the quote landed, which is
    // the opposite of the under-pricing this work set out to fix.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x6f} ** 32;
    for ([_]main.QuoteState{ .fetching, .missing }) |state| {
        main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "Not shown in this state.");
        const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
        e.state = state;

        var model = main.initialModel();
        model.stage = .ready;
        model.notes[0] = threadNote(0xA1, 100, 0);
        model.notes[0].id = 7;
        const body = "Look at this.";
        @memcpy(model.notes[0].content_buf[0..body.len], body);
        model.notes[0].content_len = @intCast(body.len);
        model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
        model.notes_len = 1;

        const p = try painted.Painted.render(arena, &model);
        const rows = p.framesOf("Open thread");
        if (rows.len < 1) return error.NoRow;
        const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
        if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
            std.debug.print("\n{s}: draws {d}, priced {d}\n", .{ @tagName(state), rows[0].height, priced });
            return error.QuietQuoteMispriced;
        }
    }
}

test "the pill asks again when its note falls out of the cache" {
    // The pill's target is asked for once, when the note holding it is filled.
    // The cache holds 64 entries and can evict that target while the pill is
    // still on screen, and nothing would ask again: the note holding it is
    // loaded, and refreshQuotes never revisits a loaded entry.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const evicted = [_]u8{0xd1} ** 32;
    main.dropQuoteForTest(evicted);
    try testing.expect(main.quoteForTest(evicted) == null);

    _ = main.quotingPillLabelForTest(&ui, evicted);
    // Asked for again, so it can come back.
    try testing.expect(main.quoteForTest(evicted) != null);
}

test "with previews off a picture is one chip, and asking for it loads that one" {
    // The setting is not about bandwidth. Reading a feed should not tell every
    // host in it that you did, so nothing leaves the machine until the reader
    // asks for a particular picture.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const url = "https://host.example/a.jpg";
    @memcpy(model.notes[0].image_url_buf[0..url.len], url);
    model.notes[0].image_url_len = @intCast(url.len);
    model.notes[0].image_w = 1600;
    model.notes[0].image_h = 900;
    model.notes[0].image_bytes = 240_000;
    model.notes_len = 1;

    main.setMediaPreviews(false);
    defer main.setMediaPreviews(true);

    const off = try painted.Painted.render(arena, &model);
    try testing.expect(off.frameOf("Load this image") != null);
    // No reserved box: the row is priced for the chip, not for a picture that is
    // not coming.
    try testing.expect(off.frameOf("Attached image, press to enlarge") == null);
    const chip_priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);

    // Asked for: the box comes back, and so does its price.
    main.askForMediaForTest(model.notes[0].id);
    defer main.forgetAskedMediaForTest();
    const on = try painted.Painted.render(arena, &model);
    try testing.expect(on.frameOf("Attached image, press to enlarge") != null);
    const box_priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    try testing.expect(box_priced > chip_priced + 100);
}

test "a page's own words come out of its head" {
    // Open Graph first, then the plain fallbacks, which is the order every other
    // reader uses. The parser is deliberately small: the body arrives capped at
    // 256 KiB, which is where the head lives, and what it cannot make sense of
    // leaves the card without that line rather than guessing.
    const og =
        "<html><head><title>Fallback</title>" ++
        "<meta property=\"og:title\" content=\"The real title\">" ++
        "<meta property=\"og:description\" content=\"What it says about itself.\">" ++
        "</head><body>ignored</body></html>";
    const meta = main.parsePageMeta(og);
    try testing.expectEqualStrings("The real title", meta.heading());
    try testing.expectEqualStrings("What it says about itself.", meta.description);

    // No Open Graph: the title tag and the description meta stand in.
    const plain = "<html><head><title>Just a title</title><meta name='description' content='Plain words.'></head></html>";
    const fallback = main.parsePageMeta(plain);
    try testing.expectEqualStrings("Just a title", fallback.heading());
    try testing.expectEqualStrings("Plain words.", fallback.description);

    // Nothing to say, and nothing invented.
    const bare = main.parsePageMeta("<html><body>no head at all</body></html>");
    try testing.expectEqual(@as(usize, 0), bare.heading().len);
    try testing.expectEqual(@as(usize, 0), bare.description.len);

    // An attribute whose name merely ENDS with one we want is not that one.
    const tricky = "<meta data-og:title=\"nope\" property=\"og:title\" content=\"yes\">";
    try testing.expectEqualStrings("yes", main.parsePageMeta(tricky).heading());

    // An empty Open Graph title is not an answer: the page's own title stands.
    const empty_og = "<html><head><title>Real title</title><meta property='og:title' content=''></head></html>";
    try testing.expectEqualStrings("Real title", main.parsePageMeta(empty_og).heading());
}

test "the domain a card shows is the host, without its www" {
    try testing.expectEqualStrings("example.com", main.urlDomain("https://www.example.com/a/b?c=d"));
    try testing.expectEqualStrings("news.ycombinator.com", main.urlDomain("https://news.ycombinator.com/item?id=1"));
    try testing.expectEqualStrings("example.com", main.urlDomain("http://example.com"));
}

test "the link a card previews is the first plain one" {
    // The picture's own URL is not a link to preview, and neither is any other
    // image: those are drawn, not summarised.
    const image = "https://host.example/a.jpg";
    const content = "look " ++ image ++ " and read https://example.com/post, then " ++ "https://other.example/b.png";
    const link = main.firstLinkUrl(content, image) orelse return error.NoLink;
    // The trailing comma is punctuation, not part of the address.
    try testing.expectEqualStrings("https://example.com/post", link);

    // A note with nothing but its picture has no link to preview.
    try testing.expect(main.firstLinkUrl("here " ++ image, image) == null);
}

test "a blurhash decodes to the picture's own colours" {
    // The reference hash from the format's own README, which encodes a warm
    // photograph. Decoding is what lets a picture that has not arrived show its
    // palette instead of a grey box.
    const blur = main.decodeBlurhash("LEHV6nWB2yk8pyo0adR*.7kCMdnj");
    try testing.expect(blur.ok);
    // Every cell is opaque and inside the gamut.
    for (blur.cells) |c| {
        try testing.expect(c.a > 0.99);
        try testing.expect(c.r >= 0 and c.r <= 1);
    }
    // The corners differ: a hash that decoded to one flat colour would be a
    // decoder that dropped its AC components.
    const first = blur.cells[0];
    const last = blur.cells[blur.cells.len - 1];
    try testing.expect(@abs(first.r - last.r) + @abs(first.g - last.g) + @abs(first.b - last.b) > 0.02);

    // Rubbish in, nothing out: a malformed hash draws stripes, never a guess.
    try testing.expect(!main.decodeBlurhash("").ok);
    try testing.expect(!main.decodeBlurhash("not a hash").ok);
    try testing.expect(!main.decodeBlurhash("LEHV6nWB2yk8pyo0adR*.7kCMdn").ok);
}

test "a picture with a blurhash shows its colours before its bytes" {
    // The placeholder is flat cells, not an image: all sixteen image slots are
    // spent on faces and photographs, and a placeholder must never evict the
    // thing it stands in for.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const url = "https://host.example/a.jpg";
    @memcpy(model.notes[0].image_url_buf[0..url.len], url);
    model.notes[0].image_url_len = @intCast(url.len);
    model.notes[0].image_aspect = 0.5;
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    @memcpy(model.notes[0].image_blur_buf[0..hash.len], hash);
    model.notes[0].image_blur_len = @intCast(hash.len);
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    const box = p.frameOf("Attached image, press to enlarge") orelse return error.NoBox;
    // The box paints a colour from the hash, not the striped fallback.
    const blur = main.decodeBlurhash(hash);
    const sample = p.fillAt(box.x + box.width / 2, box.y + box.height / 2) orelse return error.NothingPainted;
    var matched = false;
    for (blur.cells) |c| {
        if (@abs(c.r - sample.r) < 0.01 and @abs(c.g - sample.g) < 0.01 and @abs(c.b - sample.b) < 0.01) matched = true;
    }
    if (!matched) {
        std.debug.print("\npainted {any}, not a blurhash cell\n", .{sample});
        return error.NotTheBlurhash;
    }
}

test "a link is only previewed when it is safe to ask" {
    // This is the one place the app reaches out to an address a STRANGER chose,
    // unattended, because a note scrolled into view. Every rejection here is a
    // thing a note must not be able to make every reader's machine do.
    try testing.expect(main.previewableUrl("https://example.com/post"));
    try testing.expect(main.previewableUrl("https://news.ycombinator.com/item?id=1"));

    // Plaintext puts the reader's IP and the exact URL on the wire.
    try testing.expect(!main.previewableUrl("http://example.com/"));
    // Userinfo becomes an authorization header on a host of the author's choice.
    try testing.expect(!main.previewableUrl("https://admin:admin@example.com/"));
    try testing.expect(!main.previewableUrl("https://wirth.ch@evil.tld/x"));
    // The reader's own machine and their own network.
    try testing.expect(!main.previewableUrl("https://127.0.0.1/x"));
    try testing.expect(!main.previewableUrl("https://10.1.2.3/x"));
    try testing.expect(!main.previewableUrl("https://192.168.1.1/admin"));
    try testing.expect(!main.previewableUrl("https://172.16.0.1/"));
    try testing.expect(!main.previewableUrl("https://169.254.169.254/latest/meta-data/"));
    try testing.expect(!main.previewableUrl("https://100.64.0.1/"));
    try testing.expect(!main.previewableUrl("https://[::1]/"));
    // A service, not a site.
    try testing.expect(!main.previewableUrl("https://example.com:8787/approve"));
    // Names that are not public sites.
    try testing.expect(!main.previewableUrl("https://localhost/"));
    try testing.expect(!main.previewableUrl("https://printer.local/"));
    try testing.expect(!main.previewableUrl("https://vault.internal/"));
    // A public address that merely starts with a private-looking octet is fine.
    try testing.expect(main.previewableUrl("https://172.32.0.1/"));
}

test "the domain on a card is the host, not what precedes an at sign" {
    // The oldest phishing shape there is. A card showing `wirth.ch@evil.tld`
    // would be lending its credibility to whoever wrote the note.
    try testing.expectEqualStrings("evil.tld", main.urlDomain("https://wirth.ch@evil.tld/x"));
    try testing.expectEqualStrings("evil.tld", main.urlDomain("https://a@b@evil.tld/x"));
    // The port is not part of the name a reader recognises.
    try testing.expectEqualStrings("example.com", main.urlDomain("https://example.com:8443/x"));
    try testing.expectEqualStrings("example.com", main.urlDomain("https://www.example.com/a"));
}

test "a link card is priced at what it draws, with a description and without" {
    // The card's height comes from its text column, not from its 30px tile:
    // every line takes a full body line box whatever register it is set in. The
    // constant is measured for the same reason the others are.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = "https://example.com/post";
    for ([_][]const u8{ "What it says about itself.", "" }) |desc| {
        main.seedLinkForTest(url, "The page's title", desc);

        var model = main.initialModel();
        model.stage = .ready;
        model.notes[0] = threadNote(0xA1, 100, 0);
        model.notes[0].id = 7;
        const body = "Read this.";
        @memcpy(model.notes[0].content_buf[0..body.len], body);
        model.notes[0].content_len = @intCast(body.len);
        @memcpy(model.notes[0].link_url_buf[0..url.len], url);
        model.notes[0].link_url_len = @intCast(url.len);
        model.notes_len = 1;

        const p = try painted.Painted.render(arena, &model);
        const card = p.frameOf("Open link") orelse return error.NoCard;
        const priced = if (desc.len > 0) main.link_card_height_for_test else main.link_card_height_bare_for_test;
        if (@abs(card.height - priced) > 0.5) {
            std.debug.print("\ncard with desc={d} draws {d}, priced {d}\n", .{ desc.len, card.height, priced });
            return error.CardMispriced;
        }
    }
}

test "the pressable box is the picture, not the space around it" {
    // A portrait taller than the aspect cap is drawn contained at the reserved
    // height. If the box stayed column-wide, the bare window either side of it
    // would be inside the border and pressable, and pressing it would open the
    // viewer for a picture the reader was not pointing at.
    var note = threadNote(0xA1, 100, 0);
    const url = "https://host.example/tall.jpg";
    @memcpy(note.image_url_buf[0..url.len], url);
    note.image_url_len = @intCast(url.len);
    note.image_aspect = 2.0;

    const height = main.pictureHeight(&note);
    const width = main.pictureWidth(&note);
    // Reserved at the cap, drawn at its own shape.
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * 1.25, height, 0.5);
    try testing.expectApproxEqAbs(height / 2.0, width, 0.5);

    // A landscape picture fills the column.
    note.image_aspect = 0.5625;
    try testing.expectApproxEqAbs(main.picture_column_width_for_test, main.pictureWidth(&note), 0.5);
}

test "a note that no relay took is still owed" {
    // The whole point of the queue: a note written on a train and lost on
    // landing is the worst thing a client can do.
    main.resetOutboxForTest();
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

test "the outbox zone appears only when something is owed" {
    // The zone is absent most of the time on purpose: one that is always there
    // teaches nothing, and an empty popover under it would be worse.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    model.notes_len = 1;

    const quiet = try painted.Painted.render(arena, &model);
    try testing.expect(quiet.frameOf("Notes on their way") == null);

    model.outbox_pending = 2;
    const owed = try painted.Painted.render(arena, &model);
    const zone = owed.frameOf("Notes on their way") orelse return error.NoZone;
    try testing.expect(zone.width > 0);
    // It says how many, in the shot's own words.
    try testing.expectEqualStrings("posting 2 notes…", model.outbox_label(arena));
    model.outbox_pending = 1;
    try testing.expectEqualStrings("posting 1 note…", model.outbox_label(arena));
}

test "the offline banner says what still works" {
    // 11p's banner. A spinner would say the opposite of the truth: the store is
    // the app, so reading continues, and a note written now is kept.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes_len = 0;

    // No relay is up in a test, so the banner is the state under test.
    const p = try painted.Painted.render(arena, &model);
    const banner = p.fillRectOf(theme.palette.surface_offline) orelse return error.NoBanner;
    try testing.expect(banner.width > 100);
    // And it names what is waiting, when something is.
    model.outbox_pending = 3;
    const text = main.offlineBannerTextForTest(arena, model.outbox_pending);
    try testing.expect(std.mem.indexOf(u8, text, "3 notes are") != null);
}

test "a note that gave up is not called posting" {
    // The zone's words follow the state, because "posting" over a note that will
    // never go is the same lie the queue was built to stop telling.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.outbox_pending = 0;
    model.outbox_stuck = 1;
    try testing.expectEqualStrings("1 note did not go out", model.outbox_label(arena));
    model.outbox_stuck = 3;
    try testing.expectEqualStrings("3 notes did not go out", model.outbox_label(arena));

    // Still trying wins the label: what is moving matters more than what stalled.
    model.outbox_pending = 2;
    try testing.expectEqualStrings("posting 2 notes…", model.outbox_label(arena));
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

test "the picker knows when a mention is being typed" {
    // The last `@word` is the one being written; an `@name` earlier in the note
    // is already said, and an `@` inside a word is an address, not a mention.
    try testing.expectEqualStrings("wir", main.mentionQuery("hello @wir").?);
    try testing.expectEqualStrings("", main.mentionQuery("hello @").?);
    // Finished: a space means the reader has moved on.
    try testing.expect(main.mentionQuery("hello @wirth and then") == null);
    // Mid-word, so not a mention being composed.
    try testing.expect(main.mentionQuery("mail me at me@example.com") == null);
    try testing.expect(main.mentionQuery("nothing here") == null);
    // The LAST run wins, not the first.
    try testing.expectEqualStrings("ed", main.mentionQuery("@wirth said @ed").?);
}

test "an empty composer cannot be posted, by button or by key" {
    // The button is disabled when the draft is empty, so before Cmd+Enter the
    // message could never arrive with nothing to send. A key can, and closing
    // the sheet with a "Posted" toast over an empty composer would be the
    // plainest lie in the app.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    try testing.expect(model.draft_empty());

    var fx: main.EffectsForTest = undefined;
    main.update(&model, .post, &fx);
    // Still open, and nothing claimed.
    try testing.expect(model.composing);
    try testing.expectEqual(@as(usize, 0), main.outboxPending());

    // Whitespace is empty too: a note of three spaces is not a note.
    model.draft_buffer = @TypeOf(model.draft_buffer).init("   \n ");
    try testing.expect(model.draft_empty());
    main.update(&model, .post, &fx);
    try testing.expect(model.composing);
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

test "an insert that will not fit is refused, not truncated" {
    // The draft buffer truncates in silence, and half a bech32 reference is one
    // no client can resolve, published without a word of warning.
    var model = main.initialModel();
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    long[499] = '@';
    model.draft_buffer = @TypeOf(model.draft_buffer).init(&long);
    const before = model.draft();

    main.insertMentionForTest(&model, [_]u8{0x7a} ** 32);
    // Unchanged: it did not fit, so it did not happen.
    try testing.expectEqualStrings(before, model.draft());

    // With room, it lands whole and ends in a resolvable reference.
    model.draft_buffer = @TypeOf(model.draft_buffer).init("thanks @gi");
    main.insertMentionForTest(&model, [_]u8{0x7a} ** 32);
    try testing.expect(std.mem.indexOf(u8, model.draft(), "nostr:npub1") != null);
    try testing.expect(model.draft().len > 60);
}

test "a relay badge walks the three things a relay can be for" {
    // NIP-65's whole vocabulary is read and write. The badge walks both, then
    // read, then write, and back: a relay that is neither is a relay you have
    // removed, and there is a button for that.
    main.resetRelaysForTest();
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = false }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = false, .write = true }), main.relayReadWriteForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
}

test "a removed relay leaves its seat, and the next add takes it back" {
    // A slot index is a promise: the outbox's ack bits and the per-note relay
    // marks both name one. Removing must therefore empty a seat, never shift
    // the seats after it.
    main.resetRelaysForTest();
    const before = main.relaySlots();
    main.removeRelayForTest(1);
    try testing.expect(main.relayAt(1) == null);
    // The relay in slot 2 did not slide down into the hole.
    try testing.expect(main.relayAt(2) != null);
    try testing.expectEqual(before, main.relaySlots());

    // And the empty seat is reused, so remove-then-add does not consume the pool.
    try testing.expectEqual(@as(?usize, 1), main.addRelayForTest("wss://relay.example.com", true, true));
    try testing.expectEqual(before, main.relaySlots());
}

test "the pool refuses what is not a relay, and refuses to overflow" {
    main.resetRelaysForTest();
    try testing.expect(!main.isRelayUrl("https://relay.example.com"));
    try testing.expect(!main.isRelayUrl("wss://localhost"));
    try testing.expect(!main.isRelayUrl("wss://user:pass@relay.example.com"));
    // A follow's published list really does carry plain `ws://` relays, and
    // taking one would put every filter this reader sends on the wire in clear.
    try testing.expect(!main.isRelayUrl("ws://relay.example.com"));
    try testing.expect(main.isRelayUrl("wss://relay.example.com"));

    // The pool fills to its cap and then refuses, rather than silently
    // dropping, because the card says so. Counted from the bootstrap list's own
    // size and the cap, so changing either is one edit here and not a hunt for
    // whichever letter of the alphabet happened to be the last accepted one.
    const room = main.max_relays_for_test - main.bootstrap_relay_count_for_test;
    const names = [_][]const u8{
        "wss://a.example.com", "wss://b.example.com", "wss://c.example.com",
        "wss://d.example.com", "wss://e.example.com", "wss://f.example.com",
    };
    try testing.expect(names.len > room);
    for (names[0..room]) |url| try testing.expect(main.addRelayForTest(url, true, true) != null);
    try testing.expectEqual(main.max_relays_for_test, main.relayCount());
    try testing.expect(main.addRelayForTest(names[room], true, true) == null);
    // Adding one already in the pool returns its seat rather than taking a new one.
    try testing.expectEqual(@as(?usize, 0), main.addRelayForTest("wss://relay.damus.io", true, true));
}

test "their published relay list becomes the pool, once, and never over an edit" {
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com" },
        &.{ "r", "wss://two.example.com", "read" },
        &.{ "r", "wss://three.example.com", "write" },
        // Junk in a tag is not a relay: it is skipped, not dialed.
        &.{ "r", "http://four.example.com" },
        &.{"p"},
    };
    var ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };

    // Ownership is meaningless without an account: it is the whole point of the
    // record that it says WHOSE list this is.
    main.setIdentityForTest([_]u8{5} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://one.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = false }), main.relayReadWriteForTest(1));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = false, .write = true }), main.relayReadWriteForTest(2));
    try testing.expectEqual(@as(usize, 3), main.relayCount());
    try testing.expect(main.relayIsMineForTest());

    // A second list does not get to arrive: the pool is theirs now, and a later
    // event must not undo what they set here.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());

    // An edit made while an event was in flight wins over the event.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(!main.adoptRelayListForTest());

    // A list with nothing usable in it is not a list: keeping five relays beats
    // being left with none.
    const empty_tags = [_]nostr.event.Tag{&.{ "r", "http://nope.example.com" }};
    ev.tags = &empty_tags;
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.relayCount());
}

test "a newer relay list from another client is adopted, not refused" {
    // Ownership alone used to decide this, so the FIRST kind:10002 this app ever
    // adopted froze the pool for good: `saveRelays` recorded the owner and
    // nothing else, so every launch read the pool back as theirs and dropped
    // their real list before its stamp was ever looked at. Add a relay in Damus,
    // and the next badge press here republished Plaza's frozen copy at a stamp
    // built to win. Their own newer list lost to their own older one, silently.
    main.setIdentityForTest([_]u8{0x21} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();

    const first = [_]nostr.event.Tag{&.{ "r", "wss://first.example.com" }};
    var ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x21} ** 32,
        .created_at = 1_000,
        .kind = 10002,
        .tags = &first,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://first.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(i64, 1_000), main.relayListStampForTest());

    // The same list again, and an OLDER one: both refused, which is the property
    // the ownership check was there for.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    ev.created_at = 900;
    main.stageOwnRelayListForTest(ev);
    try testing.expect(!main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://first.example.com", main.relayUrlAt(0));

    // THE PROPERTY: a list they signed later, somewhere else, wins.
    const second = [_]nostr.event.Tag{&.{ "r", "wss://added-in-another-client.example.com" }};
    ev.tags = &second;
    ev.created_at = 2_000;
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://added-in-another-client.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(i64, 2_000), main.relayListStampForTest());
}

test "how new the saved pool is survives a restart" {
    // The refusal above is only worth anything if it holds across launches: the
    // file recorded WHOSE list it was and never WHEN, so every launch started
    // with a stamp of zero and the pool was frozen by whichever event landed
    // first. This drives the file's text rather than the disk, because the io is
    // not reachable from a test and the format is the part that can rot.
    main.setIdentityForTest([_]u8{0x22} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://saved.example.com", "read" }};
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x22} ** 32,
        .created_at = 1_700_000_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());

    var buf: [2048]u8 = undefined;
    const text = main.formatRelaysFileForTest(&buf).?;
    try testing.expect(std.mem.indexOf(u8, text, "stamp 1700000000") != null);

    // The relaunch: an empty pool, then the file read back.
    const saved = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(saved);
    main.clearRelaysForTest();
    try testing.expectEqual(@as(i64, 0), main.relayListStampForTest());
    main.applyRelaysFileForTest(saved);
    try testing.expectEqual(@as(i64, 1_700_000_000), main.relayListStampForTest());
    try testing.expectEqualStrings("wss://saved.example.com", main.relayUrlAt(0));

    // And the pool it read back refuses what it should and takes what it should.
    var older = ev;
    older.created_at = 1_600_000_000;
    main.stageOwnRelayListForTest(older);
    try testing.expect(!main.adoptRelayListForTest());
    var newer = ev;
    newer.created_at = 1_800_000_000;
    const newer_tags = [_]nostr.event.Tag{&.{ "r", "wss://changed-elsewhere.example.com" }};
    newer.tags = &newer_tags;
    main.stageOwnRelayListForTest(newer);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://changed-elsewhere.example.com", main.relayUrlAt(0));
}

test "building the feed does not read the contact list once per card" {
    // `followBlockedReason` is called from `noteContextItems`, which every note
    // card builds for its right-click menu. It asked `haveOwnContactList`, which
    // ran an LMDB query and then duplicated the whole record: every tag, every
    // field, each its own page_allocator call, which is its own mmap, and an
    // munmap apiece to free.
    //
    // With three hundred follows that is roughly six hundred syscalls per card
    // per frame. A stack sample of a scroll put 1437 of 1462 app-side samples
    // inside `noteContextItems`; the frame rebuild measured 22.7 ms against an
    // 8.3 ms frame, so the feed ran at about nine frames a second, and it got
    // WORSE the more people you followed.
    //
    // Counting the reads rather than timing the build, because the property is
    // the shape ("not once per card"), and a stopwatch on a CI runner is a poor
    // way to say that.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x9c} ** 32);
    main.setIdentityForTest([_]u8{0x9c} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnListMemoForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cards.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // A real-sized contact list: three hundred people, which is an ordinary
    // number and the one the slowdown was reported at.
    var tag_storage: [300][2][]const u8 = undefined;
    var tags: [300]nostr.event.Tag = undefined;
    var hexes: [300][64]u8 = undefined;
    for (0..300) |i| {
        var pk: [32]u8 = undefined;
        @memset(&pk, @intCast(i % 251 + 1));
        _ = std.fmt.bufPrint(&hexes[i], "{x}", .{pk}) catch unreachable;
        tag_storage[i] = .{ "p", &hexes[i] };
        tags[i] = &tag_storage[i];
    }
    const list = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, list, signer);

    // A feed longer than the viewport, so the window builds a real number of
    // cards. Written by SOMEBODY ELSE, which is what a feed is: the follow line
    // in a card's menu short-circuits to "This is you" on your own notes, so a
    // feed of your own would never reach the question this test is about. It
    // did, at first, and the reverted-fix check is what caught it.
    var other = nostr.keys.Signer.init();
    defer other.deinit();
    const other_kp = try other.keyPairFromSecretKey([_]u8{0x9d} ** 32);
    const ev = try signedNote(arena, other, other_kp, 1_800_000_000, "a note in a long feed");
    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    for (0..200) |i| {
        model.notes[i] = main.noteFrom(ev, 1_800_000_000);
        model.notes[i].id = @intCast(i + 1);
    }
    model.notes_len = 200;

    // Warm whatever the first build legitimately reads once, then count.
    _ = try buildTree(arena, &model);
    main.resetOwnRecordReadsForTest();
    const tree = try buildTree(arena, &model);
    const cards = countNoteRows(tree.root);
    try testing.expect(cards > 4);

    // THE PROPERTY. Not "few reads": NONE. Building a view is not a question the
    // store should be asked, and once it is asked once per card the number rises
    // with the viewport and with the size of the list being copied.
    const reads = main.ownRecordReadsForTest();
    if (reads != 0) {
        std.debug.print("\nfeed build read the whole contact list {d} times for {d} cards\n", .{ reads, cards });
    }
    try testing.expectEqual(@as(usize, 0), reads);
}

test "the rows just off screen are warmed, and the ones on it are left alone" {
    // Fetching was gated on holding one of the nine avatar ids or six picture
    // ids, and those are lent only to rows already on screen. So every row
    // arrived cold: blank, then a request, then a face a moment later, again and
    // again for as long as the reader kept scrolling.
    //
    // Nothing about downloading an image needs a registry slot. Only showing it
    // does. This pins the band that gets fetched anyway.
    var model = main.initialModel();
    // Filled by hand rather than through the store, so the room is reserved
    // here; the app grows on its way through the rebuild.
    main.reserveFeedForTest(&model, 512);
    model.stage = .ready;
    model.notes_len = 200;
    for (0..200) |i| model.notes[i].id = @intCast(i + 1);

    main.setVisibleRangeForTest(80, 90);
    const seen = model.visibleRange();
    const warm = model.prefetchRange();
    try testing.expectEqual(@as(usize, 80), seen.first);
    try testing.expectEqual(@as(usize, 90), seen.last);
    // A band either side, because scrolling back up is as common as scrolling
    // down and a cache that only looks forward makes the way back feel broken.
    try testing.expect(warm.first < seen.first);
    try testing.expect(warm.last > seen.last);
    try testing.expectEqual(seen.first - main.feed_prefetch_rows_for_test, warm.first);
    try testing.expectEqual(seen.last + main.feed_prefetch_rows_for_test, warm.last);

    // At the top of the feed it does not run off the front, and at the bottom it
    // stops at the last row rather than warming notes that do not exist.
    main.setVisibleRangeForTest(0, 5);
    const top = model.prefetchRange();
    try testing.expectEqual(@as(usize, 0), top.first);
    main.setVisibleRangeForTest(195, 199);
    const bottom = model.prefetchRange();
    try testing.expectEqual(@as(usize, 199), bottom.last);
}

test "a warmed picture is asked for at the address the row will look up" {
    // The disk cache is keyed by the URL, and two callers want one: the row that
    // holds a slot, and the warm pass that does not. Ask for a different size, or
    // forget the GIF branch, and the warmed bytes land under a name nothing looks
    // up, so the download happens twice and the row still waits.
    //
    // They share one builder, so there are not two spellings to drift. What is
    // worth pinning is that the builder still tells a GIF from a still: the sizes
    // differ, so getting that wrong would reintroduce the same miss.
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const gif = main.feedImageUrlForTest(&a, "https://example.com/a.gif");
    const still = main.feedImageUrlForTest(&b, "https://example.com/a.jpg");
    try testing.expect(gif.len > 0 and still.len > 0);
    try testing.expect(!std.mem.eql(u8, gif, still));
    // And a query string does not hide the extension from it.
    var c: [1024]u8 = undefined;
    const gif_q = main.feedImageUrlForTest(&c, "https://example.com/a.gif?w=1");
    try testing.expect(std.mem.indexOf(u8, gif_q, "a.gif") != null);
}

test "a follow's relay list is a suggestion, and only where they write" {
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://writes.example.com", "write" },
        &.{ "r", "wss://both.example.com" },
        // Where they only READ will never hold their notes, so it buys nothing.
        &.{ "r", "wss://reads.example.com", "read" },
        // Already in the pool: not worth offering.
        &.{ "r", "wss://relay.damus.io" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.resetRelaysForTest();
    main.ingestRelayListForTest(ev);
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://writes.example.com", main.relaySuggestionCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://both.example.com", main.relaySuggestionCopy(1, &buf).?);

    // The same list again adds nothing: a suggestion is a fact, not a tally.
    main.ingestRelayListForTest(ev);
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
}

test "one relay under two spellings is one relay" {
    // A relay is an address, not text: the scheme's case and a trailing slash
    // carry nothing, and a list holding both spellings would dial twice.
    try testing.expect(main.relayUrlEql("wss://relay.example.com", "wss://relay.example.com/"));
    try testing.expect(main.relayUrlEql("WSS://Relay.example.com", "wss://relay.example.com"));
    try testing.expect(!main.relayUrlEql("wss://relay.example.com", "wss://relay.example.org"));
    try testing.expectEqualStrings("relay.example.com", main.relayShortName("wss://relay.example.com/"));
}

test "the ack denominator counts only relays a note is actually sent to" {
    // An outbox entry is owed to the relays that take writes. A relay the reader
    // set to read-only was never asked to hold the note, so counting it would
    // leave every note permanently short of its acks.
    main.resetRelaysForTest();
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.writeRelayCount());
    main.cycleRelayForTest(0); // R·W -> R
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.writeRelayCount());
    main.cycleRelayForTest(0); // R -> W
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.writeRelayCount());
    main.removeRelayForTest(0);
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.writeRelayCount());
    try testing.expectEqual(main.bootstrap_relay_count_for_test - 1, main.relayCount());
}

test "a burst of relay edits publishes one list, not one per press" {
    // Walking a badge from R·W back to R·W is three presses for one decision.
    // Three replaceable events would be noise the reader's relays did not ask
    // for, so the edit settles and the last state is what goes out.
    main.resetRelaysForTest();
    main.clearRelayListPublishForTest();
    main.setIdentityForTest([_]u8{64} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);
    _ = main.addRelayForTest("wss://burst.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(!main.relayListDueForTest(1_000));

    main.relayListEditedForTest(1_000);
    // Still being pressed: nothing goes out yet.
    try testing.expect(!main.relayListDueForTest(1_000));
    main.relayListEditedForTest(1_001);
    try testing.expect(!main.relayListDueForTest(1_002));
    // Two seconds after the LAST press it is due, and it STAYS due: asking is
    // not what settles it. This used to be consumed by the question, which is
    // how an edit the publish then refused was lost for good.
    try testing.expect(main.relayListDueForTest(1_003));
    try testing.expect(main.relayListDueForTest(1_010));

    // The publish is what settles it, once, for the whole burst.
    var fx: main.EffectsForTest = undefined;
    main.flushRelayListForTest(&fx, 1_011);
    try testing.expect(!main.relayListPendingForTest());
    try testing.expect(!main.relayListDueForTest(1_020));

    // The file, though, is written on every edit: a crash must not lose one.
    main.relayListEditedForTest(2_000);
    try testing.expect(main.relayIsMineForTest());
}

test "a dormant seat in the middle does not leave the popover a hole" {
    // The popover used to index rows by SLOT, so a removed relay left a row
    // nobody wrote, and the arena hands out uninitialised memory that the
    // widget walker then follows. Removing a middle relay and opening the
    // popover is the exact press that reached it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetRelaysForTest();
    main.removeRelayForTest(1);
    main.cycleRelayForTest(2); // R·W -> R, the other way a row used to be skipped

    var model = main.initialModel();
    model.stage = .ready;
    model.menu = .relays;
    const tree = try buildTree(arena, &model);
    // The four survivors are named; the removed one is not.
    try testing.expect(findAnyText(tree.root, "relay.damus.io") != null);
    try testing.expect(findAnyText(tree.root, "nos.lol") == null);
    // And a read-only relay is listed rather than hidden: the chip counts it, so
    // a list that dropped it would disagree with the number beside it.
    try testing.expect(findAnyText(tree.root, "relay.primal.net") != null);
}

test "a relay's badge says what it is for, everywhere it is shown" {
    main.resetRelaysForTest();
    try testing.expectEqualStrings("R·W", main.relayBadgeTextForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqualStrings("R", main.relayBadgeTextForTest(0));
    main.cycleRelayForTest(0);
    try testing.expectEqualStrings("W", main.relayBadgeTextForTest(0));
}

test "a removed relay is not still connected" {
    // The status is recorded per SLOT and the slot outlives its relay, so a
    // removal that left the status alone kept counting a relay that is gone.
    main.resetRelaysForTest();
    main.setRelayStatusForTest(0, true);
    main.setRelayStatusForTest(1, true);
    try testing.expectEqual(@as(usize, 2), main.liveRelayCountForTest());
    main.removeRelayForTest(1);
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());
    try testing.expectEqual(@as(?u16, null), main.relayRttMs(1));
}

test "the newest relay list wins, whatever order the relays answer in" {
    // kind:10002 is replaceable. Relays answer in whatever order they like, so
    // adopting the first arrival would let a slow relay holding last year's list
    // decide where this reader talks.
    const old_tags = [_]nostr.event.Tag{&.{ "r", "wss://old.example.com" }};
    const new_tags = [_]nostr.event.Tag{&.{ "r", "wss://new.example.com" }};
    const old_ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 1_000,
        .kind = 10002,
        .tags = &old_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    var new_ev = old_ev;
    new_ev.created_at = 2_000;
    new_ev.tags = &new_tags;

    // Old first, then new: the new one replaces it before either is installed.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(old_ev);
    main.stageOwnRelayListForTest(new_ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://new.example.com", main.relayUrlAt(0));

    // New first, then old: the old one is ignored.
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(new_ev);
    main.stageOwnRelayListForTest(old_ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://new.example.com", main.relayUrlAt(0));
}

test "an unknown NIP-65 marker narrows nothing" {
    // NIP-65 knows "read" and "write". Reading any other word as "neither" would
    // produce a relay this app still dials and still counts while claiming it is
    // for nothing.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com", "readwrite" },
        &.{ "r", "wss://two.example.com", "" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{7} ** 32,
        .created_at = 5,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.resetRelaysForTest();
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(0));
    try testing.expectEqual(@as(?main.RelayUse, .{ .read = true, .write = true }), main.relayReadWriteForTest(1));
    try testing.expectEqualStrings("R·W", main.relayBadgeTextForTest(0));
}

test "one relay under two spellings takes one seat" {
    main.resetRelaysForTest();
    const first = main.addRelayForTest("wss://relay.example.com", true, true).?;
    // A trailing slash and the scheme's case are noise, and addRelay must dedupe
    // the way the rest of the pool does, or the reader gets two rows for one
    // relay and the app dials it twice.
    try testing.expectEqual(@as(?usize, first), main.addRelayForTest("wss://relay.example.com/", true, true));
    try testing.expectEqual(@as(?usize, first), main.addRelayForTest("WSS://Relay.example.com", true, true));
    try testing.expectEqual(main.bootstrap_relay_count_for_test + 1, main.relayCount());
}

test "an edit gives a note that gave up its rounds back" {
    // A note is stuck because it ran out of rounds with NO verdict from anyone:
    // acked and refused are both zero. Skipping those was skipping exactly the
    // notes that adding a relay is meant to rescue.
    main.resetOutboxForTest();
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

test "a relay list is not a note, so it never sits in the note queue" {
    // The queue's banner says "1 note did not go out". A kind:10002 in there
    // would make that sentence false, and the next edit republishes it anyway.
    try testing.expect(main.isReaderNoteForTest(1));
    try testing.expect(!main.isReaderNoteForTest(10002));
    try testing.expect(!main.isReaderNoteForTest(0));
}

test "the pool chip never reads more live relays than it has" {
    // Both halves come from one sample. A tick-old numerator against a live
    // denominator printed "5/3 relays" for a second after a removal.
    try testing.expect(!main.poolIsHealthyOfForTest(0, 5));
    try testing.expect(main.poolIsHealthyOfForTest(4, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(3, 5));
    try testing.expect(!main.poolIsHealthyOfForTest(1, 0));
}

test "signing out leaves the account's relay list with the account" {
    // The list came from their kind:10002 and names where they read and write.
    // Carrying it into the next account would route a stranger's notes through
    // the previous reader's relays.
    main.resetRelaysForTest();
    _ = main.addRelayForTest("wss://theirs.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayIsMineForTest());

    main.resetRelaysToBootstrapForTest();
    try testing.expect(!main.relayIsMineForTest());
    try testing.expectEqual(main.bootstrap_relay_count_for_test, main.relayCount());
    try testing.expectEqualStrings("wss://relay.damus.io", main.relayUrlAt(0));
    try testing.expectEqual(@as(usize, 0), main.relaySuggestionCount());
}

test "editing a profile keeps every field this app does not model" {
    // kind:0 is REPLACEABLE: what is published replaces the whole profile. Real
    // profiles carry a lightning address, a banner, a website and whatever else
    // their owner's other clients wrote. This app models three fields, so it
    // edits three keys and leaves the rest exactly where they were. Getting this
    // wrong silently stops somebody being paid.
    const existing =
        \\{"name":"alice","display_name":"Alice","about":"old bio","picture":"https://old.example.com/a.png",
        \\"lud16":"alice@getalby.com","banner":"https://ex.com/b.png","website":"https://alice.example",
        \\"nip05":"alice@example.com","pronouns":"she/her"}
    ;
    var model = main.initialModel();
    model.profile_name_buffer.set("Alice Liddell");
    model.profile_about_buffer.set("new bio");
    model.profile_picture_buffer.set("https://new.example.com/a.png");

    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);

    // What the reader edited.
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\":\"Alice Liddell\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"about\":\"new bio\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"picture\":\"https://new.example.com/a.png\"") != null);
    // What they did not, and what this app cannot even see.
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"alice@getalby.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"banner\":\"https://ex.com/b.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"website\":\"https://alice.example\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"nip05\":\"alice@example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"pronouns\":\"she/her\"") != null);
    // The handle is not the display name, and an account that already has one
    // keeps it: renaming yourself must not rename your @handle out from under
    // everyone who mentions you.
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\":\"alice\"") != null);
}

test "an emptied profile field removes its key rather than blanking it" {
    // `"about": ""` reads to other clients as a bio deliberately blanked, which
    // is a different statement from not having one.
    const existing = "{\"name\":\"alice\",\"about\":\"old bio\",\"lud16\":\"alice@getalby.com\"}";
    var model = main.initialModel();
    model.profile_name_buffer.set("Alice");
    model.profile_about_buffer.set("   ");
    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "about") == null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"alice@getalby.com\"") != null);
}

test "a profile with no handle gets one, and prose survives being prose" {
    // An account with no `name` at all gets one, so clients that read only
    // `name` have something to show. And a name with a quote in it is ESCAPED,
    // not stripped: dropping characters was a fixed-size buffer away from an
    // overflow, and it silently renamed people.
    var model = main.initialModel();
    model.profile_name_buffer.set("A \"quoted\" name \\ here");
    const merged = main.mergeProfileJsonForTest(testing.allocator, "{}", &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\\\"quoted\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\"") != null);
}

test "the name beat merges too, so it can never publish a name as the whole profile" {
    // The beat runs when there is nothing to merge into, but it goes through the
    // merge anyway: the destructive shape is a name published as the WHOLE
    // profile, and one path means that shape cannot come back.
    const existing = "{\"about\":\"kept\",\"lud16\":\"me@example.com\"}";
    const merged = main.mergeNameJsonForTest(testing.allocator, existing, "Bob").?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\"name\":\"Bob\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"about\":\"kept\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"me@example.com\"") != null);
}

test "the name beat forwards the tags it read, the same as the sheet's save" {
    // The beat only arms on a key this app just minted, which has no kind:0 and
    // therefore no NIP-39 proofs to lose, so this is a landmine rather than a
    // live loss: `publishName` read the stored profile and then handed the write
    // seam `&.{}`. Its own doc comment says one path exists so the destructive
    // shape cannot come back, and this is the half of the shape that was still
    // there. Driving the whole write, because the merge helper never sees a tag.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x5b} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/namebeat.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.setIdentityForTest([_]u8{0x5b} ** 32);
    defer main.clearIdentityForTest();

    const tags = [_]nostr.event.Tag{
        &.{ "i", "github:someone", "a-proof-url" },
        &.{ "i", "mastodon:someone@example.social", "another-proof" },
    };
    const before = try nostr.event.create(arena, signer, kp, 1_800_000_000, 0, &tags, "{\"about\":\"kept\"}", null);
    _ = try main.plazaIngestVerifiedForTest(arena, before, signer);

    var model = main.initialModel();
    model.name_buffer.set("Bob");
    var fx: main.EffectsForTest = undefined;
    main.publishNameForTest(&model, &fx);

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 0).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "github:someone") != null);
    try testing.expect(std.mem.indexOf(u8, written, "mastodon:someone@example.social") != null);
}

test "a profile that will not parse does not become a blank profile" {
    // This asserted the opposite of its own title: that garbage merged into an
    // empty object with the sheet's fields written over it, on the reasoning
    // that the caller would decide whether to publish. The caller does not. It
    // publishes whatever the merge hands back, so an unreadable record came out
    // the other side as a kind:0 holding nothing but a display name, and the
    // reader's lightning address, NIP-05, banner and website were gone from
    // every relay and every other client.
    var model = main.initialModel();
    model.profile_name_buffer.set("Alice");
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, "not json at all", &model) == null);

    // Not only outright garbage. Zig's JSON parser rejects an unpaired
    // surrogate half, which parsers elsewhere in the ecosystem accept, so a
    // profile carrying one is a real profile that this app cannot read. It is
    // exactly the reader most likely to have a full profile to lose.
    const lone_surrogate = "{\"name\":\"a\\ud83db\",\"lud16\":\"alice@example.com\"}";
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, lone_surrogate, &model) == null);

    // A root that is valid JSON but not an object is the same story.
    try testing.expect(main.mergeProfileJsonForTest(testing.allocator, "[1,2,3]", &model) == null);

    // Only a caller that says there is nothing there starts from nothing. That
    // is the literal `{}` handed over when no record was found.
    const fresh = main.mergeProfileJsonForTest(testing.allocator, "{}", &model) orelse
        return error.RefusedToWriteAFirstProfile;
    defer testing.allocator.free(fresh);
    try testing.expect(std.mem.indexOf(u8, fresh, "\"display_name\":\"Alice\"") != null);

    // And the ordinary path still merges: a field the sheet does not show must
    // come through the edit untouched, which is what the merge is for.
    const held = "{\"name\":\"alice\",\"lud16\":\"alice@example.com\",\"nip05\":\"alice@example.com\"}";
    const merged = main.mergeProfileJsonForTest(testing.allocator, held, &model) orelse
        return error.LostAReadableProfile;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "\"display_name\":\"Alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"alice@example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"nip05\":\"alice@example.com\"") != null);
}

test "the sheet refuses to save until it has read the profile it would replace" {
    // "The store has no kind:0 for me" means either that this account has no
    // profile or that nobody has answered yet, and those look identical. Saving
    // under the second reading replaces a real profile with three fields.
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(!model.profile_can_save());
    try testing.expect(findAnyTextIn(model.profile_status(), "Reading your current profile"));

    // "Absent" is a fact only for a key this app minted. For an imported one it
    // is what four bootstrap relays happened to say, and this line used to read
    // "only once every read relay has answered does absent become a fact",
    // which was never true of the code underneath it: one EOSE was enough.
    model.profile_stage = .absent;
    main.setIdentityMintedForTest(false);
    try testing.expect(!model.profile_can_save());
    main.setIdentityMintedForTest(true);
    try testing.expect(model.profile_can_save());
    main.setIdentityMintedForTest(false);

    model.profile_stage = .have;
    try testing.expect(model.profile_can_save());
    try testing.expectEqualStrings("", model.profile_status());

    model.profile_stage = .saving;
    try testing.expect(!model.profile_can_save());
}

fn findAnyTextIn(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Every editable field in a built tree, with whether it has a submit handler.
fn assertFieldsEditable(tree: AppUi.Tree, where: []const u8) !void {
    _ = where;
    var stack: [64]canvas.Widget = undefined;
    var depth: usize = 0;
    stack[depth] = tree.root;
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        const w = stack[depth];
        if (w.kind == .textarea or w.kind == .text_field or w.kind == .input or w.kind == .search_field) {
            var has_submit = false;
            for (tree.handlers) |h| {
                if (h.id == w.id and h.event == .submit) has_submit = true;
            }
            try testing.expect(has_submit);
        }
        for (w.children) |child| {
            if (depth < stack.len) {
                stack[depth] = child;
                depth += 1;
            }
        }
    }
}

test "every text field in the app has a submit handler, because without one it is not editable" {
    // A textarea with `on_input` but NO `on_submit` renders, focuses, reports
    // `set_text` in its actions, and accepts nothing: not a keystroke, not a
    // paste, not an automated set_text. It reads as a live field and is inert.
    // The Edit profile sheet shipped that way until it was driven for real, so
    // this walks every screen rather than trusting a reading of one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var settings = main.initialModel();
    settings.stage = .settings;
    try assertFieldsEditable(try buildTree(arena, &settings), "settings");

    var sheet = main.initialModel();
    sheet.stage = .settings;
    sheet.editing_profile = true;
    sheet.profile_stage = .have;
    try assertFieldsEditable(try buildTree(arena, &sheet), "edit profile");

    var composing = main.initialModel();
    composing.stage = .ready;
    composing.composing = true;
    try assertFieldsEditable(try buildTree(arena, &composing), "composer");

    var joining = main.initialModel();
    joining.stage = .ready;
    joining.joining = true;
    try assertFieldsEditable(try buildTree(arena, &joining), "join");

    var naming = main.initialModel();
    naming.stage = .ready;
    naming.naming = true;
    try assertFieldsEditable(try buildTree(arena, &naming), "name");
}

test "an unanswered relay round is never read as 'you have no profile'" {
    // This is the wipe. "The store has no kind:0 for me" means either that the
    // account has no profile or that nobody answered, and only one of those is
    // safe to publish over. The answer therefore records WHO it is about and is
    // only set when a relay actually replied.
    // The identity hooks take a SECRET key; the answer is recorded against the
    // PUBLIC one, which is what a relay was asked about.
    main.forgetOwnProfileAnswerForTest();
    main.setIdentityForTest([_]u8{1} ** 32);
    defer main.clearIdentityForTest();
    const a = main.activePubkeyForTest().?;
    try testing.expect(!main.ownProfileAnsweredForTest());

    // A round where every relay was offline, write-only or refused the dial
    // proves nothing, even though the round finished.
    main.recordOwnProfileAnswerForTest(a, false);
    try testing.expect(!main.ownProfileAnsweredForTest());

    // A relay that replied does prove it.
    main.recordOwnProfileAnswerForTest(a, true);
    try testing.expect(main.ownProfileAnsweredForTest());

    // And it proves it about account A only. Signing in as B must not inherit
    // A's conclusion, or B's Save publishes an empty object over B's profile.
    main.setIdentityForTest([_]u8{2} ** 32);
    try testing.expect(!main.ownProfileAnsweredForTest());
}

test "a relay that never answers leaves the sheet unable to save, not eager to" {
    // `relay.receive()` has no deadline, so a relay that accepts a subscription
    // and then says nothing would hold the round open forever. Waiting has to
    // end in "could not read it", never in "you have no profile".
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(!model.profile_can_save());
    model.profile_stage = .unread;
    try testing.expect(!model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "Could not read") != null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "no profile") == null);
}

test "typing while the profile is still arriving does not delete the rest of it" {
    // The sheet opens on a cold store, the reader types a display name, and the
    // real profile lands a second later. The seeding was all or nothing: one
    // typed character skipped all three fields, and the stage flipped to `have`
    // regardless, so Save lit up over an about and a picture that had never been
    // read. The merge REMOVES a key whose field is empty, so pressing Save
    // deleted the reader's bio and avatar from a profile the app had by then
    // read correctly.
    var model = main.initialModel();
    const existing =
        "{\"display_name\":\"old name\",\"about\":\"the bio they wrote years ago\"," ++
        "\"picture\":\"https://example.com/face.png\",\"lud16\":\"a@b.com\"}";

    // Mid-fetch, the reader has typed a new name and nothing else.
    model.profile_name_buffer.set("new name");

    // The profile arrives. Their sentence survives; the fields they never
    // touched are filled from what actually arrived.
    main.seedProfileFieldsForTest(&model, existing, true);
    try testing.expectEqualStrings("new name", model.profile_name());
    try testing.expectEqualStrings("the bio they wrote years ago", model.profile_about());
    try testing.expectEqualStrings("https://example.com/face.png", model.profile_picture());

    // And the save that follows keeps every one of them.
    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "new name") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "the bio they wrote years ago") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "face.png") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"a@b.com\"") != null);
}

test "an imported key cannot publish a profile over one nobody has read" {
    // `absent` means a relay answered without sending a kind:0. On a cold import
    // the relays being asked are the four this app was born with, which may hold
    // none of the reader's, so that answer is not evidence. Saving from there
    // merged into a literal `{}`: a reader who typed a display name lost their
    // lightning address, their NIP-05, their banner and every NIP-39 proof.
    var model = main.initialModel();
    model.profile_stage = .absent;

    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    try testing.expect(!model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "has not found your profile") != null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "publishes your first one") == null);

    // A key minted in this app has no profile anywhere, which is the one case
    // where absent really is absent.
    main.setIdentityMintedForTest(true);
    try testing.expect(model.profile_can_save());
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "publishes your first one") != null);
}

test "a field too long to show is left alone rather than written back truncated" {
    // The buffers hold 64, 280 and 200 bytes. A longer bio shown cut off, then
    // saved untouched, writes the cut-off version back over the real one: data
    // loss from merely opening a sheet.
    var model = main.initialModel();
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    const existing = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"name\":\"alice\",\"about\":\"{s}\",\"lud16\":\"a@b.com\"}}",
        .{long},
    );
    defer testing.allocator.free(existing);

    main.seedProfileFieldsForTest(&model, existing, false);
    // Not shown at all, rather than shown cut in half.
    try testing.expectEqualStrings("", model.profile_about());
    try testing.expect(model.profile_about_long);

    const merged = main.mergeProfileJsonForTest(testing.allocator, existing, &model).?;
    defer testing.allocator.free(merged);
    // The real bio is still there, at its full length.
    try testing.expect(std.mem.indexOf(u8, merged, long[0..400]) != null);
    try testing.expect(std.mem.indexOf(u8, merged, "\"lud16\":\"a@b.com\"") != null);
}

test "the name edit rewrites the key it was read from" {
    // The field is seeded from display_name, displayName or name, whichever the
    // profile has. Always writing display_name would leave the value the reader
    // edited exactly where it was, so the rename would silently do nothing.
    var model = main.initialModel();

    // A profile using the legacy camelCase key.
    const legacy = "{\"displayName\":\"Old\",\"lud16\":\"a@b.com\"}";
    main.seedProfileFieldsForTest(&model, legacy, false);
    try testing.expectEqualStrings("Old", model.profile_name());
    model.profile_name_buffer.set("New");
    const m1 = main.mergeProfileJsonForTest(testing.allocator, legacy, &model).?;
    defer testing.allocator.free(m1);
    try testing.expect(std.mem.indexOf(u8, m1, "\"displayName\":\"New\"") != null);
    try testing.expect(std.mem.indexOf(u8, m1, "\"Old\"") == null);

    // A profile with only a handle: the handle is what the reader saw, so the
    // handle is what they edited.
    var m2model = main.initialModel();
    const handle_only = "{\"name\":\"alice\",\"lud16\":\"a@b.com\"}";
    main.seedProfileFieldsForTest(&m2model, handle_only, false);
    try testing.expectEqualStrings("alice", m2model.profile_name());
    m2model.profile_name_buffer.set("alice2");
    const m2 = main.mergeProfileJsonForTest(testing.allocator, handle_only, &m2model).?;
    defer testing.allocator.free(m2);
    try testing.expect(std.mem.indexOf(u8, m2, "\"name\":\"alice2\"") != null);
    try testing.expect(std.mem.indexOf(u8, m2, "\"lud16\":\"a@b.com\"") != null);
}

test "a late profile does not overwrite what the reader is typing" {
    // The fetch lands a few seconds after the sheet opens. Seeding then would
    // replace the sentence they are in the middle of writing.
    var model = main.initialModel();
    model.profile_stage = .fetching;
    try testing.expect(model.profile_untouched());
    model.profile_about_buffer.set("halfway through a th");
    try testing.expect(!model.profile_untouched());
}

test "saving says what is true, and stays available for the next correction" {
    // Nothing here can know a relay took it: signAndPublish returns no verdict,
    // the remote and helper paths have not even signed yet, and a kind:0 that
    // reaches nobody is not retried. And a typo in the name just saved must be
    // fixable without closing the sheet.
    var model = main.initialModel();
    model.profile_stage = .sent;
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "Published") == null);
    try testing.expect(std.mem.indexOf(u8, model.profile_status(), "sent to your relays") != null);
    try testing.expect(model.profile_can_save());
}

test "a replaced relay list is kept, and can be read back" {
    // The store enforces replaceable semantics the way relays do:
    // `ingestReplaceable` DELETES the superseded event in the same transaction.
    // That is right for other people's records and wrong for ours, because the
    // version being destroyed may be the one the reader wants back. A copy
    // nothing can read is not a copy, so this test reads it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{77} ** 32);
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/backup.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const first_tags = [_]nostr.event.Tag{
        &.{ "r", "wss://one.example.com" },
        &.{ "r", "wss://two.example.com" },
    };
    const first = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &first_tags, "", null);
    _ = try main.plazaIngestForTest(arena, first);

    // The replacement. This is the moment the first one is destroyed.
    const second_tags = [_]nostr.event.Tag{&.{ "r", "wss://replacement.example.com" }};
    const second = try nostr.event.create(arena, signer, kp, 1_800_000_100, 10002, &second_tags, "", null);
    _ = try main.plazaIngestForTest(arena, second);

    // The store holds only the new one, exactly as a relay would.
    const kinds = [_]u16{10002};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 10 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    try testing.expect(std.mem.indexOf(u8, result.events[0].tags[0][1], "replacement") != null);

    // And the one it replaced is still here, in full, readable.
    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://one.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://two.example.com") != null);
    // It is the real event, not a summary: it can be republished as-is.
    try testing.expect(std.mem.indexOf(u8, backup, "\"sig\"") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "\"kind\":10002") != null);
}

test "the backup keeps a few versions, not a history" {
    // The store's KV has no cursor and no delete, so a growing key scheme could
    // never be read back or pruned. One rewritten key holding the last few is
    // the only shape that is both readable and bounded.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{78} ** 32);
    main.setIdentityForTest([_]u8{78} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/keep.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    var i: i64 = 0;
    while (i < 6) : (i += 1) {
        const url = try std.fmt.allocPrint(arena, "wss://v{d}.example.com", .{i});
        const tags = [_]nostr.event.Tag{&.{ "r", url }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + i, 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }

    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    // The most recent replacements are here.
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v4.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v3.example.com") != null);
    // The oldest are not: this is a way back from the last mistake, not an
    // archive that grows inside the feed's database forever.
    try testing.expect(std.mem.indexOf(u8, backup, "wss://v0.example.com") == null);
    var lines = std.mem.tokenizeScalar(u8, backup, '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try testing.expect(count <= 3);
}

test "someone else's replaced list is not backed up" {
    // The backup exists because losing OUR list is unrecoverable. Another
    // author's kind:0 is re-fetchable from any relay, and keeping every one
    // would fill the reader's disk with other people's history.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const mine = try signer.keyPairFromSecretKey([_]u8{79} ** 32);
    const theirs = try signer.keyPairFromSecretKey([_]u8{80} ** 32);
    main.setIdentityForTest([_]u8{79} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/theirs.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    _ = mine;

    const a = try nostr.event.create(arena, signer, theirs, 1_800_000_000, 0, &.{}, "{\"name\":\"old\"}", null);
    _ = try main.plazaIngestForTest(arena, a);
    const b = try nostr.event.create(arena, signer, theirs, 1_800_000_100, 0, &.{}, "{\"name\":\"new\"}", null);
    _ = try main.plazaIngestForTest(arena, b);

    try testing.expect(main.ownListBackups(testing.allocator, 0) == null);
}

test "the pool left behind by a sign-out is never published as the next account's list" {
    // The wipe this ownership record exists to stop, in order:
    //   1. signing out writes the BOOTSTRAP pool to ~/.plaza/relays
    //   2. the next launch reads that file back
    //   3. a bool called "these relays are mine" said yes
    //   4. so the account that signs in next has its real kind:10002 REFUSED
    //   5. and its first badge press publishes five default relays over it.
    // A list belongs to whoever was signed in when it was saved, so the record
    // is a pubkey, not a bool.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://their-real-relay.example.com" },
        &.{ "r", "wss://their-other-relay.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{31} ** 32,
        .created_at = 9_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };

    // Step 1 and 2: the bootstrap pool is in memory, as if just read from a file
    // written while signed out. It has no owner.
    main.resetRelaysForTest();
    try testing.expectEqual(@as(?[32]u8, null), main.relayOwnerForTest());

    // Step 3: signing in does NOT make that pool theirs.
    main.setIdentityForTest([_]u8{31} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(!main.relayListIsOwnedForTest());

    // Step 4: so their real list is adopted rather than refused.
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://their-real-relay.example.com", main.relayUrlAt(0));
    try testing.expectEqual(@as(usize, 2), main.relayCount());

    // And now it IS theirs, so a later stale event cannot undo it.
    try testing.expect(main.relayListIsOwnedForTest());
}

test "one account's saved relay list is not another account's" {
    // Two readers share a Mac. The first signs out, the second signs in. The
    // file on disk is the first one's, and must not silence the second's list.
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{41} ** 32);
    _ = main.addRelayForTest("wss://first-reader.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayListIsOwnedForTest());

    // The same pool, a different reader: not theirs.
    main.setIdentityForTest([_]u8{42} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(!main.relayListIsOwnedForTest());

    // Which means their own list is free to arrive.
    const tags = [_]nostr.event.Tag{&.{ "r", "wss://second-reader.example.com" }};
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{42} ** 32,
        .created_at = 9_000,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://second-reader.example.com", main.relayUrlAt(0));
}

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

test "editing a relay list does not grant permission to publish it" {
    // The hole this whole change exists to close, in its second disguise. An
    // edit claims the pool for the account, which is what stops a stale event
    // undoing it. Claiming is not reading: if an edit ALSO authorized its own
    // publish, the first badge press on a bootstrap pool would still replace a
    // real list nobody had looked at.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{61} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    // An edit: now owned.
    _ = main.addRelayForTest("wss://edited.example.com", true, true);
    main.markRelaysMineForTest();
    try testing.expect(main.relayListIsOwnedForTest());
    // But their own list is not here, so nothing goes out. Driving the real
    // publish, not just its predicates: "did not publish" IS the property, so a
    // test that only reads the flags proves nothing.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.publishRelayListForTest(&fx));

    // A key minted in this app moments ago has no history to lose, and that is
    // the ONE thing besides holding the list that opens the gate.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.publishRelayListForTest(&fx));
}

test "one relay's EOSE is not permission to replace a relay list" {
    // The gate used to be "some relay reached the end of its answer without
    // sending a kind:10002, so they have none". On a cold import the relays
    // being asked are the four this app was born with, which may hold none of
    // the reader's. Four clean answers coexisted with a twelve-relay list
    // somewhere else, and a single badge press published the four over it.
    //
    // There is nothing left to call: the flag and its setter are gone. What
    // this pins is the consequence, which is what a future gate would have to
    // keep true.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{63} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    _ = main.addRelayForTest("wss://bootstrap.example.com", true, true);
    main.markRelaysMineForTest();

    // Every relay in the pool has now finished answering. That is not evidence.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.canWriteRelayListForTest());
    try testing.expect(!main.publishRelayListForTest(&fx));
}

test "a relay list is spliced onto the one the reader published" {
    // The publish used to build the whole event out of the pool, which holds
    // eight. A reader with thirteen relays had five deleted from their NIP-65
    // list by one badge press, along with every tag type this app does not
    // model. The event is now what they published, plus what they changed here.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{77} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/splice.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.forgetRelayRemovalsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    // Their real list: more relays than the pool has seats, plus a tag this app
    // has never heard of. The store is the only thing that can hold it, because
    // the pool structurally cannot.
    const published = [_]nostr.event.Tag{
        &.{ "r", "wss://kept-1.example.com" },
        &.{ "r", "wss://kept-2.example.com" },
        &.{ "r", "wss://kept-3.example.com" },
        &.{ "r", "wss://kept-4.example.com" },
        &.{ "r", "wss://kept-5.example.com" },
        &.{ "r", "wss://kept-6.example.com" },
        &.{ "r", "wss://kept-7.example.com" },
        &.{ "r", "wss://kept-8.example.com" },
        &.{ "r", "wss://overflow-9.example.com" },
        &.{ "r", "wss://overflow-10.example.com", "read" },
        &.{ "unmodelled", "something this app does not read" },
    };
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &published, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    // The pool as the app would hold it: the first eight, which is all it can.
    for (published[0..8]) |tag| _ = main.addRelayForTest(tag[1], true, true);
    main.markRelaysMineForTest();

    // One badge press, then the publish it settles into.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.publishRelayListForTest(&fx));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10002).?;
    defer testing.allocator.free(written);
    // The eight the pool holds.
    try testing.expect(std.mem.indexOf(u8, written, "kept-1.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "kept-8.example.com") != null);
    // THE PROPERTY: the two the pool had no seat for are still in their list,
    // with their markers, and so is the tag this app does not model.
    try testing.expect(std.mem.indexOf(u8, written, "overflow-9.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "overflow-10.example.com read") != null);
    try testing.expect(std.mem.indexOf(u8, written, "unmodelled") != null);
}

test "a removed relay is not put back by the splice that protects the rest" {
    // The splice carries forward every relay the pool has no seat for, and a
    // relay the reader just removed looks exactly like one of those. Without a
    // ledger of removals the splice would undo every removal press.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{78} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/removed.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.forgetRelayRemovalsForTest();
    main.setIdentityForTest([_]u8{78} ** 32);
    defer main.clearIdentityForTest();

    const published = [_]nostr.event.Tag{
        &.{ "r", "wss://staying.example.com" },
        &.{ "r", "wss://going.example.com" },
    };
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &published, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);

    _ = main.addRelayForTest("wss://staying.example.com", true, true);
    const going = main.addRelayForTest("wss://going.example.com", true, true).?;
    main.markRelaysMineForTest();

    // The press. `removeRelayForTest` drives the same function the button does,
    // so the ledger is written by the code under test rather than by the test.
    main.removeRelayForTest(going);

    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.publishRelayListForTest(&fx));

    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 10002).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "staying.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, written, "going.example.com") == null);
}

test "an edit that could not be published is still pending" {
    // The settle timer used to CONSUME the edit: it cleared the dirty flag and
    // handed the publish a chance it could refuse. An edit made before this
    // account's list had been read was refused, the flag was already gone, and
    // nothing tried again, so the edit lived on this machine and nowhere else
    // for the rest of the install.
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityForTest([_]u8{79} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    main.clearRelayListPublishForTest();

    _ = main.addRelayForTest("wss://typed-on-a-plane.example.com", true, true);
    main.markRelaysMineForTest();
    main.relayListEditedForTest(1_000);

    // Two seconds later the tick fires and the publish is refused.
    var fx: main.EffectsForTest = undefined;
    main.flushRelayListForTest(&fx, 1_003);
    try testing.expect(main.relayListPendingForTest());

    // The reason clears, and the same edit goes out without another press.
    main.setIdentityMintedForTest(true);
    main.flushRelayListForTest(&fx, 1_004);
    try testing.expect(!main.relayListPendingForTest());
}

test "the store decides what a replacement is, not the backup" {
    // NIP-01 breaks a created_at tie on the id, and the store implements it. The
    // backup used to make its own call with `previous.created_at >= ev.created_at`
    // and so skipped the copy for exactly the case where the store DID replace:
    // equal stamps, lower id. Deciding after the store has spoken removes the
    // second opinion entirely.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{89} ** 32);
    main.setIdentityForTest([_]u8{89} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/tie.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Two events at the SAME second, differing only in content, so their ids
    // differ and one of them is lexicographically lower.
    const a_tags = [_]nostr.event.Tag{&.{ "r", "wss://aaa.example.com" }};
    const b_tags = [_]nostr.event.Tag{&.{ "r", "wss://bbb.example.com" }};
    const a = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &a_tags, "", null);
    const b = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &b_tags, "", null);

    // Ingest the one that will LOSE the tie first, so the other replaces it.
    const first = if (std.mem.order(u8, &a.id, &b.id) == .lt) b else a;
    const second = if (std.mem.order(u8, &a.id, &b.id) == .lt) a else b;
    _ = try main.plazaIngestVerifiedForTest(arena, first, signer);
    const result = try main.plazaIngestVerifiedForTest(arena, second, signer);
    try testing.expectEqual(nostr.store.IngestResult.replaced, result);

    // The store destroyed a version, so a copy of it exists.
    const backup = main.ownListBackups(testing.allocator, 10002).?;
    defer testing.allocator.free(backup);
    const lost_url: []const u8 = if (std.mem.eql(u8, &first.id, &a.id)) "aaa.example.com" else "bbb.example.com";
    try testing.expect(std.mem.indexOf(u8, backup, lost_url) != null);
}

test "following writes the newest known list plus the change, and nothing else moves" {
    // A contact list is REPLACEABLE: publishing one replaces who this reader
    // follows, on every relay, at once. So a follow is the list they already
    // have plus one name, and everything that list carried comes back with it:
    // the petnames and relay hints on other people's p tags, tag types this app
    // does not model, and the content blob, which on older clients is a relay
    // map and on none of them is ours to discard.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{91} ** 32);
    main.setIdentityForTest([_]u8{91} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/follow.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Their real list: two follows, one with a petname and a relay hint, plus a
    // tag type this app has never heard of and a content blob.
    const alice = "aa" ** 32;
    const bob = "bb" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "p", alice, "wss://alice-relay.example.com", "Alice" },
        &.{ "p", bob },
        &.{ "t", "some-future-thing" },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "{\"wss://legacy.example.com\":{\"read\":true}}", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.noteOwnContactsAnsweredForTest(kp.public_key);

    // Follow a third person.
    var carol: [32]u8 = undefined;
    @memset(&carol, 0xcc);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, carol, true));

    // The published list is the old one plus Carol.
    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.events.len);
    const published = result.events[0];

    var saw_alice_petname = false;
    var saw_bob = false;
    var saw_carol = false;
    var saw_unknown_tag = false;
    for (published.tags) |tag| {
        if (tag.len >= 4 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], alice)) {
            // The petname and the relay hint travelled with it.
            if (std.mem.eql(u8, tag[3], "Alice") and std.mem.eql(u8, tag[2], "wss://alice-relay.example.com")) saw_alice_petname = true;
        }
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], bob)) saw_bob = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], "cc" ** 32)) saw_carol = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "t")) saw_unknown_tag = true;
    }
    try testing.expect(saw_alice_petname);
    try testing.expect(saw_bob);
    try testing.expect(saw_carol);
    try testing.expect(saw_unknown_tag);
    // And the legacy relay map in the content is still there.
    try testing.expect(std.mem.indexOf(u8, published.content, "legacy.example.com") != null);
    // Stamped past the one it replaced, or every relay drops it in silence.
    try testing.expect(published.created_at > 1_800_000_000);
}

test "unfollowing removes exactly one name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{92} ** 32);
    main.setIdentityForTest([_]u8{92} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/unfollow.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const tags = [_]nostr.event.Tag{
        &.{ "p", "aa" ** 32 },
        &.{ "p", "bb" ** 32 },
        &.{ "p", "cc" ** 32 },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);
    main.noteOwnContactsAnsweredForTest(kp.public_key);

    var bob: [32]u8 = undefined;
    @memset(&bob, 0xbb);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, bob, false));

    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var count: usize = 0;
    var saw_bob = false;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p")) {
            count += 1;
            if (std.mem.eql(u8, tag[1], "bb" ** 32)) saw_bob = true;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(!saw_bob);
}

test "no follow is written before a relay has said who you already follow" {
    // The hard rule. "Nobody answered" and "you follow nobody" look identical
    // from here, and publishing under the second reading replaces a list of
    // hundreds with a handful of accounts this app chose.
    main.setIdentityForTest([_]u8{93} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();

    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    try testing.expect(!main.canWriteFollows());
    var someone: [32]u8 = undefined;
    @memset(&someone, 0xab);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.writeFollowForTest(&fx, someone, true));

    // Relay silence is NOT evidence for an imported key. Every relay in the pool
    // answering changes nothing, because on a cold import the pool is this app's
    // bootstrap five, chosen before the reader's own kind:10002 was read: five
    // clean answers happily coexist with eight hundred follows on relays this
    // app has never dialed.
    const me = main.activePubkeyForTest().?;
    for (0..5) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(!main.canWriteFollows());
    try testing.expect(main.followBlockedReason() != null);

    // A key MINTED here is different in kind: it provably has no history, so
    // there is nothing a write could destroy.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.followBlockedReason() == null);

    // And that fact belongs to the key, not the session.
    main.setIdentityForTest([_]u8{94} ** 32);
    main.setIdentityMintedForTest(false);
    try testing.expect(!main.canWriteFollows());
}

test "a contact list read from a relay becomes the feed, and an empty one does not" {
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        // A duplicate and a malformed entry: neither should reach the feed.
        &.{ "p", "11" ** 32 },
        &.{ "p", "not-hex" },
        &.{"p"},
    };
    var out: [128][32]u8 = undefined;
    const n = main.followsFromTagsForTest(&tags, &out);
    try testing.expectEqual(@as(usize, 2), n);

    // A list with no usable p tag is not a list: adopting it would empty the
    // reader's feed on the word of one malformed event.
    const empty_tags = [_]nostr.event.Tag{&.{ "p", "nope" }};
    try testing.expectEqual(@as(usize, 0), main.followsFromTagsForTest(&empty_tags, &out));
}

test "one reader's follows are never another's" {
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{95} ** 32);
    defer main.clearIdentityForTest();
    var list: [2][32]u8 = undefined;
    @memset(&list[0], 0x11);
    @memset(&list[1], 0x22);
    try testing.expect(main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expectEqual(@as(usize, 2), main.followSetForTest().len);

    // A different account, the same table: back to the pack until their own
    // list arrives. Showing them a stranger's follows would be showing them
    // somebody else's reading.
    main.setIdentityForTest([_]u8{96} ** 32);
    try testing.expectEqual(@as(usize, 9), main.followSetForTest().len);
}

test "a follow changes the generation, so the live subscriptions re-ask" {
    // Without this a follow shows nothing new until the socket happens to drop,
    // which reads as a broken button.
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{97} ** 32);
    defer main.clearIdentityForTest();
    const before = main.followGeneration();
    var list: [1][32]u8 = undefined;
    @memset(&list[0], 0x33);
    try testing.expect(main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expect(main.followGeneration() != before);

    // The same list again is not a change, and must not churn every relay.
    const after = main.followGeneration();
    try testing.expect(!main.setFollowsForTest(&list, 1_800_000_000));
    try testing.expectEqual(after, main.followGeneration());
}

test "the feed's scope line stops calling your own follows hand-picked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetFollowsForTest();
    var guest = main.initialModel();
    try testing.expectEqualStrings("Starter pack", guest.scope_name());
    try testing.expect(std.mem.indexOf(u8, guest.scope_voices(arena), "hand-picked") != null);

    main.setIdentityForTest([_]u8{98} ** 32);
    defer main.clearIdentityForTest();
    var list: [3][32]u8 = undefined;
    for (&list, 0..) |*e, i| @memset(e, @intCast(i + 1));
    _ = main.setFollowsForTest(&list, 1_800_000_000);

    var mine = main.initialModel();
    try testing.expectEqualStrings("Following", mine.scope_name());
    const voices = mine.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, voices, "hand-picked") == null);
    try testing.expect(std.mem.indexOf(u8, voices, "3 accounts") != null);
}

test "a full follow list rebuilds the feed fast enough to do it every second" {
    // The store opens ONE LMDB cursor per author and then, for every event it
    // emits, linearly picks the newest across all live streams. Its own comment
    // says "stream counts are small". That is true at nine and the reason this
    // test exists: the feed rebuilds whenever the store's event count moves,
    // which the live pool makes about once a second, so a linear-per-event pick
    // over a full follow list is a frame hitch the reader feels rather than a
    // number in a benchmark.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{99} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/perf.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    // A full list, each with a handful of notes, which is the shape a real
    // reader's feed has.
    const follows = 128;
    var list: [follows][32]u8 = undefined;
    var i: usize = 0;
    while (i < follows) : (i += 1) {
        var secret: [32]u8 = undefined;
        @memset(&secret, @intCast((i % 200) + 1));
        secret[31] = @intCast(i & 0xff);
        secret[30] = @intCast((i >> 8) & 0xff);
        const kp = signer.keyPairFromSecretKey(secret) catch continue;
        list[i] = kp.public_key;
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            const body = try std.fmt.allocPrint(arena, "note {d} from {d}", .{ n, i });
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i * 10 + n)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    try testing.expectEqual(@as(usize, follows), main.followSetForTest().len);

    var model = main.initialModel();
    model.stage = .ready;
    // One rebuild to warm the page cache, then time a run of them.
    main.reconcileForTest(&model, &store, 1_800_002_000);
    try testing.expect(model.notes_len > 0);

    // `std.time.Timer` is gone in 0.16; the awake clock is what the app itself
    // times relay round trips with.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const started = std.Io.Timestamp.now(io, .awake);
    const rounds = 10;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        main.invalidateFeedForTest();
        main.reconcileForTest(&model, &store, 1_800_002_000);
    }
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    const per_rebuild_ns = @as(u64, @intCast(@max(elapsed.toNanoseconds(), 0))) / rounds;

    // The budget is one frame at 60Hz, which is the honest bar: this runs on
    // the UI thread on a timer, so anything slower is a visible stutter every
    // second rather than a slow benchmark. Generous enough not to be flaky on a
    // loaded CI box, tight enough to catch the cliff.
    const budget_ns = 16 * std.time.ns_per_ms;
    std.debug.print("\n[perf] {d} follows: {d}us per feed rebuild (budget {d}us)\n", .{ follows, per_rebuild_ns / 1000, budget_ns / 1000 });
    if (per_rebuild_ns > budget_ns) {
        std.debug.print(
            "\nfeed rebuild with {d} follows took {d}us, budget {d}us\n",
            .{ follows, per_rebuild_ns / 1000, budget_ns / 1000 },
        );
        return error.FeedRebuildTooSlow;
    }
}

test "the note menu says which way it goes, and refuses when it cannot know" {
    // The one control that writes a contact list. Every state it can be in is
    // asserted here, because the harness cannot open a thread by pressing a row
    // (true on main too), and because the dangerous state is the one that must
    // NOT offer a press: a Follow that fires before the app has been told who
    // the reader already follows replaces that list with this app's guesses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const author = [_]u8{0x55} ** 32;
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = author;
    model.note_menu = model.thread_root.id;

    // A guest: the menu offers Follow, and pressing it raises the join sheet
    // rather than failing quietly.
    main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "Follow") != null);
    }

    // Signed in, but nobody has said who they follow yet: the menu says what it
    // is waiting for instead of offering a press.
    main.setIdentityForTest([_]u8{0x66} ** 32);
    main.setIdentityMintedForTest(false);
    defer main.clearIdentityForTest();
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "Looking for your follow list…") != null);
        try testing.expect(findAnyText(tree.root, "Unfollow") == null);
    }

    // A key minted here has no history to lose: Follow.
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(true);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "Follow") != null);
        try testing.expect(findAnyText(tree.root, "Looking for your follow list…") == null);
    }

    // Already following: the menu offers the way back out.
    var list: [1][32]u8 = undefined;
    list[0] = author;
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "Unfollow") != null);
    }

    // Their own note: no follow control at all, in either direction.
    model.thread_root.pubkey = main.activePubkeyForTest().?;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "This is you") != null);
        try testing.expect(findAnyText(tree.root, "Unfollow") == null);
    }
}

test "a guest pressing follow is offered the join sheet, not a silent failure" {
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x77} ** 32;
    main.clearIdentityForTest();

    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .follow_author = 0 }, &fx);
    try testing.expect(model.joining);
    try testing.expectEqual(@as(i64, 0), model.note_menu);
}

test "a contact list arriving from a relay becomes the feed's scope" {
    // The whole chain in one place: a signed kind:3 goes through the same
    // funnel every relay-fed event goes through, is recognised as the reader's
    // own, becomes the live follow set, and the feed's scope line stops saying
    // the app picked it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{101} ** 32);
    main.setIdentityForTest([_]u8{101} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.setIdentityMintedForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/scope.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Before: the pack, and nothing may be written.
    var before = main.initialModel();
    try testing.expectEqualStrings("Starter pack", before.scope_name());
    try testing.expect(!main.canWriteFollows());

    const tags = [_]nostr.event.Tag{
        &.{ "p", "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d" },
        &.{ "p", "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2" },
        &.{ "p", "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.ingestContactListForTest(ev);

    // After: theirs, three accounts, and a write is now allowed because a relay
    // has actually said what the list is.
    try testing.expectEqual(@as(usize, 3), main.followSetForTest().len);
    try testing.expect(main.canWriteFollows());
    var after = main.initialModel();
    try testing.expectEqualStrings("Following", after.scope_name());
    const voices = after.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, voices, "3 accounts · yours") != null);

    // And a stale list arriving later does not undo it.
    const older_tags = [_]nostr.event.Tag{&.{ "p", "aa" ** 32 }};
    const older = try nostr.event.create(arena, signer, kp, 1_700_000_000, 3, &older_tags, "", null);
    main.ingestContactListForTest(older);
    try testing.expectEqual(@as(usize, 3), main.followSetForTest().len);
}

test "the scope line states how many accounts the feed reads" {
    // This used to guard a second number. The feed read a slice of the list, so
    // the line said "128 of 300 accounts": stating only the first to somebody
    // who follows three hundred people is a lie about their own data.
    //
    // The feed reads the whole list now, so there is one number and it is the
    // right one. What is left to guard is that it is the LIST's number and not
    // the window's, and that a reader is never quietly told a smaller one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{102} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var many: [300][32]u8 = undefined;
    for (&many, 0..) |*e, i| {
        @memset(e, @intCast(i % 251));
        e[31] = @intCast(i & 0xff);
        e[30] = @intCast((i >> 8) & 0xff);
    }
    _ = main.setFollowsForTest(&many, 1_800_000_000);

    // Three hundred follows are all read, and stated as one number.
    try testing.expectEqual(@as(usize, 300), main.followSetForTest().len);
    var model = main.initialModel();
    const three_hundred = model.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, three_hundred, "300 accounts \u{b7} yours") != null);
    try testing.expect(std.mem.indexOf(u8, three_hundred, " of ") == null);

    // A single follow is not "1 accounts".
    var one: [1][32]u8 = undefined;
    @memset(&one[0], 7);
    _ = main.setFollowsForTest(&one, 1_800_000_001);
    try testing.expect(std.mem.indexOf(u8, model.scope_voices(arena), "1 account \u{b7} yours") != null);

    // A list that fits states one number, without the arithmetic.
    var few: [3][32]u8 = undefined;
    for (&few, 0..) |*e, i| @memset(e, @intCast(i + 40));
    _ = main.setFollowsForTest(&few, 1_800_000_000);
    const small = model.scope_voices(arena);
    try testing.expect(std.mem.indexOf(u8, small, "3 accounts · yours") != null);
    try testing.expect(std.mem.indexOf(u8, small, " of ") == null);
}

test "one relay's silence never authorizes replacing a contact list" {
    // The failure this whole feature is built to avoid, and the one my first
    // gate let through. EOSE means "that is all I have", not "you have none".
    // A reader follows 2000 accounts whose list lives on two relays. A third
    // relay, which simply does not carry it, finishes first. If that unlocked
    // the write, pressing Follow would publish nine hard-coded accounts over
    // the real list, on every relay, and 1991 follows would be gone.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{103} ** 32);
    main.setIdentityForTest([_]u8{103} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    // An IMPORTED key: this app cannot know what it already follows.
    main.setIdentityMintedForTest(false);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/silence.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    var someone: [32]u8 = undefined;
    @memset(&someone, 0xde);
    var fx: main.EffectsForTest = undefined;

    // Every relay answers with nothing, and it still proves nothing: the pool
    // here is the app's bootstrap five, and the reader's list lives wherever
    // their own kind:10002 points, which has not been read either.
    for (0..5) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(main.contactsConfirmedAbsentForTest());
    try testing.expect(!main.canWriteFollows());
    try testing.expect(!main.writeFollowForTest(&fx, someone, true));
    // Nothing was published.
    {
        const kinds = [_]u16{3};
        const authors = [_][32]u8{kp.public_key};
        var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
        defer result.deinit();
        try testing.expectEqual(@as(usize, 0), result.events.len);
    }

    // Then the slow relay delivers the real list. Having it is the OTHER way to
    // be allowed to write, and the safe one: the write splices into it.
    var tags: [200]nostr.event.Tag = undefined;
    var hexes: [200][64]u8 = undefined;
    for (0..200) |i| {
        _ = try std.fmt.bufPrint(&hexes[i], "{x:0>2}{s}", .{ @as(u8, @intCast(i)), "ab" ** 31 });
        const pair = try arena.alloc([]const u8, 2);
        pair[0] = "p";
        pair[1] = &hexes[i];
        tags[i] = pair;
    }
    const real = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, real, signer);
    main.ingestContactListForTest(real);

    try testing.expect(main.haveOwnContactListForTest());
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.writeFollowForTest(&fx, someone, true));

    // And the published list is 201 names, not 10.
    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var p_count: usize = 0;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p")) p_count += 1;
    }
    try testing.expectEqual(@as(usize, 201), p_count);
}

test "membership is right for every follow, and so is what the feed reads" {
    // These were two different numbers, and the bug that named this test was
    // asking the feed's bounded slice a membership question: a reader with three
    // hundred follows was told that follows 129 and up were strangers, and a new
    // follow is APPENDED, so the people they had followed most recently were the
    // ones most likely to be misfiled.
    //
    // The feed reads the whole list now, so for any list the table holds the two
    // questions agree. They can still diverge past the table, which is why they
    // are still asked separately here rather than collapsed into one.
    main.setIdentityForTest([_]u8{104} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var many: [400][32]u8 = undefined;
    for (&many, 0..) |*e, i| {
        @memset(e, @intCast(i % 251));
        e[31] = @intCast(i & 0xff);
        e[30] = @intCast((i >> 8) & 0xff);
    }
    _ = main.setFollowsForTest(&many, 1_800_000_000);

    // The feed reads all of them, and all of them are followed.
    try testing.expectEqual(@as(usize, 400), main.followSetForTest().len);
    try testing.expectEqual(@as(usize, 400), main.followTotal());
    // With a list of the reader's OWN, the two questions agree: everybody on it
    // is both read and followed.
    for ([_]usize{ 399, 200, 0 }) |i| {
        try testing.expect(main.isFollowedByMe(many[i]));
        try testing.expect(main.isInReadGraph(many[i]));
    }
    var stranger: [32]u8 = undefined;
    @memset(&stranger, 0xff);
    stranger[0] = 0xfe;
    try testing.expect(!main.isFollowedByMe(stranger));
    try testing.expect(!main.isInReadGraph(stranger));
}

test "an older contact list never undoes a newer one" {
    main.setIdentityForTest([_]u8{105} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    const newer_tags = [_]nostr.event.Tag{ &.{ "p", "11" ** 32 }, &.{ "p", "22" ** 32 } };
    const newer = nostr.event.Event{
        .id = [_]u8{1} ** 32,
        .pubkey = main.activePubkeyForTest().?,
        .created_at = 2_000,
        .kind = 3,
        .tags = &newer_tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    var older = newer;
    const older_tags = [_]nostr.event.Tag{&.{ "p", "33" ** 32 }};
    older.created_at = 1_000;
    older.tags = &older_tags;

    main.ingestContactListForTest(newer);
    try testing.expectEqual(@as(usize, 2), main.followTotal());
    // A slower relay's older copy arrives second and is refused.
    main.ingestContactListForTest(older);
    try testing.expectEqual(@as(usize, 2), main.followTotal());
}

test "the follow list survives a restart" {
    // A local-first app that forgets who you follow every launch is not local
    // first. The store already holds the newest kind:3 from last session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{106} ** 32);
    main.setIdentityForTest([_]u8{106} ** 32);
    defer main.clearIdentityForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/restart.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const tags = [_]nostr.event.Tag{ &.{ "p", "44" ** 32 }, &.{ "p", "55" ** 32 }, &.{ "p", "66" ** 32 } };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    // A restart: the in-memory list is gone, the store is not.
    main.forgetFollowsForTest();
    try testing.expectEqual(@as(usize, 9), main.followSetForTest().len);
    main.loadFollowsFromStoreForTest();
    try testing.expectEqual(@as(usize, 3), main.followTotal());
    // And the app can write immediately, without waiting on any relay.
    try testing.expect(main.canWriteFollows());
}

test "an imported key is never assumed to follow nobody, however quiet the relays" {
    // The hole every relay-completion gate has, and the reason this one is not
    // a relay gate at all. On a cold import the app has not read the reader's
    // kind:10002 yet, so the relays it is asking are its own bootstrap five.
    // They can all answer cleanly while the real list sits on relays this app
    // has never dialed. Silence from the wrong relays is not evidence.
    main.setIdentityForTest([_]u8{107} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setStoreForTest(null);

    const me = main.activePubkeyForTest().?;
    main.setIdentityMintedForTest(false);
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    try testing.expect(!main.canWriteFollows());
    // And the reader is told why, rather than handed a button that does nothing.
    try testing.expectEqualStrings("Looking for your follow list…", main.followBlockedReason().?);

    // A key minted here is the one case where "no list" is knowledge, not a
    // guess, because the key did not exist a minute ago.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.canWriteFollows());
    try testing.expect(main.followBlockedReason() == null);
}

test "a write that would drop more names than the press implies is refused" {
    // The shrink guard. No client in the ecosystem has one. A follow adds a
    // name and an unfollow removes exactly one, so a write that loses more is
    // this app's own bug, a stale base, or a rebase onto somebody else's
    // truncation. Refusing beats publishing and finding out later.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        &.{ "p", "33" ** 32 },
        &.{ "t", "not-a-person" },
        // The same person twice, which some clients emit. Removing both is
        // removing ONE person, so the count is of distinct people.
        &.{ "p", "33" ** 32 },
    };
    try testing.expectEqual(@as(usize, 3), main.countPeopleForTest(&tags));

    // Following may not lose anyone.
    try testing.expect(main.shrinkAllowedForTest(100, 101, true));
    try testing.expect(main.shrinkAllowedForTest(100, 100, true));
    try testing.expect(!main.shrinkAllowedForTest(100, 99, true));
    // Unfollowing may lose exactly one.
    try testing.expect(main.shrinkAllowedForTest(100, 99, false));
    try testing.expect(!main.shrinkAllowedForTest(100, 98, false));
    // The case this exists for: a stale base losing hundreds.
    try testing.expect(!main.shrinkAllowedForTest(2000, 9, false));
    try testing.expect(!main.shrinkAllowedForTest(2000, 10, true));
}

test "a second follow before the signer answers does not undo the first" {
    // `writeFollow` takes its base from the store, and a bunker or a Notary key
    // does not write the store until the signer answers: one to five seconds,
    // longer with an approval prompt in front of a human. Two presses inside
    // that window both read the SAME pre-press list, so the second published a
    // list without the first in it, at a newer stamp, and the first follow was
    // undone on every relay while both said "Following".
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x3c} ** 32);
    main.setIdentityForTest([_]u8{0x3c} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.clearPendingFollowBaseForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/twofollows.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Their real list, with a petname on it so the splice has something to lose.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32, "wss://their-relay.example.com", "an old friend" },
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);

    // The first press, as a remote signer leaves it: the list is SIGNED, and the
    // store still holds the pre-press one because the signer has not answered.
    // A local key writes the store inside the press, which is why that path
    // never had this bug and why the gap is set up rather than waited for.
    const signed_first = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32, "wss://their-relay.example.com", "an old friend" },
        &.{ "p", "a1" ** 32 },
    };
    main.setPendingFollowBaseForTest(&signed_first, "", 1_800_000_100);

    // The second press, driven for real.
    var bob: [32]u8 = undefined;
    @memset(&bob, 0xb2);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, bob, true));

    // THE PROPERTY: the published list has BOTH, plus the friend it started
    // with, petname and relay hint intact. Reading the STORE, because the local
    // signer this test uses does write it, so this is what actually went out.
    const written = main.ownRecordTagsJoinedForTest(testing.allocator, 3).?;
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "a1" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "b2" ** 32) != null);
    try testing.expect(std.mem.indexOf(u8, written, "an old friend") != null);
    try testing.expect(std.mem.indexOf(u8, written, "wss://their-relay.example.com") != null);
}

test "a contact list that cannot be read is not a contact list of nine" {
    // `canWriteFollows` asks the store whether this account has a kind:3, and
    // `writeFollow` then asked it AGAIN for the list itself. A transient failure
    // between the two reads turned "they have a list, splice onto it" into "they
    // have none, publish the nine names this app chose" over a real one. The
    // decision comes from the single read now, so nothing can disagree with it.
    main.setIdentityForTest([_]u8{0x3d} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.clearPendingFollowBaseForTest();
    // No store at all is the strongest form of "the read did not work".
    main.setStoreForTest(null);
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);

    var alice: [32]u8 = undefined;
    @memset(&alice, 0xa1);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.writeFollowForTest(&fx, alice, true));
    try testing.expect(main.pendingFollowCountForTest() == null);

    // A key minted in this app has provably never had a list, which is the one
    // case where reading nothing IS the answer.
    main.setIdentityMintedForTest(true);
    try testing.expect(main.writeFollowForTest(&fx, alice, true));
}

test "the follow splice matches on the p tag, not on any tag carrying that value" {
    // Amethyst's unfollow filters on tag[1] == pubkey without checking tag[0],
    // so it silently deletes an unrelated tag that happens to carry the same
    // value, and drops short tags like the ["-"] protected marker entirely.
    // Not copying that.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{108} ** 32);
    main.setIdentityForTest([_]u8{108} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/splice.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const victim = "cc" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", victim },
        // A different tag type carrying the same value, and a one-element tag.
        &.{ "e", victim },
        &.{"-"},
    };
    const existing = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, existing, signer);

    var target: [32]u8 = undefined;
    @memset(&target, 0xcc);
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.writeFollowForTest(&fx, target, false));

    const kinds = [_]u16{3};
    const authors = [_][32]u8{kp.public_key};
    var result = try store.query(arena, .{ .authors = &authors, .kinds = &kinds, .limit = 1 });
    defer result.deinit();
    var saw_e = false;
    var saw_short = false;
    var saw_p_victim = false;
    for (result.events[0].tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "e")) saw_e = true;
        if (tag.len == 1 and std.mem.eql(u8, tag[0], "-")) saw_short = true;
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "p") and std.mem.eql(u8, tag[1], victim)) saw_p_victim = true;
    }
    // The person is gone; the unrelated tag and the short marker are not.
    try testing.expect(!saw_p_victim);
    try testing.expect(saw_e);
    try testing.expect(saw_short);
}

test "a profile is a level of the back stack, not a layer over it" {
    // The SDK tracks at most 8 virtual windows per build, an OCCLUDED level
    // still registers one, and Plaza is already at the cap: feed + 6 stacked +
    // current. A profile that layered on top of a full thread stack would be a
    // ninth window, silently dropped in a release build. Sharing the depth
    // budget is what makes that impossible rather than merely unlikely.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5a);

    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(?[32]u8, who), model.viewing_profile);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // Opening a note from a profile pushes the profile, so Back returns to it.
    var note = threadNote(0xAB, 100, 0);
    note.id = 77;
    main.enterThreadForTest(&model, note);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
    try testing.expect(model.thread_stack[0].isProfile());
    try testing.expectEqual(@as(i64, 77), model.viewing_thread);
    try testing.expect(model.viewing_profile == null);

    // Back lands on the person, not the feed.
    main.closeThreadForTest(&model);
    try testing.expectEqual(@as(?[32]u8, who), model.viewing_profile);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // And Back again lands on the feed.
    main.closeThreadForTest(&model);
    try testing.expect(model.viewing_profile == null);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
}

test "the profile's tabs mean exactly what they say" {
    // Notes is what they wrote; Replies is what they wrote at somebody. A tab
    // that mixed them would be a tab that lies about what it holds.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5b);
    model.viewing_profile = who;

    model.thread_notes[0] = threadNote(0x01, 100, 0); // a note
    model.thread_notes[1] = threadNote(0x02, 90, 0xAA); // a reply
    model.thread_notes[2] = threadNote(0x03, 80, 0); // a note
    // Somebody else's note, sharing the buffer the way a stacked level does.
    model.thread_notes[3] = threadNote(0x04, 70, 0);
    var other: [32]u8 = undefined;
    @memset(&other, 0x99);
    model.thread_notes[3].pubkey = other;
    model.thread_notes_len = 4;
    for (0..3) |i| model.thread_notes[i].pubkey = who;

    var buf: [8]usize = undefined;
    model.profile_tab = .notes;
    const notes = model.profileNotesFor(&buf, who);
    try testing.expectEqual(@as(usize, 2), notes.len);

    model.profile_tab = .replies;
    var buf2: [8]usize = undefined;
    const replies = model.profileNotesFor(&buf2, who);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(@as(usize, 1), replies[0]);

    // The stranger's row belongs to neither tab of THIS person.
    model.profile_tab = .notes;
    var buf3: [8]usize = undefined;
    const mine = model.profileNotesFor(&buf3, who);
    for (mine) |i| try testing.expect(!std.mem.eql(u8, &model.thread_notes[i].pubkey, &other));
}

test "a profile screen renders the person and their notes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5c);
    model.viewing_profile = who;
    model.thread_notes[0] = threadNote(0x01, 100, 0);
    model.thread_notes_len = 1;

    const tree = try buildTree(arena, &model);
    // Back, the tabs, and the counts row are all there.
    try testing.expect(findAnyText(tree.root, "Notes") != null);
    try testing.expect(findAnyText(tree.root, "Replies") != null);
    // The follow count is unknown for a stranger with no contact list in the
    // store, and the screen says so rather than printing a confident zero.
    try testing.expect(findAnyText(tree.root, "Their follow list has not arrived yet") != null);
}

test "a number this app cannot know is not printed" {
    // FOLLOWERS is not computable from a local store: nothing here can know who
    // follows somebody. The design asks for the number; the honest answer is to
    // leave it out rather than state a figure the reader would believe.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearIdentityForTest();
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x5d);
    model.viewing_profile = who;

    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "followers") == null);
}

test "a press on a profile's own note row resolves" {
    // `noteById` searched `thread_notes` only while a THREAD was open, so every
    // per-note action on a profile (open it, like it, expand its picture) was a
    // press that looked live and did nothing.
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x71);
    model.viewing_profile = who;
    model.thread_notes[0] = threadNote(0x01, 100, 0);
    model.thread_notes[0].id = 4242;
    model.thread_notes[0].pubkey = who;
    model.thread_notes_len = 1;

    try testing.expect(model.noteById(4242) != null);
    try testing.expect(model.noteById(9999) == null);
}

test "opening the person already open does not stack a second copy of them" {
    var model = main.initialModel();
    model.stage = .ready;
    var who: [32]u8 = undefined;
    @memset(&who, 0x72);

    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);
    // Pressing a face on their own page is the reachable way to do this.
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);

    // A different person still pushes.
    var other: [32]u8 = undefined;
    @memset(&other, 0x73);
    main.enterProfileForTest(&model, other);
    try testing.expectEqual(@as(usize, 1), model.thread_stack_len);
}

test "nobody is told they follow the starter pack" {
    // The pack is what the app reads on a new account's behalf, not a list they
    // chose, and nothing is ever published to say otherwise. Telling a reader
    // they follow nine strangers offered them "Unfollow" on each, and pressing
    // it did nothing at all, because the write path correctly refuses to remove
    // somebody who is not on a list. Two questions, two answers.
    main.clearIdentityForTest();
    main.forgetFollowsForTest();
    const packed_in = main.followSetForTest()[0];
    try testing.expect(!main.isFollowedByMe(packed_in));
    try testing.expect(!main.isInReadGraph(packed_in));

    // Signed in with no list of their own: the pack IS what they read, so the
    // thread's ranking and the inbox still treat those authors as inside the
    // graph. They are still not followed, and the controls must not say so.
    main.setIdentityForTest([_]u8{0x74} ** 32);
    defer main.clearIdentityForTest();
    try testing.expect(main.isInReadGraph(packed_in));
    try testing.expect(!main.isFollowedByMe(packed_in));
}

test "the follow count counts people, not tags" {
    // Some clients emit the same person twice. This file already has a function
    // that knows that; the profile's count has to use it or it prints a number
    // nobody else shows.
    const tags = [_]nostr.event.Tag{
        &.{ "p", "11" ** 32 },
        &.{ "p", "22" ** 32 },
        &.{ "p", "11" ** 32 },
        &.{ "t", "not-a-person" },
    };
    try testing.expectEqual(@as(usize, 2), main.countPeopleForTest(&tags));
}

fn inboxEvent(kind: u16, author: u8, tags: []const nostr.event.Tag, created_at: i64) nostr.event.Event {
    return inboxEventBy(kind, [_]u8{author} ** 32, tags, created_at);
}

fn inboxEventBy(kind: u16, author: [32]u8, tags: []const nostr.event.Tag, created_at: i64) nostr.event.Event {
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

test "somebody who turns up in your notifications gets a name fetched" {
    // The profile round asks for kind:0 for three sets: the people the reader
    // follows, the people a note mentions, and the reader themself. Somebody who
    // replies to you, likes you or zaps you is in none of those, and nothing else
    // ever asked. So the notifications page listed raw npubs for exactly the
    // people it is about, which is the one screen where the name IS the row.
    main.setIdentityForTest([_]u8{0xb8} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();
    main.forgetWantedProfilesForTest();
    defer main.forgetWantedProfilesForTest();

    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};

    // A stranger replies to the reader. Nobody has ever asked who they are.
    const stranger = [_]u8{0xb9} ** 32;
    try testing.expect(!main.profileWantedForTest(stranger));

    var ev = inboxEvent(1, 0xb9, &mine, 1_800_000_000);
    ev.pubkey = stranger;
    try testing.expect(main.inboxAddForTest(ev, 1_800_000_000));

    // Filing the notification is what arms the question.
    try testing.expect(main.profileWantedForTest(stranger));
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

/// Fills the inbox with `n` mentions of the reader from distinct authors.
fn seedInbox(n: usize, first_byte: u8, base_time: i64) void {
    const me = main.activePubkeyForTest().?;
    var me_hex: [64]u8 = undefined;
    for (me, 0..) |b, i| _ = std.fmt.bufPrint(me_hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    const mine = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    for (0..n) |i| {
        const who: u8 = first_byte +% @as(u8, @intCast(i % 200));
        var ev = inboxEvent(1, who, &mine, base_time + @as(i64, @intCast(i)));
        // Distinct ids, so the dedupe does not swallow them.
        ev.id[0] = who;
        ev.id[1] = @intCast(i % 256);
        _ = main.inboxAddForTest(ev, base_time + 100_000);
    }
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

test "a press closes the sheet even when it cannot go anywhere" {
    // Every route out of the sheet has an early return in front of it: a store
    // miss for a note nobody fetched, an identity check for a person already on
    // screen. Closing on ARRIVAL therefore left the sheet up in exactly the cases
    // where the reader has least idea why nothing moved.
    main.setIdentityForTest([_]u8{0xED} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetInboxForTest();

    // A note the store has never heard of.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        var fx: main.EffectsForTest = undefined;
        main.update(&model, .{ .open_event = [_]u8{0x5E} ** 32 }, &fx);
        try testing.expect(!model.notifications_open);
        // And it says something, rather than swallowing the press.
        try testing.expect(model.toast_until != 0);
    }

    // The person whose page is already open.
    {
        var model = main.initialModel();
        model.stage = .ready;
        const alice = [_]u8{0x6F} ** 32;
        var fx: main.EffectsForTest = undefined;
        main.update(&model, .{ .open_person = alice }, &fx);
        model.notifications_open = true;
        main.update(&model, .{ .open_person = alice }, &fx);
        try testing.expect(!model.notifications_open);
    }
}

test "a keyboard shortcut fired under the sheet does not arm something invisible" {
    // These are declared shortcuts, so the shell delivers them whatever is on
    // screen, and the sheet is drawn above both destinations.
    main.setIdentityForTest([_]u8{0xEE} ** 32);
    defer main.clearIdentityForTest();

    var fx: main.EffectsForTest = undefined;
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        main.update(&model, .open_compose, &fx);
        // Otherwise the composer arms itself unseen and appears on its own the
        // moment the sheet is dismissed.
        try testing.expect(!model.notifications_open);
        try testing.expect(model.composing);
    }
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.notifications_open = true;
        main.update(&model, .open_settings, &fx);
        try testing.expect(!model.notifications_open);
        try testing.expect(model.stage == .settings);
    }
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

test "walking somewhere from the sheet closes the sheet" {
    main.setIdentityForTest([_]u8{0xE7} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetInboxForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = [_]u8{0x44} ** 32 }, &fx);
    // Otherwise the person opens UNDERNEATH a sheet still covering the screen,
    // and the press reads as having done nothing at all.
    try testing.expect(!model.notifications_open);
    try testing.expect(model.viewing_profile != null);
}

test "the notifications page draws its rows in the reading column" {
    // This replaces a test that asserted the rows sat inside a modal card. There
    // is no card: notifications is an opaque level now, like threads, profiles,
    // settings and the composer, because a scrim repaints the whole window every
    // frame and the cost grows with it.
    //
    // What still matters is that a row lands in the column and not spread across
    // a wide window, so the same note is the same width wherever it is shown.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x2f} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.notifications_open = true;
    main.seedInboxUnreadForTest(6);

    const tree = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);
    var widest: f32 = 0;
    for (tree.layout.nodes) |n| {
        if (n.widget.kind != .data_row) continue;
        widest = @max(widest, n.widget.frame.width);
    }
    try testing.expect(widest > 0);
    // The column, not the window. A row wider than the column means the centring
    // row collapsed and every notification is running the full width.
    try testing.expect(widest <= main.notifications_column_width_for_test + 1);
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

// ------------------------------------------------------- NIP-89 the client tag

test "a note says nothing about what wrote it unless the reader asks" {
    // OFF by default, which is the choice Sepehr made and NIP-89 hints at: the
    // tag is a small permanent fact about the reader attached to everything they
    // write, and it follows the note to every relay forever.
    const gpa = testing.allocator;
    main.setClientTag(false);
    defer main.setClientTag(false);

    const base = [_]nostr.event.Tag{&.{ "e", "ab" ** 32 }};
    {
        const out = main.withClientTag(gpa, 1, &base);
        try testing.expectEqual(@as(usize, 1), out.len);
    }

    main.setClientTag(true);
    // A note, and a repost of one: the things the reader actually wrote.
    for ([_]u16{ 1, 6 }) |kind| {
        const out = main.withClientTag(gpa, kind, &base);
        defer {
            gpa.free(out[out.len - 1]);
            gpa.free(out);
        }
        try testing.expectEqual(@as(usize, 2), out.len);
        try testing.expectEqualStrings("client", out[1][0]);
        try testing.expectEqualStrings("Plaza", out[1][1]);
    }
    // Machinery is not writing. A reaction and a deletion carry nothing: they
    // would broadcast the same fact more widely for nothing the reader can see,
    // which is the opposite of what an opt-in privacy switch is for.
    for ([_]u16{ 7, 5, 3, 0 }) |kind| {
        const out = main.withClientTag(gpa, kind, &base);
        try testing.expectEqual(@as(usize, 1), out.len);
    }
}

test "what a stranger's note claims about its client is treated as foreign text" {
    const cases = [_]struct { value: []const u8, shown: ?[]const u8 }{
        .{ .value = "Plaza", .shown = "Plaza" },
        .{ .value = "  Amethyst  ", .shown = "Amethyst" },
        // Too long for the row is CUT, not thrown away: the name is still
        // evidence about the note, and refusing it outright discarded the whole
        // fact. Fourteen characters.
        .{ .value = "x" ** 40, .shown = "x" ** 14 },
        // And cut by CHARACTER, not by byte. A byte cap is about eight
        // characters of Japanese and twenty-four of English, so it refused a
        // legitimate name in one script and accepted a far wider one in another.
        .{ .value = "クライアントの名前がとても長い", .shown = "クライアントの名前がとても長" },
        // A newline in a meta row is how a row stops looking like a row.
        .{ .value = "Damus\nHACKED", .shown = null },
        .{ .value = "", .shown = null },
        .{ .value = "   ", .shown = null },
    };
    for (cases) |c| {
        const ev = nostr.event.Event{
            .id = [_]u8{0} ** 32,
            .pubkey = [_]u8{0} ** 32,
            .created_at = 1_800_000_000,
            .kind = 1,
            .tags = &.{&.{ "client", c.value }},
            .content = "hi",
            .sig = [_]u8{0} ** 64,
        };
        if (c.shown) |want| {
            try testing.expectEqualStrings(want, main.clientOf(ev) orelse return error.NothingShown);
        } else {
            try testing.expect(main.clientOf(ev) == null);
        }
    }
    // A note with no tag at all draws nothing, never "via unknown": what a note
    // does not say is not a fact about it.
    const bare = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "hi",
        .sig = [_]u8{0} ** 64,
    };
    try testing.expect(main.clientOf(bare) == null);
}

test "the feed draws via without spending a node on it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    const plain = nostr.event.Event{
        .id = [_]u8{0xC1} ** 32,
        .pubkey = [_]u8{0x51} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "no client tag here",
        .sig = [_]u8{0} ** 64,
    };
    var tagged = plain;
    tagged.id = [_]u8{0xC2} ** 32;
    tagged.tags = &.{&.{ "client", "Amethyst" }};
    tagged.content = "written elsewhere";

    model.notes[0] = main.noteFrom(plain, 1_800_000_000);
    model.notes[1] = main.noteFrom(tagged, 1_800_000_000);
    model.notes_len = 2;

    const before = try buildTree(arena, &model);
    const nodes_with = countNodes(before.root);
    try testing.expect(findAnyTextContaining(before.root, "via Amethyst"));
    // The note that says nothing gets no "via" of its own.
    try testing.expect(!findAnyTextContaining(before.root, "via Plaza"));

    // And the row costs the same either way: the name rides as a second SPAN of
    // the paragraph the time already occupies, not as a node beside it. A feed
    // row is priced against a per-view ceiling that refuses the whole screen.
    model.notes[1] = main.noteFrom(plain, 1_800_000_000);
    model.notes[1].id = 999;
    const after = try buildTree(arena, &model);
    try testing.expectEqual(nodes_with, countNodes(after.root));
}

test "nothing that calls itself a button is dead" {
    // The recurring failure in this app is not a broken control, it is a control
    // that LOOKS live and does nothing: a badge saying "W" while filters still
    // went out, a textarea that renders and accepts no keys, a Repost verb drawn
    // beside a working Like. Each was found by hand, late, and only after it had
    // been reviewed and snapshot-checked. So the invariant is stated once here:
    // if a widget announces itself to the reader as a button, something has to
    // happen when it is pressed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();
    main.resetInboxForTest();
    defer main.resetInboxForTest();

    // Every screen the app can be on, including the ones layered over others.
    const Screen = struct { name: []const u8, prepare: *const fn (*main.Model) void };
    const screens = [_]Screen{
        .{ .name = "feed", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
            }
        }.f },
        .{ .name = "thread", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.viewing_thread = 1;
                m.thread_root = threadNote(0xAA, 100, 0);
                m.thread_root.id = 1;
            }
        }.f },
        .{ .name = "profile", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.viewing_profile = [_]u8{0x33} ** 32;
            }
        }.f },
        .{ .name = "settings", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .settings;
            }
        }.f },
        .{ .name = "compose", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.composing = true;
            }
        }.f },
        .{
            .name = "note menu",
            .prepare = struct {
                fn f(m: *main.Model) void {
                    m.stage = .ready;
                    m.viewing_thread = 1;
                    m.thread_root = threadNote(0xAA, 100, 0);
                    m.thread_root.id = 1;
                    // The state the first version of this test could not reach, and
                    // where its invariant was already false.
                    m.note_menu = m.thread_root.id;
                }
            }.f,
        },
        .{ .name = "notifications", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.notifications_open = true;
            }
        }.f },
        .{ .name = "onboarding", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .onboarding;
            }
        }.f },
        // The first-intent sheet and what follows it, which nothing covered until
        // now. Note what this guard can and cannot see: for a hand-built row the
        // SDK advertises `press` only BECAUSE `on_press` was set, which is the
        // same condition that registers the handler, so deleting `.on_press` from
        // `joinCard` makes all three rungs inert AND invisible to this walk. That
        // is what "the ladder's three rungs are wired" below is for.
        .{ .name = "join sheet", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
            }
        }.f },
        .{ .name = "join sheet with a waiting verb", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
                m.pending = .{ .like = 7 };
            }
        }.f },
        .{ .name = "bunker card", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.joining = true;
                m.bunker_mode = true;
            }
        }.f },
        .{ .name = "name card", .prepare = struct {
            fn f(m: *main.Model) void {
                m.stage = .ready;
                m.naming = true;
            }
        }.f },
    };

    for (screens) |screen| {
        var per_screen = std.heap.ArenaAllocator.init(testing.allocator);
        defer per_screen.deinit();
        var model = main.initialModel();
        screen.prepare(&model);
        const tree = try buildTree(per_screen.allocator(), &model);
        var dead: usize = 0;
        countDeadButtons(tree, tree.root, &dead);
        if (dead != 0) {
            std.debug.print("{s}: {d} widget(s) announce a button role with nothing behind them\n", .{ screen.name, dead });
            return error.DeadControl;
        }
    }
}

/// Counts widgets that announce a button role but carry no handler of any kind.
fn countDeadButtons(tree: AppUi.Tree, widget: canvas.Widget, out: *usize) void {
    // Ask the SDK what this widget ADVERTISES, never what the app happened to
    // declare. `semanticActions` is the same function the platform bridge calls
    // to build the accessibility node, so it is the actual promise made to the
    // reader: it folds in the widget's KIND (a `ui.button` announces a press
    // without the app writing `.role = .button` anywhere), and it returns nothing
    // at all for a disabled widget, which is how an unavailable control says so
    // honestly.
    //
    // The first version of this guard read `widget.semantics.role` instead. Plaza
    // declares that role almost nowhere, because the kinds already imply it, so
    // the guard inspected a fraction of the controls it claimed to cover and
    // matched zero checkboxes in an app with two.
    const advertised = canvas.semanticActions(widget);
    if (advertised.press or advertised.toggle) {
        var wired = false;
        for (tree.handlers) |h| {
            if (h.id == widget.id) wired = true;
        }
        if (!wired) {
            out.* += 1;
            std.debug.print("  DEAD: label='{s}' kind={s} role={s}\n", .{ widget.semantics.label, @tagName(widget.kind), @tagName(widget.semantics.role) });
        }
    }
    for (widget.children) |child| countDeadButtons(tree, child, out);
}

test "the client-tag switch is wired, and flipping it sticks" {
    // The automation harness cannot drive a `.checkbox`: its snapshot advertises
    // `actions=[focus,toggle]` and `widget-action ... toggle` reports "delivered"
    // while nothing moves. That is true of the media-previews checkbox this one
    // sits beside, so it is the harness, not this switch. It does mean the switch
    // cannot be proven by driving the real app, which is exactly the case where a
    // control quietly turns out to be wired to nothing. So it is proven here
    // instead: the widget carries a toggle handler, and the message behind it
    // changes what gets published.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setClientTag(false);
    defer main.setClientTag(false);

    var model = main.initialModel();
    model.stage = .settings;
    const tree = try buildTree(arena, &model);

    const box = findByLabel(tree.root, "Say notes were written in Plaza") orelse return error.SwitchMissing;
    var wired = false;
    for (tree.handlers) |h| {
        if (h.id == box.id and h.event == .toggle) wired = true;
    }
    try testing.expect(wired);

    // And the message behind it does what the label says.
    var fx: main.EffectsForTest = undefined;
    try testing.expect(!main.clientTag());
    main.update(&model, .client_tag_toggle, &fx);
    try testing.expect(main.clientTag());

    // Which is visible in what a note would carry.
    const base = [_]nostr.event.Tag{&.{ "e", "ab" ** 32 }};
    const out = main.withClientTag(testing.allocator, 1, &base);
    defer {
        testing.allocator.free(out[out.len - 1]);
        testing.allocator.free(out);
    }
    try testing.expectEqual(@as(usize, 2), out.len);

    main.update(&model, .client_tag_toggle, &fx);
    try testing.expect(!main.clientTag());
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

test "what a guest reached for is remembered, whatever the verb was" {
    // The app carried two ad-hoc pending fields, a bool for the composer and an
    // id for a like. Every verb added after them either grew a third or quietly
    // remembered nothing: pressing Follow as a guest opened the sheet, signed you
    // in, and dropped the follow, and a guest could type a whole reply and press
    // send to no effect at all.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: main.EffectsForTest = undefined;
    main.clearIdentityForTest();

    const alice = [_]u8{0x4A} ** 32;

    // Reaching for the composer.
    {
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, .open_compose, &fx);
        try testing.expect(model.joining);
        try testing.expect(model.pending == .post);
        try testing.expect(!model.composing);
    }

    // Reaching for a like.
    {
        var model = main.initialModel();
        model.stage = .ready;
        main.update(&model, .{ .like = 77 }, &fx);
        try testing.expect(model.joining);
        try testing.expectEqual(@as(i64, 77), model.pending.like);
    }

    // Reaching for Follow on somebody's page. This one used to remember nothing.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.viewing_profile = alice;
        main.update(&model, .{ .follow_person = 1 }, &fx);
        try testing.expect(model.joining);
        try testing.expectEqualSlices(u8, &alice, &model.pending.follow);
    }

    // Reaching for Reply. This one was gated nowhere: the press reached a signer
    // that does not exist and returned, doing and saying nothing.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.viewing_thread = 42;
        main.update(&model, .reply_submit, &fx);
        try testing.expect(model.joining);
        try testing.expectEqual(@as(i64, 42), model.pending.reply);
    }

    // And the sheet says which one it is waiting on, in the reader's terms.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        model.pending = .post;
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your note is waiting.") != null);
        model.pending = .{ .reply = 42 };
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your reply is waiting.") != null);
        model.pending = .{ .follow = alice };
        try testing.expect(findAnyTextContaining((try buildTree(arena, &model)).root, "is waiting."));
    }
}

test "closing the join sheet is an answer, so the verb is dropped" {
    // Otherwise the thing they declined lies in wait and fires at whatever later
    // sign-in they make for some other reason entirely.
    var fx: main.EffectsForTest = undefined;
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    main.update(&model, .open_compose, &fx);
    try testing.expect(model.pending.waiting());

    main.update(&model, .close_join, &fx);
    try testing.expect(!model.joining);
    try testing.expect(!model.pending.waiting());
}

test "a remembered follow is never written over a contact list nobody has read" {
    // The follow-safety rule outranks the convenience: this publishes a
    // replaceable list, and completing a remembered intent is exactly the moment
    // it would be tempting to skip the check, because the reader asked for it
    // minutes ago and is not watching.
    var fx: main.EffectsForTest = undefined;
    main.setIdentityForTest([_]u8{0x5B} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.pending = .{ .follow = [_]u8{0x4A} ** 32 };
    main.drivePendingIntentForTest(&model, &fx);

    // Spent either way, so it cannot retry on every tick for the rest of the
    // session, and the reader is told rather than left to guess.
    try testing.expect(!model.pending.waiting());
    try testing.expect(model.toast_until != 0);
}

test "only the ceremony's own report opens the name beat" {
    // The first version of this asked a 90-second TIMER whether an appearing key
    // was freshly minted. That is a different question from the one that matters,
    // and the gap was reachable: press Create, have it fail, then import a real
    // account inside the window. Plaza offered "Want a name on it?" over an
    // account that already had a name, and publishing that name rewrote its
    // kind:0 from an empty local profile.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    const body = "{\"pubkey\":\"" ++ "5b" ** 32 ++ "\",\"state\":\"ready\"}";

    // The window said it minted a key.
    {
        main.setCeremonyForTest(.created);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(model.naming);
    }

    // A ceremony is open but has said nothing yet. Sign in; do NOT assume.
    {
        main.clearIdentityForTest();
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(!model.naming);
        try testing.expect(main.ceremonyOwesNameForTest());
    }

    // No ceremony at all: an import, a terminal, a restored daemon.
    {
        main.clearIdentityForTest();
        main.setCeremonyForTest(.none);
        var model = main.initialModel();
        model.stage = .onboarding;
        main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
        try testing.expect(main.activePubkeyForTest() != null);
        try testing.expect(!model.naming);
    }
}

test "a ceremony that did not mint arms nothing" {
    // Every way out of that window except a mint: a failure, a cancel, a crash,
    // and a spawn that never ran because one was already open.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);

    for ([_]native_sdk.EffectExit{
        .{ .key = 0, .reason = .exited, .code = 0 },
        .{ .key = 0, .reason = .exited, .code = 1 },
        .{ .key = 0, .reason = .signaled, .code = 0 },
        .{ .key = 0, .reason = .rejected, .code = 0 },
    }) |exit| {
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, exit);
        try testing.expect(!model.naming);
        // And it must not claim the key has no history: that flag is what lets a
        // contact list be published without reading one back first.
        try testing.expect(!main.identityMintedForTest());
    }

    // A rejected spawn is a press that did nothing, so the reader is told.
    {
        main.setCeremonyForTest(.running);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
        try testing.expect(model.toast_until != 0);
    }
}

test "a mint confirmed after the poll still gets its name beat" {
    // The window holds its result until the reader dismisses it and Plaza polls
    // every second, so the key is all but always adopted BEFORE the window
    // exits. The beat is owed until the report arrives, and paid when it does.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    main.setCeremonyForTest(.running);
    const body = "{\"pubkey\":\"" ++ "6c" ** 32 ++ "\",\"state\":\"ready\"}";

    var model = main.initialModel();
    model.stage = .onboarding;
    main.handleHelperPubkeyForTest(&model, .{ .key = 0, .outcome = .ok, .status = 200, .body = body });
    try testing.expect(!model.naming);

    main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .exited, .code = 9 });
    try testing.expect(model.naming);
    try testing.expect(main.identityMintedForTest());
}

test "a key that was never made never claims to have no history" {
    // canWriteFollows() lets a contact list be published WITHOUT reading one back
    // when the key was minted here, because a key with no history cannot have a
    // list to destroy. Setting that on the button press rather than on a
    // confirmed mint made the claim false: press Create, have the ceremony fail,
    // import an account with eight hundred follows, and the remembered follow
    // replays into a kind:3 holding the starter pack and nothing else.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();
    var fx: main.EffectsForTest = undefined;
    main.setIdentityMintedForTest(false);
    // With the daemon parked as unreachable the queued create stays queued, so
    // this exercises the Msg arm without needing an effects layer.
    main.setHelperUnreachableForTest();
    defer main.setHelperUnreachableForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    main.update(&model, .join_create, &fx);
    try testing.expect(!main.identityMintedForTest());

    // And choosing the other rung disclaims it outright.
    main.setIdentityMintedForTest(true);
    main.setCeremonyForTest(.running);
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(!main.identityMintedForTest());
}

test "the ladder offers three ways in and the way back out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    const tree = try buildTree(arena, &model);

    // Each rung says what it is AND what it costs, because "Bring your key" on
    // its own does not tell a reader that the key goes somewhere other than this
    // window, which is the single most important fact on this sheet.
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    try testing.expect(findAnyText(tree.root, "Ready in seconds. Nothing to write down.") != null);
    try testing.expect(findAnyText(tree.root, "Bring your key") != null);
    try testing.expect(findAnyTextContaining(tree.root, "Plaza itself never sees it."));
    try testing.expect(findAnyText(tree.root, "Use your own signer") != null);
    try testing.expect(findAnyText(tree.root, "Keep browsing") != null);
}

test "the sheet names the verb it interrupted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // No verb, no pill: a reader who opened this from the rail is not owed an
    // explanation of something they did not do.
    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        try testing.expect(!findAnyTextContaining((try buildTree(arena, &model)).root, "is waiting."));
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        model.pending = .post;
        try testing.expect(findAnyText((try buildTree(arena, &model)).root, "Your note is waiting.") != null);
    }
}

test "a display name cannot push the pill out of the sheet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // The name in that sentence is a stranger's kind:0 field, so it has no length
    // and no alphabet. The pill does not wrap, so an unclipped one walks out of
    // the card and off the window.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    const who = [_]u8{0x2C} ** 32;
    const prof = main.upsertProfile(who).?;
    main.parseMetadataInto(prof, "{\"display_name\":\"" ++ "wide" ** 40 ++ "\"}");

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.pending = .{ .follow = who };
    const tree = try buildTree(arena, &model);
    const line = findAnyTextContainingText(tree.root, "is waiting.") orelse return error.NoPill;
    try testing.expect(line.len < 60);
}

test "the sheets' recommended actions actually paint" {
    // Twice in one sitting a control was built as a `.list_item` carrying a
    // background, which paints nothing: the white "Create your identity" card and
    // the white "Done" both rendered as dim text on the sheet's own dark surface.
    // The widget tree was correct both times, so every structural assertion in
    // this file passed. Only a pixel can tell the difference.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        const p = try painted.Painted.render(arena, &model);
        const fill = p.fillAtCenterOf("Create your identity") orelse return error.NoCreateCard;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.naming = true;
        const p = try painted.Painted.render(arena, &model);
        const fill = p.fillAtCenterOf("Done") orelse return error.NoDoneButton;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }
}

/// Whether the widget carrying this accessibility label has a handler behind it.
///
/// The dead-control guard walks the tree asking what each widget ADVERTISES, which
/// catches a `ui.button` or a `.checkbox` whose handler went missing. It cannot
/// catch a hand-built row losing its `on_press`: for a plain row the SDK derives
/// the advertised press FROM `on_press`, so removing it removes the advertisement
/// too and the widget stops being a button the guard is looking for. Naming the
/// control is the only way to assert it still exists AND still does something.
fn pressableByLabel(tree: AppUi.Tree, widget: canvas.Widget, label: []const u8) bool {
    if (std.mem.eql(u8, widget.semantics.label, label)) {
        for (tree.handlers) |h| {
            if (h.id == widget.id) return true;
        }
    }
    for (widget.children) |child| {
        if (pressableByLabel(tree, child, label)) return true;
    }
    return false;
}

/// The message behind the press on the widget carrying this accessibility label.
///
/// `pressableByLabel` asks whether SOMETHING is wired there. This asks what, which
/// is the difference between "the seat still works" and "the seat still goes where
/// it is supposed to".
fn pressMsgByLabel(tree: AppUi.Tree, label: []const u8) ?Msg {
    const w = findByLabel(tree.root, label) orelse return null;
    for (tree.handlers) |h| {
        if (h.id != w.id or h.event != .press) continue;
        return switch (h.action) {
            .message => |m| m,
            else => null,
        };
    }
    return null;
}

test "the rail's own seat opens your page, not your preferences" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A guest has no page to open, so the seat asks who they are. Unchanged.
    main.clearIdentityForTest();
    {
        var model = main.initialModel();
        model.stage = .ready;
        const tree = try buildTree(arena, &model);
        const msg = pressMsgByLabel(tree, "You") orelse return error.SeatHasNoPress;
        switch (msg) {
            .open_join => {},
            else => return error.GuestSeatGoesSomewhereElse,
        }
    }

    main.setIdentityForTest([_]u8{0x5A} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const msg = pressMsgByLabel(tree, "You") orelse return error.SeatHasNoPress;
    switch (msg) {
        .open_person => |pk| try testing.expectEqualSlices(u8, &me, &pk),
        else => return error.SeatGoesSomewhereElse,
    }

    // The page it opens has to KNOW whose it is. Carrying the right thirty-two
    // bytes is not the same thing as landing on a screen that reads as yours,
    // and the screen is the part a reader sees.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, msg, &fx);
    try testing.expectEqualSlices(u8, &me, &(model.viewing_profile orelse return error.NoProfile));
    const page = try buildTree(arena, &model);
    try testing.expect(findAnyText(page.root, "This is you") != null);
    // And offers no Follow. Following yourself writes your own contact list for
    // no reason, which is the one thing this app is most careful with.
    try testing.expect(findAnyText(page.root, "Follow") == null);
}

/// How many widgets in the tree carry exactly this text.
fn countAnyText(widget: canvas.Widget, text: []const u8) usize {
    var n: usize = if (std.mem.eql(u8, widget.text, text)) 1 else 0;
    for (widget.children) |child| n += countAnyText(child, text);
    return n;
}

test "a page with no name on it says the npub once" {
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.setIdentityForTest([_]u8{0x6C} ** 32);
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const who = [_]u8{0x2B} ** 32;
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = who }, &fx);

    // The header band names whoever the page is about, which 11b asks for and
    // which is not the duplication at issue. So the band is the one legitimate
    // occurrence, and the question is whether the CARD says it again underneath
    // its own name line.
    const short = main.npubShortForTest(arena, who);
    try testing.expect(short.len > 0);

    // No kind:0, so `personName` hands back the short npub for the name line.
    // The npub row must then stand down: band + name line is two, and the row
    // would make three, the same string stacked on itself.
    const nameless = try buildTree(arena, &model);
    const said = countAnyText(nameless.root, short);
    if (said != 2) {
        std.debug.print("nameless page prints \"{s}\" {d} times, want 2 (band + name line)\n", .{ short, said });
        return error.SaidTwice;
    }

    // Given a name, the two lines carry different strings and both belong: the
    // band and the name line say "Grace", the row says the npub, once.
    const prof = main.upsertProfile(who).?;
    main.parseMetadataInto(prof, "{\"display_name\":\"Grace\"}");
    const named = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 2), countAnyText(named.root, "Grace"));
    try testing.expectEqual(@as(usize, 1), countAnyText(named.root, short));
}

test "a suppressed npub does not shove the line beside it out of true" {
    // The npub row stands down for a nameless person. If it stands down by
    // becoming a zero-width spacer, the row's gap is still charged for it and
    // "follows you" lands 8px inside the left rule that the name, bio, links and
    // counts all share. `handleLine` documents that trap for the note row; this
    // is the profile card walking into it.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.setIdentityForTest([_]u8{0x4D} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/follows.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // Somebody with a contact list naming me and NO kind:0 at all. A real state,
    // not a contrived one: the two arrive as separate events, and a profile that
    // only ever set a picture never gets a name.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x51} ** 32);
    var me_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&me_hex, "{x}", .{&me}) catch unreachable;
    const tags = [_]nostr.event.Tag{&.{ "p", &me_hex }};
    const contacts = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, contacts);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .{ .open_person = kp.public_key }, &fx);

    const p = try painted.Painted.render(arena, &model);
    const follows = frameOfText(p, "follows you") orelse return error.NoFollowsLine;
    // The npub appears twice: the header band centres it, and the card's name
    // line carries it. The card's is the lower one, and it is the left rule that
    // matters here.
    const short = main.npubShortForTest(arena, kp.public_key);
    var name: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.text, short)) continue;
        if (name == null or node.widget.frame.y > name.?.y) name = node.widget.frame;
    }
    const name_line = name orelse return error.NoNameLine;
    // Same left rule, to within a hair of rounding.
    if (@abs(follows.x - name_line.x) > 1.0) {
        std.debug.print("\"follows you\" starts at x={d}, the name line at x={d}\n", .{ follows.x, name_line.x });
        return error.OutOfTrue;
    }
}

test "your own page is written for you, not about you" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x5A} ** 32);
    defer main.clearIdentityForTest();
    const me = main.activePubkeyForTest() orelse return error.NoIdentity;

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // Your own page, freshly minted: no notes, no contact list read yet. This is
    // the exact state a reader who just pressed "Create your identity" arrives in,
    // and it is entirely made of the sentences that used to say "they".
    main.update(&model, .{ .open_person = me }, &fx);
    const mine = try buildTree(arena, &model);
    if (findAnyTextContainingText(mine.root, "they have written")) |s| {
        std.debug.print("own page talks about the reader in the third person: \"{s}\"\n", .{s});
        return error.WrongPerson;
    }
    try testing.expect(findAnyTextContainingText(mine.root, "you have written") != null);
    try testing.expect(findAnyText(mine.root, "Your follow list has not arrived yet") != null);

    // The line above is the LOADING one, and it is the only empty-tab string a
    // freshly opened profile can reach: `enterProfile` sets `thread_loading` from
    // an empty note count, and with no store it never clears. Settling it reaches
    // the other two, which otherwise sit behind an assertion that cannot see them
    // and could each be reverted to "they" with the suite still green.
    model.thread_loading = false;
    for ([_]struct { tab: @TypeOf(model.profile_tab), want: []const u8 }{
        .{ .tab = .notes, .want = "Nothing you have written is here yet." },
        .{ .tab = .replies, .want = "Nothing you have written at anyone is here yet." },
    }) |c| {
        model.profile_tab = c.tab;
        const settled = try buildTree(arena, &model);
        if (findAnyText(settled.root, c.want) == null) {
            std.debug.print("own page is missing \"{s}\"\n", .{c.want});
            return error.WrongPerson;
        }
        try testing.expect(findAnyTextContainingText(settled.root, "they have written") == null);
    }
    model.profile_tab = .notes;

    // A stranger's page is unchanged: it is about somebody else, and saying "you"
    // there would be the same mistake pointed the other way.
    main.update(&model, .{ .open_person = [_]u8{0x33} ** 32 }, &fx);
    const theirs = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(theirs.root, "they have written") != null);
    try testing.expect(findAnyText(theirs.root, "Their follow list has not arrived yet") != null);
    try testing.expect(findAnyTextContainingText(theirs.root, "you have written") == null);
}

test "every way into the app is wired, by name" {
    // Deleting `.on_press` from joinCard leaves three inert rectangles that still
    // say button, still focus, still paint, and still hold every string the other
    // tests assert on. The whole suite passed with the ladder dead.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.joining = true;
        const tree = try buildTree(arena, &model);
        for ([_][]const u8{ "Create your identity", "Bring your key", "Use your own signer", "Keep browsing" }) |label| {
            if (!pressableByLabel(tree, tree.root, label)) {
                std.debug.print("join sheet: \"{s}\" is not pressable\n", .{label});
                return error.DeadControl;
            }
        }
    }

    {
        var model = main.initialModel();
        model.stage = .ready;
        model.naming = true;
        const tree = try buildTree(arena, &model);
        for ([_][]const u8{ "Done", "Skip" }) |label| {
            if (!pressableByLabel(tree, tree.root, label)) {
                std.debug.print("name card: \"{s}\" is not pressable\n", .{label});
                return error.DeadControl;
            }
        }
    }
}

test "a keyholder that is not there is reported missing, not formatted into a path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    var out: [1024]u8 = undefined;
    // Nothing beside us yet. Formatting a path is not finding a binary, and the
    // version of this that only formatted is what shipped a bundle with no
    // keyholder in it: the app spawned a file that was not there, said so on
    // stderr, and carried on believing it had a daemon.
    try testing.expectEqual(@as(usize, 0), main.resolveSiblingForTest(std.testing.io, &out, dir, "plaza-signer"));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plaza-signer", .data = "not really a binary" });
    const n = main.resolveSiblingForTest(std.testing.io, &out, dir, "plaza-signer");
    var want_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&want_buf, "{s}/plaza-signer", .{dir}),
        out[0..n],
    );
}

test "with no keyholder the create rung says why and stops being a button" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    const tree = try buildTree(arena, &model);

    // Still named, so the reader is not left hunting for where creating an
    // identity went. Just not a button, and not a promise: "every way into the
    // app is wired, by name" asserts the opposite of this on the same label, and
    // between them they pin both states.
    try testing.expect(findAnyText(tree.root, "Create your identity") != null);
    try testing.expectEqual(@as(?Msg, null), pressMsgByLabel(tree, "Create your identity"));
    try testing.expect(findAnyText(tree.root, "Not possible in this copy of Plaza.") != null);
    try testing.expect(findAnyText(tree.root, "Ready in seconds. Nothing to write down.") == null);
    // And the reason sits under the card, where a wrapping line has room to be
    // three lines long. `the ladder's rungs hold their own copy` is what keeps
    // it from drifting back INTO the card, where it paints outside the border.
    try testing.expect(findAnyTextContaining(tree.root, "is missing from this install"));

    // The two rungs that still work are untouched, and bringing a key gives up
    // its Notary promise, because with no daemon the paste lands in this
    // process. Copy that sells isolation over a field that does not have it is
    // the lie this app can least afford.
    try testing.expect(pressableByLabel(tree, tree.root, "Bring your key"));
    try testing.expect(pressableByLabel(tree, tree.root, "Use your own signer"));
    try testing.expect(findAnyText(tree.root, "Goes into Notary. Plaza itself never sees it.") == null);
    try testing.expect(findAnyText(tree.root, "Pasted here, and kept on this device.") != null);
}

test "with no keyholder nothing queues a mint that can never fire" {
    main.clearIdentityForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    try testing.expect(!main.helperSetupQueuedForTest());

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .join_create, &fx);

    // `queueHelperSetup` parks an intent until the daemon answers, and a daemon
    // that is not installed never answers. Without the guard in `beginCreate`
    // this sits queued for the life of the process while the sheet closes over
    // it, which is a press swallowed whole.
    try testing.expect(!main.helperSetupQueuedForTest());
}

test "with no keyholder a pasted key goes to the field, not to a window that cannot take it" {
    main.clearIdentityForTest();
    defer main.setNotaryWindowFoundForTest(false);

    // The window is only the right destination when there is something behind
    // it. Three of these four are the in-Plaza field.
    main.setNotaryWindowFoundForTest(true);
    main.setKeyholderMissingForTest(false);
    try testing.expect(main.ceremonyCanTakeKeyForTest());
    main.setKeyholderMissingForTest(true);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.setNotaryWindowFoundForTest(false);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());
    main.setKeyholderMissingForTest(false);
    try testing.expect(!main.ceremonyCanTakeKeyForTest());

    // And the branch that reads it lands somewhere the reader can actually
    // finish: window present, keyholder absent, so the paste goes to the field.
    main.setNotaryWindowFoundForTest(true);
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, .open_notary_import, &fx);
    try testing.expect(model.stage == .onboarding);
}

/// Every line of text INSIDE one of the join ladder's rungs has to end inside it.
///
/// A rung's subtitle is a wrapped paragraph in a column the surrounding row has
/// already been sized against, so a subtitle long enough to take a third line
/// runs past the card's own bottom edge and paints the last line half outside
/// it. Nothing about the widget tree changes when that happens: the string is
/// all present, in one node, correctly nested under the card, and every
/// structural assertion in this file passed while it was rendering clipped. Only
/// the laid-out frames say so, which is why this is a geometric assertion and
/// why it runs over BOTH states of the ladder rather than the one that happened
/// to be long.
///
/// "Inside" is ANCESTRY, walked through `parent_index`, and not a box test. The
/// first version of this asked whether a text node's frame fell within a rung's
/// frame, which is a different question with the same answer most of the time:
/// the join ladder is a sheet stacked OVER the feed, so a feed line behind it
/// can sit squarely inside a rung's box while belonging to something else
/// entirely. Making the window taller was enough to move one there.
fn expectRungsHoldTheirCopy(p: painted.Painted) !void {
    for ([_][]const u8{ "Create your identity", "Bring your key", "Use your own signer" }) |label| {
        var rung_index: ?usize = null;
        for (p.layout.nodes, 0..) |node, i| {
            if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
            rung_index = i;
            break;
        }
        const rung_i = rung_index orelse {
            std.debug.print("join ladder: no rung labelled \"{s}\"\n", .{label});
            return error.NoRung;
        };
        const rung = p.layout.nodes[rung_i].widget.frame;
        const floor = rung.y + rung.height;
        for (p.layout.nodes, 0..) |node, i| {
            const w = node.widget;
            if (w.kind != .text or w.text.len == 0) continue;
            if (!isDescendantOf(p, i, rung_i)) continue;
            if (w.frame.y + w.frame.height > floor + 0.5) {
                std.debug.print(
                    "join ladder: \"{s}\" runs {d:.1}px past the bottom of the \"{s}\" rung\n",
                    .{ w.text, w.frame.y + w.frame.height - floor, label },
                );
                return error.CopyOverflowsItsRung;
            }
        }
    }
}

/// Whether layout node `i` sits under node `ancestor`, following the parent
/// links the layout records rather than comparing rectangles.
fn isDescendantOf(p: painted.Painted, i: usize, ancestor: usize) bool {
    var cursor = p.layout.nodes[i].parent_index;
    var hops: usize = 0;
    while (cursor) |parent| : (hops += 1) {
        if (parent == ancestor) return true;
        if (hops > 64) return false;
        cursor = p.layout.nodes[parent].parent_index;
    }
    return false;
}

test "the ladder's rungs hold their own copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    try expectRungsHoldTheirCopy(try painted.Painted.render(arena_state.allocator(), &model));

    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    try expectRungsHoldTheirCopy(try painted.Painted.render(arena_state.allocator(), &model));
}

test "the fallback welcome screen stops selling a key it cannot make" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // This screen is where a broken install sends "Bring your key", so it is the
    // one a reader with no keyholder actually lands on. Its text is compiled
    // markup and cannot be swapped node-for-node, so the two lines that would
    // otherwise argue with the greyed button are bindings.
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    var model = main.initialModel();
    model.stage = .onboarding;
    const tree = try buildTree(arena, &model);

    const create = findByText(tree.root, .button, "Create your identity") orelse return error.NoCreateButton;
    try testing.expect(create.state.disabled);
    try testing.expect(findAnyTextContaining(tree.root, "is missing from this install"));
    try testing.expect(findAnyTextContaining(tree.root, "Sign in with a key you already have"));
    try testing.expect(!findAnyTextContaining(tree.root, "A second to set up"));
    try testing.expect(!findAnyTextContaining(tree.root, "Create an identity and Plaza sets you up"));

    // And with a keyholder it is the screen it has always been.
    main.setKeyholderMissingForTest(false);
    const whole = try buildTree(arena, &model);
    const live = findByText(whole.root, .button, "Create your identity") orelse return error.NoCreateButton;
    try testing.expect(!live.state.disabled);
    try testing.expect(findAnyTextContaining(whole.root, "A second to set up"));
    try testing.expect(findAnyTextContaining(whole.root, "Create an identity and Plaza sets you up"));
    try testing.expect(!findAnyTextContaining(whole.root, "is missing from this install"));
}

test "the executable's own directory is where the probe looks" {
    // The half of the resolver that `resolveSibling`'s test cannot reach. If
    // this ever returns null, or a relative path, or a directory Plaza was not
    // launched from, `resolveHelper` declares a missing keyholder on an install
    // that is perfectly fine and the app tells the reader to reinstall it. That
    // is the failure mode of trusting argv[0], which is what this replaced, so
    // the replacement is worth pinning.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = main.exeDirForTest(std.testing.io, &buf) orelse return error.NoExecutableDir;
    try testing.expect(dir.len > 0);
    try testing.expectEqual(@as(u8, '/'), dir[0]);
    // And it is a directory that exists, so formatting a sibling onto it and
    // asking whether that file is there is a question with a real answer.
    var probe: [std.fs.max_path_bytes + 64]u8 = undefined;
    try testing.expectEqual(
        @as(usize, 0),
        main.resolveSiblingForTest(std.testing.io, &probe, dir, "a-binary-plaza-does-not-ship"),
    );
    try std.Io.Dir.cwd().access(std.testing.io, dir, .{});
}

test "the dead rung stops looking like it works" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;

    // Normally it is THE recommendation: the one accent-filled rung on the
    // ladder, a button, a focus stop.
    {
        const tree = try buildTree(arena_state.allocator(), &model);
        const w = findByLabel(tree.root, "Create your identity") orelse return error.NoRung;
        try testing.expectEqual(canvas.WidgetRole.button, w.semantics.role);
        try testing.expect(w.semantics.focusable);
        const p = try painted.Painted.render(arena_state.allocator(), &model);
        const fill = p.fillAtCenterOf("Create your identity") orelse return error.RungPaintsNothing;
        try testing.expect(painted.sameColor(fill, theme.palette.accent));
    }

    // With no keyholder it must not merely stop working. A rung that still
    // wears the accent and still says button, while doing nothing, is worse
    // than one that plainly cannot: the reader presses it, twice, and concludes
    // the app is broken rather than the install. Press-and-text assertions
    // cannot see any of this, which is why the paint is sampled.
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);
    const tree = try buildTree(arena_state.allocator(), &model);
    const w = findByLabel(tree.root, "Create your identity") orelse return error.NoRung;
    try testing.expectEqual(canvas.WidgetRole.text, w.semantics.role);
    try testing.expect(!w.semantics.focusable);
    const p = try painted.Painted.render(arena_state.allocator(), &model);
    if (p.fillAtCenterOf("Create your identity")) |fill| {
        try testing.expect(!painted.sameColor(fill, theme.palette.accent));
    }
}

test "a restored Notary session on an install with no Notary says so, and does not say starting" {
    // The reader this is for signed in on a working install and updated into a
    // broken one: `restoreSession` runs BEFORE the probe, so they are signed
    // straight back in and the status bar is the only thing that can tell them.
    // "Notary starting" is what an unwritten health state reads as, and it is a
    // word that means wait a moment about a condition that never resolves.
    main.setIdentityForTest([_]u8{0x3C} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindHelperForTest();
    main.setKeyholderMissingForTest(true);
    defer main.setKeyholderMissingForTest(false);

    try testing.expect(!main.signerIsHealthy());
    try testing.expectEqualStrings("Notary is not installed", main.signerStatusLabelForTest());
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

test "a note the queue had no room for is said out loud" {
    // `g_outbox_overflow` was set here and read nowhere, so the one case it
    // exists for, a note written to this machine and offered to nobody, was the
    // one case the status bar stayed silent about. That is the promise under the
    // offline banner broken exactly where it matters.
    var model = main.initialModel();
    model.outbox_pending = 0;
    model.outbox_stuck = 0;
    model.outbox_overflowed = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a note could not be queued", model.outbox_label(arena));

    // And it outranks the others: a queue that is both busy and overflowing has
    // one thing worth saying.
    model.outbox_pending = 3;
    try testing.expectEqualStrings("a note could not be queued", model.outbox_label(arena));

    // It also has to REACH the bar. The zone returns a spacer when it thinks
    // there is nothing to report, and overflow used to count as nothing.
    model.stage = .ready;
    model.outbox_pending = 0;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyText(tree.root, "a note could not be queued") != null);
}

test "a relay that kept its seat keeps its connection" {
    // Signing out reads `0/5 relays` forever, on a pool where nothing is wrong.
    //
    // The status table is written by the ingest threads, and each of them spends
    // almost all of its life parked in a blocking read. Clearing a slot's status
    // from the UI thread is therefore not a value that goes stale and refreshes:
    // it is a value nothing will ever put back, because the thread only looks up
    // when its relay speaks, and a quiet relay does not. So a pool reset that
    // wiped every row left the bar reading nothing-is-connected over five live
    // sockets.
    main.resetRelaysToBootstrapForTest();
    const total = main.relayCount();
    try testing.expect(total >= 2);

    // Every relay reporting in, the way the threads do once dialed.
    for (0..total) |i| main.setRelayStatusForTest(i, true);
    try testing.expectEqual(total, main.liveRelayCountForTest());

    // A sign-out resets the pool to the bootstrap list. It ALREADY is the
    // bootstrap list, so not one seat changes hands and not one socket is
    // touched. The count has to survive that.
    main.resetRelaysToBootstrapForTest();
    try testing.expectEqual(total, main.liveRelayCountForTest());
    try testing.expectEqual(total, main.relayCount());

    // And the rule still holds where it should. Adopting the reader's own
    // kind:10002 puts DIFFERENT relays in those seats, so every row recorded
    // against them is about the previous occupant and has to go: a status left
    // at connected would count a socket that was never opened.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://mine-one.example.com" },
        &.{ "r", "wss://mine-two.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.setIdentityForTest([_]u8{9} ** 32);
    defer main.clearIdentityForTest();
    main.resetRelaysForTest();
    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://mine-one.example.com", main.relayUrlAt(0));
    var live_after: usize = 0;
    for (0..main.relaySlots()) |i| {
        if (main.relayStatusConnectedForTest(i)) live_after += 1;
    }
    try testing.expectEqual(@as(usize, 0), live_after);

    main.resetRelaysToBootstrapForTest();
}

test "only the seats that changed hands lose their row" {
    // The discrimination itself, which neither half of the test above reaches:
    // one of them changes NO seat and the other changes EVERY seat, so an
    // all-or-nothing rule would satisfy both. This pool changes some and keeps
    // others, in the same swap.
    main.setIdentityForTest([_]u8{0x51} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.resetRelaysForTest();

    const kept_0 = main.relayUrlAt(0);
    const kept_2 = main.relayUrlAt(2);
    try testing.expect(kept_0.len > 0 and kept_2.len > 0);

    // Everybody reporting in.
    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);

    // Their published list keeps seats 0 and 2 exactly as they are, puts a
    // different relay in seat 1, and empties the rest.
    const tags = [_]nostr.event.Tag{
        &.{ "r", kept_0 },
        &.{ "r", "wss://swapped-in.example.com" },
        &.{ "r", kept_2 },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x51} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());

    // Seats 0 and 2 kept their relay, so they kept their connection. Seat 1
    // changed hands and seats 3 and 4 emptied, so those rows are gone. A rule
    // that cleared everything gives 0 here; a rule that cleared nothing gives 5.
    try testing.expect(main.relayStatusConnectedForTest(0));
    try testing.expect(!main.relayStatusConnectedForTest(1));
    try testing.expect(main.relayStatusConnectedForTest(2));
    try testing.expect(!main.relayStatusConnectedForTest(3));
    try testing.expect(!main.relayStatusConnectedForTest(4));
}

test "signing out drops the rows of the relays it is signing out of" {
    // The KEEP half of the sign-out path is covered above, by a pool that is
    // already the bootstrap list. This is the other half on the same path, and
    // it is the one the whole guard could be deleted from while the suite
    // stayed green: an account with a list of its OWN signs out, every seat
    // changes hands, and every row has to go with them.
    main.setIdentityForTest([_]u8{0x52} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.resetRelaysForTest();

    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://only-mine-one.example.com" },
        &.{ "r", "wss://only-mine-two.example.com" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0x52} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    main.stageOwnRelayListForTest(ev);
    try testing.expect(main.adoptRelayListForTest());
    try testing.expectEqualStrings("wss://only-mine-one.example.com", main.relayUrlAt(0));

    for (0..main.relayCount()) |i| main.setRelayStatusForTest(i, true);
    try testing.expectEqual(main.relayCount(), main.liveRelayCountForTest());

    // Sign out. Not one of those relays is in the bootstrap list, so not one
    // seat keeps its occupant, and the bar must not report a single live
    // connection to relays this reader no longer talks to.
    main.resetRelaysToBootstrapForTest();
    try testing.expectEqual(@as(usize, 0), main.liveRelayCountForTest());
}

/// Every widget that can be pressed has to occupy room on screen.
///
/// A control laid out at zero width is not merely invisible. Its siblings are
/// positioned after it as though it were not there, so the next thing in the row
/// is drawn on top of whatever the control painted outside its own box. That is
/// what turned the thread header into one smear of "Starter pack", "Thread" and
/// the reply count in the same place, and what left the bunker card's way back
/// looking like a stray mark next to its own title.
///
/// Nothing structural can see it. The tree is correctly nested either way, and
/// mouse input works either way, because a press hit-tests to the deepest widget
/// and walks UP to the nearest ancestor claiming one. Only a laid-out frame says
/// so, which is why this measures.
fn expectNoZeroSizedPressables(arena: std.mem.Allocator, name: []const u8, m: *main.Model) !void {
    const tree = try buildTree(arena, m);
    const p = try painted.Painted.render(arena, m);
    for (p.layout.nodes) |n| {
        const w = n.widget;
        if (w.frame.width > 0.5 and w.frame.height > 0.5) continue;
        var pressable = false;
        for (tree.handlers) |h| {
            if (h.id == w.id and h.event == .press) pressable = true;
        }
        if (!pressable) continue;
        std.debug.print(
            "{s}: a pressable {s} labelled \"{s}\" is laid out at {d:.1}x{d:.1}\n",
            .{ name, @tagName(w.kind), w.semantics.label, w.frame.width, w.frame.height },
        );
        return error.ZeroSizedControl;
    }
}

test "no control that can be pressed is laid out at nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // One model walked through the screens, because a Model is far too large to
    // hold several of on the stack.
    var m = main.initialModel();
    m.stage = .ready;
    try expectNoZeroSizedPressables(arena, "feed", &m);

    m.viewing_thread = 12345;
    try expectNoZeroSizedPressables(arena, "thread", &m);
    m.viewing_thread = 0;

    m.joining = true;
    try expectNoZeroSizedPressables(arena, "join ladder", &m);
    m.bunker_mode = true;
    try expectNoZeroSizedPressables(arena, "bunker card", &m);
    m.joining = false;
    m.bunker_mode = false;

    m.naming = true;
    try expectNoZeroSizedPressables(arena, "name card", &m);
    m.naming = false;

    m.notifications_open = true;
    try expectNoZeroSizedPressables(arena, "notifications", &m);
    m.notifications_open = false;

    m.viewing_profile = [_]u8{0x2B} ** 32;
    try expectNoZeroSizedPressables(arena, "profile", &m);
    m.viewing_profile = null;

    m.stage = .settings;
    try expectNoZeroSizedPressables(arena, "settings", &m);
    m.stage = .onboarding;
    try expectNoZeroSizedPressables(arena, "welcome", &m);
}

test "a header's back control does not sit under the title" {
    // The consequence, stated as geometry: the thread header's three pieces are
    // laid out one after another, not on top of each other. Before the back
    // control took up room, "Thread" began at the back control's own x plus the
    // row gap, i.e. inside the chevron and across the label.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    main.clearIdentityForTest();

    var m = main.initialModel();
    m.stage = .ready;
    m.viewing_thread = 12345;
    const p = try painted.Painted.render(arena_state.allocator(), &m);

    const back = p.frameOf("Back") orelse return error.NoBackControl;
    try testing.expect(back.width > 0);

    const title = frameOfText(p, "Thread") orelse return error.NoTitle;
    // The title starts after the back control ends. Anything less and they are
    // painting over one another.
    try testing.expect(title.x >= back.x + back.width);
}

test "the mark in the rail goes home" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    // It looked like the app's own button in the corner of the rail and did
    // nothing at all when pressed, which is the one thing a mark in that
    // position must never do.
    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const msg = pressMsgByLabel(tree, "Home") orelse return error.MarkHasNoPress;
    switch (msg) {
        .go_home => {},
        else => return error.MarkGoesSomewhereElse,
    }

    // And it is a destination, not a step back: from a person opened from a
    // thread opened from the feed, one press lands on the feed, not one level up.
    //
    // The stack is built with `enterThreadForTest`, NOT by dispatching
    // `.open_thread`. That message looks the note up in the model first and
    // returns when it is not there, so a made-up id leaves the stack empty and
    // this whole test passes against a one-level Back. Which it did.
    var fx: main.EffectsForTest = undefined;
    var root = main.Note{};
    root.id = 0xAA;
    main.enterThreadForTest(&model, root);
    try testing.expectEqual(@as(i64, 0xAA), model.viewing_thread);
    main.update(&model, .{ .open_person = [_]u8{0x2B} ** 32 }, &fx);
    try testing.expect(model.viewing_profile != null);
    // Two levels deep: the thread is on the stack under the person.
    try testing.expect(model.thread_stack_len > 0);

    main.update(&model, .go_home, &fx);
    try testing.expect(model.viewing_profile == null);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqual(@as(usize, 0), model.thread_stack_len);
    try testing.expect(model.stage == .ready);

    // Settings is a screen too, and Home leaves it.
    main.update(&model, .open_settings, &fx);
    main.update(&model, .go_home, &fx);
    try testing.expect(model.stage == .ready);

    // But a question the app has ASKED is not dismissed by navigating: the
    // remembered intent behind it would go with it.
    model.joining = true;
    main.update(&model, .go_home, &fx);
    try testing.expect(model.joining);
}

test "the relay chip is text on the bar, and says nothing about latency" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();
    main.resetRelaysForTest();

    // A live round trip on record, which is what used to be printed here. The
    // popover only shows a ping for a relay it believes is connected, so the
    // status goes with it.
    main.recordRelayRttForTest(0, 337);
    main.setRelayStatusForTest(0, true);
    defer main.clearRelayRttForTest(0);
    defer main.setRelayStatusForTest(0, false);

    var model = main.initialModel();
    model.stage = .ready;
    model.live_relays = main.relayCount();
    model.relay_count = main.relayCount();
    const tree = try buildTree(arena, &model);

    // The count, and only the count. A round-trip figure that swings with
    // whichever relay answered last is a number nobody acts on, and it sat where
    // the reader looks to find out whether the pool is up.
    try testing.expect(findAnyText(tree.root, ui_fmt_pool(arena, main.relayCount())) != null);
    try testing.expect(!findAnyTextContaining(tree.root, "337 ms"));

    // The per-relay pings are still in the card the chip opens, beside the relay
    // each one belongs to, which is the only place the number means anything.
    // The popover writes it tight ("337ms") and Settings spaced ("337 ms"), so
    // both are asked for by their own spelling rather than a shared substring.
    model.menu = .relays;
    const open = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(open.root, "337ms"));

    // And no plate behind it. The dot already carries the pool's health, so the
    // surface was a second voice saying the same thing.
    // Unconditional: `fillAtCenterOf` returns null when nothing paints there,
    // which is the answer this assertion wants, so wrapping it in `if` let the
    // whole check pass by finding nothing at all.
    const p = try painted.Painted.render(arena, &model);
    try testing.expect(p.frameOf("Relays") != null);
    if (p.fillAtCenterOf("Relays")) |fill| {
        try testing.expect(!painted.sameColor(fill, theme.palette.surface_chip));
    }
}

test "the pool the app is born with holds no retired relay" {
    // relay.nostr.band was retired, and a bootstrap list is the one place a dead
    // relay costs every first run a connection attempt that can never succeed.
    // Written as a rule over the list rather than an assertion about one name,
    // so the next one that goes is caught by the same line.
    main.resetRelaysForTest();
    const retired = [_][]const u8{"nostr.band"};
    for (0..main.relayCount()) |i| {
        const url = main.relayUrlAt(i);
        for (retired) |dead| {
            if (std.mem.indexOf(u8, url, dead) != null) {
                std.debug.print("bootstrap pool still carries {s}\n", .{url});
                return error.RetiredRelayInBootstrap;
            }
        }
    }
    try testing.expect(main.relayCount() >= 3);
}

test "the window is square" {
    // A feed is a column of rows. The wide-and-short default spent its extra
    // width on margin while showing four notes at a time.
    try testing.expectEqual(main.window_width, main.window_height);
}

test "there is always something under a name" {
    // The identity block is pinned to the avatar's height, so an empty second
    // line is not restraint: it is a hole in the row that reads as a rendering
    // bug. It was empty for anyone with no NIP-05 and no username distinct from
    // their display name, which is a great many people.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const Case = struct { secret: u8, meta: []const u8, want: []const u8, violet: bool };
    const cases = [_]Case{
        // A NIP-05 is shown WHOLE. The domain is the half that says who vouched
        // for the name, so dropping it threw away the part worth showing.
        .{ .secret = 0x11, .meta = "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}", .want = "dergigi@primal.net", .violet = true },
        // The root form is the domain alone: `_@fiatjaf.com` is `fiatjaf.com`.
        .{ .secret = 0x12, .meta = "{\"display_name\":\"fiatjaf\",\"nip05\":\"_@fiatjaf.com\"}", .want = "fiatjaf.com", .violet = true },
        // No NIP-05: the username, muted, because violet has to keep meaning
        // attested somewhere.
        .{ .secret = 0x13, .meta = "{\"display_name\":\"Satoshi\",\"name\":\"nakamoto\"}", .want = "@nakamoto", .violet = false },
        // A username that only echoes the name above it is not a handle, so the
        // website stands in, as its host.
        .{ .secret = 0x14, .meta = "{\"display_name\":\"jack\",\"name\":\"jack\",\"website\":\"https://www.cash.app/about\"}", .want = "cash.app", .violet = false },
        // Nothing but a display name: the npub, which is the last honest handle
        // and the case that used to render as a void.
        .{ .secret = 0x15, .meta = "{\"display_name\":\"Anonymous\"}", .want = "", .violet = false },
        // ORDER. Every row above reaches its rung by the ones before it being
        // absent, which pins no precedence at all: a ladder that tried the
        // website first would satisfy all of them. These two carry more than one
        // rung's worth of data and say which wins.
        .{
            .secret = 0x17,
            .meta = "{\"display_name\":\"Gigi\",\"name\":\"gigi\",\"website\":\"https://dergigi.com\",\"nip05\":\"dergigi@primal.net\"}",
            .want = "dergigi@primal.net",
            .violet = true,
        },
        .{
            .secret = 0x18,
            .meta = "{\"display_name\":\"Somebody\",\"name\":\"someone\",\"website\":\"https://example.com\"}",
            .want = "@someone",
            .violet = false,
        },
        // A website that is not a web address never reaches the line. kind:0 is
        // a stranger's JSON and this string is rendered under their name.
        .{
            .secret = 0x19,
            .meta = "{\"display_name\":\"Trickster\",\"website\":\"javascript:alert(1)\"}",
            .want = "",
            .violet = false,
        },
    };

    for (cases) |c| {
        const kp = try signer.keyPairFromSecretKey([_]u8{c.secret} ** 32);
        const p = main.upsertProfile(kp.public_key).?;
        main.parseMetadataInto(p, c.meta);
        const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
        const note = main.noteFrom(ev, 1_800_000_000);
        const got = note.handleLabel(arena);

        if (c.want.len > 0) {
            try testing.expectEqualStrings(c.want, got.text);
        } else {
            // The npub case: whatever the exact string, it must be the npub and
            // it must not be empty.
            try testing.expect(got.text.len > 0);
            try testing.expect(std.mem.startsWith(u8, got.text, "npub1"));
        }
        try testing.expectEqual(c.violet, got.nip05);
    }

    // And the one case where saying nothing is right: a stranger with no kind:0
    // at all already has the short npub on the NAME line, so repeating it
    // underneath would be the same string twice.
    const stranger = try signer.keyPairFromSecretKey([_]u8{0x16} ** 32);
    const ev = try signedNote(arena, signer, stranger, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);
    try testing.expect(std.mem.startsWith(u8, note.author(), "npub1"));
    try testing.expectEqualStrings("", note.handleLabel(arena).text);
}

test "an npub is shortened one way, everywhere" {
    // There were two rules, twelve characters on the feed's name line and ten
    // everywhere else, so the same key rendered as two different strings
    // depending on which line it landed on. Anything comparing them to avoid
    // repeating a handle compared unequal and printed it twice, in two
    // spellings, which is worse than the duplication it was avoiding.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x2F} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);

    // The name line falls back to the npub, and the shortener every other
    // surface uses has to produce the same characters.
    try testing.expectEqualStrings(note.author(), main.npubShortForTest(arena, kp.public_key));
}

test "one identity, one spelling, on the same screen" {
    // `handleLabel` shows the whole NIP-05 and `Note.handle` shows `@local`.
    // Both are fine, for different jobs: an identity LINE wants the domain,
    // because that is the half saying who vouched for the name, and naming
    // somebody INLINE in a sentence does not, because a whole address mid
    // sentence reads as an email.
    //
    // What is not fine is both on the same screen for the same person, which is
    // what a nested reply did: the row's line read "dergigi@primal.net" and the
    // reply nested under it read "@dergigi".
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x21} ** 32);
    const p = main.upsertProfile(kp.public_key).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}");

    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
    const note = main.noteFrom(ev, 1_800_000_000);

    // The identity line, wherever it is drawn, is the ladder's answer.
    try testing.expectEqualStrings("dergigi@primal.net", note.handleLabel(arena).text);
    // The inline form stays compact, and stays DIFFERENT on purpose, so this
    // pins the distinction rather than letting the two drift back together.
    try testing.expectEqualStrings("@dergigi", note.handle(arena));
}

test "a website that is not a web address never reaches the line" {
    // kind:0 is a stranger's JSON, and this string is rendered under their name.
    // `picture` has been gated on the scheme since it was added; `website`
    // arrived without the same gate, and `websiteHost` trims only schemes it
    // recognises, so anything else would have been stored and shown whole.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const hostile = [_][]const u8{
        "javascript:alert(1)",
        "data:text/html,<script>x</script>",
        "file:///etc/passwd",
        "not a url at all",
        "//evil.example.com",
    };
    for (hostile, 0..) |bad, i| {
        const kp = try signer.keyPairFromSecretKey([_]u8{@intCast(0x30 + i)} ** 32);
        const p = main.upsertProfile(kp.public_key).?;
        const meta = try std.fmt.allocPrint(arena, "{{\"display_name\":\"X\",\"website\":\"{s}\"}}", .{bad});
        main.parseMetadataInto(p, meta);
        const ev = try signedNote(arena, signer, kp, 1_800_000_000, "hi");
        const note = main.noteFrom(ev, 1_800_000_000);
        const got = note.handleLabel(arena).text;
        // It falls through to the npub rung, which is the honest answer, and
        // never to the string itself.
        try testing.expect(std.mem.indexOf(u8, got, bad) == null);
    }

    // And a real one still gets through, trimmed to its host.
    const ok_kp = try signer.keyPairFromSecretKey([_]u8{0x3F} ** 32);
    const ok_p = main.upsertProfile(ok_kp.public_key).?;
    main.parseMetadataInto(ok_p, "{\"display_name\":\"Y\",\"website\":\"https://www.example.com/a/b?c=d\"}");
    const ok_ev = try signedNote(arena, signer, ok_kp, 1_800_000_000, "hi");
    const ok_note = main.noteFrom(ok_ev, 1_800_000_000);
    try testing.expectEqualStrings("example.com", ok_note.handleLabel(arena).text);
}

test "a nested reply spells its author the same way the row above does" {
    // Both are identity lines, on the same screen, about the same person. One
    // reading "dergigi@primal.net" and the other "@dergigi" is the app spelling
    // one identity two ways inside a single thread.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const author = [_]u8{0x55} ** 32;
    const p = main.upsertProfile(author).?;
    main.parseMetadataInto(p, "{\"display_name\":\"Gigi\",\"nip05\":\"dergigi@primal.net\"}");

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root = threadNote(0xAA, 100, 0);
    model.thread_root.id = 1;
    model.thread_root.pubkey = author;
    model.thread_notes[0] = threadNote(0x10, 200, 0xAA);
    model.thread_notes[0].pubkey = author;
    model.thread_notes[0].id = 10;
    model.thread_notes[1] = threadNote(0x11, 300, 0x10);
    model.thread_notes[1].pubkey = author;
    model.thread_notes[1].id = 11;
    model.thread_notes_len = 2;
    main.arrangeThread(model.thread_notes[0..2], model.thread_root.event_id);
    try testing.expectEqual(@as(u8, 2), model.thread_notes[1].depth);

    // The whole NIP-05 has to be on screen at least twice, once for the reply
    // and once for the reply nested under it, and the compact form nowhere.
    const tree = try buildTree(arena, &model);
    try testing.expect(countAnyText(tree.root, "dergigi@primal.net") >= 2);
    try testing.expect(findAnyText(tree.root, "@dergigi") == null);
}

// ---- P1: a click outside a modal closes it ----------------------------------

/// One modal the app can raise: how to open it, what it is called, what closing
/// it means, and one control inside it that has to keep working.
const ModalCase = struct {
    name: []const u8,
    /// The dialog's accessibility label, which is how the backdrop is found.
    label: []const u8,
    dismiss: Msg,
    /// A control inside the card, by accessibility label. Absorbing the press on
    /// the card is what stops a click there reaching the backdrop, and an
    /// absorber that also swallowed the buttons would satisfy the dismissal rule
    /// perfectly while leaving the sheet impossible to use.
    control: []const u8,
    open: *const fn (*Model) void,
};

const modal_cases = [_]ModalCase{
    .{
        .name = "join",
        .label = "Join",
        .dismiss = .close_join,
        .control = "Keep browsing",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.joining = true;
            }
        }.f,
    },
    .{
        // The same sheet, second step: a distinct card behind the same label, and
        // the one the reader is on while pasting a bunker URL.
        .name = "bunker",
        .label = "Join",
        .dismiss = .close_join,
        .control = "Back",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.joining = true;
                m.bunker_mode = true;
            }
        }.f,
    },
    .{
        .name = "name",
        .label = "Name",
        .dismiss = .name_skip,
        .control = "Skip",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.naming = true;
            }
        }.f,
    },
    .{
        .name = "edit profile",
        .label = "Edit profile",
        .dismiss = .close_profile_edit,
        .control = "Close",
        .open = struct {
            fn f(m: *Model) void {
                m.stage = .settings;
                m.editing_profile = true;
            }
        }.f,
    },
};

/// The node index of the dialog labelled `label`.
fn modalDialogIndex(p: painted.Painted, label: []const u8) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .dialog) continue;
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        return i;
    }
    return null;
}

/// The outermost `.card` inside the dialog at `root`: the modal's own surface,
/// which is the boundary "outside" is measured against.
/// The settings COLUMN: the band the sections are laid out in, centred in the
/// window. Settings is a page rather than a modal now, so there is no dialog to
/// look inside and no card standing in for the content; the column states its
/// own width and that is the thing every settings rule is about.
fn settingsColumn(p: painted.Painted) ?geometry.RectF {
    for (p.layout.nodes) |node| {
        const f = node.widget.frame;
        if (@abs(f.width - main.settings_column_width) > 0.5) continue;
        if (f.height < 200) continue;
        return f;
    }
    return null;
}

fn modalCardIndex(p: painted.Painted, root: usize) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .card) continue;
        if (!isDescendantOf(p, i, root)) continue;
        return i;
    }
    return null;
}

/// A control by the words on it, however it carries them: `ui.button` puts its
/// words in the widget's TEXT, while a hand-built row carries them as an
/// accessibility label. A lookup that knows only one of the two silently misses
/// half the controls in the app, and a miss here reads as "no such control".
fn controlNode(p: painted.Painted, root: usize, name: []const u8) ?canvas.Widget {
    for (p.layout.nodes, 0..) |node, i| {
        const w = node.widget;
        // Scoped to the sheet under test, not the whole window. Two sheets can
        // be on screen at once (edit profile sits over Settings) and both carry
        // a button called "Close"; an unscoped lookup found the one BEHIND the
        // sheet and then asked what a press at its coordinates did, which is a
        // question about the sheet on top.
        if (!isDescendantOf(p, i, root)) continue;
        if (std.mem.eql(u8, w.semantics.label, name) or std.mem.eql(u8, w.text, name)) {
            for (p.tree.handlers) |h| {
                if (h.id == w.id and h.event == .press) return w;
            }
        }
    }
    return null;
}

fn pressMsgById(p: painted.Painted, id: canvas.ObjectId) ?Msg {
    for (p.tree.handlers) |h| {
        if (h.id != id or h.event != .press) continue;
        return switch (h.action) {
            .message => |m| m,
            else => null,
        };
    }
    return null;
}

test "a press outside a modal's card closes it, and a press inside never does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);

        const root = modalDialogIndex(p, c.label) orelse {
            std.debug.print("{s}: no dialog labelled \"{s}\"\n", .{ c.name, c.label });
            return error.NoModalDialog;
        };
        const card_index = modalCardIndex(p, root) orelse {
            std.debug.print("{s}: no card inside the dialog labelled \"{s}\"\n", .{ c.name, c.label });
            return error.NoModalCard;
        };
        const card = p.layout.nodes[card_index].widget.frame;
        // Cards are centred and far narrower than the window, so the band to the
        // left of one is backdrop at every height.
        try testing.expect(card.x > 8);

        // Outside: halfway between the window edge and the card, at three
        // heights, so a rule that happens to hold level with the card's middle
        // is not mistaken for one that holds.
        const outside_x = card.x / 2;
        for ([_]f32{ 0.25, 0.5, 0.75 }) |fraction| {
            const y = main.window_height * fraction;
            const msg = try p.pressMsgAt(outside_x, y) orelse {
                std.debug.print(
                    "{s}: a press at ({d:.0}, {d:.0}), outside the card, dispatches NOTHING\n",
                    .{ c.name, outside_x, y },
                );
                return error.BackdropIsDead;
            };
            try testing.expectEqualStrings(@tagName(c.dismiss), @tagName(msg));
        }

        // Inside: a grid over the whole card, asking where each press LANDS
        // rather than what it dispatches. The rule is that it stops at the card
        // or at something the card contains; what a control inside then does
        // with a press aimed at it is that control's own business, and a modal
        // is allowed to carry a close control of its own (this ladder's "Keep
        // browsing" is one).
        //
        // Stated as containment rather than "is not the dialog" because a card
        // is not always the thing that stops the press: Settings is a scroll
        // filling its card, and a scroll view claims presses on its own. Either
        // answer is correct; escaping the card is not.
        //
        // A grid rather than the centre alone: whether the centre happens to sit
        // on a control is an accident of the layout, and the rule is about every
        // point on the card.
        var landed_inside: usize = 0;
        for (1..8) |ix| {
            for (1..8) |iy| {
                const x = card.x + card.width * (@as(f32, @floatFromInt(ix)) / 8.0);
                const y = card.y + card.height * (@as(f32, @floatFromInt(iy)) / 8.0);
                const target = try p.pressTargetAt(x, y) orelse continue;
                if (target.index != card_index and !isDescendantOf(p, target.index, card_index)) {
                    std.debug.print(
                        "{s}: a press at ({d:.0}, {d:.0}), INSIDE the card, lands on a {s} outside it\n",
                        .{ c.name, x, y, @tagName(target.kind) },
                    );
                    return error.CardFallsThrough;
                }
                landed_inside += 1;
            }
        }
        // And the grid actually sampled something: a card laid out at nothing
        // would satisfy the rule above by never entering the loop body.
        if (landed_inside == 0) {
            std.debug.print("{s}: no sampled point landed anywhere at all\n", .{c.name});
            return error.NothingSampled;
        }

        // And the card still works: the control named for this modal answers to
        // its own message where it is drawn. An absorber that swallowed the
        // buttons too would satisfy every rule above and leave the sheet inert.
        const control = controlNode(p, root, c.control) orelse {
            std.debug.print("{s}: no control called \"{s}\"\n", .{ c.name, c.control });
            return error.NoSuchControl;
        };
        const wired = pressMsgById(p, control.id) orelse {
            std.debug.print("{s}: \"{s}\" has no press bound\n", .{ c.name, c.control });
            return error.ControlNotWired;
        };
        const landed = try p.pressMsgAt(
            control.frame.x + control.frame.width / 2,
            control.frame.y + control.frame.height / 2,
        ) orelse {
            std.debug.print("{s}: a press on \"{s}\" dispatches nothing\n", .{ c.name, c.control });
            return error.ControlSwallowed;
        };
        try testing.expectEqualStrings(@tagName(wired), @tagName(landed));
    }
}

test "the expanded picture closes on a press anywhere it is not a control" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No card here, and that is the point: the viewer fills the window, so
    // "outside the picture" is the whole dark surround and there is nothing to
    // absorb. Neither an image nor plain text claims a press, so every point
    // that is not a button walks up to the viewer itself.
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    const url = "https://example.com/a.jpg";
    @memcpy(model.notes[0].image_url_buf[0..url.len], url);
    model.notes[0].image_url_len = url.len;
    model.notes_len = 1;
    model.expanded_note = 1;

    const p = try painted.Painted.render(arena, &model);
    const viewer = modalDialogIndex(p, "Expanded image") orelse return error.NoViewer;
    const centre = try p.pressMsgAt(main.window_width / 2, main.window_height / 2) orelse
        return error.ViewerBackdropIsDead;
    try testing.expectEqualStrings(@tagName(Msg.close_image), @tagName(centre));

    // The two controls it carries still answer for themselves.
    for ([_][]const u8{ "Close", "Open original" }) |name| {
        const control = controlNode(p, viewer, name) orelse {
            std.debug.print("the viewer has no control called \"{s}\"\n", .{name});
            return error.NoSuchControl;
        };
        const wired = pressMsgById(p, control.id) orelse return error.ControlNotWired;
        const landed = try p.pressMsgAt(
            control.frame.x + control.frame.width / 2,
            control.frame.y + control.frame.height / 2,
        ) orelse {
            std.debug.print("a press on \"{s}\" dispatches nothing\n", .{name});
            return error.ControlSwallowed;
        };
        try testing.expectEqualStrings(@tagName(wired), @tagName(landed));
    }
}

test "a card that absorbs presses states its own surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Binding a press makes the card a HOVER target as well as a press claimer,
    // and the renderer resolves a card's fill through the button state channel:
    // pressed or hovered picks a different surface from the token set. An
    // explicit `style.background` wins outright over that channel
    // (`widgetBackgroundColor` is `style.background orelse fallback`), so a card
    // that states its own colour cannot flash under the pointer, and one that
    // does not will wash grey the moment the reader's cursor crosses it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var checked: usize = 0;
    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);
        for (p.layout.nodes) |node| {
            const w = node.widget;
            if (w.kind != .card) continue;
            var absorbs = false;
            for (p.tree.handlers) |h| {
                if (h.id == w.id and h.event == .press) absorbs = true;
            }
            if (!absorbs) continue;
            checked += 1;
            if (w.style.background == null) {
                std.debug.print("{s}: a pressable card paints no surface of its own\n", .{c.name});
                return error.CardWashesOnHover;
            }
        }
    }
    // One per modal at least, or the loop above proved nothing.
    try testing.expect(checked >= modal_cases.len);
}

// ---- P3: settings is a sheet -------------------------------------------------

/// Settings with everything in it that can be in it: eight relays, six
/// suggestions with hostnames long enough to overrun a row, and a local key.
fn openFullSettings(model: *Model) void {
    main.resetRelaysForTest();
    for (0..main.max_relays_for_test) |r| {
        var url_buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "wss://relay-{d}.a-fairly-long-hostname.example.com", .{r}) catch continue;
        _ = main.addRelayForTest(url, true, true);
    }
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://suggested-one.a-fairly-long-hostname.example.com", "write" },
        &.{ "r", "wss://suggested-two.a-fairly-long-hostname.example.com", "write" },
        // Longer than a row of its own can hold. A relay URL is accepted up to
        // 96 bytes, so this is representable data, not a stunt: without it the
        // shortening below is code no test can tell from its absence.
        &.{ "r", "wss://a-suggested-relay-with-an-absurdly-long-hostname.somewhere.deep.example.com", "write" },
        &.{ "r", "wss://four.example.com", "write" },
        &.{ "r", "wss://five.example.org", "write" },
        &.{ "r", "wss://six.example.net", "write" },
    };
    main.ingestRelayListForTest(.{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{9} ** 32,
        .created_at = 0,
        .kind = 10002,
        .tags = &tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    });
    model.stage = .settings;
    model.reveal_nsec = true;
}

test "a relay edit that will not be published says so on the screen" {
    // The gate is the safe half; this is the honest half. An edit that stays on
    // this device looks exactly like one that went out, and a reader who is
    // never told will believe their relays moved with them to every other
    // client. Asserting the SCREEN, because the model being right about a
    // sentence nobody renders is the failure this repo keeps meeting.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x7a} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(false);
    defer main.setIdentityMintedForTest(false);
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);
    try testing.expect(findAnyTextContaining(p.tree.root, "has not read your published relay list"));

    // And it goes away once there is nothing to warn about: a key minted here
    // has no list to lose, so the edit publishes and the line would be a lie.
    main.setIdentityMintedForTest(true);
    const after = try painted.Painted.render(arena, &model);
    try testing.expect(!findAnyTextContaining(after.tree.root, "has not read your published relay list"));
}

test "the settings sheet paints its own surface the whole way down" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // As a screen, the grey behind the settings column was a panel inside the
    // scroll, and the scroll handed it the VIEWPORT's height: it stopped dead at
    // 760 while the sections ran on to 1253, so scrolling down left the rest of
    // Settings sitting on bare window. The sheet cannot do that, because the
    // scroll is inside the card rather than the card inside the scroll.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    // Down the middle of the window, top to bottom: something has to paint at
    // every height. The original bug was not a wrong colour, it was nothing at
    // all past the fold, and a page can make it exactly as easily as a screen
    // could: the background belongs on the page root, outside the scroll, or it
    // is only as tall as the viewport.
    var y: f32 = 2;
    while (y < main.window_height - 2) : (y += 8) {
        if (p.fillAt(main.window_width / 2, y) == null) {
            std.debug.print("settings paints nothing at y={d:.0}\n", .{y});
            return error.SurfaceStopsShort;
        }
    }

    // And the sections sit in the column the constant names, centred.
    const col = settingsColumn(p) orelse return error.NoSettingsColumn;
    try testing.expect(col.height > 300);
    try testing.expect(col.x > 8);
}

test "no relay suggestion is drawn outside the card that holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rows in this engine never flow-wrap, whatever `wrap` says on them, so a
    // row of chips is exactly as wide as its chips: six suggested relays used to
    // reach x=1372 in a 760 window. They are packed into rows here, and this is
    // the rule that says the packing agrees with the layout.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    const col_frame = settingsColumn(p) orelse return error.NoSettingsColumn;
    // The column, not a card: settings is a page and its sections are several
    // cards, so the band the chips must stay inside is the column itself.
    const sheet = col_frame;

    var seen: usize = 0;
    for (p.layout.nodes) |node| {
        // Found by the message they carry, not by the words on them: a label
        // filter here would silently match nothing the day the wording changes,
        // and a rule that matches nothing passes.
        const msg = pressMsgById(p, node.widget.id) orelse continue;
        if (msg != .relay_suggest) continue;
        const label = node.widget.semantics.label;
        seen += 1;
        const right = node.widget.frame.x + node.widget.frame.width;
        if (right > sheet.x + sheet.width or node.widget.frame.x < sheet.x) {
            std.debug.print(
                "\"{s}\" spans {d:.0}..{d:.0}, the sheet spans {d:.0}..{d:.0}\n",
                .{ label, node.widget.frame.x, right, sheet.x, sheet.x + sheet.width },
            );
            return error.ChipOverflows;
        }
    }
    // Every suggestion the table holds is on screen: packing must not drop one.
    try testing.expectEqual(main.relaySuggestionCount(), seen);
}

test "a settings card's content is as wide as the constant says" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `settings_content_width` is derived from four separate insets, and the
    // chip packing trusts it. If any of them moves and this does not, the chips
    // pack against a width the layout does not give them, which is how the row
    // overflowed in the first place: an arithmetic that nobody checked against
    // a laid-out frame.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    var model = main.initialModel();
    openFullSettings(&model);
    const p = try painted.Painted.render(arena, &model);

    // The relay card is the widest content a settings section holds.
    const row = p.frameOf("Change what wss://relay-0.a-fairly-long-hostname.example.com is for") orelse
        return error.NoRelayRow;
    var widest: f32 = 0;
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .card) continue;
        const f = node.widget.frame;
        // The section card holding that row, found by containment on the y axis.
        if (row.y < f.y or row.y > f.y + f.height) continue;
        // <= the column, not < it: as a page the section cards ARE the column's
        // width, where under the old modal they sat inside it with a margin.
        if (f.width > widest and f.width <= main.settings_column_width_for_test + 0.5) widest = f.width;
    }
    try testing.expect(widest > 0);
    // The card, less its own 12 either side, is what the content gets.
    try testing.expectApproxEqAbs(main.settings_content_width_for_test, widest - 24, 1.0);
}

// ---- P8: the verb row --------------------------------------------------------

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

test "every verb people expect is under a note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Show them all, including the ones with nothing behind them yet: a row
    // missing repost or bookmark reads as a client that lost them, not one that
    // has not written them. None of the unfinished ones takes a press, so
    // nothing here answers a click with silence.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    var found: usize = 0;
    for ([_][]const u8{ "reply", "repeat", "like", "zap", "bookmark", "ellipsis" }) |name| {
        for (p.layout.nodes) |node| {
            // Two channels, because the SDK has two icon builders: `appIcon`
            // puts the name in `Widget.icon` (so a missing app glyph draws the
            // slashed circle rather than spelling itself out), and `icon`, which
            // compile-checks a built-in name, puts it in `text`. A check that
            // knew only one of them would report half the row missing.
            const by_channel = node.widget.icon.len > 0 and std.mem.eql(u8, node.widget.icon, name);
            const by_text = node.widget.kind == .icon and std.mem.eql(u8, node.widget.text, name);
            if (!by_channel and !by_text) continue;
            found += 1;
            break;
        } else {
            std.debug.print("no \"{s}\" under a note\n", .{name});
            return error.MissingVerb;
        }
    }
    try testing.expectEqual(@as(usize, 6), found);
}

// ---- P10: a quoted picture ---------------------------------------------------

test "a link preview stays inside the card, however long the page's description" {
    // The card is a fixed width and its text column used `grow = 1`. `grow`
    // hands out SPARE space and never takes any back, so a child whose natural
    // size already exceeds the row has nothing to grow into and keeps that
    // natural size. A page title and description with `wrap = false` are as wide
    // as the sentence, so the row overflowed the card, the card overflowed the
    // column, and the description ran off the right edge of the WINDOW.
    //
    // The ellipsis did not save it, because an ellipsis needs a box to be too
    // small for, and the leaf was never given one.
    //
    // Measuring the painted geometry, not the options: the bug was invisible in
    // the widget tree, where every node claimed to be an ellipsised single line.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    const url = "https://github.com/zig-nostr/notary/pull/35";
    main.setLinkPreviewForTest(
        url,
        "github.com",
        "Notary is Notary by sepehr-safari, Pull Request #35, zig-nostr/notary",
        "A native remote signer (NIP-46 bunker) for Nostr. Your key stays on a machine you control; every signing request is approved by you, and nothing else ever holds it.",
    );

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest(url);
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);

    // The card, found by ITS OWN semantics rather than by widget kind: the feed
    // is full of list items and the first one is not this. Getting that wrong is
    // how the first version of this test passed with the bug still in place.
    const card = frameOfSemantics(p, "Open link") orelse return error.NoLinkCard;
    const right = card.x + card.width;

    // The two lines that overflowed, found by their content.
    const title = frameOfTextContaining(p, "Pull Request #35") orelse return error.NoTitle;
    const desc = frameOfTextContaining(p, "native remote signer") orelse return error.NoDescription;

    for ([_]struct { name: []const u8, f: native_sdk.geometry.RectF }{
        .{ .name = "title", .f = title },
        .{ .name = "description", .f = desc },
    }) |row| {
        if (row.f.x + row.f.width > right + 0.5) {
            std.debug.print(
                "\nthe {s} runs to {d:.0}; the card ends at {d:.0}\n",
                .{ row.name, row.f.x + row.f.width, right },
            );
        }
        try testing.expect(row.f.x + row.f.width <= right + 0.5);
    }

    // Whether the CARD itself can exceed the window is a separate question from
    // whether its text can exceed the card, and only the second was reported.
}

/// The frame of the first laid-out node carrying this accessibility label.
fn frameOfSemantics(p: painted.Painted, label: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |n| {
        if (std.mem.eql(u8, n.widget.semantics.label, label)) return n.widget.frame;
    }
    return null;
}

/// The frame of the first laid-out node whose text contains `needle`.
fn frameOfTextContaining(p: painted.Painted, needle: []const u8) ?native_sdk.geometry.RectF {
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, needle) != null) return n.widget.frame;
    }
    return null;
}

test "a quoted note that is only a picture says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The fill path cuts the image URL out of the body deliberately (a raw URL
    // is not something to read) and used to record nothing in its place, so a
    // note whose whole content is one picture came out with an empty body and
    // drew a card with a name, a time and a blank line under them.
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{61} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quoted.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const shot = try signedNote(arena, signer, kp, 1_800_000_000, "https://i.nostr.build/aBcD1234.jpg");
    _ = try store.ingest(arena, shot, .{});

    main.dropQuoteForTest(shot.id);
    main.wantQuoteForTest(shot.id);
    main.refreshQuotesForTest(&store);

    const e = main.quoteForTest(shot.id) orelse return error.NoQuote;
    try testing.expectEqual(main.QuoteState.loaded, e.state);
    // The body really is empty: the whole note was the URL, and the URL is cut.
    try testing.expectEqual(@as(u16, 0), e.text_len);
    // So the card has to have something else to say.
    try testing.expectEqualStrings("i.nostr.build", e.image_host_buf[0..e.image_host_len]);
}

test "a quote card with nothing to read is not a blank card" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const quoted_id = [_]u8{0x6f} ** 32;
    main.dropQuoteForTest(quoted_id);
    main.seedQuoteForTest(quoted_id, [_]u8{0x2b} ** 32, 100, "");
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    const host = "i.nostr.build";
    @memcpy(e.image_host_buf[0..host.len], host);
    e.image_host_len = host.len;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    // The card says what it holds, by name and by host.
    if (findAnyText(p.tree.root, "Picture from i.nostr.build") == null) {
        std.debug.print("the quote card says nothing about the picture in it\n", .{});
        return error.SilentAboutMedia;
    }
    // And the row is priced for the line it draws, or a feed of these scrolls
    // against a scrollbar that is measuring a different page.
    //
    // Held to half a line rather than the usual line and a half. That slack
    // exists because every estimate here counts CHARACTERS against a column
    // where the engine measures glyphs and breaks at words; this quote has no
    // characters to disagree about, so the estimate should be exact and the only
    // thing the slack could hide is a line charged for a body that is not there.
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 0.5 * main.body_line_height) {
        std.debug.print("\nrow with a picture chip draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.ChipNotPriced;
    }
}

// ---- P13: a door to the thing holding the key --------------------------------

test "Settings offers a look at Notary, and only when there is one to look at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.setSignerKindForTest("local");
    defer main.setNotaryWindowFoundForTest(false);

    var model = main.initialModel();
    model.stage = .settings;

    // Notary holds the key and the window is installed beside Plaza: the row
    // that says so gets a way to go and look.
    main.setSignerKindForTest("helper");
    main.setNotaryWindowFoundForTest(true);
    {
        const p = try painted.Painted.render(arena, &model);
        const msg = pressMsgByLabel(p.tree, "Open Notary") orelse {
            std.debug.print("no way to open Notary from Settings\n", .{});
            return error.NoDoor;
        };
        try testing.expectEqualStrings(@tagName(Msg.open_notary_window), @tagName(msg));
    }

    // A remote signer is somebody else's process on somebody else's machine, so
    // Notary has nothing to show about it.
    main.setSignerKindForTest("remote");
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Open Notary") == null);
    }

    // And an install that arrived without the window must not offer a press that
    // opens nothing, which is the whole class of fault this release is about.
    main.setSignerKindForTest("helper");
    main.setNotaryWindowFoundForTest(false);
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Open Notary") == null);
    }
}

test "a second Notary window is refused out loud, ceremony or not" {
    // The toast used to be said only while a CEREMONY was running, because that
    // was the only thing that could spawn this window. Opening it from Settings
    // twice was a press that did nothing, silently, which is exactly what the
    // toast exists to prevent.
    main.clearIdentityForTest();
    defer main.clearIdentityForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "none", "running" }) |state| {
        main.setCeremonyForTest(if (std.mem.eql(u8, state, "running")) .running else .none);
        var model = main.initialModel();
        model.stage = .ready;
        main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
        if (model.toast_until == 0) {
            std.debug.print("a refused spawn said nothing with the ceremony {s}\n", .{state});
            return error.SilentRefusal;
        }
    }

    // And it is said where the press was MADE. The control that raises this
    // lives in Settings, and the toast was drawn on the feed screen only: the
    // model held a message nobody could see, which is the same silence with a
    // passing unit test in front of it.
    main.setCeremonyForTest(.none);
    var model = main.initialModel();
    model.stage = .settings;
    main.handleNotaryExitedForTest(&model, .{ .key = 0, .reason = .rejected, .code = 0 });
    const p = try painted.Painted.render(arena, &model);
    if (findAnyText(p.tree.root, "A Notary window is already open") == null) {
        std.debug.print("the refusal is in the model but not on the screen\n", .{});
        return error.ToastNotDrawn;
    }
}

// ---- P5b: the status bar sits on the floor -----------------------------------

test "the status bar is on the floor of the canvas at every height" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reported as an intermittent crop of the bottom bar. It is NOT the layout:
    // this holds the bar to the floor of whatever canvas the app is handed, at
    // every height from below the window's own minimum to well past its default,
    // with the pool healthy and with it dead (the offline banner is extra height
    // above the bar, which is the shape most likely to push it off). If the crop
    // is ever traced to Plaza rather than to the size the platform hands it, this
    // is the line that should have caught it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    defer main.resetRelaysForTest();

    for ([_]bool{ true, false }) |pool_up| {
        main.resetRelaysForTest();
        for (0..main.max_relays_for_test) |r| main.setRelayStatusForTest(r, pool_up);
        var model = main.initialModel();
        model.stage = .ready;

        var first_gap: ?f32 = null;
        var h: f32 = 600;
        while (h <= 900) : (h += 25) {
            const p = try painted.Painted.renderAt(arena, &model, main.window_width, h);
            const chip = p.frameOf("Relays") orelse {
                std.debug.print("no relay chip at height {d:.0}\n", .{h});
                return error.NoStatusBar;
            };
            const gap = h - (chip.y + chip.height);
            if (gap < 0) {
                std.debug.print(
                    "at height {d:.0} the status bar ends at {d:.1}, past the floor\n",
                    .{ h, chip.y + chip.height },
                );
                return error.StatusBarOffTheFloor;
            }
            // And it is the SAME distance from the floor every time: a bar that
            // drifts up as the window grows is one the reader loses at some
            // other size, which is what "sometimes" would look like.
            if (first_gap) |g0| {
                if (@abs(gap - g0) > 0.5) {
                    std.debug.print(
                        "the status bar sits {d:.1} above the floor at {d:.0} and {d:.1} at 600\n",
                        .{ gap, h, g0 },
                    );
                    return error.StatusBarDrifts;
                }
            } else first_gap = gap;
        }
    }
}

// ---- the menu under every post -----------------------------------------------

/// A feed of one note, with an identity, so a row's menu can be opened.
fn oneNoteFeed(model: *Model) void {
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 4242;
    model.notes[0].event_id = [_]u8{0x5a} ** 32;
    model.notes[0].pubkey = [_]u8{0x2b} ** 32;
    const body = "Something worth copying.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes_len = 1;
}

test "the last verb under a post opens that post's menu, and only that post's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);
    // A second note, so "opens the menu" can be told apart from "opens every
    // menu": the state behind this was one shared bool until every post had one.
    model.notes[1] = main.Note{ .created_at = 1_799_999_000 };
    model.notes[1].id = 99;
    model.notes[1].pubkey = [_]u8{0x3c} ** 32;
    model.notes_len = 2;

    {
        const p = try painted.Painted.render(arena, &model);
        const msg = pressMsgByLabel(p.tree, "More") orelse return error.NoMoreControl;
        switch (msg) {
            .toggle_note_menu => |id| try testing.expectEqual(@as(i64, 4242), id),
            else => {
                std.debug.print("the more verb sends {s}\n", .{@tagName(msg)});
                return error.WrongMessage;
            },
        }
        // Closed, so nothing of the menu is on screen.
        try testing.expect(findAnyText(p.tree.root, "Copy note address") == null);
    }

    // Open the FIRST note's menu.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .toggle_note_menu = 4242 }, &fx);
    {
        const p = try painted.Painted.render(arena, &model);
        // Exactly one menu on screen, not one per row.
        try testing.expectEqual(@as(usize, 1), countAnyText(p.tree.root, "Copy note address"));
        try testing.expect(findAnyText(p.tree.root, "Copy text") != null);
        try testing.expect(findAnyText(p.tree.root, "Open on the web") != null);
    }

    // The same press closes it again.
    main.update(&model, Msg{ .toggle_note_menu = 4242 }, &fx);
    try testing.expectEqual(@as(i64, 0), model.note_menu);
}

test "a post's address is in its menu, not under its body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Sixty characters of bech32 sat under every focal note as a copyable pill.
    // It is a thing to copy, not a thing to read, so it lives where a reader
    // looks for something to copy.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);
    model.viewing_thread = 1;
    model.thread_root = model.notes[0];

    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(p.frameOf("Copy nevent") == null);
        if (findAnyTextContainingText(p.tree.root, "nevent1") != null) {
            std.debug.print("a raw nevent is still drawn under the note\n", .{});
            return error.AddressStillOnScreen;
        }
    }

    model.note_menu = model.thread_root.id;
    {
        const p = try painted.Painted.render(arena, &model);
        const msg = pressMsgByLabel(p.tree, "Copy note address") orelse {
            std.debug.print("the menu offers no way to copy the address\n", .{});
            return error.NoCopyAddress;
        };
        switch (msg) {
            .copy_nevent => |id| try testing.expectEqual(model.thread_root.id, id),
            else => return error.WrongMessage,
        }
    }
}

test "every post answers a right-click with the same actions as its menu" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);

    const p = try painted.Painted.render(arena, &model);
    var rows: usize = 0;
    for (p.layout.nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, "Open thread")) continue;
        rows += 1;
        const items = node.widget.context_menu;
        if (items.len == 0) {
            std.debug.print("a post offers nothing on a right-click\n", .{});
            return error.NoContextMenu;
        }
        // The same actions, by name, as the menu behind the last verb.
        for ([_][]const u8{ "Open thread", "Copy note address", "Copy text", "Open on the web" }) |want| {
            for (items) |item| {
                if (std.mem.eql(u8, item.label, want)) break;
            } else {
                std.debug.print("a right-click offers no \"{s}\"\n", .{want});
                return error.MissingContextItem;
            }
        }
    }
    try testing.expect(rows >= 1);
}

test "a note has exactly one menu trigger" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The state is per NOTE, not per control, so a second trigger keyed on the
    // same note does not toggle between them: it opens both menus at once, one
    // over the note and one over whatever is below it. Caught live.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    oneNoteFeed(&model);
    model.viewing_thread = 1;
    model.thread_root = model.notes[0];
    model.note_menu = model.thread_root.id;

    const p = try painted.Painted.render(arena, &model);
    const triggers = countAnyText(p.tree.root, "Copy note address");
    if (triggers != 1) {
        std.debug.print("{d} menus open over one note\n", .{triggers});
        return error.TwoMenus;
    }
}

test "the status bar is on screen wherever the reader is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // It was the last row of the FEED's own column, and every level layered over
    // the feed is opaque, so opening a note took the pool's health, the outbox
    // and the signer off screen. Those three are least dispensable exactly when
    // a reader is reading something and about to answer it.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const author = [_]u8{0x55} ** 32;
    const Where = struct { name: []const u8, arm: *const fn (*Model) void };
    const places = [_]Where{
        .{ .name = "the feed", .arm = struct {
            fn f(_: *Model) void {}
        }.f },
        .{ .name = "a thread", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
            }
        }.f },
        .{ .name = "a person", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_profile = [_]u8{0x55} ** 32;
            }
        }.f },
        .{ .name = "a thread three levels deep", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
                for (0..3) |d| {
                    m.thread_stack[d] = .{ .note = .{ .created_at = 100 } };
                    m.thread_stack[d].note.id = @intCast(500 + d);
                }
                m.thread_stack_len = 3;
            }
        }.f },
    };

    for (places) |place| {
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root.pubkey = author;
        place.arm(&model);
        const p = try painted.Painted.render(arena, &model);
        const chip = p.frameOf("Relays") orelse {
            std.debug.print("no status bar on {s}\n", .{place.name});
            return error.StatusBarMissing;
        };
        // On the floor of the window rather than pushed off the bottom.
        const bottom = chip.y + chip.height;
        if (bottom > main.window_height or bottom < main.window_height - 60) {
            std.debug.print(
                "on {s} the status bar ends at {d:.1}, and the window is {d:.0} tall\n",
                .{ place.name, bottom, main.window_height },
            );
            return error.StatusBarNotOnTheFloor;
        }

        // And NOT UNDER anything. Present and correctly placed is not the same
        // as visible: a thread is an opaque card laid over the feed, and while
        // the bar was the last row of the feed's own column it kept its frame,
        // kept its position, and was painted over. The first version of this
        // test asked the widget tree and passed on the broken code, which is the
        // whole reason the painted layer exists.
        for (p.layout.nodes) |node| {
            if (node.widget.kind != .card) continue;
            const f = node.widget.frame;
            const covers = f.x <= chip.x and f.y <= chip.y and
                f.x + f.width >= chip.x + chip.width and
                f.y + f.height >= chip.y + chip.height;
            if (!covers) continue;
            std.debug.print(
                "on {s} the status bar is under an opaque {d:.0}x{d:.0} surface\n",
                .{ place.name, f.width, f.height },
            );
            return error.StatusBarCovered;
        }
    }
}

test "a new account is offered Follow on the starter pack, not Unfollow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What a reader saw the moment they made a key: nine people they had never
    // chosen, each reported as followed, each offering "Unfollow", and each
    // press doing nothing. The offer is the bug; the silence when pressed was
    // the write path being right.
    main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{0x74} ** 32);
    defer main.clearIdentityForTest();
    main.setIdentityMintedForTest(true);
    defer main.setIdentityMintedForTest(false);

    const packed_in = main.followSetForTest()[0];
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 77;
    model.notes[0].pubkey = packed_in;
    model.notes_len = 1;
    model.note_menu = 77;

    const p = try painted.Painted.render(arena, &model);
    if (findAnyText(p.tree.root, "Unfollow") != null) {
        std.debug.print("a starter-pack author is offered Unfollow\n", .{});
        return error.OfferedUnfollow;
    }
    const msg = pressMsgByLabel(p.tree, "Follow") orelse {
        std.debug.print("no way to follow a starter-pack author\n", .{});
        return error.NoFollowOffer;
    };
    switch (msg) {
        .follow_author => |direction| try testing.expectEqual(@as(u8, 1), direction),
        else => return error.WrongMessage,
    }

    // And the feed still says whose choice the pack was, which is the other half
    // of not claiming it: the header has always been honest and the controls
    // were not.
    try testing.expect(findAnyText(p.tree.root, "Starter pack") != null);
    try testing.expect(findAnyTextContainingText(p.tree.root, "hand-picked") != null);
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

// ---- a dismissal has to clear the state that opened it ------------------------

/// The dismiss Msg of the surface that CONTAINS `text`, and nothing else.
///
/// Not every dismiss in the view: the mention picker floats inside the compose
/// sheet, which has a dismiss of its own, and firing both closed the sheet and
/// took the picker off screen with it. The test then passed with the picker's
/// own dismissal doing nothing at all, which is the bug it was written for.
fn dismissMsgOfSurfaceHolding(p: painted.Painted, text: []const u8) ?Msg {
    var holder: ?usize = null;
    for (p.layout.nodes, 0..) |node, i| {
        if (!std.mem.eql(u8, node.widget.text, text)) continue;
        holder = i;
        break;
    }
    var cursor = holder orelse return null;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const w = p.layout.nodes[cursor].widget;
        switch (w.kind) {
            .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu => {
                for (p.tree.handlers) |h| {
                    if (h.id != w.id or h.event != .dismiss) continue;
                    return switch (h.action) {
                        .message => |m| m,
                        else => null,
                    };
                }
                return null;
            },
            else => {},
        }
        cursor = p.layout.nodes[cursor].parent_index orelse return null;
    }
    return null;
}

test "dismissing a surface clears the state that opened it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The engine hides a dismissed surface immediately and the next rebuild is
    // truth again, so a dismiss wired to somebody ELSE's state hides the surface
    // for one frame and puts it straight back. It looks like a flicker and it
    // reads as a control that does not work.
    //
    // Found live on the note menu, which sent `close_menu` (the chrome's state)
    // while its own open flag is `note_menu`, and then on the mention picker,
    // which had no open flag at all. Both had the same shape: the surface is on
    // screen after the dismiss it declared.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const Case = struct {
        name: []const u8,
        text: []const u8,
        open: *const fn (*Model) void,
    };
    const cases = [_]Case{
        .{ .name = "the note menu", .text = "Copy note address", .open = struct {
            fn f(m: *Model) void {
                m.stage = .ready;
                m.notes[0] = main.Note{ .created_at = 1_800_000_000 };
                m.notes[0].id = 4242;
                m.notes_len = 1;
                m.note_menu = 4242;
            }
        }.f },
        .{
            .name = "the mention picker",
            .text = "inserts a nostr: link, not just a name",
            .open = struct {
                fn f(m: *Model) void {
                    m.stage = .ready;
                    m.composing = true;
                    // Somebody to offer: the picker draws nothing without a name it
                    // could insert.
                    const who = [_]u8{0x91} ** 32;
                    if (main.upsertProfile(who)) |pr| {
                        main.parseMetadataInto(pr, "{\"display_name\":\"Alice\"}");
                    }
                    m.draft_buffer.set("hello @Al");
                }
            }.f,
        },
    };

    for (cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const before = try painted.Painted.render(arena, &model);
        if (findAnyText(before.tree.root, c.text) == null) {
            std.debug.print("{s} is not on screen to begin with\n", .{c.name});
            return error.SurfaceNotOpen;
        }

        // The dismiss THIS surface declares, and only it.
        const msg = dismissMsgOfSurfaceHolding(before, c.text) orelse {
            std.debug.print("{s} declares no dismiss of its own\n", .{c.name});
            return error.NoDismissDeclared;
        };
        var fx: main.EffectsForTest = undefined;
        main.update(&model, msg, &fx);

        const after = try painted.Painted.render(arena, &model);
        if (findAnyText(after.tree.root, c.text) != null) {
            std.debug.print("{s} is still on screen after its own dismiss\n", .{c.name});
            return error.DismissDidNotClose;
        }
    }
}

test "every sheet takes the keyboard when it opens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Escape resolves from the FOCUSED widget up to the surface around it, with
    // a fallback that only sees ANCHORED surfaces. A sheet is neither anchored
    // nor focused by default, so Escape closed none of them, while three
    // comments in this file said it did. Driving the app is what found it.
    //
    // So each sheet takes the keyboard on the way in: its first field where it
    // has one (a composer you must click into before typing is a composer that
    // opened for no reason), and otherwise its way out, which is the only thing
    // safe to have under an accidental Return.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    for (modal_cases) |c| {
        var model = main.initialModel();
        c.open(&model);
        const p = try painted.Painted.render(arena, &model);
        const root = modalDialogIndex(p, c.label) orelse {
            std.debug.print("{s}: no dialog\n", .{c.name});
            return error.NoModalDialog;
        };
        var focused: usize = 0;
        for (p.layout.nodes, 0..) |node, i| {
            if (!node.widget.autofocus) continue;
            if (!isDescendantOf(p, i, root)) continue;
            focused += 1;
        }
        if (focused == 0) {
            std.debug.print("{s}: nothing in the sheet takes the keyboard\n", .{c.name});
            return error.SheetTakesNoFocus;
        }
        // Exactly one: two things asking for the caret is a race whose winner is
        // whichever the tree happens to reach first.
        if (focused > 1) {
            std.debug.print("{s}: {d} things ask for the keyboard\n", .{ c.name, focused });
            return error.TwoFocusRequests;
        }
    }
}

// ---- the retained extent context ---------------------------------------------

test "a list's retained extent context survives the arena that built it" {
    // The SDK keeps `extent_context` and calls the estimator through it long
    // after the build returned: in a post-layout measure pass, and since 0.7.2
    // from inside `virtualWindow` on a LATER build. Both lists handed it an
    // arena-allocated view context full of slices. The runtime rotates a small
    // set of arenas and resets the one it is about to build into, so a context
    // handed over on build N is read on build N+2 with its slices pointing at
    // whatever the new build has since put there. It segfaulted in
    // `noteRowEstimateWith` on a mouse-up over a person's page.
    //
    // This builds a view, DROPS the arena entirely, and then calls the estimator
    // exactly as the SDK would. Under the old shape that reads freed memory;
    // under a table of numbers with process lifetime it cannot.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const author = [_]u8{0x55} ** 32;
    const Case = struct { name: []const u8, arm: *const fn (*Model) void };
    const cases = [_]Case{
        .{ .name = "a person", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_profile = [_]u8{0x55} ** 32;
            }
        }.f },
        .{ .name = "a thread", .arm = struct {
            fn f(m: *Model) void {
                m.viewing_thread = 1;
                m.thread_root.id = 1;
            }
        }.f },
    };

    for (cases) |c| {
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root.pubkey = author;
        for (0..40) |i| {
            model.thread_notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
            model.thread_notes[i].id = @intCast(600 + i);
            model.thread_notes[i].pubkey = author;
            model.thread_notes[i].event_id = [_]u8{@intCast(i + 1)} ** 32;
        }
        model.thread_notes_len = 40;
        c.arm(&model);

        const context = if (model.viewing_profile != null)
            main.profileExtentTableForTest(0)
        else
            main.threadExtentTableForTest(0);

        {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            // NOT deferred: the arena is destroyed on purpose below, before the
            // estimator is called, which is the whole point.
            const arena = arena_state.allocator();
            _ = try painted.Painted.render(arena, &model);
            arena_state.deinit();
        }

        const rows = main.extentTableLenForTest(context);
        if (rows < 5) {
            std.debug.print("{s}: only {d} rows, too few to prove anything\n", .{ c.name, rows });
            return error.TooFewRows;
        }
        // Every row, after the arena is gone. A table of zeroes would also be
        // "safe", so the total has to be a real height.
        var total: f32 = 0;
        for (0..rows) |i| total += main.rowExtentFromTableForTest(context, @intCast(i));
        if (!(total > 100)) {
            std.debug.print("{s}: {d} rows measure {d:.1} in total\n", .{ c.name, rows, total });
            return error.ExtentsLostWithTheArena;
        }
    }
}

test "an extent context that is not a table is refused, not read" {
    // The estimator is typed now, so the wrong FUNCTION will not compile. The
    // wrong CONTEXT still would: `extent_context` is `?*const anyopaque` and
    // takes any pointer, so wiring the table's reader to a view context would
    // read one struct as the other and hand the list garbage heights without
    // saying anything. The table carries a tag for exactly that.
    var not_a_table: [64]u8 = [_]u8{0xAB} ** 64;
    const height = main.rowExtentFromTableForTest(&not_a_table, 3);
    try testing.expectApproxEqAbs(main.quiet_row_extent, height, 0.001);

    // And a real table still answers with a real height.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;
    _ = try painted.Painted.render(arena_state.allocator(), &model);
    const table = main.threadExtentTableForTest(0);
    try testing.expect(main.extentTableLenForTest(table) > 0);
    try testing.expect(main.rowExtentFromTableForTest(table, 0) > 0);
}

test "picture slots follow the reader down a long thread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same fault as the faces, and the one that shows: a level marked EVERY
    // picture it held as wanted, and the claim pass refuses to evict anything
    // wanted, so the first six took the six slots and every other picture in the
    // thread stayed an empty box for as long as the thread was open.
    //
    // What decides that is which ids the pass marks. A picture still marked is
    // one the allocator may not reclaim; a picture no longer marked is one the
    // rows now on screen can take. So that is what this asks about.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();
    // Previews OFF, so the pass marks and claims without reaching the network:
    // a test cannot construct a usable effect table, and `fireMedia` returns
    // before it needs one.
    const previews_were = main.mediaPreviews();
    main.setMediaPreviews(false);
    defer main.setMediaPreviews(previews_were);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;
    model.thread_root.pubkey = [_]u8{0x55} ** 32;

    const count = 30;
    for (0..count) |i| {
        model.thread_notes[i] = main.Note{ .created_at = 1_800_000_000 - @as(i64, @intCast(i)) };
        model.thread_notes[i].id = @intCast(900 + i);
        model.thread_notes[i].pubkey = [_]u8{0x55} ** 32;
        model.thread_notes[i].event_id = [_]u8{@intCast(i + 1)} ** 32;
        const url = "https://example.com/a.jpg";
        @memcpy(model.thread_notes[i].image_url_buf[0..url.len], url);
        model.thread_notes[i].image_url_len = url.len;
    }
    model.thread_notes_len = count;
    _ = try painted.Painted.render(arena, &model);

    var fx: main.EffectsForTest = undefined;

    // Give the notes at the TOP of the thread the slots, as a reader arriving
    // there would.
    const top = [_]i64{ 900, 901, 902 };
    for (top) |id| _ = main.claimMediaSlotForTest(&fx, id);
    for (top) |id| try testing.expect(main.mediaSlotWantedForTest(id) != null);

    // Now the reader is at the BOTTOM. The pass runs over what is on screen.
    const bottom = [_]i64{ 925, 926, 927 };
    main.recordVisibleNotesForTest(&bottom);
    main.scanMediaFetchesForTest(&fx, &model);

    // The pictures that scrolled away are no longer claimed as wanted, which is
    // exactly what lets the ones now on screen be lent a slot. Before this fix
    // every picture in the thread was marked on every pass and none of them
    // could ever be reclaimed.
    for (top) |id| {
        const wanted = main.mediaSlotWantedForTest(id) orelse continue;
        if (wanted) {
            std.debug.print("picture {d} scrolled away and is still holding its slot\n", .{id});
            return error.PicturesStuckAtTheTop;
        }
    }
}

// ---- a note that could not be found is not written off forever ---------------

test "a quote that could not be found is asked for again, and again" {
    // Three unanswered tries used to mark an entry missing for good: nothing
    // re-armed it, not a later round, not a reconnect, not reopening the thread.
    // Three tries is nothing, and they can all land while the pool is still
    // dialling, so a note sitting on the reader's OWN relays could be written
    // off in the first seconds and read "not on your relays yet" for the rest of
    // the session. That is what happened to the ancestor above a thread every
    // other client showed, and I fetched that parent from those same four relays
    // in under a second.
    const id = [_]u8{0x4c} ** 32;
    main.dropQuoteForTest(id);
    main.wantQuoteForTest(id);

    // Ask until well past the old cap of three, re-arming between rounds the way
    // the timer does.
    var tries: usize = 0;
    for (0..40) |_| {
        main.rearmWantedQuotesForTest();
        main.advanceQuoteRoundForTest(main.quoteBackoffRoundsForTest(255));
        main.requestWantedQuotesForTest();
        const e = main.quoteForTest(id) orelse return error.QuoteEvicted;
        if (e.attempts > tries) tries = e.attempts;
    }
    if (tries <= 3) {
        std.debug.print("gave up after {d} tries\n", .{tries});
        return error.GaveUpForGood;
    }

    // And it backs off rather than hammering: the first few rounds try every
    // time, then the gap grows to a ceiling.
    try testing.expectEqual(@as(u64, 1), main.quoteBackoffRoundsForTest(0));
    try testing.expectEqual(@as(u64, 1), main.quoteBackoffRoundsForTest(2));
    try testing.expect(main.quoteBackoffRoundsForTest(6) > 1);
    try testing.expect(main.quoteBackoffRoundsForTest(200) <= 30);
}

test "a relay coming up puts every unfound note back in the queue" {
    // The backoff alone would still make a reader wait out a gap for something
    // that became findable the instant a relay finished dialling. A change in
    // the pool is new information about every unanswered question.
    const id = [_]u8{0x4d} ** 32;
    main.dropQuoteForTest(id);
    main.wantQuoteForTest(id);
    main.requestWantedQuotesForTest();

    const e = main.quoteForTest(id) orelse return error.QuoteEvicted;
    // Pushed into the future by its own backoff.
    main.advanceQuoteRoundForTest(0);
    e.next_round = 999_999;
    e.requested = true;

    main.requeueMissingQuotesForTest();
    try testing.expectEqual(@as(u64, 0), e.next_round);
    try testing.expect(!e.requested);
}

// ---- waiting, and failing, look like themselves -------------------------------

test "a picture that will not load says so instead of waiting forever" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The view asked only whether the picture was LOADED, so every state that is
    // not loaded drew the same striped waiting frame. A 404 waits in it forever.
    main.resetMediaForTest();
    defer main.resetMediaForTest();
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 4242;
    model.notes[0].pubkey = [_]u8{0x2b} ** 32;
    const url = "https://haven.example.com/gone.jpg";
    @memcpy(model.notes[0].image_url_buf[0..url.len], url);
    model.notes[0].image_url_len = url.len;
    model.notes_len = 1;

    // Still coming: no failure said, because none has happened.
    {
        const p = try painted.Painted.render(arena, &model);
        try testing.expect(findAnyText(p.tree.root, "This picture would not load") == null);
    }

    // The host answered 404.
    var fx: main.EffectsForTest = undefined;
    const slot = main.claimMediaSlotForTest(&fx, 4242) orelse return error.NoSlot;
    main.markMediaFailedForTest(slot);
    try testing.expect(main.mediaFailed(4242));

    const p = try painted.Painted.render(arena, &model);
    if (findAnyText(p.tree.root, "This picture would not load") == null) {
        std.debug.print("a picture that answered 404 is still drawn as loading\n", .{});
        return error.StillWaiting;
    }
    // And it names where it was, and offers the one thing that might still work.
    try testing.expect(findAnyTextContainingText(p.tree.root, "haven.example.com") != null);
    const msg = pressMsgByLabel(p.tree, "This picture could not be loaded, press to open the original") orelse
        return error.NoWayToOpenIt;
    switch (msg) {
        .open_url => {},
        else => return error.WrongMessage,
    }
}

test "opening a reply asks about the conversation, not just that reply" {
    // NIP-10 is what makes this necessary. A reply carries an `e` tag for the
    // ROOT and one for its immediate parent, so a grandchild of the note in the
    // reader's hand names its parent and the root, and never the note in
    // between. Asking only about the note pressed therefore returned its direct
    // children and nothing else: no siblings, no parent, no root post, and
    // nothing under those children.
    const focal = [_]u8{0xf0} ** 32;
    const root = [_]u8{0x0a} ** 32;
    var root_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&root_hex, "{x}", .{root}) catch unreachable;

    var out: [2][32]u8 = undefined;

    // A reply in the middle of a thread: both ids, the pressed note first.
    const marked = [_]nostr.event.Tag{
        &.{ "e", &root_hex, "", "root" },
        &.{ "e", "b" ** 64, "", "reply" },
    };
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, &marked, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);
    try testing.expectEqualSlices(u8, &root, &out[1]);

    // A root post has nothing above it, so there is nothing to add.
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, &.{}, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);

    // A note that names ITSELF as its root is one id, not the same id twice.
    var focal_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&focal_hex, "{x}", .{focal}) catch unreachable;
    const self_rooted = [_]nostr.event.Tag{&.{ "e", &focal_hex, "", "root" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, &self_rooted, &out));

    // A quote is not an ancestor: a mention-marked tag must not be taken as the
    // root, or pressing a note that quotes another opens the wrong thread.
    const quoting = [_]nostr.event.Tag{&.{ "e", &root_hex, "", "mention" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, &quoting, &out));

    // An old-style positional reply, with no marker at all, still resolves.
    const positional = [_]nostr.event.Tag{&.{ "e", &root_hex }};
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, &positional, &out));
    try testing.expectEqualSlices(u8, &root, &out[1]);
}

test "a host having a moment is not the same as a host saying no" {
    // A 404 is an answer and the box says so. A timeout, a rate limit or a 5xx
    // is the network having a moment, and marking a good picture permanently
    // broken over one of those is the quote fetch's old mistake in a place the
    // reader can see.
    for ([_]u16{ 404, 410, 403, 400 }) |final| {
        try testing.expectEqual(main.ImageFailure.give_up, main.classifyImageFailure(.ok, final));
    }
    for ([_]u16{ 408, 429, 500, 502, 503 }) |transient| {
        try testing.expectEqual(main.ImageFailure.retry, main.classifyImageFailure(.ok, transient));
    }
    // No answer at all is the network, whatever status field came with it.
    for ([_]native_sdk.EffectFetchOutcome{ .connect_failed, .tls_failed, .protocol_failed, .timed_out }) |outcome| {
        try testing.expectEqual(main.ImageFailure.retry, main.classifyImageFailure(outcome, 0));
    }
}

test "a picture too big to decode is not downloaded again forever" {
    // This is the one the status code cannot answer. An oversized or truncated
    // body comes back 200: the host did nothing wrong and will send exactly the
    // same bytes next time. Reading only the status put the slot back to idle,
    // and the scan that refills idle slots runs on the one-second tick AND on
    // every scroll event, so one picture too large for the decoder was
    // re-downloaded for as long as the reader looked at it.
    try testing.expectEqual(main.ImageFailure.give_up, main.classifyImageFailure(.ok, 200));

    // Driven through the real handler, because the classification is only half
    // of it: the slot has to end up somewhere the refill scan will not pick up.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_001;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    // A 200 carrying more than the decoder will take.
    const too_big = try arena.alloc(u8, 250_000);
    @memset(too_big, 0);
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 200, too_big);
    if (!main.mediaFailed(note_id)) {
        std.debug.print("an oversized picture went back to idle, so it will be fetched again\n", .{});
        return error.WouldRefetchForever;
    }
}

test "a picture the network lost is retried, but not without end" {
    // The mirror of the case above, and the one the avatar path used to get
    // wrong in the other direction: a 503 is the host having a moment, so the
    // picture is worth asking for again. Bounded, so that no future mistake in
    // the classification can turn "worth asking again" into a download loop.
    var fx: main.EffectsForTest = undefined;
    const note_id: i64 = 77_002;
    _ = main.claimMediaSlotForTest(&fx, note_id) orelse return error.NoSlot;

    main.deliverMediaResponseForTest(&fx, note_id, .ok, 503, "");
    try testing.expect(main.mediaIdleForTest(note_id));
    try testing.expectEqual(@as(u8, 1), main.mediaAttemptsForTest(note_id).?);

    main.deliverMediaResponseForTest(&fx, note_id, .connect_failed, 0, "");
    main.deliverMediaResponseForTest(&fx, note_id, .ok, 429, "");
    try testing.expect(main.mediaIdleForTest(note_id));

    // The fourth is where it stops.
    main.deliverMediaResponseForTest(&fx, note_id, .timed_out, 0, "");
    try testing.expect(main.mediaFailed(note_id));
}

test "a quote still loading looks like the card that will replace it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // It was one 34px bar, which says "something is loading" and nothing about
    // what. A quote card is a face, a name and a line or two of somebody else's
    // words, so the wait is shaped like that.
    const quoted_id = [_]u8{0x7e} ** 32;
    main.dropQuoteForTest(quoted_id);
    main.wantQuoteForTest(quoted_id);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;

    const p = try painted.Painted.render(arena, &model);
    var discs: usize = 0;
    var bars: usize = 0;
    for (p.layout.nodes) |node| {
        if (node.widget.kind != .skeleton) continue;
        const f = node.widget.frame;
        if (f.width > 0 and @abs(f.width - f.height) < 1.5) discs += 1 else bars += 1;
    }
    if (discs == 0 or bars < 2) {
        std.debug.print("the waiting quote draws {d} disc(s) and {d} bar(s)\n", .{ discs, bars });
        return error.NotACardShape;
    }

    // And the row is still priced for what it draws, or the feed jumps when the
    // quote lands. That pricing is what the skeleton's fixed height is FOR.
    const priced = main.noteRowEstimateForTest(&model.notes[0], main.feed_row_chrome);
    const rows = p.framesOf("Open thread");
    if (rows.len < 1) return error.NoRow;
    if (@abs(rows[0].height - priced) > 1.5 * main.body_line_height) {
        std.debug.print("\nwaiting row draws {d}, priced {d}\n", .{ rows[0].height, priced });
        return error.SkeletonNotPriced;
    }
}

// ---- pressing Follow before the list has arrived says so --------------------

test "a follow that could not be written says why instead of nothing" {
    // Not the case where the app is still reading your list: that one is handled
    // properly already, with the button disabled and a sentence under the counts
    // saying so. This is the one with no gate in front of it.
    //
    // The built-in signer signs one thing at a time. Press Follow while a
    // signature is already out and the write is refused, and every affordance
    // for it looks perfectly live: the button is enabled, the menu row is not
    // greyed, and the press did nothing at all. That window is a second or two
    // for a local key and as long as an approval prompt takes for a Notary one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{119} ** 32);
    main.setIdentityForTest([_]u8{119} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.forgetOwnListMemoForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    defer main.setSignerKindLocalForTest();
    defer main.releaseHelperSignForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/saywhy.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    // A real list of their own, so nothing else can be the reason.
    var tags: [40]nostr.event.Tag = undefined;
    var hexes: [40][64]u8 = undefined;
    for (0..40) |i| {
        _ = try std.fmt.bufPrint(&hexes[i], "{x:0>2}{s}", .{ @as(u8, @intCast(i)), "cd" ** 31 });
        const pair = try arena.alloc([]const u8, 2);
        pair[0] = "p";
        pair[1] = &hexes[i];
        tags[i] = pair;
    }
    const mine = try nostr.event.create(arena, signer, kp, 1_800_000_000, 3, &tags, "", null);
    _ = try main.plazaIngestVerifiedForTest(arena, mine, signer);
    main.ingestContactListForTest(mine);
    try testing.expect(main.canWriteFollows());

    var stranger: [32]u8 = undefined;
    @memset(&stranger, 0x5a);

    var model = main.Model{};
    model.stage = .ready;
    model.viewing_profile = stranger;
    model.toast_len = 0;
    model.toast_until = 0;
    var fx: main.EffectsForTest = undefined;

    // A signature is already out.
    main.holdHelperSignForTest();
    main.update(&model, main.Msg{ .follow_person = 1 }, &fx);

    // The stranger was not added, which is correct and is not the point.
    try testing.expect(!main.isFollowedByMe(stranger));

    // The point: the reader was told, rather than left pressing a live-looking
    // button that does nothing.
    if (model.toast_len == 0) return error.RefusedInSilence;
    const said = model.toast_buf[0..model.toast_len];
    if (std.mem.indexOf(u8, said, "signer") == null) {
        std.debug.print("\nthe app said \"{s}\"\n", .{said});
        return error.SaidTheWrongThing;
    }

    // And once the signature comes back, the same press works.
    main.releaseHelperSignForTest();
    main.setSignerKindLocalForTest();
    model.toast_len = 0;
    main.update(&model, main.Msg{ .follow_person = 1 }, &fx);
    try testing.expect(main.isFollowedByMe(stranger));
}

// ---- nothing paints past the edge of the smallest window allowed ------------

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
    const floor = @import("window_floor").manifest_min_width;

    const States = enum { feed, feed_with_link, thread, profile, settings, notifications, composing, joining, menu_scope, menu_relays, menu_account, menu_outbox, menu_note };

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
            .menu_note => model.note_menu = model.notes[0].id,
        }

        const p = try painted.Painted.renderAt(arena_state.allocator(), model, floor, floor);
        // The baseline is the feed WITH the link note, because that is what
        // every menu state is drawn on top of. Taking it from the plain feed
        // instead made this guard pass a menu that rendered nothing: the link
        // note alone accounts for eighteen nodes, which was enough to look like
        // an opened menu.
        if (st == .feed_with_link) base_nodes = p.layout.nodes.len;
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
            .menu_scope, .menu_relays, .menu_account, .menu_outbox, .menu_note => {
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

test "a profile's name, check and npub sit next to each other" {
    // The overflow sweep cannot see this. Bounding the name with a definite
    // width satisfied it completely and still ruined the page: `width` is a
    // definite SIZE, so the name's box stayed 559px wide for a three-letter
    // name and the verified check sat at the far right of the window, with the
    // same hole between the handle and the npub. It measured perfectly and
    // looked broken.
    //
    // So this measures the gaps, which is what a reader actually sees.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Signed in, or the page under test is the guest banner. The first version
    // of this test measured that banner and reported the rail's icon as a
    // verified check adrift by 277px, which is a good reminder that a
    // measurement is only as good as the screen it was taken on.
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();

    var them: [32]u8 = undefined;
    @memset(&them, 0x11);
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.fillProfileTextForTest(them, "Sep", "sep", "https://zignostr.com");
    main.setProfileNip05ForTest(them, "sep@zignostr.com", true);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = them;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);

    // Anchored on the CHECK, then the name is whatever sits on its line to its
    // left. Anchoring on the name instead found the copy in the header band
    // forty pixels up, whose line has no check on it, so the whole assertion
    // was skipped and the test passed the bug it exists for.
    var check: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (n.widget.kind != .icon) continue;
        if (!std.mem.eql(u8, n.widget.text, "check")) continue;
        check = n.widget.frame;
    }
    const c = check orelse return error.NoVerifiedCheckOnThePage;

    var name: ?native_sdk.geometry.RectF = null;
    for (p.layout.nodes) |n| {
        if (n.widget.text.len == 0 or n.widget.kind == .icon) continue;
        if (n.widget.frame.y < c.y - 14 or n.widget.frame.y > c.y + 14) continue;
        if (n.widget.frame.x >= c.x) continue;
        if (name == null or n.widget.frame.x > name.?.x) name = n.widget.frame;
    }
    const nm = name orelse return error.NoNameBesideTheCheck;

    // Measured from where the name STARTS, not from the far side of its box.
    // Measuring from the box passes the exact bug this exists for: give the
    // name a definite 559px width and the check sits 7px past the end of that
    // box, dutifully adjacent to a rectangle that is almost entirely empty.
    // The reader sees the distance from the word.
    const from_word = c.x - nm.x;
    if (from_word > 90) {
        std.debug.print(
            "\nthe verified check is {d:.0}px from the start of a three-letter name (its box is {d:.0} wide)\n",
            .{ from_word, nm.width },
        );
        return error.CheckAdrift;
    }

    const handle = frameOfTextContaining(p, "sep@zignostr.com") orelse return error.NoHandle;

    // And the npub follows the handle rather than starting a column of its own.
    if (frameOfTextContaining(p, "npub1")) |npub| {
        const npub_gap = npub.x - handle.x;
        if (npub_gap > 160) {
            std.debug.print(
                "\nthe npub is {d:.0}px from the start of the handle (its box is {d:.0} wide)\n",
                .{ npub_gap, handle.width },
            );
            return error.NpubAdrift;
        }
    }
}

test "a profile states one identifier per line, in order" {
    // Name, then the address they proved, then the key. They shared a row
    // before, which read as one strip of identifiers and put the npub, the part
    // most likely to be copied, in the middle of it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    var them: [32]u8 = undefined;
    @memset(&them, 0x11);
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();
    main.fillProfileTextForTest(them, "Sep", "sep", "https://zignostr.com");
    main.setProfileNip05ForTest(them, "sep@zignostr.com", true);

    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_profile = them;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);
    const nip05 = frameOfTextContaining(p, "sep@zignostr.com") orelse return error.NoHandle;
    const npub = frameOfTextContaining(p, "npub1") orelse return error.NoNpub;

    // Below, not beside. A row would put them at the same y.
    if (npub.y <= nip05.y + 2) {
        std.debug.print("\nthe npub is at y={d:.0} and the handle at y={d:.0}\n", .{ npub.y, nip05.y });
        return error.NpubNotBelowHandle;
    }
    // And on the same rail, so the column reads as a column.
    if (@abs(npub.x - nip05.x) > 1.5) {
        std.debug.print("\nthe npub starts at x={d:.0} and the handle at x={d:.0}\n", .{ npub.x, nip05.x });
        return error.NotOnOneRail;
    }
}

test "a link preview's description is cut with an ellipsis, not by the card edge" {
    // The title elides through the engine and the description does not: the
    // engine's ellipsis works on a plain text node and not on a paragraph built
    // from spans, so this one is shortened in Zig. Both are asserted, because
    // the reason they differ is an engine detail that could change.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    main.clearLinkPreviewsForTest();
    defer main.clearLinkPreviewsForTest();
    const url = "https://coldcard-hack-tracker.example/x";
    main.setLinkPreviewForTest(
        url,
        "coldcard-hack-tracker.example",
        "Coldcard Hack Tracker and a title that carries on well past the room the card has for it",
        "Coldcard Hack Tracker, live monitoring of Bitcoin held from seed entropy sweeps since July 2026, and then some more words after that",
    );

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest(url);
    model.notes_len = 1;

    const p = try painted.Painted.renderAt(arena_state.allocator(), &model, main.window_width, 900);
    const card = frameOfSemantics(p, "Open link") orelse return error.NoLinkCard;
    const right = card.x + card.width;

    var found = false;
    for (p.layout.nodes) |n| {
        if (std.mem.indexOf(u8, n.widget.text, "live monitoring") == null) continue;
        found = true;
        // It says so, rather than simply stopping.
        if (std.mem.indexOf(u8, n.widget.text, "\u{2026}") == null) {
            std.debug.print("\nthe description was not cut: \"{s}\"\n", .{n.widget.text});
            return error.NoEllipsis;
        }
        // And it stops inside the card, which is the part a reader sees.
        if (n.widget.frame.x + n.widget.frame.width > right + 0.5) {
            std.debug.print(
                "\nthe description runs to {d:.0}; the card ends at {d:.0}\n",
                .{ n.widget.frame.x + n.widget.frame.width, right },
            );
            return error.DescriptionOverflowsCard;
        }
    }
    if (!found) return error.NoDescription;
}

test "a bio's nostr: mentions are drawn as names, like a note's" {
    // A bio is written the same way a note is, so it carries the same NIP-27
    // references. The feed has drawn them as `@name` for a long time and the
    // profile printed the raw token, which is sixty-three characters of base32
    // in the middle of a sentence about a person.
    //
    // Asserted through `personAbout`, which is what both the page and the
    // height calculation call, rather than through `renderContent` directly:
    // the rewriting was never in doubt, reaching for it was.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bio.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    const subject = [_]u8{0x71} ** 32;
    const friend = [_]u8{0x72} ** 32;
    const friend_npub = try nostr.nip19.encodeNpub(arena, friend);

    const bio = try std.fmt.allocPrint(arena, "Engaged to nostr:{s}", .{friend_npub});
    const meta = try std.fmt.allocPrint(arena, "{{\"name\":\"subject\",\"about\":\"{s}\"}}", .{bio});
    _ = try store.ingest(arena, .{
        .id = [_]u8{0xb1} ** 32,
        .pubkey = subject,
        .created_at = 1_800_000_000,
        .kind = 0,
        .tags = &.{},
        .content = meta,
        .sig = [_]u8{0} ** 64,
    }, .{});

    // Nobody knows the friend yet: a short npub, but never the raw token.
    {
        const shown = main.personAbout(subject);
        try testing.expect(std.mem.indexOf(u8, shown, "nostr:") == null);
        try testing.expect(std.mem.indexOf(u8, shown, "@npub1") != null);
        try testing.expect(std.mem.startsWith(u8, shown, "Engaged to @npub1"));
    }

    // Their kind:0 arrives and the app learns the name the way it really does,
    // through the profile refresh. This is the part a one-shot rewrite at parse
    // time gets wrong: the bio itself never changes, so nothing about the
    // subject's own event ever says to look at it again.
    _ = try store.ingest(arena, .{
        .id = [_]u8{0xb2} ** 32,
        .pubkey = friend,
        .created_at = 1_800_000_001,
        .kind = 0,
        .tags = &.{},
        .content = "{\"name\":\"aliza\"}",
        .sig = [_]u8{0} ** 64,
    }, .{});

    // The reader follows her, which is how her name reaches the cache at all.
    main.setIdentityForTest([_]u8{0x44} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    _ = main.setFollowsForTest(&[_][32]u8{friend}, 1_800_000_000);

    // Heap, not stack: a Model carries three hundred notes of fixed buffers.
    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    main.reconcileForTest(model, &store, 1_800_000_100);

    const shown = main.personAbout(subject);
    try testing.expectEqualStrings("Engaged to @aliza", shown);
}

test "the accessibility audit is switched on, not just present" {
    // The sweep above asserts every screen passes this audit. A guard that
    // cannot fail says the same thing as a guard that passes, so this hands it
    // a tree it must reject: two sibling buttons announced under one name, which
    // a screen reader reads as the same control twice.
    //
    // Three separate guards this session passed while measuring nothing. This is
    // the cheapest possible way to know this one is not the fourth.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var ui = main.AppUi.init(arena);
    const node = ui.column(.{ .gap = 0 }, .{
        ui.el(.button, .{ .width = 80, .height = 30, .semantics = .{ .role = .button, .label = "Same" } }, .{}),
        ui.el(.button, .{ .width = 80, .height = 30, .semantics = .{ .role = .button, .label = "Same" } }, .{}),
    });
    const tree = try ui.finalizeWithTokens(node, .{});

    // `auditWidgetA11y` rather than the sweep, because the sweep prints its
    // findings, and a test that expects to fail would print a page of teaching
    // voice about a fake tree on every green run.
    const nodes = try arena.alloc(canvas.WidgetLayoutNode, 64);
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, native_sdk.geometry.RectF.init(0, 0, 400, 300), .{}, nodes);
    var findings: [8]canvas.a11y.A11yAuditFinding = undefined;
    const issues = canvas.a11y.auditWidgetA11y(layout, &findings);
    try testing.expect(issues.total > 0);
    try testing.expectEqual(canvas.a11y.A11yAuditRuleKind.duplicate_sibling_label, issues.findings[0].rule);
}

test "the feed rebuilds inside a frame with every account a reader can follow" {
    // The other rebuild benchmark measures a typical list. This one measures the
    // ceiling, because the feed now reads the whole contact list rather than a
    // slice of it (#143), and the number that matters about that decision is
    // what it costs at the top.
    //
    // ReleaseFast only, and skipped rather than relaxed in Debug. A Debug build
    // is roughly six times slower per rebuild and would need a budget six times
    // looser, which would no longer be a frame and would stop meaning anything.
    // It also signs one event per note, and eight thousand Debug signatures is
    // minutes of CI for a number nobody ships.
    if (builtin.mode != .ReleaseFast) return;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{98} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/ceiling.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const follows = main.max_follows;
    const list = try arena.alloc([32]u8, follows);
    for (0..follows) |i| {
        var secret: [32]u8 = undefined;
        @memset(&secret, @intCast((i % 200) + 1));
        secret[31] = @intCast(i & 0xff);
        secret[30] = @intCast((i >> 8) & 0xff);
        const kp = signer.keyPairFromSecretKey(secret) catch continue;
        list[i] = kp.public_key;
        // A profile as well as notes, and the profile is OLDER than the notes,
        // which is the real shape: a bio is written once and posted over ever
        // since. That ordering is what made the profile query walk whole
        // timelines before the store indexed authors and kinds together.
        const meta = try nostr.event.create(arena, signer, kp, 1_799_000_000, 0, &.{}, "{\"name\":\"n\"}", null);
        _ = try store.ingest(arena, meta, .{});
        for (0..4) |n| {
            const body = try std.fmt.allocPrint(arena, "note {d} from {d}", .{ n, i });
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i * 10 + n)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(list, 1_800_000_000);
    try testing.expectEqual(follows, main.followSetForTest().len);

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.feed_limit = 300;
    main.reconcileForTest(model, &store, 1_800_002_000);
    try testing.expect(model.notes_len > 0);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Best of three. The stopwatch runs on a whole machine and nothing is ever
    // subtracted from a reading, so the error is one-sided and the minimum is
    // the closest estimate of the real cost available here.
    var best: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const started = std.Io.Timestamp.now(io, .awake);
        const rounds = 5;
        for (0..rounds) |_| {
            main.invalidateFeedForTest();
            main.reconcileForTest(model, &store, 1_800_002_000);
        }
        const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
        const per = @as(u64, @intCast(@max(elapsed.toNanoseconds(), 0))) / rounds;
        best = @min(best, per);
    }

    const budget_ns = 16 * std.time.ns_per_ms;
    std.debug.print("\n[perf] {d} follows (the ceiling): {d}us per feed rebuild (budget {d}us)\n", .{ follows, best / 1000, budget_ns / 1000 });
    if (best > budget_ns) {
        std.debug.print(
            "\nreading every follow costs {d}us per rebuild against a {d}us frame. The feed rebuilds on a timer, so this is a stutter every second, not a slow benchmark.\n",
            .{ best / 1000, budget_ns / 1000 },
        );
        return error.FeedRebuildTooSlow;
    }
}

test "a long follow list is split across filters that relays accept, in one REQ" {
    // The reason the feed read a slice was the REQ, not the store: a filter
    // naming a few thousand authors is past what several relays take. strfry
    // refuses a filter whose field items exceed 65535 bytes, which is 2047 hex
    // pubkeys, and it is not the only one with a ceiling.
    //
    // So the authors are split across filters and sent together. This asserts
    // the split is lossless, because a subscription that silently drops its tail
    // is exactly the bug the cap was: those people just stop appearing, and
    // nothing anywhere says so.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One past four full chunks, so the last chunk holds a single author: the
    // off-by-one that a loop written for round numbers loses.
    const total = 2001;
    const authors = try arena.alloc([32]u8, total);
    for (authors, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i / 256);
        a[1] = @intCast(i % 256);
        a[31] = 0x5a;
    }

    var buf: [main.max_feed_filters]nostr.filter.Filter = undefined;
    const filters = main.buildFeedFilters(authors, &buf);

    // Two filters per chunk: the notes and the metadata.
    try testing.expectEqual(@as(usize, 10), filters.len);

    // Every author appears exactly once across the note filters, and no filter
    // is wider than a relay will take.
    const seen = try arena.alloc(usize, total);
    @memset(seen, 0);
    var counted: usize = 0;
    for (filters) |f| {
        const list = f.authors.?;
        try testing.expect(list.len <= 500);
        try testing.expect(list.len > 0);
        // Only count the note filters, or every author is seen twice by design.
        if (f.kinds.?.len != 1) continue;
        for (list) |a| {
            const index = @as(usize, a[0]) * 256 + @as(usize, a[1]);
            seen[index] += 1;
            counted += 1;
        }
    }
    try testing.expectEqual(total, counted);
    for (seen, 0..) |n, i| {
        if (n != 1) {
            std.debug.print("\nauthor {d} appears in {d} filters, not 1\n", .{ i, n });
            return error.AuthorLostOrDuplicated;
        }
    }

    // The limit is NOT divided across chunks: each names different people, so
    // splitting it would starve whoever landed last.
    for (filters) |f| {
        if (f.kinds.?.len == 1) try testing.expectEqual(@as(u32, 300), f.limit.?);
    }

    // The metadata limit is derived from the chunk, never from a screen cache.
    //
    // These are replaceable records, so a relay holds at most one of each per
    // author: the right number to ask for is the number of authors times the
    // number of kinds, and anything else is a coincidence. Asserting it because
    // the number that used to be here was `profile_cap`, the size of the
    // in-memory profile table, which permitted a fraction of a chunk and left
    // the rest of those people nameless.
    for (filters) |f| {
        if (f.kinds.?.len == 1) continue;
        try testing.expectEqual(@as(u32, @intCast(f.authors.?.len * 3)), f.limit.?);
    }

    // A list that fits in one chunk is still one chunk, not a special case.
    const few = try arena.alloc([32]u8, 9);
    for (few, 0..) |*a, i| {
        @memset(a, 0);
        a[0] = @intCast(i);
    }
    try testing.expectEqual(@as(usize, 2), main.buildFeedFilters(few, &buf).len);
    // And nobody at all asks nothing, rather than asking about everybody.
    try testing.expectEqual(@as(usize, 0), main.buildFeedFilters(&.{}, &buf).len);
}

test "a relay that keeps dropping is asked less and less often" {
    // The wait doubles from three seconds and stops at five minutes, so a relay
    // that is down, that has stopped taking this reader, or that accepts the
    // handshake and hangs up is not dialled twelve hundred times an hour for as
    // long as the app is open.
    try testing.expectEqual(@as(u64, 3_000), main.reconnectDelayMs(0));
    try testing.expectEqual(@as(u64, 6_000), main.reconnectDelayMs(1));
    try testing.expectEqual(@as(u64, 12_000), main.reconnectDelayMs(2));
    try testing.expectEqual(@as(u64, 96_000), main.reconnectDelayMs(5));
    try testing.expectEqual(@as(u64, 300_000), main.reconnectDelayMs(7));
    // And it stops there rather than growing into hours, or wrapping.
    try testing.expectEqual(@as(u64, 300_000), main.reconnectDelayMs(63));

    // The ladder is cleared by a connection that LASTED, never by one that
    // merely opened. A relay that accepts the socket and drops it immediately
    // is the case this exists for: without the rule its ladder resets on every
    // open and it is redialled at three seconds forever.
    try testing.expectEqual(@as(u6, 1), main.nextReconnectAttempts(0, 1_200));
    try testing.expectEqual(@as(u6, 2), main.nextReconnectAttempts(1, 59_999));
    try testing.expectEqual(@as(u6, 0), main.nextReconnectAttempts(5, 60_000));
    try testing.expectEqual(@as(u6, 0), main.nextReconnectAttempts(63, 3_600_000));
    // A clock that reads backwards must not clear it either.
    try testing.expectEqual(@as(u6, 4), main.nextReconnectAttempts(3, -1));
    // And the count saturates instead of wrapping back to a short wait.
    try testing.expectEqual(@as(u6, 63), main.nextReconnectAttempts(63, 0));
}

test "the latency probe cannot deliver a single event" {
    // The probe exists to time a round trip, and that is ALL it should cost. It
    // used to ask for kind:1 with no author, no since and no until, which is a
    // subscription to every text note the relay receives, from anyone, held open
    // for the life of the connection: every one of those events was parsed,
    // allocated and secp256k1-verified before being thrown away.
    //
    // Asserting the property rather than the wording: whatever the probe asks
    // for, an ordinary note must not match it.
    const filters = main.probeFilters();
    try testing.expectEqual(@as(usize, 1), filters.len);
    const f = filters[0];

    const ev = nostr.event.Event{
        .id = [_]u8{0x9c} ** 32,
        .pubkey = [_]u8{0x11} ** 32,
        .created_at = 1_700_000_000,
        .kind = 1,
        .tags = &.{},
        .content = "an ordinary note",
        .sig = [_]u8{0} ** 64,
    };
    try testing.expect(!f.matches(ev));

    // And it is narrow by construction, not by luck: it names exact ids, so
    // there is no kind, author or time window for anything to arrive through.
    try testing.expect(f.ids != null);
    try testing.expect(f.kinds == null);
    try testing.expect(f.authors == null);
    try testing.expect(f.tags == null);
    // Belt and braces: even a relay that matched it somehow sends one event.
    try testing.expectEqual(@as(u32, 1), f.limit.?);
}

test "every engagement query asks the same bounded question" {
    // Three screens ask for replies, reposts, likes and zaps over a list of note
    // ids. They were three copies and they drifted: the feed's, which is the one
    // re-issued on every reconnect, ended up with no cap at all, so the relay
    // chose how much of four kinds across 128 note ids to send back.
    const values = [_][]const u8{ "a" ** 64, "b" ** 64 };
    const tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = &values }};
    const f = main.engagementFilter(&tags);

    try testing.expect(f.limit != null);
    try testing.expectEqual(@as(u32, 500), f.limit.?);
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 6, 7, 9735 }, f.kinds.?);
    try testing.expectEqual(@as(usize, 1), f.tags.?.len);
    try testing.expectEqual(@as(u8, 'e'), f.tags.?[0].letter);
    try testing.expectEqual(@as(usize, 2), f.tags.?[0].values.len);
}

test "eight relays that drop together do not come back together" {
    // The whole pool goes down on one network blip, so without a spread all
    // eight threads redial in the same millisecond, and keep doing it, forever.
    // Assert the consequence: eight distinct wake-up times, none of them more
    // than a quarter past the wait.
    const wait = main.reconnectDelayMs(0);
    var seen: [8]u64 = undefined;
    for (0..8) |i| {
        const jitter = main.reconnectJitterMs(wait, i, 0);
        try testing.expect(jitter <= wait / 4);
        seen[i] = wait + jitter;
    }
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| {
            if (a == b) return error.RelaysStillInLockstep;
        }
    }

    // Two relays that DID start aligned are separated by the attempt count, so
    // a slot that fails while its neighbour recovers drifts apart from it.
    try testing.expect(main.reconnectJitterMs(wait, 3, 0) != main.reconnectJitterMs(wait, 3, 1));
}

test "the window cannot be declared smaller than its own floor" {
    // Both numbers come from app.zon now, so they cannot drift apart in the
    // source. They can still be declared inconsistently IN the manifest, and a
    // startup size below the floor is a window that opens smaller than it is
    // allowed to be dragged, which is the same class of mistake as the floor
    // sitting seven pixels under what the layout needs (#138).
    try testing.expect(main.window_width >= main.window_min_width);

    // And they are real numbers, not a silently defaulted zero. A parse that
    // quietly returned 0 would satisfy the comparison above and make the
    // overflow sweep measure an empty window.
    try testing.expect(main.window_min_width > 0);
    try testing.expect(main.window_width > 0);
    try testing.expect(main.window_height > 0);
}

test "the feed has no bottom: it holds more notes than the old cap" {
    // The feed stopped at three hundred, and nothing about the rendering needed
    // that: the list is windowed, so what is held costs memory rather than
    // frames. The number was the size of a fixed array, and a reader who paged
    // to the end of it found the feed simply ended.
    //
    // Six hundred here, which is only meaningful because it is past the number
    // that used to be the ceiling.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    main.setIdentityForTest([_]u8{0x5b} ** 32);
    defer main.clearIdentityForTest();
    main.forgetFollowsForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/deep.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const wanted = 600;
    var author: [32]u8 = undefined;
    {
        var secret: [32]u8 = [_]u8{0x2c} ** 32;
        const kp = try signer.keyPairFromSecretKey(secret);
        author = kp.public_key;
        secret[0] = 0;
        var i: usize = 0;
        while (i < wanted) : (i += 1) {
            const body = try std.fmt.allocPrint(arena, "note number {d}", .{i});
            const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 1, &.{}, body, null);
            _ = try store.ingest(arena, ev, .{});
        }
    }
    _ = main.setFollowsForTest(&[_][32]u8{author}, 1_800_000_000);

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;

    // Page down the way a reader does, rather than setting the limit in one
    // jump: this is also what proves the storage GROWS instead of being sized
    // once at the top.
    while (model.notes_len < wanted) {
        const before = model.notes_len;
        main.loadOlderForTest(model);
        main.invalidateFeedForTest();
        main.reconcileForTest(model, &store, 1_800_001_000);
        if (model.notes_len == before) break;
    }

    try testing.expectEqual(@as(usize, wanted), model.notes_len);
    try testing.expect(model.notes_len > 300);

    // Every row is a distinct note, newest first. A growth that re-pointed the
    // slice wrongly, or a reuse table that collided, would show up here as a
    // repeat rather than as a crash.
    var seen = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen.deinit();
    for (model.notes[0..model.notes_len]) |note| {
        try testing.expect(!seen.contains(note.id));
        try seen.put(note.id, {});
    }
}

test "the composer holds a whole announcement, and says when it will not" {
    // 512 bytes was the old capacity, and an ordinary announcement is longer
    // than that. Pasting one came back cut mid-sentence with nothing on screen
    // admitting it, while the footer read "no length limit". The note this test
    // uses is the real one: at 512 it lost the end of its own URL, so the post
    // would have carried a dead link.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    const note =
        "Plaza is out.\n\nA Nostr client for macOS written in Zig. No Electron, no WebView, no " ++
        "browser hiding in the binary. The toolkit draws every pixel.\n\nThe feed is a local " ++
        "query. It renders from disk before the network answers, and a 500 note feed query is " ++
        "0.28ms against 100k stored events.\n\nYour key can stay out of it entirely: sign through " ++
        "Notary over NIP-46 and the client never sees it.\n\nEarly, and honest about it. No DMs, " ++
        "no zaps, no search yet. Those are the next milestones and they are public.\n\n" ++
        "https://zignostr.com/plaza";
    try testing.expect(note.len > 512);

    model.draft_buffer = @TypeOf(model.draft_buffer).init(note);
    try testing.expectEqualStrings(note, model.draft());

    // The tail is the part that used to go missing, and the part whose loss is
    // hardest to notice: a URL that still looks like a URL.
    try testing.expect(std.mem.endsWith(u8, model.draft(), "https://zignostr.com/plaza"));
}

test "the note field states its own width" {
    // A text element measures at its natural width whatever its ancestors say,
    // so a field that inherits width from a `grow` parent wraps for LAYOUT at
    // one width and measures for PAINT at another. Two wrappings of the same
    // paragraph then land on the same rows, which is what shredded a pasted
    // note on screen.
    //
    // The rule this holds is not "the number is 498". It is that the field
    // carries a definite width of its own, and that the number agrees with the
    // box it sits in.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x5c} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(
        "A paragraph long enough to wrap more than once in the composer, " ++
            "followed by another one.\n\nAnd a second paragraph, so the field has " ++
            "several source lines to lay out and not merely several visual ones.",
    );

    const p = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);
    var found = false;
    for (p.layout.nodes) |n| {
        if (n.widget.kind != .textarea) continue;
        found = true;
        // The frame the engine gave it, against the width the app asked for.
        try testing.expectApproxEqAbs(main.compose_editor_width_for_test, n.widget.frame.width, 1.0);
    }
    try testing.expect(found);
}

test "the thread's reply box takes more than one line" {
    // A reply used to be a 34pt pill, which is a shape that can only hold one
    // line. People answer notes with paragraphs, so the box has to be a
    // `textarea`: that is the widget where Enter inserts a newline and the
    // primary chord submits, while a `text_field` submits on Enter instead.
    //
    // What this pins is the pair, not the number. The reply box is the widget
    // kind that can hold a newline, and it is tall enough to show more than one
    // line of it. A regression to `text_field` fails on the kind; a regression
    // to a one-line box fails on the frame.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    main.setIdentityForTest([_]u8{0x71} ** 32);
    defer main.clearIdentityForTest();

    const model = try arena.create(main.Model);
    model.* = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    model.thread_root.id = 1;

    const p = try painted.Painted.renderAt(arena, model, main.window_width, main.window_height);

    var reply: ?@TypeOf(p.layout.nodes[0].widget) = null;
    for (p.layout.nodes) |n| {
        if (!std.mem.startsWith(u8, n.widget.placeholder, "Reply to")) continue;
        reply = n.widget;
    }
    // Found by its own placeholder, so this cannot pass on some other editor
    // that happens to be on screen.
    try testing.expect(reply != null);
    try testing.expectEqual(canvas.WidgetKind.textarea, reply.?.kind);
    try testing.expectApproxEqAbs(main.reply_editor_height_for_test, reply.?.frame.height, 1.0);
    // Two lines of room at minimum, or "multiline" is a claim the layout does
    // not honour whatever the widget kind says.
    try testing.expect(reply.?.frame.height > 34);
}

/// Finds the first tag whose name is `name`, or null.
fn tagNamed(tags: []const nostr.event.Tag, name: []const u8) ?nostr.event.Tag {
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) return t;
    }
    return null;
}

fn countTags(tags: []const nostr.event.Tag, name: []const u8) usize {
    var n: usize = 0;
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) n += 1;
    }
    return n;
}

test "a note carries the tags its own text implies" {
    // The composer used to publish kind:1 with a literally empty tag array, so a
    // hashtag was violet text that no relay filter could find, a picked mention
    // notified nobody, and an image URL arrived with no imeta for a client to
    // lay out. Everything here is derived from the finished string at publish.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "shipping #Nostr today, see https://example.com/a.png");
    const t = tagNamed(tags, "t") orelse return error.NoTopicTag;
    // NIP-24 is a MUST on the value being lowercase, so the as-typed "#Nostr"
    // has to arrive folded or a relay filter for "nostr" never matches it.
    try testing.expectEqualStrings("nostr", t[1]);

    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expectEqualStrings("url https://example.com/a.png", im[1]);
    // One space between key and value, and a reader splits on the FIRST space
    // only, because a value may contain spaces of its own.
    try testing.expectEqualStrings("m image/png", im[2]);
}

test "a hash inside a URL is not a hashtag" {
    // The scanner consumes a URL run whole before it looks for a '#'. Without
    // that ordering every link with a fragment publishes a junk topic, which is
    // a bug both reference clients still have.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "see https://example.com/guide#installation for the steps");
    try testing.expectEqual(@as(usize, 0), countTags(tags, "t"));
}

test "topics fold and dedupe, and a non-ASCII one stays whole" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    // Case-folded BEFORE the duplicate check, or "#Nostr #nostr" ships twice.
    const dedup = main.contentTagsForTest(gpa, "#Nostr and #nostr and #NOSTR");
    try testing.expectEqual(@as(usize, 1), countTags(dedup, "t"));

    // The old predicate was ASCII-only, so this emitted a truncated "caf".
    const unicode = main.contentTagsForTest(gpa, "#café");
    const t = tagNamed(unicode, "t") orelse return error.NoTopicTag;
    try testing.expectEqualStrings("café", t[1]);
}

test "a mention becomes a p tag, and a bare hash does not become anything" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x2a;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    const body = try std.fmt.allocPrint(gpa, "thanks nostr:{s} for the help", .{npub});

    const tags = main.contentTagsForTest(gpa, body);
    const p = tagNamed(tags, "p") orelse return error.NoMentionTag;
    // Lowercase 64-hex, which is what NIP-01 requires of a pubkey in a tag.
    try testing.expectEqual(@as(usize, 64), p[1].len);
    try testing.expect(std.mem.startsWith(u8, p[1], "2a00"));

    // A '#' with nothing word-like after it is punctuation, not a topic.
    const bare = main.contentTagsForTest(gpa, "the # sign, and #!/bin/sh");
    try testing.expectEqual(@as(usize, 0), countTags(bare, "t"));
}

test "one long paste yields the same tags as the same text typed" {
    // The parse runs over the finished content at publish, never over
    // keystrokes, so there is no separate paste path that could drift from the
    // typing one. This pins that: everything at once, in one string, the way a
    // paste arrives.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x7f;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    var eid = [_]u8{0} ** 32;
    eid[0] = 0xc3;
    const nevent = try nostr.nip19.encodeNevent(gpa, eid, &.{}, null, 1);

    const pasted = try std.fmt.allocPrint(gpa,
        \\A long note pasted in one go, the way anything real arrives.
        \\
        \\It mentions nostr:{s}, quotes nostr:{s}, links
        \\https://example.com/docs#section which must NOT become a topic, shows
        \\https://example.com/shot.jpg and repeats https://example.com/shot.jpg,
        \\and tags #Zig and #zig and #buildinpublic.
    , .{ npub, nevent });

    const tags = main.contentTagsForTest(gpa, pasted);
    // #zig folded and deduped against #Zig, plus #buildinpublic. The URL
    // fragment contributes nothing.
    try testing.expectEqual(@as(usize, 2), countTags(tags, "t"));
    try testing.expectEqual(@as(usize, 1), countTags(tags, "q"));
    // The same picture twice is still one picture.
    try testing.expectEqual(@as(usize, 1), countTags(tags, "imeta"));
    // The mention. The quoted nevent carries no author, so it adds no second p:
    // slot 4 is a notification target and a guess there tells the wrong person.
    try testing.expectEqual(@as(usize, 1), countTags(tags, "p"));

    const q = tagNamed(tags, "q") orelse return error.NoQuoteTag;
    try testing.expectEqual(@as(usize, 64), q[1].len);
}

test "the composer actually attaches the tags to the event it publishes" {
    // The parser being right is half of it. This pins the other half: that
    // `submitPost` calls it at all. A correct `contentTags` that nobody invokes
    // publishes exactly the empty tag array this whole change exists to fix,
    // and every other seam here stops short of the event that goes out.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x33} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("first light on #Nostr with https://example.com/x.jpg");
    try testing.expect(main.submitPostForTest(&model, &fx));

    const tags = main.lastPublishedTagsForTest();
    const t = tagNamed(tags, "t") orelse return error.TagsNeverReachedTheEvent;
    try testing.expectEqualStrings("nostr", t[1]);
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaOnEvent;
    try testing.expectEqualStrings("url https://example.com/x.jpg", im[1]);
}

test "a github raw link is canonicalised so the picture actually renders" {
    // github.com/<owner>/<repo>/raw/<path> is a 302 whose own response is
    // content-type text/html, so clients that check the type before inlining
    // refuse to draw it and the note lands as text with a link in it. The
    // raw.githubusercontent.com form serves the same bytes as image/jpeg.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x44} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    var fx: main.EffectsForTest = undefined;
    model.draft_buffer.set("shipping https://github.com/zig-nostr/plaza/raw/main/docs/shots/hero.jpg");
    try testing.expect(main.submitPostForTest(&model, &fx));

    // The imeta names the rewritten URL, which is only correct if the content
    // was rewritten too: NIP-92 pairs the tag with a URL in the content.
    const im = tagNamed(main.lastPublishedTagsForTest(), "imeta") orelse return error.NoImetaTag;
    try testing.expectEqualStrings(
        "url https://raw.githubusercontent.com/zig-nostr/plaza/main/docs/shots/hero.jpg",
        im[1],
    );
    try testing.expectEqualStrings("m image/jpeg", im[2]);
}

test "an ordinary github link is left alone" {
    // The rewrite is one host and one path shape. A repo link is not a raw
    // link, and editing what somebody typed is only defensible where the two
    // forms are the identical file.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const tags = main.contentTagsForTest(gpa, "the source is at https://github.com/zig-nostr/plaza");
    // No image extension, so no imeta, and nothing here to rewrite either.
    try testing.expectEqual(@as(usize, 0), countTags(tags, "imeta"));
}

test "a nostr mention inside a URL path is not a mention" {
    // The prefixed form had no boundary check, so a path segment that happens
    // to read `nostr:npub1…` parsed as a mention. Harmless while nothing was
    // tagged; a notification to a stranger now that mentions become p tags.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var pk = [_]u8{0} ** 32;
    pk[0] = 0x5b;
    const npub = try nostr.nip19.encodeNpub(gpa, pk);
    const body = try std.fmt.allocPrint(gpa, "see https://example.com/nostr:{s} for details", .{npub});

    const tags = main.contentTagsForTest(gpa, body);
    try testing.expectEqual(@as(usize, 0), countTags(tags, "p"));
}

test "a reply reaches everyone already in the thread" {
    // A reply that tags only the person being answered is one the rest of the
    // conversation never hears about, so they answer into a thread that has
    // moved on. Amethyst p-tags every author in the thread plus the parent's
    // own mentions; Jumble the parent author plus the parent's p tags. This is
    // the authors, which is the part Plaza retains.
    var model = main.initialModel();
    model.stage = .ready;
    model.viewing_thread = 1;
    main.setIdentityForTest([_]u8{0x66} ** 32);
    defer main.clearIdentityForTest();
    main.clearLastPublishedTagsForTest();

    model.thread_root.id = 1;
    model.thread_root.event_id = [_]u8{0xa1} ** 32;
    model.thread_root.pubkey = [_]u8{0xb2} ** 32;

    // Two other people in the thread, one of them twice, plus the root author
    // again and the replier themselves. Only the two distinct others are new.
    // The replier's own key is the DERIVED pubkey, not the secret handed to
    // setIdentityForTest. Planting the secret's bytes here would leave the
    // self-filter untested while the test still looked like it covered it.
    const mine = main.activePubkeyForTest() orelse return error.NoIdentity;
    const others = [_][32]u8{
        [_]u8{0xc3} ** 32,
        [_]u8{0xd4} ** 32,
        [_]u8{0xc3} ** 32,
        [_]u8{0xb2} ** 32,
        mine,
    };
    for (others, 0..) |pk, i| {
        model.thread_notes[i] = .{ .created_at = 1_800_000_000 };
        model.thread_notes[i].id = @intCast(700 + i);
        model.thread_notes[i].pubkey = pk;
    }
    model.thread_notes_len = others.len;

    var fx: main.EffectsForTest = undefined;
    model.reply_buffer.set("agreed, and one more thing");
    main.update(&model, main.Msg.reply_submit, &fx);

    const tags = main.lastPublishedTagsForTest();
    // The root author plus the two distinct others. Not the duplicate, not the
    // root author twice, and never the replier: your own inbox lighting up for
    // your own reply is a bug a reader would report as one.
    try testing.expectEqual(@as(usize, 3), countTags(tags, "p"));

    var mine_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&mine_hex, "{x}", .{&mine}) catch unreachable;
    var saw_self = false;
    var saw_root = false;
    for (tags) |t| {
        if (t.len < 2 or !std.mem.eql(u8, t[0], "p")) continue;
        if (std.mem.eql(u8, t[1], &mine_hex)) saw_self = true;
        if (std.mem.startsWith(u8, t[1], "b2b2")) saw_root = true;
    }
    try testing.expect(saw_root);
    try testing.expect(!saw_self);
}

test "switching somebody off keeps them out of the note" {
    // The chips promise they name exactly who gets tagged. That only holds if
    // the row the reader sees and the tags the event carries come from one
    // derivation, and if switching a name off actually reaches the publish path.
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var one = [_]u8{0} ** 32;
    one[0] = 0x11;
    var two = [_]u8{0} ** 32;
    two[0] = 0x22;
    const npub_one = try nostr.nip19.encodeNpub(gpa, one);
    const npub_two = try nostr.nip19.encodeNpub(gpa, two);
    const body = try std.fmt.allocPrint(gpa, "nostr:{s} and nostr:{s}", .{ npub_one, npub_two });

    // Both are derived, and the chips are built from this same call.
    var people: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), main.notifiedByForTest(body, &people));

    model.draft_buffer.set(body);
    main.clearLastPublishedTagsForTest();
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expectEqual(@as(usize, 2), countTags(main.lastPublishedTagsForTest(), "p"));

    // Switch the first one off and post again. One tag, and it is the other.
    model.composing = true;
    model.draft_buffer.set(body);
    main.update(&model, main.Msg{ .toggle_mention_off = one }, &fx);
    main.clearLastPublishedTagsForTest();
    try testing.expect(main.submitPostForTest(&model, &fx));

    const tags = main.lastPublishedTagsForTest();
    try testing.expectEqual(@as(usize, 1), countTags(tags, "p"));
    const p = tagNamed(tags, "p") orelse return error.NoMentionTag;
    try testing.expect(std.mem.startsWith(u8, p[1], "2200"));

    // Pressing it again puts them back: the chip is a toggle, not a delete.
    model.composing = true;
    model.draft_buffer.set(body);
    main.update(&model, main.Msg{ .toggle_mention_off = one }, &fx);
    main.clearLastPublishedTagsForTest();
    try testing.expect(main.submitPostForTest(&model, &fx));
    try testing.expectEqual(@as(usize, 2), countTags(main.lastPublishedTagsForTest(), "p"));
}

test "a reply whose parent is missing says so instead of posing as a direct reply" {
    // Three different things used to render identically: a genuine direct reply
    // to the root, a reply tagged to the root, and a reply that names a parent
    // nobody has. The third asserted it answered the opening note, which is a
    // claim about the conversation that nothing in the event supports.
    //
    // Taken from a real thread: two replies named parents that returned nothing
    // from damus, nos.lol, primal and nostr.band, and both drew as first-level
    // replies to a note they were not answering.
    const root_id = [_]u8{0xa0} ** 32;

    var notes: [3]main.Note = .{ .{}, .{}, .{} };
    // A direct reply: names the root.
    notes[0].event_id = [_]u8{0xb1} ** 32;
    notes[0].created_at = 1_800_000_001;
    notes[0].reply_parent = root_id;
    notes[0].has_reply_parent = true;
    // A reply to that one, whose parent IS in the set.
    notes[1].event_id = [_]u8{0xb2} ** 32;
    notes[1].created_at = 1_800_000_002;
    notes[1].reply_parent = notes[0].event_id;
    notes[1].has_reply_parent = true;
    // An orphan: names a parent that is nowhere in the set.
    notes[2].event_id = [_]u8{0xb3} ** 32;
    notes[2].created_at = 1_800_000_003;
    notes[2].reply_parent = [_]u8{0xcc} ** 32;
    notes[2].has_reply_parent = true;

    main.arrangeThread(&notes, root_id);

    var direct: ?*main.Note = null;
    var nested: ?*main.Note = null;
    var orphan: ?*main.Note = null;
    for (&notes) |*note| {
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb1} ** 32)) direct = note;
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb2} ** 32)) nested = note;
        if (std.mem.eql(u8, &note.event_id, &[_]u8{0xb3} ** 32)) orphan = note;
    }

    // The orphan still sits at the top level, because there is nowhere better,
    // but it is no longer indistinguishable from a real first-level reply.
    try testing.expectEqual(@as(u8, 1), orphan.?.depth);
    try testing.expect(orphan.?.parent_missing);

    // And neither of the honest ones is marked.
    try testing.expectEqual(@as(u8, 1), direct.?.depth);
    try testing.expect(!direct.?.parent_missing);
    try testing.expectEqual(@as(u8, 2), nested.?.depth);
    try testing.expect(!nested.?.parent_missing);
}

test "a wanted profile is never silently dropped, however many are wanted" {
    // The old table held 48 and, once full, looked for a slot already asked the
    // maximum number of times. Finding none it fell off the end of the function
    // having queued nothing at all. With 144 notifications that is what it did
    // every time, which is why a name only ever appeared after visiting that
    // person's profile: visiting asks for one pubkey, so it survived the churn.
    //
    // No shipping client caps authors here. NDK merges them with no limit at
    // all; Amethyst rebuilds one REQ from every name currently on screen.
    main.resetWantedProfilesForTest();

    const many = 300;
    var i: usize = 0;
    while (i < many) : (i += 1) {
        var pk = [_]u8{0} ** 32;
        pk[0] = @intCast(i % 251);
        pk[1] = @intCast(i / 251);
        pk[2] = @intCast(i % 7 + 1);
        main.wantProfileForTest(pk);
    }

    // Every distinct key asked for is still being asked for. The exact count is
    // not the point: that none of them vanished is.
    try testing.expect(main.wantedProfileCountForTest() >= 200);
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

test "a tag copy that could not complete reads as no base, not as an empty one" {
    // The splice base for every replaceable write comes through `dupeTags`, and
    // the writes decide how much to keep by counting what is in it. An empty
    // slice is a true answer for a record with no tags and a destructive one for
    // a copy that ran short: the follow list's shrink guard compares against
    // this same slice, so zero to one reads as growth and passes.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const tags = [_]nostr.event.Tag{
        &.{ "p", "aa" ** 32 },
        &.{ "p", "bb" ** 32 },
    };

    // Enough memory: the copy is whole and every field survives.
    const ok = main.dupeTagsForTest(a.allocator(), &tags) orelse return error.CopyRefusedWithMemoryAvailable;
    try testing.expectEqual(@as(usize, 2), ok.len);
    try testing.expectEqualStrings("p", ok[0][0]);

    // Not enough: null, so the caller takes its store-miss path. Anything that
    // returned a short or empty slice here would be reported as a real base.
    var failing = testing.FailingAllocator.init(a.allocator(), .{ .fail_index = 1 });
    try testing.expect(main.dupeTagsForTest(failing.allocator(), &tags) == null);
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

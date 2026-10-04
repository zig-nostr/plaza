const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("main.zig");
const painted = @import("painted.zig");
const long_form = @import("article.zig");
const theme = @import("theme.zig");
const tests_addresses = @import("tests/addresses.zig");
const tests_bookmarks = @import("tests/bookmarks.zig");
const tests_compose = @import("tests/compose.zig");
const tests_drafts = @import("tests/drafts.zig");
const tests_engagement = @import("tests/engagement.zig");
const tests_feed_media = @import("tests/feed_media.zig");
const tests_feed_state = @import("tests/feed_state.zig");
const tests_follows = @import("tests/follows.zig");
const tests_hiding = @import("tests/hiding.zig");
const tests_image_cache = @import("tests/image_cache.zig");
const tests_image_pool = @import("tests/image_pool.zig");
const tests_inbox = @import("tests/inbox.zig");
const tests_ingest = @import("tests/ingest.zig");
const tests_keyholder = @import("tests/keyholder.zig");
const tests_link_preview = @import("tests/link_preview.zig");
const tests_links = @import("tests/links.zig");
const tests_login = @import("tests/login.zig");
const tests_media_servers = @import("tests/media_servers.zig");
const tests_mutes = @import("tests/mutes.zig");
const tests_navigation = @import("tests/navigation.zig");
const tests_note_build = @import("tests/note_build.zig");
const tests_outbox = @import("tests/outbox.zig");
const tests_own_lists = @import("tests/own_lists.zig");
const tests_own_profile = @import("tests/own_profile.zig");
const tests_people_search = @import("tests/people_search.zig");
const tests_places = @import("tests/places.zig");
const tests_prefs = @import("tests/prefs.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

/// Builds the real view for `model`: the same root the app runs, so a test sees
/// the markup screens (compiled in) and the hand-written feed exactly as shipped.
pub fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    // The app's own icon table, installed the same way `main` installs it, so a
    // test tree draws Plaza's glyphs rather than the missing-icon fallback.
    main.registerIcons();
    var ui = AppUi.init(arena);
    const node = main.appView(&ui, model);
    if (ui.failed) return error.ViewBuild;
    return ui.finalize(node);
}

pub fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// How many note rows the tree actually built (the windowed list materialises
/// only the rows near the viewport). Each note row has exactly one avatar, so
/// avatars are the stable per-row marker now that the rows are not cards.
pub fn countNoteRows(widget: canvas.Widget) usize {
    var n: usize = if (widget.kind == .avatar) 1 else 0;
    for (widget.children) |child| n += countNoteRows(child);
    return n;
}

/// Like `findByText`, but matches on text content regardless of widget kind.
pub fn findAnyText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findAnyText(child, text)) |found| return found;
    }
    return null;
}

/// Whether any widget's text CONTAINS this needle (span-joined paragraphs).
/// The first text in the tree containing `needle`, so a test can assert about
/// the string itself rather than only its presence.
pub fn findAnyTextContainingText(widget: canvas.Widget, needle: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return widget.text;
    for (widget.children) |child| {
        if (findAnyTextContainingText(child, needle)) |found| return found;
    }
    return null;
}

pub fn findAnyTextContaining(widget: canvas.Widget, needle: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return true;
    for (widget.children) |child| {
        if (findAnyTextContaining(child, needle)) return true;
    }
    return false;
}

/// How many widgets the tree holds, which is what the view budget counts.
pub fn countNodes(widget: canvas.Widget) usize {
    var n: usize = 1;
    for (widget.children) |child| n += countNodes(child);
    return n;
}

/// How many widgets carry this exact label. A row count, when the rows are
/// alike: `findByLabel` says one exists, this says how many were built.
pub fn countByLabel(widget: canvas.Widget, label: []const u8) usize {
    var n: usize = if (std.mem.eql(u8, widget.semantics.label, label)) 1 else 0;
    for (widget.children) |child| n += countByLabel(child, label);
    return n;
}

/// The frame of the first widget carrying this exact text.
pub fn frameOfText(p: painted.Painted, text: []const u8) ?native_sdk.geometry.RectF {
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
pub fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
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
/// Whether a filter is one of the feed's note filters rather than a metadata one.
///
/// By whether it asks for kind 1, not by how many kinds it names. It used to be
/// `kinds.len == 1`, which stopped meaning anything the moment the feed asked
/// for reposts as well: the notes filter names three kinds now and the metadata
/// filters name several, so counting them tells the two apart by accident.
pub fn isNotesFilter(f: nostr.filter.Filter) bool {
    for (f.kinds orelse return false) |k| {
        if (k == 1) return true;
    }
    return false;
}

pub fn signedNote(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, created_at: i64, content: []const u8) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, 1, &.{}, content, null);
}

/// A signed event of any kind, with tags. `signedNote` is the kind-1 case.
pub fn signedKind(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    created_at: i64,
    kind: u16,
    tags: []const nostr.event.Tag,
    content: []const u8,
) !nostr.event.Event {
    return nostr.event.create(arena, signer, kp, created_at, kind, tags, content, null);
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

test "the settings screen shows the identity, the way to the signer, and logout" {
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
    try testing.expect(findAnyText(tree.root, "Signing via Notary") != null);
    try testing.expect(findAnyText(tree.root, "Edit profile") != null);
    try testing.expect(findAnyText(tree.root, "Copy npub") != null);
    // The key is NOT offered here, and that is the point. Backing it up happens
    // in the signer's own window, which is the process that holds it: Plaza
    // showing a key would be Plaza holding one. What this screen owes the
    // reader is the way to that window.
    try testing.expect(findAnyText(tree.root, "Reveal secret key") == null);
    // The way to that window is the "Open Notary" link on the signer row, which
    // needs both a keyholder holding the key and the window binary beside the
    // app. Neither is true of a bare test model, so its presence is not asserted
    // here; its absence from THIS screen is the property that matters.
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
    // No underline: an in-text URL is coloured and nothing more. This used to
    // assert only the REQUEST, because the renderer drew a rule under any span
    // carrying a link payload regardless. SDK 0.9.2 made the flag authoritative,
    // so the request and the pixels are the same claim again.
    try testing.expect(!spans[3].underline);
    // Plain text has no link payload.
    try testing.expectEqual(@as(usize, 0), spans[0].link.len);
}

test "a hashtag takes the identity violet only when it carries where it goes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());

    const spans = main.contentSpans(&ui, "gm #Nostr build C# code #zig!");
    try testing.expectEqual(@as(usize, 5), spans.len);
    try testing.expectEqualStrings("#Nostr", spans[1].text);
    // The identity violet, the same as a mention and a link: it opens its topic,
    // so it is coloured like the other runs that go somewhere.
    try testing.expect(spans[1].color != null and spans[1].color.? == .info);
    // And it goes somewhere now. The payload is lowercased, because
    // `contentTags` lowercases on the way out, so `#Nostr` and `#nostr` have to
    // be one topic in both directions.
    const topic = main.topicLinkValueForTest(spans[1].link) orelse return error.HashtagCarriesNoTopic;
    try testing.expectEqualStrings("nostr", topic);

    try testing.expectEqualStrings(" build C# code ", spans[2].text); // C# is not a tag
    try testing.expectEqualStrings("#zig", spans[3].text);
    try testing.expectEqualStrings("!", spans[4].text); // trailing punctuation stays plain

    // A web link keeps its own payload, so widening the channel did not put a
    // topic where a URL belongs.
    const links = main.contentSpans(&ui, "see https://example.com/x");
    try testing.expectEqual(@as(?[]const u8, null), main.topicLinkValueForTest(links[1].link));

    // A tag longer than a topic can be carries no payload, so it must not wear
    // the colour that says "press me": violet on a run that does nothing.
    const long_tag = "#" ++ "a" ** 65;
    const long = main.contentSpans(&ui, "see " ++ long_tag ++ " ok");
    try testing.expectEqual(@as(usize, 3), long.len);
    try testing.expectEqualStrings(long_tag, long[1].text);
    try testing.expectEqual(@as(usize, 0), long[1].link.len);
    try testing.expect(long[1].color == null or long[1].color.? != .info);
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

    const cap = main.image_registry_slots;
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
    try testing.expect(after >= 1 and after <= main.image_registry_slots);
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

/// The words on the Back control of whichever level is open, or null if there is
/// none on screen.
pub fn backText(root: canvas.Widget) ?[]const u8 {
    const back = findByLabel(root, "Back") orelse return null;
    var last: ?[]const u8 = null;
    for (back.children) |child| {
        if (child.text.len > 0) last = child.text;
    }
    return last;
}

test "Back names where it actually goes, from every place a level opens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.setIdentityForTest([_]u8{0x7d} ** 32);
    defer {
        main.clearIdentityForTest();
        main.setStoreForTest(null);
    }

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x7e} ** 32);
    const ev = try signedNote(arena, signer, kp, 1_800_000_000, "a note someone replied to");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/back.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    _ = try store.ingest(arena, ev, .{});
    main.setStoreForTest(&store);

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(ev, 1_800_000_100);
    model.notes_len = 1;
    const id = model.notes[0].id;
    var fx: main.EffectsForTest = undefined;
    const feed = model.scope_name();

    // From the feed, Back goes to the feed.
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);

    // From a row in Notifications, a thread's Back goes to Notifications. It
    // used to name the feed and then land on the sheet.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_event = ev.id }, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);

    // And so does a person's page opened from there.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);

    // Once the reader goes deeper, Back names the level it returns to, not the
    // sheet. A thread opened from the feed, then its author's page: Back from
    // the page lands on the thread.
    main.update(&model, .close_notifications, &fx);
    main.update(&model, Msg{ .open_thread = id }, &fx);
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    try testing.expectEqualStrings(model.thread_stack[0].note.author(), backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);

    // A topic names itself the way its own header does, and the bookmark list
    // by its title.
    var topic_level = main.Screen{ .topic_len = 3 };
    @memcpy(topic_level.topic_buf[0..3], "zig");
    try testing.expectEqualStrings("#zig", topic_level.backLabel(arena));
    try testing.expectEqualStrings("Bookmarks", (main.Screen{ .bookmarks = true }).backLabel(arena));

    // Deeper from the sheet: a thread opened from a row, then its author, then
    // Back. That is the thread again, and its Back is still the sheet, because
    // the walk into the author's page did not start from the feed.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_event = ev.id }, &fx);
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(id, model.viewing_thread);
    try testing.expectEqualStrings("Notifications", backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.notifications_open);
    main.update(&model, .close_notifications, &fx);

    // A visit to Notifications that never got back to the sheet (the reader went
    // Home instead) must not turn the next ordinary thread into a way back to it.
    model.notifications_open = true;
    main.update(&model, Msg{ .open_person = ev.pubkey }, &fx);
    main.goHomeForTest(&model);
    main.update(&model, Msg{ .open_thread = id }, &fx);
    try testing.expectEqualStrings(feed, backText((try buildTree(arena, &model)).root).?);
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(!model.notifications_open);
}

test "a reply half written in a thread is still there when the reader comes back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.setIdentityForTest([_]u8{0x7f} ** 32);
    defer main.clearIdentityForTest();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x80} ** 32);
    const first = try signedNote(arena, signer, kp, 1_800_000_000, "the first note");
    const second = try signedNote(arena, signer, kp, 1_800_000_100, "the second note");

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteFrom(first, 1_800_000_200);
    model.notes[1] = main.noteFrom(second, 1_800_000_200);
    model.notes_len = 2;
    const a = model.notes[0].id;
    const b = model.notes[1].id;
    var fx: main.EffectsForTest = undefined;

    // Back to the feed and in again: the sentence is where the reader left it.
    main.update(&model, Msg{ .open_thread = a }, &fx);
    model.reply_buffer.set("I was about to say");
    main.update(&model, Msg.close_thread, &fx);
    try testing.expect(model.reply_empty());
    main.update(&model, Msg{ .open_thread = a }, &fx);
    try testing.expectEqualStrings("I was about to say", model.reply_draft());

    // It belongs to that thread. Another one opens with an empty box, and its own
    // draft is kept apart.
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());
    model.reply_buffer.set("and over here");
    // Back from the second thread lands on the first, and its box is full again.
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqual(a, model.viewing_thread);
    try testing.expectEqualStrings("I was about to say", model.reply_draft());
    main.update(&model, Msg.close_thread, &fx);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());

    // A person's page in between, and Home, keep it as well.
    main.update(&model, Msg{ .open_person = first.pubkey }, &fx);
    try testing.expect(model.reply_empty());
    main.update(&model, Msg.close_thread, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());
    main.goHomeForTest(&model);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expectEqualStrings("and over here", model.reply_draft());

    // Emptying the box on purpose is also a draft: nothing comes back.
    model.reply_buffer.clear();
    main.update(&model, Msg.close_thread, &fx);
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());

    // Signing out takes every kept reply with it, as it does the open one.
    model.reply_buffer.set("private thinking");
    main.update(&model, Msg.close_thread, &fx);
    main.performLogoutForTest(&model, &fx);
    main.setIdentityForTest([_]u8{0x7f} ** 32);
    model.notes[1] = main.noteFrom(second, 1_800_000_200);
    model.notes_len = 2;
    main.update(&model, Msg{ .open_thread = b }, &fx);
    try testing.expect(model.reply_empty());
}

/// A thread root with nothing behind it but its id, for tests of the level
/// bookkeeping that never read a reply.
pub fn bareRoot(byte: u8) main.Note {
    var note = main.Note{ .id = @as(i64, byte) + 1000, .created_at = 1_800_000_000 };
    note.event_id = [_]u8{byte} ** 32;
    return note;
}

test "a fresh draft is empty and disables Post" {
    var model = main.initialModel();
    try testing.expect(model.draft_empty());
    try testing.expectEqualStrings("", model.draft());
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
    var fx_scan: main.EffectsForTest = undefined;
    try testing.expect(model.draft_empty());
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("my precious note", model.draft());
    try testing.expect(main.remoteSignNoticeForTest());

    // The slot is retired: a late response for it now finds nothing.
    try testing.expect(main.takePendingContentForTest("req-x") == null);
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

// ---- C2: bunker connect states ----------------------------------------------

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

pub fn threadNote(event_byte: u8, created_at: i64, parent_byte: u8) main.Note {
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
        // The NESTED unit: an ancestor's body is set one register down, and
        // that register is now boxed at the height it draws rather than at a
        // full body line.
        const priced = main.ancestor_top_pad + main.ancestor_row_chrome_for_test +
            @as(f32, @floatFromInt(One.a.lines)) * main.nested_line_height;
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
            return main.replyBlockForTest(ui, &block, [_]u8{0} ** 32, true, true);
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

test "a quoted note's time is right aligned like every other" {
    // Spotted in a screenshot: the "1d" in a quote card sat well short of the
    // card's right edge. The card's header row had no grow between the name and
    // the time, so the time was placed wherever the name left it. That is LEFT
    // alignment, and it shows because the right edge then moves with the width
    // of the text: two cards an hour apart ended seven points apart.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two quotes whose times render at different widths ("2h" and "12h"), which
    // is what tells left alignment from right.
    // The app's clock reads 0 without an `io`, which a test has none of, so an
    // age is simply `-created_at`. Negative stamps are what make the two cards
    // render "2h" and "12h" here.
    const now: i64 = 0;
    const short_id = [_]u8{0x5e} ** 32;
    const long_id = [_]u8{0x5f} ** 32;
    main.seedQuoteForTest(short_id, [_]u8{0x7a} ** 32, now - 2 * 3600, "Two hours ago.");
    main.seedQuoteForTest(long_id, [_]u8{0x7b} ** 32, now - 12 * 3600, "Twelve hours ago.");

    var model = main.initialModel();
    model.stage = .ready;
    for ([_]struct { i: usize, id: [32]u8 }{ .{ .i = 0, .id = short_id }, .{ .i = 1, .id = long_id } }) |q| {
        model.notes[q.i] = threadNote(@intCast(0xA1 + q.i), now - 5 * 3600, 0);
        model.notes[q.i].id = @intCast(7 + q.i);
        const body = "Look at this.";
        @memcpy(model.notes[q.i].content_buf[0..body.len], body);
        model.notes[q.i].content_len = @intCast(body.len);
        model.notes[q.i].quote = .{ .kind = .event, .id = q.id, .off = 0, .len = 0 };
    }
    model.notes_len = 2;

    const p = try painted.Painted.render(arena, &model);
    const short_f = frameOfText(p, "2h") orelse return error.NoShortTime;
    const long_f = frameOfText(p, "12h") orelse return error.NoLongTime;

    const short_right = short_f.x + short_f.width;
    const long_right = long_f.x + long_f.width;
    // Right aligned: the two share an edge however wide the text is. Left
    // aligned they would share an x instead, and these edges would differ by
    // exactly the width of one digit.
    if (@abs(short_right - long_right) > 1.0) {
        std.debug.print("\nquote times are not right aligned: 2h ends at {d}, 12h at {d}\n", .{ short_right, long_right });
        return error.TheQuoteTimeIsNotRightAligned;
    }
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
    const img = model.notes[0].setImageForTest(0, url);
    img.aspect = 0.5;
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    @memcpy(img.blur_buf[0..hash.len], hash);
    img.blur_len = @intCast(hash.len);
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
    const img = note.setImageForTest(0, url);
    img.aspect = 2.0;

    const height = main.pictureHeight(&note);
    const width = main.pictureWidth(&note);
    // Reserved at the cap, drawn at its own shape.
    try testing.expectApproxEqAbs(main.picture_column_width_for_test * 1.25, height, 0.5);
    try testing.expectApproxEqAbs(height / 2.0, width, 0.5);

    // A landscape picture fills the column.
    img.aspect = 0.5625;
    try testing.expectApproxEqAbs(main.picture_column_width_for_test, main.pictureWidth(&note), 0.5);
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
    const text = main.offlineBannerTextForTest(arena, model.outbox_pending, false);
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

test "a follow's relay list is a suggestion, and only where they write" {
    // Same three rules as ever, now reached through the store: only where they
    // write, never a relay the reader is already on, and one list is one
    // opinion however many times it arrives.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{9} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/suggest.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://writes.example.com", "write" },
        &.{ "r", "wss://both.example.com" },
        // Where they only READ will never hold their notes, so it buys nothing.
        &.{ "r", "wss://reads.example.com", "read" },
        // Already in the pool: not worth offering.
        &.{ "r", "wss://relay.damus.io" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
    var buf: [96]u8 = undefined;
    // Equal counts, so the tie-break orders them, and the order is stable
    // rather than whatever the tags happened to say.
    try testing.expectEqualStrings("wss://both.example.com", main.relaySuggestionCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://writes.example.com", main.relaySuggestionCopy(1, &buf).?);

    // Ranking again over the same store changes nothing: it is a count of
    // people, and there is still one person.
    main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
}

test "the relay more of your follows write to is offered first" {
    // The bug this replaces: the first six write relays ever seen filled the
    // table and everything after was dropped, so which six you were offered
    // depended on whose relay list happened to arrive first. A relay one person
    // uses could sit above one everybody uses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/rank.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One person on the lonely relay, and they list it FIRST so arrival order
    // would have put it at the top. Five on the popular one.
    var list: [6][32]u8 = undefined;
    for (0..6) |i| {
        var secret = [_]u8{3} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        list[i] = kp.public_key;
        const tags = if (i == 0)
            [_]nostr.event.Tag{&.{ "r", "wss://lonely.example.com" }}
        else
            [_]nostr.event.Tag{&.{ "r", "wss://popular.example.com" }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), main.relaySuggestionCount());
    try testing.expectEqualStrings("wss://popular.example.com", main.relaySuggestionCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://lonely.example.com", main.relaySuggestionCopy(1, &buf).?);
}

test "one person cannot outvote everyone by listing a relay twice" {
    var table: [8]main.RelayRankForTest = undefined;
    const urls = [_][]const u8{
        "wss://a.example.com",
        "wss://a.example.com/",
        "WSS://A.example.com",
    };
    const len = main.foldWriteRelaysForTest(&table, 0, &urls);
    try testing.expectEqual(@as(usize, 1), len);
    try testing.expectEqual(@as(u16, 1), main.relayRankWritersForTest(table[0]));
}

test "one enthusiastic relay list does not outvote everyone else's" {
    // Jumble's rule, and their reasoning: most people do not understand relays,
    // so an author advertising a dozen is not telling you about a dozen places
    // their notes reliably are. Only the first few of any one list count.
    var table: [64]main.RelayRankForTest = undefined;
    var urls: [16][]const u8 = undefined;
    const names = [_][]const u8{
        "wss://r0.example.com", "wss://r1.example.com", "wss://r2.example.com",
        "wss://r3.example.com", "wss://r4.example.com", "wss://r5.example.com",
        "wss://r6.example.com", "wss://r7.example.com", "wss://r8.example.com",
        "wss://r9.example.com", "wss://ra.example.com", "wss://rb.example.com",
    };
    for (names, 0..) |n, i| urls[i] = n;
    const len = main.foldWriteRelaysForTest(&table, 0, urls[0..names.len]);
    try testing.expectEqual(main.outboxRelaysPerAuthorForTest, len);
}

test "a relay list that is nothing but junk contributes nothing" {
    var table: [8]main.RelayRankForTest = undefined;
    const urls = [_][]const u8{ "", "   ", "http://not-a-relay.example.com", "nostr:npub1x" };
    try testing.expectEqual(@as(usize, 0), main.foldWriteRelaysForTest(&table, 0, &urls));
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

test "a field no other client could read is not published" {
    var model = main.initialModel();
    model.profile_stage = .have;
    try testing.expect(model.profile_can_save());
    try testing.expectEqualStrings("", model.profile_invalid());

    // A sentence in the lightning address field is the case worth catching: it
    // saves cleanly, and then nothing can pay you and nothing says why.
    model.profile_lud16_buffer.set("ask me on telegram");
    try testing.expect(model.profile_invalid().len > 0);
    try testing.expect(!model.profile_can_save());

    model.profile_lud16_buffer.set("alice@getalby.com");
    try testing.expectEqualStrings("", model.profile_invalid());
    try testing.expect(model.profile_can_save());

    // Empty is not an error. It removes the key, which is how somebody says
    // they do not have one.
    model.profile_lud16_buffer.set("");
    try testing.expectEqualStrings("", model.profile_invalid());

    model.profile_website_buffer.set("alice.example");
    try testing.expect(model.profile_invalid().len > 0);
    model.profile_website_buffer.set("https://alice.example");
    try testing.expectEqualStrings("", model.profile_invalid());

    model.profile_nip05_buffer.set("nope");
    try testing.expect(model.profile_invalid().len > 0);
}

test "the shape checks accept what works and refuse what cannot" {
    // Only the shape. A lightning address that looks right can still have no
    // endpoint behind it, and this cannot know that without asking.
    for ([_][]const u8{ "", "a@b.co", "alice@getalby.com", "a.b@sub.domain.org" }) |good| {
        var m = main.initialModel();
        m.profile_lud16_buffer.set(good);
        try testing.expectEqualStrings("", m.profile_invalid());
    }
    for ([_][]const u8{ "alice", "@getalby.com", "alice@", "a@b@c.com", "alice@nodot" }) |bad| {
        var m = main.initialModel();
        m.profile_lud16_buffer.set(bad);
        try testing.expect(m.profile_invalid().len > 0);
    }
    for ([_][]const u8{ "", "https://a.example", "http://a.example/x?y=1", "HTTPS://A.EXAMPLE" }) |good| {
        var m = main.initialModel();
        m.profile_website_buffer.set(good);
        try testing.expectEqualStrings("", m.profile_invalid());
    }
    for ([_][]const u8{ "a.example", "ftp://a.example", "www.a.example" }) |bad| {
        var m = main.initialModel();
        m.profile_website_buffer.set(bad);
        try testing.expect(m.profile_invalid().len > 0);
    }
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

test "a removed relay is not put back by the splice that protects the rest" {
    // The splice carries forward every relay the pool has no seat for, and a
    // relay the reader just removed looks exactly like one of those. Without a
    // ledger of removals the splice would undo every removal press.
    defer main.resetOutboxForTest();
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

test "a short welcome does not reserve a tall empty card" {
    // The card used to reserve a fixed 380 points whatever the host wrote, so a
    // two-line welcome sat above three hundred points of nothing with the Close
    // button stranded at the bottom of an empty box.
    const short = "## Welcome!\n\nTwo lines, that is all.";
    const tall = main.placeHomeHeightForTest(short);
    try testing.expect(tall > 0);
    try testing.expect(tall < 140);

    // And a long one is still capped, so a host cannot push the buttons off the
    // screen with an essay.
    var long_buf: [2000]u8 = undefined;
    @memset(&long_buf, 'x');
    try testing.expectEqual(@as(f32, 380), main.placeHomeHeightForTest(&long_buf));
}

test "measuring a markdown line counts what is drawn, not what is written" {
    // This is what made the first estimate useless. One paragraph of the Monero
    // welcome carries a link whose address is two hundred characters that are
    // never drawn, so the line measured four times longer than it reads.
    const link = "See [the client](/nevent1qvzqqqqqqypzqwlsccluhy6xxsr6l9a9uhhxf75g85g8a709tprjcn4e42h053va) here";
    try testing.expectEqual(@as(usize, "See the client here".len), main.visibleLenForTest(link));

    // Heading markers are syntax, not text.
    try testing.expectEqual(@as(usize, "Welcome!".len), main.visibleLenForTest("## Welcome!"));
    // Plain text is itself.
    try testing.expectEqual(@as(usize, 5), main.visibleLenForTest("hello"));
}

test "walking into a room with no logo does not leave the last room's mark behind" {
    // Reported: entered Monero Hallway, then opened the BASSPISTOL link, and
    // Monero's logo was sitting on BASSPISTOL's Info card.
    //
    // The identity check sat BELOW the "this place ships no logo" early return,
    // so a room with nothing of its own never reached the line that drops the
    // last room's mark. Walking OUT to your own feed cleared it, which is why
    // only room-to-room could show it.
    var fx = main.inertEffectsForTest();
    var model = main.initialModel();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();
    defer main.setPlaceLogoIdForTest(0);

    // A slot nothing else in this process holds: these tests share the pool.
    var slot: u64 = 0;
    var i: u64 = 1;
    while (i <= 16) : (i += 1) {
        if (std.mem.eql(u8, main.imageIdOwnerNameForTest(i), "free")) {
            slot = i;
            break;
        }
    }
    if (slot == 0) return error.NoFreeSlot;

    // Standing in a room whose mark is loaded and on screen.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa1} ** 32, "moneroh");
    try testing.expect(main.placeLogoShownForTest());

    // Straight into a different room, one that ships no logo at all.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());

    // And one host running two rooms: the host alone is not a place, so the
    // second room does not inherit the first one's mark either.
    main.setPlaceLogoLoadedForTest(slot, [_]u8{0xa3} ** 32, "room-one");
    try testing.expect(main.placeLogoShownForTest());
    main.visitPlaceForTest([_]u8{0xa3} ** 32, "room-two", "Second Room");
    main.scanPlaceLogoForTest(&fx, &model);
    try testing.expect(!main.placeLogoShownForTest());
}

test "an image with no alt text leaves nothing behind" {
    // The renderer draws an image as its ALT text, which is right for a client
    // that spends its image budget on faces. `![](url)` has no alt, so the
    // renderer does not take it as an image at all and the reader gets a
    // literal `![]` and the raw URL as a link. Seen in fiatjaf's Monero
    // welcome, which is written exactly that way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const src =
        "Welcome!\n\n![](https://example.test/sticker.png)\n\nRead on.";
    const out = main.stripEmptyImagesForTest(arena_state.allocator(), src);
    try testing.expect(std.mem.indexOf(u8, out, "![]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.test") == null);
    // And the host's actual words are untouched.
    try testing.expect(std.mem.indexOf(u8, out, "Welcome!") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Read on.") != null);

    // An image that DOES name itself is left alone: the renderer draws that alt
    // text, which is the whole point of the format.
    const kept = "see ![a sticker](https://example.test/s.png) here";
    try testing.expectEqualStrings(kept, main.stripEmptyImagesForTest(arena_state.allocator(), kept));

    // And syntax that is not an image is not touched either.
    const unclosed = "![](broken";
    try testing.expectEqualStrings(unclosed, main.stripEmptyImagesForTest(arena_state.allocator(), unclosed));
}

/// A store in a temp dir, installed as the app's, for a test that drives a real
/// write and reads back what went out.
pub const FreshStore = struct {
    tmp: std.testing.TmpDir,
    store: nostr.store.Store,

    pub fn open(self: *FreshStore, name: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ self.tmp.sub_path, name });
        self.store = try nostr.store.Store.open(db_path, .{});
        main.setStoreForTest(&self.store);
    }

    pub fn close(self: *FreshStore) void {
        main.setStoreForTest(null);
        self.store.deinit();
        self.tmp.cleanup();
    }
};

/// Signs in an imported key (not made here) whose every relay has finished
/// without sending any of its lists: the state the dead-end hunt found.
pub fn signInNothingFound(secret_byte: u8) [32]u8 {
    main.setIdentityForTest([_]u8{secret_byte} ** 32);
    main.forgetFollowsForTest();
    main.forgetOwnRecordAnswersForTest();
    main.resetRelaysForTest();
    main.setIdentityMintedForTest(false);
    const me = main.activePubkeyForTest().?;
    ownRelayListIsThePool(secret_byte, &.{}) catch unreachable;
    for (0..8) |i| main.noteContactsAnsweredByForTest(i, me);
    return me;
}

test "only the feed subscription's own ids are read as the feed" {
    try testing.expect(main.isFeedSubForTest("plaza-feed"));
    try testing.expect(main.isFeedSubForTest("plaza-feed-12"));
    try testing.expect(!main.isFeedSubForTest("plaza-inbox"));
    try testing.expect(!main.isFeedSubForTest("plaza-engagement"));
    try testing.expect(!main.isFeedSubForTest("plaza-ask-1"));
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

pub fn inboxEvent(kind: u16, author: u8, tags: []const nostr.event.Tag, created_at: i64) nostr.event.Event {
    return inboxEventBy(kind, [_]u8{author} ** 32, tags, created_at);
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

/// Fills the inbox with `n` mentions of the reader from distinct authors.
pub fn seedInbox(n: usize, first_byte: u8, base_time: i64) void {
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
        if (n.widget.kind != .data_row and n.widget.kind != .list_item) continue;
        widest = @max(widest, n.widget.frame.width);
    }
    try testing.expect(widest > 0);
    // The column, not the window. A row wider than the column means the centring
    // row collapsed and every notification is running the full width.
    try testing.expect(widest <= main.notifications_column_width_for_test + 1);
}

// ------------------------------------------------------- NIP-89 the client tag

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
            .name = "a thread",
            .prepare = struct {
                fn f(m: *main.Model) void {
                    m.stage = .ready;
                    m.viewing_thread = 1;
                    m.thread_root = threadNote(0xAA, 100, 0);
                    m.thread_root.id = 1;
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

/// Whether the widget carrying this accessibility label has a handler behind it.
///
/// The dead-control guard walks the tree asking what each widget ADVERTISES, which
/// catches a `ui.button` or a `.checkbox` whose handler went missing. It cannot
/// catch a hand-built row losing its `on_press`: for a plain row the SDK derives
/// the advertised press FROM `on_press`, so removing it removes the advertisement
/// too and the widget stops being a button the guard is looking for. Naming the
/// control is the only way to assert it still exists AND still does something.
pub fn pressableByLabel(tree: AppUi.Tree, widget: canvas.Widget, label: []const u8) bool {
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

/// The right-click items the first note in the tree offers, and the message
/// behind one of them by label.
///
/// The note's actions used to live in an anchored surface behind an ellipsis, so
/// tests reached them by opening that surface and looking for rendered text.
/// There is one list now and the runtime presents it, so what a test can see is
/// the declared items rather than drawn rows.
const ContextItems = struct {
    id: canvas.ObjectId,
    items: []const canvas.WidgetContextMenuItem,

    pub fn label(self: ContextItems, want: []const u8) ?canvas.WidgetContextMenuItem {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.label, want)) return item;
        }
        return null;
    }

    pub fn msgFor(self: ContextItems, tree: AppUi.Tree, want: []const u8) ?Msg {
        for (self.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.label, want)) return tree.msgForContextMenu(self.id, i);
        }
        return null;
    }
};

pub fn noteContext(p: painted.Painted) ?ContextItems {
    for (p.layout.nodes) |node| {
        if (node.widget.context_menu.len == 0) continue;
        return .{ .id = node.widget.id, .items = node.widget.context_menu };
    }
    return null;
}

/// The message behind the press on the widget carrying this accessibility label.
///
/// `pressableByLabel` asks whether SOMETHING is wired there. This asks what, which
/// is the difference between "the seat still works" and "the seat still goes where
/// it is supposed to".
pub fn pressMsgByLabel(tree: AppUi.Tree, label: []const u8) ?Msg {
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

/// Whether anything at or under `widget` is a focus stop.
fn holdsFocusStop(widget: canvas.Widget) bool {
    if (canvas.widgetIsFocusable(widget)) return true;
    for (widget.children) |child| {
        if (holdsFocusStop(child)) return true;
    }
    return false;
}

/// A sheet's backdrop, which closes the sheet when it is clicked. It is a
/// panel, dialog or card that does not call itself a button, and it holds the
/// sheet's own controls, which the keyboard does reach (and Escape closes it
/// besides). It is the pointer's shortcut and has no reason to be a stop of its
/// own. A row that merely CONTAINS focusable controls is not one: a note row
/// holds a like and a reply and still has to be reachable itself.
fn isBackdrop(widget: canvas.Widget) bool {
    switch (widget.kind) {
        .panel, .dialog, .card => {},
        else => return false,
    }
    if (widget.semantics.role != .none) return false;
    for (widget.children) |child| {
        if (holdsFocusStop(child)) return true;
    }
    return false;
}

/// Whether a focusable descendant of `widget` is bound to the very press it is.
/// A note row opens its thread when clicked, and so does the Reply verb inside
/// it; the row is the pointer's larger target for something the keyboard
/// already reaches, and a second stop beside it would read the note twice.
fn hasKeyboardTwin(tree: AppUi.Tree, widget: canvas.Widget, msg: Msg) bool {
    for (widget.children) |child| {
        if (canvas.widgetIsFocusable(child)) {
            if (tree.msgFor(child.id, .press)) |m| {
                if (std.meta.eql(m, msg)) return true;
            }
        }
        if (hasKeyboardTwin(tree, child, msg)) return true;
    }
    return false;
}

/// Walks one screen and fails on any press the keyboard cannot use. There are
/// three ways to be out of reach, and the first two shipped: a row bound to a
/// press with no focus stop (Tab walks past it); a row with a focus stop that is
/// a layout kind (the toolkit answers Return and Space, and draws a focus ring,
/// only for its own controls and `list_item`, so a `row` given `focusable` takes
/// focus, paints nothing and does nothing on either key); and a focus stop that
/// answers neither key.
pub fn expectKeyboardReach(tree: AppUi.Tree, widget: canvas.Widget, screen: []const u8) !void {
    if (tree.msgFor(widget.id, .press)) |msg| out: {
        if (widget.state.disabled or widget.semantics.hidden) break :out;
        // The card inside a sheet swallows presses so the backdrop does not
        // close it from under you. It is not a control.
        if (msg == .absorb_press) break :out;
        if (!canvas.widgetIsFocusable(widget)) {
            if (isBackdrop(widget) or hasKeyboardTwin(tree, widget, msg)) break :out;
            std.debug.print(
                "\n{s}: a {s} \"{s}\" answers a press and the keyboard cannot reach it (build it with pressRow)\n",
                .{ screen, @tagName(widget.kind), widget.semantics.label },
            );
            return error.PressNotReachableByKeyboard;
        }
        // An inline link is the toolkit's own text hit-area. It is a focus stop
        // that draws no ring (upstream), and `keyActivation` is what makes Return
        // open it. Everything else must be a kind the toolkit rings and answers.
        const inline_link = widget.kind == .text and widget.semantics.role == .link;
        for ([_][]const u8{ "enter", "space" }) |name| {
            const key = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = name, .focused_id = widget.id };
            const answered = if (inline_link)
                main.keyActivation(tree, key) != null
            else
                canvas.widgetKeyboardControlIntent(widget, key) != null;
            if (!answered) {
                std.debug.print(
                    "\n{s}: a {s} \"{s}\" takes focus and {s} does nothing on it, and it draws no focus ring (build it with pressRow)\n",
                    .{ screen, @tagName(widget.kind), widget.semantics.label, name },
                );
                return error.FocusedPressDoesNothing;
            }
        }
    }
    for (widget.children) |child| try expectKeyboardReach(tree, child, screen);
}

test "return and space press a focused inline link" {
    // The toolkit puts a Tab stop on every link inside a paragraph and answers
    // neither key on it, so a reader could tab onto a link in a note and nothing
    // would happen. `keyActivation` is what presses it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.clearIdentityForTest();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.noteWithLinkForTest("");
    const body = "see https://example.com/a/page for the details";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes_len = 1;
    const tree = try buildTree(arena, &model);

    const link = findLinkWidget(tree.root) orelse return error.NoLinkInTheNote;
    const press = tree.msgFor(link.id, .press) orelse return error.LinkHasNoPress;
    for ([_][]const u8{ "enter", "space" }) |name| {
        const key = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = name, .focused_id = link.id };
        const got = main.keyActivation(tree, key) orelse return error.KeyDidNotPressTheLink;
        try testing.expect(std.meta.eql(got, press));
    }
    // Only the activation keys, only on key down, and not with a chord.
    const tab = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "tab", .focused_id = link.id };
    try testing.expect(main.keyActivation(tree, tab) == null);
    const up = canvas.WidgetKeyboardEvent{ .phase = .key_up, .key = "enter", .focused_id = link.id };
    try testing.expect(main.keyActivation(tree, up) == null);
    const chord = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter", .focused_id = link.id, .modifiers = .{ .super = true } };
    try testing.expect(main.keyActivation(tree, chord) == null);
    // And nothing at all when nothing has the keyboard.
    const nowhere = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expect(main.keyActivation(tree, nowhere) == null);
}

pub fn countPressesOf(tree: AppUi.Tree, widget: canvas.Widget, msg: Msg) usize {
    var n: usize = 0;
    if (tree.msgFor(widget.id, .press)) |m| {
        if (std.meta.eql(m, msg)) n += 1;
    }
    for (widget.children) |child| n += countPressesOf(tree, child, msg);
    return n;
}

fn findLinkWidget(widget: canvas.Widget) ?canvas.Widget {
    if (widget.kind == .text and widget.semantics.role == .link) return widget;
    for (widget.children) |child| {
        if (findLinkWidget(child)) |found| return found;
    }
    return null;
}

/// Whether layout node `i` sits under node `ancestor`, following the parent
/// links the layout records rather than comparing rectangles.
pub fn isDescendantOf(p: painted.Painted, i: usize, ancestor: usize) bool {
    var cursor = p.layout.nodes[i].parent_index;
    var hops: usize = 0;
    while (cursor) |parent| : (hops += 1) {
        if (parent == ancestor) return true;
        if (hops > 64) return false;
        cursor = p.layout.nodes[parent].parent_index;
    }
    return false;
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

test "the window is square where the reading happens" {
    // A feed is a column of rows. The wide-and-short default spent its extra
    // width on margin while showing four notes at a time.
    //
    // The square is the READING AREA, not the window. It was the same thing
    // until the second rail existed; now the window carries 238pt of chrome
    // down its left side, and asserting the window itself would either shrink
    // the room by that much or quietly stop meaning anything.
    try testing.expectEqual(main.window_width - main.rails_width, main.window_height);
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

pub const modal_cases = [_]ModalCase{
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
/// A modal SURFACE by its accessible label: the panel or dialog that carries it,
/// never a text node that happens to share the wording. A card's heading is
/// usually the same words as its dialog's label ("Edit profile" both names the
/// sheet and titles it), and matching that instead found a 62x18 label where the
/// backdrop should be.
fn modalSurfaceIndex(p: painted.Painted, label: []const u8) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        switch (node.widget.kind) {
            .panel, .dialog => {},
            else => continue,
        }
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        return i;
    }
    return null;
}

pub fn modalDialogIndex(p: painted.Painted, label: []const u8) ?usize {
    for (p.layout.nodes, 0..) |node, i| {
        if (node.widget.kind != .dialog) continue;
        if (!std.mem.eql(u8, node.widget.semantics.label, label)) continue;
        return i;
    }
    return null;
}

pub fn modalCardIndex(p: painted.Painted, root: usize) ?usize {
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

pub fn pressMsgById(p: painted.Painted, id: canvas.ObjectId) ?Msg {
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

        // The BACKDROP fills the window. This is the property SDK 0.9.2 broke and
        // the reason these five surfaces were restructured: a dialog is placed
        // and sized by the runtime now, so the dim and the dismiss target had to
        // stop being the dialog. Asserting the frame rather than trusting the
        // markup, because the whole failure mode was markup that still read as
        // full-window while laying out as a 420pt box.
        const scrim = p.layout.nodes[modalSurfaceIndex(p, c.label) orelse root].widget.frame;
        if (scrim.width < main.window_width or scrim.height < main.window_height) {
            std.debug.print(
                "{s}: the backdrop is {d:.0}x{d:.0} inside a {d:.0}x{d:.0} window, so it does not cover it\n",
                .{ c.name, scrim.width, scrim.height, main.window_width, main.window_height },
            );
            return error.BackdropDoesNotCoverTheWindow;
        }

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
    _ = model.notes[0].setImageForTest(0, url);
    model.notes_len = 1;
    model.expanded_note = 1;

    const p = try painted.Painted.render(arena, &model);
    // By LABEL, not by kind: the viewer is a panel rather than a dialog, because
    // a picture wants the whole window and a dialog is centred at its preferred
    // size. What the test cares about is the surface that closes on a press.
    const viewer = modalSurfaceIndex(p, "Expanded image") orelse return error.NoViewer;
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

test "the viewer opens the picture that was pressed, not the first one" {
    // The gallery cell dispatched the right index and the update stored it, and
    // then the viewer was called with the note alone and read picture zero. So
    // this is not "the second image opens the first": EVERY cell opened the
    // first, and a one-picture note hid it because zero was the only answer.
    //
    // Asserted through "Open original", because that is the one place the
    // choice reaches something a test can read: an image node carries a
    // registered id, and nothing in a headless render registers one, so the
    // picture itself is "Still loading…" either way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = main.Note{ .created_at = 1_800_000_000 };
    model.notes[0].id = 1;
    _ = model.notes[0].setImageForTest(0, "https://example.com/first.jpg");
    _ = model.notes[0].setImageForTest(1, "https://example.com/second.jpg");
    model.notes_len = 1;
    model.expanded_note = 1;
    model.expanded_image = 1;

    const p = try painted.Painted.render(arena, &model);
    const viewer = modalSurfaceIndex(p, "Expanded image") orelse return error.NoViewer;
    const original = controlNode(p, viewer, "Open original") orelse return error.NoSuchControl;
    const msg = pressMsgById(p, original.id) orelse return error.ControlNotWired;
    switch (msg) {
        .open_url => |u| try testing.expectEqualStrings("https://example.com/second.jpg", u),
        else => {
            std.debug.print("\"Open original\" dispatches {s}, not open_url\n", .{@tagName(msg)});
            return error.WrongMessage;
        },
    }
}

// ---- P3: settings is a sheet -------------------------------------------------

/// Settings with everything in it that can be in it: eight relays, six
/// suggestions with hostnames long enough to overrun a row, and a local key.
pub fn openFullSettings(model: *Model) void {
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

// ---- P10: a quoted picture ---------------------------------------------------

/// The frame of the first laid-out node whose text contains `needle`.
pub fn frameOfTextContaining(p: painted.Painted, needle: []const u8) ?native_sdk.geometry.RectF {
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

// ---- a quote card draws the picture it quotes ---------------------------------

/// A model with one feed row quoting `quoted_id`, whose cache entry says the
/// quoted note carries `quote_picture_url`.
pub fn quotePictureModel(quoted_id: [32]u8, aspect: f32) !main.Model {
    main.dropQuoteForTest(quoted_id);
    main.seedQuoteForTest(quoted_id, [_]u8{0x2b} ** 32, 100, "");
    const e = main.quoteForTest(quoted_id) orelse return error.NoQuote;
    const host = "127.0.0.1:9";
    @memcpy(e.image_host_buf[0..host.len], host);
    e.image_host_len = host.len;
    @memcpy(e.image_url_buf[0..quote_picture_url.len], quote_picture_url);
    e.image_url_len = quote_picture_url.len;
    e.image_aspect = aspect;
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    @memcpy(e.image_blur_buf[0..hash.len], hash);
    e.image_blur_len = hash.len;

    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA1, 100, 0);
    model.notes[0].id = 7;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;
    return model;
}

test "a quote's picture box is total over whatever shape a note declares" {
    const cases = [_]f32{ 0, -1, 0.0001, 0.3, 0.5, 0.66, 1.0, 1.5, 4, 65535, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    for (cases) |aspect| {
        const box = main.quotePictureBox(aspect);
        try testing.expect(std.math.isFinite(box.width) and std.math.isFinite(box.height));
        // Never empty, never wider than the thumbnail, never taller than it is
        // wide: the card has to be priced for whatever comes through here.
        try testing.expect(box.width > 0 and box.height > 0);
        try testing.expect(box.width <= main.quote_picture_width_for_test);
        try testing.expect(box.height <= main.quote_picture_width_for_test);
    }
    // No declared shape lands on the feed's guess, not on a square or a sliver.
    const unknown = main.quotePictureBox(0);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test * 0.66, unknown.height, 0.5);
    // A tall picture gets a box of its own shape rather than bare gutters.
    const tall = main.quotePictureBox(2);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test / 2, tall.width, 0.5);
    try testing.expectApproxEqAbs(main.quote_picture_width_for_test, tall.height, 0.5);
}

test "the fill path keeps what the card needs to draw the picture, and refuses what it should" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{62} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quotedpic.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    const url = "https://i.nostr.build/aBcD1234.jpg";
    const hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
    const described = try signedKind(arena, signer, kp, 1_800_000_000, 1, &[_]nostr.event.Tag{
        &.{ "imeta", "url " ++ url, "dim 800x400", "blurhash " ++ hash },
    }, "look " ++ url);
    // A file the note itself says is a video, however it is named.
    const video_url = "https://i.nostr.build/clip.jpg";
    const video = try signedKind(arena, signer, kp, 1_800_000_001, 1, &[_]nostr.event.Tag{
        &.{ "imeta", "url " ++ video_url, "m video/mp4" },
    }, video_url);
    // An address longer than a feed picture keeps.
    const long_url = "https://i.nostr.build/" ++ "a" ** 200 ++ ".jpg";
    const long = try signedNote(arena, signer, kp, 1_800_000_002, long_url);
    // No imeta at all: a picture of unknown shape.
    const bare_url = "https://i.nostr.build/bare.png";
    const bare = try signedNote(arena, signer, kp, 1_800_000_003, bare_url);
    for ([_]nostr.event.Event{ described, video, long, bare }) |ev| {
        _ = try store.ingest(arena, ev, .{});
        main.dropQuoteForTest(ev.id);
        main.wantQuoteForTest(ev.id);
    }
    main.refreshQuotesForTest(&store);

    const d = main.quoteForTest(described.id) orelse return error.NoQuote;
    try testing.expectEqualStrings(url, d.imageUrl());
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.image_aspect, 0.0001);
    try testing.expectEqualStrings(hash, d.imageBlurhash());
    // The slot key is the one the quoted note's own feed row would use, so the
    // two share a slot when both are on screen.
    try testing.expectEqual(main.mediaKeyForTest(main.noteIdOf(described), 0), main.quoteMediaKeyForTest(described.id));

    const v = main.quoteForTest(video.id) orelse return error.NoQuote;
    try testing.expectEqual(@as(usize, 0), v.imageUrl().len);
    // Still named, as before: the card knows there is a file and where from.
    try testing.expect(v.image_host_len > 0);

    const l = main.quoteForTest(long.id) orelse return error.NoQuote;
    try testing.expectEqual(@as(usize, 0), l.imageUrl().len);
    try testing.expect(l.image_host_len > 0);

    const b = main.quoteForTest(bare.id) orelse return error.NoQuote;
    try testing.expectEqualStrings(bare_url, b.imageUrl());
    try testing.expectEqual(@as(f32, 0), b.image_aspect);
    try testing.expectEqual(@as(usize, 0), b.imageBlurhash().len);
}

// ---- P13: a door to the thing holding the key --------------------------------

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
pub fn oneNoteFeed(model: *Model) void {
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

test "a bunker can open a private half, and a refusal is not an empty one" {
    // Before this, `scanPrivateHalves` only knew one way to ask: an HTTP call
    // to the local keyholder. A reader signed in through an external signer has
    // no local keyholder holding their key, so the ask came back not-ok and the
    // half was marked refused forever. `writeMute` then refused every mute
    // write, correctly, because a private half that is present and unreadable
    // is exactly what it will not publish over. The guard was firing on a
    // question never asked of the right signer.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(index));

    // The bunker answers. The listener parks it; the tick applies it.
    main.parkRemoteHalfAnswerForTest(index, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(index));

    // And the half that matters more: a refusal or a timeout leaves it
    // REFUSED, never open-and-empty. An empty answer here is how a client
    // publishes a list with every private entry stripped out of it.
    main.forgetPrivateHalvesForTest();
    const second = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    if (!main.failRemoteHalfForTest(second)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
}

test "a legacy half is asked of the bunker as nip04_decrypt, and a current one as nip44_decrypt" {
    // NIP-51 lets the private half be either, and a bunker answers each with its
    // own method. A NIP-04 half sent as nip44_decrypt comes back an error, which
    // reads as a refusal: the reader would have a mute list they could never
    // write to. Both clients tell the two apart by the `?iv=` marker.
    try testing.expectEqualStrings("nip04_decrypt", main.remoteDecryptMethodNameForTest("AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=Zm9vYmFyYmF6cXV4MTIzNA=="));
    try testing.expectEqualStrings("nip44_decrypt", main.remoteDecryptMethodNameForTest("AqRcpq0Cw2h2Vd5Tk1Fk5wAqRcpq0Cw2h2Vd5Tk1Fk5w=="));
    // A NIP-44 payload is base64, which has no `?` in it to be mistaken.
    try testing.expectEqualStrings("nip44_decrypt", main.remoteDecryptMethodNameForTest(""));
}

test "a NIP-04 half is the bunker's to open and not Notary's" {
    // Notary's loopback door opens NIP-44 and nothing else. Asking it for a
    // NIP-04 half can only fail, and recording that failure as a refusal would
    // have every press re-ask a door that cannot answer. So it reads as
    // unreadable, which is the truth. A bunker can open it, so there it waits.
    const legacy = "AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=Zm9vYmFyYmF6cXV4MTIzNA==";
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    main.setSignerKindForTest("helper");
    try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(legacy));

    main.forgetPrivateHalvesForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(legacy));
}

test "a declined private half is asked again on the next press, never read as empty" {
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));

    // The reader dismisses the prompt on their bunker, or it times out.
    if (!main.failRemoteHalfForTest(index)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));

    // The press says so and puts the ask back for the next tick. It does not
    // report the half as readable or as empty at any point.
    try testing.expectEqualStrings("declined", main.privateHalfGateNameForTest(ciphertext));
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
    // A second press while that ask is out is a wait, not a second prompt.
    try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));

    // The tick sends it, and the reader approves this time.
    main.markIdleHalvesAskedForTest();
    main.parkRemoteHalfAnswerForTest(index, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("readable", main.privateHalfGateNameForTest(ciphertext));
}

test "an ask that died with its session is asked again" {
    // A reconnect bumps the generation, and a request from the old one is
    // dropped by the sweep. The half it was about stayed "asking" for ever, and
    // nothing asks a half that is already being asked, so the list was read-only
    // until a restart.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    try testing.expectEqual(@as(u8, 0), index);
    try testing.expect(main.registerRemoteHalfAskForTest(index, .nip04_decrypt));
    main.bumpRemoteGenerationForTest();
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
}

test "signing out forgets what the private halves said" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const ciphertext = "a-half-that-belonged-to-the-last-reader";
    main.openPrivateHalfForTest(ciphertext, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(0));

    main.performLogoutForTest(&model, &fx);
    try testing.expectEqualStrings("none", main.privateHalfStateForTest(0));
}

test "a bunker that stays silent is asked again once the wait is over, and one that said no is not" {
    // A timeout is not an answer. The prompt can sit unseen on a phone or the
    // reply can be lost on the way, and a half marked refused for the whole
    // session leaves the reader's private mutes unenforced until they happen
    // to press a write. An explicit error is different: that is a no, and it
    // waits for a press.
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const ciphertext = "AsAQ==?iv=notreallyciphertext";
    const index = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;

    // Silence: refused, with a stamp saying when it may be asked again.
    if (!main.timeoutRemoteHalfForTest(index)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));
    const retry_at = main.privateHalfRetryAtForTest(index);
    try testing.expect(retry_at > 0);

    // Not before the wait is over, and not by anything but that.
    main.rearmPrivateHalvesForTest(retry_at - 1);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(index));
    main.rearmPrivateHalvesForTest(retry_at);
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(index));
    try testing.expectEqual(@as(i64, 0), main.privateHalfRetryAtForTest(index));

    // Idle is what the tick asks from, and an ask in flight is never moved:
    // at most one prompt is out per half.
    main.forgetPrivateHalvesForTest();
    const second = main.claimPrivateHalfPendingForTest(ciphertext) orelse return error.NoSlot;
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(second));

    // An explicit error from the bunker is a no: no stamp, no timed re-ask.
    if (!main.failRemoteHalfForTest(second)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
    try testing.expectEqual(@as(i64, 0), main.privateHalfRetryAtForTest(second));
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(second));
}

test "a reconnect to the bunker asks the halves it refused again" {
    var model = main.initialModel();
    var fx_scan: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearPendingForTest();

    const refused_text = "AsAQ==?iv=refusedciphertext";
    const r = main.claimPrivateHalfPendingForTest(refused_text) orelse return error.NoSlot;
    if (!main.failRemoteHalfForTest(r)) return error.NoPendingSlot;
    main.scanPendingRemoteForTest(&model, &fx_scan);
    try testing.expectEqualStrings("refused", main.privateHalfStateForTest(r));
    const waiting = main.claimPrivateHalfPendingForTest("AsAQ==?iv=stillasking") orelse return error.NoSlot;

    main.bumpRemoteGenerationForTest();
    try testing.expectEqualStrings("idle", main.privateHalfStateForTest(r));
    // A half whose ask is still out is not the reconnect's to move: that ask is
    // retired by the stale sweep.
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(waiting));
}

test "what the keyholder says it cannot read is never asked again, and a refusal is" {
    // 422 is Notary saying it looked at this ciphertext and it does not open;
    // so is a 200 whose body is not an answer. Reporting those as "declined"
    // had every press ask a question whose answer cannot change. A 403, a 409
    // or a dead daemon are refusals: they might say yes next time.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();
    const ciphertext = "a-half-notary-cannot-read";

    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(422, "{\"error\":\"unreadable\"}");
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    // Every press reads the same, and none of them goes back to idle.
    for (0..3) |_| try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(ciphertext));
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    // Nor does a new connection or a timer.
    main.rearmPrivateHalvesForTest(std.math.maxInt(i64));
    main.bumpRemoteGenerationForTest();
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));

    main.forgetPrivateHalvesForTest();
    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(200, "this is not json");
    try testing.expectEqualStrings("unreadable", main.privateHalfStateForTest(0));
    try testing.expectEqualStrings("unreadable", main.privateHalfGateNameForTest(ciphertext));

    for ([_]u16{ 403, 409, 500, 0 }) |status| {
        main.forgetPrivateHalvesForTest();
        main.askPrivateHalfForTest(ciphertext);
        main.deliverPrivateHalfForTest(status, "{\"error\":\"refused\"}");
        try testing.expectEqualStrings("refused", main.privateHalfStateForTest(0));
        // The press says declined and puts the ask back; a second one waits.
        try testing.expectEqualStrings("declined", main.privateHalfGateNameForTest(ciphertext));
        try testing.expectEqualStrings("waiting", main.privateHalfGateNameForTest(ciphertext));
    }
}

test "an answer that lands after a sign-out is not applied to the next account's half" {
    // The answer carries a slot index and nothing else, and a sign-out frees
    // the slots while answers are parked or on the wire. Account A's plaintext
    // arriving once account B holds slot zero must change nothing in B's half.
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.clearPendingForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const a_text = "AsAQ==?iv=accountAciphertext";
    const b_text = "AsAQ==?iv=accountBciphertext";
    const a_plain = "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]";

    // A's ask is out, a parked answer for it is waiting, and A signs out.
    const a = main.claimPrivateHalfPendingForTest(a_text) orelse return error.NoSlot;
    main.parkRemoteHalfAnswerForTest(a, a_plain);
    main.performLogoutForTest(&model, &fx);
    main.setSignerKindForTest("remote");

    // B signs in and asks from the same slot.
    const b = main.claimPrivateHalfPendingForTest(b_text) orelse return error.NoSlot;
    try testing.expectEqual(a, b);
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));

    // Then A's answer arrives after all, as the listener would park it, and
    // so does A's timeout and A's refusal. None of them is B's.
    main.parkRemoteHalfAnswerForCiphertextForTest(a, a_text, a_plain);
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));
    try testing.expect(!main.privateHalfIsReadableForTest(b_text));

    try testing.expect(main.endRemoteHalfAskForTest(a, a_text, .timed_out));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));
    try testing.expect(main.endRemoteHalfAskForTest(a, a_text, .failed));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(b));

    // B's own answer still lands.
    main.parkRemoteHalfAnswerForCiphertextForTest(b, b_text, "[]");
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(b));
}

test "an answer from Notary that lands after a sign-out is not applied either" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    main.askPrivateHalfForTest("a-half-of-the-first-account");
    const first_key = main.privateHalfAskKeyForTest(0);
    main.performLogoutForTest(&model, &fx);

    // The reply for the first account's ask finds nothing waiting for it.
    main.deliverPrivateHalfKeyedForTest(first_key, 200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("none", main.privateHalfStateForTest(0));

    // And once the next account is asking from the same slot, it is still not
    // that ask's answer.
    main.askPrivateHalfForTest("a-half-of-the-second-account");
    main.deliverPrivateHalfKeyedForTest(first_key, 200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(0));
    main.deliverPrivateHalfForTest(200, "{\"items\":[\"[]\"]}");
    try testing.expectEqualStrings("open", main.privateHalfStateForTest(0));
}

test "signing out clears an answer the bunker had already handed over" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    defer main.clearIdentityForTest();
    main.setIdentityForTest([_]u8{0x8E} ** 32);

    const text = "AsAQ==?iv=sameciphertextbothtimes";
    const idx = main.claimPrivateHalfPendingForTest(text) orelse return error.NoSlot;
    main.parkRemoteHalfAnswerForTest(idx, "[[\"p\",\"" ++ "ab" ** 32 ++ "\"]]");
    try testing.expect(main.halfInboxHoldsForTest());
    main.performLogoutForTest(&model, &fx);
    try testing.expect(!main.halfInboxHoldsForTest());

    // Even for the very same ciphertext, a new session has to ask again: what
    // was parked is gone, not merely unmatched.
    main.setSignerKindForTest("remote");
    _ = main.claimPrivateHalfPendingForTest(text) orelse return error.NoSlot;
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("asking", main.privateHalfStateForTest(idx));
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
    // while its own open flag was its own, and then on the mention picker, which
    // had no open flag at all. Both had the same shape: the surface is on screen
    // after the dismiss it declared. That note menu is gone (a right-click does
    // its job now), so the picker is what stands guard over the shape.
    main.setIdentityForTest([_]u8{0x77} ** 32);
    defer main.clearIdentityForTest();

    const Case = struct {
        name: []const u8,
        text: []const u8,
        open: *const fn (*Model) void,
    };
    const cases = [_]Case{
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
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, 1, &marked, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);
    try testing.expectEqualSlices(u8, &root, &out[1]);

    // A root post has nothing above it, so there is nothing to add.
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &.{}, &out));
    try testing.expectEqualSlices(u8, &focal, &out[0]);

    // A note that names ITSELF as its root is one id, not the same id twice.
    var focal_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&focal_hex, "{x}", .{focal}) catch unreachable;
    const self_rooted = [_]nostr.event.Tag{&.{ "e", &focal_hex, "", "root" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &self_rooted, &out));

    // A quote is not an ancestor: a mention-marked tag must not be taken as the
    // root, or pressing a note that quotes another opens the wrong thread.
    const quoting = [_]nostr.event.Tag{&.{ "e", &root_hex, "", "mention" }};
    try testing.expectEqual(@as(usize, 1), main.threadQueryIds(focal, 1, &quoting, &out));

    // An old-style positional reply, with no marker at all, still resolves.
    const positional = [_]nostr.event.Tag{&.{ "e", &root_hex }};
    try testing.expectEqual(@as(usize, 2), main.threadQueryIds(focal, 1, &positional, &out));
    try testing.expectEqualSlices(u8, &root, &out[1]);
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

// ---- nothing paints past the edge of the smallest window allowed ------------

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
pub fn tagNamed(tags: []const nostr.event.Tag, name: []const u8) ?nostr.event.Tag {
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) return t;
    }
    return null;
}

pub fn countTags(tags: []const nostr.event.Tag, name: []const u8) usize {
    var n: usize = 0;
    for (tags) |t| {
        if (t.len > 0 and std.mem.eql(u8, t[0], name)) n += 1;
    }
    return n;
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

test "a feed author with no name is asked about, before the row is on screen" {
    // The wanted set had exactly two sources: the inbox, and quoted notes. The
    // feed registered nobody. That was survivable only while `refreshProfiles`
    // walked the whole follow list, and when that walk left the render path the
    // feed lost its only source of names. Real accounts, with profiles sitting
    // on the relays, drew as a raw npub and a two-character avatar for the
    // whole session.
    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var model = main.initialModel();
    model.stage = .ready;

    // A feed longer than one screen, so the band matters.
    const rows = 40;
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        var note = threadNote(@intCast(i + 1), @intCast(1000 - @as(i64, @intCast(i))), 0);
        note.id = @intCast(i + 1);
        note.pubkey = [_]u8{@intCast(i + 1)} ** 32;
        model.notes[i] = note;
    }
    model.notes_len = rows;
    main.setVisibleRangeForTest(0, 4);

    main.wantProfilesAheadForTest(&model);

    // On screen: asked about, obviously.
    try testing.expect(main.isProfileWantedForTest([_]u8{1} ** 32));
    try testing.expect(main.isProfileWantedForTest([_]u8{5} ** 32));

    // And ahead of the fold, which is the point: a name that only starts
    // loading when the row appears is a name the reader watches arrive. It is
    // also what lets a face be warmed early, since the picture URL lives in the
    // kind:0 and there is nothing to warm until it lands.
    try testing.expect(main.isProfileWantedForTest([_]u8{12} ** 32));

    // Not the whole feed, though: the band is bounded, or a long scrollback
    // would ask about everybody at once.
    try testing.expect(!main.isProfileWantedForTest([_]u8{40} ** 32));
}

// -- The feed brings itself up to date without re-reading the store ----------
//
// The feed used to answer "has anything changed" by asking the store for the
// whole window again, once a second, on the render thread. Measured in the
// library's benchmark at 2049 authors, ReleaseFast, best of fifty: 1.46 ms for a
// screenful, 10.8 ms twenty pages down, against a 16.7 ms frame.
//
// These assert on WHICH PATH RAN and how much it parsed, never on a stopwatch.
// The test binary is Debug and the machine is shared, so a timing assertion here
// measures the machine. A counter measures the code.

/// A store, an identity, a follow set and a model, wired the way the app wires
/// them, with change detection reset so a test starts from a known place.
pub const FeedFixture = struct {
    tmp: std.testing.TmpDir,
    store: nostr.store.Store,
    signer: nostr.keys.Signer,
    kp: nostr.keys.KeyPair,
    model: *main.Model,

    pub fn init(arena: std.mem.Allocator, name: []const u8) !*FeedFixture {
        const f = try arena.create(FeedFixture);
        f.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ f.tmp.sub_path, name });
        f.store = try nostr.store.Store.open(db_path, .{});
        f.signer = nostr.keys.Signer.init();
        f.kp = try f.signer.keyPairFromSecretKey([_]u8{77} ** 32);
        main.resetProfilesForTest();
        main.resetMediaForTest();
        main.setIdentityForTest([_]u8{77} ** 32);
        main.setStoreForTest(&f.store);
        main.resetFeedChangeDetectionForTest();
        main.resetFeedWork();
        f.model = try arena.create(main.Model);
        f.model.* = main.initialModel();
        f.model.stage = .ready;
        return f;
    }

    pub fn deinit(f: *FeedFixture) void {
        main.setStoreForTest(null);
        main.clearIdentityForTest();
        main.resetProfilesForTest();
        f.signer.deinit();
        f.store.deinit();
        f.tmp.cleanup();
    }

    /// Stores an event the way the app does: through the one door, which is
    /// where an arrival announces itself.
    pub fn arrive(f: *FeedFixture, arena: std.mem.Allocator, created_at: i64, content: []const u8) !nostr.event.Event {
        const ev = try signedNote(arena, f.signer, f.kp, created_at, content);
        _ = try main.plazaIngestForTest(arena, ev);
        return ev;
    }

    pub fn tick(f: *FeedFixture, now_s: i64) void {
        main.tickForTest(f.model, now_s);
    }

    pub fn ids(f: *FeedFixture, out: []i64) []i64 {
        for (f.model.notes[0..f.model.notes_len], 0..) |n, i| out[i] = n.id;
        return out[0..f.model.notes_len];
    }
};

test "a card already on screen survives a splice unparsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try FeedFixture.init(arena, "sentinel");
    defer f.deinit();

    _ = try f.arrive(arena, 1_800_000_000, "the original text");
    f.tick(1_800_000_100);
    try testing.expectEqual(@as(usize, 1), f.model.notes_len);

    const sentinel = "SENTINEL";
    @memcpy(f.model.notes[0].content_buf[0..sentinel.len], sentinel);
    f.model.notes[0].content_len = sentinel.len;

    _ = try f.arrive(arena, 1_800_000_050, "another note");
    f.tick(1_800_000_100);

    try testing.expectEqual(@as(usize, 2), f.model.notes_len);
    var found = false;
    for (f.model.notes[0..f.model.notes_len]) |*note| {
        if (std.mem.eql(u8, note.content(), sentinel)) found = true;
    }
    try testing.expect(found);
}

// -- A connection that stopped answering ------------------------------------
//
// A relay's ingest thread blocks in `receive` until the relay speaks. A peer
// that goes away without closing leaves that thread waiting forever behind a
// green dot: no error, no timeout, no reconnect, and nothing able to tell it
// apart from a quiet night. The keeper is a separate thread precisely because
// the waiting one cannot notice anything.
//
// When it pings and when it gives up is `nostr.liveness`, tested there. What
// is asserted here is what this app does with that decision.

test "a quiet relay still counts as a relay" {
    // The pool summary drives an "offline, reconnecting" banner over the whole
    // app. A relay with an open socket, live subscriptions and a publish path
    // that works is not offline, and saying so on a slow night would be the
    // same kind of lie as the green dot, pointing the other way.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example", true, true);
    main.setRelayStatusForTest(0, true);
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());

    main.setRelayQuietForTest(0);
    try testing.expect(main.relayStatusQuietForTest(0));
    try testing.expectEqual(@as(usize, 1), main.liveRelayCountForTest());
    // And it is still a relay a note can go out on.
    try testing.expect(main.relayStatusConnectedForTest(0));
}

test "coming back from quiet is not a network recovery" {
    // The outbox widens its retry delay when nothing can be reached and pulls it
    // back when a relay returns. A relay answering the keepalive it was just
    // sent is news about one socket, not about the network, and letting it reset
    // the ladder would mean a quiet pool resetting it every minute forever.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example", true, true);
    main.forgetOutboxAcksForTest();

    main.setRelayStatusForTest(0, false);
    main.setRelayStatusForTest(0, true);
    const after_real_recovery = main.outboxWokeForTest();
    try testing.expect(after_real_recovery);

    main.resetOutboxWokeForTest();
    main.setRelayQuietForTest(0);
    main.setRelayStatusForTest(0, true);
    try testing.expect(!main.outboxWokeForTest());
}

// -- A fetch that cannot run forever ----------------------------------------
//
// Every fetch that is not the feed dials its own socket, asks one question and
// reads until EOSE. A relay that accepts the REQ and then goes quiet used to
// hold that thread for the life of the process, and a message-count bound does
// not help: a relay that sends nothing never reaches the count either.
//
// The keeper holds an absolute deadline on each of them. Its decision is pure
// over the deadline table, so it is asserted here without a socket or a thread.

test "a fetch inside its budget is left alone" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(0, 10_000);
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(9_999, &out));
}

test "a fetch past its budget is cut off" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(3, 10_000);
    const n = main.expiredOneShotsForTest(10_000, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 3), out[0]);
}

test "an empty slot is not a fetch that ran out of time" {
    // Zero is the empty marker, and a keeper reading it as a deadline in 1970
    // would try to shut down every unused slot on every tick.
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(std.math.maxInt(i64), &out));
}

test "a fetch already cut off is not cut off again" {
    // The slot stays in the table until its owner clears it, because clearing
    // it from the keeper would hand the slot to another fetch while the first
    // one still holds the pointer. So the keeper has to stop acting on it
    // without forgetting it.
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(5, 1_000);
    try testing.expectEqual(@as(usize, 1), main.expiredOneShotsForTest(2_000, &out));
    main.markOneShotCutForTest(5);
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(2_000, &out));
    try testing.expectEqual(@as(usize, 0), main.expiredOneShotsForTest(std.math.maxInt(i64), &out));
}

test "several overdue fetches are all cut, not just the first" {
    main.clearOneShotsForTest();
    defer main.clearOneShotsForTest();
    var out: [main.oneShotSlotsForTest]usize = undefined;

    main.seatOneShotForTest(0, 1_000);
    main.seatOneShotForTest(1, 50_000);
    main.seatOneShotForTest(2, 1_000);
    const n = main.expiredOneShotsForTest(2_000, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 0), out[0]);
    try testing.expectEqual(@as(usize, 2), out[1]);
}

test "the bunker listener is watched alongside the pool" {
    // It is not a pool relay: no badge, no slot in the reader's list, never
    // published to. It is the same kind of thing though, a socket held open by
    // a thread blocked in `receive`, and when it half-opens remote signing
    // stops with no error anywhere. Its slot sits past the pool's, which is why
    // the keeper's status updates have to stay inside the pool's range.
    try testing.expectEqual(main.maxRelaysForTest, main.bunkerWatchSlotForTest);
}

test "a one-shot budget is shorter than the connection deadline it borrows" {
    // A fetch is a question with an answer; a pool connection is a
    // conversation. Bounding the fetch by the connection's ninety seconds would
    // leave a wedged profile lookup sitting for a minute and a half, and there
    // is nothing to wait for: the relay was asked one thing.
    try testing.expect(main.oneShotBudgetMsForTest < nostr.liveness.dead_after_ms);
}

// -- Reading where your follows actually write -------------------------------
//
// The pool asks every relay in it about every person the reader follows, so a
// follow who writes only to relays the reader is not on is invisible: no error,
// no empty state, they simply are not there. These connect to the top few
// relays the ranking found that the reader is NOT already on, and ask each only
// about the people who write there.

test "a relay the reader is not on is dialled, and asked only about its writers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/outbox.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // Four people on one relay the reader is not on, two on another.
    var list: [6][32]u8 = undefined;
    for (0..6) |i| {
        var secret = [_]u8{5} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        list[i] = kp.public_key;
        const tags = if (i < 4)
            [_]nostr.event.Tag{&.{ "r", "wss://many.example.com" }}
        else
            [_]nostr.event.Tag{&.{ "r", "wss://few.example.com" }};
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
    _ = main.setFollowsForTest(&list, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(@as(usize, 2), main.discoveredCount());
    var buf: [96]u8 = undefined;
    // The busier relay first, and each asked only about its own writers. That
    // is the whole point: a small relay gets asked about its handful of people,
    // not about two thousand strangers.
    try testing.expectEqualStrings("wss://many.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 4), main.discoveredAuthorCount(0));
    try testing.expectEqualStrings("wss://few.example.com", main.discoveredUrlCopy(1, &buf).?);
    try testing.expectEqual(@as(usize, 2), main.discoveredAuthorCount(1));
}

test "the discovered pool is separate from the eight the outbox counts" {
    // `max_relays` is eight because a delivery is recorded in a `u8` bitmap,
    // one bit per slot. A ninth slot would silently stop being counted and
    // every note would look undelivered forever, so these connections live
    // past the pool and never publish.
    try testing.expectEqual(main.maxRelaysForTest + 1, main.discoveredWatchBaseForTest);
    try testing.expect(main.relayWatchSlotsForTest >= main.discoveredWatchBaseForTest + main.maxDiscoveredRelaysForTest);
    // And a discovered connection is watched by the keeper like any other, or a
    // relay nobody chose could half-open and sit there.
    try testing.expect(main.maxDiscoveredRelaysForTest > 0);
}

test "the ranking and the routing pick the same relays for one author" {
    // They did not, and the disagreement was invisible: an author listing
    // [A, A, B, C, D] had D counted by the ranking (which skipped the repeat
    // before counting against the cap) and dropped by the routing (which
    // counted raw tags), so D got a connection with nobody on it. One function
    // now, so they cannot drift again.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{8} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/drift.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The repeat is what does it: counted once by the selection, so the fourth
    // distinct relay is still inside the cap.
    const tags = [_]nostr.event.Tag{
        &.{ "r", "wss://a.example.com" },
        &.{ "r", "wss://a.example.com/" },
        &.{ "r", "wss://b.example.com" },
        &.{ "r", "wss://c.example.com" },
        &.{ "r", "wss://d.example.com" },
    };
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // The author names four distinct relays, and exactly two get connections:
    // coverage stops at the target, so a third relay carrying only somebody
    // already covered twice is a thread and a socket for nothing.
    //
    // Counting is the assertion, not "every slot with a url has authors": the
    // empty-relay guard makes that true whether or not the two selections
    // agree, and it masked this drift when the test was first written. A relay
    // the ranking counted and the routing dropped shows up as a missing
    // connection, which is the only place it is visible.
    var routed: usize = 0;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        if (main.discoveredUrlCopy(i, &buf) == null) continue;
        routed += 1;
        try testing.expect(main.discoveredAuthorCount(i) > 0);
    }
    try testing.expectEqual(@as(usize, main.routeCoverageTargetForTest), routed);

    // And the one author really is covered twice, which is what stopped it.
    const cov = main.routeCoverageForTest();
    try testing.expectEqual(@as(usize, 1), cov.reached);
    try testing.expectEqual(@as(usize, 1), cov.doubly_reached);
    try testing.expectEqual(@as(usize, 0), cov.residual);
}

test "an unchanged route table does not tell the connections to re-ask" {
    // The ranking reruns every time a relay list lands, and during a cold start
    // hundreds of them land. If each rerun bumped the generation, every
    // discovered connection would drop and redial each time, and the pool would
    // spend the whole startup reconnecting instead of reading. Seen in a live
    // run before this: three connections, each redialled inside two minutes,
    // for a route table that had not changed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{11} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/stable.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    const tags = [_]nostr.event.Tag{&.{ "r", "wss://steady.example.com" }};
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 10002, &tags, "", null);
    _ = try main.plazaIngestForTest(arena, ev);
    const follows = [_][32]u8{kp.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    main.rankRelaySuggestionsForTest(&store);
    const settled = main.discoveredGenerationForTest(0);
    const settled_1 = main.discoveredGenerationForTest(1);
    try testing.expectEqual(@as(usize, 1), main.discoveredCount());

    // Five more runs over the same store. Nothing has moved, so nothing should
    // be told that it has.
    for (0..5) |_| main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(settled, main.discoveredGenerationForTest(0));

    // But a real change still gets through: somebody else, writing elsewhere.
    const other = try signer.keyPairFromSecretKey([_]u8{12} ** 32);
    const other_tags = [_]nostr.event.Tag{&.{ "r", "wss://elsewhere.example.com" }};
    const other_ev = try nostr.event.create(arena, signer, other, 1_800_000_001, 10002, &other_tags, "", null);
    _ = try main.plazaIngestForTest(arena, other_ev);
    const both = [_][32]u8{ kp.public_key, other.public_key };
    _ = main.setFollowsForTest(&both, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);
    try testing.expectEqual(@as(usize, 2), main.discoveredCount());

    // The NEW relay's slot moved. The one that was already connected did not,
    // which is the whole point of a counter per slot: a stranger publishing a
    // relay list must not cost the connections that were already right.
    try testing.expect(main.discoveredGenerationForTest(1) != settled_1);
    try testing.expectEqual(settled, main.discoveredGenerationForTest(0));
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://steady.example.com", main.discoveredUrlCopy(0, &buf).?);
}

test "a relay that stays in the set keeps its seat" {
    // The choice comes back in coverage order, and that order moves whenever
    // anybody's relay list does. Filling the slots in that order would hand one
    // relay's socket to another because they swapped places in a ranking, and
    // both connections would be dropped and redialled to do it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/seat.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One author on `quiet`, so it is the only relay worth dialling and it
    // lands in slot 0.
    const quiet = [_][]const u8{"wss://quiet.example.com"};
    const one = [_][]const []const u8{&quiet};
    var first: [1][32]u8 = undefined;
    try seedRelayLists(arena, signer, &one, &first);
    _ = main.setFollowsForTest(&first, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://quiet.example.com", main.discoveredUrlCopy(0, &buf).?);
    const seat_gen = main.discoveredGenerationForTest(0);

    // Now three more people, all on `busy`. It outranks `quiet` by three to
    // one, so a coverage-ordered fill would put it in slot 0 and push `quiet`
    // into slot 1: two redials to learn nothing.
    const busy = [_][]const u8{"wss://busy.example.com"};
    const four = [_][]const []const u8{ &quiet, &busy, &busy, &busy };
    var follows: [4][32]u8 = undefined;
    try seedRelayLists(arena, signer, &four, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);

    // Both are routed, and `quiet` is still where it was.
    try testing.expectEqualStrings("wss://quiet.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqualStrings("wss://busy.example.com", main.discoveredUrlCopy(1, &buf).?);
    // Its question did not change either, so its counter did not move: the
    // socket is never touched.
    try testing.expectEqual(seat_gen, main.discoveredGenerationForTest(0));
}

test "a live connection is not dropped for one more author" {
    // Coverage is computed from relay lists that arrive one at a time, so the
    // margin between two candidates moves all day. Without a margin the set
    // flaps: one person's kind:10002 lands, a challenger passes the incumbent
    // by a single author, and a live socket is torn down to gain one.
    // One more author is not enough once a relay carries more than four, which
    // is where the twenty-five per cent comes from.
    try testing.expect(!main.worthEvictingForTest(6, 5));
    try testing.expect(!main.worthEvictingForTest(9, 8));
    try testing.expect(!main.worthEvictingForTest(31, 30));
    // Nor is a draw.
    try testing.expect(!main.worthEvictingForTest(4, 4));
    // A quarter more is, exactly at the line and past it.
    try testing.expect(main.worthEvictingForTest(5, 4));
    try testing.expect(main.worthEvictingForTest(10, 8));
    try testing.expect(main.worthEvictingForTest(40, 4));
    // An incumbent reaching nobody new is defending nothing.
    try testing.expect(main.worthEvictingForTest(1, 0));
    try testing.expect(main.worthEvictingForTest(0, 0));
}

/// Whether any routed slot is pointed at this relay.
pub fn routedHolds(url: []const u8) bool {
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        const u = main.discoveredUrlCopy(i, &buf) orelse continue;
        if (std.mem.eql(u8, u, url)) return true;
    }
    return false;
}

test "a route that changed in its last author has changed" {
    // Amethyst shipped this comparison as a `forEachIndexed` with a return
    // inside it, which returns from the lambda rather than the function, so
    // only the first filter was ever compared. A relay whose author list
    // changed anywhere but the front looked unchanged, and its subscription was
    // never replaced.
    var a: [4][32]u8 = undefined;
    for (&a, 0..) |*x, i| {
        x.* = [_]u8{0} ** 32;
        x[0] = @intCast(i + 1);
    }
    const url = "wss://same.example.com";

    var b = a;
    try testing.expect(main.sameRouteForTest(url, &a, url, &b));

    // The first.
    b = a;
    b[0][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // The LAST. This is the one that was broken.
    b = a;
    b[b.len - 1][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // And one in the middle, for completeness.
    b = a;
    b[2][31] = 9;
    try testing.expect(!main.sameRouteForTest(url, &a, url, &b));

    // A different relay, and a shorter list.
    b = a;
    try testing.expect(!main.sameRouteForTest(url, &a, "wss://other.example.com", &b));
    try testing.expect(!main.sameRouteForTest(url, &a, url, b[0..3]));
}

test "the same relay with a new question keeps its url and moves its counter" {
    // The two facts a live connection branches on when its slot moves: if the
    // url is the same it replaces its REQ in place, and if it is not it drops
    // the socket. So a change of WHO must move the counter and leave the url
    // alone, or the connection either never re-asks or redials to do it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/reask.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    const there = [_][]const u8{"wss://there.example.com"};
    const two = [_][]const []const u8{ &there, &there };
    var follows: [2][32]u8 = undefined;
    try seedRelayLists(arena, signer, &two, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("wss://there.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 2), main.discoveredAuthorCount(0));
    const before = main.discoveredGenerationForTest(0);

    // A third person, writing to the same relay. Same url, one more author.
    const three = [_][]const []const u8{ &there, &there, &there };
    var wider: [3][32]u8 = undefined;
    try seedRelayLists(arena, signer, &three, &wider);
    _ = main.setFollowsForTest(&wider, 1_800_000_001);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqualStrings("wss://there.example.com", main.discoveredUrlCopy(0, &buf).?);
    try testing.expectEqual(@as(usize, 3), main.discoveredAuthorCount(0));
    try testing.expect(main.discoveredGenerationForTest(0) != before);
}

test "a relay is set aside only after a run of failures, and not forever" {
    // A handshake fails for a blip as well as for a refusal, so one is not a
    // verdict. Measured in a single live run: the paid relay failed every time
    // and a free one in my own pool failed once and was fine on the retry.
    const strikes = main.routedRefusalStrikesForTest;
    const window = main.routedRefusalMsForTest;
    const t: i64 = 1_000_000;

    try testing.expect(!main.relayIsRefusedForTest(0, t, t));
    try testing.expect(!main.relayIsRefusedForTest(strikes - 1, t, t));
    try testing.expect(main.relayIsRefusedForTest(strikes, t, t));

    // Pinned against the literal, not against the constant. Everything else
    // here counts off `strikes`, so all of it stays true if the constant drops
    // to one and a single blip starts costing a relay six hours. This is the
    // line that refuses that, and it is the property, not the number.
    try testing.expect(main.routedRefusalStrikesForTest > 1);
    try testing.expect(!main.relayIsRefusedForTest(1, t, t));

    // A record with no timestamp is not a verdict either. Zero is a real
    // reading on some clocks, so "never" is -1 and it has to be distinguished.
    try testing.expect(!main.relayIsRefusedForTest(strikes, -1, t));

    // It expires. A subscription, a block and an outage all end.
    try testing.expect(main.relayIsRefusedForTest(strikes, t, t + window - 1));
    try testing.expect(!main.relayIsRefusedForTest(strikes, t, t + window));

    // With no clock, a strike already recorded still counts. Nothing is dialled
    // before the clock exists, so this is the safe reading rather than a live
    // case: it can only set a relay aside, never wrongly reinstate one.
    try testing.expect(main.relayIsRefusedForTest(strikes, t, null));
    try testing.expect(!main.relayIsRefusedForTest(strikes - 1, t, null));
}

test "a relay that will not have us gives up its slot to the next one down" {
    // Coverage says which relays carry the people you follow. It does not say
    // which of them will talk to you. The best relay by coverage on my own
    // account refuses the websocket handshake, and held a routed slot dialling
    // and failing forever while the coverage counter reported its writers as
    // reached.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/refused.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.forgetRefusedRelaysForTest();
    defer main.forgetRefusedRelaysForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // One relay each, two more relays than there are slots, so setting one
    // aside has somewhere for the slot to go. With slots to spare the choice
    // takes everything and being set aside costs nothing visible.
    const budget = main.maxDiscoveredRelaysForTest;
    const specs = try arena.alloc([]const []const u8, budget + 2);
    for (specs, 0..) |*spec, i| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = try std.fmt.allocPrint(arena, "wss://r{d:0>2}.example.com", .{i});
        spec.* = one;
    }
    const follows = try arena.alloc([32]u8, specs.len);
    try seedRelayLists(arena, signer, specs, follows);
    _ = main.setFollowsForTest(follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    try testing.expectEqual(budget, routedCount());
    // Whichever one it picked first: that is the one to refuse.
    var buf: [96]u8 = undefined;
    const chosen = main.discoveredUrlCopy(0, &buf).?;
    var chosen_owned: [96]u8 = undefined;
    @memcpy(chosen_owned[0..chosen.len], chosen);
    const victim = chosen_owned[0..chosen.len];

    // One strike short of the line changes nothing: a blip must not cost a
    // relay its slot.
    const t: i64 = 5_000_000;
    for (0..main.routedRefusalStrikesForTest - 1) |i| {
        try testing.expect(!main.noteRelayRefusalAtForTest(victim, t + @as(i64, @intCast(i))));
    }
    try testing.expectEqual(@as(usize, 0), main.refusedRelayCountForTest());
    main.rankRelaySuggestionsForTest(&store);
    try testing.expect(routedHolds(victim));

    // The strike that does it says so, so the caller knows to ask for a rethink
    // rather than waiting for somebody's relay list to land.
    try testing.expect(main.noteRelayRefusalAtForTest(victim, t + 10));
    try testing.expectEqual(@as(usize, 1), main.refusedRelayCountForTest());

    main.rankRelaySuggestionsForTest(&store);
    // Gone, and the slot went to a relay that might answer rather than being
    // left empty. Both halves matter: dropping it and shrinking the pool would
    // cost reach instead of recovering it.
    try testing.expect(!routedHolds(victim));
    try testing.expectEqual(budget, routedCount());

    // And it comes back when it starts working.
    main.clearRelayRefusalForTest(victim);
    try testing.expectEqual(@as(usize, 0), main.refusedRelayCountForTest());
}

test "a socket whose owner is blocked reading it is re-asked by the keeper" {
    // The owner of a routed connection cannot re-ask on its own. It spends its
    // life inside `receive`, which blocks until the relay says something, and a
    // relay with nothing new to say says nothing. Driving a route change under
    // a live connection and watching it not notice took forty seconds of a
    // real run, which is how this got written.
    const here = "wss://here.example.com";
    const there = "wss://there.example.com";

    // Nothing connected in this slot: nothing to do to it.
    try testing.expectEqual(main.RouteFollowUp.leave_it, main.routeFollowUpForTest("", 0, here, 7));
    // Connected and current.
    try testing.expectEqual(main.RouteFollowUp.leave_it, main.routeFollowUpForTest(here, 7, here, 7));
    // Same relay, the slot moved: replace the question, keep the socket. This
    // is the case the whole mechanism exists for.
    try testing.expectEqual(main.RouteFollowUp.re_ask, main.routeFollowUpForTest(here, 7, here, 8));
    // A trailing slash is the same relay, not a different one, or every
    // recompute would look like a repoint and redial the whole set.
    try testing.expectEqual(main.RouteFollowUp.re_ask, main.routeFollowUpForTest(here, 7, here ++ "/", 8));
    // Pointed at somebody else: close it.
    try testing.expectEqual(main.RouteFollowUp.retire, main.routeFollowUpForTest(here, 7, there, 8));
    // Slot emptied: close it.
    try testing.expectEqual(main.RouteFollowUp.retire, main.routeFollowUpForTest(here, 7, "", 8));
}

test "every routed connection asks under one subscription id" {
    // A REQ under an id the relay already holds is a replacement rather than a
    // second subscription, and that is the entire mechanism: two ids would
    // leave the old question standing and the relay would send both answers.
    try testing.expectEqualStrings("plaza-outbox", main.outboxSubIdForTest);
    // And it must not look like a one-shot, which is swept on a deadline.
    try testing.expect(!std.mem.startsWith(u8, main.outboxSubIdForTest, main.oneShotSubPrefixForTest));
}

test "the routing waits for the flurry to stop" {
    // A cold start lands hundreds of relay lists in a few seconds, and each one
    // is a reason to redo the ranking. Redoing it on each one is work the next
    // one throws away, and every intermediate answer is a route table nobody
    // should act on.
    const settle = main.routeSettleMsForTest;
    const floor = main.routeRecomputeMinMsForTest;
    const cap = main.routeSettleMaxMsForTest;

    // Nothing wanted, nothing to do.
    try testing.expect(!main.routeRecomputeDueForTest(null, null, null));
    // Wanted, and nothing has ever landed or run: the first ranking is not
    // delayed by a window it has no reason to wait for.
    try testing.expect(main.routeRecomputeDueForTest(0, null, null));

    // A list just landed. Wait for quiet.
    try testing.expect(!main.routeRecomputeDueForTest(1, 1, null));
    try testing.expect(!main.routeRecomputeDueForTest(settle - 1, settle - 1, null));
    try testing.expect(main.routeRecomputeDueForTest(settle, settle, null));

    // Quiet, but the last run was moments ago. The floor still holds.
    try testing.expect(!main.routeRecomputeDueForTest(settle, settle, floor - 1));
    try testing.expect(main.routeRecomputeDueForTest(settle, settle, floor));

    // A steady trickle, one list every second forever. Without the cap this
    // never runs at all.
    try testing.expect(!main.routeRecomputeDueForTest(cap - 1, 1, cap - 1));
    try testing.expect(main.routeRecomputeDueForTest(cap, 1, cap));
}

// -- Asking on a socket that is already open ---------------------------------
//
// A one-shot used to dial its own connection to every relay in turn: eight TLS
// handshakes and a parked thread to learn one display name. The pool already
// holds those sockets, and no shipping client dials for a one-shot.
//
// The property that makes sharing safe is that there is nothing to route back.
// Every event goes to the store on the thread that owns the socket, whoever
// asked, and the render thread reads the store. A subscription id names a
// question, never a caller waiting on an answer.

test "a one-shot subscription id is recognisable as one" {
    // The relay threads dispatch on this. Anything that is not the feed, the
    // inbox or a one-shot falls into the engagement arm and is counted as
    // somebody reacting to a note, so a question that does not announce itself
    // does not merely go unanswered: it inflates a tally.
    try testing.expect(main.isOneShotSubForTest(main.oneShotSubPrefixForTest ++ "profiles"));
    try testing.expect(main.isOneShotSubForTest(main.oneShotSubPrefixForTest ++ "quotes"));
    try testing.expect(!main.isOneShotSubForTest("plaza-feed"));
    try testing.expect(!main.isOneShotSubForTest("plaza-inbox"));
    try testing.expect(!main.isOneShotSubForTest("plaza-engagement"));
    try testing.expect(!main.isOneShotSubForTest("plaza-thread"));
}

test "asking the pool with nothing connected asks nobody, and does not dial" {
    // The whole point is that it uses sockets that already exist. With no live
    // connection there is nothing to write to, and the honest result is zero
    // relays asked rather than a connection opened to make the number look
    // better. A test binary must never reach the network.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://relay.example.com", true, true);

    const kinds = [_]u16{0};
    const authors = [_][32]u8{[_]u8{7} ** 32};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    try testing.expectEqual(@as(usize, 0), main.askPoolForTest(main.oneShotSubPrefixForTest ++ "profiles", &filters));
}

test "a write-only relay is not asked a question" {
    // Asking a relay that takes writes and answers no filters is asking it the
    // wrong thing. It keeps its socket, for publishing.
    //
    // Asserted on WHICH SLOTS are chosen, not on how many were asked. With no
    // live socket in a test every slot is skipped anyway, so a count passes
    // whether or not the read marker is honoured: removing the check failed
    // nothing when this test was first written.
    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://reads.example.com", true, false);
    _ = main.addRelayForTest("wss://writeonly.example.com", false, true);
    _ = main.addRelayForTest("wss://both.example.com", true, true);

    var slots: [8]usize = undefined;
    const n = main.askableSlotsForTest(&slots);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 0), slots[0]);
    try testing.expectEqual(@as(usize, 2), slots[1]);
}

// -- Every socket asks only about the people it can answer for ---------------
//
// The pool used to ask all eight of its relays about every followed author. Now
// each is asked about the follows who write there, plus the residual: everyone
// no relay in either set is being asked about.
//
// Defining the residual correctly is the whole risk. It is NOT "authors with no
// relay list": an author who publishes only to a relay that did not make the
// cut has a list and is still asked of nobody, and vanishes with no error and
// no empty state. That is the exact failure the outbox model exists to fix.

/// Seeds a store with one kind:10002 per author and returns the follow set.
pub fn seedRelayLists(
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    specs: []const []const []const u8,
    out: [][32]u8,
) !void {
    for (specs, 0..) |urls, i| {
        var secret = [_]u8{21} ** 32;
        secret[31] = @intCast(i + 1);
        const kp = try signer.keyPairFromSecretKey(secret);
        out[i] = kp.public_key;
        if (urls.len == 0) continue;
        var tags = try arena.alloc(nostr.event.Tag, urls.len);
        for (urls, 0..) |u, j| {
            const t = try arena.alloc([]const u8, 2);
            t[0] = "r";
            t[1] = u;
            tags[j] = t;
        }
        const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000 + @as(i64, @intCast(i)), 10002, tags, "", null);
        _ = try main.plazaIngestForTest(arena, ev);
    }
}

test "every followed author is asked of at least one relay" {
    // THE invariant. A follow that appears in nobody's filters is a person who
    // silently stops existing in the feed, which is worse than a slow feed and
    // is the thing routing is most likely to break while improving reach.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cover.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    _ = main.addRelayForTest("wss://mine.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // MORE distinct relays than the routed budget can hold, which is the whole
    // point: with only a couple of relays everything gets routed and the
    // residual is never exercised, so the test passes without testing anything.
    // Removing the residual entirely failed nothing until this list grew.
    //
    // One writes to the reader's own relay, two share a popular one, one has no
    // relay list at all, and the rest each write to a relay of their own that
    // is too unpopular to be chosen.
    const specs = [_][]const []const u8{
        &.{"wss://mine.example.com"},
        &.{"wss://busy.example.com"},
        &.{"wss://busy.example.com"},
        &.{},
        &.{"wss://lonely-a.example.com"},
        &.{"wss://lonely-b.example.com"},
        &.{"wss://lonely-c.example.com"},
        &.{"wss://lonely-d.example.com"},
        &.{"wss://lonely-e.example.com"},
        &.{"wss://lonely-f.example.com"},
    };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Collect every author named anywhere: the routed relays, then the pool.
    var seen = [_]bool{false} ** specs.len;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        var ubuf: [96]u8 = undefined;
        if (main.discoveredUrlCopy(i, &ubuf) == null) continue;
        var abuf: [main.discoveredAuthorsCapForTest][32]u8 = undefined;
        const n = main.discoveredAuthorsForTest(i, &abuf);
        for (abuf[0..n]) |a| {
            for (follows, 0..) |f, k| {
                if (std.mem.eql(u8, &a, &f)) seen[k] = true;
            }
        }
    }
    var pool_buf: [main.max_follows + 1][32]u8 = undefined;
    const pn = main.poolAuthorsForTest(0, &pool_buf);
    for (pool_buf[0..pn]) |a| {
        for (follows, 0..) |f, k| {
            if (std.mem.eql(u8, &a, &f)) seen[k] = true;
        }
    }

    for (seen, 0..) |ok, k| {
        if (!ok) {
            std.debug.print("\nfollow {d} is asked of no relay at all\n", .{k});
            return error.AuthorAskedOfNobody;
        }
    }

    // And the residual is actually carrying people here, or the loop above
    // proved coverage in a case where routing happened to reach everyone.
    try testing.expect(main.residualCountForTest() > 0);
}

test "coverage beats popularity when the popular relays carry the same crowd" {
    // The reason ranking and routing need different algorithms. Three relays
    // are popular and carry an overlapping crowd; one quiet relay is the only
    // way to reach two people. Top-N by popularity spends the whole budget on
    // the crowd and never reaches them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/cover2.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The crowd has to outnumber the budget or this proves nothing: with fewer
    // candidate relays than slots everything is dialled and the two orderings
    // cannot disagree. One person may name at most `outbox_relays_per_author`
    // relays, so the crowd comes in groups of that many, each group's relays
    // carrying only that group.
    const budget = main.maxDiscoveredRelaysForTest;
    const per_author = main.outboxRelaysPerAuthorForTest;
    const groups = (budget - 1) / 2;
    const per_group = 5;
    // Coverage needs two relays per group and one slot left for the quiet
    // relay, and popularity has to run out of budget before it reaches that
    // relay. If a change to the budget breaks either, this fails loudly rather
    // than passing hollow.
    try testing.expect(groups * 2 + 1 <= budget);
    try testing.expect(groups * per_author > budget);

    var specs = std.ArrayList([]const []const u8).empty;
    for (0..groups) |g| {
        const urls = try arena.alloc([]const u8, per_author);
        for (urls, 0..) |*u, j| u.* = try std.fmt.allocPrint(arena, "wss://crowd-{d}-{d}.example.com", .{ g, j });
        for (0..per_group) |_| try specs.append(arena, urls);
    }
    const quiet_url = "wss://onlyhere.example.com";
    const quiet = try arena.alloc([]const u8, 1);
    quiet[0] = quiet_url;
    try specs.append(arena, quiet);

    const follows = try arena.alloc([32]u8, specs.items.len);
    try seedRelayLists(arena, signer, specs.items, follows);
    _ = main.setFollowsForTest(follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    // Everybody reached, including the one nobody popular carries.
    const cov = main.routeCoverageForTest();
    try testing.expectEqual(specs.items.len, cov.reached);
    try testing.expectEqual(@as(usize, 0), cov.residual);
    try testing.expect(routedHolds(quiet_url));

    // And the popularity order really does leave that person out, which is the
    // half of this the coverage numbers cannot show. Every crowd relay carries
    // five writers against the quiet relay's one, so the suggestions never
    // mention it while the routing dials it.
    var sbuf: [96]u8 = undefined;
    for (0..main.relaySuggestionCount()) |i| {
        const u = main.relaySuggestionCopy(i, &sbuf) orelse continue;
        try testing.expect(!std.mem.eql(u8, u, quiet_url));
    }

    // The budget is not spent, either. Two relays per group is enough to carry
    // that group twice, so the greedy stops rather than opening sockets to
    // relays whose people are already covered.
    try testing.expectEqual(groups * 2 + 1, routedCount());
}

/// How many routed slots hold a relay.
fn routedCount() usize {
    var n: usize = 0;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        if (main.discoveredUrlCopy(i, &buf) != null) n += 1;
    }
    return n;
}

test "the candidate cap is counted, not swallowed" {
    // A cap that drops work in silence reads as a complete answer. This one was
    // hit exactly on a real account (128 distinct relays for 257 follows) and
    // nobody knew, because nothing said so.
    const cov = main.routeCoverageForTest();
    _ = cov;
    try testing.expect(@hasField(main.RouteCoverage, "candidates_dropped"));
}

test "a relay carrying only people the pool already covers twice is not dialled" {
    // What the pre-seed is for. The reader's own relays are already connected,
    // so whoever they carry is already reached; a routed slot spent on a relay
    // carrying only those people is a thread and a socket that reach nobody
    // new. Without counting the pool's coverage first, the greedy sees a big
    // number and takes it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/preseed.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.clearRelaysForTest();
    defer main.resetRelaysToBootstrapForTest();
    // TWO of the reader's own relays, so the crowd on them reaches the coverage
    // target without any routed relay at all.
    _ = main.addRelayForTest("wss://m1.example.com", true, true);
    _ = main.addRelayForTest("wss://m2.example.com", true, true);
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.setIdentityForTest([_]u8{77} ** 32);
    defer main.clearIdentityForTest();

    // The crowd writes to both of the reader's relays AND to a third the reader
    // is not on. That third one reaches nobody new. One more person writes only
    // somewhere else, and IS worth a slot.
    const crowd = [_][]const u8{ "wss://m1.example.com", "wss://m2.example.com", "wss://redundant.example.com" };
    const alone = [_][]const u8{"wss://only-here.example.com"};
    const specs = [_][]const []const u8{ &crowd, &crowd, &crowd, &crowd, &alone };
    var follows: [specs.len][32]u8 = undefined;
    try seedRelayLists(arena, signer, &specs, &follows);
    _ = main.setFollowsForTest(&follows, 1_800_000_000);
    main.rankRelaySuggestionsForTest(&store);

    var saw_redundant = false;
    var saw_only_here = false;
    var buf: [96]u8 = undefined;
    for (0..main.maxDiscoveredRelaysForTest) |i| {
        const u = main.discoveredUrlCopy(i, &buf) orelse continue;
        if (std.mem.eql(u8, u, "wss://redundant.example.com")) saw_redundant = true;
        if (std.mem.eql(u8, u, "wss://only-here.example.com")) saw_only_here = true;
    }
    // The one that reaches somebody new is dialled; the one that does not is
    // not, even though four follows write there and only one writes to the
    // other. Popularity would have picked it first.
    try testing.expect(saw_only_here);
    try testing.expect(!saw_redundant);
}

// -- A mention is a person, and pressing one says so --------------------------

test "rendering a mention records where its label landed and whom it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{7} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"jack\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "hey nostr:{s} welcome", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);

    try testing.expectEqualStrings("hey @jack welcome", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), mentions.all().len);
    const ref = mentions.all()[0];
    // The recorded range is the label in the RENDERED buffer, not the token in
    // the source: the pubkey is gone from the text by then, which is the whole
    // reason this table exists.
    try testing.expectEqualStrings("@jack", buf[ref.off..][0..ref.len]);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(ref.link()).?));
}

test "a mention's link payload is a person and an http link is not" {
    const pk = [_]u8{9} ** 32;
    var mentions = main.MentionList{};
    var buf: [64]u8 = undefined;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const npub = try nostr.nip19.encodeNpub(arena_state.allocator(), pk);
    const src = try std.fmt.allocPrint(arena_state.allocator(), "nostr:{s}", .{npub});
    _ = main.renderContentInto(&buf, src, &.{}, &mentions);

    try testing.expect(main.mentionLinkPubkey(mentions.all()[0].link()) != null);
    // Everything a paragraph's one link handler can otherwise be given. The two
    // share a message, so telling them apart is not a nicety: getting it wrong
    // means either a profile press shelling out to the browser, or a stranger's
    // URL being read as thirty-two bytes of pubkey.
    try testing.expect(main.mentionLinkPubkey("https://example.com/x") == null);
    try testing.expect(main.mentionLinkPubkey("") == null);
    // Exactly the payload's length, and starting with the same letter, and still
    // not a mention, because the byte after it is not zero.
    try testing.expect(main.mentionLinkPubkey("p" ++ ("a" ** 33)) == null);
    // Carrying the tag is not enough either. Without the length checked first,
    // these two read a pubkey out of a buffer that is not one: the short one
    // reaches past its end, and the long one takes the wrong thirty-two bytes.
    try testing.expect(main.mentionLinkPubkey("p\x00short") == null);
    try testing.expect(main.mentionLinkPubkey("p\x00" ++ ("z" ** 40)) == null);
}

test "a mention with a space in the name is one pressable span, not two" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ui = main.AppUi.init(arena);

    const pk = [_]u8{11} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"Sepehr Safari\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "gm nostr:{s} o/", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);
    const text = buf[0..n];

    const spans = main.contentSpansIn(&ui, text, mentions.all(), 0);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("gm ", spans[0].text);
    // The `@`-to-first-space heuristic reads this as `@Sepehr` and leaves the
    // surname behind as plain text. The recorded range knows how long the label
    // is because it is what wrote it.
    try testing.expectEqualStrings("@Sepehr Safari", spans[1].text);
    try testing.expectEqualStrings(" o/", spans[2].text);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(spans[1].link).?));
}

test "an offset recorded before the trim still points at the label after it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{13} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"ana\"}");

    // The picture is lifted out of the text and drawn as a picture, which is
    // what strands the whitespace the trim then removes, and the trim shifts
    // everything after it to the left.
    const image = "https://example.com/a.jpg";
    const src = try std.fmt.allocPrint(arena, "{s} nostr:{s}", .{ image, npub });
    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const n = main.renderContentInto(&buf, src, &.{image}, &mentions);

    try testing.expectEqualStrings("@ana", buf[0..n]);
    try testing.expectEqual(@as(usize, 1), mentions.all().len);
    const ref = mentions.all()[0];
    try testing.expectEqual(@as(u16, 0), ref.off);
    try testing.expectEqualStrings("@ana", buf[ref.off..][0..ref.len]);
}

test "mentions map onto a piece of the content, not only the whole of it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ui = main.AppUi.init(arena);

    const pk = [_]u8{17} ** 32;
    const npub = try nostr.nip19.encodeNpub(arena, pk);
    const p = main.upsertProfile(pk).?;
    main.parseMetadataInto(p, "{\"name\":\"bo\"}");

    var buf: [220]u8 = undefined;
    var mentions = main.MentionList{};
    const src = try std.fmt.allocPrint(arena, "hello nostr:{s}", .{npub});
    const n = main.renderContentInto(&buf, src, &.{}, &mentions);
    const text = buf[0..n];

    // What a body does when it splits around a quote card: the paragraph after
    // the rule is handed a slice starting part-way in, and the offsets recorded
    // against the whole have to be read relative to that.
    const tail_at: usize = 6;
    const spans = main.contentSpansIn(&ui, text[tail_at..], mentions.all(), tail_at);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("@bo", spans[0].text);
    try testing.expectEqualSlices(u8, &pk, &(main.mentionLinkPubkey(spans[0].link).?));

    // And with the offset NOT applied, the same mention is not found, so the
    // check above is testing the rebasing rather than passing for free.
    const wrong = main.contentSpansIn(&ui, text[tail_at..], mentions.all(), 0);
    try testing.expect(wrong.len == 0 or main.mentionLinkPubkey(wrong[0].link) == null);
}

// -- Reposting ----------------------------------------------------------------

// -- The mute list you already have -------------------------------------------

test "a refused host sends the face back through its own door, once" {
    defer main.resetProfilesForTest();
    const saved_on = main.mediaProxyOn();
    const saved_fb = main.mediaDirectFallback();
    defer {
        main.setMediaProxyOn(saved_on);
        main.setMediaDirectFallback(saved_fb);
    }
    main.setMediaProxyOn(true);
    main.setMediaDirectFallback(true);

    var fx: main.EffectsForTest = undefined;
    const pk = [_]u8{0x3b} ** 32;
    main.setProfileAvatarForTest(pk, 1, .fetching);

    // wsrv.nl's refusal of the HOST. The face goes back to idle so the next
    // pass asks again, and it is now pinned to its own host.
    main.deliverAvatarResponseForTest(&fx, pk, .ok, 400, "");
    const after = main.avatarFallbackStateForTest(pk).?;
    try testing.expect(after.idle);
    try testing.expect(after.direct);

    // Once. A second refusal, this time from the host itself, is a real
    // failure: there is nowhere else to ask, so it must not loop.
    main.setProfileAvatarForTest(pk, 1, .fetching);
    main.deliverAvatarResponseForTest(&fx, pk, .ok, 400, "");
    const again = main.avatarFallbackStateForTest(pk).?;
    try testing.expect(!again.idle);
}

// -- A note with more than one picture ----------------------------------------

test "a face assembles from slices too, and never outlives its fetch" {
    // Faces and banners were left on one request when pictures moved to slices,
    // so a full-size profile picture straight from its own host still drew
    // initials for exactly the reason a photo drew a blank cell. One Download,
    // three consumers.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetProfilesForTest();
    defer main.resetProfilesForTest();

    var fx: main.EffectsForTest = undefined;
    const pk = [_]u8{0x2a} ** 32;
    main.setProfileAvatarForTest(pk, 1, .fetching);

    const full = try arena.alloc(u8, main.maxImageBytesForTest());
    @memset(full, 0x5a);
    try testing.expectEqual(main.SliceOutcome.want_more, main.appendAvatarSliceForTest(pk, full).?);
    try testing.expectEqual(main.SliceOutcome.complete, main.appendAvatarSliceForTest(pk, "tail").?);
    try testing.expectEqual(@as(usize, 1), main.avatarPartialCountForTest());

    // The host stops answering partway through the next one: the bytes go with
    // the fetch, or a feed of failing hosts leaks megabytes of faces.
    main.deliverAvatarResponseForTest(&fx, pk, .timed_out, 0, "");
    try testing.expectEqual(@as(usize, 0), main.avatarPartialCountForTest());

    // And a busy effect table is the other way a fetch ends without an answer.
    // It sends the face back to idle to be asked again from the start, so what
    // it already had has to go with it: keeping it would splice the front of
    // one download onto the front of the next.
    _ = main.appendAvatarSliceForTest(pk, full);
    try testing.expectEqual(@as(usize, 1), main.avatarPartialCountForTest());
    main.deliverAvatarResponseForTest(&fx, pk, .rejected, 0, "");
    try testing.expectEqual(@as(usize, 0), main.avatarPartialCountForTest());
}

test "a follow with no relay list anywhere is asked once, not on every rebuild" {
    // The routing table is rebuilt whenever a relay list lands, and somebody who
    // has never published one is unroutable at every one of those rebuilds. If
    // the sweep re-asked each time, a single account with no kind:10002 would
    // put a REQ to four relays for the life of the session.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const nobody = try signer.keyPairFromSecretKey([_]u8{5} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/asked.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);

    main.resetRelaysForTest();
    main.forgetFollowsForTest();
    defer main.forgetFollowsForTest();
    main.resetIndexerAskedForTest();
    defer main.resetIndexerAskedForTest();
    main.setIdentityForTest([_]u8{89} ** 32);
    defer main.clearIdentityForTest();

    const follows = [_][32]u8{nobody.public_key};
    _ = main.setFollowsForTest(&follows, 1_800_000_000);

    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), main.collectUnroutedForTest(&out));

    // Once the sweep has put them to the indexers, they are off the list even
    // though the store still holds nothing for them: an attempt that came back
    // empty is still an attempt, which is what Amethyst's LRU gets wrong when
    // it evicts and resurrects a question already given up on.
    main.markIndexerAskedForTest(nobody.public_key);
    try testing.expectEqual(@as(usize, 0), main.collectUnroutedForTest(&out));
}

test "the indexers are asked, never joined, and never published as ours" {
    // They answer one question and are not part of the reader's identity. The
    // failure to avoid is Notedeck's, where the bootstrap set is spliced into
    // the user's own advertised relays the first time they edit their list, so
    // editing one relay publishes four you never chose.
    main.resetRelaysForTest();

    const before = main.relaySlots();
    for (main.indexerRelaysForTest()) |url| {
        try testing.expect(std.mem.startsWith(u8, url, "wss://"));
    }
    // Naming them does not dial them into the pool.
    try testing.expectEqual(before, main.relaySlots());

    // And the chunk stays inside what a relay will accept in one filter: an
    // unchunked 2000-author array is past the limit on most, and they truncate
    // or CLOSE without saying which.
    try testing.expect(main.indexerChunkForTest() <= 100);
    try testing.expect(main.indexerChunkForTest() > 0);
}

test "a long note is kept whole, not cut where the old buffer ended" {
    // The reported bug: a release announcement of ~1900 bytes was stored into a
    // 1024-byte buffer, so "Show more" expanded onto a note that stopped
    // mid-sentence. Nothing in the UI said a limit had been hit, because the
    // text just ended.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Built to the shape that broke: many short lines, well past the old cap.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(arena);
    var line: usize = 0;
    while (body.items.len < 1900) : (line += 1) {
        try body.print(arena, "line {d}: something worth reading to the end\n", .{line});
    }
    const written = try arena.dupe(u8, body.items);
    try testing.expect(written.len > 1024); // the old cap
    try testing.expect(written.len < main.noteContentCapForTest());

    var out: [main.note_content_cap_for_test]u8 = undefined;
    const n = main.renderContentInto(&out, written, &.{}, null);

    // Whole, and byte-identical against the SOURCE TRIMMED, because the renderer
    // strips leading and trailing whitespace on purpose. Trimming is the only
    // difference allowed here: nothing else about this content is rewritten, so
    // any other shortfall is a cut.
    const want = std.mem.trim(u8, written, " \t\r\n");
    try testing.expectEqual(want.len, n);
    try testing.expectEqualStrings(want, out[0..n]);

    // And the tail specifically, because a cut shows up at the END and a test
    // that only checks a length can pass on a buffer of zeroes.
    try testing.expect(std.mem.endsWith(u8, out[0..n], "to the end"));
}

test "thread replies order by arrival then time, and ties keep their order" {
    // sortThreadNotes sorts an array of indices and permutes the notes by
    // following cycles, because a Note is kilobytes and the standard library
    // refuses to sort an element type that large at all. The permutation is the
    // part worth pinning: a cycle walked wrong loses or duplicates a reply.
    var notes: [6]main.Note = .{ .{}, .{}, .{}, .{}, .{}, .{} };

    // Deliberately not already sorted, and with a tie in the middle: two notes
    // sharing (arrival, created_at) must come out in the order they went in.
    const seed = [_]struct { id: i64, arrival: u32, created_at: i64 }{
        .{ .id = 10, .arrival = 2, .created_at = 500 },
        .{ .id = 11, .arrival = 1, .created_at = 900 },
        .{ .id = 12, .arrival = 1, .created_at = 100 },
        .{ .id = 13, .arrival = 3, .created_at = 50 },
        .{ .id = 14, .arrival = 1, .created_at = 900 }, // ties with id 11
        .{ .id = 15, .arrival = 2, .created_at = 400 },
    };
    for (seed, 0..) |sd, i| {
        notes[i].id = sd.id;
        notes[i].arrival = sd.arrival;
        notes[i].created_at = sd.created_at;
    }

    main.sortThreadNotes(&notes);

    // arrival 1: 12 (t=100), then 11 and 14 (both t=900, input order kept).
    // arrival 2: 15 (t=400), then 10 (t=500). arrival 3: 13.
    const want = [_]i64{ 12, 11, 14, 15, 10, 13 };
    for (want, 0..) |id, i| {
        if (notes[i].id != id) {
            std.debug.print("position {d}: want id {d}, got {d}\n", .{ i, id, notes[i].id });
            return error.WrongOrder;
        }
    }

    // Every note still present exactly once: a mishandled cycle drops one and
    // duplicates another, which an order check alone can miss.
    var seen: [6]bool = @splat(false);
    for (notes) |n| {
        const idx: usize = @intCast(n.id - 10);
        if (seen[idx]) return error.DuplicatedNote;
        seen[idx] = true;
    }
    for (seen) |ok| try testing.expect(ok);
}

test "a whole batch arriving at once keeps the order it arrived in" {
    // A thread that loads in one go gives every reply the same arrival stamp,
    // and relays answer in whatever order they please, so this is the case that
    // decides whether a conversation can reshuffle under the reader between
    // rebuilds.
    //
    // Honest about what this test is: it pins the behaviour, it does not catch a
    // regression. Swapping the stable sort for the unstable one leaves it green,
    // because the unstable sort happens to preserve equal elements at these
    // sizes too. That is exactly why the comparator carries no tiebreak: a
    // second mechanism no probe can falsify is one to delete, not to keep.
    const n = 40;
    var notes: [n]main.Note = @splat(.{});
    for (0..n) |i| {
        notes[i].id = @intCast(1000 + i);
        notes[i].arrival = 7; // one batch
        notes[i].created_at = 12345; // written the same second
    }

    main.sortThreadNotes(&notes);

    for (0..n) |i| {
        const want: i64 = @intCast(1000 + i);
        if (notes[i].id != want) {
            std.debug.print("tie at {d}: want id {d}, got {d}\n", .{ i, want, notes[i].id });
            return error.TiesReordered;
        }
    }
}

test "a reply in the feed says what it answers" {
    // A feed that mixes replies in with root notes shows half a conversation:
    // an answer with no question reads as a non sequitur, or worse as something
    // the person said unprompted.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();

    const parent_id = [_]u8{0xab} ** 32;
    const parent_author = [_]u8{0xcd} ** 32;

    var note = main.Note{};
    note.id = 4242;
    note.reply_parent = parent_id;
    note.has_reply_parent = true;

    // Before the parent resolves the line is still there, holding its place,
    // saying the neutral thing rather than flickering a name in later.
    {
        const tree = try main.buildReplyContextForTest(arena, &note);
        try testing.expect(std.mem.indexOf(u8, tree, "reply to") != null);
    }

    // Once it resolves it names the author and shows the opening words.
    main.fillQuoteForTest(parent_id, parent_author, "sorry, only cold snow up here :D");
    {
        const tree = try main.buildReplyContextForTest(arena, &note);
        try testing.expect(std.mem.indexOf(u8, tree, "reply to") != null);
        if (std.mem.indexOf(u8, tree, "cold snow") == null) {
            std.debug.print("the line does not carry the answered note's words: {s}\n", .{tree});
            return error.NoSnippet;
        }
    }

    // A root note gets no line at all.
    var root = main.Note{};
    root.id = 99;
    try testing.expect(!root.has_reply_parent);
}

test "the snippet stops at one line and on a character boundary" {
    // A snippet cut mid-codepoint draws a replacement glyph, which is a worse
    // thing to show than a shorter snippet.
    const multi = "first line\nsecond line should never appear";
    try testing.expectEqualStrings("first line", main.firstLineOfForTest(multi, 200));

    // Cut inside a multi-byte character: the result must still be valid UTF-8.
    const emoji = "aaa\u{1F600}bbb";
    const cut = main.firstLineOfForTest(emoji, 5); // lands inside the 4-byte emoji
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualStrings("aaa", cut);
}

test "building a reply queues the note it answers, so the line can fill in" {
    // The line is only ever useful if something actually goes and fetches the
    // parent. `noteFrom` is where that has to happen, because it is the one
    // place every note in the feed passes through, and a test that fills the
    // cache by hand proves nothing about it.
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();

    const parent_hex = "ab" ** 32;
    const tags = [_]nostr.event.Tag{
        &.{ "e", parent_hex, "", "reply" },
    };
    const ev = nostr.event.Event{
        .id = [_]u8{0x11} ** 32,
        .pubkey = [_]u8{0x22} ** 32,
        .created_at = 1000,
        .kind = 1,
        .tags = &tags,
        .content = "answering you",
        .sig = [_]u8{0} ** 64,
    };

    const note = main.noteFrom(ev, 2000);
    try testing.expect(note.has_reply_parent);

    if (main.quoteForTest(note.reply_parent) == null) {
        std.debug.print("the answered note was never queued, so the line stays generic forever\n", .{});
        return error.ParentNeverRequested;
    }
}

/// WCAG relative luminance, for the one question a colour table cannot answer
/// by inspection: is this readable on the window it has to survive?
fn relativeLuminance(c: canvas.Color) f64 {
    const ch = struct {
        fn lin(v: f32) f64 {
            const x: f64 = @floatCast(v);
            return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * ch.lin(c.r) + 0.7152 * ch.lin(c.g) + 0.0722 * ch.lin(c.b);
}

fn contrastRatio(a: canvas.Color, b: canvas.Color) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

test "every community colour is readable as text on this window" {
    // `on_dark` is the one column in the table that is OURS rather than
    // Hallway's, and it exists for exactly one reason: Hallway's `primary` is a
    // fill, and several of the eighteen are unreadable as text on #0a0a0b
    // (INDIGO is about 2.5:1). The lightness floor that fixes that is not a
    // taste, it is the lowest one at which all eighteen clear 4.5:1, so it is
    // pinned here rather than left to whoever next edits a hex.
    const window = theme.palette.surface_window;
    var worst: f64 = 1000;
    var worst_name: []const u8 = "";
    for (theme.place_colors) |c| {
        const ratio = contrastRatio(c.on_dark, window);
        if (ratio < worst) {
            worst = ratio;
            worst_name = c.name;
        }
        if (ratio < 4.5) {
            std.debug.print("{s} reads at {d:.2}:1 on the window, under 4.5:1\n", .{ c.name, ratio });
            return error.UnreadableCommunityColour;
        }
        // And the ink has to survive the fill it is knocked out of. This is the
        // assertion that caught six rows where Hallway's own near-black ink is
        // unreadable on its own colour (VIOLET at 2.08:1). 4.0 rather than 4.5
        // because the floor is DEFAULT at 4.16:1, and lifting that would mean
        // altering the FILL -- the community's actual colour, which is theirs
        // and not ours to correct.
        const on_fill = contrastRatio(c.on_primary, c.primary);
        if (on_fill < 4.0) {
            std.debug.print("{s}: label reads at {d:.2}:1 on its own fill\n", .{ c.name, on_fill });
            return error.UnreadableLabelOnFill;
        }
    }
    // Worth knowing which one is closest to the edge when this next moves.
    try testing.expect(worst >= 4.5);
}

test "a logo body that arrives after you walk out is not painted on the new room" {
    // The fetch is keyed by a constant, so the answer carries no clue which room
    // asked. Taking `activePlace()` at delivery meant a body fetched for room A
    // and landing after a walk into room B was decoded into B's slot AND cached
    // under B's logo URL, so the wrong mark came back on every later visit and
    // every later launch. `handleBannerFetched` has carried this guard for
    // faces all along.
    var fx = main.inertEffectsForTest();
    main.resetPlacesForTest();
    defer main.resetPlacesForTest();

    // Asked for by Monero, delivered while standing in BASSPISTOL.
    main.visitPlaceForTest([_]u8{0xa2} ** 32, "outernational-dancehall", "BASSPISTOL");
    main.setPlaceLogoAskedForTest([_]u8{0xa1} ** 32, "moneroh");
    main.deliverPlaceLogoBodyForTest(&fx, "a body that is not this room's");

    // Dropped, and left idle so this room's own mark is still asked for. Not
    // `failed`: nothing about THIS room's logo has been tried yet.
    try testing.expectEqualStrings("idle", main.placeLogoStateNameForTest());
    try testing.expect(!main.placeLogoShownForTest());
}

test "the emoji face the Linux build registers parses, and carries colour emoji" {
    // The toolkit refuses a face whose `maxp` declares ANY glyph past its
    // outline budgets, and refuses the whole file rather than the one picture,
    // so a single over-detailed emoji costs every other one in it.
    //
    // This shipped that way once and I only found it by running the app on
    // Linux and reading the log: three glyphs of the face I was building then
    // were past the 1024-point budget, registration refused the face, text
    // silently fell back to plain Geist, and every emoji drew as a solid block.
    // The screenshot looked fine because nothing in view had an emoji in it.
    //
    // Embedded HERE rather than read through theme.zig on purpose: the app does
    // not embed this face on macOS (it has CoreText and does not need it), so
    // reading it from there would make this test check an empty string on the
    // platform most of the work happens on.
    const emoji = @embedFile("fonts/Twemoji.ttf");
    const font_ttf = native_sdk.canvas.font_ttf;
    const face = font_ttf.Face.parse(emoji) catch {
        if (font_ttf.parseFailureReason(emoji)) |why| std.debug.print("\nthe emoji face was refused: {s}\n", .{why});
        return error.TheEmojiFaceIsPastTheToolkitsBudget;
    };

    // Registering it is only half of it. The renderer falls back to a
    // registered face for a glyph the text face lacks ONLY when that face
    // carries colour, so a build that quietly swapped in a monochrome emoji
    // font would register fine and still draw blocks.
    if (!face.hasColorGlyphs()) return error.TheEmojiFaceIsNotAColourFace;

    // The pictures a note actually carries, including the ones above U+FFFF
    // that need a format-12 cmap to reach at all.
    for ([_]u21{ 0x1F600, 0x1F525, 0x1F389, 0x2764, 0x1F596, 0x2620, 0x1F44D }) |cp| {
        const glyph = face.glyphIndex(cp);
        if (glyph == 0) return error.AnEmojiIsMissingFromTheFace;
        if (face.colorLayerCount(glyph) == 0) return error.AnEmojiWouldDrawInOneColour;
    }

    // And it never shadows plain text. An emoji face claims the keycap bases
    // (the digits, `#`, `*`) because a keycap is built from one, so "2" IS in
    // this face as a picture. What keeps a digit a digit is that the renderer
    // asks the text face FIRST and only falls through for a codepoint it has
    // no glyph for, so the guarantee to check is Geist's coverage, not
    // Twemoji's.
    const geist = font_ttf.geist_regular;
    for ([_]u21{ 'A', 'z', '0', '9', '#', '*' }) |cp| {
        if (geist.glyphIndex(cp) == 0) return error.TheTextFaceWouldYieldPlainTextToTheEmojiFace;
    }
}

test "the scripts Geist cannot draw are covered by a face the Linux build registers" {
    // Off macOS there is no platform text provider, so the registered faces are
    // the only glyph source and a codepoint none of them carries is painted as
    // a SOLID FILLED RECTANGLE, not a placeholder outline. Geist covers Latin
    // and Cyrillic; its Greek is four maths symbols. Everything below used to
    // be blocks.
    //
    // Embedded here rather than read through theme.zig for the same reason the
    // emoji test does it: the app does not embed these on macOS, so reading
    // them from there would check empty strings on the platform this runs on.
    const font_ttf = native_sdk.canvas.font_ttf;
    const latin = font_ttf.Face.parse(@embedFile("fonts/NotoSans-Regular.ttf")) catch
        return error.TheNotoSansFaceIsRefused;
    const sc = font_ttf.Face.parse(@embedFile("fonts/NotoSansSC-Regular.ttf")) catch
        return error.TheNotoSansSCFaceIsRefused;
    const kr = font_ttf.Face.parse(@embedFile("fonts/NotoSansKR-Hangul.ttf")) catch
        return error.TheNotoSansKRFaceIsRefused;

    const geist = font_ttf.geist_regular;
    // One real word per script, not one character: a face can carry a stray
    // codepoint from a block it does not otherwise cover.
    const cases = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "Greek", .text = "Ελληνικά" },
        .{ .name = "Japanese hiragana", .text = "こんにちは" },
        .{ .name = "Japanese katakana", .text = "ナカムラ" },
        .{ .name = "Japanese kanji", .text = "日本語" },
        .{ .name = "Chinese", .text = "你好世界" },
        .{ .name = "Korean", .text = "안녕하세요" },
        .{ .name = "Cyrillic", .text = "Привет" },
    };
    for (cases) |case| {
        var i: usize = 0;
        while (i < case.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(case.text[i]) catch return error.BadFixture;
            const cp = std.unicode.utf8Decode(case.text[i .. i + len]) catch return error.BadFixture;
            i += len;
            if (geist.glyphIndex(cp) != 0) continue; // the text face draws it
            if (latin.glyphIndex(cp) != 0) continue;
            if (sc.glyphIndex(cp) != 0) continue;
            if (kr.glyphIndex(cp) != 0) continue;
            std.debug.print("\nno registered face carries U+{X:0>4} ({s})\n", .{ cp, case.name });
            return error.AScriptWouldStillDrawAsSolidBlocks;
        }
    }

    // The other half: these faces must not TAKE anything from Geist. The
    // renderer asks the text face first, so Latin stays Geist whatever else is
    // registered, and this pins the premise that makes that true.
    for ("The quick brown fox 0123456789") |ch| {
        if (geist.glyphIndex(ch) == 0) return error.TheTextFaceWouldYieldLatinToANotoFace;
    }
}

test "the weight faces the Linux build registers parse, and differ from regular" {
    // Off macOS the toolkit maps a span's weight onto reserved font ids and
    // bundles no face for any of them, so medium and bold ink REGULAR outlines
    // unless the app fills those ids. Plaza fills them from the same two files
    // CoreText is handed on macOS (main.zig `registered_fonts`).
    //
    // The failure this guards is silent: registration refuses a face whole if
    // its `maxp` is past the outline budgets, and the app then falls back to
    // regular and simply looks flat. Nothing crashes and no test would notice.
    const font_ttf = native_sdk.canvas.font_ttf;
    inline for (.{
        .{ "Geist-Medium.ttf", theme.geist_medium_ttf },
        .{ "Geist-Bold.ttf", theme.geist_bold_ttf },
    }) |entry| {
        const face = font_ttf.Face.parse(entry[1]) catch {
            if (font_ttf.parseFailureReason(entry[1])) |why| std.debug.print("\n{s} was refused: {s}\n", .{ entry[0], why });
            return error.AWeightFaceIsPastTheToolkitsBudget;
        };

        // A weight that draws the same outlines as regular is the defect, not
        // the fix. `M` is the widest Latin glyph, so a real weight step shows
        // in its advance; identical advances would mean the same face twice.
        const glyph = face.glyphIndex('M');
        if (glyph == 0) return error.AWeightFaceIsMissingTheLatinAlphabet;
        const regular = font_ttf.Face.parse(theme.geist_ttf) catch return error.TheRegularFaceIsRefused;
        const regular_m = regular.glyphIndex('M');
        const width = face.advance(glyph) * regular.units_per_em;
        const regular_width = regular.advance(regular_m) * face.units_per_em;
        if (width <= regular_width) return error.AWeightFaceIsNoHeavierThanRegular;
    }
}

test "a shortcut sends the message its tile sends" {
    // A key that reimplements what a control does is a second implementation to
    // keep in step, and this app has one already declared for compose and
    // settings. The places keys go through the same messages.
    try testing.expectEqual(main.Msg.toggle_places_rail, main.onCommandForTest("places-rail").?);
    try testing.expectEqual(main.Msg.place_bounce, main.onCommandForTest("place-bounce").?);
    try testing.expectEqual(main.Msg{ .place_step = -1 }, main.onCommandForTest("place-prev").?);
    try testing.expectEqual(main.Msg{ .place_step = 1 }, main.onCommandForTest("place-next").?);
    try testing.expect(main.onCommandForTest("no-such-key") == null);
}

test "every bundled face agrees about where the baseline is" {
    // The macOS host draws a run with `drawAtPoint:(x, baseline - size)` into a
    // flipped context, and AppKit then puts the baseline `round(ascender)`
    // below that point. Subtracting the point SIZE asserts "ascent == size",
    // which is a per-FACE number, so two faces on one line diverge by the
    // difference in their ascents.
    //
    // Ours did: Geist-Regular ships 920/-220/100 and the other three shipped
    // 1005/-295/0, which at a 14.5pt body put every medium, bold and mono run
    // exactly 2pt BELOW the regular text beside it. Mentions, the reply
    // context label, bold names next to regular meta: all of them sat low, and
    // nothing on the Zig side could see it, because the display list carries
    // one baseline for the whole line and is correct.
    //
    // scripts/harmonize-font-metrics.py made the four agree. This is what
    // notices if a font update ever pulls them apart again.
    const faces = [_]struct { name: []const u8, ttf: []const u8 }{
        .{ .name = "Geist-Regular", .ttf = theme.geist_ttf },
        .{ .name = "Geist-Medium", .ttf = theme.geist_medium_ttf },
        .{ .name = "Geist-Bold", .ttf = theme.geist_bold_ttf },
        .{ .name = "GeistMono-Regular", .ttf = theme.geist_mono_ttf },
    };

    var want: ?[6]i16 = null;
    for (faces) |face| {
        const m = try verticalMetrics(face.ttf);
        if (want) |w| {
            if (!std.mem.eql(i16, &w, &m)) {
                std.debug.print(
                    "\n{s} has vertical metrics {any}, and Geist-Regular has {any}.\n" ++
                        "Two faces that disagree draw on two different baselines. Run\n" ++
                        "  python3 scripts/harmonize-font-metrics.py\n",
                    .{ face.name, m, w },
                );
                return error.FacesDisagreeAboutTheBaseline;
            }
        } else want = m;
    }
    // And they agree on numbers that are actually there, not on all zeroes.
    try testing.expect(want.?[0] > 0);
}

/// hhea ascender/descender/lineGap and OS/2 sTypoAscender/Descender/LineGap,
/// read straight out of the sfnt. Six numbers, because macOS picks the typo set
/// when USE_TYPO_METRICS is on and the hhea set when it is not, and a face is
/// only safe if both agree with everyone else's.
fn verticalMetrics(ttf: []const u8) ![6]i16 {
    if (ttf.len < 12) return error.NotAFont;
    const count = std.mem.readInt(u16, ttf[4..6], .big);
    var hhea: ?usize = null;
    var os2: ?usize = null;
    for (0..count) |i| {
        const entry = 12 + i * 16;
        if (entry + 16 > ttf.len) return error.NotAFont;
        const tag = ttf[entry..][0..4];
        const off = std.mem.readInt(u32, ttf[entry + 8 ..][0..4], .big);
        if (std.mem.eql(u8, tag, "hhea")) hhea = off;
        if (std.mem.eql(u8, tag, "OS/2")) os2 = off;
    }
    const h = hhea orelse return error.NoHhea;
    const o = os2 orelse return error.NoOs2;
    if (h + 10 > ttf.len or o + 74 > ttf.len) return error.NotAFont;
    return .{
        std.mem.readInt(i16, ttf[h + 4 ..][0..2], .big),
        std.mem.readInt(i16, ttf[h + 6 ..][0..2], .big),
        std.mem.readInt(i16, ttf[h + 8 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 68 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 70 ..][0..2], .big),
        std.mem.readInt(i16, ttf[o + 72 ..][0..2], .big),
    };
}

test "a reply snippet stops saying npub once the name lands" {
    // The snippet is baked into text the same way a note body is: a mention
    // becomes "@Name", or an abbreviated npub when no name is known yet. A body
    // re-parses when a display name arrives, because the names generation
    // moving invalidates every card. The quote cache had no such stamp, so a
    // snippet rendered before its mentioned author's kind:0 landed kept the
    // npub for as long as the entry lived, which is the raw "@npub1..." showing
    // in a reply context line while the same person's name reads correctly two
    // rows down.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6d} ** 32);
    const mentioned = try signer.keyPairFromSecretKey([_]u8{0x6e} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/quote-names.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();

    main.resetProfilesForTest();
    main.resetQuotesForTest();
    defer main.resetProfilesForTest();
    defer main.resetQuotesForTest();

    // A note that mentions somebody nobody has a name for yet.
    const npub = try nostr.nip19.encodeNpub(arena, mentioned.public_key);
    const body = try std.fmt.allocPrint(arena, "hello nostr:{s} how are you", .{npub});
    const ev = try nostr.event.create(arena, signer, kp, 1_800_000_000, 1, &.{}, body, null);
    _ = try store.ingest(arena, ev, .{});

    main.wantQuoteForTest(ev.id);
    main.refreshQuotesForTest(&store);
    const before = main.quoteTextForTest(ev.id) orelse return error.TheQuoteNeverLoaded;
    if (std.mem.indexOf(u8, before, "npub1") == null) {
        std.debug.print("expected an npub while the name is unknown, got \"{s}\"\n", .{before});
        return error.NoNpubToBeginWith;
    }

    // The name lands, exactly as it does live: a kind:0 into the store, then
    // the profile pass that reads it and moves the names generation.
    var meta_buf: [128]u8 = undefined;
    const meta = try std.fmt.bufPrint(&meta_buf, "{{\"name\":\"Rabble\"}}", .{});
    const kind0 = try nostr.event.create(arena, signer, mentioned, 1_800_000_060, 0, &.{}, meta, null);
    _ = try store.ingest(arena, kind0, .{});
    main.refreshProfilesForTest(&store);
    main.refreshQuotesForTest(&store);

    const after = main.quoteTextForTest(ev.id) orelse return error.TheQuoteWentAway;
    if (std.mem.indexOf(u8, after, "npub1") != null) {
        std.debug.print("the snippet still says npub after the name landed: \"{s}\"\n", .{after});
        return error.TheSnippetKeptTheNpub;
    }
    try testing.expect(std.mem.indexOf(u8, after, "@Rabble") != null);
}

test "a paste that does not fit says so instead of vanishing" {
    // The composer caps the draft at 4096 and the retained editor caps at half
    // a megabyte, so a longer paste is clamped on the way in. Nothing read the
    // buffer's `truncated` flag, whose own documentation calls it a "loud seam
    // for paste", so the overflow disappeared without a word: the counter read
    // "0 left", which says the box is exactly full, not that a third of what
    // was just pasted is gone. Measured live at 6064 bytes pasted, 4096 kept,
    // 1968 lost, cut mid-word.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    // Something that fits: nothing to report.
    main.update(&model, .{ .draft_edit = .{ .insert_text = "a short note" } }, &fx);
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);

    // And something that does not.
    const cap = main.compose_capacity_for_test;
    const big = try arena_state.allocator().alloc(u8, cap + 500);
    @memset(big, 'x');
    main.update(&model, .{ .draft_edit = .{ .insert_text = big } }, &fx);
    if (model.draft_dropped == 0) {
        std.debug.print("{d} bytes went in over a {d} cap and nothing was reported\n", .{ big.len, cap });
        return error.TheOverflowVanishedInSilence;
    }
    // The draft is full, and what did not fit is exactly what was refused.
    try testing.expectEqual(cap, model.draft().len);
    try testing.expectEqual(big.len - (cap - "a short note".len), model.draft_dropped);

    // The composer says it, rather than "0 left".
    const line = main.composeReachForTest(arena_state.allocator(), model.draft().len, model.draft_dropped);
    if (std.mem.indexOf(u8, line, "did not fit") == null) {
        std.debug.print("the composer says \"{s}\"\n", .{line});
        return error.TheComposerNeverSaidSo;
    }

    // Clearing the box clears the warning with it.
    main.update(&model, .close_compose, &fx);
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);
}

test "every line break macOS draws and the layout does not becomes a plain LF" {
    // The toolkit breaks a line only at LF, and on macOS the host draws each
    // row through AppKit, which also breaks at these. A paste separated by any
    // of them drew the words after the break a row lower, on top of the next
    // row (#165). Reproduced live with CR, U+2028 and vertical tab.
    const Case = struct { in: []const u8, want: []const u8, changed: bool };
    const cases = [_]Case{
        .{ .in = "one\rtwo", .want = "one\ntwo", .changed = true },
        .{ .in = "one\r\rtwo", .want = "one\n\ntwo", .changed = true },
        .{ .in = "one\x0btwo\x0cthree", .want = "one\ntwo\nthree", .changed = true },
        .{ .in = "one\u{0085}two", .want = "one\ntwo", .changed = true },
        .{ .in = "one\u{2028}two\u{2029}three", .want = "one\ntwo\nthree", .changed = true },
        .{ .in = "trailing\r", .want = "trailing\n", .changed = true },
        .{ .in = "one\r\r\ntwo", .want = "one\n\r\ntwo", .changed = true },
        // Left alone. CRLF draws correctly, since its CR ends a row, and a
        // change would cost the caret and undo for nothing.
        .{ .in = "one\r\ntwo", .want = "one\r\ntwo", .changed = false },
        .{ .in = "one\r\n\r\ntwo", .want = "one\r\n\r\ntwo", .changed = false },
        .{ .in = "one\n\ntwo", .want = "one\n\ntwo", .changed = false },
        // Characters that share a leading byte with a separator.
        .{ .in = "caf\u{e9} \u{2026} \u{2022} \u{1F600}", .want = "caf\u{e9} \u{2026} \u{2022} \u{1F600}", .changed = false },
        // Truncated sequences at the very end are copied, not misread.
        .{ .in = "a\xe2\x80", .want = "a\xe2\x80", .changed = false },
        .{ .in = "a\xc2", .want = "a\xc2", .changed = false },
        .{ .in = "", .want = "", .changed = false },
    };
    for (cases) |c| {
        var out: [64]u8 = undefined;
        const got = main.plainLineBreaks(c.in, &out);
        testing.expectEqualStrings(c.want, got.text) catch |err| {
            std.debug.print("for input {any}\n", .{c.in});
            return err;
        };
        try testing.expectEqual(c.want.len, got.full_len);
        try testing.expectEqual(c.changed, got.changed);
    }
}

test "a full buffer stops at a character boundary and still counts the rest" {
    // "ab" then a three-byte character: with room for four bytes, the
    // character does not fit whole, so it is left out rather than cut, and
    // "cd", which would fit, is not written after the gap.
    var out: [4]u8 = undefined;
    const got = main.plainLineBreaks("ab\u{2026}cd", &out);
    try testing.expectEqualStrings("ab", got.text);
    try testing.expectEqual(@as(usize, 7), got.full_len);
}

test "a paste with CR line breaks lands in every multi-line box as LF" {
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    const pasted = "Alpha one.\rBravo two.\r\rCharlie three.\u{2028}Delta four.";
    const plain = "Alpha one.\nBravo two.\n\nCharlie three.\nDelta four.";

    main.update(&model, .{ .draft_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.draft());
    try testing.expectEqual(@as(usize, 0), model.draft_dropped);

    main.update(&model, .{ .reply_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.reply_buffer.text());

    main.update(&model, .{ .profile_about_edit = .{ .insert_text = pasted } }, &fx);
    try testing.expectEqualStrings(plain, model.profile_about_buffer.text());
}

test "a paste that had to change leaves the caret where the editor puts it" {
    // The editor takes the model's text when the two differ, and then puts
    // its caret at the end, with no way for the app to say otherwise. The
    // model's caret has to be there too, or the next key goes in somewhere
    // the reader cannot see: found live, typing after a mid-text paste.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.update(&model, .{ .draft_edit = .{ .insert_text = "Hello world" } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);

    main.update(&model, .{ .draft_edit = .{ .insert_text = "A\rB" } }, &fx);
    try testing.expectEqualStrings("HelloA\nB world", model.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(model.draft().len), model.draft_buffer.selection);
    main.update(&model, .{ .draft_edit = .{ .insert_text = "x" } }, &fx);
    try testing.expectEqualStrings("HelloA\nB worldx", model.draft());

    // A paste that needed no change is an ordinary edit, caret and all.
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .insert_text = "C\r\nD" } }, &fx);
    try testing.expectEqualStrings("HelloC\r\nDA\nB worldx", model.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(9), model.draft_buffer.selection);
}

test "a paste cut to fit keeps the caret where the editor puts it, and no lone CR" {
    // The editor holds the whole paste, the draft only what fits, so the
    // editor takes the draft's text and moves its caret to the end. A cut can
    // also land between a CR and its LF, which would leave exactly the lone CR
    // that #165 is about.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cap = main.compose_capacity_for_test;
    const start = "Hello world\nSecond line";
    const room = cap - start.len;

    // The cut lands between CR and LF.
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    main.update(&model, .{ .draft_edit = .{ .insert_text = start } }, &fx);
    main.update(&model, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const split = try arena_state.allocator().alloc(u8, room + 5);
    @memset(split, 'x');
    split[room - 1] = '\r';
    split[room] = '\n';
    main.update(&model, .{ .draft_edit = .{ .insert_text = split } }, &fx);
    try testing.expectEqual(cap, model.draft().len);
    if (std.mem.indexOfScalar(u8, model.draft(), '\r') != null) return error.ALoneCrSurvivedTheCut;
    try testing.expectEqual(canvas.TextSelection.collapsed(cap), model.draft_buffer.selection);

    // A plain paste cut to fit, in the middle of the text.
    var model2 = main.initialModel();
    model2.stage = .ready;
    model2.composing = true;
    main.update(&model2, .{ .draft_edit = .{ .insert_text = start } }, &fx);
    main.update(&model2, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const long = try arena_state.allocator().alloc(u8, room + 100);
    @memset(long, 'y');
    main.update(&model2, .{ .draft_edit = .{ .insert_text = long } }, &fx);
    try testing.expectEqual(canvas.TextSelection.collapsed(cap), model2.draft_buffer.selection);

    // Refused outright, into a full draft: nothing here changes, and the
    // caret stays where it was.
    main.update(&model2, .{ .draft_edit = .{ .set_selection = canvas.TextSelection.collapsed(5) } }, &fx);
    const full = try arena_state.allocator().dupe(u8, model2.draft());
    main.update(&model2, .{ .draft_edit = .{ .insert_text = "p\rq" } }, &fx);
    try testing.expectEqualStrings(full, model2.draft());
    try testing.expectEqual(canvas.TextSelection.collapsed(5), model2.draft_buffer.selection);
}

test "a paste that does not fit is counted after its line breaks are made plain" {
    // Past the cap, the overflow reported is measured in what the draft would
    // have held.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    const cap = main.compose_capacity_for_test;
    // cap + 1 bytes of U+2028, three bytes each on the way in and one once
    // plain: cap + 1 plain bytes asked for, cap of them fit.
    const big = try arena_state.allocator().alloc(u8, (cap + 1) * 3);
    for (0..cap + 1) |i| @memcpy(big[i * 3 ..][0..3], "\u{2028}");
    main.update(&model, .{ .draft_edit = .{ .insert_text = big } }, &fx);
    try testing.expectEqual(cap, model.draft().len);
    try testing.expect(std.mem.indexOfScalar(u8, model.draft(), 0xE2) == null);
    try testing.expectEqual(@as(usize, 1), model.draft_dropped);
}

test "a private half Notary has not opened yet is unreadable, not empty" {
    // The distinction this whole cache exists for. Plaza used to open the
    // private half of a NIP-51 list inline against a secret key in this
    // process; there is no secret here now, so it asks the keyholder, and an
    // answer that has not arrived yet must not read as "the half is empty".
    //
    // Treating them alike is how a client publishes a list back with every
    // private entry deleted. Jumble does exactly that, which is why the guard
    // this feeds was written in the first place.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();

    // No keyholder has opened anything, and nothing can: there is no identity,
    // so the stand-in cannot answer either.
    const ciphertext = "AqRcpq0Cw2h2Vd5Tk1Fk5w==?iv=notarealciphertext";
    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), main.privateMutesForTest(ciphertext, &out));
    // Zero mutes AND unreadable, which is not the same as zero mutes and empty.
    try testing.expect(!main.privateHalfIsReadableForTest(ciphertext));
}

test "an opened private half is read without asking again" {
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();

    const ciphertext = "whatever-the-keyholder-was-given";
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{[_]u8{0x5a} ** 32});
    const plain = try std.fmt.allocPrint(testing.allocator, "[[\"p\",\"{s}\"]]", .{hex});
    defer testing.allocator.free(plain);

    main.openPrivateHalfForTest(ciphertext, plain);
    try testing.expect(main.privateHalfIsReadableForTest(ciphertext));

    var out: [8][32]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), main.privateMutesForTest(ciphertext, &out));
    try testing.expectEqualSlices(u8, &[_]u8{0x5a} ** 32, &out[0]);
}

test "a keyholder that refuses to open a private half leaves it unreadable" {
    // The other half of the same distinction, and the one an app meets in
    // practice: Notary answering 403 because nobody approved the decrypt, or
    // 409 because the key is locked, or not answering at all.
    //
    // None of those means the list is empty. Recording them as "open with no
    // content" would publish the list back with every private entry deleted,
    // which is the bug this whole cache is shaped around.
    main.forgetPrivateHalvesForTest();
    defer main.forgetPrivateHalvesForTest();
    main.clearIdentityForTest();

    const ciphertext = "a-half-the-keyholder-will-not-open";

    for ([_]u16{ 403, 409, 500, 0 }) |status| {
        main.askPrivateHalfForTest(ciphertext);
        main.deliverPrivateHalfForTest(status, "{\"error\":\"refused\"}");
        if (main.privateHalfIsReadableForTest(ciphertext)) {
            std.debug.print("\nstatus {d} was treated as a readable half\n", .{status});
            return error.RefusalReadAsEmpty;
        }
    }

    // And an answer carrying no items is not an empty list either.
    main.askPrivateHalfForTest(ciphertext);
    main.deliverPrivateHalfForTest(200, "{\"items\":[]}");
    try testing.expect(!main.privateHalfIsReadableForTest(ciphertext));
}

test "an address Plaza cannot read keeps the field open with what was typed in it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    try testing.expect(model.address_open);

    // Starts like an address and does not decode. Plain words would not do: the
    // same field finds people by name, so those are a search and not a refusal.
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "npub1notreal" } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // Open, with the text still there: the reader is about to fix a character,
    // and a field that empties itself on a refusal makes them paste again.
    try testing.expect(model.address_open);
    try testing.expectEqualStrings("npub1notreal", model.address_draft());
    try testing.expectEqual(main.AddressError.unreadable, model.address_error);

    // And the sheet says so, rather than still offering the hint.
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContainingText(tree.root, "not an address Plaza can read") != null);

    // Typing is the answer to the refusal, so the refusal goes at once.
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "n" } }, &fx);
    try testing.expectEqual(main.AddressError.none, model.address_error);
}

test "opening an address puts the field away before it navigates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]u8{0x55} ** 32;
    const note1 = try nostr.nip19.encodeNote(arena, id);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = note1 } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // Closed, and emptied. Every destination behind this has an early return in
    // front of it, so closing on arrival would leave the sheet up in exactly
    // the cases where the reader has least idea why nothing moved.
    try testing.expect(!model.address_open);
    try testing.expectEqualStrings("", model.address_draft());

    // Nothing holds this note, so it was asked for rather than silently dropped.
    try testing.expect(main.quoteHintCountForTest(id) != null);
}

test "the relays an address named reach the fetch that goes looking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();

    const id = [_]u8{0x66} ** 32;
    const pk = [_]u8{0x77} ** 32;
    const relays = [_][]const u8{ "wss://hinted.example", "wss://also.example" };

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNevent(arena, id, &relays, pk, 1) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);

    // This is the whole of #259 on the event side: without it the fetch asks
    // only relays the reader already reads, and the card settles on "no relay
    // has" a note that one of these two is holding.
    try testing.expectEqual(@as(?u8, 2), main.quoteHintCountForTest(id));

    // An nprofile names a person the same way.
    main.update(&model, Msg.open_address, &fx);
    main.update(&model, Msg{ .address_edit = .{ .insert_text = try nostr.nip19.encodeNprofile(arena, pk, &relays) } }, &fx);
    main.update(&model, Msg.address_submit, &fx);
    try testing.expectEqual(@as(?u8, 2), main.profileHintCountForTest(pk));
}

/// A store in a temp dir and a model at the feed, with a way to paste into
/// the address field: what the address tests below start from.
pub const AddressFixture = struct {
    tmp: testing.TmpDir,
    store: nostr.store.Store,
    model: main.Model,
    fx: main.EffectsForTest = undefined,

    pub fn up(self: *AddressFixture, name: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        var pbuf: [128]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ self.tmp.sub_path, name });
        self.store = try nostr.store.Store.open(db_path, .{});
        main.setStoreForTest(&self.store);
        main.resetPlacesForTest();
        main.resetQuotesForTest();
        self.model = main.initialModel();
        self.model.stage = .ready;
    }

    pub fn down(self: *AddressFixture) void {
        main.resetPlacesForTest();
        main.setStoreForTest(null);
        self.store.deinit();
        self.tmp.cleanup();
    }

    pub fn paste(self: *AddressFixture, text: []const u8) void {
        main.update(&self.model, Msg.open_address, &self.fx);
        main.update(&self.model, Msg{ .address_edit = .{ .insert_text = text } }, &self.fx);
        main.update(&self.model, Msg.address_submit, &self.fx);
    }
};

test "an address opened over Settings leaves Settings so the result is seen" {
    // Cmd+L works over Settings, and the destination is drawn UNDER it. Press
    // Open and the dialog closed, Settings stayed up, and nothing visible
    // happened; the page only appeared after Close.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f: AddressFixture = undefined;
    try f.up("oversettings");
    defer f.down();

    const who = [_]u8{0x3f} ** 32;
    main.update(&f.model, Msg.open_settings, &f.fx);
    try testing.expectEqual(main.Stage.settings, f.model.stage);
    f.paste(try nostr.nip19.encodeNpub(arena, who));

    try testing.expectEqual(main.Stage.ready, f.model.stage);
    try testing.expect(!f.model.address_open);
    try testing.expectEqual(@as(?[32]u8, who), f.model.viewing_profile);

    // A refusal is not a destination: the sheet stays up over Settings with
    // what was typed, and Settings stays put under it.
    main.update(&f.model, Msg.open_settings, &f.fx);
    f.paste("not an address");
    try testing.expectEqual(main.Stage.settings, f.model.stage);
    try testing.expect(f.model.address_open);
}

test "a quoted note in a note body keeps the relays its address named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();

    const id = [_]u8{0x88} ** 32;
    const relays = [_][]const u8{"wss://quoted-lives-here.example"};
    const body = try std.fmt.allocPrint(arena, "look at this nostr:{s}", .{
        try nostr.nip19.encodeNevent(arena, id, &relays, [_]u8{0x99} ** 32, 1),
    });

    // The ordinary path: a note arrives in the feed carrying a quote, and the
    // scan that finds the quote is where the hints were being dropped.
    _ = main.findQuoteRefForTest(body);
    try testing.expectEqual(@as(?u8, 1), main.quoteHintCountForTest(id));
}

/// The app's own Zig files, for the tests that read the source rather than run
/// it. Listed by hand because `@embedFile` needs a literal path; the network
/// gate test fails when main.zig imports a file that is not on this list.
const AppSource = struct { name: []const u8, text: []const u8 };
pub const app_sources = [_]AppSource{
    .{ .name = "main.zig", .text = @embedFile("main.zig") },
    .{ .name = "theme.zig", .text = @embedFile("theme.zig") },
    .{ .name = "plaza_icons.zig", .text = @embedFile("plaza_icons.zig") },
    .{ .name = "search.zig", .text = @embedFile("search.zig") },
    .{ .name = "article.zig", .text = @embedFile("article.zig") },
    .{ .name = "blossom.zig", .text = @embedFile("blossom.zig") },
    .{ .name = "tuning.zig", .text = @embedFile("tuning.zig") },
    .{ .name = "hiding.zig", .text = @embedFile("hiding.zig") },
    .{ .name = "prefs.zig", .text = @embedFile("prefs.zig") },
    .{ .name = "updates.zig", .text = @embedFile("updates.zig") },
    .{ .name = "links.zig", .text = @embedFile("links.zig") },
    .{ .name = "login.zig", .text = @embedFile("login.zig") },
    .{ .name = "places.zig", .text = @embedFile("places.zig") },
    .{ .name = "relay_table.zig", .text = @embedFile("relay_table.zig") },
    .{ .name = "relay_list.zig", .text = @embedFile("relay_list.zig") },
    .{ .name = "routing.zig", .text = @embedFile("routing.zig") },
    .{ .name = "relay_conn.zig", .text = @embedFile("relay_conn.zig") },
    .{ .name = "store_glue.zig", .text = @embedFile("store_glue.zig") },
    .{ .name = "feed_state.zig", .text = @embedFile("feed_state.zig") },
    .{ .name = "thread_model.zig", .text = @embedFile("thread_model.zig") },
    .{ .name = "note_build.zig", .text = @embedFile("note_build.zig") },
    .{ .name = "profile_cache.zig", .text = @embedFile("profile_cache.zig") },
    .{ .name = "person_card.zig", .text = @embedFile("person_card.zig") },
    .{ .name = "quote_cache.zig", .text = @embedFile("quote_cache.zig") },
    .{ .name = "addresses.zig", .text = @embedFile("addresses.zig") },
    .{ .name = "link_preview.zig", .text = @embedFile("link_preview.zig") },
    .{ .name = "relay_hints.zig", .text = @embedFile("relay_hints.zig") },
    .{ .name = "engagement.zig", .text = @embedFile("engagement.zig") },
    .{ .name = "inbox.zig", .text = @embedFile("inbox.zig") },
    .{ .name = "image_cache.zig", .text = @embedFile("image_cache.zig") },
    .{ .name = "image_pool.zig", .text = @embedFile("image_pool.zig") },
    .{ .name = "feed_media.zig", .text = @embedFile("feed_media.zig") },
    .{ .name = "own_lists.zig", .text = @embedFile("own_lists.zig") },
    .{ .name = "follows.zig", .text = @embedFile("follows.zig") },
    .{ .name = "mutes.zig", .text = @embedFile("mutes.zig") },
    .{ .name = "bookmarks.zig", .text = @embedFile("bookmarks.zig") },
    .{ .name = "private_lists.zig", .text = @embedFile("private_lists.zig") },
    .{ .name = "keyholder.zig", .text = @embedFile("keyholder.zig") },
    .{ .name = "remote_signer.zig", .text = @embedFile("remote_signer.zig") },
    .{ .name = "drafts.zig", .text = @embedFile("drafts.zig") },
    .{ .name = "session.zig", .text = @embedFile("session.zig") },
    .{ .name = "own_profile.zig", .text = @embedFile("own_profile.zig") },
    .{ .name = "uploads.zig", .text = @embedFile("uploads.zig") },
    .{ .name = "media_servers.zig", .text = @embedFile("media_servers.zig") },
    .{ .name = "view_upload.zig", .text = @embedFile("view_upload.zig") },
    .{ .name = "compose.zig", .text = @embedFile("compose.zig") },
    .{ .name = "outbox.zig", .text = @embedFile("outbox.zig") },
    .{ .name = "people_search.zig", .text = @embedFile("people_search.zig") },
    .{ .name = "profile_notes.zig", .text = @embedFile("profile_notes.zig") },
    .{ .name = "navigation.zig", .text = @embedFile("navigation.zig") },
    .{ .name = "relay_auth.zig", .text = @embedFile("relay_auth.zig") },
    .{ .name = "ingest.zig", .text = @embedFile("ingest.zig") },
    .{ .name = "view_media.zig", .text = @embedFile("view_media.zig") },
    .{ .name = "view_note.zig", .text = @embedFile("view_note.zig") },
    .{ .name = "view_chrome.zig", .text = @embedFile("view_chrome.zig") },
    .{ .name = "view_place.zig", .text = @embedFile("view_place.zig") },
    .{ .name = "view_rail.zig", .text = @embedFile("view_rail.zig") },
    .{ .name = "view_feed.zig", .text = @embedFile("view_feed.zig") },
    .{ .name = "view_profile.zig", .text = @embedFile("view_profile.zig") },
    .{ .name = "view_article.zig", .text = @embedFile("view_article.zig") },
    .{ .name = "view_thread.zig", .text = @embedFile("view_thread.zig") },
    .{ .name = "view_compose.zig", .text = @embedFile("view_compose.zig") },
    .{ .name = "view_notifications.zig", .text = @embedFile("view_notifications.zig") },
    .{ .name = "view_search.zig", .text = @embedFile("view_search.zig") },
    .{ .name = "view_sheets.zig", .text = @embedFile("view_sheets.zig") },
    .{ .name = "view_settings.zig", .text = @embedFile("view_settings.zig") },
    .{ .name = "view_app.zig", .text = @embedFile("view_app.zig") },
};

test "no thread that dials a relay is spawned without a gate above it" {
    // The September segfault was a detached worker dialling real relays from a
    // unit test and writing into a store the test was tearing down. The fix
    // reached three fetchers. Five more had the same shape, and one of them was
    // not latent: driving `.place_feed` in this very file opened eight real
    // sockets a run, to nos.lol and offchain.pub among others.
    //
    // So this asserts the RULE rather than those five call sites. It reads the
    // source, finds every function that reaches `nostr.relay.dial`, finds every
    // place one of them is spawned, and requires a gate between the start of
    // the spawning function and the spawn itself. Add a network worker with no
    // gate and this fails by name, whether or not a test happens to reach it.
    // The scan below is only as good as its list of files.
    var lines = std.mem.splitScalar(u8, app_sources[0].text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "const ")) continue;
        const open = "= @import(\"";
        const at = std.mem.indexOf(u8, line, open) orelse continue;
        const rest = line[at + open.len ..];
        const file = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse continue];
        if (!std.mem.endsWith(u8, file, ".zig")) continue;
        for (app_sources) |s| {
            if (std.mem.eql(u8, s.name, file)) break;
        } else {
            std.debug.print("\n  main.zig imports {s}, which app_sources in tests.zig does not list.\n", .{file});
            return error.UnlistedSource;
        }
    }

    const alloc = testing.allocator;

    // Every file of the app, joined: a worker and the code that spawns it can
    // sit in different files, and both have to be seen.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (app_sources) |s| {
        try joined.append(alloc, '\n');
        try joined.appendSlice(alloc, s.text);
    }

    // `pub fn` folded into `fn` so one split finds both.
    const flat = try std.mem.replaceOwned(u8, alloc, joined.items, "\npub fn ", "\nfn ");
    defer alloc.free(flat);

    // Every function whose body reaches the network. Derived, not listed: a
    // list here would be the next thing to drift.
    var dialers: std.ArrayList([]const u8) = .empty;
    defer dialers.deinit(alloc);
    var fns = std.mem.splitSequence(u8, flat, "\nfn ");
    _ = fns.next();
    while (fns.next()) |chunk| {
        const paren = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const name = chunk[0..paren];
        if (std.mem.indexOfAny(u8, name, " \n\t") != null) continue;
        if (std.mem.indexOf(u8, chunk, "nostr.relay.dial") != null) {
            try dialers.append(alloc, name);
        }
    }
    try testing.expect(dialers.items.len > 0);

    for (dialers.items) |worker| {
        const needle = try std.fmt.allocPrint(alloc, "std.Thread.spawn(.{{}}, {s},", .{worker});
        defer alloc.free(needle);

        var from: usize = 0;
        while (std.mem.indexOfPos(u8, flat, from, needle)) |at| {
            from = at + needle.len;
            // The enclosing function: the last `\nfn ` before the spawn.
            const start = std.mem.lastIndexOf(u8, flat[0..at], "\nfn ") orelse 0;
            const body = flat[start..at];
            const gated = std.mem.indexOf(u8, body, "relayFetchAllowed()") != null or
                std.mem.indexOf(u8, body, "networkAllowed()") != null;
            if (!gated) {
                const fn_end = std.mem.indexOfScalar(u8, flat[start + 4 ..], '(') orelse 0;
                std.debug.print(
                    "\n  {s} reaches nostr.relay.dial and is spawned by {s} with no" ++
                        " relayFetchAllowed() or networkAllowed() above it.\n" ++
                        "  A unit test that reaches this opens a real socket.\n",
                    .{ worker, flat[start + 4 ..][0..fn_end] },
                );
                return error.UngatedNetworkThread;
            }
        }
    }
}

test "every glyph the rail asks for is a real glyph" {
    // `ui.icon` does not fail on a name nobody registered: `resolveOrMissing`
    // hands back a placeholder, so a typo or a glyph that left the toolkit
    // draws a box and every tree assertion still passes. The tile test below
    // finds the press and would not notice.
    //
    // Both tables, because the rail draws from both: `railTile` takes a BUILT-IN
    // by name through `ui.icon`, `railDest` takes one of Plaza's own through
    // `ui.appIcon`.
    main.registerIcons();
    const builtin_names = [_][]const u8{ "search", "edit", "settings", "play" };
    for (builtin_names) |name| {
        if (canvas.icons.find(name) == null) {
            std.debug.print("\n  the toolkit has no built-in glyph named \"{s}\"\n", .{name});
            return error.RailAsksForAMissingGlyph;
        }
    }
    const app_names = [_][]const u8{ "mark", "bell", "places" };
    for (app_names) |name| {
        if (canvas.icons.resolve(name) == null) {
            std.debug.print("\n  no registered app glyph named \"{s}\"\n", .{name});
            return error.RailAsksForAMissingGlyph;
        }
    }
}

// ------------------------------------------------------ noticing a new release

fn releaseDoc(arena: std.mem.Allocator, tag: []const u8, extra: []const u8) []const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"tag_name":"{s}","html_url":"https://github.com/zig-nostr/plaza/releases/tag/{s}","name":"Plaza {s}"{s}}}
    , .{ tag, tag, tag, extra }) catch unreachable;
}

test "a newer release is newer by order, not by spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;

    // The one that matters. "0.9.0" sorts AFTER "0.10.0" as text, so a string
    // inequality offers an upgrade that is a downgrade, once per launch forever.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.10.0", ""), "0.9.0", &v, &u) != null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.9.0", ""), "0.10.0", &v, &u) == null);

    // Ordinary forward, and the two that are not news.
    if (main.newerRelease(releaseDoc(arena, "v0.21.0", ""), "0.20.1", &v, &u)) |news| {
        try testing.expectEqualStrings("0.21.0", v[0..news.version_len]);
        try testing.expectEqualStrings("https://github.com/zig-nostr/plaza/releases/tag/v0.21.0", u[0..news.url_len]);
    } else return error.MissedANewerRelease;
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.20.1", ""), "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.20.0", ""), "0.20.1", &v, &u) == null);

    // Every component, so a major or minor bump is not read off the patch alone.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v1.0.0", ""), "0.99.99", &v, &u) != null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ""), "0.20.99", &v, &u) != null);
}

test "a release nobody should be sent to is not news" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;

    // A draft or a prerelease is not something to point somebody at, even
    // though neither appears on `/releases/latest` today.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"draft\":true"), "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"prerelease\":true"), "0.20.1", &v, &u) == null);
    // And the same document with both false IS news, so the guard above is
    // reading the flag rather than the key's presence.
    try testing.expect(main.newerRelease(releaseDoc(arena, "v0.21.0", ",\"draft\":false,\"prerelease\":false"), "0.20.1", &v, &u) != null);

    // Nothing a bad answer can do should produce a destination.
    try testing.expect(main.newerRelease("", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("not json at all", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("[]", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{}", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{\"tag_name\":\"not-a-version\"}", "0.20.1", &v, &u) == null);
    try testing.expect(main.newerRelease("{\"tag_name\":\"v0.21.0\"}", "0.20.1", &v, &u) == null); // no html_url
    // A link somewhere else entirely, which is the one that would matter.
    try testing.expect(main.newerRelease(
        \\{"tag_name":"v0.21.0","html_url":"http://evil.example/plaza"}
    , "0.20.1", &v, &u) == null);
}

test "the version this build reports is the one it compares against" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Not a literal: the comparison has to be against what this build actually
    // is, or it tells everybody about a release they are already running.
    var v: [24]u8 = undefined;
    var u: [160]u8 = undefined;
    const mine = main.plaza_version_for_test;
    try testing.expect(main.newerRelease(releaseDoc(arena, mine, ""), mine, &v, &u) == null);
}

test "switched off, Plaza does not ask at all" {
    // The promise in the issue is not "asks less often" or "asks and ignores
    // the answer", it is makes no request. The fetch cannot run under test
    // (`networkAllowed` is comptime false), so this asserts the decision.
    const now: i64 = 1_000_000;

    // Off, and no clock makes it due. Long overdue, never asked, still no.
    try testing.expect(!main.updateCheckDue(false, false, now, 0));
    try testing.expect(!main.updateCheckDue(false, false, now, now - 999_999));
    try testing.expect(!main.updateCheckDue(false, true, now, 0));

    // On, and the clock decides.
    try testing.expect(main.updateCheckDue(true, false, now, 0));
    try testing.expect(main.updateCheckDue(true, false, now, now));
    try testing.expect(!main.updateCheckDue(true, false, now, now + 1));

    // One at a time: a request already out is not a reason to send another.
    try testing.expect(!main.updateCheckDue(true, true, now, 0));
}

test "a newer release is offered, put away, and never offered when switched off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetUpdateStateForTest();
    defer main.resetUpdateStateForTest();

    // Nothing known yet: no line.
    try testing.expectEqualStrings("", main.pendingUpdateVersion());

    // A release document arrives that names something newer than this build.
    const newer = try std.fmt.allocPrint(arena,
        \\{{"tag_name":"v99.0.0","html_url":"https://github.com/zig-nostr/plaza/releases/tag/v99.0.0"}}
    , .{});
    main.updateNewsForTest(newer);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
    try testing.expectEqualStrings("https://github.com/zig-nostr/plaza/releases/tag/v99.0.0", main.pendingUpdateUrl());

    // It draws, and says both versions rather than only the new one.
    var model = main.initialModel();
    model.stage = .ready;
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "99.0.0") != null);
        try testing.expect(findAnyTextContainingText(tree.root, main.plaza_version_for_test) != null);
        try testing.expect(pressMsgByLabel(tree, "See what is new") != null);
    }

    // Put away for this session.
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.dismiss_update, &fx);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(pressMsgByLabel(tree, "See what is new") == null);
    }

    // Switched off, nothing is offered, even though the release is still out.
    main.resetUpdateStateForTest();
    main.updateNewsForTest(newer);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
    main.setUpdateCheck(false);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
    try testing.expectEqualStrings("", main.pendingUpdateUrl());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(pressMsgByLabel(tree, "See what is new") == null);
    }

    // And switched back on it comes straight back, because that version is
    // still out. Making the reader wait up to six hours for the next check to
    // rediscover what Plaza already knew would be a worse answer.
    main.setUpdateCheck(true);
    try testing.expectEqualStrings("99.0.0", main.pendingUpdateVersion());
}

test "a release that is not newer raises no line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetUpdateStateForTest();
    defer main.resetUpdateStateForTest();

    // The version this build actually is. Answered with itself, there is no news.
    const same = try std.fmt.allocPrint(arena,
        \\{{"tag_name":"v{s}","html_url":"https://github.com/zig-nostr/plaza/releases/tag/v{s}"}}
    , .{ main.plaza_version_for_test, main.plaza_version_for_test });
    main.updateNewsForTest(same);
    try testing.expectEqualStrings("", main.pendingUpdateVersion());

    // And a reply that is not a release document leaves no line either.
    main.updateNewsForTest("<html>rate limited</html>");
    try testing.expectEqualStrings("", main.pendingUpdateVersion());
}

// ------------------------------------------------------- a video is a video

// ---- NIP-22: a reply of either kind reaches me ------------------------------

test "a comment's parent and root are read from its own vocabulary" {
    // NIP-22 has no marker vocabulary at all, and field 4 of its `e` is the
    // AUTHOR pubkey where NIP-10 puts a marker. Reading one as the other is how
    // a reader quietly starts mistaking every comment for an unmarked
    // positional reply, so the two readers stay separate and a dispatcher picks.
    const root_id = [_]u8{0xE1} ** 32;
    const parent_id = [_]u8{0xE2} ** 32;
    var root_hex: [64]u8 = undefined;
    var parent_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&root_hex, "{x}", .{root_id}) catch unreachable;
    _ = std.fmt.bufPrint(&parent_hex, "{x}", .{parent_id}) catch unreachable;

    // The ordinary shape: uppercase names the root, lowercase the note being
    // answered, and the fourth field is a pubkey rather than a marker.
    const nested = [_]nostr.event.Tag{
        &.{ "E", &root_hex, "wss://relay.example", "f" ** 64 },
        &.{ "K", "1" },
        &.{ "e", &parent_hex, "wss://relay.example", "a" ** 64 },
        &.{ "k", "1111" },
    };
    try testing.expectEqualSlices(u8, &parent_id, &(main.nip22Parent(&nested).?));
    try testing.expectEqualSlices(u8, &root_id, &(main.nip22Root(&nested).?));

    // A top-level comment answers the root directly and carries no lowercase
    // `e` at all, so the parent falls back to the uppercase.
    const top = [_]nostr.event.Tag{
        &.{ "E", &root_hex, "", "f" ** 64 },
        &.{ "K", "30023" },
    };
    try testing.expectEqualSlices(u8, &root_id, &(main.nip22Parent(&top).?));

    // A comment on a URL or a hashtag has no event parent at all. Calling one
    // of those a reply to something would be inventing a tie.
    const on_a_url = [_]nostr.event.Tag{
        &.{ "I", "https://example.com/a" },
        &.{ "K", "web" },
    };
    try testing.expect(main.nip22Parent(&on_a_url) == null);
    try testing.expect(main.nip22Root(&on_a_url) == null);

    // And the dispatcher keeps the two vocabularies apart. These same tags read
    // as NIP-10 would answer with the LAST plain `e`, which is the parent here
    // by luck; the root is what separates them, because NIP-10 has no `E`.
    try testing.expectEqualSlices(u8, &parent_id, &(main.replyParent(main.comment_kind, &nested).?));
    try testing.expectEqualSlices(u8, &root_id, &(main.replyRoot(main.comment_kind, &nested).?));

    // And this is why the dispatcher exists rather than one reader with a
    // branch inside it. Handed the SAME tags, the NIP-10 reader finds no `root`
    // marker (field 4 is a pubkey), takes the first unmarked `e`, and answers
    // that the root is the PARENT. Not null, not an error: a confident wrong
    // answer, which is the shape of bug that survives review.
    try testing.expectEqualSlices(u8, &parent_id, &(main.replyRoot(1, &nested).?));
}

// ---- NIP-36 content warnings --------------------------------------------------

pub fn warnedEvent(id_byte: u8, content: []const u8, tags: []const nostr.event.Tag) nostr.event.Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0x61} ** 32,
        .created_at = 1_800_000_000,
        .kind = 1,
        .tags = tags,
        .content = content,
        .sig = [_]u8{0} ** 64,
    };
}

test "uncovering a note does not persist and does not leak to another" {
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const a = main.noteFrom(warnedEvent(0xC6, "a", &tags), 1_800_000_100);
    const b = main.noteFrom(warnedEvent(0xC7, "b", &tags), 1_800_000_100);
    try testing.expect(main.noteCovered(&a));
    try testing.expect(main.noteCovered(&b));
    main.uncoverNoteForTest(a.id);
    try testing.expect(!main.noteCovered(&a));
    try testing.expect(main.noteCovered(&b));
    // Session only: a new launch starts with the set empty.
    main.forgetUncoveredForTest();
    try testing.expect(main.noteCovered(&a));
}

test "a quote card, a reply line and a quoting pill do not repeat a covered note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const quoted_id = [_]u8{0x5f} ** 32;
    main.seedQuoteForTest(quoted_id, [_]u8{0x7a} ** 32, 100, "QUOTEDSECRET");
    main.warnQuoteForTest(quoted_id, "spoilers");

    // The card inside a feed row.
    var model = main.initialModel();
    model.stage = .ready;
    model.notes[0] = threadNote(0xA2, 100, 0);
    model.notes[0].id = 8;
    const body = "Look at this.";
    @memcpy(model.notes[0].content_buf[0..body.len], body);
    model.notes[0].content_len = @intCast(body.len);
    model.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
    model.notes_len = 1;
    const tree = try buildTree(arena, &model);
    try testing.expect(findAnyTextContaining(tree.root, "Look at this."));
    try testing.expect(!findAnyTextContaining(tree.root, "QUOTEDSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: spoilers"));

    // The line above a reply.
    var reply = main.Note{};
    reply.id = 9;
    reply.reply_parent = quoted_id;
    reply.has_reply_parent = true;
    const line = try main.buildReplyContextForTest(arena, &reply);
    try testing.expect(std.mem.indexOf(u8, line, "QUOTEDSECRET") == null);
    try testing.expect(std.mem.indexOf(u8, line, "reply to") != null);

    // The pill that walks into a quote of a quote.
    var ui = main.AppUi.init(arena);
    const label = main.quotingPillLabelForTest(&ui, quoted_id);
    try testing.expect(std.mem.indexOf(u8, label, "QUOTEDSECRET") == null);

    // Uncovering the note anywhere uncovers it here: it is one note.
    main.uncoverNoteForTest(main.feedKeyForTest(quoted_id));
    const open_line = try main.buildReplyContextForTest(arena, &reply);
    try testing.expect(std.mem.indexOf(u8, open_line, "QUOTEDSECRET") != null);
}

test "a notification covers the words of a covered note and uncovers on a press" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    const tags = [_]nostr.event.Tag{&.{ "content-warning", "spoilers" }};
    const ev = warnedEvent(0xCD, "NOTIFYSECRET", &tags);
    var item = main.InboxItem{ .used = true, .author = ev.pubkey, .verb = .reply, .created_at = ev.created_at };
    main.bakeBodyForTest(&item, ev);
    try testing.expect(item.warned);

    var ui = main.AppUi.init(arena);
    const tree = try ui.finalize(main.notificationRowForTest(&ui, &item));
    try testing.expect(!findAnyTextContaining(tree.root, "NOTIFYSECRET"));
    try testing.expect(findAnyTextContaining(tree.root, "Content warning: spoilers"));
    const msg = pressMsgByLabel(tree, "Show this note") orelse return error.NothingToPress;
    switch (msg) {
        .uncover_note => |key| try testing.expectEqual(main.noteIdOf(ev), key),
        else => return error.WrongPress,
    }

    main.uncoverNoteForTest(main.noteIdOf(ev));
    var ui2 = main.AppUi.init(arena);
    const open = try ui2.finalize(main.notificationRowForTest(&ui2, &item));
    try testing.expect(findAnyTextContaining(open.root, "NOTIFYSECRET"));
}

test "a draft handed back by a timed-out sign has the warning it was signed with" {
    // Several signs can be out at once with a remote signer. The warning rides
    // with each one, so the draft that comes back gets its own, not whichever
    // post was submitted last.
    main.clearPendingForTest();
    defer main.clearPendingForTest();
    main.setIdentityForTest([_]u8{0x4d} ** 32);
    defer main.clearIdentityForTest();
    main.setSignerKindForTest("remote");
    defer main.setSignerKindForTest("helper");
    var fx: main.EffectsForTest = undefined;

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;

    // First post, warned. Second post, not.
    model.draft_buffer.set("first, behind a warning");
    model.warn_on = true;
    model.warn_buffer.set("spoilers");
    try testing.expect(main.submitPostForTest(&model, &fx));
    model.draft_buffer.set("second, nothing to warn about");
    try testing.expect(main.submitPostForTest(&model, &fx));

    // The first one times out. The second is still with the signer.
    try testing.expect(main.failPendingByContentForTest("first, behind a warning"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("first, behind a warning", model.draft());
    try testing.expect(model.warn_on);
    try testing.expectEqualStrings("spoilers", model.warn_draft());

    // Now the second one, into a clean composer: it must not inherit the first
    // one's warning, which the single global it used to share would have given it.
    model.draft_buffer.clear();
    model.warn_on = false;
    model.warn_buffer.clear();
    try testing.expect(main.failPendingByContentForTest("second, nothing to warn about"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("second, nothing to warn about", model.draft());
    try testing.expect(!model.warn_on);
    try testing.expectEqual(@as(usize, 0), model.warn_draft().len);
}

/// The width of a notice's label in units: one for a narrow character, two for a
/// wide one. The engine's test measure is not a glyph measure (it sizes CJK
/// narrower than a screen does), so the claim "this fits" is made on what the
/// label says, with a deliberately generous width per unit.
fn labelUnits(text: []const u8) usize {
    var units: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| units += if (cp >= 0x2E80) @as(usize, 2) else 1;
    return units;
}

/// A covered note's chip, in a column of `column`: the label cut to a short
/// line, and that line plus the "Show" and the paddings inside the column even at
/// seven pixels a unit, wider than the mono register ever draws a unit.
fn expectChipFits(p: painted.Painted, chip: native_sdk.geometry.RectF, column: native_sdk.geometry.RectF) !void {
    var label: ?[]const u8 = null;
    for (p.layout.nodes) |n| {
        if (std.mem.startsWith(u8, n.widget.text, "Content warning")) label = n.widget.text;
    }
    const text = label orelse return error.NoLabel;
    try testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
    const worst = @as(f32, @floatFromInt(labelUnits(text))) * 7.0 + 4 * 7.0 + 60.0;
    if (chip.x < column.x - 0.5 or chip.x + chip.width > column.x + column.width + 0.5 or worst > chip.width) {
        std.debug.print("\nchip {d}..{d} column {d}..{d}, label needs about {d}\n", .{ chip.x, chip.x + chip.width, column.x, column.x + column.width, worst });
        return error.ChipOutsideColumn;
    }
    const show = frameOfText(p, "Show") orelse return error.NoShow;
    try testing.expect(show.x + show.width <= chip.x + chip.width + 0.5);
}

test "a long reason stays inside the column it is drawn in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.forgetUncoveredForTest();
    defer main.forgetUncoveredForTest();
    main.setShowSensitive(false);

    // 48 wide characters, then 48 narrow ones: the two ways a reason runs long.
    const cjk = "警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容警告内容";
    const latin = "a reason that goes on and on and on and on and on";
    const reasons = [_][]const u8{ cjk, latin };

    for (reasons) |reason| {
        // A nested reply, at the deepest indent a thread draws, in the narrowest
        // window the app allows.
        var model = main.initialModel();
        model.stage = .ready;
        model.thread_root = main.noteFrom(warnedEvent(0xD0, "the root", &.{}), 1_800_000_100);
        model.viewing_thread = model.thread_root.id;
        const tags = [_]nostr.event.Tag{&.{ "content-warning", reason }};
        var reply = warnedEvent(0xD1, "REPLYSECRET", &tags);
        reply.created_at = 1_800_000_200;
        model.thread_notes[0] = main.noteFrom(reply, 1_800_000_300);
        model.thread_notes[0].reply_parent = model.thread_root.event_id;
        model.thread_notes[0].has_reply_parent = true;
        model.thread_notes[0].depth = 6;
        model.thread_notes_len = 1;

        const p = try painted.Painted.renderAt(arena, &model, main.window_min_width, main.window_height);
        const chips = p.framesOf("Show this note");
        try testing.expectEqual(@as(usize, 1), chips.len);
        const rows = p.framesOf("Open thread");
        try testing.expect(rows.len >= 1);
        // Inside the reply's own row, which is the column it is drawn in.
        try expectChipFits(p, chips[0], rows[rows.len - 1]);

        // A quote card in a feed row.
        const quoted_id = [_]u8{0x5e} ** 32;
        main.seedQuoteForTest(quoted_id, [_]u8{0x7b} ** 32, 100, "QUOTEDSECRET");
        main.warnQuoteForTest(quoted_id, reason[0..@min(reason.len, 96)]);
        var feed = main.initialModel();
        feed.stage = .ready;
        feed.notes[0] = threadNote(0xA3, 100, 0);
        feed.notes[0].id = 11;
        const body = "Look at this.";
        @memcpy(feed.notes[0].content_buf[0..body.len], body);
        feed.notes[0].content_len = @intCast(body.len);
        feed.notes[0].quote = .{ .kind = .event, .id = quoted_id, .off = 0, .len = 0 };
        feed.notes_len = 1;
        const q = try painted.Painted.renderAt(arena, &feed, main.window_min_width, main.window_height);
        const qchips = q.framesOf("Show this note");
        try testing.expectEqual(@as(usize, 1), qchips.len);
        const cards = q.framesOf("Quoted note");
        try testing.expectEqual(@as(usize, 1), cards.len);
        try expectChipFits(q, qchips[0], cards[0]);
        main.resetQuotesForTest();
    }
}

// ---------------------------------------------------------------- NIP-42 AUTH
//
// A relay may ask who the reader is. These drive the whole exchange at the level
// the reader thread sees it: the messages a relay sends, a stand-in for the
// socket it answers on, and the real signer path in between. What they pin is
// the consent rule (ask once per relay, never for a guest, never after "no"),
// what is sent (a kind:22242 naming the dialed address and the challenge), and
// that a refusal is a finished subscription and not an answer.

pub const auth_test_url = "wss://auth.example.com";

/// The socket the reader thread would send its reply on. Records the one thing
/// the exchange puts on the wire so a test can look at the event itself.
const AuthRecorder = struct {
    sent: usize = 0,
    kind: u16 = 0,
    id: [32]u8 = [_]u8{0} ** 32,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    verified: bool = false,
    content_len: usize = 0,
    relay_buf: [128]u8 = undefined,
    relay_len: usize = 0,
    challenge_buf: [300]u8 = undefined,
    challenge_len: usize = 0,

    pub fn authenticate(self: *AuthRecorder, ev: nostr.event.Event) !void {
        self.sent += 1;
        self.kind = ev.kind;
        self.id = ev.id;
        self.pubkey = ev.pubkey;
        self.content_len = ev.content.len;
        for (ev.tags) |tag| {
            if (tag.len < 2) continue;
            if (std.mem.eql(u8, tag[0], "relay")) {
                @memcpy(self.relay_buf[0..tag[1].len], tag[1]);
                self.relay_len = tag[1].len;
            }
            if (std.mem.eql(u8, tag[0], "challenge")) {
                @memcpy(self.challenge_buf[0..tag[1].len], tag[1]);
                self.challenge_len = tag[1].len;
            }
        }
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        self.verified = nostr.event.verify(testing.allocator, signer, ev) catch false;
    }

    fn relay(self: *const AuthRecorder) []const u8 {
        return self.relay_buf[0..self.relay_len];
    }
    fn challenge(self: *const AuthRecorder) []const u8 {
        return self.challenge_buf[0..self.challenge_len];
    }
};

fn authFixture() !usize {
    main.resetRelayAuthForTest();
    main.clearRelaysForTest();
    main.setIdentityForTest([_]u8{0x71} ** 32);
    return main.addRelayForTest(auth_test_url, true, true) orelse error.NoSeat;
}

fn authCleanup() void {
    main.silenceTestSignerForTest(false);
    main.resetRelayAuthForTest();
    main.clearIdentityForTest();
    main.resetRelaysToBootstrapForTest();
}

fn authMsg(challenge: []const u8) nostr.message.RelayMessage {
    return .{ .auth = .{ .challenge = challenge } };
}

pub fn closedMsg(sub: []const u8, reason: []const u8) nostr.message.RelayMessage {
    return .{ .closed = .{ .subscription_id = sub, .message = reason } };
}

/// What a gating relay does: it sends its challenge and then refuses the feed
/// for want of an answer. A challenge on its own asks nothing of the reader.
pub fn challengeAndRefuse(sess: *main.AuthSessionForTest, url: []const u8, challenge: []const u8, now_ms: i64) void {
    _ = main.authReactForTest(sess, url, authMsg(challenge), now_ms);
    _ = main.authReactForTest(sess, url, closedMsg("plaza-feed", "auth-required: log in first"), now_ms);
}

test "a relay's AUTH is asked about once it refuses something, in a notice that names the relay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();

    var sess = main.AuthSessionForTest{ .index = idx };
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;

    // Nothing has asked yet, so nothing is on screen.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }

    // A challenge on its own is held quietly: the relay has not refused
    // anything, so there is nothing to ask about.
    const heard = main.authReactForTest(&sess, auth_test_url, authMsg("chal-1"), 0);
    try testing.expect(heard.handled);
    try testing.expect(!heard.resend.any());
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }

    // The relay refusing a subscription for want of AUTH is what asks.
    const refusal = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in first"), 1);
    try testing.expect(refusal.handled);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "auth.example.com asks you to identify yourself to it.") != null);
        const allow = pressMsgByLabel(tree, "Let auth.example.com know who you are") orelse return error.NoAllow;
        try testing.expectEqual(idx, allow.auth_allow);
        const deny = pressMsgByLabel(tree, "Do not identify yourself to auth.example.com") orelse return error.NoDeny;
        try testing.expectEqual(idx, deny.auth_deny);
    }

    // The same relay asking again on the same socket is still one question.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("chal-2"), 0);
    try testing.expectEqual(@as(usize, 1), main.authAskingCount());

    // A second relay is a second question, shown after the first and named as
    // waiting beside it rather than stacked on top of it.
    const idx2 = main.addRelayForTest("wss://second.example.com", true, true) orelse return error.NoSeat;
    var sess2 = main.AuthSessionForTest{ .index = idx2 };
    challengeAndRefuse(&sess2, "wss://second.example.com", "chal-9", 0);
    try testing.expectEqual(@as(usize, 2), main.authAskingCount());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "1 more is waiting.") != null);
    }

    // Answering the first moves the notice to the second.
    main.update(&model, Msg{ .auth_allow = @intCast(idx) }, &fx);
    try testing.expectEqual(@as(?usize, idx2), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "second.example.com asks you") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "more is waiting") == null);
    }

    // And the answer is remembered: the next connection to that relay hears the
    // same challenge and is not asked again, it goes straight to being signed.
    main.authSlotResetForTest(idx);
    var again = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&again, auth_test_url, "chal-3", 0);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() != null and main.authAsking().? == idx2);
}

test "a challenge alone raises no notice and sends nothing, even for a relay the reader already allowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    // Several busy public relays challenge every connection and gate nothing.
    // Ask first: no notice.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("hello"), 0);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }
    // Things the relay says that are not an auth refusal do not count as one.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "error: too many subscriptions"), 2);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{3} ** 32, .accepted = false, .message = "blocked: no" } }, 3);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{3} ** 32, .accepted = true, .message = "auth-required: but fine" } }, 4);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    try testing.expect(main.authRowNoteForTest(idx) == null);

    // Allow already said yes for this relay: still nothing is signed or sent
    // for a relay that only greeted.
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var allowed = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&allowed, auth_test_url, authMsg("hello-again"), 10);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    try testing.expect(!main.authHelperBusyForTest());
    _ = main.authPollForTest(&allowed, auth_test_url, &rec, 11);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
}

test "a challenge followed by an auth-required refusal asks, or answers when the reader allowed, and re-sends what was refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    // Ask: the refusal raises the notice, naming the relay.
    var asked = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&asked, auth_test_url, authMsg("held"), 0);
    try testing.expect(main.authAsking() == null);
    _ = main.authReactForTest(&asked, auth_test_url, closedMsg("plaza-feed", "auth-required: log in"), 1);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "auth.example.com asks you to identify yourself to it.") != null);
    }
    _ = main.authPollForTest(&asked, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);

    // Allow: the refusal alone is enough, the held challenge is signed and
    // sent, and the feed it refused is asked again once the relay says OK.
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("held-2"), 10);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in"), 11);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 12);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("held-2", rec.challenge());
    try testing.expectEqualStrings(auth_test_url, rec.relay());
    const ok = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 13);
    try testing.expect(ok.resend.feed);
    try testing.expect(!ok.resend.inbox);

    // An OK that says no to an event with an auth-required reason is the same
    // refusal as a CLOSED for a REQ.
    main.authSlotResetForTest(idx);
    var event_refused = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&event_refused, auth_test_url, authMsg("held-3"), 20);
    const no = main.authReactForTest(&event_refused, auth_test_url, .{ .ok = .{ .event_id = [_]u8{4} ** 32, .accepted = false, .message = "auth-required: only for members" } }, 21);
    try testing.expect(no.handled);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&event_refused, auth_test_url, &rec, 22);
    try testing.expectEqual(@as(usize, 2), rec.sent);
    try testing.expectEqualStrings("held-3", rec.challenge());
}

test "a relay the reader refused sends nothing when it refuses, and the choice is not asked for again" {
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .deny));
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("nope"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 1);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "allowing signs a kind 22242 that names the dialed address and the challenge, and the refused subscriptions are re-sent after the relay's OK" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    main.forgetLastPublishedForTest();

    // The order a strict relay uses: it refuses the subscriptions first, then
    // challenges. Each refusal is held, not treated as the end of anything.
    const feed = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: log in first"), 0);
    try testing.expect(feed.handled);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-inbox", "auth-required: log in first"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-engagement", "auth-required: log in first"), 0);
    // A one-shot question has nothing to be re-sent from, and a probe is only
    // a latency reading. Neither is owed.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-ask-profile", "auth-required: log in first"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("chal-xyz"), 0);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Until the reader answers, nothing is sent and nothing is signed.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 10);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Allow, pressed in the notice itself.
    var model = main.initialModel();
    model.stage = .ready;
    const tree = try buildTree(arena, &model);
    const press = pressMsgByLabel(tree, "Let auth.example.com know who you are") orelse return error.NoAllow;
    main.update(&model, press, &fx);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // The tick gets it signed, through the same keyholder path a note takes.
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // The reader thread sends it.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 20);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqual(@as(u16, 22242), rec.kind);
    try testing.expectEqualStrings(auth_test_url, rec.relay());
    try testing.expectEqualStrings("chal-xyz", rec.challenge());
    try testing.expectEqual(@as(usize, 0), rec.content_len);
    try testing.expectEqualSlices(u8, &me, &rec.pubkey);
    try testing.expect(rec.verified);
    try testing.expectEqualStrings("sent", main.authPhaseNameForTest(idx));
    // It was not stored and not published: it is for one relay's ears.
    try testing.expect(main.lastPublishedForTest() == null);

    // Sent once. Another wake does not send it again.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 30);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    // An OK for something else is not the verdict on this.
    const stranger = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = [_]u8{9} ** 32, .accepted = true, .message = "" } }, 40);
    try testing.expect(!stranger.handled);
    try testing.expect(!stranger.resend.any());

    // The relay accepts. NOW the refused subscriptions come back, and only the
    // ones it refused.
    const accepted = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 50);
    try testing.expect(accepted.handled);
    try testing.expect(accepted.resend.feed);
    try testing.expect(accepted.resend.inbox);
    try testing.expect(accepted.resend.engagement);
    try testing.expectEqualStrings("done", main.authPhaseNameForTest(idx));
    try testing.expect(main.authRowNoteForTest(idx) == null);

    // And a relay that still says auth-required after accepting us is final: the
    // loop's own handling of a closed feed takes over, not a second round.
    const still = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: and again"), 60);
    try testing.expect(!still.handled);
}

test "a relay that rejects the reply is not asked again, and says so in its row" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("c"), 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    const no = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = false, .message = "restricted: not on the list" } }, 2);
    try testing.expect(no.handled);
    try testing.expect(!no.resend.any());
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "would not accept") != null);

    // Nothing more goes out for the same challenge.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqual(@as(usize, 1), rec.sent);
}

test "not allowing sends nothing, is remembered, and the relay's row says what it is waiting for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    challengeAndRefuse(&sess, auth_test_url, "chal-no", 0);
    const tree = try buildTree(arena, &model);
    const press = pressMsgByLabel(tree, "Do not identify yourself to auth.example.com") orelse return error.NoDeny;
    main.update(&model, press, &fx);

    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    try testing.expect(main.authAsking() == null);

    // The notice is gone, and the tick has nothing to sign and the reader
    // thread nothing to send.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 5);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    {
        const after = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(after.root, "identify yourself") == null);
    }

    // The subscription the relay refuses afterwards is a refusal that stays: no
    // reply is composed for it, and the row tells the reader why this relay is
    // giving them nothing even though its dot is green.
    const refused = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 6);
    try testing.expect(refused.handled);
    try testing.expect(!refused.resend.any());
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 7);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "You chose not to tell it.") != null);

    // Written down in the file beside the other local settings, as the word,
    // the account it was said for, and the address, and nothing else.
    var buf: [512]u8 = undefined;
    var want_buf: [256]u8 = undefined;
    const me_hex = std.fmt.bytesToHex(main.activePubkeyForTest().?, .lower);
    const want = try std.fmt.bufPrint(&want_buf, "deny {s} wss://auth.example.com\n", .{me_hex[0..]});
    try testing.expectEqualStrings(want, main.authFileForTest(&buf).?);

    // A later connection hears the challenge, is not asked, and sends nothing.
    main.authSlotResetForTest(idx);
    var later = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&later, auth_test_url, authMsg("chal-again"), 100);
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
    _ = main.authReactForTest(&later, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 100);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&later, auth_test_url, &rec, 101);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "changing the choice to anonymous after the signature is ready still sends nothing" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "late-no", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // allow -> deny from the relay row, with the reply already composed.
    main.authCycleForTest(idx);
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("declined", main.authPhaseNameForTest(idx));
}

test "a guest is never asked, and is asked once there is someone to ask about" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    main.clearIdentityForTest();

    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var model = main.initialModel();
    model.stage = .ready;

    _ = main.authReactForTest(&sess, auth_test_url, authMsg("guest-chal"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    try testing.expectEqualStrings("no_key", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContainingText(tree.root, "identify yourself") == null);
    }
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);

    // A refused subscription for a guest is explained in the row, with the way
    // out, rather than reading as a relay with nothing to say.
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 2);
    try testing.expect(std.mem.indexOf(u8, main.authRowNoteForTest(idx).?, "Sign in to answer it.") != null);
    // Nothing was decided on the guest's behalf, so no choice was recorded.
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceForTest(auth_test_url));

    // Signing in is when the question becomes askable.
    // And no badge either: a guest has no identity to give, so there is
    // nothing for it to change.
    try testing.expect(main.authBadgeTextForTest(idx, auth_test_url) == null);

    main.setIdentityForTest([_]u8{0x71} ** 32);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    try testing.expectEqualStrings("ask first", main.authBadgeTextForTest(idx, auth_test_url).?);
}

test "a CLOSED for any other reason still ends the feed, and a relay that never challenges is dialed again" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};

    // Not an auth refusal: the loop's own handling of a closed feed stands.
    const other = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "error: too many subscriptions"), 0);
    try testing.expect(!other.handled);
    try testing.expect(!sess.owed.any());

    // An auth refusal with no challenge to answer it with. It waits a while for
    // one, because relays send theirs at connect and a late one is possible, and
    // then the connection is dropped and dialed again.
    const gate = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 1_000);
    try testing.expect(gate.handled);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1_000 + main.auth_gate_wait_ms_for_test));
    try testing.expectEqualStrings("redial", main.authPollForTest(&sess, auth_test_url, &rec, 1_001 + main.auth_gate_wait_ms_for_test));

    // A challenge arriving ends the wait for one.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("late"), 5_000);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1_001 + main.auth_gate_wait_ms_for_test));
}

test "a signature for an old challenge, another key, or another relay is never sent" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const secret = [_]u8{0x71} ** 32;
    const other_secret = [_]u8{0x72} ** 32;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // A signer that has not answered yet.
    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "old", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    // One at a time through the keyholder.
    try testing.expect(main.authHelperBusyForTest());

    // The relay sends a newer challenge while the signature is out. The slot
    // goes back to wanting one, and the late signature for "old" is dropped.
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("new"), 1);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    const old_ev = try signAuthEvent(a, signer, secret, auth_test_url, "old");
    main.authDeliverSignedForTest(idx, old_ev);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // And the sharper case, a bunker's: the request for "new" is out as well
    // when the answer for "old" turns up. It must not be taken for the answer to
    // the question being asked now.
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authDeliverSignedForTest(idx, old_ev);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // A reply signed by someone who is not the signed-in account.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 2);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    const wrong_key = try signAuthEvent(a, signer, other_secret, auth_test_url, "fresh");
    main.authDeliverSignedForTest(idx, wrong_key);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // The same for another relay's name in the tag: the signer was asked for
    // this relay, and an answer for a different one is not that.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 3);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    const wrong_relay = try signAuthEvent(a, signer, secret, "wss://elsewhere.example.com", "fresh");
    main.authDeliverSignedForTest(idx, wrong_relay);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // And the right one, to show the checks are not simply refusing everything.
    main.resetRelayAuthForTest();
    challengeAndRefuse(&sess, auth_test_url, "fresh", 4);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    const right = try signAuthEvent(a, signer, secret, auth_test_url, "fresh");
    main.authDeliverSignedForTest(idx, right);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // Nothing of the refused ones was ever sent.
    try testing.expectEqual(@as(usize, 0), rec.sent);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 5);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("fresh", rec.challenge());
}

fn signAuthEvent(a: std.mem.Allocator, signer: nostr.keys.Signer, secret: [32]u8, url: []const u8, challenge: []const u8) !nostr.event.Event {
    const kp = try signer.keyPairFromSecretKey(secret);
    return nostr.nip42.authEvent(a, signer, kp, url, challenge, 1_700_000_000, null);
}

test "a connection identified as one account is left when the reader becomes someone else" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "who", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 1));
    try testing.expectEqual(@as(usize, 1), rec.sent);
    _ = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 2);
    try testing.expectEqualStrings("quiet", main.authPollForTest(&sess, auth_test_url, &rec, 3));

    // Signing out (or in as somebody else) moves the identity generation. The
    // relay still knows this socket as the old account, and the only way to stop
    // that is to leave it.
    main.bumpIdentityGeneration();
    try testing.expectEqualStrings("redial", main.authPollForTest(&sess, auth_test_url, &rec, 4));
}

test "a signature that never comes back fails the exchange instead of hanging it" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var fx: main.EffectsForTest = undefined;

    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "slow", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authSweepForTest(0);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));
    main.authSweepForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
}

test "a bunker that refuses or never answers fails the exchange" {
    const idx = try authFixture();
    defer authCleanup();
    try testing.expectEqual(@as(usize, 0), idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.clearPendingForTest();
    defer main.clearPendingForTest();

    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "bunk", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));

    // The bunker's table holds the request with the slot as its tag. Its answer
    // is an error: the tick retires it and the exchange fails with it.
    try testing.expect(main.registerPendingForTest("auth-req-1", .sign_auth, null));
    try testing.expect(main.failPendingForTest("auth-req-1"));
    main.scanPendingRemoteForTest(&model, &fx);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));
}

test "the choice survives a relaunch and is keyed by the account and the address, not its spelling" {
    main.resetRelayAuthForTest();
    defer main.resetRelayAuthForTest();
    const alice = [_]u8{0xa1} ** 32;
    const bob = [_]u8{0xb2} ** 32;

    try testing.expect(main.setAuthChoiceForTest(alice, "wss://Relay.Example.com/", .allow));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com/"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://other.example.com"));
    // Alice's yes is hers. Bob has not been asked.
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(bob, "wss://relay.example.com"));
    try testing.expect(main.setAuthChoiceForTest(alice, "wss://nope.example.com", .deny));
    try testing.expect(main.setAuthChoiceForTest(bob, "wss://relay.example.com", .deny));

    var buf: [1024]u8 = undefined;
    const text = try testing.allocator.dupe(u8, main.authFileForTest(&buf).?);
    defer testing.allocator.free(text);

    main.resetRelayAuthForTest();
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    main.applyAuthFileForTest(text);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(alice, "wss://nope.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(bob, "wss://nope.example.com"));

    // "Ask first" is a real choice too: it forgets the answer, and only that
    // account's.
    try testing.expect(main.setAuthChoiceForTest(alice, "wss://relay.example.com", .ask));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://relay.example.com"));
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, "wss://relay.example.com"));

    // A hand-edited file does not get to name things that are not relays, or
    // words that are not answers, or accounts that are not keys.
    main.resetRelayAuthForTest();
    const a_hex = std.fmt.bytesToHex(alice, .lower);
    var raw_buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(&raw_buf, "allow {0s} http://not-a-relay\nmaybe {0s} wss://odd.example.com\n# allow {0s} wss://c.example.com\nallow abc wss://short.example.com\nallow {0s} wss://two.example.com extra\nallow {0s} wss://ok.example.com\n", .{a_hex[0..]});
    main.applyAuthFileForTest(raw);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, "wss://ok.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://odd.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://c.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://short.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://two.example.com"));
}

test "an answer written before answers named an account is not taken as anyone's" {
    main.resetRelayAuthForTest();
    defer main.resetRelayAuthForTest();
    const alice = [_]u8{0xa1} ** 32;

    // The old shape: a word and an address. Whoever said it, it was not
    // necessarily the account signed in now, so the relay is asked again.
    main.applyAuthFileForTest("allow wss://old.example.com\ndeny wss://older.example.com\n");
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://old.example.com"));
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceOfForTest(alice, "wss://older.example.com"));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", main.authFileForTest(&buf).?);
}

test "the relay row carries the choice as a badge once the relay has asked, and the badge changes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const idx = try authFixture();
    defer authCleanup();
    var model = main.initialModel();
    model.stage = .settings;
    var fx: main.EffectsForTest = undefined;
    var sess = main.AuthSessionForTest{ .index = idx };
    const label = "Change whether wss://auth.example.com may know who you are";

    // A relay that has never mentioned identity gets no control about it.
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findByLabel(tree.root, label) == null);
    }

    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("row"), 0);
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "ask first") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "Waiting for your answer.") != null);
        const msg = pressMsgByLabel(tree, label) orelse return error.NoBadge;
        main.update(&model, msg, &fx);
    }
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceForTest(auth_test_url));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "identify") != null);
        try testing.expect(findAnyTextContainingText(tree.root, "Identifying you to it.") != null);
        main.update(&model, pressMsgByLabel(tree, label).?, &fx);
    }
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceForTest(auth_test_url));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyText(tree.root, "anonymous") != null);
        main.update(&model, pressMsgByLabel(tree, label).?, &fx);
    }
    try testing.expectEqual(main.AuthChoice.ask, main.authChoiceForTest(auth_test_url));
    // Back to asking means the notice is back, because the relay is still
    // waiting and the reader has not decided.
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
}

test "a relay taken out of the list stops asking, and does not hide the one behind it" {
    const idx = try authFixture();
    defer authCleanup();
    const idx2 = main.addRelayForTest("wss://second.example.com", true, true) orelse return error.NoSeat;
    var a = main.AuthSessionForTest{ .index = idx };
    var b = main.AuthSessionForTest{ .index = idx2 };
    challengeAndRefuse(&a, auth_test_url, "one", 0);
    challengeAndRefuse(&b, "wss://second.example.com", "two", 0);
    try testing.expectEqual(@as(usize, 2), main.authAskingCount());
    try testing.expectEqual(@as(?usize, idx), main.authAsking());

    main.removeRelayForTest(idx);
    try testing.expectEqual(@as(usize, 1), main.authAskingCount());
    try testing.expectEqual(@as(?usize, idx2), main.authAsking());
    try testing.expectEqualStrings("idle", main.authPhaseNameForTest(idx));
}

test "a second account on the same machine is asked for itself, and the first keeps its answer" {
    const idx = try authFixture();
    defer authCleanup();
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const alice = main.activePubkeyForTest().?;

    var first = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&first, auth_test_url, "a-1", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&first, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &alice, &rec.pubkey);

    // Someone else signs in on this machine. The relay is the same, the person
    // it would learn is not, so it is a new question.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    main.authSlotResetForTest(idx);
    var second = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&second, auth_test_url, "b-1", 10);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    try testing.expectEqual(@as(?usize, idx), main.authAsking());
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&second, auth_test_url, &rec, 11);
    try testing.expectEqual(@as(usize, 1), rec.sent);

    // Bob says no. That is his answer and leaves Alice's alone.
    main.authAnswerForTest(idx, false);
    try testing.expectEqual(main.AuthChoice.deny, main.authChoiceOfForTest(bob, auth_test_url));
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceOfForTest(alice, auth_test_url));

    // Alice back: not asked again, straight to being signed, as her.
    main.setIdentityForTest([_]u8{0x71} ** 32);
    main.authSlotResetForTest(idx);
    var third = main.AuthSessionForTest{ .index = idx };
    challengeAndRefuse(&third, auth_test_url, "a-2", 20);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    try testing.expect(main.authAsking() == null);
}

test "switching account between the yes and the signature asks the new account instead of signing as it" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    challengeAndRefuse(&sess, auth_test_url, "between", 0);
    main.authAnswerForTest(idx, true);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // The UI thread switches account before its tick, and before the reader
    // thread has woken to look again. Alice said yes; Bob has said nothing.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
}

test "a reply signed as one account is never sent once the reader is another, or has gone back to ask first" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    const alice = main.activePubkeyForTest().?;

    // Composed for Alice and waiting for the reader thread.
    challengeAndRefuse(&sess, auth_test_url, "mine", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));

    // Alice puts the badge back to "ask first" (allow, anonymous, ask). It is
    // not a no, but it is not a yes either.
    try testing.expect(main.setAuthChoiceForTest(alice, auth_test_url, .ask));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("asking", main.authPhaseNameForTest(idx));

    // Yes again, signed again, and before it goes out Bob signs in. Bob has
    // said yes to this relay himself, which is exactly when Alice's reply would
    // have slipped through: the choice in force is a yes, just not hers.
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signed", main.authPhaseNameForTest(idx));
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    try testing.expect(main.setAuthChoiceForTest(bob, auth_test_url, .allow));
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 0), rec.sent);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    // Bob's own yes gets Bob's own signature, and that is what goes out.
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 3);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &bob, &rec.pubkey);
    try testing.expect(rec.verified);
}

test "an exchange that failed is tried again when the reader answers, and not on its own" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    // A bunker whose person was away: the signature timed out.
    main.silenceTestSignerForTest(true);
    _ = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed", "auth-required: x"), 0);
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("away"), 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    main.authSweepForTest(std.math.maxInt(i64));
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // The reader thread waking does not start it over: a signer that refuses
    // would be asked again every time.
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("failed", main.authPhaseNameForTest(idx));

    // Pressing the badge round to identify again is an answer, and it is.
    main.silenceTestSignerForTest(false);
    main.authCycleForTest(idx);
    main.authCycleForTest(idx);
    main.authCycleForTest(idx);
    try testing.expectEqual(main.AuthChoice.allow, main.authChoiceForTest(auth_test_url));
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualStrings("away", rec.challenge());
}

test "a signature that comes back after the reader switched account is dropped and the new account is asked" {
    const idx = try authFixture();
    defer authCleanup();
    var sess = main.AuthSessionForTest{ .index = idx };
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    // Alice's signature is out with a keyholder that has not answered yet.
    main.silenceTestSignerForTest(true);
    challengeAndRefuse(&sess, auth_test_url, "switch", 0);
    main.authAnswerForTest(idx, true);
    main.driveRelayAuthForTest(&fx);
    try testing.expectEqualStrings("signing", main.authPhaseNameForTest(idx));

    // Bob signs in and has said yes to this relay himself. Alice's answer then
    // arrives. It is not his, and it is not a broken signer either: the
    // exchange goes on for Bob instead of failing for good.
    main.setIdentityForTest([_]u8{0x72} ** 32);
    const bob = main.activePubkeyForTest().?;
    try testing.expect(main.setAuthChoiceForTest(bob, auth_test_url, .allow));
    const alices = try signAuthEvent(a, signer, [_]u8{0x71} ** 32, auth_test_url, "switch");
    main.authDeliverSignedForTest(idx, alices);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));

    main.silenceTestSignerForTest(false);
    main.authHelperFreeForTest();
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 1);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    try testing.expectEqualSlices(u8, &bob, &rec.pubkey);
}

// ------------------------------------------------------------ long-form articles

/// A markdown body of `paragraphs` paragraphs, each its own distinctive line, with
/// a heading every tenth and a fenced block and a list in the middle.
fn longArticleBody(arena: std.mem.Allocator, paragraphs: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (0..paragraphs) |i| {
        if (i % 10 == 0) try out.print(arena, "## Section {d}\n\n", .{i / 10});
        try out.print(arena, "Paragraph number {d} says something about the subject at a length that wraps onto a second line when it is drawn in a reading column.\n\n", .{i});
        if (i == paragraphs / 2) {
            try out.appendSlice(arena, "```zig\nconst a = 1;\n\nconst b = 2;\n```\n\n");
            try out.appendSlice(arena, "1. first item\n\n2. second item\n\n3. third item\n\n");
        }
    }
    return out.items;
}

/// The blocks the toolkit's Markdown view makes of `source`, counted the plain
/// way: a run of non-blank lines after a blank one. Exact for text whose blocks
/// are set apart by blank lines, which is what the tests below hand it.
fn blocksIn(source: []const u8) usize {
    var n: usize = 0;
    var blank = true;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const empty = std.mem.trim(u8, line, " \t\r").len == 0;
        if (!empty and blank) n += 1;
        blank = empty;
    }
    return n;
}

/// The row whose bytes hold all of `needle`, if one does.
fn rowHolding(source: []const u8, rows: []const long_form.Chunk, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, source, needle) orelse return null;
    for (rows, 0..) |c, i| {
        if (at >= c.start and at + needle.len <= c.end) return i;
    }
    return null;
}

test "an article's tags are read the way the reader needs them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x61} ** 32);

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "a-slug" },
        &[_][]const u8{ "title", "  The title  " },
        &[_][]const u8{ "summary", "One line about it." },
        &[_][]const u8{ "image", "https://example.com/cover.jpg" },
        &[_][]const u8{ "published_at", "1700000000" },
        &[_][]const u8{ "t", "Zig" },
        &[_][]const u8{ "t", "zig" },
        &[_][]const u8{ "t", "nostr" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "body");
    const meta = long_form.metaOf(ev);
    try testing.expectEqualStrings("The title", meta.title);
    try testing.expectEqualStrings("One line about it.", meta.summary);
    try testing.expectEqualStrings("https://example.com/cover.jpg", meta.image);
    try testing.expectEqual(@as(i64, 1_700_000_000), meta.published_at);
    // Two spellings of one topic are one chip.
    try testing.expectEqual(@as(usize, 2), meta.tag_count);

    // An article cannot have been published after the event carrying it was made.
    const future = [_]nostr.event.Tag{&[_][]const u8{ "published_at", "1900000000" }};
    const late = long_form.metaOf(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &future, "body"));
    try testing.expectEqual(@as(i64, 1_800_000_000), late.published_at);
    const junk = [_]nostr.event.Tag{&[_][]const u8{ "published_at", "yesterday" }};
    const unparsed = long_form.metaOf(try signedKind(arena, signer, kp, 1_800_000_000, 30023, &junk, "body"));
    try testing.expectEqual(@as(i64, 1_800_000_000), unparsed.published_at);

    try testing.expect(long_form.isWebUrl("https://example.com/a.png"));
    try testing.expect(!long_form.isWebUrl("javascript:alert(1)"));
    try testing.expect(!long_form.isWebUrl("https://exa mple.com/a.png"));
    try testing.expectEqual(@as(u32, 1), long_form.readingMinutes("a few words"));
    try testing.expectEqual(@as(u32, 2), long_form.readingMinutes("word " ** 226));
}

test "an article body is cut where cutting cannot change how it reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try longArticleBody(arena, 400);
    var chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const cut = long_form.chunk(body, &chunks);
    try testing.expect(!cut.truncated);
    // Many rows, not one: the list can only skip what is cut into pieces.
    try testing.expect(cut.len > 10);

    // In order, inside the body, and with no row a few kilobytes past the target
    // unless it holds something that must stay whole.
    var prev_end: u32 = 0;
    for (chunks[0..cut.len]) |c| {
        try testing.expect(c.start >= prev_end);
        try testing.expect(c.end > c.start);
        try testing.expect(c.end <= body.len);
        try testing.expect(c.height > 0);
        prev_end = c.end;
    }

    // The fenced block, blank line and all, is inside exactly one row.
    const fence_at = std.mem.indexOf(u8, body, "const a = 1;").?;
    for (chunks[0..cut.len]) |c| {
        if (fence_at >= c.start and fence_at < c.end) {
            try testing.expect(std.mem.indexOf(u8, body[c.start..c.end], "const b = 2;") != null);
            try testing.expect(std.mem.indexOf(u8, body[c.start..c.end], "```\n") != null);
        }
    }
    // A fenced block longer than a whole row, with a blank line deep inside it:
    // the blank line is code, not a paragraph break.
    var big = std.ArrayList(u8).empty;
    try big.appendSlice(arena, "Before.\n\n```\n");
    for (0..300) |_| try big.appendSlice(arena, "let x = 1;\n");
    try big.appendSlice(arena, "\nTAIL_OF_THE_BLOCK\n```\n\nAfter.\n");
    var big_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const big_cut = long_form.chunk(big.items, &big_chunks);
    const tail_at = std.mem.indexOf(u8, big.items, "TAIL_OF_THE_BLOCK").?;
    for (big_chunks[0..big_cut.len]) |c| {
        if (tail_at >= c.start and tail_at < c.end) {
            try testing.expect(std.mem.indexOf(u8, big.items[c.start..c.end], "let x = 1;") != null);
        }
    }

    // A list longer than a whole row, its items set apart by blank lines. The
    // toolkit draws 64 blocks of a row and drops the rest, and a blank line ends
    // a list there, so each item is a block: one row holding all eighty lost the
    // last sixteen and the line after them. Each item is cut whole, and keeps the
    // number its author wrote.
    var items = std.ArrayList(u8).empty;
    try items.appendSlice(arena, "Steps:\n\n");
    for (1..81) |n| try items.print(arena, "{d}. step number {d} is described here at some length\n\n", .{ n, n });
    try items.appendSlice(arena, "Done.\n");
    var item_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const item_cut = long_form.chunk(items.items, &item_chunks);
    for (item_chunks[0..item_cut.len]) |c| {
        try testing.expect(blocksIn(items.items[c.start..c.end]) <= long_form.max_row_weight);
    }
    for (1..81) |n| {
        const line = try std.fmt.allocPrint(arena, "{d}. step number {d} is described here at some length\n", .{ n, n });
        try testing.expect(rowHolding(items.items, item_chunks[0..item_cut.len], line) != null);
    }

    // Short paragraphs, the way a poem is set: two thousand bytes of them is a
    // hundred blocks. The byte target alone made that one row.
    var poem = std.ArrayList(u8).empty;
    for (0..300) |n| try poem.print(arena, "Verse {d} goes here\n\n", .{n});
    var poem_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const poem_cut = long_form.chunk(poem.items, &poem_chunks);
    for (poem_chunks[0..poem_cut.len]) |c| {
        try testing.expect(blocksIn(poem.items[c.start..c.end]) <= long_form.max_row_weight);
    }

    // Headings on consecutive lines are a block each with no blank line between
    // them, so the row ends before a block rather than only at a blank line.
    var heads = std.ArrayList(u8).empty;
    for (0..200) |n| try heads.print(arena, "## Heading {d}\n", .{n});
    var head_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const head_cut = long_form.chunk(heads.items, &head_chunks);
    try testing.expect(head_cut.len > 1);
    for (head_chunks[0..head_cut.len]) |c| {
        try testing.expect(std.mem.count(u8, heads.items[c.start..c.end], "## ") <= long_form.max_row_weight);
    }

    // `<details>` written as an example in prose is not a details block, the
    // toolkit's own test being a line that starts with it. Read as one, it was
    // never closed, and nothing after it could be cut.
    var prose = std.ArrayList(u8).empty;
    try prose.appendSlice(arena, "Wrap it in a `<details>` element to fold it.\n\n");
    try prose.appendSlice(arena, body);
    var prose_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
    const prose_cut = long_form.chunk(prose.items, &prose_chunks);
    try testing.expect(prose_cut.len > 10);

    // Whatever a row is in the middle of, it ends by `row_hard_bytes`: a fence
    // that never closes, a details block that never closes, one line that never
    // ends. A cut inside the fence says so, so the row can be drawn as code.
    const hostile = [_][]const u8{ "```\n", "<details>\n", "# " };
    for (hostile) |opening| {
        var wall = std.ArrayList(u8).empty;
        try wall.appendSlice(arena, opening);
        for (0..6000) |n| try wall.print(arena, "w{d} ", .{n});
        if (opening[0] != '#') {
            for (0..3000) |n| try wall.print(arena, "\nline {d}", .{n});
        }
        var wall_chunks: [long_form.max_chunks]long_form.Chunk = undefined;
        const wall_cut = long_form.chunk(wall.items, &wall_chunks);
        try testing.expect(!wall_cut.truncated);
        try testing.expect(wall_cut.len > 3);
        var at: u32 = 0;
        for (wall_chunks[0..wall_cut.len], 0..) |c, i| {
            try testing.expectEqual(at, c.start);
            try testing.expect(c.end - c.start <= long_form.row_hard_bytes);
            try testing.expectEqual(i > 0 and opening[0] == '`', c.in_fence);
            at = c.end;
        }
        try testing.expectEqual(@as(u32, @intCast(wall.items.len)), at);
    }

    // A body past the cap is cut and says so, rather than silently running on.
    var few: [3]long_form.Chunk = undefined;
    const clipped = long_form.chunk(body, &few);
    try testing.expectEqual(@as(usize, 3), clipped.len);
    try testing.expect(clipped.truncated);
}

/// A store in a temp directory with `ev` ingested, and the app pointed at it.
pub fn articleStore(tmp: *std.testing.TmpDir, pbuf: []u8, name: []const u8) !nostr.store.Store {
    const db_path = try std.fmt.bufPrintZ(pbuf, ".zig-cache/tmp/{s}/{s}.mdb", .{ tmp.sub_path, name });
    return nostr.store.Store.open(db_path, .{});
}

test "opening an article by id opens a reader, and a long one builds only what is on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x63} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "reader");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    const body = try longArticleBody(arena, 400);
    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "the-long-one" },
        &[_][]const u8{ "title", "A reasonably long article" },
        &[_][]const u8{ "summary", "What the article is about, in a sentence." },
        &[_][]const u8{ "t", "zig" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, body);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);
    // A level of its own, rooted at the article.
    try testing.expectEqual(@as(u16, 30023), model.thread_root.kind);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));

    const tree = try buildTree(arena, &model);
    // The head: title, summary and the reading time.
    try testing.expect(findAnyTextContaining(tree.root, "A reasonably long article"));
    try testing.expect(findAnyTextContaining(tree.root, "What the article is about, in a sentence."));
    try testing.expect(findAnyTextContaining(tree.root, "min read"));
    // The body, rendered: the first section's heading and paragraph are here, as
    // text rather than as markup.
    try testing.expect(findAnyTextContaining(tree.root, "Section 0"));
    try testing.expect(findAnyTextContaining(tree.root, "Paragraph number 0 says"));
    try testing.expect(!findAnyTextContaining(tree.root, "## Section 0"));
    // And the end of it is not: four hundred paragraphs are not built to show the
    // first screenful.
    try testing.expect(!findAnyTextContaining(tree.root, "Paragraph number 399 says"));
    try testing.expect(!findAnyTextContaining(tree.root, "Paragraph number 200 says"));
    try testing.expect(main.articleRowCountForTest(ev.id) > 20);
    try testing.expect(countNodes(tree.root) < 600);
}

/// The first widget whose text contains `needle`.
fn widgetContaining(widget: canvas.Widget, needle: []const u8) ?canvas.Widget {
    if (std.mem.indexOf(u8, widget.text, needle) != null) return widget;
    for (widget.children) |child| {
        if (widgetContaining(child, needle)) |found| return found;
    }
    return null;
}

test "every part of a long article is drawn by some row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6d} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "every-row");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    // What a writer actually does, each at a size that used to lose text: a
    // poem in short stanzas, a listing longer than a row, a folded aside, and one
    // paragraph written as a single enormous line.
    var body = std.ArrayList(u8).empty;
    try body.appendSlice(arena, "Fold the notes in a `<details>` element if they run long.\n\n");
    for (0..150) |n| try body.print(arena, "Verse {d} of the poem\n\n", .{n});
    try body.appendSlice(arena, "```\n");
    for (0..500) |n| try body.print(arena, "listing line {d};\n", .{n});
    try body.appendSlice(arena, "```\n\n");
    try body.appendSlice(arena, "<details>\n<summary>Notes</summary>\n\nThe folded words.\n\n</details>\n\n");
    for (0..3000) |n| try body.print(arena, "word{d} ", .{n});
    try body.appendSlice(arena, "END_OF_THE_LONG_LINE\n\nThe last paragraph.\n");

    const tags = [_]nostr.event.Tag{ &[_][]const u8{ "d", "every-row" }, &[_][]const u8{ "title", "All of it" } };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, body.items);
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);

    // Every row, drawn on its own, as the list draws it.
    const rows = main.articleRowCountForTest(ev.id);
    try testing.expect(rows > 2);
    const trees = try arena.alloc(AppUi.Tree, rows - 2);
    for (trees, 1..) |*tree, index| {
        var ui = AppUi.init(arena);
        const node = main.articleRowForTest(&ui, &model.thread_root, index);
        try testing.expect(!ui.failed);
        tree.* = try ui.finalize(node);
        // And a row stays a size the window can hold a few of at once.
        try testing.expect(countNodes(tree.root) < 200);
    }
    const Find = struct {
        fn in(all: []const AppUi.Tree, needle: []const u8) ?canvas.Widget {
            for (all) |t| {
                if (widgetContaining(t.root, needle)) |w| return w;
            }
            return null;
        }
    };
    for (0..150) |n| {
        const verse = try std.fmt.allocPrint(arena, "Verse {d} of the poem", .{n});
        try testing.expect(Find.in(trees, verse) != null);
    }
    // The listing is code from its first line to its last, across the rows it
    // was cut into: line for line, where prose would have run them together.
    const first = Find.in(trees, "listing line 0;") orelse return error.ListingStartMissing;
    const last = Find.in(trees, "listing line 499;") orelse return error.ListingEndMissing;
    try testing.expectEqual(first.kind, last.kind);
    try testing.expect(std.mem.indexOf(u8, last.text, "listing line 498;\nlisting line 499;") != null);
    try testing.expect(Find.in(trees, "The folded words.") != null);
    try testing.expect(Find.in(trees, "END_OF_THE_LONG_LINE") != null);
    try testing.expect(Find.in(trees, "The last paragraph.") != null);
}

test "a draft is not opened as though it were published" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x64} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "draft");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "unfinished" },
        &[_][]const u8{ "title", "Not ready" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30024, &tags, "Half a thought.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, ev.id);
    try testing.expectEqual(@as(i64, 0), model.viewing_thread);
    try testing.expectEqualStrings("That is an unpublished draft.", model.toast_text());
    // And the reader will not draw one even if asked directly.
    try testing.expectEqual(@as(usize, 0), main.articleRowCountForTest(ev.id));
}

// ---- an naddr opens the article it names ---------------------------------------

test "a card for an naddr fills from the store and opens the article" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6a} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "card");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.forgetAddressFetchForTest();
    defer main.forgetAddressFetchForTest();
    main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "the-card" },
        &[_][]const u8{ "title", "The title on the card" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "The article body.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);

    // A note in the store that names the article, parsed the way the feed does.
    const naddr = try nostr.nip19.encodeNaddr(arena, "the-card", kp.public_key, 30023, &.{});
    const text = try std.fmt.allocPrint(arena, "this one nostr:{s}", .{naddr});
    const note_ev = try signedNote(arena, signer, kp, 1_800_000_100, text);
    const note = main.noteFrom(note_ev, 1_800_000_200);
    try testing.expect(main.noteHasEventQuote(&note));

    // Loading first: the card exists and has not resolved.
    const e = main.quoteForTest(note.quote.id) orelse return error.NoCard;
    try testing.expect(e.state != .loaded);

    // Found: the store has it, so one pass fills the card with the article's title.
    main.refreshQuotesForTest(&store);
    try testing.expect(e.state == .loaded);
    try testing.expectEqualStrings("The title on the card", main.quoteTextForTest(note.quote.id) orelse "");

    // And pressing it, which is an open of the card's key, opens the article.
    var model = main.initialModel();
    model.stage = .ready;
    main.openEventForTest(&model, note.quote.id);
    try testing.expect(std.mem.eql(u8, &model.thread_root.event_id, &ev.id));
}

test "a card for an naddr nobody has settles as missing, and loads if it lands later" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x6b} ** 32);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [160]u8 = undefined;
    var store = try articleStore(&tmp, &pbuf, "cardmissing");
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.forgetArticleForTest();
    defer main.forgetArticleForTest();
    main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const naddr = try nostr.nip19.encodeNaddr(arena, "ghost", kp.public_key, 30023, &.{});
    const note = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}));
    main.wantQuoteForTest(note.quote.id);
    const e = main.quoteForTest(note.quote.id) orelse return error.NoCard;

    // Asked and unanswered enough times, the card stops showing a skeleton. The
    // store never changes here, so nothing but the asking can have said so: a
    // card that waits for the store to grow is a spinner on a quiet one.
    for (0..6) |_| {
        main.rearmWantedQuotesForTest();
        main.advanceQuoteRoundForTest(main.quoteBackoffRoundsForTest(255));
        main.requestWantedQuotesForTest();
    }
    try testing.expect(e.state == .missing);
    try testing.expect(e.attempts > 3);

    // Missing is what the row says, not a verdict: the article lands afterwards
    // and the card fills.
    const tags = [_]nostr.event.Tag{
        &[_][]const u8{ "d", "ghost" },
        &[_][]const u8{ "title", "It was there after all" },
    };
    const ev = try signedKind(arena, signer, kp, 1_800_000_000, 30023, &tags, "Late.");
    _ = try main.plazaIngestVerifiedForTest(arena, ev, signer);
    main.refreshQuotesForTest(&store);
    try testing.expect(e.state == .loaded);
    try testing.expectEqualStrings("It was there after all", main.quoteTextForTest(note.quote.id) orelse "");
}

test "a round of quote cards asks a few addresses and dials fewer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    main.resetQuotesForTest();
    defer main.resetQuotesForTest();
    main.resetAddressesForTest();
    defer main.resetAddressesForTest();

    const pk = [_]u8{0x49} ** 32;
    var keys: [6][32]u8 = undefined;
    for (&keys, 0..) |*k, i| {
        const ident = try std.fmt.allocPrint(arena, "card-{d}", .{i});
        const naddr = try nostr.nip19.encodeNaddr(arena, ident, pk, 30023, &.{});
        const note = main.findQuoteRefForTest(try std.fmt.allocPrint(arena, "nostr:{s}", .{naddr}));
        k.* = note.quote.id;
        main.wantQuoteForTest(k.*);
    }

    main.rearmWantedQuotesForTest();
    main.requestWantedQuotesForTest();
    var asked: usize = 0;
    var dialled: usize = 0;
    for (keys) |k| {
        if (main.quoteForTest(k).?.requested) asked += 1;
        if (main.addressDialledForTest(k)) dialled += 1;
    }
    try testing.expectEqual(@as(usize, main.addressPoolBatchForTest), asked);
    try testing.expectEqual(@as(usize, main.addressDialsPerRoundForTest), dialled);

    // The ones left over are not forgotten: the next round takes them.
    main.advanceQuoteRoundForTest(1);
    main.requestWantedQuotesForTest();
    asked = 0;
    for (keys) |k| {
        if (main.quoteForTest(k).?.requested) asked += 1;
    }
    try testing.expectEqual(@as(usize, 6), asked);
}

// ------------------------------------------------------------------ relay hints
//
// What Plaza writes into the relay slot of the tags and addresses it publishes.
// The reading half (an `nevent1` that names relays gets them asked) has its own
// tests; these pin the writing half, where a wrong answer is worse than none.

pub const hint_a = "wss://relay.alpha.example";
pub const hint_b = "wss://relay.bravo.example";
pub const hint_c = "wss://relay.charlie.example";

/// Resets the delivered-by table around a test, because it is process-wide and
/// the suite shares one process.
pub fn freshHints() void {
    main.resetSeenOnForTest();
}

fn nodeForHints(event_id: [32]u8, pubkey: [32]u8) main.Note {
    var note = main.Note{ .created_at = 1_800_000_000 };
    note.id = 4242;
    note.event_id = event_id;
    note.pubkey = pubkey;
    return note;
}

/// A kind:10002 for `kp`, writing to each of `urls`.
pub fn relayListFor(arena: std.mem.Allocator, signer: nostr.keys.Signer, kp: nostr.keys.KeyPair, urls: []const []const u8) !nostr.event.Event {
    const tags = try arena.alloc(nostr.event.Tag, urls.len);
    for (urls, 0..) |u, i| {
        const t = try arena.alloc([]const u8, 3);
        t[0] = "r";
        t[1] = u;
        t[2] = "write";
        tags[i] = t;
    }
    return signedKind(arena, signer, kp, 1_800_000_000, 10002, tags, "");
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

test "every relay-fed note ingest remembers which relay it came from" {
    // The helper being right is half of it. A new fetch path that ingests with the
    // bare funnel quietly stops teaching the hint table, and nothing else fails:
    // notes from it just publish with an empty hint. The six left on the bare
    // funnel read profiles, places, relay lists and media server lists, which
    // are never hinted at.
    // An article fetched by its address is a note like any other and is counted
    // with the rest.
    var bare: usize = 0;
    var from: usize = 0;
    for (app_sources) |s| {
        var it = std.mem.splitScalar(u8, s.text, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "plazaIngest(gpa, e.event, .{ .verify_with = signer })") != null) bare += 1;
            if (std.mem.indexOf(u8, line, "plazaIngestFrom(gpa, e.event, .{ .verify_with = signer }, ") != null) from += 1;
        }
    }
    try testing.expectEqual(@as(usize, 6), bare);
    try testing.expectEqual(@as(usize, 11), from);
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

test "the three ways to hand out a note address all carry the hint" {
    freshHints();
    defer freshHints();
    var model = main.initialModel();
    oneNoteFeed(&model);
    main.recordSeenOnForTest(model.notes[0].event_id, hint_a);
    var fx: main.EffectsForTest = undefined;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Copy note address.
    main.update(&model, Msg{ .copy_nevent = model.notes[0].id }, &fx);
    {
        const ptr = try nostr.nip19.decodeNevent(arena, main.lastClipboardForTest());
        try testing.expectEqual(@as(usize, 1), ptr.relays.len);
        try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    }

    // Quote: the address is typed into the draft after `nostr:`.
    main.setIdentityForTest([_]u8{0x53} ** 32);
    defer main.clearIdentityForTest();
    main.update(&model, Msg{ .quote_note = model.notes[0].id }, &fx);
    {
        const text = model.draft_buffer.text();
        try testing.expect(std.mem.startsWith(u8, text, "nostr:nevent1"));
        const ptr = try nostr.nip19.decodeNevent(arena, text["nostr:".len..]);
        try testing.expectEqual(@as(usize, 1), ptr.relays.len);
        try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    }
}

test "copying your profile address names the relays you publish to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{0x54} ** 32;
    main.setIdentityForTest(pk);
    defer main.clearIdentityForTest();
    const mine = main.activePubkeyForTest() orelse return error.NoIdentity;

    // The pool is whatever the process holds: pin it to two write relays, one
    // read-only relay and one nobody else could reach.
    main.clearRelaysForTest();
    defer main.resetRelaysForTest();
    _ = main.addRelayForTest(hint_a, true, true);
    _ = main.addRelayForTest(hint_b, true, false);
    _ = main.addRelayForTest("wss://127.0.0.1:7777", true, true);
    _ = main.addRelayForTest(hint_c, false, true);

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.copy_nprofile, &fx);
    const ptr = try nostr.nip19.decodeNprofile(arena, main.lastClipboardForTest());
    try testing.expectEqualSlices(u8, &mine, &ptr.pubkey);
    try testing.expectEqual(@as(usize, 2), ptr.relays.len);
    try testing.expectEqualStrings(hint_a, ptr.relays[0]);
    try testing.expectEqualStrings(hint_c, ptr.relays[1]);

    // Settings still copies the bare npub, which is what a tool that takes a key
    // wants.
    main.update(&model, Msg.copy_npub, &fx);
    try testing.expect(std.mem.startsWith(u8, main.lastClipboardForTest(), "npub1"));
}

// ---------------------------------------------------------- finding a person
//
// The field that opens an address finds people by name too. Two halves answer:
// every profile already on this machine, instantly and offline, then NIP-50
// search relays, folded in as they land and each marked with where it came from.
// These cover the matching and the ranking (`search.zig`), the field's decision
// about what a string is, and the hand-off from the relay threads to the list.

pub const search = main.search;

test "a term matches at the start, at a word, or anywhere, and says which" {
    try testing.expectEqual(search.Quality.exact, search.quality("jack", "JACK").?);
    try testing.expectEqual(search.Quality.prefix, search.quality("Jackson", "jack").?);
    try testing.expectEqual(search.Quality.word, search.quality("Black Jack", "jack").?);
    // The domain half of an address is a word of its own: `@` is a boundary.
    try testing.expectEqual(search.Quality.word, search.quality("bob@jack.example", "jack").?);
    try testing.expectEqual(search.Quality.within, search.quality("Hijack", "jack").?);
    try testing.expect(search.quality("Alice", "jack") == null);
    // The best occurrence wins, not the first.
    try testing.expectEqual(search.Quality.word, search.quality("Hijack jack", "jack").?);
}

test "the people who follow are listed before the people who are followed back before everyone" {
    const gpa = testing.allocator;
    var b = search.Builder.init(gpa);
    defer b.deinit();
    const pk = struct {
        fn of(n: u8) [32]u8 {
            return [_]u8{n} ** 32;
        }
    }.of;
    // Added newest-last on purpose, so order cannot come from insertion.
    try b.add(pk(1), .seen, 100, "Jackson", "", "");
    try b.add(pk(2), .seen, 100, "Hijack", "", "");
    try b.add(pk(3), .follows_me, 100, "Jack", "", "");
    try b.add(pk(4), .follows, 100, "Black Jack", "", "");
    try b.add(pk(5), .seen, 100, "Bob", "", "bob@jack.example");
    try b.add(pk(6), .seen, 100, "Nobody Relevant", "", "");
    var index = try b.finish();
    defer index.deinit(gpa);

    var hits: [8]search.Hit = undefined;
    const n = index.find("JACK", &hits);
    try testing.expectEqual(@as(usize, 5), n);
    const order = [_]u8{ 4, 3, 1, 5, 2 };
    for (order, 0..) |want, i| {
        try testing.expectEqual(want, index.entries[hits[i].entry].pubkey[0]);
    }

    // A short list keeps the best, not the first: the cap never costs the top.
    var two: [2]search.Hit = undefined;
    try testing.expectEqual(@as(usize, 2), index.find("jack", &two));
    try testing.expectEqual(@as(u8, 4), index.entries[two[0].entry].pubkey[0]);
    try testing.expectEqual(@as(u8, 3), index.entries[two[1].entry].pubkey[0]);
}

test "a term is cleaned the way it is sent" {
    var buf: [search.term_max]u8 = undefined;
    try testing.expectEqualStrings("Jack dorsey", search.cleanTerm(&buf, "  @Jack\n  dorsey  ").?);
    try testing.expect(search.cleanTerm(&buf, " \n\t ") == null);
    try testing.expect(search.cleanTerm(&buf, "@@") == null);
    // Cut at the cap, and never in the middle of a character.
    const long = "a" ** (search.term_max - 1) ++ "\u{00e9}";
    const cut = search.cleanTerm(&buf, long).?;
    try testing.expect(cut.len <= search.term_max);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "the search request is the NIP-50 shape and survives a hostile term" {
    const gpa = testing.allocator;
    const text = try search.requestText(gpa, "al\"ice\\ \u{00e9}\n");
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqualStrings("REQ", arr[0].string);
    try testing.expectEqualStrings(search.sub_id, arr[1].string);
    const filter = arr[2].object;
    try testing.expectEqualStrings("al\"ice\\ \u{00e9}\n", filter.get("search").?.string);
    try testing.expectEqual(@as(i64, 0), filter.get("kinds").?.array.items[0].integer);
    try testing.expectEqual(@as(i64, search.relay_limit), filter.get("limit").?.integer);
}

test "a search relay that asks for a login on connect is still read, and one that refuses is declined" {
    // The challenge alone ends nothing: the relay may well answer anyway.
    try testing.expect(search.settle(.auth, 0) == null);
    try testing.expect(search.settle(.event, 0) == null);
    try testing.expectEqual(search.RelayState.answered, search.settle(.eose, 0).?);
    try testing.expectEqual(search.RelayState.answered, search.settle(.eose, 4).?);
    // A CLOSED in place of results, `auth-required:` among them, is a refusal.
    try testing.expectEqual(search.RelayState.declined, search.settle(.closed, 0).?);
    try testing.expectEqual(search.RelayState.answered, search.settle(.closed, 2).?);
    try testing.expectEqual(search.RelayState.declined, search.settle(.notice, 0).?);
    try testing.expect(search.settle(.notice, 3) == null);
}

test "a relay's state and count travel as one word" {
    const s = search.Status{ .gen = 7, .state = .answered, .count = 12 };
    const back = search.Status.unpack(s.pack());
    try testing.expectEqual(@as(u32, 7), back.gen);
    try testing.expectEqual(search.RelayState.answered, back.state);
    try testing.expectEqual(@as(u16, 12), back.count);

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("found no one", search.describe(&buf, .answered, 0));
    try testing.expectEqualStrings("1 person", search.describe(&buf, .answered, 1));
    try testing.expectEqualStrings("3 people", search.describe(&buf, .answered, 3));
    try testing.expectEqualStrings("could not connect", search.describe(&buf, .unreachable_, 0));
    try testing.expectEqualStrings("did not answer", search.describe(&buf, .silent, 0));
}

test "one field: the button says what Enter will do with what is in it" {
    var model = main.initialModel();
    model.stage = .ready;
    main.searchResetForTest();
    defer main.searchResetForTest();
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg.open_address, &fx);

    main.update(&model, Msg{ .address_edit = .{ .insert_text = "alice" } }, &fx);
    try testing.expectEqualStrings("Search relays", model.address_action());
    main.update(&model, Msg{ .address_edit = .{ .insert_text = "@example.com" } }, &fx);
    try testing.expectEqualStrings("Look up", model.address_action());

    var addr = main.initialModel();
    addr.stage = .ready;
    main.update(&addr, Msg.open_address, &fx);
    main.update(&addr, Msg{ .address_edit = .{ .insert_text = "npub1abc" } }, &fx);
    try testing.expectEqualStrings("Open", addr.address_action());
}

// ------------------------------------------------------------ picture upload

pub const blossom = @import("blossom.zig");

/// Waits for an upload job to reach `phase`, which is moved by a worker thread.
pub fn awaitUpload(phase: []const u8) !void {
    var waited: usize = 0;
    while (waited < 1000) : (waited += 1) {
        if (std.mem.eql(u8, main.uploadStateForTest(), phase)) return;
        // A job that has failed will not reach anything else.
        if (std.mem.eql(u8, main.uploadStateForTest(), "failed") and !std.mem.eql(u8, phase, "failed")) return error.UploadFailed;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    std.debug.print("\nupload stuck in {s}, wanted {s}\n", .{ main.uploadStateForTest(), phase });
    return error.UploadStuck;
}

/// A picture on disk for the file dialog to hand back.
pub fn writeTestPicture(name: []const u8, w: u32, h: u32, extra: []const u8) ![]const u8 {
    const png = try blossom.testPng(testing.allocator, w, h, extra);
    defer testing.allocator.free(png);
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = png });
    return path;
}

test "a picture this app uploaded carries everything the uploader knew in its imeta" {
    // A reader fetching a picture learns its type from the server. Only an
    // uploader has the hash, the size, the dimensions and the blurhash before
    // anyone has fetched the file, and a note that leaves them out makes every
    // client that opens it lay the picture out blind.
    main.forgetUploadedForTest();
    defer main.forgetUploadedForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const sha = "ab" ** 32;
    main.rememberUploadedForTest("https://cdn.example/" ++ sha ++ ".png", "image/png", sha, 48211, 800, 600, "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "A red door");

    const tags = main.contentTagsForTest(gpa, "look at this\nhttps://cdn.example/" ++ sha ++ ".png\n");
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expectEqual(@as(usize, 8), im.len);
    try testing.expectEqualStrings("url https://cdn.example/" ++ sha ++ ".png", im[1]);
    try testing.expectEqualStrings("m image/png", im[2]);
    try testing.expectEqualStrings("x " ++ sha, im[3]);
    try testing.expectEqualStrings("size 48211", im[4]);
    try testing.expectEqualStrings("dim 800x600", im[5]);
    try testing.expectEqualStrings("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj", im[6]);
    try testing.expectEqualStrings("alt A red door", im[7]);
    // And the reader of that note can use it: Plaza's own parser reads it back.
    const meta = main.imetaFor(tags, "https://cdn.example/" ++ sha ++ ".png");
    try testing.expectEqual(@as(u16, 800), meta.width);
    try testing.expectEqual(@as(u16, 600), meta.height);
    try testing.expectEqualStrings("A red door", meta.alt);
    try testing.expectEqual(@as(u32, 48211), meta.size);

    // An address with no extension is a picture here, because this app sent it;
    // anywhere else it is a link, and gets no tag.
    main.rememberUploadedForTest("https://cdn.example/" ++ sha, "image/webp", sha, 10, 0, 0, "", "");
    const bare = main.contentTagsForTest(gpa, "https://cdn.example/" ++ sha ++ " and https://other.example/page");
    try testing.expectEqual(@as(usize, 1), countTags(bare, "imeta"));
    const bare_im = tagNamed(bare, "imeta").?;
    try testing.expectEqualStrings("m image/webp", bare_im[2]);
    // Nothing unknown is written empty.
    try testing.expectEqual(@as(usize, 5), bare_im.len);
}

test "a picture goes from a chosen file to an address in the note, through the signer and over HTTP" {
    // The whole path on one thread of events: the file dialog (stood in for), the
    // worker that reads and cleans the file, the kind:24242 token signed by the
    // same stand-in keyholder every other test signs with, the send to a server
    // on loopback, and the address landing in the draft with its imeta.
    main.forgetBlossomForTest();
    main.forgetUploadedForTest();
    main.clearLastPublishedForTest();
    main.setIdentityForTest([_]u8{0x4a} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.forgetUploadedForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    var extra = std.ArrayList(u8).empty;
    defer extra.deinit(testing.allocator);
    try blossomPngText(testing.allocator, &extra, "taken at 12.34N 56.78E");
    const path = try writeTestPicture("upload-test-note.png", 40, 30, extra.items);
    defer testing.allocator.free(path);

    const srv = try blossom.TestServer.start(testing.io, .accept, 2);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    const server_url = srv.url(&url_buf);
    main.setBlossomServersForTest(&.{server_url});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("a good one");
    var fx: main.EffectsForTest = undefined;

    // Choosing the file reads it and stops. Nothing has been signed or sent.
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    try testing.expectEqual(@as(usize, 0), srv.heads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), srv.puts.load(.acquire));
    try testing.expect(!main.helperSignPendingForTest());

    // The card names the server before the press.
    const ready_tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(ready_tree.root, "from your server list"));
    try testing.expect(findAnyTextContaining(ready_tree.root, "127.0.0.1"));
    try testing.expect(findAnyTextContaining(ready_tree.root, "upload-test-note.png"));
    try testing.expect(findAnyText(ready_tree.root, "Upload") != null);
    try testing.expect(findAnyTextContaining(ready_tree.root, "Location and camera details"));

    model.upload_alt_buffer.set("A square of nothing");
    main.update(&model, .upload_go, &fx);
    // The stand-in keyholder answers at once, so the token is already back.
    try testing.expectEqualStrings("signed", main.uploadStateForTest());
    main.driveUploadForTest(&model);
    try awaitUpload("sent");
    main.driveUploadForTest(&model);

    try testing.expectEqualStrings("none", main.uploadStateForTest());
    try testing.expectEqual(@as(usize, 1), srv.puts.load(.acquire));
    try testing.expect(srv.body_matches_header.load(.acquire));
    try testing.expect(srv.auth_ok.load(.acquire));
    // The file that was sent is the cleaned one: the text chunk with where it was
    // taken is not in it.
    try testing.expect(srv.body_len.load(.acquire) > 0);
    try testing.expect(!srv.body_has_text.load(.acquire));

    // The address is in the draft, after what was already there, and the whole
    // note's tags carry the picture's imeta.
    const draft = model.draft();
    try testing.expect(std.mem.startsWith(u8, draft, "a good one\nhttp://127.0.0.1:"));
    const tags = main.contentTagsForTest(a.allocator(), draft);
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expect(std.mem.startsWith(u8, im[1], "url http://127.0.0.1:"));
    try testing.expectEqualStrings("m image/png", im[2]);
    try testing.expect(std.mem.startsWith(u8, im[3], "x "));
    try testing.expectEqual(@as(usize, 64 + 2), im[3].len);
    try testing.expectEqualStrings("dim 40x30", im[5]);
    try testing.expectEqualStrings("blurhash L00000fQfQfQfQfQfQfQfQfQfQfQ", im[6]);
    try testing.expectEqualStrings("alt A square of nothing", im[7]);
    // Nothing was published: the token is a credential, not a record.
    try testing.expect(main.lastPublishedForTest() == null);
}

fn blossomPngText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    // A tEXt chunk, built by hand so the test does not depend on blossom.zig's
    // private helper.
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast("Comment\x00".len + text.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, "tEXt");
    try out.appendSlice(gpa, "Comment\x00");
    try out.appendSlice(gpa, text);
    var crc = std.hash.Crc32.init();
    crc.update("tEXt");
    crc.update("Comment\x00");
    crc.update(text);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

test "a failed upload keeps the draft, says why in plain words, and can be tried again" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4b} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const path = try writeTestPicture("upload-test-fail.png", 8, 8, "");
    defer testing.allocator.free(path);

    const srv = try blossom.TestServer.start(testing.io, .refuse_put, 4);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("words I must not lose");
    var fx: main.EffectsForTest = undefined;

    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .upload_go, &fx);
    main.driveUploadForTest(&model);
    try awaitUpload("failed");

    try testing.expectEqualStrings("words I must not lose", model.draft());
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "payment required") != null);
    const tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(tree.root, "payment required"));
    try testing.expect(findAnyText(tree.root, "Try again") != null);
    try testing.expect(findAnyText(tree.root, "Dismiss") != null);

    // Try again sends the same file with the same token: the signer is not
    // asked a second time for something it already approved.
    main.update(&model, .upload_retry, &fx);
    try testing.expectEqualStrings("signed", main.uploadStateForTest());
    main.driveUploadForTest(&model);
    try awaitUpload("failed");
    try testing.expectEqual(@as(usize, 2), srv.puts.load(.acquire));

    // A token is good for an hour. Once that is nearly over, Try again asks the
    // signer for a new one instead of sending one every server will refuse.
    main.ageUploadTokenForTest(blossom.auth_lifetime_s);
    main.silenceTestSignerForTest(true);
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    main.update(&model, .upload_retry, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
    try testing.expect(main.helperSignPendingForTest());

    // Dismissing puts the card away and leaves the words.
    main.update(&model, .upload_cancel, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    try testing.expectEqualStrings("words I must not lose", model.draft());
}

test "choosing a file uploads nothing, and what is not a picture is refused by its bytes" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4c} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = ".zig-cache/upload-test-notes.png", .data = "%PDF-1.7 a document that has been named like a picture" });

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(".zig-cache/upload-test-notes.png");
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("failed");
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "not a picture") != null);
    try testing.expect(!main.helperSignPendingForTest());

    // A file that is not there.
    main.dropUploadForTest();
    main.setPickPathForTest(".zig-cache/upload-test-missing.png");
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("failed");
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "no longer there") != null);

    // A guest is not offered any of it.
    main.dropUploadForTest();
    main.clearIdentityForTest();
    var guest = main.initialModel();
    main.setPickPathForTest(".zig-cache/upload-test-notes.png");
    main.update(&guest, .{ .upload_pick = 0 }, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
}

test "a token for some other file, or for more than this upload, is not accepted from a signer" {
    const sha = "cd" ** 32;
    const now: i64 = 1_700_000_000;
    const good = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(main.tokenNamesFileForTest(&good, sha, now));
    try testing.expect(!main.tokenNamesFileForTest(&good, "ef" ** 32, now));
    const wrong_purpose = [_]nostr.event.Tag{ &.{ "t", "delete" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&wrong_purpose, sha, now));
    const no_file = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" } };
    try testing.expect(!main.tokenNamesFileForTest(&no_file, sha, now));
    // Wider than what was asked: a delete as well, or a second file.
    const also_delete = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "t", "delete" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&also_delete, sha, now));
    const two_files = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" }, &.{ "x", sha }, &.{ "x", "ef" ** 32 } };
    try testing.expect(!main.tokenNamesFileForTest(&two_files, sha, now));
    // Good forever, already over, or good for a year.
    const no_expiry = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&no_expiry, sha, now));
    const expired = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1699999999" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&expired, sha, now));
    const a_year = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1731536000" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&a_year, sha, now));
}

test "a new upload waits while a bunker still holds the token of one that was put away" {
    // A bunker takes several requests at once. A picture put away while its
    // token was out leaves that request live, and whatever comes back for it
    // would land on the next upload to start signing: a refusal would fail it,
    // and an approval would be for a different file.
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x57} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.clearPendingForTest();
    defer main.setSignerKindLocalForTest();
    const path = try writeTestPicture("upload-test-outstanding.png", 8, 8, "");
    defer testing.allocator.free(path);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.setRemotePubkeyForTest([_]u8{0x58} ** 32);
    main.setSignerKindForTest("remote");

    try testing.expect(main.registerPendingForTest("an-earlier-token", .sign_upload_auth, null));
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("ready", main.uploadStateForTest());
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "busy") != null);

    // Once that one has come back, the press goes through.
    _ = main.takePendingContentForTest("an-earlier-token");
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
}

test "a token from a remote signer reaches the upload and is never published" {
    // The bunker's answer arrives on the listener thread and is parked for the
    // tick; the same signed event is what the built-in keyholder returns.
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4e} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    main.forgetLastPublishedForTest();
    const path = try writeTestPicture("upload-test-remote.png", 8, 8, "");
    defer testing.allocator.free(path);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.silenceTestSignerForTest(true);
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());

    // What the bunker would return: this account's token, for this file.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4e} ** 32);
    const sha = try uploadedFileSha(a.allocator(), path);
    const now = main.nowSecondsForTest();
    const tags = try blossom.authTags(a.allocator(), &sha, 0, now + blossom.auth_lifetime_s);
    const ev = try nostr.event.create(a.allocator(), signer, kp, now, blossom.auth_kind, tags, blossom.auth_content, null);
    main.parkUploadSignForTest(try nostr.event.toJson(a.allocator(), ev));
    main.driveUploadForTest(&model);
    try testing.expectEqualStrings("sending", main.uploadStateForTest());
    try testing.expect(main.lastPublishedForTest() == null);

    // And a bunker that answers with nothing usable ends the attempt.
    main.dropUploadForTest();
    main.releaseHelperSignForTest();
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .upload_go, &fx);
    main.parkUploadSignForTest(null);
    main.driveUploadForTest(&model);
    try testing.expectEqualStrings("failed", main.uploadStateForTest());
}

/// The sha256 the app will compute for a test picture on disk (it has no
/// metadata to strip, so it is the file's own).
fn uploadedFileSha(gpa: std.mem.Allocator, path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "the avatar and the banner take the address into their own fields, and only those" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x50} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const path = try writeTestPicture("upload-test-avatar.png", 16, 16, "");
    defer testing.allocator.free(path);
    const srv = try blossom.TestServer.start(testing.io, .accept, 4);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .have;
    model.profile_banner_buffer.set("https://old.example/banner.png");
    model.draft_buffer.set("untouched");
    var fx: main.EffectsForTest = undefined;

    // The sheet offers both, and the card stands where the field was.
    const before = try buildTree(a.allocator(), &model);
    try testing.expectEqual(@as(usize, 2), countByLabel(before.root, "Upload..."));
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 1 }, &fx);
    try awaitUpload("ready");
    const during = try buildTree(a.allocator(), &model);
    try testing.expectEqual(@as(usize, 1), countByLabel(during.root, "Upload..."));
    try testing.expect(findAnyTextContaining(during.root, "127.0.0.1"));
    // No description box for a profile picture: it has no imeta to put one in.
    try testing.expect(findByLabel(during.root, "Picture description") == null);

    main.update(&model, .upload_go, &fx);
    main.driveUploadForTest(&model);
    try awaitUpload("sent");
    main.driveUploadForTest(&model);
    try testing.expect(std.mem.startsWith(u8, model.profile_picture(), "http://127.0.0.1:"));
    try testing.expectEqualStrings("https://old.example/banner.png", model.profile_banner());
    try testing.expectEqualStrings("untouched", model.draft());
    // Not saved: that is its own press, and the sheet says so, because a field
    // with an address in it does not tell anyone the picture is not out yet.
    try testing.expect(main.lastPublishedForTest() == null);
    const filled = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(filled.root, "not published until you press Save"));

    // Closing the sheet puts a picture still on its way away with it.
    main.update(&model, .{ .upload_pick = 2 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .close_profile_edit, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    // And so does the sheet closing because Settings was opened over it.
    model.editing_profile = true;
    main.update(&model, .{ .upload_pick = 1 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .open_settings, &fx);
    try testing.expect(!model.editing_profile);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    // And reopening starts clean.
    model.editing_profile = true;
    const reopened = try buildTree(a.allocator(), &model);
    try testing.expect(!findAnyTextContaining(reopened.root, "not published until you press Save"));
}

/// Puts `count` kind:1 notes by `author` into the store, newest first by
/// construction: note `i` is dated `newest - i`. With `reply`, each one answers
/// somebody, which is what makes the Notes tab count them as replies.
pub fn seedAuthorNotes(store: *nostr.store.Store, arena: std.mem.Allocator, author: [32]u8, count: usize, newest: i64, reply: bool) !void {
    for (0..count) |i| {
        var id = [_]u8{0} ** 32;
        std.mem.writeInt(u32, id[0..4], @intCast(i + 1), .big);
        id[31] = author[0];
        var parent_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&parent_hex, "{s}", .{"ab" ** 32}) catch unreachable;
        const tags: []const nostr.event.Tag = if (reply) &.{&.{ "e", &parent_hex, "", "reply" }} else &.{};
        const ev = nostr.event.Event{
            .id = id,
            .pubkey = author,
            .created_at = newest - @as(i64, @intCast(i)),
            .kind = 1,
            .tags = tags,
            .content = "a note",
            .sig = [_]u8{0} ** 64,
        };
        _ = try store.ingest(arena, ev, .{});
    }
}

test "a person's page pages down through the store, then asks the relays for older notes" {
    // A profile read one page from the store and one from the relays and stopped.
    // The list had no end to reach, so the notes under the first hundred (sixty
    // or so on the Notes tab, once the replies are taken out) were out of reach.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/paging.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x61} ** 32;
    const newest: i64 = 1_800_000_000;
    try seedAuthorNotes(&store, arena, who, 250, newest, false);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    // The first page is what it always was.
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);

    // Reaching the end reads the next page from disk. No relay is involved.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 200), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // The store has fifty more, then it has no more.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Newest first, no repeats, and every row is theirs.
    for (model.thread_notes[0..250], 0..) |note, i| {
        try testing.expectEqual(newest - @as(i64, @intCast(i)), note.created_at);
        try testing.expectEqualSlices(u8, &who, &note.pubkey);
    }

    // Now the relays are asked, from as far back as they have brought this
    // person's notes: here the first page, their newest hundred.
    main.noteProfileReachForTest(who, newest - 99);
    main.loadOlderProfileForTest(&model);
    const ask = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqualSlices(u8, &who, &ask.pubkey);
    try testing.expectEqual(newest - 99, ask.until);
}

test "older notes are asked from where the relays reached, not from an old note the store happened to hold" {
    // The store holds what any surface fetched. Beside the run the relays paged
    // through, it can hold one old note of theirs from a thread or a quote, and
    // paging from the oldest note in hand jumped straight past everything in
    // between. On the next visit that note was still the oldest in hand, so the
    // gap was skipped every time.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/gap.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x6b} ** 32;
    const newest: i64 = 1_800_000_000;
    try seedAuthorNotes(&store, arena, who, 40, newest, false);
    // A year older, and nothing in between.
    var old = nostr.event.Event{
        .id = [_]u8{0x6b} ** 32,
        .pubkey = who,
        .created_at = newest - 365 * 24 * 3600,
        .kind = 1,
        .tags = &.{},
        .content = "an old note somebody quoted",
        .sig = [_]u8{0} ** 64,
    };
    old.id[0] = 0xEE;
    _ = try store.ingest(arena, old, .{});

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 41), model.thread_notes_len);

    // No round has brought a note yet, so there is no run to continue: the page
    // asks for their newest, from the moment it opened.
    main.loadOlderProfileForTest(&model);
    const first = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(model.thread_open_at, first.until);

    // The relays brought the forty. The next page starts under them, not under
    // the note from a year ago.
    main.noteProfileReachForTest(who, newest - 39);
    main.loadOlderProfileForTest(&model);
    const next = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(newest - 39, next.until);

    // A round for somebody else says nothing about this person.
    main.noteProfileReachForTest([_]u8{0x6c} ** 32, newest - 5000);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));
    // A later round can only take it further back.
    main.noteProfileReachForTest(who, newest - 10);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));

    // Back from a thread keeps how far the relays got; a fresh visit does not.
    main.enterThreadForTest(&model, model.thread_notes[0]);
    main.closeThreadForTest(&model);
    try testing.expectEqual(@as(?i64, newest - 39), main.profileReachForTest(who));
    main.enterProfileForTest(&model, [_]u8{0x6c} ** 32);
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(?i64, null), main.profileReachForTest(who));
}

test "a round reaches as far as every relay asked has answered for" {
    // Each relay sends its newest page under the cursor. Under the oldest note
    // of the shortest page, another relay may hold notes nobody sent yet, so the
    // cut is the hundredth newest distinct note across all of them.
    var seen: [200]main.ProfileSeen = undefined;
    // Relay one: a full page, one note a second from 1000 down to 901.
    for (0..100) |i| seen[i] = .{ .at = 1000 - @as(i64, @intCast(i)), .key = @intCast(i + 1) };
    // Relay two: the same newest fifty, then fifty far older ones.
    for (0..50) |i| seen[100 + i] = seen[i];
    for (0..50) |i| seen[150 + i] = .{ .at = 500 - @as(i64, @intCast(i)), .key = @intCast(1000 + i) };
    // Under 901 only relay two has answered: relay one stopped at its hundredth
    // and may hold everything between 901 and 451. So the cut is 901, and a note
    // both relays sent counts once (twice, and the cut would stop at 951).
    const cut = main.roundReachForTest(&seen) orelse return error.NoReach;
    try testing.expectEqual(@as(i64, 901), cut);

    // Fewer than a page in all: every relay sent what it had, so the oldest.
    var few = [_]main.ProfileSeen{ .{ .at = 30, .key = 3 }, .{ .at = 10, .key = 1 }, .{ .at = 20, .key = 2 } };
    try testing.expectEqual(@as(?i64, 10), main.roundReachForTest(&few));
    var none: [0]main.ProfileSeen = .{};
    try testing.expectEqual(@as(?i64, null), main.roundReachForTest(&none));
}

test "back from a note keeps a person's page as deep as it was paged" {
    // Back rebuilt the page from its first hundred, so a reader three pages down
    // came back to a list cut short under them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/depth.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x6d} ** 32;
    try seedAuthorNotes(&store, arena, who, 250, 1_800_000_000, false);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    main.loadOlderProfileForTest(&model);
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);

    main.enterThreadForTest(&model, model.thread_notes[220]);
    main.closeThreadForTest(&model);
    try testing.expect(model.viewing_profile != null);
    try testing.expectEqual(@as(usize, 250), model.thread_notes_len);
}

test "a person's history ends when the relays say it does, and the page says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/ending.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    const who = [_]u8{0x62} ** 32;
    const other = [_]u8{0x63} ** 32;
    try seedAuthorNotes(&store, arena, who, 2, 1_800_000_000, false);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 2), model.thread_notes_len);

    // Not at the end until a relay has said so: nothing says it yet, and a list
    // that claims an end it has not found would hide the rest of the history.
    try testing.expectEqual(@as(u8, 0), main.profileFooterForTest(&model, who, 2));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(!findAnyTextContaining(tree.root, "That is everything"));
    }

    main.setProfileEndForTest(who);
    try testing.expect(main.profileEndReachedForTest(who));
    {
        const tree = try buildTree(arena, &model);
        try testing.expect(findAnyTextContaining(tree.root, "That is everything the relays have from them."));
    }

    // And it is THEIR end, not the page's: it says nothing about anybody else.
    try testing.expect(!main.profileEndReachedForTest(other));

    // At the end the reader's scroll asks nobody anything.
    main.resetProfileEndForTest();
    main.setProfileEndForTest(who);
    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Opening the page again is asking again.
    main.enterProfileForTest(&model, other);
    main.enterProfileForTest(&model, who);
    try testing.expect(!main.profileEndReachedForTest(who));
}

test "a list whose bottom is in view asks for more, even when it is too short to scroll" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/fill.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // Someone who only ever answers other people: every one of their notes is a
    // reply, so the Notes tab is empty however much history there is, and an
    // empty list has no end to scroll to.
    const who = [_]u8{0x64} ** 32;
    try seedAuthorNotes(&store, arena, who, 150, 1_800_000_000, true);

    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);
    var buf: [200]usize = undefined;
    try testing.expectEqual(@as(usize, 0), model.profileNotesFor(&buf, who).len);

    // Bottom out of view: nothing to do.
    main.loadAtProfileBottomForTest(&model, false);
    try testing.expectEqual(@as(usize, 100), model.thread_notes_len);

    // In view: from the store first.
    main.loadAtProfileBottomForTest(&model, true);
    try testing.expectEqual(@as(usize, 150), model.thread_notes_len);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Then from the relays, once the store has nothing more, from as far back as
    // they have brought this person's notes.
    main.noteProfileReachForTest(who, 1_800_000_000 - 99);
    main.loadAtProfileBottomForTest(&model, true);
    const ask = main.profileOlderAskForTest() orelse return error.NoOlderAsk;
    try testing.expectEqual(@as(i64, 1_800_000_000 - 99), ask.until);

    // And not again from the same place. A round that left the list as it was
    // would otherwise be asked for once a second for as long as the page is open.
    main.resetProfileEndForTest();
    main.loadAtProfileBottomForTest(&model, true);
    try testing.expect(main.profileOlderAskForTest() == null);
}

test "a short tab fills itself a few pages and then leaves the rest to the reader" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/bounded.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // A thousand replies and no notes: the Notes tab stays empty however far
    // back it goes, which is what the bound is for.
    const who = [_]u8{0x6a} ** 32;
    try seedAuthorNotes(&store, arena, who, 1000, 1_800_000_000, true);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);

    for (0..20) |_| main.loadAtProfileBottomForTest(&model, true);
    // 100 to open, plus a page for each automatic ask.
    try testing.expectEqual(@as(usize, 100 + 5 * 100), model.thread_notes_len);

    // The reader scrolling to the end still gets another.
    main.loadOlderProfileForTest(&model);
    try testing.expectEqual(@as(usize, 100 + 6 * 100), model.thread_notes_len);
}

test "older notes are asked of the relays the person publishes to, then the reader's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/targets.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.clearRelaysForTest();
    defer main.clearRelaysForTest();
    _ = main.addRelayForTest("wss://reader.example.com", true, true);
    _ = main.addRelayForTest("wss://writeonly.example.com", false, true);

    const who = [_]u8{0x67} ** 32;
    const list = nostr.event.Event{
        .id = [_]u8{0x67} ** 32,
        .pubkey = who,
        .created_at = 1_800_000_000,
        .kind = 10002,
        .tags = &.{
            &.{ "r", "wss://their.example.com" },
            &.{ "r", "wss://readonly.example.com", "read" },
            &.{ "r", "wss://reader.example.com", "write" },
            &.{ "r", "wss://their.example.com" },
        },
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    _ = try store.ingest(arena, list, .{});

    var out: [12][96]u8 = undefined;
    var lens: [12]u8 = undefined;
    const n = main.profileTargetsForTest(who, &out, &lens);
    // Their write relays in the order they listed them (a repeat and a read-only
    // relay left out), then the reader's read relays they did not already name:
    // the reader's own relay is named by both and asked once.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("wss://their.example.com", out[0][0..lens[0]]);
    try testing.expectEqualStrings("wss://reader.example.com", out[1][0..lens[1]]);

    // Somebody whose list has not arrived is asked of the reader's relays alone.
    const stranger = [_]u8{0x68} ** 32;
    const m = main.profileTargetsForTest(stranger, &out, &lens);
    try testing.expectEqual(@as(usize, 1), m);
    try testing.expectEqualStrings("wss://reader.example.com", out[0][0..lens[0]]);
}

test "history is not declared over by a round that was only second to the first fetch" {
    // Opening a page races two fetches for the same notes. Whichever lands
    // second finds every one of them already stored, and "nothing was new to the
    // store" read as "nothing older exists". On a person with two hundred notes
    // that put "That is everything" under the first hundred.
    try testing.expect(!main.profileRoundEndedForTest(1, 1, 0, 99));
    // A relay that answered and had nothing older is the only thing that ends it.
    try testing.expect(main.profileRoundEndedForTest(1, 1, 0, 0));
    // One that never answered says nothing at all.
    try testing.expect(!main.profileRoundEndedForTest(1, 0, 0, 0));
    try testing.expect(!main.profileRoundEndedForTest(0, 0, 0, 0));
}

test "a short page does not page while its own first fetch is still out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&pbuf, ".zig-cache/tmp/{s}/racing.mdb", .{tmp.sub_path});
    var store = try nostr.store.Store.open(db_path, .{});
    defer store.deinit();
    main.setStoreForTest(&store);
    defer main.setStoreForTest(null);
    main.resetProfileEndForTest();
    defer main.resetProfileEndForTest();

    // One note held, the way it is when the first fetch has not come back: the
    // list is short, so it is "at its end" the moment it opens.
    const who = [_]u8{0x69} ** 32;
    try seedAuthorNotes(&store, arena, who, 1, 1_800_000_000, false);
    var model = main.initialModel();
    model.stage = .ready;
    main.enterProfileForTest(&model, who);
    main.setFirstProfileFetchOutForTest(&model, true);

    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() == null);

    // Once the first fetch has landed, reaching the end asks.
    main.setFirstProfileFetchOutForTest(&model, false);
    main.loadOlderProfileForTest(&model);
    try testing.expect(main.profileOlderAskForTest() != null);
}

test "a pressed hashtag opens the tag that was pressed, however many were drawn after it" {
    // A hashtag's payload has to outlive the build that made it, because the
    // press is delivered against that build's tree. It used to sit in a ring of
    // sixteen that every hashtag drawn took the next slot of, so the seventeenth
    // tag on screen wrote over the first, and pressing the first opened the
    // seventeenth's page.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ui = main.AppUi.init(arena_state.allocator());
    var buf: [32]u8 = undefined;

    // Two builds away from whatever earlier tests drew, so the room is all free.
    main.beginViewBuildForTest();
    main.beginViewBuildForTest();
    const first = main.contentSpans(&ui, "#First")[0].link;
    // Twenty more distinct tags in the same build, more than the old ring held.
    for (0..20) |i| {
        const text = try std.fmt.bufPrint(&buf, "#later{d}", .{i});
        const spans = main.contentSpans(&ui, text);
        try testing.expectEqualStrings(text[1..], main.topicLinkValueForTest(spans[0].link) orelse return error.NoTopic);
    }
    try testing.expectEqualStrings("first", main.topicLinkValueForTest(first) orelse return error.NoTopic);

    // The next build may still be answering a press on the last one, so what the
    // last one drew is kept through it, even when this one draws more tags than
    // there is room for. One that finds no room is drawn without a payload: a
    // run that opens nothing, never one that opens another tag.
    main.beginViewBuildForTest();
    for (0..100) |i| {
        const text = try std.fmt.bufPrint(&buf, "#flood{d}", .{i});
        const link = main.contentSpans(&ui, text)[0].link;
        if (main.topicLinkValueForTest(link)) |topic| try testing.expectEqualStrings(text[1..], topic);
    }
    try testing.expectEqualStrings("first", main.topicLinkValueForTest(first) orelse return error.NoTopic);

    // And the press itself lands on the tag that was pressed.
    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.update(&model, Msg{ .open_url = first }, &fx);
    try testing.expectEqualStrings("first", model.viewingTopic() orelse return error.NoTopic);
    main.closeThreadForTest(&model);

    // Two builds on, nothing can press the old payloads any more, and the room
    // they held is given out again.
    main.beginViewBuildForTest();
    main.beginViewBuildForTest();
    const fresh = main.contentSpans(&ui, "#fresh")[0].link;
    try testing.expectEqualStrings("fresh", main.topicLinkValueForTest(fresh) orelse return error.NoTopic);
}

// ---- settings, relays and signing in: the dead ends --------------------------

fn findKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findKind(child, kind)) |found| return found;
    }
    return null;
}

test "a relay address with a control byte, a space or a bad port is refused" {
    // The address is written to the relays file one relay per line and sent in
    // the handshake's request line, so a BEL in it was listed, counted, dialled
    // and saved.
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/\x07"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/a\nb"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io/a b"));
    try testing.expect(!main.isRelayUrl("wss://relay.damus.io\x7f"));
    try testing.expect(!main.isRelayUrl("wss://relay.example.com:notaport"));
    try testing.expect(main.isRelayUrl("wss://relay.damus.io/"));
    try testing.expect(main.isRelayUrl("wss://relay.example.com:7447/path"));

    // And through the Add press, which is the door the reader uses.
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    const before = main.relayCount();
    model.relay_buffer.set("wss://relay.damus.io/\x07");
    main.update(&model, .relay_add, &fx);
    try testing.expectEqual(before, main.relayCount());
    try testing.expect(model.relay_error);
    try testing.expectEqualStrings("A relay address starts with wss:// and names a host.", model.relay_status());
}

test "the last relay cannot be removed, and the press says why" {
    main.resetRelaysForTest();
    defer main.resetRelaysForTest();
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;

    // Down to one by the same function the button calls.
    var i: usize = 0;
    while (main.relayCount() > 1) : (i += 1) {
        if (main.relayAt(i) != null) main.removeRelayForTest(i);
    }
    var last: usize = 0;
    while (main.relayAt(last) == null) : (last += 1) {}

    main.update(&model, Msg{ .relay_remove = @intCast(last) }, &fx);
    try testing.expectEqual(@as(usize, 1), main.relayCount());
    try testing.expect(model.relay_last);
    try testing.expect(std.mem.indexOf(u8, model.relay_status(), "at least one relay") != null);

    // Adding another is what makes room, and the complaint goes with it.
    model.relay_buffer.set("wss://relay.example.com");
    main.update(&model, .relay_add, &fx);
    try testing.expectEqual(@as(usize, 2), main.relayCount());
    try testing.expect(!model.relay_last);
    main.update(&model, Msg{ .relay_remove = @intCast(last) }, &fx);
    try testing.expectEqual(@as(usize, 1), main.relayCount());
}

test "a paused pool is not worded or coloured as a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.stage = .ready;

    // No relay is up in a test. Not paused: the amber failure strip.
    const down = try painted.Painted.render(arena, &model);
    try testing.expect(down.fillRectOf(theme.palette.surface_offline) != null);
    try testing.expect(down.frameOf("Resume relays") == null);

    // Paused: the same silence, but it is the reader's doing, so it is not amber
    // and it carries the way back.
    model.relays_paused = true;
    const paused = try painted.Painted.render(arena, &model);
    try testing.expect(paused.fillRectOf(theme.palette.surface_offline) == null);
    try testing.expect(paused.frameOf("Resume relays") != null);
    try testing.expect(std.mem.indexOf(u8, main.pausedBannerTextForTest(arena, 0), "paused") != null);
    try testing.expect(std.mem.indexOf(u8, main.pausedBannerTextForTest(arena, 2), "2 notes are waiting") != null);

    // And a list with nobody in it is not "no relay is answering".
    const none = main.offlineBannerTextForTest(arena, 0, true);
    try testing.expect(std.mem.indexOf(u8, none, "No relays are set up") != null);
    try testing.expect(std.mem.indexOf(u8, none, "answering") == null);
}

test "asking to log out brings the question into view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    model.stage = .settings;
    // The reader has scrolled to the foot of the page to find the button.
    main.update(&model, Msg{ .settings_scrolled = .{ .offset_y = 120, .viewport_extent_y = 500, .content_extent_y = 620 } }, &fx);
    try testing.expectEqual(@as(f32, 120), model.settings_scroll_y);

    main.update(&model, .logout_request, &fx);
    try testing.expect(model.logout_pending);
    try testing.expectEqual(main.settings_scroll_end, model.settings_scroll_y);
    // And the scroll view is told, which is what moves the page.
    const tree = try buildTree(arena, &model);
    const scroll = findKind(tree.root, .scroll_view) orelse return error.NoScroll;
    try testing.expectEqual(main.settings_scroll_end, scroll.value);

    // Reopening Settings starts at the top, not where the last visit asked for.
    main.update(&model, .close_settings, &fx);
    main.update(&model, .open_settings, &fx);
    try testing.expectEqual(@as(f32, 0), model.settings_scroll_y);
}

test "copying the npub says it was copied" {
    var model = main.initialModel();
    var fx: main.EffectsForTest = undefined;
    main.recordingEffectsForTest(&fx, testing.allocator);
    defer fx.deinit();
    main.setIdentityForTest([_]u8{82} ** 32);
    defer main.clearIdentityForTest();
    main.update(&model, .copy_npub, &fx);
    try testing.expectEqualStrings("npub copied", model.toast_text());
}

test "a bunker link signs the reader in when the signer answers, not before" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    var id_buf: [24]u8 = undefined;
    const id = main.beginBunkerConnectForTest([_]u8{0x5A} ** 32, &id_buf);

    // Waiting: the sheet is up, the reader is a guest, and the button says so.
    main.driveBunkerConnectForTest(&model);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expectEqualStrings("Connecting to your signer…", model.login_status());
    // A second press while waiting does not replace the pairing.
    model.login_buffer.set("bunker://anything");
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());

    // The signer answers: now, and only now, the reader is in.
    main.answerBunkerConnectForTest(id);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!model.is_guest());
    try testing.expect(!model.joining and !model.bunker_mode);
    try testing.expectEqual(main.Stage.ready, model.stage);
}

test "a bunker that does not answer leaves the reader a guest, with the reason" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    var model = main.initialModel();
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    var id_buf: [24]u8 = undefined;
    const id = main.beginBunkerConnectForTest([_]u8{0x5B} ** 32, &id_buf);
    // The send could not reach the relay, or the signer said no.
    try testing.expect(main.failPendingForTest(id));
    main.scanPendingRemoteForTest(&model, &fx);
    main.driveBunkerConnectForTest(&model);

    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());
    // Still on the sheet they pasted into, told what happened.
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expect(std.mem.indexOf(u8, model.login_status(), "Couldn't connect to your signer") != null);
    // And no sign request can be waiting on a signer that was never reached.
    try testing.expect(main.takePendingContentForTest(id) == null);

    // Backing out of the sheet while it waits cancels the pairing.
    _ = main.beginBunkerConnectForTest([_]u8{0x5C} ** 32, &id_buf);
    main.update(&model, .close_bunker, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("", model.login_status());

    // A request nothing is waiting for any more (it never went out) is a
    // failure too, not a spinner.
    _ = main.beginBunkerConnectForTest([_]u8{0x5D} ** 32, &id_buf);
    main.clearPendingForTest();
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
}

test "pasting a bunker link waits for the signer instead of signing in" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    // A link that is not one. Nothing starts, and the sheet says it cannot read it.
    model.login_buffer.set("bunker://not-a-key");
    main.update(&model, .login_submit, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expectEqualStrings("Couldn't read that bunker link.", model.login_status());

    // A well-formed link to a relay nobody is listening on. The press connects,
    // and that is all it does: no account, no feed, the sheet still up.
    const link = "bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=abc";
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(model.is_guest());
    try testing.expect(model.joining and model.bunker_mode);
    try testing.expectEqualStrings("Connecting to your signer…", model.login_status());

    // The signer answers the request that went out, and then the reader is in.
    var id_buf: [24]u8 = undefined;
    const id = main.pendingConnectIdForTest(&id_buf) orelse return error.NoConnectRequest;
    main.answerBunkerConnectForTest(id);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!model.is_guest());
    try testing.expect(!model.joining and !model.bunker_mode);
}

test "a bunker pairing that is taken back leaves its secret nowhere" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;
    const link = "bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=pairing-secret-one";

    // The signer refuses, or the relay never carried the request.
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    try testing.expect(main.remoteSecretHeldForTest("pairing-secret-one"));
    var id_buf: [24]u8 = undefined;
    const id = main.pendingConnectIdForTest(&id_buf) orelse return error.NoConnectRequest;
    try testing.expect(main.failPendingForTest(id));
    main.scanPendingRemoteForTest(&model, &fx);
    main.driveBunkerConnectForTest(&model);
    try testing.expect(!main.bunkerConnecting());
    // A length of zero is not the same as gone: the bytes are wiped, and the
    // client key with them.
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-one"));

    // And the same when the reader backs out while it waits.
    model.login_buffer.set(link);
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.remoteSecretHeldForTest("pairing-secret-one"));
    main.update(&model, .close_bunker, &fx);
    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-one"));
}

test "a key adopted while a bunker link waits takes the link down with it" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    main.setIoForTest(testing.io);
    defer main.setIoForTest(null);
    var model = main.initialModel();
    model.stage = .ready;
    model.joining = true;
    model.bunker_mode = true;
    var fx: main.EffectsForTest = undefined;

    model.login_buffer.set("bunker://" ++ "ab" ** 32 ++ "?relay=wss://127.0.0.1:1&secret=pairing-secret-two");
    main.update(&model, .login_submit, &fx);
    try testing.expect(main.bunkerConnecting());
    const generation = main.remoteGenerationForTest();

    // An import finished in Notary meanwhile, and the keyholder's key was
    // adopted. That account is the reader's now.
    main.setIdentityForTest([_]u8{0x6A} ** 32);
    main.driveBunkerConnectForTest(&model);

    try testing.expect(!main.bunkerConnecting());
    try testing.expect(!model.is_guest());
    try testing.expectEqualStrings("helper", main.signerKindNameForTest());
    // The pairing went with it: its listener was told to stop, nothing waits
    // on its answer, and its secret is gone.
    try testing.expect(main.remoteGenerationForTest() != generation);
    var id_buf: [24]u8 = undefined;
    try testing.expect(main.pendingConnectIdForTest(&id_buf) == null);
    try testing.expect(!main.remoteSecretHeldForTest("pairing-secret-two"));
}

test "a connect answered by the signer is never read as one that never went out" {
    defer main.resetBunkerConnectForTest();
    defer main.clearIdentityForTest();
    // The listener takes an answer on its own thread while the tick asks
    // whether the request is still out. Between "the slot is gone" and "the
    // connection is up" there must be no moment the tick can see, or a signer
    // that said yes is reported as silent and the reader is turned away.
    const Listener = struct {
        go: std.atomic.Value(u32) = .init(0),
        done: std.atomic.Value(u32) = .init(0),
        id: []const u8 = "",
        fn run(self: *@This(), rounds: u32) void {
            var round: u32 = 1;
            while (round <= rounds) : (round += 1) {
                while (self.go.load(.acquire) != round) std.atomic.spinLoopHint();
                main.answerBunkerConnectForTest(self.id);
                self.done.store(round, .release);
            }
        }
    };
    const rounds: u32 = 20_000;
    var listener: Listener = .{};
    var id_buf: [24]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, Listener.run, .{ &listener, rounds });
    var misread: u32 = 0;
    var round: u32 = 1;
    while (round <= rounds) : (round += 1) {
        listener.id = main.beginBunkerConnectForTest([_]u8{0x5E} ** 32, &id_buf);
        listener.go.store(round, .release);
        while (listener.done.load(.acquire) != round) {
            if (main.connectWentQuietForTest()) misread += 1;
        }
    }
    thread.join();
    try testing.expectEqual(@as(u32, 0), misread);
}

test "a re-issued feed that a relay refuses for want of AUTH is asked again once the relay says yes" {
    // The feed is closed and asked again under a new id each time its question
    // changes (`plaza-feed-<generation>`), and sign-in is one of those times, so
    // the feed a relay refuses for want of AUTH is almost never the bare
    // `plaza-feed` any more. Matched by name alone, the refusal was not recorded
    // as owed, nothing was re-sent after the relay accepted the reply, and that
    // relay sent the reader no feed for the rest of the connection.
    const idx = try authFixture();
    defer authCleanup();
    const me = main.activePubkeyForTest().?;
    var rec = AuthRecorder{};
    var fx: main.EffectsForTest = undefined;

    try testing.expect(main.setAuthChoiceForTest(me, auth_test_url, .allow));
    main.authSlotResetForTest(idx);
    var sess = main.AuthSessionForTest{ .index = idx };
    _ = main.authReactForTest(&sess, auth_test_url, authMsg("after-sign-in"), 0);
    const refused = main.authReactForTest(&sess, auth_test_url, closedMsg("plaza-feed-7", "auth-required: log in"), 1);
    try testing.expect(refused.handled);
    try testing.expectEqualStrings("want_sign", main.authPhaseNameForTest(idx));
    main.driveRelayAuthForTest(&fx);
    _ = main.authPollForTest(&sess, auth_test_url, &rec, 2);
    try testing.expectEqual(@as(usize, 1), rec.sent);
    const ok = main.authReactForTest(&sess, auth_test_url, .{ .ok = .{ .event_id = rec.id, .accepted = true, .message = "" } }, 3);
    try testing.expect(ok.resend.feed);
    try testing.expect(!ok.resend.inbox);
    try testing.expect(!ok.resend.engagement);
}

test {
    _ = tests_addresses;
    _ = tests_bookmarks;
    _ = tests_compose;
    _ = tests_drafts;
    _ = tests_engagement;
    _ = tests_feed_media;
    _ = tests_feed_state;
    _ = tests_follows;
    _ = tests_hiding;
    _ = tests_image_cache;
    _ = tests_image_pool;
    _ = tests_inbox;
    _ = tests_ingest;
    _ = tests_keyholder;
    _ = tests_link_preview;
    _ = tests_links;
    _ = tests_login;
    _ = tests_media_servers;
    _ = tests_mutes;
    _ = tests_navigation;
    _ = tests_note_build;
    _ = tests_outbox;
    _ = tests_own_lists;
    _ = tests_own_profile;
    _ = tests_people_search;
    _ = tests_places;
    _ = tests_prefs;
}

// re-exports: tests/feed_media.zig
pub const quote_picture_url = tests_feed_media.quote_picture_url;

// re-exports: tests/inbox.zig
pub const inboxEventBy = tests_inbox.inboxEventBy;

// re-exports: tests/own_lists.zig
pub const ownRelayListIsThePool = tests_own_lists.ownRelayListIsThePool;

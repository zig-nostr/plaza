//! Tests of login.zig. Reading what a reader pastes: sign-in input, the search box, and NIP-05 addresses.

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

test "login text is classified by prefix" {
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("nsec1abcdef"));
    try testing.expectEqual(main.LoginTarget.bunker, main.classifyLogin("bunker://pubkey?relay=wss://r"));
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("  nsec1withspace  "));
    // An npub (read-only) is not a sign-in path yet, nor is arbitrary text.
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("npub1abcdef"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("hello"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin(""));
}
test "a pasted secret key is refused and pointed at Notary" {
    // A client that accepts an nsec is a client holding the one thing that
    // cannot be replaced if it leaks. So the field still RECOGNISES one, which
    // is the point: recognising it is how the reader gets told where it goes
    // instead of "that does not look like a signer".
    try testing.expectEqual(main.LoginTarget.nsec, main.classifyLogin("nsec1abcdef"));
    try testing.expectEqual(main.LoginTarget.bunker, main.classifyLogin("bunker://abc?relay=wss://r"));
    try testing.expectEqual(main.LoginTarget.invalid, main.classifyLogin("npub1abcdef"));
}

// --------------------------------------------------------- opening an address
//
// Plaza could put an address on the clipboard long before it could take one
// back, so a note shared out of here opened in every other client and not in
// this one. These cover the door (`parseAddress` and the field around it) and
// the relay hints the address carries, which were decoded and dropped.

test "every address form Plaza accepts opens what it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]u8{0x11} ** 32;
    const pk = [_]u8{0x22} ** 32;

    // note1: an id and nothing else.
    switch (main.parseAddress(arena, try nostr.nip19.encodeNote(arena, id))) {
        .ok => |hit| {
            try testing.expectEqualSlices(u8, &id, &hit.target.event);
            try testing.expectEqual(@as(usize, 0), hit.hints.len);
        },
        else => return error.NoteNotRead,
    }

    // nevent1: the same id, plus the relays its author named.
    const relays = [_][]const u8{ "wss://one.example", "wss://two.example" };
    switch (main.parseAddress(arena, try nostr.nip19.encodeNevent(arena, id, &relays, pk, 1))) {
        .ok => |hit| {
            try testing.expectEqualSlices(u8, &id, &hit.target.event);
            try testing.expectEqual(@as(usize, 2), hit.hints.len);
            try testing.expectEqualStrings("wss://one.example", hit.hints[0]);
        },
        else => return error.NeventNotRead,
    }

    // npub1 and nprofile1 both land on the person, and only one carries relays.
    switch (main.parseAddress(arena, try nostr.nip19.encodeNpub(arena, pk))) {
        .ok => |hit| try testing.expectEqualSlices(u8, &pk, &hit.target.person),
        else => return error.NpubNotRead,
    }
    switch (main.parseAddress(arena, try nostr.nip19.encodeNprofile(arena, pk, &relays))) {
        .ok => |hit| {
            try testing.expectEqualSlices(u8, &pk, &hit.target.person);
            try testing.expectEqual(@as(usize, 2), hit.hints.len);
        },
        else => return error.NprofileNotRead,
    }

    // naddr1 for a place: the pubkey and the identifier both survive, because
    // the place fetch needs both to build its `d` filter.
    switch (main.parseAddress(arena, try nostr.nip19.encodeNaddr(arena, "the-room", pk, main.place_kind_for_test, &relays))) {
        .ok => |hit| {
            try testing.expectEqualSlices(u8, &pk, &hit.target.place.pubkey);
            try testing.expectEqualStrings("the-room", hit.target.place.identifier);
        },
        else => return error.NaddrNotRead,
    }
}

test "an address arrives with whitespace, a nostr prefix or a whole URL around it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id = [_]u8{0x33} ** 32;
    const note1 = try nostr.nip19.encodeNote(arena, id);

    // All three of these are what a real paste looks like, and none of them is
    // a typo: a copy carries whitespace, a NIP-21 link carries `nostr:`, and a
    // link out of a web viewer is a whole URL ending in the address.
    const forms = [_][]const u8{
        try std.fmt.allocPrint(arena, "  {s}\n", .{note1}),
        try std.fmt.allocPrint(arena, "nostr:{s}", .{note1}),
        try std.fmt.allocPrint(arena, "https://njump.me/{s}", .{note1}),
        try std.fmt.allocPrint(arena, " nostr:{s} ", .{note1}),
    };
    for (forms) |form| {
        switch (main.parseAddress(arena, form)) {
            .ok => |hit| try testing.expectEqualSlices(u8, &id, &hit.target.event),
            else => {
                std.debug.print("\n  did not read: \"{s}\"\n", .{form});
                return error.FormNotRead;
            },
        }
    }
}

test "an address for a kind Plaza cannot show is not called unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A perfectly good naddr naming a live activity, which Plaza has no screen
    // for. Saying "that is not an address" here sends somebody looking for a typo
    // that is not there.
    const other = try nostr.nip19.encodeNaddr(arena, "a-stream", [_]u8{0x44} ** 32, 30311, &.{});
    try testing.expectEqual(main.AddressParse.wrong_kind, main.parseAddress(arena, other));

    // And the things that really are unreadable.
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, ""));
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, "   "));
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, "hello"));
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, "https://example.com/"));
    // Right prefix, wrong bytes: to a reader this is the same thing as garbage.
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, "note1notactuallybech32"));
    // A secret key is never a destination.
    try testing.expectEqual(main.AddressParse.unreadable, main.parseAddress(arena, "nsec1abcdef"));
}
test "an article address is read, and so is its draft" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pk = [_]u8{0x45} ** 32;
    const relays = [_][]const u8{ "wss://one.example.com", "wss://two.example.com" };
    const published = try nostr.nip19.encodeNaddr(arena, "a-long-read", pk, 30023, &relays);
    switch (main.parseAddress(arena, published)) {
        .ok => |hit| {
            try testing.expectEqual(@as(u16, 30023), hit.target.article.kind);
            try testing.expectEqualSlices(u8, &pk, &hit.target.article.pubkey);
            try testing.expectEqualStrings("a-long-read", hit.target.article.identifier);
            try testing.expectEqual(@as(usize, 2), hit.hints.len);
        },
        else => return error.ArticleAddressNotRead,
    }
    // Pasted the way a link out of a web viewer arrives.
    const url = try std.fmt.allocPrint(arena, "https://njump.me/{s}", .{published});
    switch (main.parseAddress(arena, url)) {
        .ok => |hit| try testing.expectEqualStrings("a-long-read", hit.target.article.identifier),
        else => return error.ArticleUrlNotRead,
    }
    const draft = try nostr.nip19.encodeNaddr(arena, "a-long-read", pk, 30024, &.{});
    switch (main.parseAddress(arena, draft)) {
        .ok => |hit| try testing.expectEqual(@as(u16, 30024), hit.target.article.kind),
        else => return error.DraftAddressNotRead,
    }
    // An identifier too long to hold is refused, never cut: a cut identifier
    // names a different event.
    const long = "x" ** 200;
    const too_long = try nostr.nip19.encodeNaddr(arena, long, pk, 30023, &.{});
    try testing.expectEqual(main.AddressParse.wrong_kind, main.parseAddress(arena, too_long));
}
test "the field knows an address, a NIP-05 name and a name apart" {
    try testing.expectEqual(main.SearchInput.blank, main.classifySearch("  \n"));
    try testing.expectEqual(main.SearchInput.term, main.classifySearch("alice"));
    try testing.expectEqual(main.SearchInput.term, main.classifySearch("@alice"));
    try testing.expectEqual(main.SearchInput.term, main.classifySearch("alice smith"));

    // Anything that starts like an address is one, decoded or not: half a paste
    // is a typo to be told about, never a name to put to three relays.
    for ([_][]const u8{ "npub1", "npub1abc", "nprofile1xyz", "note1q", "nevent1q", "naddr1q", "nostr:npub1abc", "https://njump.me/npub1abc" }) |s| {
        try testing.expectEqual(main.SearchInput.address, main.classifySearch(s));
    }

    try testing.expectEqual(main.SearchInput.nip05, main.classifySearch("alice@example.com"));
    try testing.expectEqual(main.SearchInput.nip05, main.classifySearch(" _@example.com "));
    // Not addresses: no dot in the domain, an IP literal, a port, two `@`.
    for ([_][]const u8{ "alice@example", "alice@10.0.0.1", "alice@example.com:8080", "a@b@example.com", "alice@" }) |s| {
        try testing.expectEqual(main.SearchInput.term, main.classifySearch(s));
    }
    const parts = main.nip05Address("Alice@Example.COM").?;
    try testing.expectEqualStrings("alice", parts.name());
    try testing.expectEqualStrings("example.com", parts.domain());
}

test "a well-known document names the person and the relays they use" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hex = "ab" ** 32;
    const body = "{\"names\":{\"alice\":\"" ++ hex ++ "\",\"short\":\"abcd\"},\"relays\":{\"" ++ hex ++
        "\":[\"wss://relay.example.com\",\"ws://insecure.example.com\",\"wss://bad host\"]}}";
    const hit = main.nip05Resolve(arena, "alice", body).?;
    try testing.expectEqualSlices(u8, &([_]u8{0xab} ** 32), &hit.pubkey);
    // Only a relay Plaza would dial anyway.
    try testing.expectEqual(@as(usize, 1), hit.relays.len);
    try testing.expectEqualStrings("wss://relay.example.com", hit.relays[0]);

    try testing.expect(main.nip05Resolve(arena, "bob", body) == null);
    try testing.expect(main.nip05Resolve(arena, "short", body) == null);
    try testing.expect(main.nip05Resolve(arena, "alice", "not json") == null);
    try testing.expect(main.nip05Resolve(arena, "alice", "{\"names\":[]}") == null);
}

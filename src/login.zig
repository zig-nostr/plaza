//! Reading what a reader pastes: sign-in input, the search box, and NIP-05 addresses.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const search = @import("search.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Address = main.Address;
const isSafeRelayUrl = main.isSafeRelayUrl;
const place_kind = main.place_kind;
const validNip05Domain = main.validNip05Domain;
const validNip05Name = main.validNip05Name;

// A synchronous error from the unified login field (nsec / bunker), shown under
// it. `.none` while idle or when the async bunker path is in charge (its state
// comes from `g_remote_status`). See `LoginError` and `Model.login_status`.
pub const LoginError = enum(u8) { none = 0, format = 1, bad_key = 2, key_goes_to_notary = 3, signer_silent = 4 };
pub var g_login_error = std.atomic.Value(u8).init(0);

/// What the pasted login text is: a signer to connect, a secret key that
/// belongs somewhere else, or neither.
pub const LoginTarget = enum { nsec, bunker, invalid };
/// What a pasted address names, once decoded.
pub const AddressTarget = union(enum) {
    event: [32]u8,
    person: [32]u8,
    /// `identifier` points into the arena the parse was given, so a caller that
    /// outlives the arena copies it.
    place: struct { pubkey: [32]u8, identifier: []const u8 },
    /// A long-form article (kind 30023) or its draft (30024). Opened by
    /// coordinate: the newest copy, since the author may have edited it.
    article: struct { kind: u16, pubkey: [32]u8, identifier: []const u8 },
};

/// The outcome of reading a pasted address.
pub const AddressParse = union(enum) {
    ok: struct {
        target: AddressTarget,
        /// The relays the address itself named, in the arena. Empty for the
        /// forms that carry none (`note1`, `npub1`) and for one that named none.
        hints: []const []const u8 = &.{},
    },
    /// Decoded, and names a kind there is no screen for.
    wrong_kind,
    /// Not an address, or an address that does not decode.
    unreadable,
};

/// What is left of a pasted string once the three routine wrappers are off it:
/// surrounding whitespace, a leading `nostr:`, and everything up to the last `/`.
fn addressCandidate(raw: []const u8) []const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "nostr:")) text = text["nostr:".len..];
    if (std.mem.lastIndexOfScalar(u8, text, '/')) |slash| text = text[slash + 1 ..];
    return text;
}

/// Reads a pasted address and says what it names.
///
/// Everything it hands back lives in `arena`, including the relay hints and a
/// place's identifier, so a caller that outlives the arena copies what it keeps.
///
/// Three things are stripped before the prefix is looked at, because all three
/// arrive routinely on a paste and none of them is a typo. Surrounding
/// whitespace. A leading `nostr:`, which is what a NIP-21 link is. And
/// everything up to the last `/`, which is what turns a web viewer's URL into
/// the address it is showing: that is how a link out of another client arrives,
/// and it is the case this whole field exists for.
pub fn parseAddress(arena: std.mem.Allocator, raw: []const u8) AddressParse {
    const text = addressCandidate(raw);
    if (text.len == 0) return .unreadable;

    if (std.mem.startsWith(u8, text, "note1")) {
        const id = nostr.nip19.decodeNote(arena, text) catch return .unreadable;
        return .{ .ok = .{ .target = .{ .event = id } } };
    }
    if (std.mem.startsWith(u8, text, "nevent1")) {
        const ptr = nostr.nip19.decodeNevent(arena, text) catch return .unreadable;
        return .{ .ok = .{ .target = .{ .event = ptr.id }, .hints = ptr.relays } };
    }
    if (std.mem.startsWith(u8, text, "npub1")) {
        const pk = nostr.nip19.decodeNpub(arena, text) catch return .unreadable;
        return .{ .ok = .{ .target = .{ .person = pk } } };
    }
    if (std.mem.startsWith(u8, text, "nprofile1")) {
        const pp = nostr.nip19.decodeNprofile(arena, text) catch return .unreadable;
        return .{ .ok = .{ .target = .{ .person = pp.pubkey }, .hints = pp.relays } };
    }
    if (std.mem.startsWith(u8, text, "naddr1")) {
        const ptr = nostr.nip19.decodeNaddr(arena, text) catch return .unreadable;
        // A place and an article are the addressable kinds Plaza has a screen
        // for. Anything else decoded fine and names something this app cannot
        // show, which is a different answer from "that is not an address".
        if (ptr.kind == place_kind) return .{ .ok = .{
            .target = .{ .place = .{ .pubkey = ptr.pubkey, .identifier = ptr.identifier } },
            .hints = ptr.relays,
        } };
        if (Address.make(ptr.kind, ptr.pubkey, ptr.identifier) != null) return .{ .ok = .{
            .target = .{ .article = .{ .kind = @intCast(ptr.kind), .pubkey = ptr.pubkey, .identifier = ptr.identifier } },
            .hints = ptr.relays,
        } };
        return .wrong_kind;
    }
    return .unreadable;
}

/// What the search field holds, which decides what pressing Enter does.
pub const SearchInput = enum {
    /// Nothing to act on.
    blank,
    /// A NIP-19 address, or something that starts like one. It is read by
    /// `parseAddress` and never put to a relay as a name: a half-pasted `npub1`
    /// is a typo to be told about, not somebody to search for.
    address,
    /// `name@domain`. The domain is the authority on who that is, so it is asked
    /// rather than searched for.
    nip05,
    /// A secret key (`nsec1`, `ncryptsec1`), a signer link (`bunker://`,
    /// `nostrconnect://`, which carry a secret of their own), or 64 hex digits,
    /// which may be a secret key written out raw. None of these is a name, and
    /// the cost of treating one as a name is putting it to three strangers, so
    /// nothing is done with it at all: not matched, not looked up, not sent.
    key,
    /// Anything else, which is a name.
    term,
};

/// Decides which of the field's jobs a string is for.
///
/// One field takes all of them, as Jumble's search bar does (an `npub1`,
/// `nprofile1` or other NIP-19 string becomes the profile or note itself rather
/// than a query: SearchBar/index.tsx:40-46 and :150-153) and Amethyst's does
/// (CacheSearch.findUsersStartingWith decodes the term as a key before it
/// searches, CacheSearch.kt:72-79). Two fields side by side would put the
/// decision on the reader, and the strings are not ambiguous: a bech32 prefix and
/// an `@` between two names are not how anybody spells a person.
pub fn classifySearch(raw: []const u8) SearchInput {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .blank;
    // Checked anywhere in the string and in either case, before anything else:
    // `my key is NSEC1...` is still a key, and a name never contains one.
    for ([_][]const u8{ "nsec1", "ncryptsec1", "bunker://", "nostrconnect://" }) |marker| {
        if (search.indexOfFold(trimmed, marker) != null) return .key;
    }
    if (trimmed.len == 64 and isHexString(trimmed)) return .key;
    const text = addressCandidate(raw);
    for ([_][]const u8{ "npub1", "nprofile1", "note1", "nevent1", "naddr1" }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return .address;
    }
    // A link that does not end in a Nostr address is still a link, not a name.
    // It goes to the address reader, which says it cannot read it, rather than
    // to the search relays with whatever its path and query carry.
    if (std.mem.indexOf(u8, trimmed, "://") != null) return .address;
    if (nip05Address(raw) != null) return .nip05;
    return .term;
}

fn isHexString(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A NIP-05 address split and lowercased, in buffers of its own.
pub const Nip05Address = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    domain_buf: [253]u8 = undefined,
    domain_len: u8 = 0,

    pub fn name(self: *const Nip05Address) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn domain(self: *const Nip05Address) []const u8 {
        return self.domain_buf[0..self.domain_len];
    }
};

/// `name@domain` as NIP-05 spells it, or null. The local part and the domain go
/// through the checks the verification fetch already uses, and a port or an IP
/// literal is refused the way Amethyst's `Nip05Id.parse` refuses them
/// (Nip05Id.kt:59-70): an address somebody types is a hostname, and a lookup
/// that Plaza sends from the reader's own address should not be steerable at one
/// machine by a string that merely looks like a name.
pub fn nip05Address(raw: []const u8) ?Nip05Address {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return null;
    if (std.mem.indexOfScalarPos(u8, text, at + 1, '@') != null) return null;
    const name = text[0..at];
    const domain = text[at + 1 ..];
    if (!validNip05Name(name) or !validNip05Domain(domain)) return null;
    if (std.mem.indexOfScalar(u8, domain, ':') != null) return null;
    const tld = domain[std.mem.lastIndexOfScalar(u8, domain, '.').? + 1 ..];
    if (tld.len == 0) return null;
    var all_digits = true;
    for (tld) |c| {
        if (!std.ascii.isDigit(c)) all_digits = false;
    }
    if (all_digits) return null;
    var out = Nip05Address{};
    out.name_len = @intCast(name.len);
    out.domain_len = @intCast(domain.len);
    _ = std.ascii.lowerString(out.name_buf[0..name.len], name);
    _ = std.ascii.lowerString(out.domain_buf[0..domain.len], domain);
    return out;
}

/// The well-known document for `addr`, which is the same URL the verification
/// fetch builds for a profile's own identifier.
pub fn nip05LookupUrl(buf: []u8, addr: *const Nip05Address) ?[]const u8 {
    return std.fmt.bufPrint(buf, "https://{s}/.well-known/nostr.json?name={s}", .{ addr.domain(), addr.name() }) catch null;
}

/// Who a well-known document says `name` is, and the relays it says that person
/// uses (NIP-05's optional `relays` map), which `arena` owns. Null when the
/// document does not list the name or lists something that is not a key.
pub fn nip05Resolve(arena: std.mem.Allocator, name: []const u8, body: []const u8) ?struct { pubkey: [32]u8, relays: []const []const u8 } {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (root != .object) return null;
    const names = root.object.get("names") orelse return null;
    if (names != .object) return null;
    const entry = names.object.get(name) orelse return null;
    if (entry != .string or entry.string.len != 64) return null;
    var pubkey: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pubkey, entry.string) catch return null;

    var hints: std.ArrayList([]const u8) = .empty;
    if (root.object.get("relays")) |map| {
        if (map == .object) {
            if (map.object.get(entry.string)) |list| {
                if (list == .array) {
                    for (list.array.items) |item| {
                        if (item != .string or !isSafeRelayUrl(item.string)) continue;
                        if (hints.items.len == 3) break;
                        hints.append(arena, item.string) catch break;
                    }
                }
            }
        }
    }
    return .{ .pubkey = pubkey, .relays = hints.items };
}

/// Classifies pasted login text by its prefix. Pure, so it is unit-tested.
///
/// `nsec` is still recognised, and that is the point of keeping it. Plaza no
/// longer takes a secret key ANYWHERE: it does not hold one, so a field that
/// swallowed one would be asking for the most dangerous thing a person owns and
/// then handing it straight on. Recognising it is how the reader gets told
/// where it goes instead of "that does not look like a signer".
pub fn classifyLogin(text: []const u8) LoginTarget {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "nsec1")) return .nsec;
    if (std.mem.startsWith(u8, t, "bunker://")) return .bunker;
    return .invalid;
}

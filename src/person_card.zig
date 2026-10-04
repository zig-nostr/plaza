//! The person card: what the profile screen reads about one author.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const profile_cache = @import("profile_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const OwnProfile = main.OwnProfile;
const abbreviateNpub = main.abbreviateNpub;
const activePubkey = main.activePubkey;
const avatarTint = main.avatarTint;
const contact_list_kind = main.contact_list_kind;
const countPeople = main.countPeople;
const dupeTags = main.dupeTags;
const freeOwnProfile = main.freeOwnProfile;
const hexLower = main.hexLower;
const isPublicMediaUrl = main.isPublicMediaUrl;
const lookupProfile = main.lookupProfile;
const renderContent = main.renderContent;
const stringField = main.stringField;
const thread_depth_max = main.thread_depth_max;
const utf8SafeLen = main.utf8SafeLen;

// ----------------------------------------------------------------- a person
//
// Everything the profile screen needs about somebody, read from the RAW kind:0
// rather than the name-and-face cache. The cache models four fields and drops
// the rest, which is right for a feed row and useless here: a profile is mostly
// the fields it does not keep.
//
// Cached per pubkey for the life of a level, because a virtual list rebuilds its
// visible rows every frame and a JSON parse per frame is not free.

const PersonCard = struct {
    used: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    /// The kind:0 these fields came from, so an unchanged event is parsed once.
    meta_id: [32]u8 = [_]u8{0} ** 32,
    /// The store's event count when this card was last filled. The store only
    /// grows, so an unchanged count means nothing this card reads can have
    /// changed either.
    stamp: usize = std.math.maxInt(usize),
    about_buf: [512]u8 = [_]u8{0} ** 512,
    about_len: u16 = 0,
    /// The about text with its NIP-27 mentions rewritten as `@name`, which is
    /// what the page shows. Kept beside the raw bytes rather than rewritten at
    /// draw time because the card's height is computed from the length of the
    /// string, so measuring the raw one and drawing the rewritten one would
    /// reserve space for a line that is not there.
    about_shown_buf: [512]u8 = [_]u8{0} ** 512,
    about_shown_len: u16 = 0,
    /// The names generation `about_shown_buf` was written under. A mention
    /// resolves to a short npub until that person's kind:0 arrives, and then it
    /// has a name, so this is rewritten when the cache learns one.
    about_shown_gen: u64 = std.math.maxInt(u64),
    website_buf: [128]u8 = [_]u8{0} ** 128,
    website_len: u8 = 0,
    lud16_buf: [128]u8 = [_]u8{0} ** 128,
    lud16_len: u8 = 0,
    banner_buf: [256]u8 = [_]u8{0} ** 256,
    banner_len: u16 = 0,
    /// How many their own contact list names, or null when none has arrived.
    following: ?usize = null,
    /// Whether their contact list names the reader.
    follows_me: bool = false,
};

/// One card per stack level, plus the one being looked at.
var g_person_cards = [_]PersonCard{.{}} ** (thread_depth_max + 2);

/// The card for `pubkey`, filled from the store when it is stale.
fn personCard(pubkey: [32]u8) *const PersonCard {
    var slot: ?*PersonCard = null;
    for (&g_person_cards) |*c| {
        if (c.used and std.mem.eql(u8, &c.pubkey, &pubkey)) {
            slot = c;
            break;
        }
    }
    if (slot == null) {
        // Oldest wins the seat: the levels below are what a reader walks back
        // through, so evicting the least recently looked at is wrong here.
        for (&g_person_cards) |*c| {
            if (!c.used) {
                slot = c;
                break;
            }
        }
        if (slot == null) slot = &g_person_cards[0];
        slot.?.* = .{ .used = true, .pubkey = pubkey };
    }
    const card = slot.?;
    // Only when the store has actually moved. This is called several times per
    // frame (once per field the header shows) and each refresh ran two LMDB
    // queries and deep-copied the subject's whole contact list, which for
    // somebody with two thousand follows is a few hundred allocations per field
    // per frame.
    const stamp = if (main.g_store) |store| store.eventCount() catch 0 else 0;
    if (card.stamp != stamp) {
        card.stamp = stamp;
        refreshPersonCard(card);
    }
    return card;
}

fn refreshPersonCard(card: *PersonCard) void {
    const gpa = std.heap.page_allocator;
    if (readRecord(gpa, card.pubkey, 0)) |own| {
        defer freeOwnProfile(gpa, own);
        if (!std.mem.eql(u8, &card.meta_id, &own.id)) {
            card.meta_id = own.id;
            parsePersonMetadata(card, own.json);
        }
    }
    // Their contact list: how many they follow, and whether the reader is in it.
    if (readRecord(gpa, card.pubkey, contact_list_kind)) |own| {
        defer freeOwnProfile(gpa, own);
        var mine = false;
        const me = activePubkey();
        for (own.tags) |tag| {
            if (tag.len < 2 or !std.mem.eql(u8, tag[0], "p")) continue;
            if (tag[1].len != 64) continue;
            if (me) |pk| {
                var hex: [64]u8 = undefined;
                hexLower(&hex, pk);
                if (std.ascii.eqlIgnoreCase(tag[1], &hex)) mine = true;
            }
        }
        // DISTINCT people. Some clients emit the same person twice, and this
        // file already has one function that knows that; counting raw tags here
        // would print a follow count nobody else shows.
        card.following = countPeople(own.tags);
        card.follows_me = mine;
    } else {
        card.following = null;
        card.follows_me = false;
    }

    // A bio is written the same way a note is, so it carries the same
    // `nostr:npub...` references, and printing one raw drops sixty-three
    // characters of base32 into the middle of a sentence about a person. The
    // feed has drawn these as `@name` since NIP-27 landed; this is the same pass
    // over the same cache.
    if (card.about_shown_gen != profile_cache.g_names_generation) {
        card.about_shown_gen = profile_cache.g_names_generation;
        card.about_shown_len = @intCast(renderContent(
            &card.about_shown_buf,
            card.about_buf[0..card.about_len],
            "",
        ));
    }
}

fn parsePersonMetadata(card: *PersonCard, json: []const u8) void {
    card.about_len = 0;
    card.website_len = 0;
    card.lud16_len = 0;
    card.banner_len = 0;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch return;
    if (root != .object) return;
    const obj = root.object;
    if (stringField(obj, "about")) |v| {
        const n = utf8SafeLen(v, card.about_buf.len);
        @memcpy(card.about_buf[0..n], v[0..n]);
        card.about_len = @intCast(n);
    }
    if (stringField(obj, "website")) |v| {
        if (v.len <= card.website_buf.len) {
            @memcpy(card.website_buf[0..v.len], v);
            card.website_len = @intCast(v.len);
        }
    }
    if (stringField(obj, "lud16")) |v| {
        if (v.len <= card.lud16_buf.len) {
            @memcpy(card.lud16_buf[0..v.len], v);
            card.lud16_len = @intCast(v.len);
        }
    }
    if (stringField(obj, "banner")) |v| {
        // https only, and only what fits: a banner is a picture fetched
        // unattended from a host the subject named, so it goes through the same
        // gate every other unattended fetch does.
        if (v.len <= card.banner_buf.len and std.mem.startsWith(u8, v, "https://") and isPublicMediaUrl(v)) {
            @memcpy(card.banner_buf[0..v.len], v);
            card.banner_len = @intCast(v.len);
        }
    }
}

pub fn personBanner(pubkey: [32]u8) []const u8 {
    const c = personCard(pubkey);
    return c.banner_buf[0..c.banner_len];
}

/// Any pubkey's newest event of `kind`, raw. `ownRecordJson` is this for the
/// reader themselves; a profile needs it for somebody else.
fn readRecord(gpa: std.mem.Allocator, pubkey: [32]u8, kind: u16) ?OwnProfile {
    const store = main.g_store orelse return null;
    const kinds = [_]u16{kind};
    const authors = [_][32]u8{pubkey};
    var result = store.query(gpa, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return null;
    defer result.deinit();
    if (result.events.len == 0) return null;
    const copy = gpa.dupe(u8, result.events[0].content) catch return null;
    // Whole or not at all. A partial base is what turns a splice into a delete.
    const tags = dupeTags(gpa, result.events[0].tags) orelse return null;
    return .{ .json = copy, .tags = tags, .created_at = result.events[0].created_at, .id = result.events[0].id };
}

pub fn personAbout(pubkey: [32]u8) []const u8 {
    const c = personCard(pubkey);
    // The rewritten one, so what the page measures and what it draws are the
    // same string.
    return c.about_shown_buf[0..c.about_shown_len];
}

pub fn personWebsite(pubkey: [32]u8) []const u8 {
    const c = personCard(pubkey);
    return c.website_buf[0..c.website_len];
}

pub fn personLud16(pubkey: [32]u8) []const u8 {
    const c = personCard(pubkey);
    return c.lud16_buf[0..c.lud16_len];
}

/// How many people they follow, or null when their list has not arrived. Null is
/// not zero, and the screen says so rather than printing a confident 0.
pub fn personFollowingCount(pubkey: [32]u8) ?usize {
    return personCard(pubkey).following;
}

/// Whether their contact list names the reader.
pub fn followsMe(pubkey: [32]u8) bool {
    if (activePubkey() == null) return false;
    return personCard(pubkey).follows_me;
}

/// Their display name, or a short npub until a kind:0 arrives. Never blank: a
/// nameless header reads as a broken screen rather than an unfetched one.
pub fn personName(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |prof| {
        if (prof.name_len > 0) return prof.name();
    }
    return personNpubShort(ui, pubkey);
}

/// Whether this person has a name of their own, as opposed to one this app made
/// up for them out of their key.
///
/// `personName` falls back to the short npub, which is the right thing on a row
/// that must say SOMETHING. On the profile it means the name line and the npub
/// line can end up holding the identical string, which reads as a rendering fault
/// rather than as an identity. The note row has guarded its handle against the
/// same shape since it was written; the profile card never did.
pub fn personIsNamed(pubkey: [32]u8) bool {
    const prof = lookupProfile(pubkey) orelse return false;
    return prof.name_len > 0;
}

pub fn personNpubShort(ui: *AppUi, pubkey: [32]u8) []const u8 {
    return npubShortOf(ui.arena, pubkey);
}

/// The abbreviated npub, allocating. ONE truncation rule, shared with the feed's
/// name line through `abbreviateNpub`.
///
/// There were two. The name line cut at twelve characters and this cut at ten,
/// so the same key rendered as two different strings depending on which line it
/// landed on, and any code comparing them to avoid saying it twice compared
/// unequal and said it twice, in two spellings. That is worse than the
/// duplication it was trying to prevent.
pub fn npubShortOf(arena: std.mem.Allocator, pubkey: [32]u8) []const u8 {
    var buf: [128]u8 = undefined;
    const s = abbreviateNpub(&buf, pubkey);
    return arena.dupe(u8, s) catch "npub…";
}
/// A NIP-05 as an identity line shows it: whole (`someone@example.com`), or the
/// domain alone for the root `_@domain` form, which is what that form means.
/// Empty when it is malformed, so a broken one is shown as nothing rather than
/// as itself.
///
/// One rule, shared by the feed's handle line and the profile page, because two
/// spellings of the same identity on two screens is its own small dishonesty.
pub fn nip05Display(id: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, id, '@') orelse return "";
    const local = id[0..at];
    const domain = id[at + 1 ..];
    if (domain.len == 0) return "";
    return if (std.mem.eql(u8, local, "_")) domain else id;
}

/// Their NIP-05 for the profile page, and ONLY once the well-known lookup has
/// actually mapped it back to this key.
///
/// The page used to draw a bare check next to the name and no address at all, so
/// a verified profile said "verified" without ever saying verified as WHAT. The
/// domain is the half that names who vouched, and the profile page is the one
/// screen a reader opens specifically to decide whether this is the right person.
///
/// Unverified is shown as nothing rather than as plain text. An address the app
/// has not checked, printed under a name, is read as an endorsement by everyone
/// who has ever seen one anywhere else, and that is exactly the impersonation
/// this is supposed to guard against.
pub fn verifiedNip05(pubkey: [32]u8) []const u8 {
    const prof = lookupProfile(pubkey) orelse return "";
    if (prof.nip05_state != .verified) return "";
    return nip05Display(prof.nip05());
}
/// The verified check, drawn only when their NIP-05 actually resolves to them.
pub fn personCheck(ui: *AppUi, pubkey: [32]u8) AppUi.Node {
    const prof = lookupProfile(pubkey) orelse return ui.spacer(0);
    if (prof.nip05_state != .verified) return ui.spacer(0);
    return ui.icon(.{ .width = 14, .height = 14, .style = .{ .foreground = theme.palette.status_success } }, "check");
}

/// Their face at a stated size.
pub fn personAvatar(ui: *AppUi, pubkey: [32]u8, size: f32) AppUi.Node {
    const tint = avatarTint(pubkey);
    const hexdigits = "0123456789abcdef";
    return ui.avatar(.{
        .width = size,
        .height = size,
        .image = if (lookupProfile(pubkey)) |prof| prof.image_id else 0,
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 3 },
    }, ui.fmt("{c}{c}", .{ hexdigits[pubkey[0] >> 4], hexdigits[pubkey[0] & 0x0f] }));
}

pub fn verifiedNip05ForTest(pubkey: [32]u8) []const u8 {
    return verifiedNip05(pubkey);
}

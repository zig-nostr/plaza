//! Profiles: which are wanted, the cache and its index, and NIP-05 verification.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const prefs = @import("prefs.zig");
const view_thread = @import("view_thread.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Download = main.Download;
const Effects = main.Effects;
const Model = main.Model;
const RelayHints = main.RelayHints;
const activePubkey = main.activePubkey;
const askPool = main.askPool;
const buildFeedFilters = main.buildFeedFilters;
const copyBounded = main.copyBounded;
const copyDisplayText = main.copyDisplayText;
const hydrateProfiles = main.hydrateProfiles;
const inbox_cap = main.inbox_cap;
const isPublicRelayUrl = main.isPublicRelayUrl;
const networkAllowed = main.networkAllowed;
const nip05_fetch_key_base = main.nip05_fetch_key_base;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const one_shot_sub_prefix = main.one_shot_sub_prefix;
const place_relay_cap = main.place_relay_cap;
const plazaIngest = main.plazaIngest;
const profile_cap = main.profile_cap;
const quote_hint_dials_per_pass = main.quote_hint_dials_per_pass;
const relayFetchAllowed = main.relayFetchAllowed;
const releaseOneShot = main.releaseOneShot;
const thread_reply_cap = main.thread_reply_cap;
const urlHost = main.urlHost;
const watchOneShot = main.watchOneShot;

// Pubkeys a note mentioned that we have no name for. The pool only subscribes
// to the follow set's metadata, so a mention of anyone else would render as a
// bare npub forever; these are fetched separately, once each, and then resolve
// like any other name.
// Sized to the real ceiling rather than to a guess: a full inbox, a full
// thread, and headroom. The old table held 48 and, once full, SILENTLY DROPPED
// every further request: the loop looked for a slot already asked the maximum
// number of times, found none, and fell off the end having queued nothing. With
// 144 notifications that is what it did all day, which is why a name only ever
// arrived after visiting that person's profile, because visiting asks for one.
//
// No shipping client has an author cap here. NDK merges `authors` with no limit
// at all; Amethyst rebuilds one REQ from every name currently on screen.
pub const wanted_profiles_cap = inbox_cap + thread_reply_cap + 64;
pub const WantedProfile = struct {
    used: bool = false,
    /// When this pubkey was last actually asked for, and how many times running
    /// it has come back with nothing. Together they gate a retry: wait
    /// `2^attempts` seconds, clamped, before asking again.
    ///
    /// There is no strike limit. The old code wrote a pubkey off permanently
    /// after three rounds and incremented the counter BEFORE checking whether
    /// the network was even allowed, so an app launched offline burned all three
    /// inside forty seconds and showed a raw npub for the rest of the process.
    /// welshman's loader is the shape copied here: a timestamp, exponential
    /// backoff, and nothing ever marked dead.
    last_tried: i64 = 0,
    attempts: u8 = 0,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    /// Where an `nprofile1` said this person publishes. Dropped on the floor
    /// before: `parseMentionAt` read `.pubkey` off the pointer and nothing else,
    /// so a mention that named a relay was asked for on the reader's own relays
    /// and nowhere the address pointed.
    hints: RelayHints = .{},
};
/// The longest a repeatedly silent pubkey waits between asks.
const profile_retry_cap_s: i64 = 300;
pub var g_wanted = [_]WantedProfile{.{}} ** wanted_profiles_cap;

/// Whether `w` is due another ask.
fn profileRetryDue(w: *const WantedProfile, now: i64) bool {
    if (w.attempts == 0) return true;
    const shift: u6 = @intCast(@min(w.attempts, 8));
    const wait = @min(@as(i64, 1) << shift, profile_retry_cap_s);
    return now - w.last_tried >= wait;
}

/// Notes that `pubkey` was mentioned but has no known name yet.
pub fn wantProfile(pubkey: [32]u8) void {
    wantProfileHinted(pubkey, &.{});
}

/// Wants someone's metadata, and remembers where an address said they publish.
///
/// The same keep-the-first rule as `wantQuoteHinted`, for the same reason.
pub fn wantProfileHinted(pubkey: [32]u8, hints: []const []const u8) void {
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) return;
    }
    for (&g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) {
            if (w.hints.isEmpty()) w.hints.fill(hints);
            return;
        }
    }
    for (&g_wanted) |*w| {
        if (!w.used) {
            w.* = .{ .used = true, .pubkey = pubkey };
            w.hints.fill(hints);
            return;
        }
    }
    // Genuinely full, which the size above is chosen to make impossible in
    // normal use. Take the slot that has gone longest without an answer rather
    // than dropping the request, because dropping it is what the old 48-slot
    // table did and it is the whole reason names never loaded.
    var oldest: ?*WantedProfile = null;
    for (&g_wanted) |*w| {
        if (oldest == null or w.last_tried < oldest.?.last_tried) oldest = w;
    }
    if (oldest) |w| {
        w.* = .{ .used = true, .pubkey = pubkey };
        w.hints.fill(hints);
    }
}

/// Whether `pubkey`'s profile is still being fetched: no profile in hand yet, and
/// the wanted-set is still trying (attempts left). This distinguishes "loading"
/// (show a skeleton) from "gave up, or never on the relays" (show nothing), so a
/// handle placeholder does not linger forever for an author with no metadata.
pub fn profileLoading(pubkey: [32]u8) bool {
    if (lookupProfile(pubkey) != null) return false;
    for (&g_wanted) |*w| {
        // Still being asked for, because nothing is ever written off now.
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return true;
    }
    return false;
}

pub var g_profile_round: u64 = 0;
/// Quote re-ask rounds. Quotes still use a round counter; profiles moved to a
/// per-pubkey backoff, and the two shared this number only by accident.
pub const quote_rearm_rounds: u64 = 10;

/// Asks the relays for the metadata of everyone mentioned but still unnamed, in
/// one batch on a throwaway connection.
pub fn requestWantedProfiles() void {
    const now = nowSeconds();
    var batch: [wanted_profiles_cap][32]u8 = undefined;
    var n: usize = 0;
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        // Resolved: free the slot so later mentions can use it.
        if (lookupProfile(w.pubkey)) |p| {
            if (p.name_len > 0) {
                w.* = .{};
                continue;
            }
        }
        if (!profileRetryDue(w, now)) continue;
        batch[n] = w.pubkey;
        n += 1;
        if (n == batch.len) break;
    }
    if (n == 0) return;

    // THE DISK FIRST, always. A notification's author is very often somebody
    // whose kind:0 is already in the store from the feed, a thread, or a
    // previous session, and this path never once looked. Every reference client
    // reads its cache before it opens a socket: NDK's `fetchProfile` returns
    // from the cache adapter before creating a subscription, and Jumble reads
    // IndexedDB and only refreshes past a three day staleness.
    //
    // Exact and cheap here, because the store has a composite author+kind index
    // and keeps at most one kind:0 per pubkey.
    var still_missing: [wanted_profiles_cap][32]u8 = undefined;
    var missing: usize = 0;
    if (main.g_store != null) {
        hydrateProfiles(batch[0..n]);
        for (batch[0..n]) |pk| {
            const known = if (lookupProfile(pk)) |prof| prof.name_len > 0 else false;
            if (known) {
                // Answered from disk. Retire the want rather than asking a relay
                // for something already held.
                for (&g_wanted) |*w| {
                    if (w.used and std.mem.eql(u8, &w.pubkey, &pk)) w.* = .{};
                }
                continue;
            }
            still_missing[missing] = pk;
            missing += 1;
        }
    } else {
        @memcpy(still_missing[0..n], batch[0..n]);
        missing = n;
    }
    if (missing == 0) return;

    // Only now, and only for what disk could not answer. The attempt is counted
    // HERE, after the network is known to be allowed, never before: counting it
    // first is what wrote names off during the seconds before the first relay
    // had finished its handshake.
    if (!networkAllowed()) return;
    for (still_missing[0..missing]) |pk| {
        for (&g_wanted) |*w| {
            if (!w.used or !std.mem.eql(u8, &w.pubkey, &pk)) continue;
            w.last_tried = now;
            w.attempts +|= 1;
        }
    }
    askProfiles(still_missing, missing);
    askProfileHints();
}

/// Dials the relays an `nprofile1` named, for the people whose hints are still
/// untried. Bounded per pass, like the quote half.
fn askProfileHints() void {
    if (!relayFetchAllowed()) return;
    var spawned: usize = 0;
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        if (w.hints.tried or w.hints.isEmpty()) continue;
        if (spawned + w.hints.count > quote_hint_dials_per_pass) break;
        w.hints.tried = true;
        for (0..w.hints.count) |i| {
            if (!isPublicRelayUrl(w.hints.at(@intCast(i)))) continue;
            var url_buf: [place_relay_cap]u8 = undefined;
            const len = copyBounded(&url_buf, w.hints.at(@intCast(i)));
            const t = std.Thread.spawn(.{}, askProfileAt, .{ url_buf, len, w.pubkey }) catch continue;
            t.detach();
            spawned += 1;
        }
    }
}

/// Asks ONE relay an address named for one person's metadata, ingests it, and
/// closes. `askQuoteAt`'s shape, with a kind:0 filter.
fn askProfileAt(url_buf: [place_relay_cap]u8, url_len: usize, pubkey: [32]u8) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var relay = nostr.relay.dial(gpa, io, url_buf[0..url_len]) catch return;
    defer relay.deinit();
    const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse return;
    defer releaseOneShot(watched);

    const authors = [_][32]u8{pubkey};
    const kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    relay.subscribe(one_shot_sub_prefix ++ "profile-hint", &filters) catch return;
    while (true) {
        var msg = (relay.receive() catch break) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| _ = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch {},
            .eose => break,
            // A CLOSED ends this relay's part, and no EOSE is coming after it.
            .closed => break,
            else => {},
        }
    }
}

/// The filters for a relay the reader is not on, asked about the people who
/// write there.
///
/// NO `since`, which is the whole point of this function existing separately.
///
/// `feedSince` is "the newest note I hold, minus an hour", and on the pool's own
/// relays that is right: they have been answering this same question all along,
/// so anything older is already in the store. A routed relay has answered
/// nothing. It was dialled precisely because it holds notes from people whose
/// posts the reader has never had, and every one of those is older than the
/// newest note the reader holds from anybody else. Stamping `since` on that
/// subscription asks a relay full of missing history for the last hour of it.
///
/// Amethyst hit the same thing from the other side and wrote it down: a `since`
/// floor "silently emptied the tab" on a cold start.
///
/// No `self` either: the reader's own notes come from the reader's own relays,
/// and asking a stranger's relay about them is asking the wrong place.
pub fn buildRoutedFilters(authors: []const [32]u8, out: []nostr.filter.Filter) []nostr.filter.Filter {
    return buildFeedFilters(authors, null, null, out);
}
/// Asks the pool for these authors' metadata, on the sockets it already holds.
///
/// Was a thread that dialled every relay in turn and read each to EOSE: eight
/// TLS handshakes and a parked thread to learn one display name. The answers
/// land in the store either way, and the profile cache already reads them from
/// there on the next tick, so there was never anything for that thread to wait
/// for.
fn askProfiles(batch: [wanted_profiles_cap][32]u8, len: usize) void {
    const kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{.{ .authors = batch[0..len], .kinds = &kinds, .limit = @intCast(len) }};
    _ = askPool(one_shot_sub_prefix ++ "profiles", &filters);
}
/// A cached author profile.
pub const Profile = struct {
    used: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    name_buf: [64]u8 = [_]u8{0} ** 64,
    /// kind:0 `name`: the username, kept even when `display_name` wins the line
    /// above it, because it is what the handle line shows without a NIP-05.
    username_buf: [64]u8 = [_]u8{0} ** 64,
    username_len: u8 = 0,
    name_len: u8 = 0,
    // The kind:0 `nip05` identifier (`name@domain`), and where its verification
    // stands. The check draws only on `.verified`: a well-known lookup that maps
    // the name back to this pubkey, never on mere presence of the string.
    nip05_buf: [128]u8 = [_]u8{0} ** 128,
    nip05_len: u8 = 0,
    /// kind:0 `website`, kept for the handle line's last fallback before the
    /// npub. Shown as its host, because a full URL under a name is a link the
    /// row has no room for and nobody reads.
    website_buf: [128]u8 = [_]u8{0} ** 128,
    website_len: u8 = 0,
    nip05_state: enum { idle, fetching, verified, failed } = .idle,
    picture_buf: [200]u8 = [_]u8{0} ** 200,
    picture_len: u8 = 0,
    /// The resolved avatar URL, which is also its cache key.
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,
    /// The id of the kind:0 event these fields came from, so an unchanged
    /// event is never parsed twice (the store keeps only the newest per
    /// author, but the feed reconciles every second).
    meta_id: [32]u8 = [_]u8{0} ** 32,
    // The avatar's lifecycle: not yet fetched, in flight, registered, or given
    // up on (initials fallback).
    avatar_state: enum { idle, fetching, loaded, failed } = .idle,
    /// Fetches of this face that came back unusable for a reason worth retrying.
    /// Cleared on a successful load, on a changed picture URL, and by the
    /// Settings retry.
    avatar_attempts: u8 = 0,
    /// Ask this face's own host rather than the proxy, because the proxy
    /// refused the HOST rather than the picture. One flag rather than a
    /// counter, because it is one alternative: proxy, then source, then give
    /// up. Cleared with the rest of the avatar when the picture URL changes.
    avatar_direct: bool = false,
    /// A face too big for one response body. Same problem as a feed picture and
    /// the same answer: a profile picture straight from its own host is often a
    /// full-size photo, and one that drew initials was never undecodable, only
    /// too long to arrive in one piece.
    down: Download = .{},
    /// Whether this face's BYTES have been pulled into the disk cache ahead of
    /// being needed. Separate from `avatar_state` because that one is about a
    /// registry id and there are only nine of those: warming is what a row just
    /// off the bottom of the viewport can do without one.
    warm_state: enum { idle, fetching, done } = .idle,
    // The registered canvas-image id for this profile's avatar (0 = none). NOT
    // fixed per cache slot: there are only `max_avatar_images` registry ids for
    // far more cached authors, so ids are lent to whoever is on screen now and
    // reclaimed from whoever scrolled away (see `assignAvatarSlots`).
    image_id: u64 = 0,
    // The last avatar pass this author was on screen, so the id LRU evicts the
    // least-recently-seen author when it needs a slot for a new one.
    avatar_clock: u64 = 0,

    pub fn name(self: *const Profile) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn username(self: *const Profile) []const u8 {
        return self.username_buf[0..self.username_len];
    }
    fn website(self: *const Profile) []const u8 {
        return self.website_buf[0..self.website_len];
    }
    /// The host on its own: `https://fiatjaf.com/about` reads as `fiatjaf.com`.
    pub fn websiteHost(self: *const Profile) []const u8 {
        return urlHost(self.website());
    }
    pub fn nip05(self: *const Profile) []const u8 {
        return self.nip05_buf[0..self.nip05_len];
    }
    pub fn picture(self: *const Profile) []const u8 {
        return self.picture_buf[0..self.picture_len];
    }
    pub fn url(self: *const Profile) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

pub var g_profiles = [_]Profile{.{}} ** profile_cap;

// The avatar-id LRU clock (see `assignAvatarSlots`): bumped once per avatar
// pass; a profile's `avatar_clock` records the last pass it was on screen.
/// The tick that the avatar pass, the picture pass and the banner all mark
/// against.
///
/// ONE clock, because the slots are one pool: an avatar marked at tick N and a
/// picture marked at tick N+1 are not comparable, and eviction is nothing but
/// that comparison. Two clocks would have made whichever pass ticked second
/// look permanently newer, so the other kind would always be the one evicted.
pub var g_image_clock: u64 = 0;

// Bumped whenever a profile gains or changes a display name. Mention labels are
// baked into note text at parse time, so the feed re-parses (rather than
// reuses) its notes when this moves; author lines resolve live and never need it.
pub var g_names_generation: u64 = 0;
/// Drops a cached avatar. `parseMetadataInto` only ever REPLACES a picture URL,
/// which is right for an incoming profile (an absent key is silence, not a
/// removal) and wrong for an edit made here, where clearing the field IS the
/// removal and the old face would otherwise keep being drawn.
pub fn clearProfilePicture(pubkey: [32]u8) void {
    const profile = lookupProfile(pubkey) orelse return;
    profile.picture_len = 0;
    profile.url_len = 0;
    profile.avatar_state = .idle;
    profile.image_id = 0;
}
/// Finds the cached profile for `pubkey`, or null.
/// An open-addressed index over `g_profiles`, so a lookup is a probe rather
/// than a walk.
///
/// The cache was 160 slots and a linear scan was fine. Sizing it to the real
/// author set (200 notifications plus up to 2048 follows) made that scan 12x
/// longer, and it runs per note per feed rebuild: the 2048-follow rebuild went
/// from inside the frame budget to 17155us against 16000us, a visible stutter
/// every second. The cap and this index are one change, not two.
///
/// Slot values are index+1 so that zero means empty. Rebuilt wholesale on
/// eviction, which is rare and bounded.
const profile_index_slots = 8192;
pub var g_profile_index = [_]u16{0} ** profile_index_slots;
var g_profile_index_stale: usize = 0;

fn profileSlotFor(pubkey: [32]u8) usize {
    // The pubkey is already a hash, so its low bits are as good as any.
    const h = std.mem.readInt(u64, pubkey[0..8], .little);
    return @intCast(h % profile_index_slots);
}

fn profileIndexInsert(idx: usize) void {
    var slot = profileSlotFor(g_profiles[idx].pubkey);
    var probes: usize = 0;
    while (probes < profile_index_slots) : (probes += 1) {
        if (g_profile_index[slot] == 0) {
            g_profile_index[slot] = @intCast(idx + 1);
            return;
        }
        slot = (slot + 1) % profile_index_slots;
    }
}

fn profileIndexRebuild() void {
    @memset(&g_profile_index, 0);
    g_profile_index_stale = 0;
    for (&g_profiles, 0..) |*p, i| {
        if (p.used) profileIndexInsert(i);
    }
}

pub fn lookupProfile(pubkey: [32]u8) ?*Profile {
    var slot = profileSlotFor(pubkey);
    var probes: usize = 0;
    while (probes < profile_index_slots) : (probes += 1) {
        const entry = g_profile_index[slot];
        // An empty slot ends the probe: nothing past it can belong to this key.
        if (entry == 0) return null;
        const p = &g_profiles[entry - 1];
        if (p.used and std.mem.eql(u8, &p.pubkey, &pubkey)) return p;
        slot = (slot + 1) % profile_index_slots;
    }
    return null;
}

/// The cache slot for `pubkey`, allocating a free one on first sight, else
/// reusing the least-recently-seen slot. Avatar image ids are NOT tied to the
/// slot here (see `assignAvatarSlots`); a new slot starts with none and earns
/// one only while on screen.
pub fn upsertProfile(pubkey: [32]u8) ?*Profile {
    if (lookupProfile(pubkey)) |p| return p;
    for (&g_profiles, 0..) |*p, i| {
        if (!p.used) {
            p.* = .{ .used = true, .pubkey = pubkey };
            profileIndexInsert(i);
            return p;
        }
    }
    // Cache full: evict the author least-recently on screen. Never evict one
    // marked on screen THIS pass (an over-full pass would otherwise wipe an
    // author it just marked and thrash every tick), nor one with an index-keyed
    // fetch in flight (avatar OR NIP-05): those responses re-derive the profile
    // from its slot, so reusing it would apply a result to the wrong pubkey. An
    // over-full pass simply leaves the newcomer slotless (npub + initials) until
    // a slot frees, rather than churning. A reused id is freed for the newcomer.
    var victim: ?*Profile = null;
    for (&g_profiles) |*p| {
        if (p.avatar_state == .fetching or p.nip05_state == .fetching) continue;
        if (p.avatar_clock == g_image_clock) continue;
        if (victim == null or p.avatar_clock < victim.?.avatar_clock) victim = p;
    }
    const v = victim orelse return null;
    v.* = .{ .used = true, .pubkey = pubkey };
    // The evicted key's entry is left pointing at a slot that no longer holds
    // it. That is SAFE, because a lookup compares the pubkey and keeps probing
    // on a mismatch, and it is what keeps eviction O(1). Rebuilding the whole
    // table here instead cost 10ms per feed rebuild at 2048 follows, where the
    // cache is permanently full and every new author evicts.
    profileIndexInsert(idxOf(v));
    g_profile_index_stale += 1;
    // Stale entries lengthen probe chains, so the table is rebuilt occasionally
    // rather than never. Amortised to nothing across 512 evictions.
    if (g_profile_index_stale >= 512) profileIndexRebuild();
    return v;
}

/// The slot number of a profile pointer, for the index.
fn idxOf(p: *const Profile) usize {
    return (@intFromPtr(p) - @intFromPtr(&g_profiles[0])) / @sizeOf(Profile);
}

/// Parses a kind:0 metadata JSON content into `profile`'s name and picture.
/// Tolerant: unknown fields are ignored and a malformed blob leaves the profile
/// unchanged (it just keeps rendering from its npub). Prefers `display_name`
/// (or the legacy `displayName`) over `name`.
pub fn parseMetadataInto(profile: *Profile, content: []const u8) void {
    @setRuntimeSafety(true); // A kind:0 body, which is whatever its author put there.
    const Metadata = struct {
        name: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        displayName: ?[]const u8 = null,
        picture: ?[]const u8 = null,
        nip05: ?[]const u8 = null,
        website: ?[]const u8 = null,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const md = std.json.parseFromSliceLeaky(Metadata, arena_state.allocator(), content, .{ .ignore_unknown_fields = true }) catch return;

    // The first name that is actually SET wins. Checking presence alone is not
    // enough: plenty of real profiles carry `"display_name": ""` alongside a
    // real `name` (jb55's does), and an empty winner drops the author back to a
    // bare npub.
    for ([_]?[]const u8{ md.displayName, md.display_name, md.name }) |candidate| {
        const raw = candidate orelse continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        profile.name_len = @intCast(copyDisplayText(&profile.name_buf, trimmed));
        break;
    }
    // The username is kept separately: it is the handle line under a display
    // name, and collapsing the two fields into one left that line empty for every
    // author without a NIP-05.
    if (md.name) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            profile.username_len = @intCast(copyDisplayText(&profile.username_buf, trimmed));
        }
    }
    if (md.picture) |pic| {
        const trimmed = std.mem.trim(u8, pic, " \t\r\n");
        if (trimmed.len <= profile.picture_buf.len and (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://"))) {
            // A changed picture URL means the old avatar is stale: refetch it
            // into the same image slot.
            if (!std.mem.eql(u8, trimmed, profile.picture())) {
                @memcpy(profile.picture_buf[0..trimmed.len], trimmed);
                profile.picture_len = @intCast(trimmed.len);
                if (profile.avatar_state != .fetching) profile.avatar_state = .idle;
                // A different picture is a different resource, so whatever the
                // last one failed at says nothing about this one, including
                // which host refused it.
                profile.avatar_attempts = 0;
                profile.avatar_direct = false;
            }
        }
    }

    // The website, for the handle line's last fallback before an npub. Stored
    // whole and trimmed to its host at render time, so a profile that changes
    // its path does not have to be re-parsed.
    profile.website_len = 0;
    if (md.website) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        // Gated on the scheme, exactly as `picture` is twelve lines above. This
        // string is a stranger's, it goes on the identity line under their name,
        // and `websiteHost` trims a scheme it recognises: without the gate a
        // `javascript:` or `data:` value would be stored and then rendered whole,
        // because the trimmer would find no `//` to cut at.
        const web = std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://");
        if (web and trimmed.len <= profile.website_buf.len) {
            @memcpy(profile.website_buf[0..trimmed.len], trimmed);
            profile.website_len = @intCast(trimmed.len);
        }
    }

    // NIP-05: keep the identifier and (re)arm verification when it is present
    // and changed. Absent or oversized means there is nothing to verify, so no
    // check ever draws.
    if (md.nip05) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0 and trimmed.len <= profile.nip05_buf.len and std.mem.indexOfScalar(u8, trimmed, '@') != null) {
            if (!std.mem.eql(u8, trimmed, profile.nip05())) {
                @memcpy(profile.nip05_buf[0..trimmed.len], trimmed);
                profile.nip05_len = @intCast(trimmed.len);
                if (profile.nip05_state != .fetching) profile.nip05_state = .idle;
            }
        } else {
            profile.nip05_len = 0;
            profile.nip05_state = .failed;
        }
    } else {
        profile.nip05_len = 0;
        profile.nip05_state = .failed;
    }
}
/// Reads kind:0 metadata for the feed's authors from the store and parses each
/// into the profile cache. The store keeps only the newest kind:0 per author, so
/// this always reflects the current metadata.
pub fn refreshProfiles(store: *nostr.store.Store) void {
    const kinds = [_]u16{0};
    // Bounds-checked at every push. This array used to be sized off the
    // comptime pack with no checks, so the first runtime follow list longer than
    // nine would have written past it: silent stack corruption in a release
    // build, from a feature that has nothing to do with profiles.
    // NOT the follow list. This used to walk every follow, up to 2048 of them,
    // on the feed reconcile path, and ask LMDB for all of their metadata on
    // every rebuild. That is the single reason a bigger profile cache made
    // scrolling slower rather than faster: the query limit was derived from the
    // cache size, so growing the cache grew the query.
    //
    // No reference client does this. Notedeck collects pubkeys from notes that
    // were actually ingested and only on a database MISS, then asks in a
    // debounced batch, with no follow-list pass anywhere. Amethyst has no path
    // at all that requests kind:0 for a whole contact list: each name on screen
    // registers itself. Jumble does walk the follow list, but off the render
    // path entirely, twenty at a time with a one second sleep between batches.
    //
    // What replaces it is already here: a displayed author with no name calls
    // `wantProfile`, so the wanted set IS the on-screen set, which is exactly
    // the input Notedeck uses.
    var authors: [wanted_profiles_cap + 1][32]u8 = undefined;
    var authors_len: usize = 0;
    if (activePubkey()) |pk| {
        if (authors_len < authors.len) {
            authors[authors_len] = pk;
            authors_len += 1;
        }
    }
    // Anyone a note mentioned, so their name resolves once it arrives.
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        if (authors_len >= authors.len) break;
        authors[authors_len] = w.pubkey;
        authors_len += 1;
    }
    if (authors_len == 0) return;
    // The limit is how many records the query can match, which is one kind:0
    // per author. It is not a cache size, and tying it to one was the bug.
    var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = @intCast(authors_len) }) catch return;
    defer result.deinit();
    for (result.events) |ev| {
        const p = upsertProfile(ev.pubkey) orelse continue;
        // The same event parses to the same fields; skip the JSON work.
        if (std.mem.eql(u8, &p.meta_id, &ev.id)) continue;
        const named_before = p.name_len > 0;
        const name_before = p.name_buf;
        parseMetadataInto(p, ev.content);
        p.meta_id = ev.id;
        if ((p.name_len > 0) != named_before or !std.mem.eql(u8, &p.name_buf, &name_before)) {
            g_names_generation +%= 1;
        }
    }
}

/// Marks `pubkey`'s profile as on screen this pass (creating the slot if new),
/// so the id LRU keeps its avatar and evicts someone off screen instead.
pub fn markAvatarWanted(pubkey: [32]u8) void {
    if (upsertProfile(pubkey)) |p| p.avatar_clock = g_image_clock;
}

/// Lends the `max_avatar_images` registry ids to the authors on screen right
/// now (the feed's visible window, or the open thread), reclaiming ids from
/// authors who scrolled away. There are far more cached authors than ids, so
/// without this only the first handful ever seen could hold a face and a
/// thread of strangers showed initials for everyone. Runs each tick before
/// `scanAvatarFetches`, which then fetches the faces for whoever just gained an
/// id. `fx` is needed to free a reclaimed id's registered image.
/// Asks for the kind:0 of everybody the reader is about to read.
///
/// The wanted set is the app's queue of "whose name do we still need", and it
/// was populated by exactly two callers: the inbox, and quoted notes. The FEED
/// never registered anybody. That was fine only for as long as `refreshProfiles`
/// walked the whole follow list, and when that walk was removed from the render
/// path the feed lost its only source of names: the comment left behind claimed
/// "a displayed author with no name calls `wantProfile`", which was true of the
/// notifications page it was written for and of nothing else.
///
/// What that looked like: real accounts, with profiles sitting on the relays,
/// drawn as a raw npub and a two-character avatar for the whole session. The
/// dial-time subscription asks for kind:0 alongside the notes, so most authors
/// resolve and the gap looks like an occasional glitch rather than a missing
/// mechanism. Anybody that one bounded backfill did not cover was never asked
/// about again.
///
/// Over the PREFETCH band, not just the visible rows, so a name is being fetched
/// while the row is still below the fold. This is the same window the image
/// warmer uses, and it has to be: `warmAvatar` needs `picture_len`, which comes
/// from the kind:0, so a face cannot be warmed ahead for somebody nobody asked
/// about. One missing registration was starving both.
///
/// Cheap to call every tick: `wantProfile` returns at once for anybody already
/// named, which after the first pass is nearly everybody.
pub fn wantProfilesAhead(model: *const Model) void {
    if (activePubkey()) |pk| wantProfile(pk);
    // The notifications page registers its own authors as rows are admitted,
    // which catches likers and zappers who are in no other set.
    if (model.notifications_open) return;
    if (model.levelOpen()) {
        const set = &view_thread.g_level_visible[@min(view_thread.g_visible_level, view_thread.g_level_visible.len - 1)];
        for (set.authors[0..set.author_count]) |pk| wantProfile(pk);
        return;
    }
    const w = model.prefetchRange();
    var i = w.first;
    while (i <= w.last and i < model.notes_len) : (i += 1) wantProfile(model.notes[i].pubkey);
}
/// A NIP-05 local part (`^[a-z0-9-_.]+$`, case-insensitive per the spec), so the
/// name drops straight into the query string without escaping.
pub fn validNip05Name(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

/// A plausible host (optionally `host:port`) for the well-known URL. Guards the
/// fetch against a malformed identifier rather than trusting the kind:0 blob.
pub fn validNip05Domain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > 253) return false;
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return false;
    for (domain) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_' or c == ':')) return false;
    }
    return true;
}

/// Fires NIP-05 well-known lookups for cached profiles that carry an identifier
/// and have not been checked, a few per tick. The response lands on
/// `nip05_verified`; only a match flips the profile to `.verified`, and only
/// then does the identity line draw its check.
pub fn scanNip05Fetches(fx: *Effects) void {
    // Verifying a NIP-05 means asking a domain a stranger wrote whether it knows
    // this key, from the reader's own address. That is the same disclosure the
    // switch exists to stop, so it stops here too, and unverified names simply
    // show without a check.
    if (!prefs.g_media_previews) return;
    const per_tick = 4;
    var fired: usize = 0;
    for (&g_profiles, 0..) |*p, i| {
        if (!p.used or p.nip05_state != .idle or p.nip05_len == 0) continue;
        const at = std.mem.indexOfScalar(u8, p.nip05(), '@') orelse {
            p.nip05_state = .failed;
            continue;
        };
        const name = p.nip05()[0..at];
        const domain = p.nip05()[at + 1 ..];
        if (!validNip05Name(name) or !validNip05Domain(domain)) {
            p.nip05_state = .failed;
            continue;
        }
        if (fired >= per_tick) continue;
        var url_buf: [320]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/.well-known/nostr.json?name={s}", .{ domain, name }) catch {
            p.nip05_state = .failed;
            continue;
        };
        p.nip05_state = .fetching;
        fx.fetch(.{
            .key = nip05_fetch_key_base + @as(u64, @intCast(i)),
            .url = url,
            .on_response = Effects.responseMsg(.nip05_verified),
        });
        fired += 1;
    }
}
pub fn nip05Matches(identifier: []const u8, pubkey: [32]u8, body: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, identifier, '@') orelse return false;
    const name = identifier[0..at];
    if (name.len == 0) return false;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch return false;
    if (root != .object) return false;
    const names = root.object.get("names") orelse return false;
    if (names != .object) return false;
    const entry = names.object.get(name) orelse return false;
    if (entry != .string) return false;

    const want = std.fmt.bytesToHex(pubkey, .lower);
    return std.ascii.eqlIgnoreCase(entry.string, &want);
}

/// Handles a NIP-05 fetch response: verified only on a well-known name→pubkey
/// match; a busy slot retries next tick; anything else fails closed (no check).
pub fn handleNip05Fetched(response: native_sdk.EffectResponse) void {
    if (response.key < nip05_fetch_key_base) return;
    const slot = response.key - nip05_fetch_key_base;
    if (slot >= g_profiles.len) return;
    const p = &g_profiles[@intCast(slot)];
    if (!p.used or p.nip05_len == 0) return;

    if (response.outcome == .rejected) {
        p.nip05_state = .idle;
        return;
    }
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0) {
        p.nip05_state = .failed;
        return;
    }
    p.nip05_state = if (nip05Matches(p.nip05(), p.pubkey, response.body)) .verified else .failed;
}

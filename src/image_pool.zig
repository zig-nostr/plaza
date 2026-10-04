//! The app's image registry slots, prewarming, and avatar fetches.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const inbox = @import("inbox.zig");
const prefs = @import("prefs.zig");
const profile_cache = @import("profile_cache.zig");
const feed_media = @import("feed_media.zig");
const view_place = @import("view_place.zig");
const view_profile = @import("view_profile.zig");
const view_thread = @import("view_thread.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const mediaFetchAllowed = main.mediaFetchAllowed;
const wantProfilesAhead = main.wantProfilesAhead;
const Effects = main.Effects;
const InboxItem = main.InboxItem;
const MediaSlot = main.MediaSlot;
const Model = main.Model;
const Note = main.Note;
const Profile = main.Profile;
const activePubkey = main.activePubkey;
const avatarUrl = main.avatarUrl;
const avatar_fetch_key_base = main.avatar_fetch_key_base;
const avatar_target_px = main.avatar_target_px;
const avatar_warm_key_base = main.avatar_warm_key_base;
const cachedImageExists = main.cachedImageExists;
const classifyImageFailure = main.classifyImageFailure;
const decodeAndRegister = main.decodeAndRegister;
const feedImageUrl = main.feedImageUrl;
const fetchSlice = main.fetchSlice;
const image_registry_slots = main.image_registry_slots;
const inboxItems = main.inboxItems;
const inbox_cap = main.inbox_cap;
const loadCachedImage = main.loadCachedImage;
const lookupProfile = main.lookupProfile;
const markAvatarWanted = main.markAvatarWanted;
const max_image_attempts = main.max_image_attempts;
const max_image_bytes = main.max_image_bytes;
const media_warm_key_base = main.media_warm_key_base;
const proxyRefusedHost = main.proxyRefusedHost;
const rememberProxyRefusal = main.rememberProxyRefusal;
const showsImage = main.showsImage;
const storeCachedImage = main.storeCachedImage;
const thread_reply_cap = main.thread_reply_cap;

/// Opens one pass of the image passes: everything they mark as on screen is
/// marked against this tick.
///
/// Its own step, called by the tick rather than hidden inside whichever pass
/// happens to run first. Burying it in the avatar pass would have made the
/// picture pass silently depend on running second, and a later reordering would
/// have shown up as pictures thrashing rather than as anything named.
pub fn beginImagePass() void {
    profile_cache.g_image_clock += 1;
}

pub fn assignAvatarSlots(fx: *Effects, model: *const Model) void {

    // Collect the on-screen authors in READING ORDER (the active user, then the
    // thread's root and replies top-down, or the feed's visible window). Order
    // matters: there are far fewer ids than a long thread has authors, so the
    // ids are lent to the top of what is being read, not to an arbitrary cache
    // slot. Bounded to the largest set a single pass can hold.
    var onscreen: [thread_reply_cap + 4][32]u8 = undefined;
    var n: usize = 0;
    const push = struct {
        fn f(list: [][32]u8, len: *usize, pk: [32]u8) void {
            if (len.* < list.len) {
                list[len.*] = pk;
                len.* += 1;
            }
        }
    }.f;
    if (activePubkey()) |pk| push(&onscreen, &n, pk);
    if (model.notifications_open) {
        // The notifications page occludes everything, and its rows are the only
        // faces on screen. Without this branch its authors were never in the
        // set that lends registry slots, so every row drew initials no matter
        // how long the page stayed open: the ids were all out on loan to a feed
        // nobody could see.
        // Only the rows ON SCREEN, which is the same rule the thread branch
        // below spells out and the same mistake it is warning about. Pushing
        // all of them marked every author wanted, and the claim pass never
        // evicts anything wanted this pass, so nine ids were locked by rows the
        // reader could not see and every visible row kept its initials.
        var buf: [inbox_cap]InboxItem = undefined;
        const shown = inboxItems(&buf, !model.notifications_everyone);
        const first = @min(inbox.g_inbox_visible.first, shown.len);
        const last = @min(inbox.g_inbox_visible.last + 1, shown.len);
        if (last > first) {
            for (shown[first..last]) |item| push(&onscreen, &n, item.author);
        }
    } else if (model.levelOpen()) {
        // A level occludes the feed, so its authors own the ids while it is up,
        // and only the ones ON SCREEN in it. Walking every note in the level
        // instead meant the first nine authors of a long thread took every id
        // and kept it: the claim pass never evicts anything marked wanted this
        // pass, and marking all of them made every id unreclaimable. Everyone
        // below kept initials for as long as the level was open.
        const set = &view_thread.g_level_visible[@min(view_thread.g_visible_level, view_thread.g_level_visible.len - 1)];
        for (set.authors[0..set.author_count]) |pk| push(&onscreen, &n, pk);
    } else {
        const w = model.visibleRange();
        var i = w.first;
        while (i <= w.last and i < model.notes_len) : (i += 1) push(&onscreen, &n, model.notes[i].pubkey);
    }

    // Mark every one wanted FIRST, so the claim pass below never evicts a
    // sibling that is also on screen this pass. Then lend an id to each in order,
    // so the earliest-read authors win the scarce ids.
    for (onscreen[0..n]) |pk| markAvatarWanted(pk);
    for (onscreen[0..n]) |pk| {
        const p = lookupProfile(pk) orelse continue;
        if (p.image_id == 0 and p.picture_len > 0) claimAvatarSlot(fx, p);
    }
}

// ------------------------------------------------- the whole-app image pool
//
// ONE allocator over all `image_registry_slots`, serving avatars, pictures and
// the profile banner alike. The block at the top of this file argues for it;
// this is it. Consumers differ only in what they downscale to, never in a
// reserved share, because a reserved share is capacity that sits idle on the
// screen that needs it: a profile page wants a banner and many faces and no
// feed pictures at all, and a feed of four-picture notes wants the opposite.

/// Who is holding each id. Derived from the consumers on every pass rather than
/// stored beside them: they already record which id they hold, and a second
/// table saying the same thing is a second thing that can be wrong.
const IdOwner = union(enum) {
    free,
    avatar: *Profile,
    banner,
    /// The open place's mark. It has to be an owner like any other: a slot this
    /// app holds but the pool does not know about reads as FREE, so the next
    /// face that arrives is handed the id the Info card is drawing. The reader
    /// sees the community's logo turn into somebody's avatar.
    place_logo,
    media: *MediaSlot,
};

/// One pass over the consumers, rather than a scan per id: the profile cache is
/// thousands of entries and this runs whenever a face or a picture appears.
pub fn imageIdOwners() [image_registry_slots + 1]IdOwner {
    var owners = [_]IdOwner{.free} ** (image_registry_slots + 1);
    if (view_profile.g_banner_image_id >= 1 and view_profile.g_banner_image_id <= image_registry_slots) {
        owners[@intCast(view_profile.g_banner_image_id)] = .banner;
    }
    if (view_place.g_place_logo_id >= 1 and view_place.g_place_logo_id <= image_registry_slots) {
        owners[@intCast(view_place.g_place_logo_id)] = .place_logo;
    }
    for (&profile_cache.g_profiles) |*p| {
        if (p.used and p.image_id >= 1 and p.image_id <= image_registry_slots) {
            owners[@intCast(p.image_id)] = .{ .avatar = p };
        }
    }
    for (&feed_media.g_media) |*m| {
        if (m.used and m.image_id >= 1 and m.image_id <= image_registry_slots) {
            owners[@intCast(m.image_id)] = .{ .media = m };
        }
    }
    return owners;
}

/// When a held id was last on screen, or null if it may not be taken at all.
///
/// Two things make an id untouchable, and they are the same two for every kind
/// of consumer: it is on screen THIS pass (taking it would evict something the
/// reader is looking at, and with the marking done first, that means a sibling
/// that has not been served yet), or a fetch is in flight for it (taking it
/// would hand the arriving bytes to whoever holds the id next).
pub fn imageIdSeen(owner: IdOwner) ?u64 {
    return switch (owner) {
        .free => null,
        .avatar => |p| if (p.avatar_clock == profile_cache.g_image_clock or p.avatar_state == .fetching) null else p.avatar_clock,
        .media => |m| if (m.last_used == profile_cache.g_image_clock or m.state == .fetching) null else m.last_used,
        .banner => if (view_profile.g_banner_seen == profile_cache.g_image_clock) null else view_profile.g_banner_seen,
        .place_logo => if (view_place.g_place_logo_seen == profile_cache.g_image_clock or view_place.g_place_logo_state == .fetching) null else view_place.g_place_logo_seen,
    };
}

/// Takes an id back from whoever holds it: the registered pixels go, and the
/// former owner is reset so it reloads (from the disk cache, usually) if the
/// reader comes back to it.
fn releaseImageId(fx: *Effects, owner: IdOwner, id: u64) void {
    _ = fx.unregisterImage(id);
    switch (owner) {
        .free => {},
        .avatar => |p| {
            p.image_id = 0;
            p.avatar_state = .idle;
        },
        .media => |m| {
            m.releaseFrames();
            m.image_id = 0;
            m.state = .idle;
        },
        .banner => {
            view_profile.g_banner_image_id = 0;
            view_profile.g_banner_state = .idle;
        },
        .place_logo => {
            view_place.g_place_logo_id = 0;
            view_place.g_place_logo_state = .idle;
        },
    }
}

const IdPick = struct { id: u64, owner: IdOwner };

/// WHICH id the next image should get: a free one, or the one whose holder has
/// been off screen longest. Null when every id is held by something on screen
/// or mid-fetch, which is the honest answer: the caller shows initials, or a
/// blurhash, for this frame and asks again next pass.
///
/// Separate from taking it because this is the whole rule, and taking it needs
/// the effects channel to drop the old pixels. The decision is what a test can
/// ask about.
pub fn chooseImageId(owners: *const [image_registry_slots + 1]IdOwner) ?IdPick {
    var id: u64 = 1;
    while (id <= image_registry_slots) : (id += 1) {
        if (owners[@intCast(id)] == .free) return .{ .id = id, .owner = .free };
    }

    var pick: ?IdPick = null;
    var oldest: u64 = std.math.maxInt(u64);
    id = 1;
    while (id <= image_registry_slots) : (id += 1) {
        const owner = owners[@intCast(id)];
        const seen = imageIdSeen(owner) orelse continue;
        if (seen < oldest) {
            oldest = seen;
            pick = .{ .id = id, .owner = owner };
        }
    }
    return pick;
}

/// Takes the id `chooseImageId` picked, dropping whatever was in it.
pub fn acquireImageId(fx: *Effects) ?u64 {
    const owners = imageIdOwners();
    const pick = chooseImageId(&owners) orelse return null;
    if (pick.owner != .free) releaseImageId(fx, pick.owner, pick.id);
    return pick.id;
}

/// Assigns `p` an id from the shared pool. A no-op when everything is spoken
/// for, and that author keeps initials this frame.
fn claimAvatarSlot(fx: *Effects, p: *Profile) void {
    p.image_id = acquireImageId(fx) orelse return;
}

/// Pulls the bytes for rows NEAR the viewport into the disk cache, without
/// claiming a registry id for any of them.
///
/// The two are separable and were not separated. Fetching was gated on holding
/// one of the nine avatar ids or six picture ids, and those are lent only to rows
/// already on screen, so every row arrived cold: blank, then a request, then a
/// face a moment later. Scroll and it happens again, forever, which is what makes
/// a feed feel like it is dragging even when the frame time is fine.
///
/// Nothing about downloading an image needs a slot. Only DISPLAYING it does. So a
/// band either side of the viewport is fetched and written to `~/.plaza/media`
/// ahead of time, and the local-first path that already exists (`loadCachedImage`
/// on claim, "registered before the first paint") turns that into an instant
/// face when the row does arrive.
pub fn warmAhead(fx: *Effects, model: *const Model) void {
    if (!prefs.g_media_previews) return;
    // Only the feed. A thread or a profile is a bounded level whose rows are all
    // fetched by the pass that owns it, and widening those would spend bandwidth
    // on rows that do not exist.
    if (model.levelOpen()) return;

    const warm = model.prefetchRange();
    const seen = model.visibleRange();
    // Budgets of their own, under the ceilings the on-screen passes use: warming
    // must never crowd out the row the reader is looking at. Faces are small and
    // there is one per row, so they get the larger share; a picture can be a
    // megabyte, and warming a stack of them for rows nobody reaches is how a
    // prefetch turns into somebody's data bill.
    const face_per_tick = 8;
    const picture_per_tick = 3;
    var faces: usize = 0;
    var pictures: usize = 0;

    var i = warm.first;
    while (i <= warm.last and i < model.notes_len) : (i += 1) {
        // The rows on screen are the other passes' business; they hold slots and
        // are already being fetched properly.
        if (i >= seen.first and i <= seen.last) continue;
        const note = &model.notes[i];
        if (faces < face_per_tick) {
            if (lookupProfile(note.pubkey)) |p| {
                if (warmAvatar(fx, p)) faces += 1;
            }
        }
        if (pictures < picture_per_tick and showsImage(note)) {
            if (warmPicture(fx, note)) pictures += 1;
        }
    }
}

/// Warms one face. Returns whether a fetch actually went out.
fn warmAvatar(fx: *Effects, p: *Profile) bool {
    if (p.warm_state != .idle or p.picture_len == 0) return false;
    // A face that HOLDS a registry id is the on-screen path's business, and
    // warming it would be a second request for the same bytes. Everything else is
    // warmable: a `.failed` fetch from a previous pass is worth one more try from
    // the cache's side, and `.idle` with no id is the ordinary case this exists
    // for. What is NOT warmable is a face already in the cache, which the check
    // below settles.
    if (p.image_id != 0 or p.avatar_state == .loaded) return false;

    var url_buf: [1024]u8 = undefined;
    const url = avatarUrl(&url_buf, p.picture(), p.avatar_direct);
    if (!mediaFetchAllowed(url)) return false;
    if (cachedImageExists(url)) {
        p.warm_state = .done;
        return false;
    }
    const index = profileIndexOf(p) orelse return false;
    p.warm_state = .fetching;
    fx.fetch(.{
        .key = avatar_warm_key_base + index,
        .url = url,
        .on_response = Effects.responseMsg(.avatar_warmed),
    });
    return true;
}

/// Warms one picture. Keyed by the note's own id rather than a slot, since the
/// whole point is that it has no slot.
fn warmPicture(fx: *Effects, note: *const Note) bool {
    const raw = note.imageUrl();
    if (raw.len == 0) return false;
    var url_buf: [1024]u8 = undefined;
    const url = feedImageUrl(&url_buf, raw);
    if (!mediaFetchAllowed(url)) return false;
    if (warmedAlready(url)) return false;
    if (cachedImageExists(url)) {
        _ = rememberWarmed(url);
        return false;
    }
    // A slot's worth of key space, indexed by the ring position rather than by a
    // media slot, which this deliberately does not hold.
    const index = rememberWarmed(url);
    fx.fetch(.{
        .key = media_warm_key_base + index,
        .url = url,
        .on_response = Effects.responseMsg(.media_warmed),
    });
    return true;
}

/// The URLs warmed recently, so a row hovering just off screen is not re-fetched
/// every tick. A ring rather than a set: it only has to stop a repeat within the
/// few seconds a row spends near the edge, and a cache hit is the backstop for
/// anything it forgets.
pub const warm_ring_len = 32;
pub const WarmEntry = struct {
    hash: u64 = 0,
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,

    fn url(self: *const WarmEntry) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};
pub var g_warm_ring: [warm_ring_len]WarmEntry = [_]WarmEntry{.{}} ** warm_ring_len;
pub var g_warm_ring_next: u64 = 0;

pub fn warmedAlready(url: []const u8) bool {
    const h = std.hash.Wyhash.hash(0, url);
    for (&g_warm_ring) |*seen| {
        if (seen.hash == h and seen.url_len != 0) return true;
    }
    return false;
}

/// Records the attempt AND the URL, because the effect response carries a key
/// and a body but not the address it came from, and the cache is keyed by the
/// address.
fn rememberWarmed(url: []const u8) u64 {
    const slot = g_warm_ring_next % warm_ring_len;
    const e = &g_warm_ring[@intCast(slot)];
    e.hash = std.hash.Wyhash.hash(0, url);
    const n = @min(url.len, e.url_buf.len);
    @memcpy(e.url_buf[0..n], url[0..n]);
    e.url_len = @intCast(n);
    g_warm_ring_next +%= 1;
    return slot;
}

/// The index of `p` within the profile table, which is what the avatar fetch
/// keys are built from.
fn profileIndexOf(p: *const Profile) ?u64 {
    for (&profile_cache.g_profiles, 0..) |*q, i| {
        if (q == p) return @intCast(i);
    }
    return null;
}

/// A warmed face's bytes: written to the cache, never registered. The row that
/// eventually shows it claims an id and loads it from disk.
pub fn handleAvatarWarmed(response: native_sdk.EffectResponse) void {
    if (response.key < avatar_warm_key_base) return;
    const index = response.key - avatar_warm_key_base;
    if (index >= profile_cache.g_profiles.len) return;
    const p = &profile_cache.g_profiles[@intCast(index)];
    if (!p.used) return;
    // A rejection is a busy effect table, not a bad URL: leave it warmable.
    if (response.outcome == .rejected) {
        p.warm_state = .idle;
        return;
    }
    p.warm_state = .done;
    if (response.outcome != .ok or response.status != 200 or response.truncated) return;
    if (response.body.len == 0 or response.body.len > max_image_bytes) return;
    var url_buf: [1024]u8 = undefined;
    const url = avatarUrl(&url_buf, p.picture(), p.avatar_direct);
    storeCachedImage(url, response.body);
}

/// The same for a picture. There is no per-note state to update: the ring already
/// recorded the attempt, and the file is the result.
pub fn handleMediaWarmed(response: native_sdk.EffectResponse) void {
    if (response.key < media_warm_key_base) return;
    const slot = response.key - media_warm_key_base;
    if (slot >= g_warm_ring.len) return;
    if (response.outcome != .ok or response.status != 200 or response.truncated) return;
    // Warming stays one request, so a picture bigger than one body is not warmed
    // at all: it is fetched in slices when its row reaches the screen, and
    // cached then. The cost is that a big picture arrives a moment late the
    // first time and instantly ever after, which is worth more than holding a
    // prefetch slot open across several round trips for a row nobody has
    // reached yet.
    if (response.body.len == 0 or response.body.len > max_image_bytes) return;
    // The ring is what remembers the address: a response carries a key and a
    // body, and the cache is keyed by the URL. A slot reused by a later warm
    // before this answer arrived writes the newer URL's name, so the hash is
    // checked rather than assumed.
    const e = &g_warm_ring[@intCast(slot)];
    if (e.url_len == 0) return;
    storeCachedImage(e.url(), response.body);
}

/// Fires avatar fetches for cached profiles that have a picture and an image
/// slot but no avatar yet, a few per tick to stay well inside the effect budget.
/// The response lands on `avatar_fetched`.
pub fn scanAvatarFetches(fx: *Effects) void {
    // A face is something the note points at, like its picture.
    if (!prefs.g_media_previews) return;
    const per_tick = 8;
    var fired: usize = 0;
    for (&profile_cache.g_profiles, 0..) |*p, i| {
        if (!p.used or p.avatar_state != .idle or p.picture_len == 0 or p.image_id == 0) continue;

        var url_buf: [1024]u8 = undefined;
        const url = avatarUrl(&url_buf, p.picture(), p.avatar_direct);
        const n = @min(url.len, p.url_buf.len);
        @memcpy(p.url_buf[0..n], url[0..n]);
        p.url_len = @intCast(n);

        // Local-first: a cached avatar is registered before the first paint, so
        // faces arrive with the feed rather than seconds after it.
        if (loadCachedImage(fx, p.image_id, p.url(), avatar_target_px)) |_| {
            p.avatar_state = .loaded;
            continue;
        }
        if (fired >= per_tick) continue;
        p.avatar_state = .fetching;
        p.down.release();
        if (!fetchSlice(fx, avatar_fetch_key_base + @as(u64, @intCast(i)), p.url(), 0, Effects.responseMsg(.avatar_fetched))) {
            // Refused, so no answer is coming: initials, not a wait for good.
            p.avatar_state = .failed;
            continue;
        }
        fired += 1;
    }
}

/// Handles an avatar fetch response: registers the decoded image on success, or
/// retries a slot-starved rejection and gives up (initials) on anything else.
pub fn handleAvatarFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < avatar_fetch_key_base) return;
    const slot = response.key - avatar_fetch_key_base;
    if (slot >= profile_cache.g_profiles.len) return;
    const p = &profile_cache.g_profiles[@intCast(slot)];
    if (!p.used) return;

    // A rejection means every effect slot was busy: try again next tick.
    if (response.outcome == .rejected) {
        p.down.release();
        p.avatar_state = .idle;
        return;
    }
    // A slice of a face bigger than one body: take it, and ask for the next
    // unless the host just said there is no next.
    if (response.outcome == .ok and response.status == 206 and !response.truncated and response.body.len > 0) {
        const outcome = p.down.append(response.body) orelse {
            p.down.release();
            p.avatar_state = .failed;
            return;
        };
        if (outcome == .want_more) {
            if (!fetchSlice(fx, response.key, p.url(), p.down.len, Effects.responseMsg(.avatar_fetched))) {
                p.down.release();
                p.avatar_state = .failed;
            }
            return;
        }
        const whole = p.down.bytes() orelse response.body;
        finishAvatar(fx, p, whole);
        p.down.release();
        return;
    }
    // Anything but a clean, whole, OK image body. Which of those is worth asking
    // again is the same question the feed's pictures ask, so it is the same
    // answer: a face used to be given up on for the rest of the session over one
    // 503, one rate limit, or one dropped connection.
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        p.down.release();
        // The proxy refusing the HOST is a different question from the picture
        // being unusable, so it gets the source itself rather than another go
        // at the same wall. Once per face, and only while the proxy is what was
        // used, so it can never loop. The attempt counter is untouched.
        if (prefs.g_media_direct_fallback and prefs.g_media_proxy_on and !p.avatar_direct and
            proxyRefusedHost(response.outcome, response.status))
        {
            // Written down for the whole host, not just this face: the refusal
            // is a fact about where the picture lives, and every other picture
            // there can skip the round trip that discovers it.
            rememberProxyRefusal(p.picture());
            p.avatar_direct = true;
            p.avatar_state = .idle;
            return;
        }
        p.avatar_state = switch (classifyImageFailure(response.outcome, response.status)) {
            .give_up => .failed,
            .retry => blk: {
                p.avatar_attempts +|= 1;
                break :blk if (p.avatar_attempts >= max_image_attempts) .failed else .idle;
            },
        };
        return;
    }
    p.down.release();
    finishAvatar(fx, p, response.body);
}

/// Decodes a complete face into `p`'s registry id and remembers it.
fn finishAvatar(fx: *Effects, p: *Profile, bytes: []const u8) void {
    // Downscaling if the platform decoder will not take it as-is. Only a
    // genuinely undecodable body falls back to initials now.
    if (decodeAndRegister(fx, p.image_id, bytes, avatar_target_px)) |_| {
        p.avatar_state = .loaded;
        p.avatar_attempts = 0;
        storeCachedImage(p.url(), bytes);
    } else {
        // Undecodable bytes are a fact about the picture, not about the network.
        p.avatar_state = .failed;
    }
}

/// Runs one avatar-id assignment pass, for tests.
pub fn assignAvatarSlotsForTest(fx: *Effects, model: *const Model) void {
    wantProfilesAhead(model);
    beginImagePass();
    assignAvatarSlots(fx, model);
}
pub fn warmAheadForTest(fx: *Effects, model: *const Model) void {
    warmAhead(fx, model);
}

pub fn resetWarmForTest() void {
    g_warm_ring = [_]WarmEntry{.{}} ** warm_ring_len;
    g_warm_ring_next = 0;
}
/// Whether the pool could take this id back right now: held, and neither on
/// screen this pass nor mid-fetch.
pub fn imageIdTakeableForTest(id: u64) bool {
    if (id < 1 or id > image_registry_slots) return false;
    const owners = imageIdOwners();
    return imageIdSeen(owners[@intCast(id)]) != null;
}
pub fn touchMediaClockForTest() u64 {
    beginImagePass();
    return profile_cache.g_image_clock;
}

pub fn acquireImageIdForTest(fx: *Effects) ?u64 {
    return acquireImageId(fx);
}

/// What the pool thinks holds an id. The bug this guards against is a slot the
/// app holds and the pool calls `free`.
pub fn imageIdOwnerNameForTest(id: u64) []const u8 {
    if (id < 1 or id > image_registry_slots) return "out-of-range";
    const owners = imageIdOwners();
    return @tagName(owners[@intCast(id)]);
}

pub fn placeLogoUntouchableForTest() bool {
    return imageIdSeen(.place_logo) == null;
}
/// The id the pool would hand out next, without taking it. Lets a test ask what
/// the rule decides without an effects channel to drop pixels through.
pub fn chooseImageIdForTest() ?u64 {
    const owners = imageIdOwners();
    const pick = chooseImageId(&owners) orelse return null;
    return pick.id;
}
pub fn beginImagePassForTest() void {
    beginImagePass();
}

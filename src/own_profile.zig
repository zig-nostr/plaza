//! The reader's own profile: reading it back, editing it, and publishing it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const own_lists = @import("own_lists.zig");
const session = @import("session.zig");
const store_glue = @import("store_glue.zig");
const uploads = @import("uploads.zig");
const keyholder = @import("keyholder.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const unstored_toast = main.unstored_toast;
const signer_busy_toast = main.signer_busy_toast;
const setToast = main.setToast;
const ownWriteUnstored = main.ownWriteUnstored;
const heldOwnRecord = main.heldOwnRecord;
const takeFresh = main.takeFresh;
const listWriteInFlight = main.listWriteInFlight;
const SelfRead = main.SelfRead;
const Effects = main.Effects;
const Model = main.Model;
const activePubkey = main.activePubkey;
const clearProfilePicture = main.clearProfilePicture;
const confirmStartFresh = main.confirmStartFresh;
const dupeTags = main.dupeTags;
const forgetFresh = main.forgetFresh;
const max_relays = main.max_relays;
const noHistoryKnown = main.noHistoryKnown;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const parseMetadataInto = main.parseMetadataInto;
const plazaIngest = main.plazaIngest;
const relayFetchAllowed = main.relayFetchAllowed;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const releaseOneShot = main.releaseOneShot;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const upsertProfile = main.upsertProfile;
const watchOneShot = main.watchOneShot;

/// How long the sheet waits for a relay before saying it could not read the
/// profile. `relay.receive()` has no deadline, so a relay that accepts the
/// subscription and then says nothing would otherwise hold the round open for
/// the rest of the session.
pub const own_profile_wait_s: i64 = 12;
/// WHO has been asked about, and whether a relay actually answered.
///
/// Two things a bool got wrong. It survived a sign-out, so the round run for one
/// account decided that the NEXT account had no profile, and Save then published
/// an empty object over a real one. And it was set even when every relay was
/// offline, unreachable or write-only, so "nobody answered" and "they answered,
/// you have no profile" were the same state. Both readings end in a wipe, so the
/// answer records the pubkey it is about and is only set when a relay reached
/// the end of its answer.
pub var g_own_profile_asked_for: ?[32]u8 = null;
/// And the same for the CONTACT list, where getting it wrong is worse: a write
/// made before hearing back replaces everyone this reader follows with a
/// handful of accounts the app chose for them.
pub var g_own_contacts_asked_for: ?[32]u8 = null;
var g_own_contacts_answered = std.atomic.Value(bool).init(false);

/// Whether a relay has told THIS account who they follow (including telling us
/// they follow nobody).
pub fn ownContactsAnswered() bool {
    const pk = activePubkey() orelse return false;
    lockOwnProfile();
    defer unlockOwnProfile();
    const asked = g_own_contacts_asked_for orelse return false;
    if (!std.mem.eql(u8, &asked, &pk)) return false;
    return g_own_contacts_answered.load(.acquire);
}

pub fn noteOwnContactsAnswered(pk: [32]u8) void {
    lockOwnProfile();
    defer unlockOwnProfile();
    g_own_contacts_asked_for = pk;
    g_own_contacts_answered.store(true, .release);
}
/// Forgets every conclusion about this account's own records. Called on any
/// identity change, so nothing decided about one account is read as a fact about
/// the next.
pub fn forgetOwnRecordAnswers() void {
    forgetOwnProfileAnswer();
    lockOwnProfile();
    defer unlockOwnProfile();
    g_own_contacts_asked_for = null;
    g_own_contacts_answered.store(false, .release);
    // And WHICH relays answered. Leaving these set would let the next account
    // inherit the previous one's answers and reach the write gate without any
    // relay having said a word about them.
    own_lists.g_contacts_answered_by = [_]bool{false} ** max_relays;
    own_lists.g_own_outbox = .{};
    own_lists.g_own_lists_since_for = null;
    forgetFresh();
}
var g_own_profile_asking = std.atomic.Value(bool).init(false);
/// Set by the worker when at least one relay ANSWERED (EOSE), paired with the
/// pubkey it asked about. Read on the UI thread through `ownProfileAnswered`.
pub var g_own_profile_answered = std.atomic.Value(bool).init(false);
var g_own_profile_lock = std.atomic.Value(bool).init(false);

pub fn lockOwnProfile() void {
    while (g_own_profile_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
pub fn unlockOwnProfile() void {
    g_own_profile_lock.store(false, .release);
}

/// Whether a relay has answered about THIS account. Anything else, including a
/// round for a previous account and a round where nothing connected, is not an
/// answer about this one.
pub fn ownProfileAnswered() bool {
    const pk = activePubkey() orelse return false;
    lockOwnProfile();
    defer unlockOwnProfile();
    const asked = g_own_profile_asked_for orelse return false;
    if (!std.mem.eql(u8, &asked, &pk)) return false;
    return g_own_profile_answered.load(.acquire);
}

/// Forgets what was asked. Called whenever the identity changes, so no
/// conclusion about one account is ever read as a fact about another.
pub fn forgetOwnProfileAnswer() void {
    lockOwnProfile();
    defer unlockOwnProfile();
    g_own_profile_asked_for = null;
    g_own_profile_answered.store(false, .release);
}

/// A profile as it was published: its content AND its tags. NIP-39 puts identity
/// proofs (a GitHub account, a Mastodon handle) in kind:0's TAGS, so republishing
/// with `&.{}` deletes them exactly as silently as dropping a JSON key would.
pub const OwnProfile = struct {
    json: []u8,
    tags: []const nostr.event.Tag,
    created_at: i64,
    /// The event these came from, so a caller can tell an unchanged record from
    /// a new one without re-parsing it.
    id: [32]u8 = [_]u8{0} ** 32,
};

/// The reader's own newest kind:0, raw. The RAW content is the source of truth,
/// never the `Profile` cache: the cache models four fields and drops everything
/// else, so rebuilding from it would publish a profile with the rest deleted.
///
/// The returned slice is owned by the caller's allocator.
pub fn ownProfileJson(gpa: std.mem.Allocator) ?OwnProfile {
    return ownRecordJson(gpa, 0);
}

/// The reader's own newest event of `kind`, content and tags. The RAW record is
/// the source of truth for every write this app makes over one of its own
/// lists: the caches model a few fields and drop the rest, so rebuilding from
/// one would publish a record with everything else deleted.
pub fn ownRecordJson(gpa: std.mem.Allocator, kind: u16) ?OwnProfile {
    // Counted so a test can assert the SHAPE of the fix rather than its timing:
    // the property is that building a feed does not read this account's whole
    // contact list once per card, and a stopwatch on a CI runner is a poor way
    // to say that. Comptime, so the shipped binary has no counter.
    if (builtin.is_test) store_glue.g_own_record_reads += 1;
    const store = main.g_store orelse return null;
    const pk = activePubkey() orelse return null;
    const kinds = [_]u16{kind};
    const authors = [_][32]u8{pk};
    var result = store.query(gpa, .{ .authors = &authors, .kinds = &kinds, .limit = 1 }) catch return null;
    defer result.deinit();
    if (result.events.len == 0) return null;
    // Copied out before `result.deinit()`: the query owns its events through an
    // arena, and the write seam holds what it is given past this frame.
    const copy = gpa.dupe(u8, result.events[0].content) catch return null;
    // Whole or not at all. A partial base is what turns a splice into a delete.
    const tags = dupeTags(gpa, result.events[0].tags) orelse return null;
    return .{ .json = copy, .tags = tags, .created_at = result.events[0].created_at, .id = result.events[0].id };
}
/// The record a write of `kind` builds on: the reader's own newest one, or the
/// one that went out and the store has not taken yet when that is newer.
///
/// Built on the stored one instead, the write would publish a record without
/// the change already out on the relays. UI thread only, like the hold.
pub fn ownWriteBase(gpa: std.mem.Allocator, kind: u16) ?OwnProfile {
    const stored = ownRecordJson(gpa, kind);
    const held = heldOwnRecord(kind) orelse return stored;
    if (stored) |own| {
        if (own.created_at >= held.created_at) return own;
        freeOwnProfile(gpa, own);
    }
    // Whole or not at all, as for the stored one.
    const content = gpa.dupe(u8, held.content) catch return null;
    const tags = dupeTags(gpa, held.tags) orelse {
        gpa.free(content);
        return null;
    };
    return .{ .json = content, .tags = tags, .created_at = held.created_at, .id = held.id };
}

/// Frees what `ownProfileJson` handed back.
pub fn freeOwnProfile(gpa: std.mem.Allocator, own: OwnProfile) void {
    gpa.free(own.json);
    for (own.tags) |t| {
        for (t) |field| gpa.free(field);
        gpa.free(t);
    }
    gpa.free(own.tags);
}

/// Whether a kind:0 of this reader's is with a signer, Notary or a bunker. Until
/// it is signed and stored, no profile in the store is not "no profile".
pub fn profileSignPending() bool {
    if (keyholder.g_helper_sign.active and keyholder.g_helper_sign.kind == 0) return true;
    return listWriteInFlight(0);
}

/// Opens the sheet, seeded from the reader's own kind:0 if the app has it.
pub fn openProfileEdit(model: *Model) void {
    // A guest has no key, so there is nothing to read and nothing that could
    // sign an edit. The sheet would sit on "Reading your current profile" for
    // the rest of the session.
    if (model.is_guest()) {
        model.joining = true;
        return;
    }
    model.editing_profile = true;
    uploads.g_profile_upload_unsaved = false;
    uploads.g_profile_unsaved_at_save = false;
    uploads.clearPickRefused();
    model.profile_confirm_new = false;
    model.profile_name_buffer.clear();
    model.profile_about_buffer.clear();
    model.profile_picture_buffer.clear();
    model.profile_website_buffer.clear();
    model.profile_banner_buffer.clear();
    model.profile_lud16_buffer.clear();
    model.profile_nip05_buffer.clear();
    const gpa = std.heap.page_allocator;
    if (ownProfileJson(gpa)) |own| {
        // The whole record, not just its content: freeing only `json` left every
        // tag it carried behind on each open of the sheet.
        defer freeOwnProfile(gpa, own);
        // The three buffers were cleared two lines up, so there is nothing typed
        // to preserve here.
        seedProfileFields(model, own.json, false);
        model.profile_stage = .have;
        return;
    }
    // Nothing here yet. Ask before concluding anything.
    model.profile_seeded = false;
    model.profile_asked_at = nowSeconds();
    // Never `.absent` while a profile is with the signer: the reader's first one,
    // saved a moment ago, is not in the store until it is signed, and the sheet
    // would offer to start fresh over it.
    model.profile_stage = if (ownProfileAnswered() and !profileSignPending()) .absent else .fetching;
    if (model.profile_stage == .fetching) startOwnProfileFetch();
}

/// Fills the sheet's fields from the RAW blob, so what the reader sees is what
/// is about to be rewritten.
///
/// A value too long for its field is NOT shown truncated. A bio that runs past
/// the buffer would otherwise appear cut off, and saving without touching it
/// would write the cut-off version back over the real one: silent data loss from
/// merely opening a sheet. Such a field is left empty and marked, and the merge
/// then leaves that key exactly as it was.
pub fn seedProfileFields(model: *Model, json: []const u8, keep_typed: bool) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{
        // A real profile out there has repeated keys sometimes, and refusing to
        // parse it would refuse to edit it.
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch return;
    if (root != .object) return;
    const obj = root.object;
    // Which key the name came from, so the edit REWRITES that key. Seeding from
    // `name` and writing `display_name` leaves the value the reader edited
    // exactly where it was, and the rename silently does nothing.
    model.profile_name_key = .display_name;
    var name: ?[]const u8 = null;
    if (stringField(obj, "display_name")) |v| {
        name = v;
    } else if (stringField(obj, "displayName")) |v| {
        name = v;
        model.profile_name_key = .display_name_legacy;
    } else if (stringField(obj, "name")) |v| {
        name = v;
        model.profile_name_key = .name;
    }
    // A field the reader has already typed into keeps their text; every other
    // field is filled from the profile that just arrived.
    //
    // It used to be all or nothing, and the tick flipped the stage to `.have`
    // whether or not the seeding ran. So a reader who typed a display name while
    // the fetch was still out got a savable sheet over two fields that had never
    // been seeded and were still empty, and the merge REMOVES a key whose field
    // is empty: pressing Save deleted their bio and their avatar from a profile
    // the app had by then read correctly. Per field, every field is now either
    // known or deliberately typed, which is the same rule the too-long-to-show
    // fields already followed.
    if (!(keep_typed and model.profile_name_buffer.text().len > 0)) {
        model.profile_name_long = seedField(&model.profile_name_buffer, name);
    }
    if (!(keep_typed and model.profile_about_buffer.text().len > 0)) {
        model.profile_about_long = seedField(&model.profile_about_buffer, stringField(obj, "about"));
    }
    if (!(keep_typed and model.profile_picture_buffer.text().len > 0)) {
        model.profile_picture_long = seedField(&model.profile_picture_buffer, stringField(obj, "picture"));
    }
    if (!(keep_typed and model.profile_website_buffer.text().len > 0)) {
        model.profile_website_long = seedField(&model.profile_website_buffer, stringField(obj, "website"));
    }
    if (!(keep_typed and model.profile_banner_buffer.text().len > 0)) {
        model.profile_banner_long = seedField(&model.profile_banner_buffer, stringField(obj, "banner"));
    }
    if (!(keep_typed and model.profile_lud16_buffer.text().len > 0)) {
        model.profile_lud16_long = seedField(&model.profile_lud16_buffer, stringField(obj, "lud16"));
    }
    if (!(keep_typed and model.profile_nip05_buffer.text().len > 0)) {
        model.profile_nip05_long = seedField(&model.profile_nip05_buffer, stringField(obj, "nip05"));
    }
    model.profile_seeded = true;
}

/// Seeds one field. Returns whether the value was too long to hold, in which
/// case the field is left EMPTY rather than truncated: an empty field the merge
/// leaves alone is honest, a truncated one that gets written back is not.
fn seedField(buffer: anytype, value: ?[]const u8) bool {
    const v = value orelse return false;
    if (v.len > buffer.storage.len) {
        buffer.clear();
        return true;
    }
    buffer.set(v);
    return false;
}

pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |str| if (str.len == 0) null else str,
        else => null,
    };
}

/// Publishes the sheet's fields, MERGED into the reader's existing kind:0.
///
/// kind:0 is replaceable: what is published replaces the whole profile. Real
/// profiles carry `about`, `banner`, `website`, `lud16` (the lightning address
/// that is how somebody gets paid), and whatever else their other clients wrote.
/// This app models three of those, so it edits three keys of the object it read
/// and leaves every other key exactly where it was.
pub fn saveProfile(model: *Model, fx: *Effects) void {
    if (!model.profile_can_save()) return;
    if (activePubkey() == null) return;
    // A profile not found on any relay, for a key that was not made here: the
    // first press shows what a wrong guess costs, and the second is the reader's
    // answer. Nothing is signed or written by the first.
    if (model.profile_stage == .absent) {
        // The profile landed after the sheet said there was none. Its fields were
        // never shown, so merging the sheet into it would remove every one the
        // reader did not happen to type. Show it first; the next Save merges.
        const gpa = std.heap.page_allocator;
        if (ownProfileJson(gpa)) |own| {
            defer freeOwnProfile(gpa, own);
            seedProfileFields(model, own.json, true);
            model.profile_stage = .have;
            model.profile_confirm_new = false;
            return;
        }
    }
    if (model.profile_stage == .absent and !noHistoryKnown(.profile)) {
        if (!model.profile_confirm_new) {
            model.profile_confirm_new = true;
            return;
        }
        model.profile_confirm_new = false;
        if (!confirmStartFresh(.profile)) return;
    }
    // The sheet reports `.sent` as soon as it has handed the merge over, so a
    // rejected sign would show a saved profile that was never signed. Refusing
    // leaves the sheet exactly as it was, with Save still live.
    if (!signerReady()) return;
    // The last profile published is not in the store, and merging into the one
    // before it would undo that edit on every relay.
    if (ownWriteUnstored(0)) {
        setToast(model, unstored_toast);
        return;
    }
    const gpa = std.heap.page_allocator;

    var prev_created_at: i64 = 0;
    var prev_tags: []const nostr.event.Tag = &.{};
    var existing: ?OwnProfile = null;
    if (ownWriteBase(gpa, 0)) |own| {
        existing = own;
        prev_created_at = own.created_at;
        prev_tags = own.tags;
    } else if (model.profile_stage != .absent) {
        // It arrived as `have` and is gone now, or the round never finished.
        // Either way there is nothing safe to merge into.
        model.profile_stage = .fetching;
        startOwnProfileFetch();
        return;
    }
    defer if (existing) |e| freeOwnProfile(gpa, e);
    // A first profile for a key not made here spends the reader's yes, as every
    // list's first write does. One yes starts one profile: left standing, a later
    // read that came back empty (the first one still at the signer) published a
    // second first profile without asking.
    if (existing == null and !own_lists.g_identity_minted_here and !takeFresh(.profile)) {
        model.profile_confirm_new = false;
        return;
    }

    const merged = mergeProfileJson(gpa, if (existing) |e| e.json else "{}", model) orelse {
        model.profile_stage = .failed;
        return;
    };
    // The cache is seeded from a COPY, and BEFORE the write seam takes the
    // original: `signAndPublish` owns what it is handed and the remote path
    // frees it, so reading `merged` afterwards is a use-after-free.
    if (activePubkey()) |pk| {
        if (upsertProfile(pk)) |prof| parseMetadataInto(prof, merged);
        // A cleared picture has to leave the cache too, or the old avatar keeps
        // being drawn from a slot nothing will overwrite.
        if (trimmedField(model.profile_picture()).len == 0) clearProfilePicture(pk);
    }
    // A replaceable event with a stamp that does not beat the one already stored
    // is DROPPED, by this store and by every relay. A second edit inside one
    // second, or a clock that was ahead when the last client wrote, would make
    // the edit vanish while the app claimed success.
    const created = @max(nowSeconds(), prev_created_at + 1);
    // The TAGS come forward too. NIP-39 identity proofs (a GitHub account, a
    // Mastodon handle) live in kind:0's tags, and republishing with none would
    // delete them as silently as dropping a JSON key.
    const tags = dupeTags(gpa, prev_tags) orelse return;
    // The cache was seeded above so the sheet shows the edit at once. If the
    // signature never comes back, that seeding is what has to be contradicted:
    // "Saved here and sent to your relays" is otherwise the last word on an
    // edit that reached nobody.
    // Remembered before the edit goes, for a signer that refuses it. A signer
    // that answers at once releases this inside the call.
    uploads.g_profile_unsaved_at_save = uploads.g_profile_upload_unsaved;
    signAndPublish(fx, gpa, created, 0, tags, merged, false, .profile, null);
    // Only here, where the edit has actually gone to be signed. Every return
    // above leaves the sheet as it was, and the picture in it is still not out.
    uploads.g_profile_upload_unsaved = false;
    // NOT "published": nothing here can know that yet. `signAndPublish` returns
    // no verdict, the remote and helper paths have not even signed, and a kind:0
    // that reaches no relay is not retried. What IS true is that the edit is
    // saved here and is on its way out.
    model.profile_stage = .sent;
}

/// Parses `existing`, replaces the three keys this app models, and serialises the
/// whole object back. Key order survives the round trip, so a profile this app
/// did not change comes back byte-similar rather than reshuffled.
/// The object a kind:0 edit merges into, or null when a record that IS there
/// could not be read.
///
/// Falling back to an empty object on a parse failure is the merge failing
/// open, and this object is the base every field is written into. A profile
/// that did not parse would be republished as nothing but the fields the screen
/// happened to hold, so the reader's lightning address, NIP-05, banner and
/// website would be gone from every relay and from every other client. That is
/// the same shape as writing a contact list over one that was never read, and
/// the answer is the same: a record that cannot be read whole reads as "not
/// read", which every caller already handles.
///
/// Not a hypothetical failure, either. Zig's JSON parser is stricter than the
/// ones the rest of the ecosystem uses: it rejects an unpaired surrogate half
/// in a `\u` escape, and it validates raw UTF-8. Profiles that came through
/// bridges, or were written by clients that never checked, carry both, and
/// those readers would be the ones who lost the most.
///
/// Only a caller saying there is nothing there may start from nothing, which is
/// the literal `{}` passed when no record was found.
/// Whether `s` is empty or a plain http(s) URL.
///
/// Scheme only. Anything past that is the host's business, and a checker that
/// refused an unusual but working URL would be worse than one that let a typo
/// through: the reader can see their own picture not loading, and cannot see
/// why this app declined to save it.
pub fn looksLikeUrl(s: []const u8) bool {
    if (s.len == 0) return true;
    return std.ascii.startsWithIgnoreCase(s, "https://") or std.ascii.startsWithIgnoreCase(s, "http://");
}

/// Whether `s` is empty or looks like `name@domain.tld`.
///
/// One `@`, something on each side, and a dot in the domain. Both a lightning
/// address and a NIP-05 identifier are the same shape, and both are useless to
/// every other client if that shape is wrong.
pub fn looksLikeAddress(s: []const u8) bool {
    if (s.len == 0) return true;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (std.mem.lastIndexOfScalar(u8, s, '@').? != at) return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len == 0 or domain.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, domain, '.') orelse return false;
    return dot > 0 and dot + 1 < domain.len;
}

fn profileMergeBase(a: std.mem.Allocator, existing: []const u8) ?std.json.ObjectMap {
    const nothing_to_lose = existing.len == 0 or
        std.mem.eql(u8, std.mem.trim(u8, existing, " \t\r\n"), "{}");
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, existing, .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch return if (nothing_to_lose) std.json.ObjectMap.empty else null;
    if (root != .object) return if (nothing_to_lose) std.json.ObjectMap.empty else null;
    return root.object;
}

pub fn mergeProfileJson(gpa: std.mem.Allocator, existing: []const u8, model: *const Model) ?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var obj = profileMergeBase(a, existing) orelse return null;

    // An emptied field REMOVES its key rather than writing "": a profile with
    // `"about": ""` reads to other clients as a bio the reader deliberately
    // blanked, which is a different statement from not having one.
    // A field whose real value did not fit its buffer was never SHOWN, so it is
    // never written: the key keeps exactly what it had.
    if (!model.profile_name_long) {
        // Whichever key the name was read from is the key the edit rewrites.
        // Seeding from `name` and writing `display_name` would leave the value
        // the reader edited untouched, so the rename would silently do nothing.
        const key: []const u8 = switch (model.profile_name_key) {
            .display_name => "display_name",
            .display_name_legacy => "displayName",
            .name => "name",
        };
        setOrRemove(&obj, a, key, trimmedField(model.profile_name())) catch return null;
        // A profile with no handle at all gets one, so clients that read only
        // `name` have something to show. One that has a handle keeps it: a
        // display name is not a handle, and renaming yourself must not rename
        // the @handle everyone mentions you by.
        if (stringField(obj, "name") == null) {
            setOrRemove(&obj, a, "name", trimmedField(model.profile_name())) catch return null;
        }
    }
    if (!model.profile_about_long) {
        setOrRemove(&obj, a, "about", trimmedField(model.profile_about())) catch return null;
    }
    if (!model.profile_picture_long) {
        setOrRemove(&obj, a, "picture", trimmedField(model.profile_picture())) catch return null;
    }
    if (!model.profile_website_long) {
        setOrRemove(&obj, a, "website", trimmedField(model.profile_website())) catch return null;
    }
    if (!model.profile_banner_long) {
        setOrRemove(&obj, a, "banner", trimmedField(model.profile_banner())) catch return null;
    }
    if (!model.profile_lud16_long) {
        setOrRemove(&obj, a, "lud16", trimmedField(model.profile_lud16())) catch return null;
    }
    if (!model.profile_nip05_long) {
        setOrRemove(&obj, a, "nip05", trimmedField(model.profile_nip05())) catch return null;
    }

    // Straight onto the caller's allocator: the write seam holds this for the
    // life of the process, and the arena above dies with this function.
    return std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = obj }, .{}) catch null;
}
/// A field's text with the whitespace a reader leaves behind taken off.
pub fn trimmedField(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn setOrRemove(obj: *std.json.ObjectMap, a: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (value.len == 0) {
        _ = obj.orderedRemove(key);
        return;
    }
    try obj.put(a, key, .{ .string = try a.dupe(u8, value) });
}

/// Asks every read relay for our own kind:0, once. Until this has finished, "the
/// store has no profile for me" is not a fact about the account.
pub fn startOwnProfileFetch() void {
    // BEFORE the busy flag, not after: a return that has already swapped the
    // flag to true latches it, and nothing would ever ask again.
    if (!relayFetchAllowed()) return;
    if (g_own_profile_asking.swap(true, .acq_rel)) return;
    const pk = activePubkey() orelse {
        g_own_profile_asking.store(false, .release);
        return;
    };
    const thread = std.Thread.spawn(.{}, ownProfileWorker, .{pk}) catch {
        g_own_profile_asking.store(false, .release);
        return;
    };
    thread.detach();
}

/// What a relay's message says about the question a socket was opened to ask.
///
/// Three outcomes and not two, because the two ways a question ends are not the
/// same thing. An EOSE is the relay saying it looked and that is all of it.
/// A CLOSED is the relay refusing to look, or ending the subscription, and no
/// EOSE follows it. A loop that waits for "every relay answered" has to stop
/// waiting on a refusal, and must not count it toward what it learned.
const AskVerdict = enum { pending, answered, refused };

pub fn askVerdict(msg: nostr.message.RelayMessage) AskVerdict {
    return switch (msg) {
        .eose => .answered,
        .closed => .refused,
        else => .pending,
    };
}
fn ownProfileWorker(pk: [32]u8) void {
    var answered = false;
    // A profile that arrived from any relay and could not be read or stored
    // means the round has not shown there is none, however many relays said
    // EOSE. Otherwise "Publish first profile" is offered over it.
    var self_read: SelfRead = .{};
    defer {
        // ANSWERED, not merely attempted. A round where every relay was offline,
        // write-only, or refused the dial proves nothing about the account, and
        // reading it as "you have no profile" is how a profile gets replaced
        // with an empty one.
        lockOwnProfile();
        g_own_profile_asked_for = pk;
        g_own_profile_answered.store(answered and self_read.eoseAnswers(), .release);
        unlockOwnProfile();
        g_own_profile_asking.store(false, .release);
    }
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const kinds = [_]u16{0};
    const authors = [_][32]u8{pk};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    for (0..relaySlots()) |ri| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        if (!entry.read) continue;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        // Declared AFTER deinit so it runs BEFORE it: the keeper must have
        // let go of this pointer before the connection is freed.
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms) orelse continue;
        defer releaseOneShot(watched);
        relay.subscribe("plaza-me", &filters) catch continue;
        // A message that arrived and could not be parsed is skipped by the
        // connection and counted, and it may have been the profile. Checked
        // when this relay's part ends, whichever way it ends.
        const unreadable_at_ask = relay.unreadable();
        defer self_read.sawUnreadableSince(unreadable_at_ask, relay.unreadable());
        var seen: usize = 0;
        while (seen < 32) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            // Only an EOSE is an answer: "that is all I have". A CLOSED ends
            // this relay's part of the question and says nothing about the
            // account. `auth-required:` is the case that matters: the relay
            // declined to look, and reading that as "no kind:0 here" is what
            // lets an empty profile replace a real one.
            switch (askVerdict(msg.value)) {
                .answered => {
                    answered = true;
                    break;
                },
                .refused => break,
                .pending => {},
            }
            switch (msg.value) {
                .event => |e| {
                    const result = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch {
                        self_read.sawEvent(e.event, pk, false);
                        continue;
                    };
                    // A relay can send ANY event down any subscription, so the
                    // event has to be the thing that was asked for before it can
                    // count as an answer about it. Verified was not enough: a
                    // valid note from a stranger, pushed down "plaza-me", used to
                    // decide that this account had no profile.
                    if (result == .invalid) {
                        self_read.sawEvent(e.event, pk, false);
                        continue;
                    }
                    if (e.event.kind != 0) continue;
                    if (!std.mem.eql(u8, &e.event.pubkey, &pk)) continue;
                    answered = true;
                },
                else => continue,
            }
        }
    }
}

/// Publishes the name beat's text as the account's kind:0 metadata, and seeds
/// the local profile cache so the app shows the name at once.
///
/// The beat runs right after a key is created, when there is nothing to merge
/// into, but it goes through the same merge as the Edit profile sheet anyway:
/// the destructive shape is the one where a name is published as the WHOLE
/// profile, and having exactly one path here means that shape cannot come back
/// the next time somebody reaches for this function.
///
/// Returns false when the write was refused and the toast says why, so the
/// beat stays open for another press.
pub fn publishName(model: *Model, fx: *Effects) bool {
    const raw = trimmedField(model.name_buffer.text());
    if (raw.len == 0) return true;
    // Gated like every other write: a sign the signer cannot take would leave
    // the name on screen and on nobody's relays.
    if (!signerReady()) {
        setToast(model, signer_busy_toast);
        return false;
    }
    if (ownWriteUnstored(0)) {
        setToast(model, unstored_toast);
        return false;
    }
    const gpa = std.heap.page_allocator;

    var prev_created_at: i64 = 0;
    var prev_tags: []const nostr.event.Tag = &.{};
    var existing: ?OwnProfile = null;
    if (ownWriteBase(gpa, 0)) |own| {
        existing = own;
        prev_created_at = own.created_at;
        prev_tags = own.tags;
    }
    defer if (existing) |e| freeOwnProfile(gpa, e);

    // Quotes and backslashes are ESCAPED, not dropped: a name is prose, and the
    // serializer knows how to carry prose. (Dropping them was a fixed 64-byte
    // buffer away from a longer field overflowing it.)
    const json = mergeNameJson(gpa, if (existing) |e| e.json else "{}", raw) orelse return true;
    // The TAGS come forward, the same as the sheet's save. The beat only arms on
    // a key this app just minted, which has no kind:0 and therefore no NIP-39
    // proofs to lose, so this is not a bug being fixed: it is the one line that
    // stopped the doc comment above from being true, and the read of the stored
    // profile two lines up says plainly that somebody already expected one.
    const tags = dupeTags(gpa, prev_tags) orelse return true;
    signAndPublish(fx, gpa, @max(nowSeconds(), prev_created_at + 1), 0, tags, json, false, .profile, null);
    // Seed the cache: the composer line and the feed show the name at once.
    if (activePubkey()) |pk| {
        if (upsertProfile(pk)) |prof| parseMetadataInto(prof, json);
    }
    model.name_buffer.clear();
    return true;
}

/// The name beat's one-field merge: the same read-modify-write as the sheet's,
/// with only the name touched.
pub fn mergeNameJson(gpa: std.mem.Allocator, existing: []const u8, name: []const u8) ?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var obj = profileMergeBase(a, existing) orelse return null;
    setOrRemove(&obj, a, "name", name) catch return null;
    setOrRemove(&obj, a, "display_name", name) catch return null;
    return std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = obj }, .{}) catch null;
}

/// Completes the remembered first intent once an identity exists: the guest
/// reached for the composer, so it opens by itself. The welcome-in moment.
pub fn replayPending(model: *Model) void {
    if (model.pending == .post) {
        model.pending = .none;
        model.composing = true;
    }
}

pub fn forgetOwnRecordAnswersForTest() void {
    forgetOwnRecordAnswers();
}
pub fn noteOwnContactsAnsweredForTest(pk: [32]u8) void {
    noteOwnContactsAnswered(pk);
}

// There was a `g_own_relays_answered` here, set by the first EOSE from any relay
// and read as permission to publish a kind:10002. It is GONE rather than merely
// unused: an inference that wrong, left sitting in the file under a reassuring
// name, is one grep away from becoming a gate again. `canWriteRelayList` is the
// rule now, and the reason is written there.

/// This account's newest stored event of `kind`, its tags flattened to one
/// string. For tests that need to see what a publish actually WROTE rather than
/// whether it returned true: a splice that quietly drops half the list still
/// publishes, so the return value proves nothing about what went out.
/// This account's newest stored event of `kind`, its CONTENT. For the one
/// property that tags cannot show: that an encrypted half nobody here reads was
/// carried through a write rather than replaced with nothing.
pub fn ownRecordContentForTest(gpa: std.mem.Allocator, kind: u16) ?[]u8 {
    const own = ownRecordJson(gpa, kind) orelse return null;
    defer freeOwnProfile(gpa, own);
    return gpa.dupe(u8, own.json) catch null;
}

pub fn ownRecordTagsJoinedForTest(gpa: std.mem.Allocator, kind: u16) ?[]u8 {
    const own = ownRecordJson(gpa, kind) orelse return null;
    defer freeOwnProfile(gpa, own);
    var out = std.ArrayList(u8).empty;
    for (own.tags) |tag| {
        for (tag) |field| {
            out.appendSlice(gpa, field) catch return null;
            out.append(gpa, ' ') catch return null;
        }
        out.append(gpa, '\n') catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}
pub fn forgetOwnProfileAnswerForTest() void {
    forgetOwnProfileAnswer();
}

/// Records an answer the way the worker's `defer` does.
pub fn recordOwnProfileAnswerForTest(pk: [32]u8, answered: bool) void {
    lockOwnProfile();
    g_own_profile_asked_for = pk;
    g_own_profile_answered.store(answered, .release);
    unlockOwnProfile();
}

pub fn ownProfileAnsweredForTest() bool {
    return ownProfileAnswered();
}

pub fn seedProfileFieldsForTest(model: *Model, json: []const u8, keep_typed: bool) void {
    seedProfileFields(model, json, keep_typed);
}

/// The merge, exposed so a test can prove what survives it. This is the whole
/// safety argument of the Edit profile sheet in one function.
pub fn mergeProfileJsonForTest(gpa: std.mem.Allocator, existing: []const u8, model: *const Model) ?[]u8 {
    return mergeProfileJson(gpa, existing, model);
}

/// Drives the name beat's whole write, not just its merge. The tags it forwards
/// are invisible to `mergeNameJsonForTest`, which only sees the content.
pub fn publishNameForTest(model: *Model, fx: *Effects) void {
    _ = publishName(model, fx);
}

pub fn mergeNameJsonForTest(gpa: std.mem.Allocator, existing: []const u8, name: []const u8) ?[]u8 {
    return mergeNameJson(gpa, existing, name);
}

pub fn askVerdictForTest(msg: nostr.message.RelayMessage) []const u8 {
    return @tagName(askVerdict(msg));
}

/// The replay seam, exercised without disk or relays. For tests.
pub fn replayPendingForTest(model: *Model) void {
    replayPending(model);
}

//! The reader's media servers: the list, asking whether one exists, and writing it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const own_lists = @import("own_lists.zig");
const blossom = @import("blossom.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const FreshAsk = main.FreshAsk;
const Model = main.Model;
const OwnProfile = main.OwnProfile;
const activePubkey = main.activePubkey;
const askFreshFirst = main.askFreshFirst;
const blossom_list_kind = main.blossom_list_kind;
const freeOwnProfile = main.freeOwnProfile;
const nowSeconds = main.nowSeconds;
const one_shot_budget_ms = main.one_shot_budget_ms;
const ownRecordCreatedAt = main.ownRecordCreatedAt;
const ownRecordJson = main.ownRecordJson;
const ownRelaysAllFinished = main.ownRelaysAllFinished;
const plazaIngest = main.plazaIngest;
const relayFetchAllowed = main.relayFetchAllowed;
const relaySlots = main.relaySlots;
const relaySnapshot = main.relaySnapshot;
const releaseOneShot = main.releaseOneShot;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const takeFresh = main.takeFresh;
const watchOneShot = main.watchOneShot;

/// The media servers uploads go to, with where they came from.
const UploadServers = struct {
    urls: [blossom.max_servers][blossom.max_server_len]u8 = undefined,
    lens: [blossom.max_servers]u8 = [_]u8{0} ** blossom.max_servers,
    count: usize = 0,
    /// The reader's own list, rather than the built-in fallback.
    own: bool = false,

    pub fn at(self: *const UploadServers, i: usize) []const u8 {
        return self.urls[i][0..self.lens[i]];
    }
};

var g_blossom_lock = std.atomic.Value(bool).init(false);
var g_blossom_owner: ?[32]u8 = null;
var g_blossom_urls: [blossom.max_servers][blossom.max_server_len]u8 = undefined;
var g_blossom_lens: [blossom.max_servers]u8 = [_]u8{0} ** blossom.max_servers;
var g_blossom_count: usize = 0;
/// When the list held here was signed, or 0 when this account has none.
pub var g_blossom_created_at: i64 = 0;

pub fn lockBlossom() void {
    while (g_blossom_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

pub fn unlockBlossom() void {
    g_blossom_lock.store(false, .release);
}

/// Whether the list held here is the signed-in account's.
fn blossomIsOwned() bool {
    const pk = activePubkey() orelse return false;
    const owner = g_blossom_owner orelse return false;
    return std.mem.eql(u8, &owner, &pk);
}

/// Where a picture goes: the reader's own list when they have published one,
/// else the two built-in servers.
pub fn uploadServers() UploadServers {
    var out: UploadServers = .{};
    {
        lockBlossom();
        defer unlockBlossom();
        if (blossomIsOwned() and g_blossom_count > 0) {
            out.own = true;
            out.count = g_blossom_count;
            for (0..g_blossom_count) |i| {
                out.lens[i] = g_blossom_lens[i];
                @memcpy(out.urls[i][0..g_blossom_lens[i]], g_blossom_urls[i][0..g_blossom_lens[i]]);
            }
            return out;
        }
    }
    for (blossom.default_servers) |url| {
        var buf: [blossom.max_server_len]u8 = undefined;
        const norm = blossom.normalizeServer(&buf, url) orelse continue;
        out.lens[out.count] = @intCast(norm.len);
        @memcpy(out.urls[out.count][0..norm.len], norm);
        out.count += 1;
    }
    return out;
}

pub fn setBlossomServers(tags: []const nostr.event.Tag, created_at: i64) void {
    const pk = activePubkey() orelse return;
    var urls: [blossom.max_servers][blossom.max_server_len]u8 = undefined;
    var lens: [blossom.max_servers]u8 = undefined;
    const n = blossom.serversFromTags(tags, &urls, &lens);
    lockBlossom();
    defer unlockBlossom();
    g_blossom_urls = urls;
    g_blossom_lens = lens;
    g_blossom_count = n;
    g_blossom_owner = pk;
    g_blossom_created_at = created_at;
}

pub fn forgetBlossom() void {
    lockBlossom();
    defer unlockBlossom();
    g_blossom_owner = null;
    g_blossom_count = 0;
    g_blossom_created_at = 0;
}

pub fn loadBlossomFromStore() void {
    const gpa = std.heap.page_allocator;
    const own = ownRecordJson(gpa, blossom_list_kind) orelse return;
    defer freeOwnProfile(gpa, own);
    setBlossomServers(own.tags, own.created_at);
}

/// A server list arriving from a relay. This reader's own only, and only a newer
/// one than the one held.
pub fn ingestBlossomList(ev: nostr.event.Event) void {
    const me = activePubkey() orelse return;
    if (!std.mem.eql(u8, &me, &ev.pubkey)) return;
    // Under the lock: this runs on whichever relay thread delivered the list,
    // while the UI thread reads the same fields.
    lockBlossom();
    const older = blossomIsOwned() and ev.created_at < g_blossom_created_at;
    unlockBlossom();
    if (older) return;
    loadBlossomFromStore();
}

/// Whether this account's own server list is held here.
pub fn haveOwnBlossomList() bool {
    lockBlossom();
    defer unlockBlossom();
    return blossomIsOwned() and g_blossom_created_at > 0;
}

// Whether a list that is not here is a list that does not exist. Not a question
// the local store can answer: it holds no row both when there is none and when
// the fetch has not landed. So every relay the reader reads from is asked once,
// and only if ALL of them answer without one is the account treated as having
// none. One that is down, slow or write-only proves nothing about the others.
pub var g_blossom_probe_state = std.atomic.Value(u8).init(0);
pub var g_blossom_probe_for: ?[32]u8 = null;
const probe_none: u8 = 0;
const probe_asking: u8 = 1;
pub const probe_clean: u8 = 2;
pub const probe_unknown: u8 = 3;

/// Asks the relays whether this account has a server list. Once per account,
/// unless the last round could not tell: a relay that was down a minute ago may
/// be up now, and until it answers the list cannot be edited.
pub fn startBlossomProbe() void {
    if (!relayFetchAllowed()) return;
    const pk = activePubkey() orelse return;
    {
        lockBlossom();
        defer unlockBlossom();
        if (!blossomProbeWantedUnlocked(pk)) return;
        g_blossom_probe_for = pk;
    }
    g_blossom_probe_state.store(probe_asking, .release);
    const thread = std.Thread.spawn(.{}, blossomProbeWorker, .{pk}) catch {
        g_blossom_probe_state.store(probe_unknown, .release);
        return;
    };
    thread.detach();
}

/// Whether `pk` should be asked about. Called with the blossom lock held.
pub fn blossomProbeWantedUnlocked(pk: [32]u8) bool {
    const asked = g_blossom_probe_for orelse return true;
    if (!std.mem.eql(u8, &asked, &pk)) return true;
    return g_blossom_probe_state.load(.acquire) == probe_unknown;
}
/// Whether one relay's reply to the probe answers it. EOSE does: that relay
/// looked and has sent everything it holds. CLOSED does not: it is the relay
/// declining to look (auth-required, rate-limited, restricted), and a list kept
/// there is exactly as possible as before it said so.
pub fn probeReplyAnswers(tag: std.meta.Tag(nostr.message.RelayMessage)) bool {
    return tag == .eose;
}
fn blossomProbeWorker(pk: [32]u8) void {
    var asked: usize = 0;
    var answered: usize = 0;
    var found = false;
    defer {
        // An answer about one account is not an answer about another.
        lockBlossom();
        const still_current = if (g_blossom_probe_for) |current| std.mem.eql(u8, &current, &pk) else false;
        unlockBlossom();
        if (still_current) {
            g_blossom_probe_state.store(if (asked > 0 and answered == asked and !found) probe_clean else probe_unknown, .release);
        }
    }
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const kinds = [_]u16{blossom_list_kind};
    const authors = [_][32]u8{pk};
    const filters = [_]nostr.filter.Filter{.{ .authors = &authors, .kinds = &kinds, .limit = 1 }};
    for (0..relaySlots()) |ri| {
        var url_buf: [96]u8 = undefined;
        const entry = relaySnapshot(ri, &url_buf) orelse continue;
        if (!entry.read) continue;
        asked += 1;
        var relay = nostr.relay.dial(gpa, io, entry.url) catch continue;
        defer relay.deinit();
        const watched = watchOneShot(io, relay, one_shot_budget_ms);
        defer releaseOneShot(watched);
        relay.subscribe("plaza-bl", &filters) catch continue;
        var seen: usize = 0;
        while (seen < 32) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const result = plazaIngest(gpa, e.event, .{ .verify_with = signer }) catch continue;
                    if (result == .invalid) continue;
                    if (e.event.kind != blossom_list_kind) continue;
                    if (!std.mem.eql(u8, &e.event.pubkey, &pk)) continue;
                    found = true;
                },
                .eose, .closed => {
                    if (probeReplyAnswers(std.meta.activeTag(msg.value))) answered += 1;
                    break;
                },
                else => continue,
            }
        }
    }
}

pub fn blossomProbeAsking() bool {
    return g_blossom_probe_state.load(.acquire) == probe_asking;
}

/// Whether the account's server list may be published. Either it is here, so an
/// edit splices onto it and loses nothing, or the key was made in this app a
/// moment ago, or every relay the reader writes to has finished without one, in
/// which case the first Add asks before it starts a list.
pub fn canWriteBlossomList() bool {
    if (activePubkey() == null) return false;
    if (haveOwnBlossomList()) return true;
    if (own_lists.g_identity_minted_here) return true;
    return ownRelaysAllFinished();
}

pub const BlossomWrite = enum {
    published,
    /// Already there, or already gone.
    nothing_to_do,
    /// A signature is already out. One key signs one thing at a time.
    signer_busy,
    /// This account's list has not been read back, so publishing one would
    /// replace whatever is really out there.
    no_list_yet,
    /// The list is as long as Plaza sends to.
    full,
    failed,
};

/// Adds `add` to, or removes `remove` from, this reader's kind:10063. Either is
/// a normalized server address.
///
/// A near-copy of `writeBookmark`'s discipline, applied to a smaller list: the
/// RAW previous record is read, every tag and the content are carried forward
/// whole, only the one server moves, and nothing is written over a record that
/// has not been read.
pub fn writeBlossomServers(fx: *Effects, add_raw: ?[]const u8, remove_raw: ?[]const u8) BlossomWrite {
    if (!signerReady()) return .signer_busy;
    _ = activePubkey() orelse return .failed;
    const gpa = std.heap.page_allocator;
    // Compared and written in one spelling, whatever the caller was handed.
    var add_buf: [blossom.max_server_len]u8 = undefined;
    var remove_buf: [blossom.max_server_len]u8 = undefined;
    const add: ?[]const u8 = if (add_raw) |raw| (blossom.normalizeServer(&add_buf, raw) orelse return .failed) else null;
    const remove: ?[]const u8 = if (remove_raw) |raw| (blossom.normalizeServer(&remove_buf, raw) orelse return .failed) else null;

    var previous: ?OwnProfile = null;
    if (ownRecordJson(gpa, blossom_list_kind)) |own| previous = own;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);
    // With nothing stored to splice onto, only proof that there is nothing to
    // lose licenses a write. A list held in memory is not that proof: it is a
    // copy of a stored record, and a stored record that has gone is the case
    // where writing from nothing replaces it with one server. Nor is every relay
    // in the pool answering without one: on a cold import the pool is the
    // bootstrap relays, and the list lives on the relays the reader writes to.
    // The proof is the follow list's: the key was made here, or the reader said
    // to start one after every relay they write to had finished without it, and
    // that yes is spent by this write.
    if (previous == null and !own_lists.g_identity_minted_here and !takeFresh(.media_servers)) return .no_list_yet;

    const base_tags: []const nostr.event.Tag = if (previous) |prev| prev.tags else &.{};
    const base_content: []const u8 = if (previous) |prev| prev.json else "";
    const base_created_at: i64 = if (previous) |prev| prev.created_at else 0;

    var tags = std.ArrayList(nostr.event.Tag).empty;
    var handed_off = false;
    defer if (!handed_off) {
        for (tags.items) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        tags.deinit(gpa);
    };
    var found = false;
    var dropped = false;
    var usable: usize = 0;
    for (base_tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "server")) {
            var buf: [blossom.max_server_len]u8 = undefined;
            if (blossom.normalizeServer(&buf, tag[1])) |norm| {
                if (add) |a| {
                    if (std.mem.eql(u8, norm, a)) found = true;
                }
                if (remove) |r| {
                    if (std.mem.eql(u8, norm, r)) {
                        dropped = true;
                        continue;
                    }
                }
                usable += 1;
            }
        }
        // Everything else, and any server this app cannot read, goes back out
        // exactly as it came in.
        const copy = gpa.alloc([]const u8, tag.len) catch return .failed;
        for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    }
    if (add) |a| {
        if (found) return .nothing_to_do;
        if (usable >= blossom.max_servers) return .full;
        const copy = gpa.alloc([]const u8, 2) catch return .failed;
        copy[0] = gpa.dupe(u8, "server") catch return .failed;
        copy[1] = gpa.dupe(u8, a) catch return .failed;
        tags.append(gpa, copy) catch return .failed;
    } else if (!dropped) {
        return .nothing_to_do;
    }

    const owned_tags = tags.toOwnedSlice(gpa) catch return .failed;
    handed_off = true;
    const content = gpa.dupe(u8, base_content) catch return .failed;
    const created = @max(@max(nowSeconds(), ownRecordCreatedAt(blossom_list_kind) + 1), base_created_at + 1);
    g_blossom_saving = created;
    signAndPublish(fx, gpa, created, blossom_list_kind, owned_tags, content, false, .none, null);
    return .published;
}

/// The stamp of a server list that has been sent to be signed and has not come
/// back yet, or 0.
pub var g_blossom_saving: i64 = 0;
pub fn blossomAdd(model: *Model, fx: *Effects) void {
    const typed = std.mem.trim(u8, model.blossom_buffer.text(), " \t\r\n");
    model.blossom_error = .none;
    var buf: [blossom.max_server_len]u8 = undefined;
    const norm = blossom.normalizeServer(&buf, typed) orelse {
        model.blossom_error = .invalid;
        return;
    };
    // No list held and every write relay finished without one: the reader is
    // asked before a list of one is published over anything Plaza has not seen.
    if (askFreshFirst(model, FreshAsk.mediaServer(norm))) return;
    sayBlossomAdd(model, writeBlossomServers(fx, norm, null));
}

/// What an Add did, under the field.
pub fn sayBlossomAdd(model: *Model, outcome: BlossomWrite) void {
    switch (outcome) {
        .published => model.blossom_buffer.clear(),
        .nothing_to_do => model.blossom_buffer.clear(),
        .signer_busy => model.blossom_error = .busy,
        .no_list_yet => model.blossom_error = .unread,
        .full => model.blossom_error = .full,
        .failed => model.blossom_error = .failed,
    }
}

pub fn blossomRemove(model: *Model, fx: *Effects, index: u8) void {
    model.blossom_error = .none;
    const servers = uploadServers();
    // Only the reader's own list has rows to remove; the fallback is not theirs.
    if (!servers.own or index >= servers.count) return;
    switch (writeBlossomServers(fx, null, servers.at(index))) {
        .published, .nothing_to_do => {},
        .signer_busy => model.blossom_error = .busy,
        .no_list_yet => model.blossom_error = .unread,
        .full => model.blossom_error = .full,
        .failed => model.blossom_error = .failed,
    }
}

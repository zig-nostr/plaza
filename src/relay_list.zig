//! The reader's own NIP-65 relay list: owning it, adopting it, and publishing it.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const relay_table = @import("relay_table.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const OwnProfile = main.OwnProfile;
const RelayEntry = main.RelayEntry;
const activePubkey = main.activePubkey;
const forgetChangedRelaySlotStates = main.forgetChangedRelaySlotStates;
const forgetOutboxAcks = main.forgetOutboxAcks;
const forgetRelayRemovals = main.forgetRelayRemovals;
const freeOwnProfile = main.freeOwnProfile;
const isRelayUrl = main.isRelayUrl;
const lockRelayTable = main.lockRelayTable;
const max_relays = main.max_relays;
const noteOwnOutbox = main.noteOwnOutbox;
const nowMillis = main.nowMillis;
const nowSeconds = main.nowSeconds;
const ownRecordCreatedAt = main.ownRecordCreatedAt;
const ownRecordJson = main.ownRecordJson;
const poolHoldsRelay = main.poolHoldsRelay;
const relayAt = main.relayAt;
const relaySlots = main.relaySlots;
const relayUrlEql = main.relayUrlEql;
const relayWasRemoved = main.relayWasRemoved;
const relay_list_kind = main.relay_list_kind;
const saveRelays = main.saveRelays;
const signAndPublish = main.signAndPublish;
const signerReady = main.signerReady;
const snapshotRelayUrls = main.snapshotRelayUrls;
const unlockRelayTable = main.unlockRelayTable;

/// Whether this reader has a list of their own, as opposed to the one the app
/// was born with. It gates the one moment a remote event may rewrite the pool:
/// their published kind:10002 is their list, but only until they edit here.
pub var g_relays_are_mine = false;
/// WHOSE list is in `g_relays`. A bool could not tell "this account's list" from
/// "a list", and the difference is a wipe: signing out writes the bootstrap pool
/// to disk, the next launch reads it back as a saved list, and the account that
/// signs in next then has its real kind:10002 refused and overwritten with the
/// five relays the app was born with. Null means the pool belongs to nobody yet,
/// which is a guest's pool and the bootstrap pool.
pub var g_relay_owner: ?[32]u8 = null;

/// Whether the pool in memory is THIS account's, as opposed to a leftover from a
/// previous one or the list the app was born with. Only a yes here may refuse an
/// incoming kind:10002, and only a yes may be published as one.
pub fn relayListIsOwned() bool {
    const pk = activePubkey() orelse return false;
    const owner = g_relay_owner orelse return false;
    return std.mem.eql(u8, &owner, &pk);
}

/// Marks the pool as this account's: they edited it here, or it came from their
/// own kind:10002.
fn claimRelayList() void {
    g_relay_owner = activePubkey();
    g_relays_are_mine = g_relay_owner != null;
}

/// WHEN the list in the pool was signed, and it is the half that was missing.
///
/// Ownership alone decided whether an incoming kind:10002 was refused, so the
/// FIRST list this app ever adopted for an account froze the pool permanently,
/// across restarts, because `saveRelays` recorded the owner and nothing else. A
/// relay added in another client streamed in on every launch and was dropped
/// before its stamp was ever looked at, and the next badge press here
/// republished the frozen copy at a stamp built to win. The reader's own newer
/// list lost to their older one, silently, forever.
///
/// A stamp makes the rule the same one `ingestContactList` uses for kind:3:
/// refuse what is not newer, rather than refuse everything.
pub var g_relay_list_stamp: i64 = 0;

pub fn heldRelayListStamp() i64 {
    return g_relay_list_stamp;
}

/// Records the stamp of the list now in the pool. On adopt it is the event's; on
/// a publish from here it is what this app signed.
pub fn setRelayListStamp(created_at: i64) void {
    g_relay_list_stamp = created_at;
}

/// Whether an incoming kind:10002 for this account is allowed to replace the
/// pool. Owned and not newer is the only refusal.
fn relayListRefusesEvent(created_at: i64) bool {
    if (!relayListIsOwned()) return false;
    // An edit that has not gone out yet, and still can, beats their history: it
    // publishes within a tick or two and would out-stamp this anyway. An edit
    // this account is not allowed to publish has no future, so the list the
    // relays actually hold wins instead of being locked out by it.
    if (g_relay_list_dirty and canWriteRelayList()) return true;
    return created_at <= heldRelayListStamp();
}

/// A reader's own kind:10002, parsed and waiting for the UI thread to take it.
/// An ingest thread must not swap the pool out from under the threads reading
/// it (nor write the file), so it stages the list here and `adoptRelayList`
/// installs it between frames.
var g_staged_relays = [_]RelayEntry{.{}} ** max_relays;
pub var g_staged_ready = std.atomic.Value(bool).init(false);
/// When the staged list was signed. A kind:10002 is REPLACEABLE: whichever one
/// the reader signed last is their list, and relays answer in whatever order
/// they feel like. Without this the first relay to reply wins permanently, which
/// on a slow relay holding an old list means the app adopts a pool the reader
/// abandoned months ago.
pub var g_staged_created_at: i64 = 0;

/// Stages a reader's own kind:10002 as their relay list. NIP-65's markers read
/// plainly: an `r` tag with no marker is both, `read` or `write` narrows it.
///
/// Only ever staged when the pool is still the one the app was born with, so a
/// stale event from a relay cannot undo an edit made here.
pub fn applyOwnRelayList(ev: nostr.event.Event) void {
    // Only THIS account's own edits get to refuse this, and only when what they
    // hold is at least as new. A pool inherited from a previous account, or the
    // one the app was born with, must give way to the list the reader actually
    // published, and so must a copy of their list that they have since changed
    // somewhere else.
    if (relayListRefusesEvent(ev.created_at)) return;
    // A newer list replaces one already staged; an older one is ignored. Equal
    // stamps keep what is staged, so a relay echoing the same event changes
    // nothing.
    lockRelayTable();
    const staged_at = g_staged_created_at;
    unlockRelayTable();
    if (g_staged_ready.load(.acquire) and ev.created_at <= staged_at) return;
    var next = [_]RelayEntry{.{}} ** max_relays;
    var n: usize = 0;
    for (ev.tags) |tag| {
        if (tag.len < 2) continue;
        if (!std.mem.eql(u8, tag[0], "r")) continue;
        const url = std.mem.trim(u8, tag[1], " \t\r\n");
        if (!isRelayUrl(url) or url.len > 96) continue;
        var dup = false;
        for (next[0..n]) |e| {
            if (relayUrlEql(e.url(), url)) dup = true;
        }
        if (dup) continue;
        if (n >= max_relays) break;
        // NIP-65 knows two markers. Anything else narrows NOTHING: reading an
        // unknown word as "not read and not write" would produce a relay that
        // is neither, which is a relay this app would still dial and still count
        // while claiming it is for nothing.
        const marker: []const u8 = if (tag.len >= 3) tag[2] else "";
        const read_only = std.mem.eql(u8, marker, "read");
        const write_only = std.mem.eql(u8, marker, "write");
        next[n].used = true;
        @memcpy(next[n].url_buf[0..url.len], url);
        next[n].url_len = @intCast(url.len);
        next[n].read = !write_only;
        next[n].write = !read_only;
        n += 1;
    }
    // An empty list is not a list. A reader whose kind:10002 has no usable `r`
    // tag keeps the pool they have, rather than losing every relay at once.
    if (n == 0) return;
    lockRelayTable();
    g_staged_relays = next;
    g_staged_created_at = ev.created_at;
    unlockRelayTable();
    g_staged_ready.store(true, .release);
}

/// Installs a staged relay list, on the UI thread, between frames. Returns
/// whether anything changed, so the caller can say the pool moved.
pub fn adoptRelayList() bool {
    if (!g_staged_ready.load(.acquire)) return false;
    g_staged_ready.store(false, .monotonic);
    lockRelayTable();
    const staged_at = g_staged_created_at;
    unlockRelayTable();
    // An edit made while the event was in flight wins: their hands beat their
    // history. Re-checked here because the pool may have been claimed between
    // the staging and this frame.
    if (relayListRefusesEvent(staged_at)) return false;
    var before: [max_relays][96]u8 = undefined;
    var lens: [max_relays]u8 = undefined;
    snapshotRelayUrls(&before, &lens);
    lockRelayTable();
    relay_table.g_relays = g_staged_relays;
    unlockRelayTable();
    // A slot MAY now hold a different relay, in which case everything recorded
    // against it is about the previous occupant and is dropped. A slot that kept
    // its relay keeps its row: the connection behind it never went anywhere.
    forgetChangedRelaySlotStates(&before, &lens);
    var n: u8 = 0;
    for (relay_table.g_relays, 0..) |e, i| {
        if (e.used) n = @intCast(i + 1);
    }
    if (n > relay_table.g_relay_count.load(.monotonic)) relay_table.g_relay_count.store(n, .release);
    claimRelayList();
    setRelayListStamp(staged_at);
    // A pending edit is discarded rather than published on top: this list is
    // newer than anything that edit could have been based on, and republishing
    // the pool now would out-stamp the change the reader made elsewhere. The
    // refusal above is what keeps an edit that CAN still go out from reaching
    // here at all.
    clearRelayListPublish();
    // The list that just arrived IS this account's list, so nothing recorded
    // against the pool it replaced is about anything any more.
    forgetRelayRemovals();
    forgetOutboxAcks();
    saveRelays();
    // Deliberately NOT marked dirty: this list came FROM their kind:10002, and
    // republishing it would be the app talking to itself.
    return true;
}

/// Routes a kind:10002 by whose it is: the reader's own IS their list, a
/// follow's only offers where that follow can be reached.
pub fn ingestRelayList(ev: nostr.event.Event) void {
    if (activePubkey()) |pk| {
        if (std.mem.eql(u8, &pk, &ev.pubkey)) {
            // Where their lists live, recorded before anything below can refuse
            // the event: a pool this account edited here still has to be checked
            // against the relays they actually write to.
            noteOwnOutbox(ev);
            // The event itself is what opens the write gate, and it does so by
            // being STORED rather than by being seen: `canWriteRelayList` asks
            // the store, so a publish always has the list it is splicing onto.
            applyOwnRelayList(ev);
            return;
        }
    }
    // Somebody else's list. The suggestions are ranked from every list the
    // store holds rather than from this one in isolation, so all this has to do
    // is say that the answer has moved.
    //
    // It used to walk the tags here and keep the first six write relays ever
    // seen. That made the offer depend on whose list arrived first: one
    // person's relay could sit above one two hundred people use.
    //
    // Stamped as well as flagged, because a cold start lands hundreds of these
    // in a few seconds and the ranking is worth doing once they have stopped.
    if (nowMillis()) |ms| main.g_route_list_at.store(ms, .release);
    main.g_relay_ranks_dirty.store(true, .release);
}

/// An edit is waiting to be published, and when it was made. Walking a badge
/// from R·W back to R·W is three presses; publishing three replaceable events
/// for one decision is noise the reader's relays did not ask for, so the edit
/// settles first and the last state is what goes out.
pub var g_relay_list_dirty = false;
pub var g_relay_list_touched: i64 = 0;
const relay_list_settle_s: i64 = 2;

/// Marks the pool changed. The file is written at once (a crash must not lose an
/// edit), and the network hears about it once the reader stops pressing.
pub fn relayListEdited() void {
    // Claimed BEFORE the file is written, or the file records the PREVIOUS owner
    // (none, on the edit that matters) and the next launch reads this reader's
    // own list back as belonging to nobody.
    claimRelayList();
    saveRelays();
    forgetOutboxAcks();
    g_relay_list_dirty = true;
    g_relay_list_touched = nowSeconds();
}

/// Whether a settled edit is now due to go out. Split from the publish so a test
/// can drive the clock without a signer or a relay.
///
/// It does NOT consume the edit. It used to, and that was how an edit made
/// before this account's list had been read disappeared: the publish refused,
/// the flag was already gone, and nothing ever tried again, so the edit lived on
/// this machine and nowhere else for the rest of the install. Only a publish
/// that actually went out clears it.
pub fn relayListDue(now_s: i64) bool {
    if (!g_relay_list_dirty) return false;
    return now_s - g_relay_list_touched >= relay_list_settle_s;
}
/// Publishes a settled edit. Called from the frame tick, so a burst of presses
/// costs one event rather than one per press.
pub fn flushRelayList(fx: *Effects, now_s: i64) void {
    if (!relayListDue(now_s)) return;
    // Cleared by the publish, not by the attempt. A refusal leaves the edit
    // pending, so the tick tries again once the reason clears: their list
    // arriving from a relay is what usually clears it, and that can be minutes
    // after the press on a bad connection.
    if (publishRelayListReporting(fx)) clearRelayListPublish();
}

/// Marks the pending edit as delivered. Only a publish that went out calls this.
pub fn clearRelayListPublish() void {
    g_relay_list_dirty = false;
    g_relay_list_touched = 0;
}

/// Whether a kind is a note the reader wrote, as opposed to a record the app
/// keeps on their behalf. Only a note goes in the outbox: the queue is a promise
/// about things the reader typed, and "1 note did not go out" must never mean a
/// relay list that will be republished by the next edit anyway.
pub fn isReaderNote(kind: u16) bool {
    return kind == 1;
}

/// Publishes this reader's list as their kind:10002, so the next client they
/// open reads the same pool. An edit here is the source of truth: it goes to
/// disk and to the network in the same breath.
fn publishRelayList(fx: *Effects) void {
    _ = publishRelayListReporting(fx);
}

/// Whether this account's relay list may be published at all.
///
/// This used to be "some relay sent EOSE and did not mention a kind:10002, so
/// they must not have one". That is the same inference `canWriteFollows` calls
/// wrong, and dangerously so, and for the same reason: on a cold import the
/// relays being asked are the four this app was born with, which may hold none
/// of the reader's real ones. Four clean answers can coexist with a
/// twelve-relay list sitting somewhere this app has never dialed, and the price
/// of believing them was that list, replaced by the four we happened to know.
///
/// So the bar is the same as the contact list's. Either their list is HERE, in
/// which case the publish splices onto it and nothing can be lost, or the key
/// was minted in this app moments ago and provably has no history to lose.
/// Everything else stays on this device, and `relayWriteBlockedReason` says so.
pub fn canWriteRelayList() bool {
    if (activePubkey() == null) return false;
    if (haveOwnRelayList()) return true;
    return main.g_identity_minted_here;
}

/// Whether this account's own kind:10002 is in the local store.
fn haveOwnRelayList() bool {
    const gpa = std.heap.page_allocator;
    const own = ownRecordJson(gpa, relay_list_kind) orelse return false;
    freeOwnProfile(gpa, own);
    return true;
}

/// Why an edit is staying on this device, in the reader's terms, or null when
/// it is going out. A pool that silently never publishes is the same unexplained
/// dead control `followBlockedReason` exists to avoid.
pub fn relayWriteBlockedReason() ?[]const u8 {
    if (activePubkey() == null) return null;
    if (canWriteRelayList()) return null;
    return "Saved on this device. Plaza has not read your published relay list yet, so it will not replace it.";
}

/// Publishes, and says whether it did. The caller ignores the answer; a test
/// cannot, because "did not publish" is the whole safety property.
pub fn publishRelayListReporting(fx: *Effects) bool {
    // A guest has no identity to sign with, and their list stays local.
    if (activePubkey() == null) return false;
    // Owned, meaning this pool is this account's rather than a leftover or the
    // one the app was born with. An edit grants this to itself, which is why it
    // is not the whole gate.
    if (!relayListIsOwned()) return false;
    // A refusal here keeps the edit pending, so the tick brings it back the
    // moment the signer is free. This is the half of the same-tick collision the
    // relay list was on the losing end of.
    if (!signerReady()) return false;
    const gpa = std.heap.page_allocator;

    // Read ONCE, and gate on the read that is actually spliced from.
    //
    // This used to ask `canWriteRelayList()` first, which does its own store
    // read, and then read again for the base. Two reads can disagree: if the
    // second returns nothing, the gate has already said yes, the splice loop is
    // skipped, and the event is built from the pool alone. A thirteen-relay list
    // is then replaced by the eight relays this process happens to hold, which
    // is the exact deletion the splice below exists to prevent. `writeFollow`
    // documents this hazard and decides its gate from the one read it uses.
    var previous: ?OwnProfile = null;
    if (ownRecordJson(gpa, relay_list_kind)) |own| previous = own;
    // Somebody else's list may not be overwritten sight unseen. Minting the
    // identity here is the one case where there is legitimately nothing to read.
    if (previous == null and !main.g_identity_minted_here) return false;
    defer if (previous) |prev| freeOwnProfile(gpa, prev);

    var tags = std.ArrayList(nostr.event.Tag).empty;
    // Freed on every path that does not hand it to the write seam, which now
    // includes the ordinary "nothing usable" bail below.
    var handed_off = false;
    defer if (!handed_off) {
        for (tags.items) |tag| {
            for (tag) |field| gpa.free(field);
            gpa.free(tag);
        }
        tags.deinit(gpa);
    };

    // THE SPLICE. This used to build the whole event out of the pool, which is
    // how a thirteen-relay list came back as eight: the pool holds `max_relays`
    // and everything past that was simply not in the event any more. Same for a
    // `ws://` relay, a URL too long for a seat, and every tag type this app does
    // not model. A kind:10002 is replaceable, so each of those was a deletion.
    //
    // So the event is what they published, plus what the reader changed here.
    // A relay is dropped only when the reader took it out (`relayWasRemoved`);
    // one the pool holds is emitted below from the pool, which is where its
    // current read/write markers live.
    if (previous) |prev| {
        for (prev.tags) |tag| {
            if (tag.len == 0) continue;
            if (std.mem.eql(u8, tag[0], "r") and tag.len >= 2) {
                const url = std.mem.trim(u8, tag[1], " \t\r\n");
                if (poolHoldsRelay(url)) continue;
                if (relayWasRemoved(url)) continue;
            }
            const copy = gpa.alloc([]const u8, tag.len) catch return false;
            for (tag, 0..) |field, i| copy[i] = gpa.dupe(u8, field) catch return false;
            tags.append(gpa, copy) catch return false;
        }
    }

    for (0..relaySlots()) |i| {
        const e = relayAt(i) orelse continue;
        if (!e.read and !e.write) continue;
        var parts = gpa.alloc([]const u8, if (e.read and e.write) 2 else 3) catch return false;
        // Every field is allocated, including the literals: the cleanup above
        // frees each one, and a static string handed to `free` is a crash that
        // only happens on the error path nobody drives.
        parts[0] = gpa.dupe(u8, "r") catch return false;
        parts[1] = gpa.dupe(u8, e.url()) catch return false;
        if (!(e.read and e.write)) {
            parts[2] = gpa.dupe(u8, if (e.read) "read" else "write") catch return false;
        }
        tags.append(gpa, parts) catch return false;
    }
    // A list with no relays in it is not a list, it is a deletion. Refusing is
    // the same rule `applyOwnRelayList` applies coming the other way, and it
    // matters more here: the splice can leave tags behind (a carried `alt`, say)
    // after the reader has emptied the pool, so "some tags" is not "some relays".
    var relay_tags: usize = 0;
    for (tags.items) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "r")) relay_tags += 1;
    }
    if (relay_tags == 0) return false;
    const owned = tags.toOwnedSlice(gpa) catch return false;
    handed_off = true;
    // Past whatever is already stored. A replaceable event whose stamp does not
    // beat the stored one is dropped by this store and by every relay, so an
    // edit could vanish everywhere while the app showed it applied.
    const created = @max(nowSeconds(), ownRecordCreatedAt(relay_list_kind) + 1);
    // NIP-65 puts everything in the tags and says nothing about the content, so
    // this app has nothing to write there. That is not the same as having
    // something to erase: whatever a previous client put there comes forward,
    // for the same reason a contact list's legacy relay map does.
    const content = gpa.dupe(u8, if (previous) |prev| prev.json else "") catch return false;
    // `heldRelayListStamp()` is still the OLD stamp here: `setRelayListStamp`
    // runs below, after the handoff.
    signAndPublish(fx, gpa, created, relay_list_kind, owned, content, false, .{ .relay_list = heldRelayListStamp() }, null);
    // What the pool now represents. Without this the app's own event would come
    // back from a relay and be adopted over the pool that produced it, and worse,
    // a list the reader signed BEFORE this one would still be newer than the
    // nothing the pool used to record.
    setRelayListStamp(created);
    saveRelays();
    return true;
}

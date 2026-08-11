//! Writes a fixed feed into a store, so the frame budget measures the same app
//! twice.
//!
//! The frame budget used to measure whatever the relays happened to send. Two
//! runs of one binary saw different numbers of rows carrying an image, a quote
//! card or a link preview, so they had different amounts to lay out, and the
//! layout reading swung 2.4x on unchanged code. Twenty-two readings taken in one
//! afternoon spanned 1424us to 3376us, and dividing by the mounted node count
//! did not stabilise them either.
//!
//! A gate that noisy can only catch order-of-magnitude regressions, and it
//! caused two wrong conclusions in a day: a real 35% layout regression was read
//! as noise, and then a 300us saving was read as confirmed. Neither was
//! knowable from that harness.
//!
//! So the harness gets its own store, filled from here, and the app that reads
//! it never dials. Same corpus, same rows, every run.
//!
//! Deliberately NO images and no link previews. Both would send the app to the
//! network for bytes, which is the variance being removed, and an image whose
//! download races the measurement is worse than one that is absent. That makes
//! these numbers lower than a real feed's, which is fine: the budgets are
//! re-based against this corpus and the gate compares runs of itself.
//!
//! Authors are the starter pack, because a signed-out reader's feed is scoped
//! to exactly that, so the harness needs no identity, no session and no key.
//!
//! Events are written unsigned. Nothing on the read path verifies a signature
//! (the pool verifies on the way IN, which is the door this bypasses), so a
//! signature here would cost a second of secp256k1 per run and prove nothing.

const std = @import("std");
const nostr = @import("nostr");

/// The pubkeys a signed-out reader's feed is scoped to. Copied from the app
/// rather than imported: importing `main.zig` would drag the whole SDK into a
/// tool that wants a store and nothing else.
///
/// They only have to MATCH the app's list, and the app asserts that they do.
const starter_pack_hex = [_][]const u8{
    "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2",
    "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245",
    "04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9",
    "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93",
    "84dee6e676e5bb67b4ad4e042cf70cbd8681155db535942fcc6a0533858a7240",
};

/// Names of a few different lengths, so the identity line is not uniformly
/// short. One is long enough to need the ellipsis bound, because the branch
/// that decides that is on the path being measured and a corpus where it never
/// fires would measure only half of it.
const names = [_][]const u8{
    "fiatjaf",
    "jack",
    "jb55",
    "ODELL",
    "Gigi",
    "a display name long enough that it has to be held to the width of its box",
};

/// Bodies of a few different lengths, cycled. Text only: an image or a link
/// would send the app to the network, which is the variance being removed.
const bodies = [_][]const u8{
    "gm",
    "Short one.",
    "A middling note, the length most notes actually are, with enough words in it to wrap onto a second line at the reading column's width.",
    "A long one. " ** 18,
    "Two lines,\nexplicitly.",
    "A note with a nostr: mention in it that resolves to nothing here, so the renderer walks the same path it walks for a real one without needing anything fetched: nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsevaq2",
};

const notes_per_author = 40;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const dir_arg = args.next();
    if (dir_arg == null) {
        std.debug.print(
            \\usage: seed-feed <dir>
            \\
            \\Creates <dir>/feed.mdb holding a fixed feed, and <dir>/relays so the
            \\app that opens it dials nothing. Point the app at it with HOME=<dir's
            \\parent>, which is all the isolation it needs: the store, the identity,
            \\the session and the relay list all hang off $HOME/.plaza.
            \\
        , .{});
        std.process.exit(2);
    }
    const dir_path = dir_arg.?;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    // An EMPTY relay list, which is what stops the app dialling. A missing file
    // means "first run", and the app seeds itself the relays it was born with
    // and connects to all of them; a present, empty one is a reader who removed
    // every relay, and the pool parks. No app change needed for any of this.
    try dir.writeFile(io, .{ .sub_path = "relays", .data = "" });

    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/feed.mdb", .{dir_path});
    var store = try nostr.store.Store.open(db_path, .{ .map_size = 1 << 30 });
    defer store.deinit();

    var written: usize = 0;
    for (starter_pack_hex, 0..) |pk_hex, ai| {
        const pubkey = try nostr.hex.decodeFixed(32, pk_hex);

        // A profile first, stamped older than every note, which is the real
        // shape: a name is written once and posted over ever since.
        const meta = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{names[ai % names.len]});
        defer gpa.free(meta);
        _ = try store.putEvent(gpa, makeEvent(idOf(ai, 0, .meta), pubkey, 1_700_000_000, 0, meta));
        written += 1;

        for (0..notes_per_author) |n| {
            const body = bodies[(ai + n) % bodies.len];
            // Interleaved in time across authors, so the feed's merge does real
            // work instead of returning one author's run.
            const at: i64 = 1_800_000_000 + @as(i64, @intCast(n * starter_pack_hex.len + ai));
            _ = try store.putEvent(gpa, makeEvent(idOf(ai, n, .note), pubkey, at, 1, body));
            written += 1;
        }
    }

    std.debug.print("seed-feed: {d} events into {s}\n", .{ written, db_path });
}

const Kind = enum { meta, note };

/// A distinct, reproducible id. Derived from the position rather than hashed
/// from the content, so re-running writes the same ids over the same records
/// and the store does not grow every time the harness runs.
fn idOf(author: usize, index: usize, kind: Kind) [32]u8 {
    var id = [_]u8{0} ** 32;
    std.mem.writeInt(u64, id[0..8], @as(u64, author) << 40 | @as(u64, index) << 8 | @intFromEnum(kind), .big);
    return id;
}

fn makeEvent(id: [32]u8, pubkey: [32]u8, created_at: i64, kind: u16, content: []const u8) nostr.event.Event {
    return .{
        .id = id,
        .pubkey = pubkey,
        .created_at = created_at,
        .kind = kind,
        .tags = &.{},
        .content = content,
        .sig = [_]u8{0} ** 64,
    };
}

test "an id is stable across runs and distinct within one" {
    // Re-running the seeder must overwrite the same records rather than add
    // more, or the corpus grows every time the harness is used and the numbers
    // drift for the reason the harness exists to remove.
    try std.testing.expectEqual(idOf(2, 7, .note), idOf(2, 7, .note));
    try std.testing.expect(!std.mem.eql(u8, &idOf(2, 7, .note), &idOf(2, 7, .meta)));
    try std.testing.expect(!std.mem.eql(u8, &idOf(2, 7, .note), &idOf(3, 7, .note)));
    try std.testing.expect(!std.mem.eql(u8, &idOf(2, 7, .note), &idOf(2, 8, .note)));
}

test "the corpus exercises both sides of the identity width branch" {
    // One name is deliberately longer than the identity box, so the harness
    // measures the bounded path as well as the cheap one. A corpus of short
    // names would measure half the code and call it the layout cost.
    var any_long = false;
    for (names) |n| {
        if (n.len > 40) any_long = true;
    }
    try std.testing.expect(any_long);
}

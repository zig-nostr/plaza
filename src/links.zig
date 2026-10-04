//! Links in and out: plaza:// links handed to the app, and external URLs opened in the browser.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const places = @import("places.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const place_looking_toast = main.place_looking_toast;
const setToast = main.setToast;
const samePlace = main.samePlace;
const leaveNotifications = main.leaveNotifications;
const leaveSettings = main.leaveSettings;
const Effects = main.Effects;
const Model = main.Model;
const askPlace = main.askPlace;
const copyBounded = main.copyBounded;
const nowSeconds = main.nowSeconds;
const place_kind = main.place_kind;
const plazaDir = main.plazaDir;
const secret_file_permissions = main.secret_file_permissions;

// A pressed link is handed to the OS opener. The URL comes from note content,
// which is untrusted, so it is validated before it ever becomes an argument: it
// must be a plain http(s) URL with no whitespace or control bytes. There is no
// shell involved (argv is passed as a vector), and a leading scheme means the
// opener can never read it as a flag or a local path.
var g_open_url_buf: [1024]u8 = undefined;

/// Whether `url` is safe to hand to the system opener.
/// The toolkit's own gate on `openUrl`, declared where the test can reach it.
///
/// `*` is deliberate and is explained at the call site: the toolkit's pattern
/// language cannot express "any https URL", so a narrower-looking pattern here
/// is a pattern that matches nothing and denies every link. `isSafeExternalUrl`
/// is the gate that actually narrows, and it runs first.
pub const external_link_policy: native_sdk.ExternalLinkPolicy = .{
    .action = .open_system_browser,
    .allowed_urls = &.{"*"},
};

pub fn isSafeExternalUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    if (url.len > g_open_url_buf.len) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Opens `url` in the user's browser, if it passes validation.
pub fn openExternally(fx: *Effects, url: []const u8) void {
    if (!isSafeExternalUrl(url)) return;
    // The link slice lives in the view arena, so copy it before the effect runs.
    @memcpy(g_open_url_buf[0..url.len], url);
    const owned = g_open_url_buf[0..url.len];
    // The host's own opener, not `/usr/bin/open`. That path is a macOS binary
    // and nothing else, so every link in this app was a silent no-op anywhere
    // else: the spawn registered no `on_exit` either, so not even the rejection
    // came back. The toolkit has always had this seam and routes it to
    // `NSWorkspace` on macOS and `gtk_uri_launcher` on Linux, which is the same
    // behaviour on the platform that used to work and working behaviour on the
    // one that did not.
    fx.hostSend("native-sdk.os.openUrl", owned);
}
/// Boot: seed the feed once, register whatever images are already cached, then
/// arm the repeating timers.
/// Receiving a `plaza://` link. See `src/urlscheme.m`: the SDK registers the
/// scheme but hands the app nothing, so Plaza installs its own Apple Event
/// handler. macOS-only; elsewhere these are stubs and a link does nothing,
/// which is honest because no other platform routes one here either.
/// Not in test builds: the suite does not link AppKit (nothing in it receives
/// an Apple Event, and linking it would make the tests need a window server),
/// so referencing the symbols there would fail to link.
pub const has_url_scheme = builtin.os.tag == .macos and !builtin.is_test;
pub extern fn plaza_url_scheme_install() void;
extern fn plaza_url_scheme_take(out: [*]u8, cap: usize) usize;

/// A `plaza://` link this process was STARTED with, held until the tick takes it.
///
/// macOS delivers links as an Apple Event (`src/urlscheme.m`), which is the only
/// inbound path the toolkit's macOS host has. Everywhere else the desktop
/// entry's `%u` puts the link in argv and nothing delivers it at all, so this is
/// the whole of cold start there. Without it, following a link on Linux launches
/// Plaza and drops the link on the floor, and a place has no other door.
///
/// Cold start only. A link clicked while Plaza is ALREADY running is handed to
/// the running process by the desktop environment, and the toolkit's GTK host
/// discards it before any app code runs: it builds the application with
/// `G_APPLICATION_DEFAULT_FLAGS` and calls `g_application_run` with no argv at
/// all, so there is nothing this side can read. Filed upstream as
/// vercel-labs/native#422.
pub var g_argv_link_buf: [2048]u8 = undefined;
pub var g_argv_link_len: usize = 0;

/// Where a link waits for the window that will open it.
///
/// Following a `plaza://` link from a browser starts a NEW process every time,
/// running or not. On a first launch that process is the app and reads its own
/// argv. On a second, GTK's single-instance machinery hands the launch to the
/// window already open and this process exits, so whatever it read dies with it
/// and the reader watches Plaza come to the front and do nothing.
///
/// Our code runs before the toolkit's does, which is the whole of the fix: the
/// link goes to a file, and whichever process owns the window picks it up on its
/// next tick. One path serves both cases, so there is no "am I the first one"
/// guess to get wrong.
const pending_link_file = "pending-link";

/// How long a link on disk is still worth opening. A file left by a crash is
/// not something the reader just clicked, and opening a room they asked for
/// yesterday is worse than doing nothing.
const pending_link_stale_s: i64 = 120;

/// Reads the command line once, at startup, before any window exists.
pub fn captureArgvLink(args: std.process.Args) void {
    var it = std.process.Args.Iterator.init(args);
    defer it.deinit();
    // Past argv[0]: the executable's own path is not a link.
    _ = it.next();
    while (it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "plaza://")) continue;
        if (arg.len > g_argv_link_buf.len) continue;
        @memcpy(g_argv_link_buf[0..arg.len], arg);
        g_argv_link_len = arg.len;
        writePendingLink(arg);
        // The first one wins. A launcher passing two is not a case worth
        // guessing about, and opening two rooms in one tick is worse than
        // opening the one that was asked for first.
        return;
    }
}

/// Hands the link to whichever process owns the window. Best effort: a link
/// that cannot be written is one the reader will click again.
fn writePendingLink(link: []const u8) void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    writePendingLinkIn(io, &dir, link, nowSeconds());
}

pub fn writePendingLinkIn(io: std.Io, dir: *std.Io.Dir, link: []const u8, now_s: i64) void {
    var buf: [2176]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d}\n{s}", .{ now_s, link }) catch return;
    dir.writeFile(io, .{
        .sub_path = pending_link_file,
        .data = body,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// Takes the link off disk, once. Deleted on the way out whether or not it was
/// still fresh, so a stale one cannot be re-read every second forever.
fn takeWrittenLink(buf: []u8) ?[]const u8 {
    const io = main.g_io orelse return null;
    const environ = main.g_environ orelse return null;
    var dir = plazaDir(io, environ) catch return null;
    defer dir.close(io);
    return takeWrittenLinkIn(io, &dir, buf, nowSeconds());
}

pub fn takeWrittenLinkIn(io: std.Io, dir: *std.Io.Dir, buf: []u8, now_s: i64) ?[]const u8 {
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, pending_link_file, gpa, std.Io.Limit.limited(4096)) catch return null;
    defer gpa.free(raw);
    dir.deleteFile(io, pending_link_file) catch {};
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return null;
    const stamp = std.fmt.parseInt(i64, raw[0..nl], 10) catch return null;
    if (now_s - stamp > pending_link_stale_s) return null;
    const link = raw[nl + 1 ..];
    if (link.len == 0 or link.len > buf.len) return null;
    if (!std.mem.startsWith(u8, link, "plaza://")) return null;
    @memcpy(buf[0..link.len], link);
    return buf[0..link.len];
}

/// The link handed to us since the last tick, if any.
pub fn takePendingLink(buf: []u8) ?[]const u8 {
    // Taken ONCE, whichever way it arrived: the tick polls this every second
    // and a link that stayed would reopen its place forever.
    if (g_argv_link_len > 0) {
        const n = @min(g_argv_link_len, buf.len);
        @memcpy(buf[0..n], g_argv_link_buf[0..n]);
        g_argv_link_len = 0;
        // Ours, and already in hand: drop the copy on disk so the tick after
        // this one does not open the same room a second time.
        clearPendingLink();
        return buf[0..n];
    }
    if (takeWrittenLink(buf)) |link| return link;
    if (!has_url_scheme) return null;
    const n = plaza_url_scheme_take(buf.ptr, buf.len);
    if (n == 0) return null;
    return buf[0..n];
}

fn clearPendingLink() void {
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    dir.deleteFile(io, pending_link_file) catch {};
}
/// What a `plaza://` link asks for.
///
/// One shape in v1: `plaza://place/<naddr>`, which applies somebody's published
/// place. The path segment is there so a later version can add others without
/// the first form becoming ambiguous.
///
/// Untrusted: a link can come from a note, a DM, or anywhere else. It names
/// what to fetch and never carries the place itself, so the worst a hostile link
/// can do is point Plaza at an event that is not a place, which the parser
/// refuses, or one that is, which is then shown before it applies.
pub fn parsePlazaLink(link: []const u8) ?[]const u8 {
    const prefix = "plaza://place/";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    var rest = link[prefix.len..];
    // A query or fragment is ordinary link decoration (a tracker, an anchor)
    // and is cut off.
    if (std.mem.indexOfAny(u8, rest, "?#")) |cut| rest = rest[0..cut];
    if (rest.len == 0 or rest.len > 1024) return null;
    if (!std.mem.startsWith(u8, rest, "naddr1")) return null;
    // bech32 is lowercase alphanumeric. Checked here so nothing downstream has
    // to wonder what a stranger put in the path, and it is also what refuses an
    // extra path segment: `plaza://place/<naddr>` has exactly one, and a `/`
    // is not a bech32 character. I wrote a separate check for that first and no
    // probe could fail it, because this one already covered it.
    for (rest) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (!ok) return null;
    }
    return rest;
}
pub fn handlePlazaLink(model: *Model, fx: *Effects, link: []const u8) void {
    const naddr = parsePlazaLink(link) orelse return;
    const gpa = std.heap.page_allocator;
    var ptr = nostr.nip19.decodeNaddr(gpa, naddr) catch return;
    defer ptr.deinit(gpa);
    // Only ever a place. The link says `place`, so an address pointing at some
    // other kind is a link that lies, not a kind to go and fetch.
    if (ptr.kind != place_kind) return;

    var want: @TypeOf(places.g_place_want.?) = .{ .pubkey = ptr.pubkey, .ident_buf = @splat(0), .ident_len = 0 };
    want.ident_len = @intCast(copyBounded(&want.ident_buf, ptr.identifier));
    places.g_place_want = want;
    askPlace(fx, ptr.relays);
    // What the address field does with a place, for the same reasons: the room
    // is drawn under Settings and the notifications sheet, so both are left,
    // and a room is not a level that Back could return to the sheet through.
    if (model.stage == .settings) leaveSettings(model);
    leaveNotifications(model);
    if (!model.levelOpen()) model.notifications_return = false;
    // And the link was heard. The tick reads the store right after this, and
    // a room already held there opens and takes the toast down again.
    if (!samePlace(want)) setToast(model, place_looking_toast);
}

pub fn writePendingLinkForTest(io: std.Io, dir: *std.Io.Dir, link: []const u8, now_s: i64) void {
    writePendingLinkIn(io, dir, link, now_s);
}

pub fn takeWrittenLinkForTest(io: std.Io, dir: *std.Io.Dir, buf: []u8, now_s: i64) ?[]const u8 {
    return takeWrittenLinkIn(io, dir, buf, now_s);
}

pub fn captureArgvLinkForTest(link: []const u8) void {
    if (link.len > g_argv_link_buf.len) return;
    @memcpy(g_argv_link_buf[0..link.len], link);
    g_argv_link_len = link.len;
}

pub fn takePendingLinkForTest(buf: []u8) ?[]const u8 {
    return takePendingLink(buf);
}

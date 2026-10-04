//! Reader settings: media previews, the client tag, the media proxy, and the settings file.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const hiding = @import("hiding.zig");
const updates = @import("updates.zig");
const places = @import("places.zig");
const follows = @import("follows.zig");
const compose = @import("compose.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const activePlaceLine = main.activePlaceLine;
const applyActivePlaceLine = main.applyActivePlaceLine;
const applyHiddenLine = main.applyHiddenLine;
const forgetDirectFallbacks = main.forgetDirectFallbacks;
const forgetProxyRefusals = main.forgetProxyRefusals;
const hiddenLine = main.hiddenLine;
const plazaDir = main.plazaDir;
const secret_file_permissions = main.secret_file_permissions;

// --------------------------------------------------------------- media proxy
//
// The image registry decodes at most a 512x512 image and the fetch effect caps
// bodies at 256 KiB, so a full-size photo can neither be downloaded nor decoded
// as-is. Images are therefore requested at the size they will actually be drawn:
// through a host's own resizer when it has one, otherwise through a
// weserv-compatible proxy (the free public wsrv.nl by default, and any instance
// the user prefers, including their own). Clearing the setting loads originals
// straight from their host, which still works for anything small enough.

const default_media_proxy = "https://wsrv.nl/";
/// Whether the app reaches out for the things a note POINTS AT: its picture, the
/// faces of the people in the feed, the page a link goes to, and the domain a
/// NIP-05 name claims. On by default, because a feed of grey boxes is not the
/// app. Off, none of that leaves the machine until the reader asks for a
/// particular picture, and the only hosts that learn anything are the relays,
/// which are the ones the reader chose.
///
/// It covers every unattended fetch, deliberately: gating only the pictures
/// would leave each author's own domain and every avatar host still learning
/// that you are reading, which is exactly what the switch is for.
pub var g_media_previews: bool = true;

pub fn mediaPreviews() bool {
    return g_media_previews;
}

pub fn setMediaPreviews(on: bool) void {
    g_media_previews = on;
}

/// Whether notes their authors marked sensitive (NIP-36) are drawn like any
/// other. OFF by default: the author asked for the note to be covered and the
/// reader has not said they would rather not be asked. Jumble keeps the same
/// switch (`NSFW_DISPLAY_POLICY.SHOW`, `src/constants.ts:329`) and Amethyst's
/// `WarningType` has a Show entry (`SecurityFiltersScreen.kt:116`); both default
/// to covering.
pub var g_show_sensitive: bool = false;

pub fn showSensitive() bool {
    return g_show_sensitive;
}

pub fn setShowSensitive(on: bool) void {
    g_show_sensitive = on;
}
/// Whether notes published from here say so, with NIP-89's `client` tag.
///
/// OFF by default. The tag is a small permanent fact about the reader attached
/// to everything they write: not what they said, but what they said it WITH, and
/// it follows the note to every relay and every client forever. NIP-89 puts the
/// privacy question in the spec itself ("clients SHOULD allow users to opt-out
/// of using this tag"), which is unusual enough to be worth reading as a hint
/// about which way the default should fall.
///
/// The argument the other way is real and lost: this is how anyone discovers a
/// new client exists at all. Sepehr chose the private default (2026-07-31), so
/// Plaza is invisible in other people's clients unless the reader decides
/// otherwise. Reading the tag on OTHER people's notes is unaffected: that is
/// their disclosure, already made.
pub var g_client_tag: bool = false;

pub fn clientTag() bool {
    return g_client_tag;
}

pub fn setClientTag(on: bool) void {
    g_client_tag = on;
}

/// What Plaza calls itself in that tag. NIP-89's full tuple also carries a
/// `31990:<pubkey>:<d>` handler address and a relay hint, which point at a
/// handler event Plaza does not publish; the name alone is valid, and is what
/// most clients actually emit.
pub const client_tag_name = "Plaza";

var g_media_proxy_buf: [200]u8 = undefined;
pub var g_media_proxy_len: usize = 0;

/// The configured proxy base URL, empty when images load directly.
pub fn mediaProxy() []const u8 {
    return g_media_proxy_buf[0..g_media_proxy_len];
}

/// Sets the proxy base URL (trimmed; empty disables proxying).
/// Whether image URLs are routed through the proxy at all.
///
/// ON by default, and not only for privacy: the proxy RESIZES. The registry
/// decodes at most 512x512, so a 2040x1536 photograph is 611 KB direct and a
/// fraction of that proxied, and the difference is downloaded and thrown away.
/// One note with three pictures measured 825 KB direct.
pub var g_media_proxy_on: bool = true;

/// Whether a picture the proxy REFUSES is then fetched from its own host.
///
/// ON by default, because the alternative is a broken picture, and a broken
/// picture reads as a broken app. The public proxy blocks whole TLDs by policy
/// (code 400, "Domain or TLD blocked by policy") for Blossom hosts that serve
/// the same file directly without complaint, and that is not something this app
/// can fix from here.
///
/// The cost is stated rather than hidden: a fallback fetch is a request to that
/// host, so it sees the reader's address. Turning it off means those pictures do
/// not load at all, which is a legitimate thing to want and is why this is a
/// switch rather than a silent behaviour.
pub var g_media_direct_fallback: bool = true;

pub fn mediaProxyOn() bool {
    return g_media_proxy_on;
}

pub fn setMediaProxyOn(on: bool) void {
    g_media_proxy_on = on;
    // A proxy that has just been switched on has refused nothing yet, and one
    // switched off has no policy to remember.
    forgetProxyRefusals();
}

pub fn mediaDirectFallback() bool {
    return g_media_direct_fallback;
}

pub fn setMediaDirectFallback(on: bool) void {
    g_media_direct_fallback = on;
    // Off means off from now, not from the next refusal: every host and every
    // picture already marked to load direct goes back through the proxy.
    if (!on) {
        forgetProxyRefusals();
        forgetDirectFallbacks();
    }
}

/// Whether a typed proxy base is one this app can build a request from: an
/// `http://` or `https://` address that names a host, with no space or control
/// byte in it, short enough for the buffer it is kept in. Empty is not asked
/// here, because empty is a choice (load originals) and the caller decides it.
///
/// Plain `http://` is allowed, unlike a relay: the proxy is the reader's own
/// pick, often an instance on their own network, and what it carries is
/// pictures that were public to begin with.
pub fn isMediaProxyUrl(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (url.len > g_media_proxy_buf.len) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    if (host.len == 0 or host[0] == ':') return false;
    return std.mem.indexOfScalar(u8, host, '@') == null;
}

pub fn setMediaProxy(url: []const u8) void {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const n = @min(trimmed.len, g_media_proxy_buf.len);
    @memcpy(g_media_proxy_buf[0..n], trimmed[0..n]);
    g_media_proxy_len = n;
    // A different proxy answers for itself rather than inheriting the last
    // one's policy. The per-face flag already followed this rule; the hosts
    // now follow it too, in one place instead of three.
    forgetProxyRefusals();
}
/// Loads app-wide settings (the media proxy) from `$HOME/.plaza/settings`,
/// starting from the default so a fresh install proxies out of the box.
pub fn loadSettings(io: std.Io, environ: *const std.process.Environ.Map) void {
    setMediaProxy(default_media_proxy);
    g_media_previews = true;
    g_show_sensitive = false;
    g_client_tag = false;
    updates.g_update_check = true;
    g_media_proxy_on = true;
    g_media_direct_fallback = true;
    hiding.g_hidden = @splat(false);
    places.g_rail_open = false;
    places.g_boot_place_set = false;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "settings", gpa, std.Io.Limit.limited(2048)) catch return;
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        // An empty value is meaningful: the user chose to load originals.
        // Anything that is not an address keeps the default. A value written
        // before the field checked what it was given would otherwise send every
        // uncached picture to a URL that goes nowhere.
        if (std.mem.eql(u8, line[0..eq], "media_proxy")) {
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r\n");
            if (value.len == 0 or isMediaProxyUrl(value)) setMediaProxy(value);
        }
        if (std.mem.eql(u8, line[0..eq], "media_previews")) g_media_previews = std.mem.eql(u8, line[eq + 1 ..], "on");
        if (std.mem.eql(u8, line[0..eq], "show_sensitive")) g_show_sensitive = std.mem.eql(u8, line[eq + 1 ..], "on");
        if (std.mem.eql(u8, line[0..eq], "client_tag")) g_client_tag = std.mem.eql(u8, line[eq + 1 ..], "on");
        if (std.mem.eql(u8, line[0..eq], "update_check")) updates.g_update_check = std.mem.eql(u8, line[eq + 1 ..], "on");
        if (std.mem.eql(u8, line[0..eq], "media_proxy_on")) g_media_proxy_on = std.mem.eql(u8, line[eq + 1 ..], "on");
        if (std.mem.eql(u8, line[0..eq], "media_direct_fallback")) g_media_direct_fallback = std.mem.eql(u8, line[eq + 1 ..], "on");
        // Written by id rather than by position, so adding an element to the
        // registry, or reordering it, cannot silently un-hide something.
        if (std.mem.eql(u8, line[0..eq], "hidden")) applyHiddenLine(line[eq + 1 ..]);
        if (std.mem.eql(u8, line[0..eq], "rail_open")) places.g_rail_open = std.mem.eql(u8, line[eq + 1 ..], "on");
        // Only a name this app wrote. Anything else keeps the default, which
        // for a key made here is set at the mint and for every other key is
        // their own follows.
        if (std.mem.eql(u8, line[0..eq], "home_scope")) {
            const val = line[eq + 1 ..];
            if (std.mem.eql(u8, val, "starter_pack")) follows.g_home_scope = .starter_pack;
            if (std.mem.eql(u8, val, "following")) follows.g_home_scope = .following;
        }
        if (std.mem.eql(u8, line[0..eq], "post_delay")) {
            // Anything unreadable keeps the default rather than turning the
            // pause off: a corrupt line should not quietly remove a safeguard.
            const n = std.fmt.parseInt(i64, line[eq + 1 ..], 10) catch continue;
            compose.g_post_delay_s = switch (n) {
                0, 5, 10 => n,
                else => compose.g_post_delay_s,
            };
        }
        // An empty value is meaningful here too: it is your own Plaza.
        if (std.mem.eql(u8, line[0..eq], "place")) applyActivePlaceLine(line[eq + 1 ..]);
    }
}
/// Persists app-wide settings. Best-effort, like the session file.
/// Counts what `saveSettings` was ASKED to do, before it needs a filesystem to
/// do it. The bug it exists for is a transition that never asked at all.
pub var g_settings_writes: usize = 0;
pub fn saveSettings() void {
    g_settings_writes += 1;
    const io = main.g_io orelse return;
    const environ = main.g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var hidden_buf: [256]u8 = undefined;
    const hidden_ids = hiddenLine(&hidden_buf);
    var place_buf: [160]u8 = undefined;
    const place = activePlaceLine(&place_buf);
    var buf: [1024]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "media_proxy={s}\nmedia_previews={s}\nclient_tag={s}\nhidden={s}\nmedia_proxy_on={s}\nmedia_direct_fallback={s}\nrail_open={s}\nplace={s}\npost_delay={d}\nhome_scope={s}\nupdate_check={s}\nshow_sensitive={s}\n", .{
        mediaProxy(),
        if (g_media_previews) "on" else "off",
        if (g_client_tag) "on" else "off",
        hidden_ids,
        if (g_media_proxy_on) "on" else "off",
        if (g_media_direct_fallback) "on" else "off",
        if (places.g_rail_open) "on" else "off",
        place,
        compose.g_post_delay_s,
        @tagName(follows.g_home_scope),
        if (updates.g_update_check) "on" else "off",
        if (g_show_sensitive) "on" else "off",
    }) catch return;
    dir.writeFile(io, .{
        .sub_path = "settings",
        .data = data,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch |err| std.debug.print("plaza: could not persist settings: {s}\n", .{@errorName(err)});
}

pub fn settingsWritesForTest() usize {
    return g_settings_writes;
}

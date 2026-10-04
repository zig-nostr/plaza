//! The release check: whether a newer Plaza exists, asked politely and at most once at a time.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Effects = main.Effects;
const isSafeShareUrl = main.isSafeShareUrl;
const networkAllowed = main.networkAllowed;
const plaza_version = main.plaza_version;
const update_check_key = main.update_check_key;

/// True when the well-known JSON maps the identifier's name to `pubkey`. This is
/// the whole trust test: a check is drawn on this and nothing weaker.
// --------------------------------------------------------------- the update
//
// Whoever installed Plaza is otherwise on that build until they happen to visit
// the site, which makes shipping a fix worth less than it should be.
//
// TOLD, not done. Plaza is ad-hoc signed and installed by a script that clears
// quarantine, and it is not going to replace its own bundle while running. A
// line saying a newer version exists, with one press to go and get it, is the
// honest amount of automation for how this app is distributed. The toolkit does
// ship a signed self-updater; it swaps the bundle and relaunches, it is macOS
// only while Plaza also ships Linux, and it wants a signed feed hosted
// somewhere. All three are reasons this does not use it.
//
// The releases API, because that is the same document `scripts/install-macos.sh`
// already reads. One source of truth for what the newest release is, rather than
// a second one to keep in step.

const update_check_url = "https://api.github.com/repos/zig-nostr/plaza/releases/latest";

/// Whether to ask at all. OFF IS A REAL ANSWER: a client that contacts a server
/// on a timer should say so and let it be switched off, and while it is off it
/// makes no request. The gate is in `maybeCheckForUpdate` before the fetch, not
/// in the handler after it.
pub var g_update_check: bool = true;
/// The newest release seen, when it is newer than this build. Empty otherwise.
var g_update_version_buf: [24]u8 = @splat(0);
pub var g_update_version_len: usize = 0;
var g_update_url_buf: [160]u8 = @splat(0);
pub var g_update_url_len: usize = 0;
/// A request is out. One at a time: the key is a single value, not a base.
pub var g_update_asking: bool = false;
/// When to ask next, in `awake` milliseconds. Set at boot to a short delay so
/// the first ask does not race the feed for the network on a cold start.
pub var g_update_next_at_ms: i64 = 0;
/// Put away for this session. Not persisted: a newer version is still newer
/// tomorrow, and a dismissal that outlived the release it was about would be a
/// reader told once and never again.
pub var g_update_dismissed: bool = false;

/// The first ask waits this long after launch, so the feed gets the network
/// first on a cold start.
const update_first_delay_ms: i64 = 20_000;
/// And then this far apart. A release is not something that happens hourly.
const update_interval_ms: i64 = 6 * 60 * 60 * 1000;

pub fn updateCheckOn() bool {
    return g_update_check;
}

pub fn setUpdateCheck(on: bool) void {
    g_update_check = on;
    // Nothing is cleared here, deliberately. `pendingUpdateVersion` already
    // returns nothing while the switch is off, so clearing the buffers changed
    // nothing a reader could see. What it DID change is switching back on: the
    // news would be gone until the next check came round, up to six hours
    // later, and that release is still out. Keep it and show it again.
    //
    // I wrote the clear first and a probe found no test could tell the
    // difference, which is how the behaviour question got asked at all.
}

/// The version this build is being offered, empty when there is nothing newer
/// or the reader has put it away.
pub fn pendingUpdateVersion() []const u8 {
    if (!g_update_check or g_update_dismissed) return "";
    return g_update_version_buf[0..g_update_version_len];
}

pub fn pendingUpdateUrl() []const u8 {
    if (!g_update_check or g_update_dismissed) return "";
    return g_update_url_buf[0..g_update_url_len];
}

/// Whether to ask right now.
///
/// Pure over the four inputs, because the promise this keeps is not observable
/// any other way: the fetch cannot run under test at all (`networkAllowed` is
/// comptime false there), so "off makes no request" has to be asserted on the
/// decision rather than on the socket.
///
/// `enabled` is read FIRST and on its own. Off is not "ask less often" or "ask
/// and ignore the answer", it is do not ask, and a reader who switched this off
/// is owed exactly that.
pub fn updateCheckDue(enabled: bool, asking: bool, now_ms: i64, next_at_ms: i64) bool {
    if (!enabled) return false;
    if (asking) return false;
    return now_ms >= next_at_ms;
}

/// Asks the releases API, at most once every `update_interval_ms`.
///
/// Driven from the tick with a due stamp, which is the idiom this app already
/// uses for anything slower than a tick (`pollHelper` polls the keyholder the
/// same way). There is no one-shot timer to reach for.
pub fn maybeCheckForUpdate(fx: *Effects) void {
    if (!networkAllowed()) return;
    const io = main.g_io orelse return;
    const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    if (!updateCheckDue(g_update_check, g_update_asking, now, g_update_next_at_ms)) return;
    g_update_next_at_ms = now + update_interval_ms;
    g_update_asking = true;
    fx.fetch(.{
        .key = update_check_key,
        .url = update_check_url,
        // What the API wants to be asked for. Without it the answer is the v3
        // default, which is the same shape today and is not promised to stay.
        .headers = &.{.{ .name = "accept", .value = "application/vnd.github+json" }},
        .timeout_ms = 10_000,
        .on_response = Effects.responseMsg(.update_checked),
    });
}

/// What the releases API answered.
///
/// A failure is silent on purpose. Nobody asked for this, it runs on a timer,
/// and a reader who cannot reach GitHub is told nothing rather than shown an
/// error about a check they did not request. The next due time is already set.
pub fn handleUpdateChecked(response: native_sdk.EffectResponse) void {
    g_update_asking = false;
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0) return;
    // `response.body` is valid only for this call, so what is kept is copied
    // into the buffers rather than aliased.
    var version_buf: [24]u8 = undefined;
    var url_buf: [160]u8 = undefined;
    const news = newerRelease(response.body, plaza_version, &version_buf, &url_buf) orelse return;
    @memcpy(g_update_version_buf[0..news.version_len], version_buf[0..news.version_len]);
    g_update_version_len = news.version_len;
    @memcpy(g_update_url_buf[0..news.url_len], url_buf[0..news.url_len]);
    g_update_url_len = news.url_len;
}
/// What a release document said, once it is known to be newer than this build.
pub const ReleaseNews = struct {
    version_len: usize,
    url_len: usize,
};

/// Strips one leading `v`, which is the same thing CI does when it checks a tag
/// against `app.zon` (`tagged="${GITHUB_REF_NAME#v}"`). Exactly one: `vv1.0.0`
/// is not a version this project ever writes.
fn withoutVPrefix(tag: []const u8) []const u8 {
    if (tag.len > 1 and (tag[0] == 'v' or tag[0] == 'V')) return tag[1..];
    return tag;
}

/// Reads a GitHub release document and reports the version it names when that
/// version is NEWER than `current`. Null otherwise: same version, older, or
/// anything that did not parse.
///
/// Pure over the bytes so the comparison is testable without a network, which
/// is the shape `nip05Matches` already uses for a third party's JSON.
///
/// A real ORDER, not a string compare. "0.9.0" sorts after "0.10.0" as text,
/// so a string inequality would offer somebody an upgrade that is a downgrade,
/// and would do it exactly once per launch forever.
pub fn newerRelease(body: []const u8, current: []const u8, version_out: []u8, url_out: []u8) ?ReleaseNews {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch return null;
    if (root != .object) return null;

    // A draft or a prerelease is not something to send anybody to. Both are
    // absent from `/releases/latest` today, and reading them costs nothing and
    // stops this from depending on that staying true.
    if (root.object.get("draft")) |d| {
        if (d == .bool and d.bool) return null;
    }
    if (root.object.get("prerelease")) |p| {
        if (p == .bool and p.bool) return null;
    }

    const tag = root.object.get("tag_name") orelse return null;
    if (tag != .string) return null;
    const theirs = withoutVPrefix(tag.string);

    const mine = std.SemanticVersion.parse(withoutVPrefix(current)) catch return null;
    const newest = std.SemanticVersion.parse(theirs) catch return null;
    if (newest.order(mine) != .gt) return null;

    // The release PAGE, which carries the notes and the downloads together, so
    // "what is in it" and "where do I get it" are one press rather than two.
    const url = root.object.get("html_url") orelse return null;
    if (url != .string) return null;
    if (!isSafeShareUrl(url.string)) return null;
    if (theirs.len > version_out.len or url.string.len > url_out.len) return null;

    @memcpy(version_out[0..theirs.len], theirs);
    @memcpy(url_out[0..url.string.len], url.string);
    return .{ .version_len = theirs.len, .url_len = url.string.len };
}

pub fn resetUpdateStateForTest() void {
    g_update_check = true;
    g_update_version_len = 0;
    g_update_url_len = 0;
    g_update_asking = false;
    g_update_dismissed = false;
    g_update_next_at_ms = 0;
}
